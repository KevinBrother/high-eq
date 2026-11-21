package gateway

import (
	"context"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"time"
)

// ValidateRouteTx applies the same contract ordering as business dispatch, including
// failover from a canary. Caller serializes management writes on gateway_revision.
func ValidateRouteTx(ctx context.Context, tx pgx.Tx, primary, backup, mod uuid.UUID, canary *uuid.UUID) error {
	load := func(id uuid.UUID, kind Kind) (approved, error) {
		var a approved
		a.id = id
		err := tx.QueryRow(ctx, `select a.purpose,a.deletion_method,a.max_retention_days,a.sent_fields from model_configs m join provider_admissions a on a.ref=m.active_ref where m.id=$1 and m.kind=$2 and m.protocol='openai_compatible' and m.input_cny_per_million is not null and m.output_cny_per_million is not null`, id, kind).Scan(&a.purpose, &a.deletion, &a.retention, &a.fields)
		return a, err
	}
	p, e := load(primary, Model)
	if e != nil {
		return e
	}
	b, e := load(backup, Model)
	if e != nil {
		return e
	}
	if !p.covers(b) || primary == backup {
		return ErrConfig
	}
	if _, e = load(mod, Moderation); e != nil {
		return e
	}
	if canary != nil {
		v, e := load(*canary, Model)
		if e != nil {
			return e
		}
		if !p.covers(v) || !v.covers(b) {
			return ErrConfig
		}
	}
	return nil
}

// ProbeTx pins the approval and model during the bounded synthetic request. Never
// accepts caller text, credentials or a URL, and discards the entire provider reply.
func (c *Catalog) ProbeTx(ctx context.Context, tx pgx.Tx, id uuid.UUID) error {
	var t target
	var protocol string
	var sealed []byte
	err := tx.QueryRow(ctx, `select m.endpoint,m.model_name,m.protocol,m.api_key_enc from model_configs m join provider_admissions a on (a.ref,a.provider,a.endpoint,a.kind,a.model_scope)=(m.active_ref,m.provider,m.endpoint,m.kind,m.admitted_model) where m.id=$1 and m.enabled for share of m,a`, id).Scan(&t.endpoint, &t.model, &protocol, &sealed)
	if err != nil {
		return err
	}
	a := c.adapters[protocol]
	if a == nil || !validEndpoint(t.endpoint) {
		return ErrConfig
	}
	k, e := c.fields.Open(sealed, keyAAD(id))
	if e != nil {
		return ErrConfig
	}
	t.key = string(k)
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	_, e = a.chat(ctx, t, Request{Mode: Text, Messages: []Message{{Role: "user", Content: "synthetic connectivity check"}}})
	return e
}
