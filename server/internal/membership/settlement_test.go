package membership

import "testing"

func TestSharedSettlementTable(t *testing.T) {
	for _, tt := range []struct {
		from   string
		event  Outcome
		state  string
		refund bool
	}{
		{"accepted", Completed, "complete", false}, {"accepted", Exited, "exited", false}, {"held", Failed, "failed", true}, {"held", Exited, "exited", false}, {"held", Safety, "safety", true}, {"accepted", Failed, "failed", true}, {"accepted", Safety, "safety", true}, {"held", ModerationUnavailable, "moderation_unavailable", true}, {"accepted", ModerationUnavailable, "moderation_unavailable", true}, {"safety", Safety, "safety", false}, {"complete", Failed, "complete", false},
	} {
		state, refund, e := transition(tt.from, tt.event)
		if e != nil || state != tt.state || refund != tt.refund {
			t.Errorf("%s/%s: %s %v %v", tt.from, tt.event, state, refund, e)
		}
	}
	if _, _, e := transition("held", Completed); e == nil {
		t.Fatal("no approved result")
	}
}
