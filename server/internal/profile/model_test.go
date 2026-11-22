package profile

import (
	"testing"
	"time"

	"github.com/google/uuid"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/emotion"
)

func TestIndependentEvidence(t *testing.T) {
	var d dossier
	d.Scene = "partner"
	d.Answers[5] = 1
	p := d.render(nil)
	q := d.render([]vote{{5, 1}, {5, 1}})
	if p.ConflictStyle.Label != q.ConflictStyle.Label || q.ConflictStyle.Confidence <= p.ConflictStyle.Confidence {
		t.Fatal(p, q)
	}
	if d.render([]vote{{5, 2}}).ConflictStyle.Confidence != 0 {
		t.Fatal("contradictions must lower certainty")
	}
	d.Scene = "work"
	d.Answers[6] = 1
	if d.render(nil).Attachment != nil {
		t.Fatal("partner only")
	}
}
func TestNonPartnerOmitsAttachmentFromSummary(t *testing.T) {
	d := dossier{Scene: "work"}
	p := d.render([]vote{{Axis: 6, Option: 2}})
	if p.Attachment != nil {
		t.Fatal("non-partner attachment rendered")
	}
	if p.Summary != unknown {
		t.Fatalf("non-partner attachment leaked into summary: %q", p.Summary)
	}
}

func TestExplicitSelfOnly(t *testing.T) {
	id := uuid.New()
	for _, k := range []string{"manual_mark", "conversation_rhythm", "self_fluctuation"} {
		for _, c := range []string{"pending", "yes", "no"} {
			r := emotion.FeedbackSource{SignalEvent: app.SignalEvent{Id: id, Kind: app.SignalEventKind(k), Confirmation: app.SignalEventConfirmation(c)}, FeedbackID: uuid.New()}
			if r.Positive() {
				t.Fatal("missing canonical confirmation time")
			}
			r.ConfirmedAt = &nowFixture
			if r.Positive() != (k == "self_fluctuation" && c == "yes") {
				t.Fatal(k, c)
			}
		}
	}
}

var nowFixture = time.Unix(123, 0)
