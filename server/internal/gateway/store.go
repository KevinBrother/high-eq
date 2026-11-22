package gateway

import (
	"context"
	"slices"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"high-eq/server/internal/privacy"
)

// NewRouter binds the privileged catalog to an account-guarded, task-only business port.
func (c *Catalog) NewRouter(data *privacy.Coordinator, stop Stop) (*Router, error) {
	if data == nil || stop == nil {
		return nil, ErrConfig
	}
	s := routingStore{data.Access}
	return &Router{resolvePrompt: databasePrompts(c.db), load: s.load, record: s.record, stop: stop, first: 10 * time.Second, total: 60 * time.Second, review: 10 * time.Second, dispatch: func(ctx context.Context, rev uuid.UUID, e endpoint, k Kind, r Request) (Result, error) {
		a, t, err := c.lookupAt(ctx, e.id, k, rev)
		if err != nil {
			return Result{}, err
		}
		r.includeUsage = e.includeUsage
		return a.chat(ctx, t, r)
	}}, nil
}

type routingStore struct {
	access func(context.Context, uuid.UUID, func(pgx.Tx) error) error
}
type approved struct {
	endpoint
	purpose, deletion string
	retention         int
	fields            []string
}

// Both sides already satisfy T09 domestic processing/storage and evidence constraints.
// A different contract can only receive the same purpose, no extra fields and no longer retention.
func (a approved) covers(b approved) bool {
	if a.id == uuid.Nil || b.id == uuid.Nil || a.purpose != b.purpose || a.deletion != b.deletion || b.retention > a.retention {
		return false
	}
	for _, f := range b.fields {
		if !slices.Contains(a.fields, f) {
			return false
		}
	}
	return true
}
func optional(id uuid.UUID) any {
	if id == uuid.Nil {
		return nil
	}
	return id
}
func (s routingStore) load(ctx context.Context, c Call) (p plan, err error) {
	err = s.access(ctx, c.User, func(tx pgx.Tx) error {
		var ok bool
		err := tx.QueryRow(ctx, `select
 ($2::uuid is null or exists(select from activities where id=$2 and user_id=$1)) and
 ($3::uuid is null or exists(select from contacts where id=$3 and user_id=$1)) and
 ($4::uuid is null or exists(select from prompt_versions where id=$4 and task=$5))`, c.User, optional(c.Activity), optional(c.Contact), optional(c.PromptVersion), c.Task).Scan(&ok)
		if err != nil || !ok {
			return ErrRequest
		}
		// One MVCC snapshot for route, evidence, tariff and revision. Each actual dispatch pins it.
		rows, err := tx.Query(ctx, `select v.version,r.canary_percent,slots.slot,m.id,m.input_cny_per_million::text,m.output_cny_per_million::text,a.purpose,a.deletion_method,a.max_retention_days,a.sent_fields
 from model_routes r cross join gateway_revision v
 cross join lateral (values ('primary',r.primary_model),('backup',r.fallback_model),('canary',r.canary_model),
   ('moderator',r.moderation_model)) slots(slot,id)
 join model_configs m on m.id=slots.id and m.enabled
   and m.input_cny_per_million is not null and m.output_cny_per_million is not null
 join provider_admissions a on a.ref=m.active_ref
 where r.task=$1 and m.kind=case when slots.slot='moderator' then 'moderation' else 'model' end`, c.Task)
		if err != nil {
			return ErrConfig
		}
		defer rows.Close()
		models := map[string]approved{}
		var pct int
		for rows.Next() {
			var a approved
			var slot string
			if err := rows.Scan(&p.rev, &pct, &slot, &a.id, &a.inputPrice, &a.outputPrice, &a.purpose, &a.deletion, &a.retention, &a.fields); err != nil {
				return ErrConfig
			}
			// Imported chat may only reach model / review endpoints with a <=24h retention agreement.
			if c.Task == ProfileInference && a.retention > 1 {
				continue
			}
			a.includeUsage = slices.Contains(a.fields, "stream_options.include_usage")
			models[slot] = a
		}
		if rows.Err() != nil {
			return ErrConfig
		}
		base := models["primary"]
		if base.id == uuid.Nil {
			return ErrConfig
		}
		pick := base
		if inCanary(c.User, pct) {
			candidate := models["canary"]
			if !base.covers(candidate) {
				return ErrConfig
			}
			pick = candidate
		}
		p.primary = pick.endpoint
		p.moderator = models["moderator"].endpoint
		backup := models["backup"]
		if pick.id != backup.id && pick.covers(backup) {
			p.backup = backup.endpoint
		}
		return nil
	})
	return p, err
}
func (s routingStore) record(ctx context.Context, c Call, a attemptStat) error {
	return s.access(ctx, c.User, func(tx pgx.Tx) error {
		var in, out any
		if a.usage.UsageKnown {
			in, out = a.usage.InputTokens, a.usage.OutputTokens
		}
		_, err := tx.Exec(ctx, `insert into ai_calls(id,operation_id,user_id,activity_id,contact_id,task,model_id,prompt_version_id,
   started_at,outcome,latency_ms,input_tokens,output_tokens,cost_cny)
 values($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,
   ($12::integer*$14::text::numeric+$13::integer*$15::text::numeric)/1000000)`, a.id, c.Operation, c.User, optional(c.Activity), optional(c.Contact), c.Task, a.model.id, optional(c.PromptVersion), a.start, a.outcome, a.elapsed.Milliseconds(), in, out, a.model.inputPrice, a.model.outputPrice)
		return err
	})
}

// LinkScoreTx runs inside the scorer's guarded score-insert transaction. No reason or value is copied.
func LinkScoreTx(ctx context.Context, tx pgx.Tx, user, call, activity, score uuid.UUID) error {
	tag, err := tx.Exec(ctx, `update ai_calls set score_id=$4 where id=$2 and user_id=$1 and activity_id=$3 and task='scoring' and outcome='ok' and (score_id is null or score_id=$4) and exists(select from model_configs m where m.id=ai_calls.model_id and m.kind='model')`, user, call, activity, score)
	if err != nil || tag.RowsAffected() != 1 {
		return ErrRequest
	}
	return nil
}
