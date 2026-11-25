package training

import (
	"context"
	"errors"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/fieldcrypt"
	"high-eq/server/internal/privacy"
)

type exportSetup struct {
	Level    *uuid.UUID `json:"level_id,omitempty"`
	Contact  *uuid.UUID `json:"contact_id,omitempty"`
	Scene    *string    `json:"scene,omitempty"`
	Scenario *string    `json:"scenario,omitempty"`
	Previous *uuid.UUID `json:"previous_id,omitempty"`
}

type exportMessage struct {
	ID   uuid.UUID `json:"id"`
	Role string    `json:"role"`
	Seq  int       `json:"seq"`
	Text string    `json:"text"`
}

func Hooks(f *fieldcrypt.Cipher) privacy.Module {
	s := Service{Fields: f}
	return privacy.Module{Name: "training", Delete: func(ctx context.Context, tx pgx.Tx, d privacy.Deletion) error {
		switch d.Scope {
		case "account", "contacts", "sessions":
		default:
			return nil
		}
		var remains bool
		e := tx.QueryRow(ctx, `select exists(select from activities a join practice_work w on w.activity_id=a.id where a.user_id=$1 and ($2='account' or ($2='contacts' and a.contact_id=$3) or ($2='sessions' and a.source_id=$3)))`, d.UserID, d.Scope, d.SourceID).Scan(&remains)
		if e == nil && remains {
			return errors.New("practice source remains")
		}
		return e
	}, Export: func(ctx context.Context, tx pgx.Tx, q privacy.ExportRequest, emit privacy.Emit) error {
		var after uuid.UUID
		for {
			rows, e := tx.Query(ctx, `select id from activities join practice_work on activity_id=id where user_id=$1 and id>$2 order by id limit 50`, q.UserID, after)
			if e != nil {
				return e
			}
			ids, e := pgx.CollectRows(rows, pgx.RowTo[uuid.UUID])
			if e != nil {
				return e
			}
			for _, id := range ids {
				r, e := s.load(ctx, tx, q.UserID, id)
				if e != nil {
					return e
				}
				detail, e := s.publicDetail(ctx, tx, q.UserID, r)
				if e != nil {
					return e
				}
				setup := detail.Setup
				messages := make([]exportMessage, 0, len(r.Messages))
				for _, m := range r.Messages {
					messages = append(messages, exportMessage{ID: m.Id, Role: string(m.Role), Seq: m.Seq, Text: m.Text})
				}
				if e = emit(struct {
					SessionSummary
					Setup    exportSetup     `json:"setup"`
					Messages []exportMessage `json:"messages"`
					Source   uuid.UUID       `json:"source_id"`
				}{
					SessionSummary: detail.SessionSummary,
					Setup: exportSetup{Level: setup.Level, Contact: setup.Contact, Scene: setup.Scene,
						Scenario: setup.Scenario, Previous: setup.Previous},
					Messages: messages,
					Source:   r.source,
				}); e != nil {
					return e
				}
				after = id
			}
			if len(ids) < 50 {
				return nil
			}
		}
	}}
}
