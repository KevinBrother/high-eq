package accounts

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/api/app"
)

const (
	ContactNoticeVersion   = "2026-11"
	ReplyChatImportPurpose = "reply_chat_import"
	ReplyChatImportVersion = "2026-11-reply"
)

var purposes = map[string]bool{"terms": true, "privacy": true, "assessment": true, "health": true, "voice": true, "audio_retention": true, "practice": true, "review": true, "contacts": true, "chat_import": true, ReplyChatImportPurpose: true, "manual_mark": true}

// Granted is a transaction-scoped check for modules that collect data. Use the
// same authorized transaction for the subsequent write to serialize withdrawal.
func Granted(ctx context.Context, tx pgx.Tx, user uuid.UUID, purpose string) (bool, error) {
	if !purposes[purpose] {
		return false, ErrInvalid
	}
	var ok bool
	e := tx.QueryRow(ctx, "select exists(select from consents where user_id=$1 and purpose=$2 and withdrawn_at is null)", user, purpose).Scan(&ok)
	return ok, e
}
func validateConsentRequest(purpose, version string, grant bool) error {
	if !purposes[purpose] || !validText(version, 100) {
		return ErrInvalid
	}
	if grant && (purpose == "privacy" || purpose == "terms") && version != PolicyVersion {
		return ErrInvalid
	}
	if purpose == ReplyChatImportPurpose && version != ReplyChatImportVersion {
		return ErrInvalid
	}
	return nil
}

func (s *Service) Consent(ctx context.Context, p Principal, purpose, version string, grant bool) (app.Consent, error) {
	var out app.Consent
	if err := validateConsentRequest(purpose, version, grant); err != nil {
		return out, err
	}
	out.Purpose = app.ConsentPurpose(purpose)
	out.Version = version
	out.Granted = grant
	e := s.WithSession(ctx, p, false, func(tx pgx.Tx) error {
		var id uuid.UUID
		var old string
		var active bool
		e := tx.QueryRow(ctx, `select id,version,withdrawn_at is null,coalesce(withdrawn_at,granted_at) from consents where user_id=$1 and purpose=$2 order by (withdrawn_at is null) desc,granted_at desc,id desc limit 1`, p.User, purpose).Scan(&id, &old, &active, &out.UpdatedAt)
		if e != nil && !errors.Is(e, pgx.ErrNoRows) {
			return e
		}
		// Voice withdrawal also disables optional retention. If it was never
		// granted, acknowledge the disabled state without writing consent history.
		if !grant && out.Purpose == app.ConsentPurposeAudioRetention && errors.Is(e, pgx.ErrNoRows) {
			return tx.QueryRow(ctx, "select clock_timestamp()").Scan(&out.UpdatedAt)
		}
		if e == nil && old == version && active == grant {
			return nil
		}
		if !grant && (e != nil || old != version || !active) {
			return ErrInvalid
		}
		if active {
			if e = tx.QueryRow(ctx, `update consents set withdrawn_at=clock_timestamp() where id=$1 returning withdrawn_at`, id).Scan(&out.UpdatedAt); e != nil {
				return e
			}
		}
		if grant {
			return tx.QueryRow(ctx, `insert into consents(user_id,purpose,version,granted_at) values($1,$2,$3,clock_timestamp()) returning granted_at`, p.User, purpose, version).Scan(&out.UpdatedAt)
		}
		return nil
	})
	return out, e
}

type consentCursor struct {
	At time.Time
	ID uuid.UUID
}

func (s *Service) ListConsents(ctx context.Context, p Principal, params app.ListConsentsParams) (app.ListConsentsResult, error) {
	out := app.ListConsentsResult{Items: []app.Consent{}}
	limit := 20
	if params.Limit != nil {
		limit = *params.Limit
	}
	if limit < 1 || limit > 100 {
		return out, ErrInvalid
	}
	var after consentCursor
	if params.Cursor != nil {
		if len(*params.Cursor) > 256 {
			return out, ErrInvalid
		}
		b, e := base64.RawURLEncoding.DecodeString(*params.Cursor)
		if e != nil || json.Unmarshal(b, &after) != nil || after.At.IsZero() || after.ID == uuid.Nil {
			return out, ErrInvalid
		}
	}
	e := s.WithReadSession(ctx, p, false, func(tx pgx.Tx) error {
		rows, e := tx.Query(ctx, `with current as (select distinct on (purpose) purpose,version,withdrawn_at is null as granted,coalesce(withdrawn_at,granted_at) as at,id from consents where user_id=$1 order by purpose,(withdrawn_at is null) desc,granted_at desc,id desc) select purpose,version,granted,at,id from current where $2 or (at,id)<($3,$4) order by at desc,id desc limit $5`, p.User, params.Cursor == nil, after.At, after.ID, limit+1)
		if e != nil {
			return e
		}
		defer rows.Close()
		var last consentCursor
		for rows.Next() {
			if len(out.Items) == limit {
				b, e := json.Marshal(last)
				if e != nil {
					return e
				}
				v := base64.RawURLEncoding.EncodeToString(b)
				out.NextCursor = &v
				break
			}
			var c app.Consent
			if e := rows.Scan(&c.Purpose, &c.Version, &c.Granted, &c.UpdatedAt, &last.ID); e != nil {
				return e
			}
			last.At = c.UpdatedAt
			if c.Purpose == app.ConsentPurposeReplyChatImport || c.Purpose == app.ConsentPurposeContacts {
				id := last.ID
				c.DecisionId = &id
			}
			out.Items = append(out.Items, c)
		}
		return rows.Err()
	})
	return out, e
}
