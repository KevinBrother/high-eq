package gateway

import (
	"bytes"
	"context"
	"net/url"
	"strings"

	"github.com/google/uuid"
)

// Config contains platform metadata only. Save accepts the write-only key separately.
type Config struct {
	ID                                                          uuid.UUID
	Name, Provider, Endpoint, ModelName, AdmissionRef, Protocol string
	Kind                                                        Kind
	Enabled                                                     bool
}

func keyAAD(id uuid.UUID) []byte { return []byte("model_configs.api_key_enc/" + id.String()) }
func validEndpoint(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || strings.ContainsAny(raw, "?#%\\") {
		return false
	}
	for _, segment := range strings.Split(u.Path, "/") {
		if segment == "." || segment == ".." {
			return false
		}
	}
	return true
}

// Save replaces one configuration. Call only from a privileged management layer,
// never from business code. Evidence is provisioned separately by trusted operators.
func (c *Catalog) Save(ctx context.Context, m Config, key []byte) error {
	if m.ID == uuid.Nil || strings.TrimSpace(m.Name) == "" || strings.TrimSpace(m.ModelName) == "" ||
		strings.TrimSpace(m.Provider) == "" || !validEndpoint(m.Endpoint) || c.adapters[m.Protocol] == nil ||
		(m.Kind != Model && m.Kind != Moderation) || len(bytes.TrimSpace(key)) == 0 || bytes.ContainsAny(key, "\r\n") {
		return ErrConfig
	}
	sealed, err := c.fields.Seal(key, keyAAD(m.ID))
	if err != nil {
		return ErrConfig
	}
	_, err = c.db.Exec(ctx, `insert into model_configs(id,name,provider,endpoint,model_name,admission_ref,protocol,kind,enabled,api_key_enc,admitted_model)
 values($1,$2,$3,$4,$5,nullif($6,''),$7,$8,$9,$10, coalesce((select model_scope from provider_admissions where ref=$6),'*'))
 on conflict(id) do update set name=excluded.name, provider=excluded.provider, endpoint=excluded.endpoint,
 model_name=excluded.model_name, admission_ref=excluded.admission_ref, protocol=excluded.protocol,
 kind=excluded.kind, enabled=excluded.enabled, api_key_enc=excluded.api_key_enc, admitted_model=excluded.admitted_model`, m.ID, m.Name, m.Provider, m.Endpoint, m.ModelName, m.AdmissionRef, m.Protocol, m.Kind, m.Enabled, sealed)
	if err != nil {
		return ErrConfig
	}
	return c.Notify(ctx)
}

// Notify after a committed change. Delivery carries no IDs, endpoints, or secrets.
func (c *Catalog) Notify(ctx context.Context) error {
	if err := c.cache.Publish(ctx, changeChannel, "changed").Err(); err != nil {
		return ErrNotification
	}
	return nil
}
