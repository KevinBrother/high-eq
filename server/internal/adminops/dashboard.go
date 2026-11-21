package adminops

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"high-eq/server/internal/api/admin"
	"high-eq/server/internal/gateway"
	"high-eq/server/internal/prompts"
)

func (a api) ListPromptModels(c *gin.Context, p admin.ListPromptModelsParams) {
	a.listConfig(c, `select id,name,enabled from model_configs where kind='model'`, "id::text", p.Cursor, p.Limit)
}

type groupKey struct {
	task    string
	model   uuid.UUID
	version string
}

func metricKey(m gateway.Metric) groupKey {
	k := groupKey{task: string(m.Task), model: m.Model}
	if m.PromptVersion != nil {
		k.version = m.PromptVersion.String()
	}
	return k
}
func (k groupKey) encode() string {
	return base64.RawURLEncoding.EncodeToString([]byte(strings.Join([]string{k.task, k.model.String(), k.version}, "|")))
}
func groupAfter(cursor *string) (k groupKey, ok bool) {
	if cursor == nil {
		return k, true
	}
	if len(*cursor) > 180 {
		return
	}
	b, e := base64.RawURLEncoding.DecodeString(*cursor)
	v := strings.Split(string(b), "|")
	if e != nil || len(v) != 3 || !prompts.ValidTask(admin.Task(v[0])) {
		return
	}
	k.model, e = uuid.Parse(v[1])
	if e != nil {
		return
	}
	k.task = v[0]
	if v[2] != "" {
		id, e := uuid.Parse(v[2])
		if e != nil {
			return k, false
		}
		k.version = id.String()
	}
	return k, true
}

type bin struct {
	Total int `json:"nvc_total"`
	Count int `json:"count"`
}

// Never open scores.detail_enc. Only distinct source IDs linked to successful
// attempts in this exact group are eligible. Missing projections are not zeros.
func (a api) distribution(ctx context.Context, tx pgx.Tx, f gateway.Filter, m gateway.Metric) ([]bin, int, error) {
	bins := []bin{}
	missing := 0
	if m.Task != gateway.Scoring {
		return bins, 0, nil
	}
	rows, e := tx.Query(ctx, `select s.score_id,g.nvc_enc from (select distinct score_id from ai_calls
 where started_at >= $1 and started_at < $2 and task='scoring' and model_id=$3 and prompt_version_id is not distinct from $4::uuid and outcome='ok' and score_id is not null) s left join growth_scores g using(score_id)`, f.From, f.Until, m.Model, m.PromptVersion)
	if e != nil {
		return nil, 0, e
	}
	defer rows.Close()
	var counts [101]int
	for rows.Next() {
		var id uuid.UUID
		var sealed []byte
		if e = rows.Scan(&id, &sealed); e != nil {
			return nil, 0, e
		}
		if sealed == nil {
			missing++
			continue
		}
		if a.fields == nil {
			return nil, 0, errors.New("numeric projection unavailable")
		}
		raw, e := a.fields.Open(sealed, []byte("growth_scores.nvc_enc/"+id.String()))
		if e != nil {
			return nil, 0, e
		}
		var value struct {
			Total *int `json:"total"`
		}
		if json.Unmarshal(raw, &value) != nil || value.Total == nil || *value.Total < 0 || *value.Total > 100 {
			return nil, 0, errors.New("invalid numeric projection")
		}
		counts[*value.Total]++
	}
	for i, n := range counts {
		if n != 0 {
			bins = append(bins, bin{i, n})
		}
	}
	return bins, missing, rows.Err()
}

func (a api) GetMetrics(c *gin.Context, p admin.GetMetricsParams) {
	until := time.Now().UTC()
	if p.Until != nil {
		until = *p.Until
	}
	f := gateway.Filter{Until: until, From: until.Add(-24 * time.Hour)}
	if p.From != nil {
		f.From = *p.From
	}
	n := 20
	if p.Limit != nil {
		n = *p.Limit
	}
	after, ok := groupAfter(p.Cursor)
	if !ok || n < 1 || n > 100 || !f.Until.After(f.From) || f.Until.Sub(f.From) > 31*24*time.Hour || p.Task != nil && !prompts.ValidTask(*p.Task) || p.ModelId != nil && *p.ModelId == uuid.Nil || p.PromptVersionId != nil && *p.PromptVersionId == uuid.Nil {
		reject(c, 400)
		return
	}
	if p.Task != nil {
		f.Task = gateway.Task(*p.Task)
	}
	if p.ModelId != nil {
		f.Model = *p.ModelId
	}
	if p.PromptVersionId != nil {
		f.PromptVersion = *p.PromptVersionId
	}
	ctx := c.Request.Context()
	items := []gin.H{}
	var next *string
	e := pgx.BeginTxFunc(ctx, a.db, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly}, func(tx pgx.Tx) error {
		groups := []gateway.Metric{}
		more := n + 1
		e := gateway.MetricPage(ctx, tx, f, after.task, after.model, after.version, &more, func(m gateway.Metric) error { groups = append(groups, m); return nil })
		if e != nil {
			return e
		}
		if len(groups) > n {
			s := metricKey(groups[n-1]).encode()
			next = &s
			groups = groups[:n]
		}
		for _, m := range groups {
			bins, missing, e := a.distribution(ctx, tx, f, m)
			if e != nil {
				return e
			}
			items = append(items, gin.H{"task": m.Task, "model_id": m.Model, "prompt_version_id": m.PromptVersion, "calls": m.Calls, "failures": m.Failures, "failure_rate": m.FailureRate, "mean_latency_ms": m.MeanLatencyMS, "cost_cny": json.Number(m.KnownCostCNY), "unpriced_calls": m.Unpriced, "score_distribution": bins, "missing_score_values": missing})
		}
		return nil
	})
	if e != nil {
		reject(c, 500)
		return
	}
	c.JSON(200, gin.H{"items": items, "next_cursor": next})
}
