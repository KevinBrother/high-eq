package profile

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/privacy"
)

func (s *Service) Hooks() privacy.Module {
	return privacy.Module{Name: "profiles", Export: s.export, Delete: func(ctx context.Context, tx pgx.Tx, d privacy.Deletion) error {
		// Sources and FK-backed votes have already cascaded. No materialized confidence or group cache.
		if d.Scope != "account" && d.Scope != "contacts" {
			return nil
		}
		var remains bool
		e := tx.QueryRow(ctx, `select exists(select from contacts where user_id=$1 and ($2 or id=$3)) or ($2 and exists(select from profile_observations where user_id=$1))`, d.UserID, d.Scope == "account", d.SourceID).Scan(&remains)
		if e == nil && remains {
			return errors.New("profile erasure incomplete")
		}
		return e
	}}
}
func (s *Service) export(ctx context.Context, tx pgx.Tx, q privacy.ExportRequest, emit privacy.Emit) error {
	u := q.UserID
	rows, e := tx.Query(ctx, `select id from contacts where user_id=$1 order by id`, u)
	if e != nil {
		return e
	}
	ids, e := pgx.CollectRows(rows, pgx.RowTo[uuid.UUID])
	if e != nil {
		return e
	}
	for _, id := range ids {
		d, e := s.read(ctx, tx, u, id)
		if e != nil {
			return e
		}
		v, e := s.votes(ctx, tx, u, id)
		if e != nil {
			return e
		}
		if e = emit(map[string]any{"contact_id": id, "nickname": d.Nickname, "scene": d.Scene, "question_choices": d.Answers, "material_choices": d.Material, "profile": d.render(v)}); e != nil {
			return e
		}
	}
	rows, e = tx.Query(ctx, `select o.id, coalesce(a.source_id,o.event_id),o.subject,o.fact_enc,o.applied,o.occurred_at from profile_observations o left join activities a on a.id=o.activity_id left join signal_events se on se.id=o.event_id where o.user_id=$1 and (o.event_id is null or se.occurred_at>now()-interval '4320 hours') order by o.id`, u)
	if e != nil {
		return e
	}
	defer rows.Close()
	for rows.Next() {
		var id, src uuid.UUID
		var subject string
		var b []byte
		var applied bool
		var at time.Time
		if e = rows.Scan(&id, &src, &subject, &b, &applied, &at); e != nil {
			return e
		}
		var f fact
		if e = s.open("feedback", u, id, b, &f); e != nil {
			return e
		}
		if e = emit(map[string]any{"feedback_id": id, "source_id": src, "subject": subject, "fact": f, "applied": applied, "occurred_at": at}); e != nil {
			return e
		}
	}
	return rows.Err()
}
