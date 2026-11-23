package training

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

const chatImportRetention = 24 * time.Hour

// PurgeChatImports deletes only the imported source row. Its activity remains as
// the existing idempotency root, so an old request does not become a new write.
func (s *Service) PurgeChatImports(ctx context.Context, now time.Time) error {
	if s == nil || s.DB == nil {
		return errors.New("chat import cleanup unavailable")
	}
	attempt, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	return pgx.BeginFunc(attempt, s.DB, func(tx pgx.Tx) error {
		// Bound the server-side DELETE as well, so a lock wait ends even if
		// the client disconnects before PostgreSQL notices.
		if _, err := tx.Exec(attempt, `set local statement_timeout = '5s'`); err != nil {
			return err
		}
		_, err := tx.Exec(attempt, `delete from chat_imports where received_at <= $1`, now.Add(-chatImportRetention))
		return err
	})
}
