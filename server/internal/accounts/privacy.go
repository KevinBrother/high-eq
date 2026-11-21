package accounts

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/fieldcrypt"
	"high-eq/server/internal/privacy"
)

func Hooks(fields *fieldcrypt.Cipher) privacy.Module {
	return privacy.Module{Name: "accounts", Delete: func(ctx context.Context, tx pgx.Tx, d privacy.Deletion) error {
		if d.Scope != "account" {
			return nil
		} // Coordinator removes users before hooks; the FKs and bound-SMS trigger run in this transaction.
		var remains bool
		e := tx.QueryRow(ctx, `select exists(select from auth_sessions where user_id=$1 union all select from login_identities where user_id=$1 union all select from consents where user_id=$1)`, d.UserID).Scan(&remains)
		if e != nil {
			return e
		}
		if remains {
			return errors.New("account dependents remain")
		}
		return nil
	}, Export: func(ctx context.Context, tx pgx.Tx, r privacy.ExportRequest, emit privacy.Emit) error {
		var zone string
		var purchaseToken uuid.UUID
		var created, age time.Time
		var closure *time.Time
		if e := tx.QueryRow(ctx, "select timezone,created_at,age_confirmed_at,closure_requested_at,app_account_token from users where id=$1", r.UserID).Scan(&zone, &created, &age, &closure, &purchaseToken); e != nil {
			return e
		}
		if e := emit(map[string]any{"kind": "account", "user_id": r.UserID, "timezone": zone, "created_at": created, "age_confirmed_at": age, "closure_requested_at": closure, "app_account_token": purchaseToken}); e != nil {
			return e
		}
		return exportDetails(ctx, tx, r, fields, emit)
	}}
}
func exportDetails(ctx context.Context, tx pgx.Tx, r privacy.ExportRequest, fields *fieldcrypt.Cipher, emit privacy.Emit) error {
	rows, e := tx.Query(ctx, "select provider,subject_enc from login_identities where user_id=$1 order by provider", r.UserID)
	if e != nil {
		return e
	}
	var provider string
	var enc []byte
	_, e = pgx.ForEachRow(rows, []any{&provider, &enc}, func() error {
		plain, e := fields.Open(enc, aad(r.UserID, provider))
		if e != nil {
			return e
		}
		return emit(map[string]any{"kind": "identity", "provider": provider, "subject": string(plain)})
	})
	if e != nil {
		return e
	}
	rows, e = tx.Query(ctx, "select purpose,version,granted_at,withdrawn_at from consents where user_id=$1 order by granted_at,id", r.UserID)
	if e != nil {
		return e
	}
	var purpose, version string
	var at time.Time
	var withdrawn *time.Time
	_, e = pgx.ForEachRow(rows, []any{&purpose, &version, &at, &withdrawn}, func() error {
		return emit(map[string]any{"kind": "consent", "purpose": purpose, "version": version, "granted_at": at, "withdrawn_at": withdrawn})
	})
	return e
}
