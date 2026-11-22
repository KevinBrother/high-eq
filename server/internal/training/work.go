package training

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/gateway"
	"high-eq/server/internal/membership"
	"high-eq/server/internal/scoring"
)

// Worker != client key != quota token. The first fences late model callbacks,
// the second deduplicates the turn, the third belongs exclusively to T06.
type job struct {
	record
	user, run, token uuid.UUID
	op               string
	key              uuid.UUID
	profile          string
	held             bool
	stopped          string
}

func (j job) scope() gateway.Scope {
	v := gateway.Scope{User: j.user, Activity: j.ID, Operation: j.source}
	if j.op == "message" {
		v.Operation = j.key
	}
	if j.input.Contact != nil {
		v.Contact = *j.input.Contact
	}
	return v
}
func (s *Service) check(ctx context.Context, tx pgx.Tx, j job) error {
	var ok bool
	e := tx.QueryRow(ctx, `select exists(select from practice_work w join activities a on a.id=w.activity_id where activity_id=$1 and user_id=$2 and worker=$3 and valid_until>clock_timestamp())`, j.ID, j.user, j.run).Scan(&ok)
	if e == nil && !ok {
		return membership.ErrConflict
	}
	return e
}
func (s *Service) add(ctx context.Context, tx pgx.Tx, j job, m app.Message) error {
	b, e := s.seal(j.user, m.Id, "message", m.Text)
	if e != nil {
		return e
	}
	_, e = tx.Exec(ctx, `insert into practice_messages(id,activity_id,kind,client_message_id,seq,role,content_enc)values($1,$2,$3,$4,$5,$6,$7)`, m.Id, j.ID, j.kind, m.ClientMessageId, m.Seq, m.Role, b)
	return e
}

type Frame struct {
	Name string
	Data any
}
type Emit func(Frame) error
type saved struct {
	Client     uuid.UUID  `json:"client_message_id"`
	Message    uuid.UUID  `json:"message_id"`
	Settlement Settlement `json:"settlement"`
}

func keyData(k uuid.UUID) map[string]any { return map[string]any{"client_message_id": k} }
func terminal(state string) *gateway.Terminal {
	switch state {
	case "safety":
		return &gateway.Terminal{Safety: true, Message: gateway.HelpMessage}
	case "moderation_unavailable":
		return &gateway.Terminal{Code: state, Message: gateway.UnavailableMessage, Retryable: true}
	}
	return nil
}
func (s *Service) claim(ctx context.Context, p accounts.Principal, id, key uuid.UUID, op, text string) (j job, replay *Frame, e error) {
	if op == "message" && (key == uuid.Nil || strings.TrimSpace(text) == "") {
		return j, nil, accounts.ErrInvalid
	}
	cappedAtClaim := false
	e = s.Accounts.WithSession(ctx, p, false, func(tx pgx.Tx) error {
		r, e := s.load(ctx, tx, p.User, id)
		if e != nil {
			return e
		}
		j = job{record: r, user: p.User, key: key, op: op}
		same := r.action == op && (op == "finish" || r.client != nil && *r.client == key)
		existing := false
		if op == "message" {
			for _, m := range r.Messages {
				if m.ClientMessageId != key {
					continue
				}
				if m.Role == "user" {
					if m.Text != text {
						return membership.ErrConflict
					}
					existing = true
				} else {
					replay = &Frame{"reply_saved", saved{key, m.Id, r.Settlement}}
				}
			}
		}
		recovery := ""
		if r.settlementPending {
			recovery = r.settlementOutcome
		} else if r.worker != nil {
			if _, ok := terminalOutcome(r.Status); ok {
				recovery = r.Status
			}
		}
		if recovery != "" {
			switch recovery {
			case "safety":
				replay = &Frame{"safety", terminal(recovery)}
				return nil
			case "moderation_unavailable":
				if r.quota == nil || r.worker == nil {
					return membership.ErrConflict
				}
				j.token = *r.quota
				j.run = *r.worker
				// Keep a failed compensation from aborting the claim transaction. A
				// retry of the same key must still return the durable terminal frame
				// while the original worker remains fenced for maintenance retry.
				if e := s.settlePendingTxIsolated(ctx, tx, j); e != nil {
					if same {
						replay = &Frame{"moderation_unavailable", terminal(recovery)}
						return nil
					}
					return e
				}
				// The terminal intent is now durable and settled. Reload so an
				// explicit retry of the original operation can proceed.
				if r, e = s.load(ctx, tx, p.User, id); e != nil {
					return e
				}
				j.record = r
			case "failed":
				return ErrGeneration
			default:
				return membership.ErrConflict
			}
		}
		if r.Status == "safety" {
			replay = &Frame{"safety", terminal(r.Status)}
			return nil
		}
		if replay != nil || op == "finish" && r.Result != nil {
			return nil
		}
		if r.live {
			if same && op == "message" {
				replay = &Frame{"in_progress", keyData(key)}
				return nil
			}
			return membership.ErrConflict
		}
		if r.worker != nil && !same {
			return membership.ErrConflict
		}
		if r.Status != "active" && r.Status != "pending" && !(r.Status == "moderation_unavailable" && same) && !(r.Status == "capped" && op == "finish") {
			return membership.ErrConflict
		}
		if e = s.allowed(ctx, tx, p.User, r.input); e != nil {
			return e
		}
		if r.input.Contact != nil {
			if s.Summary == nil {
				j.profile = "仅供参考：按场景回应，不推测对方的性格。"
			} else {
				v, e := s.Summary(ctx, tx, p.User, *r.input.Contact)
				if e != nil {
					return e
				}
				j.profile = v.Summary
			}
		}
		if op == "finish" {
			if len(r.Messages) == 0 || r.Messages[len(r.Messages)-1].Role != "assistant" {
				return membership.ErrConflict
			}
		} else if !existing && !fits(len(r.Messages)/2, r.tokens, len(text)) {
			if r.quota != nil {
				j.token = *r.quota
			}
			if e := s.capTx(ctx, tx, j); e != nil {
				return e
			}
			cappedAtClaim = true
			return nil
		}
		if r.Status == "capped" && op == "finish" {
			// The prior complete turn already owns the accepted quota attempt.
			// Scoring must not begin a new attempt or charge the activity again.
			if r.quota == nil {
				return membership.ErrConflict
			}
			j.token = *r.quota
			j.run = uuid.New()
			_, e = tx.Exec(ctx, `update practice_work set worker=$2,valid_until=clock_timestamp()+interval '95 seconds',action=$3,client_id=$4 where activity_id=$1`, id, j.run, op, key)
			return e
		}
		var a membership.Attempt
		if r.Status == "moderation_unavailable" {
			if r.quota == nil {
				return membership.ErrConflict
			}
			a, e = s.Rights.Retry(ctx, tx, p.User, id, *r.quota)
		} else {
			a, e = s.Rights.Begin(ctx, tx, p.User, id)
		}
		if e != nil {
			return e
		}
		if a.State != "held" && a.State != "accepted" {
			return membership.ErrConflict
		}
		if a.State == "held" && !a.Work { // The original T06 lease still owns the first save.
			if op == "message" && same {
				replay = &Frame{"in_progress", keyData(key)}
				return nil
			}
			return membership.ErrConflict
		}
		j.held = a.State == "held"
		j.token = a.Token
		j.run = uuid.New()
		_, e = tx.Exec(ctx, `update practice_work set worker=$2,valid_until=clock_timestamp()+interval '95 seconds',action=$3,client_id=$4 where activity_id=$1`, id, j.run, op, key)
		if e != nil {
			return e
		}
		if op == "message" && !existing {
			m := app.Message{Id: uuid.New(), ClientMessageId: key, Role: "user", Seq: len(r.Messages) + 1, Text: text}
			if e = s.add(ctx, tx, j, m); e != nil {
				return e
			}
			j.Messages = append(j.Messages, m)
		}
		if r.Status == "moderation_unavailable" {
			_, e = tx.Exec(ctx, `update activities set state='active' where id=$1`, id)
		}
		return e
	})
	if e == nil && cappedAtClaim {
		e = ErrCap
	}
	return
}
func (s *Service) endTx(ctx context.Context, tx pgx.Tx, j job, state membership.Outcome) error {
	if j.token != uuid.Nil {
		if e := s.Rights.Finish(ctx, tx, j.user, j.ID, j.token, state); e != nil {
			return e
		}
	}
	if _, e := tx.Exec(ctx, `update activities set state=$2 where id=$1`, j.ID, state); e != nil {
		return e
	}
	_, e := tx.Exec(ctx, `update practice_work set worker=null,valid_until=null,settlement_pending=false where activity_id=$1`, j.ID)
	return e
}

func terminalOutcome(state string) (membership.Outcome, bool) {
	switch state {
	case string(membership.Safety), string(membership.ModerationUnavailable), string(membership.Failed):
		return membership.Outcome(state), true
	default:
		return "", false
	}
}

// persistSettlement commits the intent in its own transaction before any
// refund/state update. A failed endTx therefore leaves a durable retry point.
func (s *Service) persistSettlement(ctx context.Context, j job, state membership.Outcome) error {
	if _, ok := terminalOutcome(string(state)); !ok {
		return membership.ErrConflict
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	return s.Data.Access(ctx, j.user, func(tx pgx.Tx) error {
		if e := s.check(ctx, tx, j); e != nil {
			r, loadErr := s.load(ctx, tx, j.user, j.ID)
			if loadErr == nil && (r.Status == string(state) || r.settlementPending && r.settlementOutcome == string(state)) {
				return nil
			}
			return e
		}
		tag, e := tx.Exec(ctx, `update practice_work set settlement_pending=true,settlement_outcome=$2
            where activity_id=$1 and worker=$3 and valid_until>clock_timestamp()`, j.ID, state, j.run)
		if e != nil {
			return e
		}
		if tag.RowsAffected() == 1 {
			return nil
		}
		r, loadErr := s.load(ctx, tx, j.user, j.ID)
		if loadErr == nil && (r.Status == string(state) || r.settlementPending && r.settlementOutcome == string(state)) {
			return nil
		}
		return membership.ErrConflict
	})
}

// If the dedicated settlement intent cannot be written, persist the terminal
// state itself while retaining the worker as a recovery marker. This is the
// fail-closed path for the same transient update failure that blocks intent.
func (s *Service) persistTerminalState(ctx context.Context, j job, state membership.Outcome) error {
	if _, ok := terminalOutcome(string(state)); !ok {
		return membership.ErrConflict
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	return s.Data.Access(ctx, j.user, func(tx pgx.Tx) error {
		if e := s.check(ctx, tx, j); e != nil {
			r, loadErr := s.load(ctx, tx, j.user, j.ID)
			if loadErr == nil && r.Status == string(state) {
				return nil
			}
			return e
		}
		_, e := tx.Exec(ctx, `update activities set state=$2 where id=$1`, j.ID, state)
		return e
	})
}

func (s *Service) settlePendingTx(ctx context.Context, tx pgx.Tx, j job) error {
	var pending bool
	var outcome string
	var activityState string
	var worker *uuid.UUID
	e := tx.QueryRow(ctx, `select w.settlement_pending,coalesce(w.settlement_outcome,''),a.state,w.worker
        from practice_work w join activities a on a.id=w.activity_id where w.activity_id=$1 for update of w`, j.ID).Scan(&pending, &outcome, &activityState, &worker)
	if e != nil {
		return e
	}
	if !pending {
		if _, ok := terminalOutcome(activityState); !ok {
			return membership.ErrConflict
		}
		outcome = activityState
	}
	if worker == nil {
		if !pending {
			return nil
		}
		return membership.ErrConflict
	}
	if j.run == uuid.Nil || *worker != j.run {
		return membership.ErrConflict
	}
	state, ok := terminalOutcome(outcome)
	if !ok {
		return membership.ErrConflict
	}
	if j.token == uuid.Nil && j.quota != nil {
		j.token = *j.quota
	}
	return s.endTx(ctx, tx, j, state)
}

// settlePendingTxIsolated runs a compensation attempt behind a savepoint so a
// transient trigger/storage failure cannot poison the surrounding claim
// transaction. The savepoint is released only after the settlement succeeds.
func (s *Service) settlePendingTxIsolated(ctx context.Context, tx pgx.Tx, j job) error {
	nested, e := tx.Begin(ctx)
	if e != nil {
		return e
	}
	if e = s.settlePendingTx(ctx, nested, j); e != nil {
		if rollbackErr := nested.Rollback(ctx); rollbackErr != nil {
			return errors.Join(e, rollbackErr)
		}
		return e
	}
	return nested.Commit(ctx)
}

func (s *Service) settlePending(ctx context.Context, user, id, token, worker uuid.UUID) error {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	return s.Data.Access(ctx, user, func(tx pgx.Tx) error {
		r, e := s.load(ctx, tx, user, id)
		if e != nil {
			return e
		}
		j := job{record: r, user: user, token: token, run: worker}
		return s.settlePendingTx(ctx, tx, j)
	})
}

func (s *Service) stop(ctx context.Context, j job, state membership.Outcome) error {
	if _, ok := terminalOutcome(string(state)); !ok {
		return membership.ErrConflict
	}
	if e := s.persistSettlement(ctx, j, state); e != nil {
		if fallbackErr := s.persistTerminalState(ctx, j, state); fallbackErr != nil {
			return errors.Join(e, fallbackErr)
		}
	}
	if e := s.settlePending(ctx, j.user, j.ID, j.token, j.run); e != nil {
		return errors.Join(errSettlementPending, e)
	}
	return nil
}

func (s *Service) Exit(ctx context.Context, p accounts.Principal, id uuid.UUID) (out Settlement, e error) {
	e = s.Accounts.WithSession(ctx, p, false, func(tx pgx.Tx) error {
		r, e := s.load(ctx, tx, p.User, id)
		if e != nil {
			return e
		}
		out = r.Settlement
		if r.Status == "exited" {
			return nil
		}
		if r.settlementPending || r.Status != "pending" && r.Status != "active" {
			return membership.ErrConflict
		}
		j := job{record: r, user: p.User}
		if r.quota != nil {
			j.token = *r.quota
		}
		return s.endTx(ctx, tx, j, membership.Exited)
	})
	return
}

type guardedRunner struct {
	scoring.Runner
	guard func(context.Context) error
}

func (r guardedRunner) Run(ctx context.Context, c gateway.Call) (gateway.Reply, error) {
	c.Guard = r.guard
	return r.Runner.Run(ctx, c)
}

func (s *Service) runner(p accounts.Principal, j *job) (scoring.Runner, error) {
	r, e := s.Router(func(ctx context.Context, scope gateway.Scope, t gateway.Terminal) error {
		if scope.Operation != j.scope().Operation || scope.Activity != j.ID || scope.User != j.user {
			return membership.ErrConflict
		}
		return s.settleTerminal(ctx, j, t)
	})
	if e != nil {
		return nil, e
	}
	return guardedRunner{Runner: r, guard: func(ctx context.Context) error {
		return s.Accounts.WithSession(ctx, p, false, func(tx pgx.Tx) error {
			if e := s.check(ctx, tx, *j); e != nil {
				return e
			}
			return s.allowed(ctx, tx, j.user, j.input)
		})
	}}, nil
}

// T10 calls Stop before returning; T12 can also surface its own safety object.
// Retry a failed callback but do not race an explicit client retry after success.
func (s *Service) settleTerminal(ctx context.Context, j *job, t gateway.Terminal) error {
	if j.stopped == t.Name() {
		return nil
	}
	e := s.stop(ctx, *j, membership.Outcome(t.Name()))
	if e == nil {
		j.stopped = t.Name()
	}
	return e
}

func (s *Service) capped(ctx context.Context, j *job) error {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	e := s.Data.Access(ctx, j.user, func(tx pgx.Tx) error {
		if e := s.check(ctx, tx, *j); e != nil {
			r, loadErr := s.load(ctx, tx, j.user, j.ID)
			if loadErr == nil && r.Status == "capped" {
				return nil
			}
			return e
		}
		return s.capTx(ctx, tx, *j)
	})
	if e != nil {
		return errors.Join(ErrCap, e)
	}
	return ErrCap
}

// capTx closes an incomplete turn after the budget is exhausted. A prior
// complete assistant turn keeps its accepted quota attempt for scoring; a
// session without one is refunded immediately. Callers commit this transaction
// before returning ErrCap.
func (s *Service) capTx(ctx context.Context, tx pgx.Tx, j job) error {
	// Drop the unapproved turn, including any earlier orphaned user messages
	// after the last complete assistant reply.
	if _, e := tx.Exec(ctx, `delete from practice_messages
        where activity_id=$1 and seq > coalesce((select max(seq) from practice_messages
            where activity_id=$1 and role='assistant'),0)`, j.ID); e != nil {
		return e
	}
	var complete bool
	if e := tx.QueryRow(ctx, `select exists(select from practice_messages where activity_id=$1 and role='assistant')`, j.ID).Scan(&complete); e != nil {
		return e
	}
	if j.token != uuid.Nil && !complete {
		if e := s.Rights.Finish(ctx, tx, j.user, j.ID, j.token, membership.Failed); e != nil {
			return e
		}
	}
	if _, e := tx.Exec(ctx, `update activities set state='capped' where id=$1`, j.ID); e != nil {
		return e
	}
	_, e := tx.Exec(ctx, `update practice_work set worker=null,valid_until=null,settlement_pending=false,settlement_outcome=null where activity_id=$1`, j.ID)
	return e
}

func (s *Service) failed(ctx context.Context, j job, cause error) error {
	return errors.Join(cause, s.stop(ctx, j, membership.Failed))
}
