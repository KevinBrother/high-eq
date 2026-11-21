package membership

import (
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestAccountMidnight(t *testing.T) {
	for _, c := range []struct{ instant, zone, date, next string }{
		{"2026-11-21T16:00:00Z", "Asia/Shanghai", "2026-11-22", "2026-11-23T00:00:00+08:00"},
		{"2018-11-03T14:00:00Z", "America/Sao_Paulo", "2018-11-03", "2018-11-04T01:00:00-02:00"},
		{"2026-03-08T05:00:00Z", "America/New_York", "2026-03-08", "2026-03-09T00:00:00-04:00"},
	} {
		at, _ := time.Parse(time.RFC3339, c.instant)
		d, next, e := dayWindow(at, c.zone)
		if e != nil || d != c.date || next.Format(time.RFC3339) != c.next {
			t.Fatal(d, next, e)
		}
	}
}
func TestLimitsAndCapabilities(t *testing.T) {
	s, e := New(nil)
	if e != nil {
		t.Fatal(e)
	}
	for _, f := range features {
		if *s.policy.Free.Daily[f] != 3 || s.policy.Member.Daily[f] != nil {
			t.Fatal(f)
		}
	}
	for _, c := range []Capability{ManualMark, History, Assessment, Radar, Exercise, Card, GenericPlan} {
		if !s.policy.Free.allows(c) {
			t.Fatal(c)
		}
	}
	for _, c := range []Capability{Collection, AlignedReplay, EmotionSummary, PersonalPlan} {
		if s.policy.Free.allows(c) || !s.policy.Member.allows(c) {
			t.Fatal(c)
		}
	}
	if s.policy.Member.allows(WatchAlert) || s.policy.Member.allows("unknown") {
		t.Fatal("unreleased capability")
	}
}

// These authenticated operations do not even look up a subscription or a Redis bucket.
func TestManualAndHistoryBypassMembership(t *testing.T) {
	s, e := New(nil)
	if e != nil {
		t.Fatal(e)
	}
	for _, c := range []Capability{ManualMark, History} {
		if e := s.Require(t.Context(), nil, uuid.Nil, c); e != nil {
			t.Fatal(c, e)
		}
	}
}
