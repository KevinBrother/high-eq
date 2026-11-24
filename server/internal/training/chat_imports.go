package training

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/privacy"
)

const chatImportRetention = 24 * time.Hour

// chatImportExport deliberately omits original_enc. The historical rows have no
// confirmed decryption/AAD contract, so exporting bytes would either leak an
// opaque envelope or fabricate readable source text.
type chatImportExport struct {
	ActivityID         uuid.UUID `json:"activity_id"`
	ReceivedAt         time.Time `json:"received_at"`
	ContentUnavailable bool      `json:"content_unavailable"`
}

// ChatImportHooks exposes live import metadata as its own archive module.
// Session rows stay in training.json; the two contracts must not be mixed.
func ChatImportHooks() privacy.Module {
	return privacy.Module{
		Name: "chat_imports",
		// The owning activity/account cascades the import row. This explicit
		// no-op keeps the inventory complete without deleting an unrelated
		// source from the session module.
		Delete: func(context.Context, pgx.Tx, privacy.Deletion) error { return nil },
		Export: func(ctx context.Context, tx pgx.Tx, q privacy.ExportRequest, emit privacy.Emit) error {
			return exportChatImports(ctx, tx, q.UserID, time.Now(), emit)
		},
	}
}

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

func exportChatImports(ctx context.Context, tx pgx.Tx, user uuid.UUID, now time.Time, emit privacy.Emit) error {
	if tx == nil || emit == nil || user == uuid.Nil {
		return errors.New("invalid chat import export")
	}
	rows, err := tx.Query(ctx, `select a.id,c.received_at
from chat_imports c join activities a on a.id=c.activity_id
where a.user_id=$1 and c.received_at>$2
order by c.received_at,a.id`, user, now.Add(-chatImportRetention))
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		record := chatImportExport{ContentUnavailable: true}
		if err := rows.Scan(&record.ActivityID, &record.ReceivedAt); err != nil {
			return err
		}
		if err := emit(record); err != nil {
			return err
		}
	}
	return rows.Err()
}
