package gateway

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"errors"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

type Task string

const (
	RolePlay          Task = "role_play"
	ReplySuggestion   Task = "reply_suggestion"
	Scoring           Task = "scoring"
	ProfileInference  Task = "profile_inference"
	ReviewAnalysis    Task = "review_analysis"
	ContentGeneration Task = "content_generation"
	Classification    Task = "classification"
)

func (t Task) valid() bool {
	switch t {
	case RolePlay, ReplySuggestion, Scoring, ProfileInference, ReviewAnalysis, ContentGeneration, Classification:
		return true
	}
	return false
}
func inCanary(id uuid.UUID, percent int) bool {
	h := sha256.Sum256(id[:])
	return int(binary.BigEndian.Uint64(h[:8])%100) < percent
}

// Scope comes from authenticated server state, never from routing parameters supplied by the client.
type Scope struct{ User, Operation, Activity, Contact, PromptVersion uuid.UUID }

// Generated is a complete model output retained by the caller before output
// moderation. Replaying it must still repeat the safety checks, but must not
// dispatch the model or invoke OnGenerated again.
type Generated struct {
	Task   Task
	Raw    string
	CallID uuid.UUID
}

type Call struct {
	Scope
	Task      Task
	Mode      Mode
	Variables map[string]string
	Messages  []Message
	Emit      func(context.Context, Event) error
	// ProfileOwner binds profile-inference accounting to the reservation owner.
	// It is metadata, never proof that the request was authorized or dispatched.
	ProfileOwner uuid.UUID
	// Guard rechecks authorization before any external review, after moderation,
	// and before each model call or streamed fragment. It must never be sourced
	// from client input.
	Guard func(context.Context) error
	// BeforeAttempt runs immediately before each provider dispatch, including
	// moderation and fallback attempts. Returning an error aborts the dispatch.
	BeforeAttempt func(context.Context) error
	// BeforeGenerate rechecks mutable authorization and lease state after input
	// moderation and immediately before model generation. Fallback generation is
	// another external round trip and therefore checks it before that attempt too.
	BeforeGenerate func(context.Context) error
	// OnGenerated durably retains the opaque complete output before output
	// moderation. It is not called when replaying a persisted Generated result.
	OnGenerated func(context.Context, uuid.UUID, string) error
	// Generated replays an already persisted output. It still repeats all
	// moderation, but never dispatches a model or calls OnGenerated.
	Generated *Generated
	// Authorize wraps the actual external dispatch. The owning module must call
	// send only while its authorization/lock scope is still active, so a
	// withdrawal cannot commit between the check and the provider request. The
	// transaction passed to send must be reused by every database-backed step of
	// the dispatch, including revision lookup, to avoid borrowing a second pool
	// connection while the authorization transaction holds its own.
	Authorize func(context.Context, pgx.Tx, func(context.Context, pgx.Tx) error) error
}

type authorizedDispatchKey struct{}
type authorizedScope struct{ tx pgx.Tx }

type dispatchReceipt struct {
	id         uuid.UUID
	dispatched atomic.Bool
}
type dispatchReceiptKey struct{}

func withDispatchReceipt(ctx context.Context, id uuid.UUID) (context.Context, *dispatchReceipt) {
	receipt := &dispatchReceipt{id: id}
	return context.WithValue(ctx, dispatchReceiptKey{}, receipt), receipt
}

func dispatchReceiptFrom(ctx context.Context) *dispatchReceipt {
	receipt, _ := ctx.Value(dispatchReceiptKey{}).(*dispatchReceipt)
	return receipt
}

// markProviderDispatch is called at the last internal boundary before the
// provider adapter receives material. Route lookup and authorization failures
// happen before this point and therefore cannot produce accounting.
func markProviderDispatch(ctx context.Context) {
	if receipt := dispatchReceiptFrom(ctx); receipt != nil {
		receipt.dispatched.Store(true)
	}
}

func inheritedDispatchReceipt(parent, child context.Context) context.Context {
	if receipt := dispatchReceiptFrom(parent); receipt != nil {
		return context.WithValue(child, dispatchReceiptKey{}, receipt)
	}
	return child
}

func authorizedTx(ctx context.Context) pgx.Tx {
	if v, ok := ctx.Value(authorizedDispatchKey{}).(authorizedScope); ok {
		return v.tx
	}
	return nil
}

// dispatchAuthorized marks nested dispatches made from inside send. Those
// dispatches run under the same owning-module transaction and must not start a
// second account session (which would self-lock on the users row).
func (r *Router) dispatchAuthorized(ctx context.Context, c Call, send func(context.Context, pgx.Tx) error) error {
	if v, ok := ctx.Value(authorizedDispatchKey{}).(authorizedScope); ok {
		return send(ctx, v.tx)
	}
	if c.Authorize == nil {
		return send(ctx, nil)
	}
	sent := false
	err := c.Authorize(ctx, nil, func(sendCtx context.Context, tx pgx.Tx) error {
		sent = true
		sendCtx = inheritedDispatchReceipt(ctx, sendCtx)
		return send(context.WithValue(sendCtx, authorizedDispatchKey{}, authorizedScope{tx}), tx)
	})
	if err == nil && !sent {
		return errAuthorizationSkipped
	}
	return err
}

// Text is provisional for fragment events. For terminal events replace all fragments with Terminal.
type Event struct {
	Name, Text string
	Terminal   *Terminal
}
type Reply struct {
	Result   Result
	CallID   uuid.UUID
	Terminal *Terminal
}
type Terminal struct {
	Safety    bool   `json:"safety,omitempty"`
	Code      string `json:"code,omitempty"`
	Message   string `json:"message"`
	Retryable bool   `json:"retryable,omitempty"`
}

func (t Terminal) Name() string {
	if t.Safety {
		return "safety"
	}
	return t.Code
}

const HelpMessage = "听起来你现在可能正经历很难受的事。这里不适合继续练习，建议你马上联系专业的人：全国心理援助热线 12356；如果有人身危险，请立即拨打 110 或 120。"
const UnavailableMessage = "服务暂不可用，可重试"

var crisis = Terminal{Safety: true, Message: HelpMessage}
var unavailable = Terminal{Code: "moderation_unavailable", Message: UnavailableMessage, Retryable: true}
var errSink = errors.New("downstream unavailable")
var errAudit = errors.New("attempt accounting unavailable")
var errStopped = errors.New("generation stopped")
var errAuthorizationSkipped = errors.New("authorization skipped dispatch")

// Stop must idempotently cancel scoring and release/refund this operation on its original ledger day.
// A failed settlement is returned to the caller for durable retry, never converted to success.
type Stop func(context.Context, Scope, Terminal) error
type attemptRejected struct{ error }

func (e attemptRejected) Unwrap() error { return e.error }

type endpoint struct {
	id                      uuid.UUID
	inputPrice, outputPrice string
	includeUsage            bool
}
type plan struct {
	rev                        uuid.UUID
	primary, backup, moderator endpoint
}
type attemptStat struct {
	id      uuid.UUID
	model   endpoint
	start   time.Time
	elapsed time.Duration
	usage   Result
	outcome string
}
type Router struct {
	resolvePrompt        promptResolver
	load                 func(context.Context, Call) (plan, error)
	dispatch             func(context.Context, uuid.UUID, endpoint, Kind, Request) (Result, error)
	record               func(context.Context, Call, attemptStat) error
	recordTx             func(context.Context, pgx.Tx, Call, attemptStat) error
	stop                 Stop
	first, total, review time.Duration
	// routed is true only for the production closure that resolves an adapter
	// before calling it. Test and direct dispatch fixtures are already at the
	// external boundary, so invoking them is itself the dispatch proof.
	routed bool
}

func (r *Router) dispatchOnce(ctx context.Context, rev uuid.UUID, e endpoint, k Kind, req Request) (Result, error) {
	if !r.routed {
		markProviderDispatch(ctx)
	}
	return r.dispatch(ctx, rev, e, k, req)
}

func (r *Router) beforeAttempt(ctx context.Context, c Call) error {
	if c.BeforeAttempt == nil {
		return nil
	}
	if err := c.BeforeAttempt(ctx); err != nil {
		return attemptRejected{err}
	}
	return nil
}

func rejected(err error) error {
	var rejected attemptRejected
	if errors.As(err, &rejected) {
		return rejected.error
	}
	return nil
}

func (r *Router) Run(parent context.Context, c Call) (Reply, error) {
	if !c.Task.valid() || c.User == uuid.Nil || c.Operation == uuid.Nil || c.PromptVersion != uuid.Nil {
		return Reply{}, ErrRequest
	}
	if c.ProfileOwner != uuid.Nil && (c.Task != ProfileInference || c.Contact == uuid.Nil) {
		return Reply{}, ErrRequest
	}
	// Once a caller claims profile-owner accounting, it must also provide the
	// final authorization transaction. Legacy calls without the owner remain
	// distinguishable, but an integrated profile path fails closed if it omits
	// the dispatch fence.
	if c.Task == ProfileInference && c.ProfileOwner != uuid.Nil && c.Authorize == nil {
		return Reply{}, ErrConfig
	}
	if c.Generated != nil && (c.Generated.Task != c.Task || c.Generated.Raw == "" || c.Generated.CallID == uuid.Nil) {
		return Reply{}, ErrRequest
	}
	if (c.Mode != Text && c.Mode != Stream && c.Mode != JSONObject) || (c.Mode == Stream) != (c.Emit != nil) {
		return Reply{}, ErrRequest
	}
	for _, m := range c.Messages {
		if m.Role != "user" && m.Role != "assistant" || m.Content == "" {
			return Reply{}, ErrRequest
		}
	}
	ctx, cancel := context.WithTimeout(parent, r.total)
	defer cancel()
	p, err := r.load(ctx, c)
	if err != nil {
		return Reply{}, err
	}
	for modelIndex, model := range []endpoint{p.primary, p.backup} {
		if model.id == uuid.Nil {
			break
		}
		if ctx.Err() != nil {
			return Reply{}, ctx.Err()
		}
		attempt, err := r.prepare(ctx, c, model)
		if err != nil {
			return Reply{}, err
		}
		if err := guard(ctx, c.Guard); err != nil {
			return Reply{}, err
		}
		// A fallback starts another external round trip. Recheck mutable
		// authorization before sending the review to input moderation, then again
		// after an allow verdict and before generation.
		if modelIndex > 0 && c.BeforeGenerate != nil {
			if err := c.BeforeGenerate(ctx); err != nil {
				return Reply{}, err
			}
		}
		review := reviewer{r: r, c: attempt, p: p}
		input, _ := json.Marshal(attempt.Messages)
		if term, err := review.check(ctx, string(input)); term != nil {
			return r.finish(parent, c, *term, err)
		} else if err != nil {
			if rejection := rejected(err); rejection != nil {
				return Reply{}, rejection
			}
			return Reply{}, err
		}
		if err := guard(ctx, c.Guard); err != nil {
			return Reply{}, err
		}
		if c.BeforeGenerate != nil {
			if err := c.BeforeGenerate(ctx); err != nil {
				return Reply{}, err
			}
		}
		if c.Generated != nil {
			a := generation{review: &review, model: model}
			result, err := a.replay(ctx, c.Generated.Raw)
			if a.terminal != nil {
				return r.finish(parent, c, *a.terminal, errors.Join(a.reviewErr, err))
			}
			if rejection := rejected(err); rejection != nil {
				return Reply{}, rejection
			}
			if err != nil {
				return Reply{}, err
			}
			if ctx.Err() != nil {
				return Reply{}, ctx.Err()
			}
			return Reply{Result: result, CallID: c.Generated.CallID}, nil
		}
		id := uuid.New()
		a := generation{review: &review, model: model}
		result, err := a.run(ctx, id)
		if rejection := rejected(err); rejection != nil {
			return Reply{}, rejection
		}
		if a.terminal != nil {
			return r.finish(parent, c, *a.terminal, a.reviewErr)
		}
		if err == nil {
			if ctx.Err() != nil {
				return Reply{}, ctx.Err()
			}
			return Reply{Result: result, CallID: id}, nil
		}
		if a.sent || (!errors.Is(err, ErrProvider) && !errors.Is(err, ErrConfig) && !errors.Is(err, context.DeadlineExceeded)) || model.id == p.backup.id {
			return Reply{}, err
		}
		if p.backup.id == uuid.Nil {
			return Reply{}, err
		}
	}
	return Reply{}, ErrConfig
}
func outcome(err error, t *Terminal) string {
	switch {
	case t != nil:
		return t.Name()
	case err == nil:
		return "ok"
	case errors.Is(err, context.DeadlineExceeded):
		return "timeout"
	default:
		return "failed"
	}
}

// Never pass generated content to a telemetry sink, even an in-memory one.
func (r *Router) log(parent context.Context, c Call, s attemptStat) error {
	return r.logTx(parent, nil, c, s)
}

// logTx records a dispatched attempt in the authorization transaction that
// owns its provider call. The control context is deliberately detached from
// caller cancellation so a real provider cost survives request timeout after
// the adapter boundary was crossed.
func (r *Router) logTx(parent context.Context, tx pgx.Tx, c Call, s attemptStat) error {
	receipt := dispatchReceiptFrom(parent)
	if receipt == nil || receipt.id != s.id || !receipt.dispatched.Load() {
		return nil
	}
	// Project into explicitly allowed fields; future Call/Result fields stay private by default.
	c = Call{Scope: c.Scope, Task: c.Task, ProfileOwner: c.ProfileOwner}
	s.usage = Result{InputTokens: s.usage.InputTokens, OutputTokens: s.usage.OutputTokens, UsageKnown: s.usage.UsageKnown}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(parent), 2*time.Second)
	defer cancel()
	var err error
	if tx != nil {
		if r.recordTx == nil {
			return errAudit
		}
		err = r.recordTx(ctx, tx, c, s)
	} else {
		if r.record == nil {
			return errAudit
		}
		err = r.record(ctx, c, s)
	}
	if err != nil {
		return errAudit
	}
	return nil
}
func guard(ctx context.Context, check func(context.Context) error) error {
	if check == nil {
		return nil
	}
	return check(ctx)
}

func (r *Router) finish(parent context.Context, c Call, t Terminal, prior error) (Reply, error) {
	var sendErr error
	if c.Emit != nil {
		sendCtx, done := context.WithTimeout(parent, 2*time.Second)
		eventTerm := t
		err := c.Emit(sendCtx, Event{t.Name(), t.Message, &eventTerm})
		done()
		if err != nil {
			sendErr = errSink
		}
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(parent), 3*time.Second)
	defer cancel()
	settled := r.stop(ctx, c.Scope, t)
	return Reply{Terminal: &t}, errors.Join(prior, sendErr, settled)
}
