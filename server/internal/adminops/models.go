package adminops

import (
	"context"
	"encoding/json"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"high-eq/server/internal/api/admin"
	"high-eq/server/internal/gateway"
	"io"
	"strings"
)

const modelSelect = `select id,name,provider,endpoint,model_name,kind,admission_ref,enabled,key_last_four,input_cny_per_million,output_cny_per_million from model_configs`
const modelFields = "name provider endpoint model_name kind admission_ref enabled input_cny_per_million output_cny_per_million api_key"

func (a api) ListModels(c *gin.Context, p admin.ListModelsParams) {
	a.listConfig(c, modelSelect, "id::text", p.Cursor, p.Limit)
}
func (a api) CreateModel(c *gin.Context)               { a.writeModel(c, uuid.New(), true) }
func (a api) UpdateModel(c *gin.Context, id uuid.UUID) { a.writeModel(c, id, false) }
func modelRow(ctx context.Context, tx pgx.Tx, id uuid.UUID) (v admin.Model, err error) {
	var raw []byte
	err = tx.QueryRow(ctx, `select row_to_json(q) from (`+modelSelect+` where id=$1) q`, id).Scan(&raw)
	if err == nil {
		err = json.Unmarshal(raw, &v)
	}
	return
}
func (a api) writeModel(c *gin.Context, id uuid.UUID, create bool) {
	req := ""
	if create {
		req = modelFields
	}
	patch, e := object(c, modelFields, req, "admission_ref")
	if e != nil {
		reject(c, 400)
		return
	}
	var key []byte
	if raw := patch["api_key"]; raw != nil {
		var s string
		if json.Unmarshal(raw, &s) != nil || len(s) > 4096 || len(s) < 5 || strings.IndexFunc(s, func(r rune) bool { return r < '!' || r > '~' }) >= 0 {
			reject(c, 400)
			return
		}
		key = []byte(s)
		delete(patch, "api_key")
	}
	a.manage(c, true, func(ctx context.Context, tx pgx.Tx) (any, error) {
		var v admin.Model
		if !create {
			var err error
			v, err = modelRow(ctx, tx, id)
			if err != nil {
				return nil, err
			}
		}
		old := v
		if v.AdmissionRef != nil {
			refValue := *v.AdmissionRef
			old.AdmissionRef = &refValue
		}
		raw, _ := json.Marshal(patch)
		if json.Unmarshal(raw, &v) != nil {
			return nil, badInput
		}
		for _, price := range []*float64{v.InputCnyPerMillion, v.OutputCnyPerMillion} {
			if (v.Enabled && price == nil) || (price != nil && (*price < 0 || *price > 999999.999999)) {
				return nil, badInput
			}
		}
		ref := func(s *string) string {
			if s == nil {
				return ""
			}
			return *s
		}
		if !create {
			changed := old.Endpoint != v.Endpoint || old.Provider != v.Provider
			if changed && key == nil {
				return nil, badInput
			}
			if changed || !v.Enabled || old.Kind != v.Kind || ref(old.AdmissionRef) != ref(v.AdmissionRef) || old.ModelName != v.ModelName {
				var used bool
				if e := tx.QueryRow(ctx, `select exists(select from model_routes where $1 in(primary_model,fallback_model,canary_model,moderation_model))`, id).Scan(&used); e != nil {
					return nil, e
				}
				if used {
					return nil, gateway.ErrConfig
				}
			}
		}
		cfg := gateway.Config{ID: id, Name: v.Name, Provider: v.Provider, Endpoint: v.Endpoint, ModelName: v.ModelName, Kind: gateway.Kind(v.Kind), AdmissionRef: ref(v.AdmissionRef), Enabled: v.Enabled, Protocol: "openai_compatible"}
		if e := a.catalog.SaveTx(ctx, tx, cfg, key); e != nil {
			return nil, e
		}
		if _, e := tx.Exec(ctx, `update model_configs set input_cny_per_million=$2,output_cny_per_million=$3 where id=$1`, id, v.InputCnyPerMillion, v.OutputCnyPerMillion); e != nil {
			return nil, e
		}
		if e := auditObject(ctx, tx, c, id); e != nil {
			return nil, e
		}
		return modelRow(ctx, tx, id)
	})
}
func (a api) TestModel(c *gin.Context, id uuid.UUID) {
	var buf [1]byte
	if n, e := c.Request.Body.Read(buf[:]); n != 0 || e != io.EOF || c.Request.URL.RawQuery != "" {
		reject(c, 400)
		return
	}
	a.manage(c, false, func(ctx context.Context, tx pgx.Tx) (any, error) {
		return admin.Ack{Ok: true}, a.catalog.ProbeTx(ctx, tx, id)
	})
}
