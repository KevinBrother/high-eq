// Package payments verifies channel evidence before changing the account's SQL ledger.
package payments

import (
	"sort"
	"time"

	"github.com/google/uuid"
)

type span struct{ start, end time.Time }
type grant struct {
	id                 uuid.UUID
	start, end, refund time.Time
	duration           time.Duration
}

// Replay immutable purchase times, not callback arrival times. The Android span
// includes pauses: in their union with iOS this is exactly the T06 coverage.
func project(facts []grant) map[uuid.UUID]span {
	out := map[uuid.UUID]span{}
	var ios []span
	var cards []grant
	for _, f := range facts {
		if f.start.IsZero() {
			continue
		}
		if f.duration > 0 {
			cards = append(cards, f)
			continue
		}
		end := cut(f.end, f.refund)
		if end.After(f.start) {
			s := span{f.start, end}
			ios = append(ios, s)
			out[f.id] = s
		}
	}
	sort.Slice(ios, func(i, j int) bool { return ios[i].start.Before(ios[j].start) })
	sort.Slice(cards, func(i, j int) bool {
		if cards[i].start.Equal(cards[j].start) {
			return cards[i].id.String() < cards[j].id.String()
		}
		return cards[i].start.Before(cards[j].start)
	})
	var tail time.Time
	for _, c := range cards {
		start := c.start
		if tail.After(start) {
			start = tail
		}
		cursor, left := start, c.duration
		for _, s := range ios {
			if !s.end.After(cursor) {
				continue
			}
			if !s.start.Before(cursor.Add(left)) {
				break
			}
			if s.start.After(cursor) {
				left -= s.start.Sub(cursor)
			}
			cursor = s.end
		}
		end := cut(cursor.Add(left), c.refund)
		if end.After(start) {
			out[c.id] = span{start, end}
			tail = end
		}
	}
	return out
}
func cut(t, limit time.Time) time.Time {
	if !limit.IsZero() && limit.Before(t) {
		return limit
	}
	return t
}
