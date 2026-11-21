package payments

import (
	"context"
	"encoding/json"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/privacy"
)

func rebuild(ctx context.Context, tx pgx.Tx, user uuid.UUID, now time.Time) error {
	rows, e := tx.Query(ctx, `select order_id,paid_at,apple_until,refunded_at,card_days from payment_facts where user_id=$1`, user)
	if e != nil {
		return e
	}
	var facts []grant
	for rows.Next() {
		var f grant
		var start, end, refund *time.Time
		var days int
		if e := rows.Scan(&f.id, &start, &end, &refund, &days); e != nil {
			rows.Close()
			return e
		}
		if start != nil {
			f.start = *start
		}
		if end != nil {
			f.end = *end
		}
		if refund != nil {
			f.refund = *refund
		}
		f.duration = time.Duration(days) * 24 * time.Hour
		facts = append(facts, f)
	}
	rows.Close()
	if e := rows.Err(); e != nil {
		return e
	}
	periods := project(facts)
	for _, f := range facts {
		p, ok := periods[f.id]
		state := "pending"
		if !f.refund.IsZero() {
			state = "refunded"
		} else if ok {
			state = "paid"
			if !p.end.After(now) {
				state = "expired"
			}
		}
		if _, e = tx.Exec(ctx, "update orders set state=$2 where id=$1 and state<>$2", f.id, state); e != nil {
			return e
		}
		if ok && state != "refunded" {
			_, e = tx.Exec(ctx, `insert into entitlements(order_id,user_id,starts_at,ends_at) values($1,$2,$3,$4) on conflict(order_id) do update set starts_at=excluded.starts_at,ends_at=excluded.ends_at`, f.id, user, p.start, p.end)
		} else {
			_, e = tx.Exec(ctx, "delete from entitlements where order_id=$1", f.id)
		}
		if e != nil {
			return e
		}
	}
	return nil
}
func Hooks() privacy.Module {
	return privacy.Module{Name: "payments", Delete: func(ctx context.Context, tx pgx.Tx, d privacy.Deletion) error {
		if d.Scope != "account" {
			return nil
		}
		var remains bool
		e := tx.QueryRow(ctx, `select exists(select from orders where user_id=$1 union all select from payment_facts where user_id=$1 union all select from payment_notices where user_id=$1)`, d.UserID).Scan(&remains)
		if e == nil && remains {
			return ErrOrder
		}
		return e
	}, Export: func(ctx context.Context, tx pgx.Tx, r privacy.ExportRequest, emit privacy.Emit) error {
		if _, e := tx.Exec(ctx, `update orders o set state='expired' from entitlements e where o.id=e.order_id and o.user_id=$1 and o.state='paid' and e.ends_at<=now()`, r.UserID); e != nil {
			return e
		}
		rows, e := tx.Query(ctx, `select to_jsonb(x) from (select o.id,o.platform,o.product_code,o.amount_fen,case when o.state='paid' and e.ends_at<=now() then 'expired' else o.state end as state,o.created_at,f.paid_at,f.refunded_at from orders o left join payment_facts f on f.order_id=o.id left join entitlements e on e.order_id=o.id where o.user_id=$1 order by o.created_at,o.id) x`, r.UserID)
		if e != nil {
			return e
		}
		defer rows.Close()
		for rows.Next() {
			var b json.RawMessage
			if e := rows.Scan(&b); e != nil {
				return e
			}
			if e := emit(b); e != nil {
				return e
			}
		}
		return rows.Err()
	}}
}
