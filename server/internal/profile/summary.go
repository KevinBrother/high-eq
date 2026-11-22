package profile

import (
	"cmp"
	"context"
	"slices"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/emotion"
	"high-eq/server/internal/membership"
)

// Group from live source links (including later scene edits); deletion or expiry cannot leave a cached count.
type Group struct {
	Contact   *uuid.UUID `json:"contact_id"`
	Scene     *string    `json:"scene"`
	Manual    int        `json:"manual_count"`
	Confirmed int        `json:"confirmed_self_count"`
}
type groupKey struct {
	contact uuid.UUID
	scene   string
}

func (s *Service) self(ctx context.Context, tx pgx.Tx, u uuid.UUID, visit func(*uuid.UUID, string)) error {
	rows, e := tx.Query(ctx, `select o.id,o.fact_enc,a.contact_id,se.id,se.event_enc,se.contact_id from profile_observations o left join activities a on a.id=o.activity_id left join signal_events se on se.id=o.event_id where o.user_id=$1 and o.applied and o.subject='self' and (o.event_id is null or se.occurred_at>now()-interval '4320 hours')`, u)
	if e != nil {
		return e
	}
	defer rows.Close()
	for rows.Next() {
		var id uuid.UUID
		var contact, event, linked *uuid.UUID
		var b, signal []byte
		if e = rows.Scan(&id, &b, &contact, &event, &signal, &linked); e != nil {
			return e
		}
		if event != nil {
			r, e := (emotion.Service{Fields: s.Fields}).DecodeFeedback(u, *event, signal)
			if e != nil {
				return e
			}
			if r.Id == *event && r.FeedbackID == id && same(r.ContactId, linked) && r.Positive() {
				sc := ""
				if r.Scene != nil {
					sc = *r.Scene
				}
				visit(linked, sc)
			}
			continue
		}
		var f fact
		if e = s.open("feedback", u, id, b, &f); e != nil {
			return e
		}
		if f.Positive {
			visit(contact, f.Scene)
		}
	}
	return rows.Err()
}
func (s *Service) Personal(ctx context.Context, tx pgx.Tx, u uuid.UUID) (string, error) {
	n := 0
	e := s.self(ctx, tx, u, func(*uuid.UUID, string) { n++ })
	if n == 0 {
		return "目前没有你明确认作本人波动的记录", e
	}
	return "已有你明确核对的记录，可以回顾当时的需要", e
}
func (s *Service) Groups(ctx context.Context, tx pgx.Tx, u uuid.UUID) ([]Group, error) {
	if e := s.Rights.Require(ctx, tx, u, membership.EmotionSummary); e != nil {
		return nil, e
	}
	m := map[groupKey]*Group{}
	get := func(c *uuid.UUID, sc string) *Group {
		k := groupKey{scene: sc}
		if c != nil {
			k.contact = *c
		}
		if m[k] == nil {
			g := &Group{Contact: c}
			if sc != "" {
				g.Scene = &sc
			}
			m[k] = g
		}
		return m[k]
	}
	if e := s.self(ctx, tx, u, func(c *uuid.UUID, sc string) { get(c, sc).Confirmed++ }); e != nil {
		return nil, e
	}
	rows, e := tx.Query(ctx, `select id,contact_id,mark_enc from manual_marks where user_id=$1 and accepted_at>now()-interval '4320 hours'`, u)
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	for rows.Next() {
		var id uuid.UUID
		var c *uuid.UUID
		var b []byte
		var mark app.Mark
		if e = rows.Scan(&id, &c, &b); e != nil {
			return nil, e
		}
		if e = s.open("mark", u, id, b, &mark); e != nil {
			return nil, e
		}
		sc := ""
		if mark.Scene != nil {
			sc = *mark.Scene
		}
		get(c, sc).Manual++
	}
	keys := make([]groupKey, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	slices.SortFunc(keys, func(a, b groupKey) int {
		if n := cmp.Compare(a.contact.String(), b.contact.String()); n != 0 {
			return n
		}
		return cmp.Compare(a.scene, b.scene)
	})
	out := make([]Group, 0, len(keys))
	for _, k := range keys {
		out = append(out, *m[k])
	}
	return out, rows.Err()
}
