package growth

import (
	"math"
	"time"
)

// DailyCompletion is the plan-level projection used by streak calculations.
type DailyCompletion struct {
	Day  string
	Done bool
}

func planDays(days []DailyCompletion) []string {
	out := make([]string, 0, len(days))
	for _, d := range days {
		if d.Done {
			out = append(out, d.Day)
		}
	}
	return out
}

func streakFrom(days []string, today time.Time) (int, []int) {
	return Achievements(days, today.Format(time.DateOnly))
}

func round2(v float64) float64 {
	return math.Round(v*100) / 100
}
