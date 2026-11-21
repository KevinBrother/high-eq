package membership

import (
	"context"
	"encoding/json"

	"github.com/jackc/pgx/v5"
	"high-eq/server/internal/privacy"
)

func (s *Service) Hooks() privacy.Module {
	return privacy.Module{Name: "membership", Delete: func(ctx context.Context, _ pgx.Tx, d privacy.Deletion) error {
		// SQL cascades remove per-source attempts/charges; the anonymous-to-source daily
		// total must survive single-source deletion. Account erasure removes both.
		if d.Scope != "account" {
			return nil
		}
		keys := make([]string, 0, len(features))
		for _, f := range features {
			keys = append(keys, counterKey(d.UserID, f))
		}
		return s.cache.Del(ctx, keys...).Err()
	}, Export: func(ctx context.Context, tx pgx.Tx, r privacy.ExportRequest, emit privacy.Emit) error {
		for _, q := range []string{
			`select to_jsonb(x) from (select 'entitlement' as kind,starts_at,ends_at from entitlements where user_id=$1 order by starts_at,order_id) x`,
			`select to_jsonb(x) from (select 'charge' as kind,a.kind as feature,activity_id,charged_day,charged_at,refunded_at from quota_ledger q join activities a on a.id=q.activity_id where a.user_id=$1 order by activity_id) x`,
			`select to_jsonb(x) from (select 'daily_usage' as kind,feature,charged_day,used from daily_quota_usage where user_id=$1 order by charged_day,feature) x`,
			`select to_jsonb(x) from (select 'settlement' as kind,activity_id,q.state from quota_attempts q join activities a on a.id=q.activity_id where a.user_id=$1 order by activity_id) x`,
		} {
			if e := exportRows(ctx, tx, r, emit, q); e != nil {
				return e
			}
		}
		return nil
	}}
}
func exportRows(ctx context.Context, tx pgx.Tx, r privacy.ExportRequest, emit privacy.Emit, q string) error {
	rows, e := tx.Query(ctx, q, r.UserID)
	if e != nil {
		return e
	}
	defer rows.Close()
	for rows.Next() {
		var v json.RawMessage
		if e := rows.Scan(&v); e != nil {
			return e
		}
		if e := emit(v); e != nil {
			return e
		}
	}
	return rows.Err()
}
