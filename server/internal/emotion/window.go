package emotion

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"math"
	"slices"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/events"
	"high-eq/server/internal/fieldcrypt"
	"high-eq/server/internal/privacy"
)

var (
	Invalid   = errors.New("invalid aggregate or annotation")
	Conflict  = errors.New("conflicting signal")
	Forbidden = errors.New("signal permission unavailable")
)

type Service struct {
	Fields *fieldcrypt.Cipher
	Data   *privacy.Coordinator
	DB     *pgxpool.Pool
	Bus    *events.Bus
}
type Stat struct {
	Mean    *float64 `json:"mean"`
	Maximum *float64 `json:"maximum"`
	Count   int      `json:"sample_count"`
	Seconds *int     `json:"valid_seconds,omitempty"`
}
type Window struct {
	At       time.Time `json:"starts_at"`
	Channel  string    `json:"channel"`
	Duration int       `json:"duration_seconds"`
	Exercise *bool     `json:"exercise"`
	Source   string    `json:"source,omitempty"`
	Voiced   *int      `json:"voiced_seconds,omitempty"`
	Heart    *Stat     `json:"heart_rate,omitempty"`
	HRV      *Stat     `json:"hrv,omitempty"`
	Cadence  *Stat     `json:"cadence,omitempty"`
	Speech   *Stat     `json:"speech_rate,omitempty"`
	Volume   *Stat     `json:"volume,omitempty"`
	Pitch    *Stat     `json:"pitch,omitempty"`
}

func (w *Window) UnmarshalJSON(b []byte) error {
	type plain Window
	d := json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	if e := d.Decode((*plain)(w)); e != nil {
		return Invalid
	}
	// Check presence as well as decoded values: null is not an omitted field,
	// and an empty foreign-channel field is not part of either OpenAPI branch.
	var fields map[string]json.RawMessage
	if json.Unmarshal(b, &fields) != nil {
		return Invalid
	}
	for name, raw := range fields {
		if string(raw) == "null" {
			return Invalid
		}
		switch name {
		case "channel", "starts_at", "duration_seconds", "exercise":
		case "source", "heart_rate", "hrv", "cadence":
			if w.Channel != "health" {
				return Invalid
			}
		case "voiced_seconds", "speech_rate", "volume", "pitch":
			if w.Channel != "voice" {
				return Invalid
			}
		default:
			return Invalid
		}
	}
	return w.validate()
}
func (w Window) validate() error {
	if !aligned(w.At) || w.Duration != 30 || w.Exercise == nil {
		return Invalid
	}
	limit := 30
	switch w.Channel {
	case "health":
		if !slices.Contains([]string{"watch_live", "apple_history", "health_connect", "huawei_history"}, w.Source) || w.Voiced != nil || w.Volume != nil || w.Pitch != nil || w.Speech != nil || (w.Heart == nil && w.HRV == nil && w.Cadence == nil) {
			return Invalid
		}
	case "voice":
		if w.Voiced == nil || *w.Voiced < 0 || *w.Voiced > 30 || w.Source != "" || w.Heart != nil || w.Cadence != nil || w.HRV != nil {
			return Invalid
		}
		limit = *w.Voiced
	default:
		return Invalid
	}
	for _, s := range []*Stat{w.Heart, w.HRV, w.Cadence, w.Speech, w.Volume, w.Pitch} {
		if s == nil {
			continue
		}
		if s.Mean == nil || s.Maximum == nil || *s.Maximum < *s.Mean || s.Count < 1 || s.Count > math.MaxInt32 || math.Abs(*s.Maximum) > math.MaxFloat32 || math.Abs(*s.Mean) > math.MaxFloat32 || (s != w.Volume && *s.Mean < 0) {
			return Invalid
		}
		if s == w.HRV {
			if s.Seconds != nil {
				return Invalid
			}
		} else if s.Seconds == nil || *s.Seconds < 0 || *s.Seconds > limit {
			return Invalid
		}
	}
	return nil
}
func consent(ctx context.Context, tx pgx.Tx, u uuid.UUID, purpose string, at time.Time) error {
	yes, e := accounts.Granted(ctx, tx, u, purpose)
	if e != nil {
		return e
	}
	if !yes {
		return Forbidden
	}
	var inGrant bool
	e = tx.QueryRow(ctx, `select exists(select from consents where user_id=$1 and purpose=$2 and withdrawn_at is null and granted_at<=$3)`, u, purpose, at).Scan(&inGrant)
	if e == nil && !inGrant {
		return Forbidden
	}
	return e
}
func aad(u, id uuid.UUID, table string) []byte {
	return []byte(table + "/" + u.String() + "/" + id.String())
}
func (s Service) seal(u, id uuid.UUID, table string, v any) ([]byte, error) {
	b, e := json.Marshal(v)
	if e != nil {
		return nil, e
	}
	return s.Fields.Seal(b, aad(u, id, table))
}
func (s Service) open(u, id uuid.UUID, table string, b []byte, v any) error {
	p, e := s.Fields.Open(b, aad(u, id, table))
	if e != nil {
		return e
	}
	return json.Unmarshal(p, v)
}
func (s Service) Upload(ctx context.Context, tx pgx.Tx, u uuid.UUID, w Window, now time.Time) error {
	if e := w.validate(); e != nil {
		return e
	}
	w.At = w.At.UTC()
	if w.At.After(now) || !w.At.After(now.Add(-retention)) {
		return Invalid
	}
	if e := consent(ctx, tx, u, w.Channel, w.At); e != nil {
		return e
	}
	id := uuid.New()
	enc, e := s.seal(u, id, "window", w)
	if e != nil {
		return e
	}
	tag, e := tx.Exec(ctx, `insert into signal_windows(user_id,channel,starts_at,stats_enc,purge_id) values($1,$2,$3,$4,$5) on conflict(user_id,channel,starts_at) do nothing`, u, w.Channel, w.At, enc, id)
	if e != nil || tag.RowsAffected() == 1 {
		return e
	}
	e = tx.QueryRow(ctx, `select purge_id,stats_enc from signal_windows where user_id=$1 and channel=$2 and starts_at=$3`, u, w.Channel, w.At).Scan(&id, &enc)
	if e != nil {
		return e
	}
	b, e := s.Fields.Open(enc, aad(u, id, "window"))
	if e != nil {
		return e
	}
	want, _ := json.Marshal(w)
	if !bytes.Equal(want, b) {
		return Conflict
	}
	return nil
}
