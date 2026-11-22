package emotion

import (
	"time"

	"github.com/google/uuid"

	"high-eq/server/internal/api/app"
)

// FeedbackSource is the minimum disclosure needed by T25. Trigger features
// remain private even when consuming a legitimately confirmed event.
type FeedbackSource struct {
	app.SignalEvent
	FeedbackID  uuid.UUID  `json:"feedback_id"`
	ConfirmedAt *time.Time `json:"confirmed_at"`
}

func (r FeedbackSource) Verified() bool {
	return r.Kind == Self && r.ConfirmedAt != nil && r.FeedbackID != uuid.Nil && (r.Confirmation == "yes" || r.Confirmation == "no")
}
func (r FeedbackSource) Positive() bool { return r.Verified() && r.Confirmation == "yes" }

// DecodeFeedback uses the source owner's envelope format. Callers must select the
// unexpired row under the transaction's account/erasure lock and verify its parent.
func (s Service) DecodeFeedback(user, id uuid.UUID, b []byte) (FeedbackSource, error) {
	var r record
	if e := s.open(user, id, "event", b, &r); e != nil {
		return FeedbackSource{}, e
	}
	out := FeedbackSource{r.SignalEvent, r.FeedbackID, r.ConfirmedAt}
	if r.Id != id || !out.Verified() {
		return FeedbackSource{}, Invalid
	}
	return out, nil
}
