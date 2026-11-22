package growth

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/events"
	"high-eq/server/internal/fieldcrypt"
)

const behaviorWindow = 720 * time.Hour

type NVCValues struct {
	Observation int `json:"observation"`
	Feeling     int `json:"feeling"`
	Need        int `json:"need"`
	Request     int `json:"request"`
	Total       int `json:"total"`
}

type EmotionValues struct {
	ReadOthers     int `json:"read_others"`
	SelfManagement int `json:"self_management"`
	Relationship   int `json:"relationship"`
}

// Service owns T26's source-keyed numeric projection. Its methods run inside
// the account/source transaction supplied by T04; they never open or commit one.
type Service struct {
	Fields *fieldcrypt.Cipher
}

// Reference is recomputed from surviving sources. No aggregate is persisted,
// so adding or deleting a valid score changes the denominator immediately.
type Reference struct {
	LatestAssessment   *uuid.UUID `json:"latest_assessment"`
	WLEISPercent       *float64   `json:"wleis_percent"`
	TrainingReference  *float64   `json:"training_reference"`
	ValidBehaviorCount int        `json:"valid_behavior_count"`
}

type ExportRecord struct {
	RecordType string        `json:"record_type"`
	SourceID   uuid.UUID     `json:"source_id"`
	Kind       string        `json:"kind"`
	OccurredAt time.Time     `json:"occurred_at"`
	NVC        NVCValues     `json:"nvc"`
	Emotion    EmotionValues `json:"emotion"`
}

type PlanItemExportRecord struct {
	ID        uuid.UUID `json:"id"`
	Kind      string    `json:"kind"`
	Title     string    `json:"title"`
	ContentID uuid.UUID `json:"content_id"`
	Completed bool      `json:"completed"`
}

type PlanExportRecord struct {
	RecordType   string                 `json:"record_type"`
	AssessmentID *uuid.UUID             `json:"assessment_id"`
	Day          string                 `json:"day"`
	Personalized bool                   `json:"personalized"`
	Items        []PlanItemExportRecord `json:"items"`
	CompletedAt  *time.Time             `json:"completed_at"`
}

type DrillExportRecord struct {
	RecordType string     `json:"record_type"`
	LevelID    uuid.UUID  `json:"level_id"`
	TargetItem string     `json:"target_item"`
	Score      int        `json:"score"`
	Band       string     `json:"band"`
	OccurredAt time.Time  `json:"occurred_at"`
	RetryAt    *time.Time `json:"retry_at"`
}

// Consume is idempotent by the canonical score/source ID. It stores only the
// numeric projection; date and account are derived from the surviving source.
func (s *Service) Consume(ctx context.Context, tx pgx.Tx, v events.Score) error {
	if tx == nil || s.Fields == nil || v.SourceID == uuid.Nil || v.UserID == uuid.Nil || (v.Kind != "practice" && v.Kind != "review") {
		return errors.New("invalid growth score event")
	}
	var values events.ScoreValues
	values.NVC.Observation = v.NVC.Observation
	values.NVC.Feeling = v.NVC.Feeling
	values.NVC.Need = v.NVC.Need
	values.NVC.Request = v.NVC.Request
	values.NVC.Total = v.NVC.Total
	values.Emotion.ReadOthers = v.Emotion.ReadOthers
	values.Emotion.SelfManagement = v.Emotion.SelfManagement
	values.Emotion.Relationship = v.Emotion.Relationship
	if err := validateValues(values); err != nil {
		return err
	}
	nvc := NVCValues{v.NVC.Observation, v.NVC.Feeling, v.NVC.Need, v.NVC.Request, v.NVC.Total}
	emotion := EmotionValues{v.Emotion.ReadOthers, v.Emotion.SelfManagement, v.Emotion.Relationship}
	nvcEnc, err := s.seal(nvc, v.SourceID, "nvc_enc")
	if err != nil {
		return err
	}
	emotionEnc, err := s.seal(emotion, v.SourceID, "emotion_enc")
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `insert into growth_scores(score_id,kind,nvc_enc,emotion_enc) values($1,$2,$3,$4) on conflict(score_id) do nothing`, v.SourceID, v.Kind, nvcEnc, emotionEnc)
	return err
}

// Reference must be called with the caller's guarded pgx.Tx. It reads the
// latest surviving WLEIS result and recomputes the behavior mean over valid
// practice/review projections whose original score time is within 720 hours.
func (s *Service) Reference(ctx context.Context, tx pgx.Tx, user uuid.UUID, now time.Time) (Reference, error) {
	var out Reference
	if tx == nil || s.Fields == nil || user == uuid.Nil || now.IsZero() {
		return out, errors.New("invalid growth reference request")
	}
	var (
		assessmentID uuid.UUID
		version      string
		sealed       []byte
	)
	err := tx.QueryRow(ctx, `select id,instrument_version,scores_enc from assessments where user_id=$1 order by completed_at desc,id desc limit 1`, user).Scan(&assessmentID, &version, &sealed)
	switch {
	case err == nil:
		aad := []byte("assessments:scores_enc:" + user.String() + ":" + assessmentID.String() + ":" + version)
		plain, openErr := s.Fields.Open(sealed, aad)
		if openErr != nil {
			return out, openErr
		}
		var scores struct {
			Total struct {
				Percent *float64 `json:"percent"`
			} `json:"total"`
		}
		if openErr = json.Unmarshal(plain, &scores); openErr != nil {
			return out, openErr
		}
		if scores.Total.Percent == nil || *scores.Total.Percent < 0 || *scores.Total.Percent > 100 {
			return out, errors.New("invalid WLEIS percentage")
		}
		id, percent := assessmentID, *scores.Total.Percent
		out.LatestAssessment, out.WLEISPercent = &id, &percent
	case errors.Is(err, pgx.ErrNoRows):
		// WLEIS is optional for this projection.
	default:
		return out, err
	}

	rows, err := tx.Query(ctx, `select g.score_id,g.kind,s.occurred_at,g.nvc_enc,g.emotion_enc
from growth_scores g
join scores s on s.id=g.score_id and s.activity_kind=g.kind
join activities a on a.id=s.activity_id and a.source_id=s.id
where a.user_id=$1 and a.state='complete' and g.kind in ('practice','review')
  and s.occurred_at>$2 and s.occurred_at<=$3
order by s.occurred_at,g.score_id`, user, now.Add(-behaviorWindow), now)
	if err != nil {
		return out, err
	}
	defer rows.Close()
	var sum float64
	for rows.Next() {
		var (
			source     uuid.UUID
			kind       string
			occurredAt time.Time
			nvcEnc     []byte
			emotionEnc []byte
		)
		if err = rows.Scan(&source, &kind, &occurredAt, &nvcEnc, &emotionEnc); err != nil {
			return out, err
		}
		record, openErr := s.openRecord(source, kind, occurredAt, nvcEnc, emotionEnc)
		if openErr != nil {
			return out, openErr
		}
		sum += BehaviorScore(record.NVC.Total, [3]int{record.Emotion.ReadOthers, record.Emotion.SelfManagement, record.Emotion.Relationship})
		out.ValidBehaviorCount++
	}
	if err = rows.Err(); err != nil {
		return out, err
	}
	if out.ValidBehaviorCount > 0 {
		average := sum / float64(out.ValidBehaviorCount)
		out.TrainingReference = TrainingReference(out.WLEISPercent, &average)
	}
	return out, nil
}

func (s *Service) export(ctx context.Context, tx pgx.Tx, user uuid.UUID, emit func(any) error) error {
	rows, err := tx.Query(ctx, `select g.score_id,g.kind,s.occurred_at,g.nvc_enc,g.emotion_enc
from growth_scores g
join scores s on s.id=g.score_id and s.activity_kind=g.kind
join activities a on a.id=s.activity_id and a.source_id=s.id
where a.user_id=$1 and a.state='complete' and g.kind in ('practice','review')
order by s.occurred_at,g.score_id`, user)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var (
			source     uuid.UUID
			kind       string
			occurredAt time.Time
			nvcEnc     []byte
			emotionEnc []byte
		)
		if err = rows.Scan(&source, &kind, &occurredAt, &nvcEnc, &emotionEnc); err != nil {
			return err
		}
		record, err := s.openRecord(source, kind, occurredAt, nvcEnc, emotionEnc)
		if err != nil {
			return err
		}
		if err = emit(record); err != nil {
			return err
		}
	}
	return rows.Err()
}

func (s *Service) openRecord(source uuid.UUID, kind string, occurredAt time.Time, nvcEnc, emotionEnc []byte) (ExportRecord, error) {
	var record ExportRecord
	if s.Fields == nil || source == uuid.Nil || (kind != "practice" && kind != "review") || occurredAt.IsZero() {
		return record, errors.New("invalid growth projection")
	}
	nvcPlain, err := s.Fields.Open(nvcEnc, growthAAD(source, "nvc_enc"))
	if err != nil {
		return record, err
	}
	if err = json.Unmarshal(nvcPlain, &record.NVC); err != nil {
		return record, err
	}
	emotionPlain, err := s.Fields.Open(emotionEnc, growthAAD(source, "emotion_enc"))
	if err != nil {
		return record, err
	}
	if err = json.Unmarshal(emotionPlain, &record.Emotion); err != nil {
		return record, err
	}
	values := events.ScoreValues{}
	values.NVC.Observation, values.NVC.Feeling, values.NVC.Need, values.NVC.Request, values.NVC.Total = record.NVC.Observation, record.NVC.Feeling, record.NVC.Need, record.NVC.Request, record.NVC.Total
	values.Emotion.ReadOthers, values.Emotion.SelfManagement, values.Emotion.Relationship = record.Emotion.ReadOthers, record.Emotion.SelfManagement, record.Emotion.Relationship
	if err = validateValues(values); err != nil {
		return record, err
	}
	record.RecordType = "score"
	record.SourceID, record.Kind, record.OccurredAt = source, kind, occurredAt.UTC()
	return record, nil
}

func (s *Service) seal(v any, source uuid.UUID, field string) ([]byte, error) {
	plain, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	return s.Fields.Seal(plain, growthAAD(source, field))
}

func growthAAD(source uuid.UUID, field string) []byte {
	return []byte("growth_scores." + field + "/" + source.String())
}

func validateValues(v events.ScoreValues) error {
	sum := v.NVC.Observation + v.NVC.Feeling + v.NVC.Need + v.NVC.Request
	if !validNVC(v.NVC.Observation) || !validNVC(v.NVC.Feeling) || !validNVC(v.NVC.Need) || !validNVC(v.NVC.Request) || v.NVC.Total != sum || v.NVC.Total < 0 || v.NVC.Total > 100 {
		return fmt.Errorf("invalid NVC values")
	}
	if v.Emotion.ReadOthers < 1 || v.Emotion.ReadOthers > 5 || v.Emotion.SelfManagement < 1 || v.Emotion.SelfManagement > 5 || v.Emotion.Relationship < 1 || v.Emotion.Relationship > 5 {
		return fmt.Errorf("invalid emotion values")
	}
	return nil
}

func validNVC(v int) bool {
	return v == 0 || v == 5 || v == 10 || v == 15 || v == 25
}
