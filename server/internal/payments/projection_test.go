package payments

import (
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestProjection(t *testing.T) {
	day := 24 * time.Hour
	at := func(d int) time.Time { return time.Unix(0, 0).UTC().Add(time.Duration(d) * day) }
	a, b, ios, renew := uuid.New(), uuid.New(), uuid.New(), uuid.New()
	cards := []grant{{id: a, start: at(0), duration: 30 * day}, {id: b, start: at(2), duration: 365 * day}, {id: ios, start: at(5), end: at(35)}}
	check := func(wanta, wantb int) {
		t.Helper()
		p := project(cards)
		if !p[a].end.Equal(at(wanta)) || !p[b].end.Equal(at(wantb)) {
			t.Fatalf("wrong account periods: %v", p)
		}
	}
	check(60, 425)
	cards = append(cards, grant{id: renew, start: at(33), end: at(65)})
	check(90, 455)
	cards[3].refund = at(45)
	check(70, 435)
	cards[0].refund = at(48)
	check(48, 413)
}

func TestQueuedAndRefundedCardsDoNotConsumeCoveredTime(t *testing.T) {
	at := func(h int) time.Time { return time.Unix(int64(h*3600), 0).UTC() }
	apple, first, queued, last := uuid.New(), uuid.New(), uuid.New(), uuid.New()
	// First hour consumed before iOS starts; refund a queued year before it begins.
	facts := []grant{{id: last, start: at(4), duration: time.Hour}, {id: apple, start: at(1), end: at(25)}, {id: queued, start: at(3), refund: at(10), duration: 365 * 24 * time.Hour}, {id: first, start: at(0), duration: 2 * time.Hour}}
	p := project(facts)
	if _, ok := p[queued]; ok || !p[first].end.Equal(at(26)) || !p[last].start.Equal(at(26)) || !p[last].end.Equal(at(27)) {
		t.Fatal(p)
	}
}
