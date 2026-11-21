package emotion

import (
	"context"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// Process one time slot at a time: both channels share the same motion mask.
// Keep only 4 cadence buckets and daily counters, not a user's 180-day trace.
type slot struct {
	at            time.Time
	health, voice *Window
}
type cadencePoint struct {
	at      time.Time
	mean    float64
	seconds int
}

func (s Service) windows(ctx context.Context, tx pgx.Tx, u uuid.UUID, from, to time.Time, visit func(Window) error) error {
	rows, e := tx.Query(ctx, `select purge_id,stats_enc from signal_windows where user_id=$1 and starts_at>$2 and starts_at<=$3 order by starts_at,channel`, u, from, to)
	if e != nil {
		return e
	}
	defer rows.Close()
	for rows.Next() {
		var id uuid.UUID
		var enc []byte
		var w Window
		if e = rows.Scan(&id, &enc); e != nil {
			return e
		}
		if e = s.open(u, id, "window", enc, &w); e != nil {
			return e
		}
		if e = visit(w); e != nil {
			return e
		}
	}
	return rows.Err()
}

// For a classification at end, leave its slot out of its own reference baseline.
func (s Service) baseline(ctx context.Context, tx pgx.Tx, u uuid.UUID, now, end time.Time, forEvent bool) (Baselines, Frame, error) {
	var zone string
	var f Frame
	e := tx.QueryRow(ctx, `select timezone from users where id=$1`, u).Scan(&zone)
	if e != nil {
		return Baselines{}, f, e
	}
	loc, e := time.LoadLocation(zone)
	if e != nil {
		return Baselines{}, f, e
	}
	a, f, e := reduceWindows(loc, end, forEvent, func(visit func(Window) error) error { return s.windows(ctx, tx, u, now.Add(-retention), end, visit) })
	if e != nil {
		return Baselines{}, f, e
	}
	counts := map[string]int{}
	e = s.walkEvents(ctx, tx, u, now.Add(-retention), end, func(r record) error {
		if r.Confirmation == "no" && r.ConfirmedAt != nil && !r.ConfirmedAt.After(end) {
			for _, k := range r.Triggers {
				counts[k]++
			}
		}
		return nil
	})
	if e != nil {
		return Baselines{}, f, e
	}
	b := a.progress(end, counts)
	f.Thresholds = map[string]*float64{}
	for i, p := range []Progress{b.Heart, b.Speech, b.Volume, b.Pitch} {
		if p.Threshold != nil {
			f.Thresholds[signals[i]] = p.Threshold
		}
	}
	return b, f, nil
}
func (s Service) Baselines(ctx context.Context, tx pgx.Tx, u uuid.UUID, now time.Time) (Baselines, error) {
	b, _, e := s.baseline(ctx, tx, u, now, now, false)
	return b, e
}

// reduceWindows folds sorted (time, channel) statistics. The reader can be a
// PG cursor or synthetic vector; no database, clock or device enters the fold.
func reduceWindows(loc *time.Location, end time.Time, forEvent bool, read func(func(Window) error) error) (*accumulator, Frame, error) {
	var f Frame
	a := newAccumulator(loc)
	var slot slot
	var cad []cadencePoint
	consume := func() {
		h, v := slot.health, slot.voice
		if h == nil && v == nil {
			return
		}
		f0 := Frame{Start: slot.at, Means: map[string]*float64{}}
		for len(cad) > 0 && !cad[0].at.After(slot.at.Add(-2*time.Minute)) {
			cad = cad[1:]
		}
		if h != nil {
			f0.HealthAt = h.At
			f0.Source = h.Source
			f0.Exercise = *h.Exercise
			if c := h.Cadence; c != nil && *c.Seconds > 0 {
				cad = append(cad, cadencePoint{h.At, *c.Mean, *c.Seconds})
			}
		}
		sum, n := 0., 0
		for _, c := range cad {
			sum += c.mean * float64(c.seconds)
			n += c.seconds
		}
		if n > 0 {
			f0.Cadence = sum / float64(n)
		}
		if v != nil {
			f0.VoiceAt = v.At
			f0.Exercise = f0.Exercise || *v.Exercise
		}
		sample := func(k string, s *Stat) {
			if s == nil || *s.Seconds == 0 {
				return
			}
			f0.Means[k] = s.Mean
			if !(forEvent && end.Equal(slot.at)) && !f0.Exercise && f0.Cadence <= 100 {
				a.add(slot.at, k, *s.Mean, *s.Seconds)
			}
		}
		if h != nil {
			sample("heart_rate", h.Heart)
			if h.HRV != nil {
				a.readings += h.HRV.Count
				a.hrvDays[h.At.In(loc).Format(time.DateOnly)] = true
			}
		}
		if v != nil {
			sample("speech_rate", v.Speech)
			sample("volume", v.Volume)
			sample("pitch", v.Pitch)
		}
		if slot.at.Equal(end) {
			f = f0
		}
	}
	e := read(func(w Window) error {
		if !slot.at.Equal(w.At) {
			consume()
			slot.health = nil
			slot.voice = nil
			slot.at = w.At
		}
		if w.Channel == "voice" {
			slot.voice = &w
		} else {
			slot.health = &w
		}
		return nil
	})
	if e != nil {
		return nil, f, e
	}
	consume()
	return a, f, nil
}
