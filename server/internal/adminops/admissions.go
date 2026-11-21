package adminops

import (
	"context"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"high-eq/server/internal/api/admin"
)

const admissionFields = "provider endpoint model_scope kind purpose sent_fields processing_country storage_country cross_border max_retention_days deletion_method terms_evidence"

func (a api) ListAdmissions(c *gin.Context, p admin.ListAdmissionsParams) {
	a.listConfig(c, `select ref,provider,endpoint,model_scope,kind,purpose,sent_fields,processing_country,storage_country,cross_border,max_retention_days,deletion_method,terms_evidence from provider_admissions`, "ref", p.Cursor, p.Limit)
}
func (a api) CreateAdmission(c *gin.Context) {
	var v admin.NewAdmission
	if !decodeObject(c, &v, admissionFields, admissionFields, "") {
		return
	}
	a.manage(c, true, func(ctx context.Context, tx pgx.Tx) (any, error) {
		id := uuid.New()
		_, e := tx.Exec(ctx, `insert into provider_admissions(ref,provider,endpoint,model_scope,kind,purpose,sent_fields,processing_country,storage_country,cross_border,max_retention_days,deletion_method,terms_evidence) values($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)`, id.String(), v.Provider, v.Endpoint, v.ModelScope, v.Kind, v.Purpose, v.SentFields, v.ProcessingCountry, v.StorageCountry, bool(v.CrossBorder), v.MaxRetentionDays, v.DeletionMethod, v.TermsEvidence)
		if e != nil {
			return nil, e
		}
		return struct {
			Ref string `json:"ref"`
			admin.NewAdmission
		}{id.String(), v}, auditObject(ctx, tx, c, id)
	})
}
func (a api) RevokeAdmission(c *gin.Context, ref string) {
	a.manage(c, true, func(ctx context.Context, tx pgx.Tx) (any, error) {
		_, e := tx.Exec(ctx, `delete from model_routes r using model_configs m where m.admission_ref=$1 and m.id in(r.primary_model,r.fallback_model,r.canary_model,r.moderation_model)`, ref)
		if e != nil {
			return nil, e
		}
		_, e = tx.Exec(ctx, `update model_configs set enabled=false,admission_ref=null where admission_ref=$1`, ref)
		if e != nil {
			return nil, e
		}
		tag, e := tx.Exec(ctx, `delete from provider_admissions where ref=$1`, ref)
		if e != nil {
			return nil, e
		}
		if tag.RowsAffected() != 1 {
			return nil, pgx.ErrNoRows
		}
		if id, e := uuid.Parse(ref); e == nil {
			if e = auditObject(ctx, tx, c, id); e != nil {
				return nil, e
			}
		}
		return admin.Ack{Ok: true}, nil
	})
}
