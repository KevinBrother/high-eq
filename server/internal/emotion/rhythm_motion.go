package emotion

import (
	"context"
	"errors"
	"math"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

const rhythmSlot = 30 * time.Second

// RhythmMotionReader is a server-side source of verified coverage for a
// single user and target window. The source must establish provenance,
// continuous observability and the health grant under which it measured.
// An unavailable or no longer authorized source returns unknown evidence.
// Legacy signal windows and client event payloads cannot supply this proof.
type RhythmMotionReader func(ctx context.Context, tx pgx.Tx, user uuid.UUID, target time.Time) (RhythmMotionEvidence, error)

// Cadence covers the four slots ending at target+30s. Exercise covers the
// target slot alone. Nil readings represent unknown; measured zero is valid.
type RhythmMotionEvidence struct {
	HealthGrantID    uuid.UUID
	CadenceFrom      time.Time
	CadenceUntil     time.Time
	CadencePerMinute *float64
	ExerciseFrom     time.Time
	ExerciseUntil    time.Time
	Exercise         *bool
}

func (s Service) rhythmMotion(ctx context.Context, tx pgx.Tx, u uuid.UUID, target, now, collectionFrom time.Time) (RhythmMotionEvidence, error) {
	var evidence RhythmMotionEvidence
	until := target.Add(rhythmSlot)
	from := until.Add(-2 * time.Minute)
	if until.After(now) || !from.After(now.Add(-retention)) {
		return evidence, Invalid
	}
	if from.Before(collectionFrom) {
		return evidence, Forbidden
	}
	// Admission and withdrawal use the same account lock. The current grant
	// must cover the earliest cadence slot, including after a re-grant.
	var grantID uuid.UUID
	err := tx.QueryRow(ctx, `select id from consents
		where user_id=$1 and purpose='health' and withdrawn_at is null and granted_at<=$2`, u, from).Scan(&grantID)
	if errors.Is(err, pgx.ErrNoRows) {
		return evidence, Forbidden
	}
	if err != nil {
		return evidence, err
	}
	if s.ReadRhythmMotion == nil {
		return evidence, Invalid
	}
	evidence, err = s.ReadRhythmMotion(ctx, tx, u, target)
	if err != nil {
		return evidence, err
	}
	if evidence.HealthGrantID != grantID ||
		!evidence.CadenceFrom.Equal(from) || !evidence.CadenceUntil.Equal(until) ||
		!evidence.ExerciseFrom.Equal(target) || !evidence.ExerciseUntil.Equal(until) ||
		evidence.Exercise == nil || evidence.CadencePerMinute == nil {
		return evidence, Invalid
	}
	cadence := *evidence.CadencePerMinute
	if cadence < 0 || math.IsNaN(cadence) || math.IsInf(cadence, 0) {
		return evidence, Invalid
	}
	return evidence, nil
}
