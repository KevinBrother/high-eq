package membership

import (
	"context"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// RequireContact authorizes creation (nil) or writing an existing contact. Reads of history are not writes.
func (s *Service) RequireContact(ctx context.Context, tx pgx.Tx, user uuid.UUID, id *uuid.UUID) error {
	a, e := s.access(ctx, tx, user)
	if e != nil {
		return e
	}
	var ok bool
	if id == nil {
		if a.Contacts == nil {
			return nil
		}
		e = tx.QueryRow(ctx, `select count(*)<$2 from contacts where user_id=$1`, user, *a.Contacts).Scan(&ok)
	} else {
		e = tx.QueryRow(ctx, `select exists(select from (select id from contacts where user_id=$1 order by last_used_at desc nulls last,id limit $2) active where id=$3)`, user, a.Contacts, *id).Scan(&ok)
	}
	if e == nil && !ok {
		return ErrForbidden
	}
	return e
}

// SelectContact is an explicit user choice; mere reads must not change last_used_at.
func (s *Service) SelectContact(ctx context.Context, tx pgx.Tx, user, id uuid.UUID) error {
	tag, e := tx.Exec(ctx, `update contacts set last_used_at=clock_timestamp() where user_id=$1 and id=$2`, user, id)
	if e == nil && tag.RowsAffected() != 1 {
		return ErrForbidden
	}
	return e
}
