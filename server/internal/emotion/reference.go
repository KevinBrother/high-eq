// Package emotion works only with aligned 30-second aggregates. Decide is the
// portable reference for T32B; neither missing features nor HRV are imputed.
package emotion

import (
	"math"
	"time"
)

const (
	Self   = "self_fluctuation"
	Rhythm = "conversation_rhythm"
	None   = "none"
)

var signals = []string{"heart_rate", "speech_rate", "volume", "pitch"}

type Frame struct {
	Start          time.Time           `json:"starts_at"`
	HealthAt       time.Time           `json:"health_at"`
	VoiceAt        time.Time           `json:"voice_at"`
	Source         string              `json:"source"`
	WatchReleased  bool                `json:"watch_released"`
	Exercise       bool                `json:"exercise"`
	Cadence        float64             `json:"cadence_2m"`
	Last           *time.Time          `json:"last_alert"`
	Means          map[string]*float64 `json:"means"`
	Thresholds     map[string]*float64 `json:"thresholds"`
	SpeechRateUnit string              `json:"speech_rate_unit,omitempty"`
}
type Decision struct {
	Kind    string
	Signals []string
}

func aligned(t time.Time) bool { return !t.IsZero() && t.Equal(t.Truncate(30*time.Second)) }
func Decide(f Frame) Decision {
	none := Decision{Kind: None}
	if !aligned(f.Start) || !f.Start.Equal(f.VoiceAt) || f.Exercise || f.Cadence > 100 || (f.Last != nil && f.Start.Sub(*f.Last) < 10*time.Minute) {
		return none
	}
	var hits []string
	for _, name := range signals {
		v := f.Means[name]
		t := f.Thresholds[name]
		if v != nil && t != nil && *v >= *t {
			if name == "speech_rate" && f.SpeechRateUnit != SpeechRateUnitCharactersPerSecond {
				continue
			}
			if name == "heart_rate" && (!f.Start.Equal(f.HealthAt) || f.Source != "watch_live" || !f.WatchReleased) {
				continue
			}
			hits = append(hits, name)
		}
	}
	if len(hits) < 2 {
		return none
	}
	if hits[0] == "heart_rate" {
		return Decision{Self, hits}
	}
	if hits[0] == "speech_rate" {
		return Decision{Rhythm, hits}
	}
	return none
}

type Progress struct {
	Days      int      `json:"valid_days"`
	Today     int      `json:"today_valid_seconds"`
	Ready     bool     `json:"ready"`
	Reason    string   `json:"reason"`
	Baseline  *float64 `json:"baseline"`
	Threshold *float64 `json:"threshold"`
}
type Trend struct {
	Readings int    `json:"readings"`
	Days     int    `json:"sampling_days"`
	Ready    bool   `json:"ready_for_alert"`
	Reason   string `json:"reason"`
}
type Baselines struct {
	Heart  Progress `json:"heart_rate"`
	Speech Progress `json:"speech_rate"`
	Volume Progress `json:"volume"`
	Pitch  Progress `json:"pitch"`
	HRV    Trend    `json:"hrv"`
}

const (
	HealthOffReason = "健康授权已关闭"
	VoiceOffReason  = "语音授权已关闭"
)

// Restrict removes every statistic derived from a collection purpose whose
// consent is not currently granted. Heart rate and HRV are health-derived;
// speech rate, volume and pitch are voice-derived. The response keeps its
// required shape, but unauthorized dimensions carry no counts or baselines.
func (b *Baselines) Restrict(health, voice bool) {
	if !health {
		b.Heart = Progress{Reason: HealthOffReason}
		b.HRV = Trend{Reason: HealthOffReason}
	}
	if !voice {
		b.Speech = Progress{Reason: VoiceOffReason}
		b.Volume = Progress{Reason: VoiceOffReason}
		b.Pitch = Progress{Reason: VoiceOffReason}
	}
}
type totals struct {
	seconds  int
	weighted float64
	days     map[string]int
}
type accumulator struct {
	loc      *time.Location
	stats    map[string]*totals
	hrvDays  map[string]bool
	readings int
}

func newAccumulator(loc *time.Location) *accumulator {
	return &accumulator{loc: loc, stats: map[string]*totals{}, hrvDays: map[string]bool{}}
}
func (a *accumulator) add(at time.Time, k string, v float64, seconds int) {
	if seconds <= 0 {
		return
	}
	s := a.stats[k]
	if s == nil {
		s = &totals{days: map[string]int{}}
		a.stats[k] = s
	}
	s.seconds += seconds
	s.weighted += v * float64(seconds)
	s.days[at.In(a.loc).Format(time.DateOnly)] += seconds
}
func (a *accumulator) progress(now time.Time, negatives map[string]int) Baselines {
	var b Baselines
	today := now.In(a.loc).Format(time.DateOnly)
	for i, p := range []*Progress{&b.Heart, &b.Speech, &b.Volume, &b.Pitch} {
		k := signals[i]
		p.Reason = "尚无有效覆盖"
		if i > 0 {
			p.Reason = "尚无人声特征有效时长"
		}
		s := a.stats[k]
		if s == nil {
			continue
		}
		p.Today = s.days[today]
		for _, n := range s.days {
			if n >= 1800 {
				p.Days++
			}
		}
		p.Reason = "有效日不足 7 天（每天需 1800 秒）"
		if p.Days >= 7 {
			p.Ready = true
			p.Reason = "基线已就绪"
			base := s.weighted / float64(s.seconds)
			delta := []float64{base * .20, base * .25, 6, base * .15}[i]
			factor := math.Min(1.5, math.Pow(1.05, float64(negatives[k])))
			upper := (base + delta) * factor
			if k == "volume" { // dB is logarithmic and may be negative: raise the +6 dB margin.
				upper = base + delta*factor
			}
			p.Baseline = &base
			p.Threshold = &upper
		}
	}
	b.HRV = Trend{Readings: a.readings, Days: len(a.hrvDays), Reason: "暂无离散读数，不影响提醒"}
	if a.readings > 0 {
		b.HRV.Reason = "仅供历史趋势，不参与提醒"
	}
	return b
}
