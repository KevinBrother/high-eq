package emotion

import (
	"regexp"
	"strings"
	"time"
)

// Check the original fraction before time.Parse can discard non-zero digits.
var windowStart = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt][0-9]{2}:[0-9]{2}:(00|30)(\.0+)?([Zz]|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$`)

func ParseWindowStart(raw string) (time.Time, error) {
	if !windowStart.MatchString(raw) {
		return time.Time{}, Invalid
	}
	at, err := time.Parse(time.RFC3339, strings.ToUpper(raw))
	if err != nil || !aligned(at) {
		return time.Time{}, Invalid
	}
	return at.UTC(), nil
}
