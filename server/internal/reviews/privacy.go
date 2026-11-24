package reviews

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/fieldcrypt"
	"high-eq/server/internal/privacy"
)

// Root deletion precedes module hooks. A retained daily aggregate is not a
// journal record; all source rows, quota attempts, outbox and logs must cascade.
func verifyErased(ctx context.Context, tx pgx.Tx, d privacy.Deletion) error {
	if d.Scope != "reviews" && d.Scope != "contacts" && d.Scope != "account" {
		return nil
	}
	var remains bool
	e := tx.QueryRow(ctx, `select exists(select from review_requests r join activities a on a.id=r.activity_id where a.user_id=$1 and ($2='account' or ($2='reviews' and a.source_id=$3) or ($2='contacts' and a.contact_id=$3)))`, d.UserID, d.Scope, d.SourceID).Scan(&remains)
	if e == nil && remains {
		return errors.New("review erasure incomplete")
	}
	return e
}
func Hooks(f *fieldcrypt.Cipher) privacy.Module {
	s := Service{Fields: f}
	return privacy.Module{Name: "reviews", Delete: verifyErased, Export: s.export}
}

type exportResult struct {
	ID           uuid.UUID       `json:"id"`
	RepairPhrase string          `json:"repair_phrase"`
	Score        app.FullScore   `json:"score"`
	Submitted    exportSubmitted `json:"submitted"`
}

// The ZIP keeps the journal and its links without the request used for replay.
type exportSubmitted struct {
	ContactID            *uuid.UUID            `json:"contact_id,omitempty"`
	Happened             string                `json:"happened"`
	MarkID               *uuid.UUID            `json:"mark_id,omitempty"`
	MyAction             string                `json:"my_action"`
	MyFeeling            string                `json:"my_feeling"`
	NextAction           string                `json:"next_action"`
	OccurredAt           *time.Time            `json:"occurred_at,omitempty"`
	Scene                *app.ReviewInputScene `json:"scene,omitempty"`
	SignalEventID        *uuid.UUID            `json:"signal_event_id,omitempty"`
	TheirPossibleFeeling string                `json:"their_possible_feeling"`
}

func (s *Service) export(ctx context.Context, tx pgx.Tx, q privacy.ExportRequest, emit privacy.Emit) error {
	rows, e := tx.Query(ctx, `select a.id,a.source_id,a.created_at,r.mark_id,r.signal_event_id,a.content_enc,s.detail_enc,a.state,a.contact_id,r.repair_enc,s.occurred_at from review_requests r join activities a on a.id=r.activity_id left join scores s on s.activity_id=a.id where a.user_id=$1 order by a.created_at,a.id`, q.UserID)
	if e != nil {
		return e
	}
	defer rows.Close()
	for rows.Next() {
		var r stored
		var scored *time.Time
		var state string
		var partial []byte
		var contact *uuid.UUID
		if e = rows.Scan(&r.id, &r.source, &r.at, &r.mark, &r.signal, &r.enc, &r.detail, &state, &contact, &partial, &scored); e != nil {
			return e
		}
		record := map[string]any{"id": r.id, "source_id": r.source, "created_at": r.at, "state": state, "scored_at": scored, "contact_id": contact, "mark_id": r.mark, "signal_event_id": r.signal}
		if partial != nil {
			b, e := s.Fields.Open(partial, aad(q.UserID, r.id, "repair"))
			if e != nil {
				return e
			}
			record["approved_repair_draft"] = string(b)
		}
		if state == "complete" {
			v, e := s.decode(q.UserID, r)
			if e != nil {
				return e
			}
			in := v.Submitted
			record["result"] = exportResult{
				ID: v.Id, RepairPhrase: v.RepairPhrase, Score: v.Score,
				Submitted: exportSubmitted{
					ContactID: in.ContactId, Happened: in.Happened, MarkID: in.MarkId,
					MyAction: in.MyAction, MyFeeling: in.MyFeeling, NextAction: in.NextAction,
					OccurredAt: in.OccurredAt, Scene: in.Scene, SignalEventID: in.SignalEventId,
					TheirPossibleFeeling: in.TheirPossibleFeeling,
				},
			}
		}
		if e = emit(record); e != nil {
			return e
		}
	}
	return rows.Err()
}
