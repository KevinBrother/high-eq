package marks

import (
	"context"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/api/app"
)

// accepted_at is unique within an account by the exclusion constraint. NULL
// limit streams the whole surviving export; neither tokens nor plaintext persist.
func (s Service) walk(ctx context.Context, tx pgx.Tx, u uuid.UUID, cut time.Time, before *time.Time, limit *int, visit func(time.Time, app.Mark) error) error {
	rows, e := tx.Query(ctx, `select id,contact_id,accepted_at,mark_enc from manual_marks where user_id=$1 and accepted_at>$2 and ($3::timestamptz is null or accepted_at<$3) order by accepted_at desc limit $4`, u, cut, before, limit)
	if e != nil {
		return e
	}
	defer rows.Close()
	for rows.Next() {
		var id uuid.UUID
		var contact *uuid.UUID
		var at time.Time
		var b []byte
		if e = rows.Scan(&id, &contact, &at, &b); e != nil {
			return e
		}
		m, e := s.decode(u, id, contact, b)
		if e != nil {
			return e
		}
		if e = visit(at, m); e != nil {
			return e
		}
	}
	return rows.Err()
}

func (s Service) List(ctx context.Context, tx pgx.Tx, u uuid.UUID, p app.ListMarksParams, now time.Time) (app.ListMarksResult, error) {
	out := app.ListMarksResult{Items: []app.Mark{}}
	n := 20
	if p.Limit != nil {
		n = *p.Limit
	}
	if n < 1 || n > 100 {
		return out, accounts.ErrInvalid
	}
	var before *time.Time
	if p.Cursor != nil {
		v, e := time.Parse(time.RFC3339Nano, *p.Cursor)
		if e != nil {
			return out, accounts.ErrInvalid
		}
		before = &v
	}
	fetch := n + 1
	var last string
	e := s.walk(ctx, tx, u, now.Add(-retention), before, &fetch, func(at time.Time, m app.Mark) error {
		if len(out.Items) == n {
			out.NextCursor = &last
		} else {
			out.Items = append(out.Items, m)
			last = at.UTC().Format(time.RFC3339Nano)
		}
		return nil
	})
	return out, e
}
