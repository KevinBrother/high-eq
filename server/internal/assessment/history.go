package assessment

import (
	"context"
	"encoding/base64"
	"encoding/binary"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/accounts"
)

type Page struct {
	Items []Result `json:"items"`
	Next  *string  `json:"next_cursor"`
}

// Keyset pagination survives deletion of the cursor row. All reads still filter by owner.
func cursor(v Result) string {
	b := binary.BigEndian.AppendUint64(nil, uint64(v.CompletedAt.UnixMicro()))
	return base64.RawURLEncoding.EncodeToString(append(b, v.ID[:]...))
}

func decodeCursor(v string) (time.Time, uuid.UUID, error) {
	var id uuid.UUID
	b, e := base64.RawURLEncoding.DecodeString(v)
	if e != nil || len(b) != 24 {
		return time.Time{}, id, ErrInvalid
	}
	at := time.UnixMicro(int64(binary.BigEndian.Uint64(b[:8]))).UTC()
	copy(id[:], b[8:])
	if at.Year() < 1 || at.Year() > 9999 || id == uuid.Nil {
		return time.Time{}, id, ErrInvalid
	}
	return at, id, nil
}

func (s *Service) History(ctx context.Context, p accounts.Principal, after *string, limit int) (Page, error) {
	page := Page{Items: []Result{}}
	if limit < 1 || limit > 100 {
		return Page{}, ErrInvalid
	}
	var at *time.Time
	var id uuid.UUID
	if after != nil {
		t, i, e := decodeCursor(*after)
		if e != nil {
			return Page{}, e
		}
		at = &t
		id = i
	}
	e := s.sessions.WithSession(ctx, p, false, func(tx pgx.Tx) error {
		rows, e := tx.Query(ctx, `select id,instrument_version,completed_at,scores_enc from assessments where user_id=$1 and ($2::timestamptz is null or (completed_at,id)<($2,$3::uuid)) order by completed_at desc,id desc limit $4`, p.User, at, id, limit+1)
		if e != nil {
			return e
		}
		defer rows.Close()
		for rows.Next() {
			if len(page.Items) == limit {
				v := cursor(page.Items[limit-1])
				page.Next = &v
				break
			}
			var r record
			var enc []byte
			var scores Scores
			if e = rows.Scan(&r.ID, &r.Version, &r.At, &enc); e != nil {
				return e
			}
			if e = r.open(s.fields, p.User, "scores_enc", enc, &scores); e != nil {
				return e
			}
			page.Items = append(page.Items, r.result(scores))
		}
		return rows.Err()
	})
	if e != nil {
		return Page{}, e
	}
	return page, nil
}
