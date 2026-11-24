package gateway

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"high-eq/server/internal/privacy"
)

// Metrics is the internal T15 read port, not an unauthenticated HTTP endpoint.
// Each group counts attempts (including fallback); missing measurements are explicit.
type Filter struct {
	From, Until          time.Time
	Task                 Task
	Model, PromptVersion uuid.UUID
}
type Metric struct {
	Task                       Task
	Model                      uuid.UUID
	PromptVersion              *uuid.UUID
	Calls, Failures, Unpriced  int64
	MeanLatencyMS, FailureRate float64
	InputTokens, OutputTokens  int64
	KnownCostCNY               string
}

func Metrics(ctx context.Context, db *pgxpool.Pool, f Filter, emit func(Metric) error) error {
	return readMetrics(ctx, db, f, emit)
}
func readMetrics(ctx context.Context, db interface {
	Query(context.Context, string, ...any) (pgx.Rows, error)
}, f Filter, emit func(Metric) error) error {
	return MetricPage(ctx, db, f, "", uuid.Nil, "", nil, emit)
}

// MetricPage also accepts a transaction so an admin page and its score bins
// share a snapshot. NULL prompt versions sort before version UUIDs.
func MetricPage(ctx context.Context, db interface {
	Query(context.Context, string, ...any) (pgx.Rows, error)
}, f Filter, afterTask string, afterModel uuid.UUID, afterVersion string, limit *int, emit func(Metric) error) error {
	if !f.Until.After(f.From) || f.From.IsZero() || f.Task != "" && !f.Task.valid() || emit == nil {
		return ErrRequest
	}
	rows, err := db.Query(ctx, `select task,model_id,prompt_version_id,count(*),count(*) filter(where outcome<>'ok'),count(*) filter(where cost_cny is null),
 coalesce(avg(latency_ms),0)::float8,(count(*) filter(where outcome<>'ok'))::float8/count(*),
 coalesce(sum(input_tokens),0),coalesce(sum(output_tokens),0),coalesce(sum(cost_cny),0)::text
 from ai_calls where started_at>=$1 and started_at<$2 and ($3::text='' or task::text=$3)
 and ($4::uuid is null or model_id=$4) and ($5::uuid is null or prompt_version_id=$5)
 and (task::text,model_id,coalesce(prompt_version_id::text,''))>($6::text,$7::uuid,$8::text)
 group by task,model_id,prompt_version_id order by task::text,model_id,coalesce(prompt_version_id::text,'') limit $9`, f.From, f.Until, f.Task, optional(f.Model), optional(f.PromptVersion), afterTask, afterModel, afterVersion, limit)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var m Metric
		if err := rows.Scan(&m.Task, &m.Model, &m.PromptVersion, &m.Calls, &m.Failures, &m.Unpriced, &m.MeanLatencyMS, &m.FailureRate, &m.InputTokens, &m.OutputTokens, &m.KnownCostCNY); err != nil {
			return err
		}
		if err := emit(m); err != nil {
			return err
		}
	}
	return rows.Err()
}

func Hooks(masterKey []byte) privacy.Module {
	key := hmac.New(sha256.New, masterKey)
	key.Write([]byte("high-eq/ai_calls/export-operation/v2"))
	exportKey := key.Sum(nil)
	return privacy.Module{Name: "ai_calls", Delete: func(context.Context, pgx.Tx, privacy.Deletion) error {
		return nil /* source, score, contact and user FKs cascade in the coordinator transaction */
	}, Export: func(ctx context.Context, tx pgx.Tx, q privacy.ExportRequest, emit privacy.Emit) error {
		rows, err := tx.Query(ctx, `select jsonb_build_object(
 'id',id,'activity_id',activity_id,'contact_id',contact_id,'score_id',score_id,
 'model_id',model_id,'prompt_version_id',prompt_version_id,'task',task,'started_at',started_at,
 'outcome',outcome,'latency_ms',latency_ms,'input_tokens',input_tokens,'output_tokens',output_tokens,'cost_cny',cost_cny
 ), operation_id, task, activity_id, contact_id,
 task='scoring' and exists(select from activities a where a.id=ai_calls.activity_id and a.kind='review')
 from ai_calls
 where user_id=$1 or (user_id is null and activity_id in (select id from activities where user_id=$1))
 order by started_at,id`, q.UserID)
		if err != nil {
			return err
		}
		defer rows.Close()
		groupMAC := hmac.New(sha256.New, exportKey)
		for rows.Next() {
			var row map[string]any
			var operation, activity, contact *uuid.UUID
			var task Task
			var reviewScore bool
			if err := rows.Scan(&row, &operation, &task, &activity, &contact, &reviewScore); err != nil {
				return err
			}
			row["operation_id"] = nil
			if operation != nil {
				// A review shares one activity and request across analysis and scoring.
				// Other tasks have their own request namespaces, including practice
				// turns and scoring within a single activity.
				if reviewScore {
					task = ReviewAnalysis
				}
				group := append([]byte(string(task)+"/"), operation[:]...)
				switch {
				case activity != nil:
					group = append(group, 'a')
					group = append(group, activity[:]...)
				case contact != nil:
					group = append(group, 'c')
					group = append(group, contact[:]...)
				}
				// Historical rows with identical stored scope and request cannot
				// distinguish separate operations. Keep that group deterministic.
				row["operation_id"] = uuid.NewHash(groupMAC, q.UserID, group, 8)
			}
			if err := emit(row); err != nil {
				return err
			}
		}
		return rows.Err()
	}}
}
