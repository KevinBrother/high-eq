package prompts

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"errors"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"high-eq/server/internal/api/admin"
)

type Reader interface {
	QueryRow(context.Context, string, ...any) pgx.Row
}

func ValidTask(t admin.Task) bool {
	_, ok := taskVariables[t]
	return ok
}

// Create uses the caller's read-committed audit transaction. Serialize numbering per task;
// take a fresh statement snapshot AFTER acquiring the lock so concurrent editors both save.
func Create(ctx context.Context, tx pgx.Tx, v admin.CreatePromptVersionJSONBody) (admin.PromptVersion, error) {
	var out admin.PromptVersion
	if !ValidTask(v.Task) {
		return out, ErrTemplate
	}
	if err := ValidateForTask(v.Task, v.Template); err != nil {
		return out, err
	}
	if _, err := tx.Exec(ctx, `select pg_advisory_xact_lock(11011,hashtext($1))`, string(v.Task)); err != nil {
		return out, ErrStorage
	}
	err := tx.QueryRow(ctx, `insert into prompt_versions(task,version,template)
        select $1::ai_task,coalesce(max(version),0)+1,$2 from prompt_versions where task=$1
        returning id,task,version,template,created_at`, v.Task, v.Template).Scan(&out.Id, &out.Task, &out.Version, &out.Template, &out.CreatedAt)
	if err != nil {
		return out, ErrStorage
	}
	return out, nil
}

// Publish switches both arms and the split in one statement. Rollback is the same operation.
func Publish(ctx context.Context, tx pgx.Tx, r admin.PromptRelease) error {
	if !ValidTask(r.Task) || r.ModelId == uuid.Nil || r.PrimaryVersionId == uuid.Nil || r.ExperimentPercent < 0 || r.ExperimentPercent > 100 {
		return ErrRelease
	}
	if r.ExperimentVersionId == nil && r.ExperimentPercent != 0 {
		return ErrRelease
	}
	if r.ExperimentVersionId != nil && (*r.ExperimentVersionId == uuid.Nil || *r.ExperimentVersionId == r.PrimaryVersionId) {
		return ErrRelease
	}
	checkVersion := func(id uuid.UUID) error {
		var template string
		err := tx.QueryRow(ctx, `select template from prompt_versions where task=$1 and id=$2`, r.Task, id).Scan(&template)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return ErrStorage
		}
		return ValidateForTask(r.Task, template)
	}
	if err := checkVersion(r.PrimaryVersionId); err != nil {
		return err
	}
	if r.ExperimentVersionId != nil {
		if err := checkVersion(*r.ExperimentVersionId); err != nil {
			return err
		}
	}
	_, err := tx.Exec(ctx, `insert into prompt_releases(task,model_id,primary_version_id,experiment_version_id,experiment_percent)
        values($1,$2,$3,$4,$5) on conflict (task,model_id) do update set
        primary_version_id=excluded.primary_version_id, experiment_version_id=excluded.experiment_version_id,
        experiment_percent=excluded.experiment_percent`, r.Task, r.ModelId, r.PrimaryVersionId, r.ExperimentVersionId, r.ExperimentPercent)
	var pg *pgconn.PgError
	if errors.As(err, &pg) && pg.Code == "23503" {
		return ErrNotFound
	}
	if err != nil {
		return ErrStorage
	}
	return nil
}

// This hash is intentionally independent of model canary assignment. Never hash the
// operation, version or percentage: changing a threshold should only move boundary users.
func bucket(task string, model, user uuid.UUID) int {
	h := sha256.New()
	h.Write([]byte("prompt-ab:v1\x00" + task + "\x00"))
	h.Write(model[:])
	h.Write(user[:])
	return int(binary.BigEndian.Uint64(h.Sum(nil)[:8]) % 100)
}

// Resolve reads pointer and immutable template in ONE primary-database snapshot per attempt.
func Resolve(ctx context.Context, db Reader, task string, model, user uuid.UUID, vars map[string]string) (uuid.UUID, string, error) {
	var id uuid.UUID
	var src string
	err := db.QueryRow(ctx, `select v.id,v.template from prompt_releases r join prompt_versions v
        on v.id=case when $3 < r.experiment_percent then r.experiment_version_id else r.primary_version_id end
        where r.task=$1 and r.model_id=$2`, task, model, bucket(task, model, user)).Scan(&id, &src)
	if errors.Is(err, pgx.ErrNoRows) {
		return uuid.Nil, "", ErrNotFound
	}
	if err != nil {
		return uuid.Nil, "", ErrStorage
	}
	text, err := Render(src, vars)
	if err != nil {
		return uuid.Nil, "", err
	}
	return id, text, nil
}
