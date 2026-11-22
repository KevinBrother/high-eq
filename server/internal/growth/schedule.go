package growth

import (
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"sort"
	"time"

	"github.com/google/uuid"
)

const (
	KindExercise = "exercise"
	KindLevel    = "level"
	KindCard     = "card"

	ReviewNow       = "retry_now"
	ReviewThreeDays = "retry_in_three_days"
	ReviewPass      = "pass"
	namespaceText   = "high-eq.t26.plan-item"
)

var planNamespace = uuid.MustParse("c2d4f4f4-2c91-4b20-9a2e-6c8f3a0f2a10")

type WLEIS struct {
	SEA float64
	OEA float64
	UOE float64
	ROE float64
}

// LevelIDs are resolved by T19. T26 never invents or falls back to a level ID:
// every plan item of kind "level" must point at a surviving canonical level.
type LevelIDs struct {
	Single uuid.UUID
	Full   uuid.UUID
}

type PlanInput struct {
	User             uuid.UUID
	Day              time.Time
	AssessmentID     uuid.UUID
	Scores           WLEIS
	Personalized     bool
	Scene            string
	Levels           LevelIDs
	UsedExercises    map[uuid.UUID]bool
	UsedCards        map[uuid.UUID]bool
	ReviewExerciseID *uuid.UUID
	ReviewTarget     string
	ReviewLevelID    *uuid.UUID
	ReviewActivityID *uuid.UUID
}

type PlanItem struct {
	ID               uuid.UUID  `json:"id"`
	Kind             string     `json:"kind"`
	Title            string     `json:"title"`
	ContentID        uuid.UUID  `json:"content_id"`
	Completed        bool       `json:"completed"`
	Review           bool       `json:"review,omitempty"`
	ReviewActivityID *uuid.UUID `json:"review_activity_id,omitempty"`
}

type Plan struct {
	Day          string     `json:"day"`
	Personalized bool       `json:"personalized"`
	Items        []PlanItem `json:"items"`
	AssessmentID *uuid.UUID `json:"assessment_id,omitempty"`
}

func Weakest(w WLEIS) string {
	type candidate struct {
		focus string
		value float64
	}
	c := []candidate{
		{"observation", w.SEA},
		{"feeling", w.OEA},
		{"need", w.UOE},
		{"request", w.ROE},
	}
	best := c[0]
	for _, v := range c[1:] {
		if v.value < best.value {
			best = v
		}
	}
	return best.focus
}

func Band(score int) string {
	switch {
	case score >= 25:
		return ReviewPass
	case score >= 10:
		return ReviewThreeDays
	default:
		return ReviewNow
	}
}

func BehaviorScore(nvcTotal int, emotion [3]int) float64 {
	if nvcTotal < 0 {
		nvcTotal = 0
	}
	if nvcTotal > 100 {
		nvcTotal = 100
	}
	mean := float64(emotion[0]+emotion[1]+emotion[2]) / 3
	normalized := (mean - 1) / 4 * 100
	if normalized < 0 {
		normalized = 0
	}
	if normalized > 100 {
		normalized = 100
	}
	return float64(nvcTotal)*0.7 + normalized*0.3
}

func TrainingReference(wleisPercent, behaviorAverage *float64) *float64 {
	if wleisPercent == nil || behaviorAverage == nil {
		return nil
	}
	v := (*wleisPercent + *behaviorAverage) / 2
	if v < 0 {
		v = 0
	}
	if v > 100 {
		v = 100
	}
	return &v
}

// Achievements returns the current consecutive-day streak and every threshold
// reached by the user's historical longest streak. A day is a local date string
// (YYYY-MM-DD), matching daily_plans.plan_day.
func Achievements(days []string, today string) (int, []int) {
	now, err := time.Parse(time.DateOnly, today)
	if err != nil {
		return 0, []int{}
	}
	unique := make(map[string]time.Time, len(days))
	for _, raw := range days {
		d, e := time.Parse(time.DateOnly, raw)
		if e == nil {
			unique[raw] = d
		}
	}
	if len(unique) == 0 {
		return 0, []int{}
	}
	ordered := make([]time.Time, 0, len(unique))
	for _, d := range unique {
		ordered = append(ordered, d)
	}
	sort.Slice(ordered, func(i, j int) bool { return ordered[i].Before(ordered[j]) })
	longest, run := 1, 1
	for i := 1; i < len(ordered); i++ {
		if ordered[i].Equal(ordered[i-1].AddDate(0, 0, 1)) {
			run++
		} else {
			run = 1
		}
		if run > longest {
			longest = run
		}
	}
	current := 0
	last := ordered[len(ordered)-1]
	if last.Equal(now) || last.Equal(now.AddDate(0, 0, -1)) {
		current = 1
		for i := len(ordered) - 2; i >= 0; i-- {
			if ordered[i].Equal(last.AddDate(0, 0, -1)) {
				current++
				last = ordered[i]
			} else {
				break
			}
		}
	}
	out := []int{}
	for _, threshold := range []int{3, 7, 30} {
		if longest >= threshold {
			out = append(out, threshold)
		}
	}
	return current, out
}

func PlanItemID(user uuid.UUID, day, kind string, content uuid.UUID) uuid.UUID {
	h := sha256.New()
	h.Write([]byte(namespaceText))
	h.Write(user[:])
	h.Write([]byte(day))
	h.Write([]byte(kind))
	h.Write(content[:])
	sum := h.Sum(nil)
	var b [16]byte
	copy(b[:], sum[:16])
	b[6] = (b[6] & 0x0f) | 0x50
	b[8] = (b[8] & 0x3f) | 0x80
	return uuid.UUID(b)
}

func BuildPlan(c Content, in PlanInput) (Plan, error) {
	if in.User == uuid.Nil || in.Day.IsZero() || in.AssessmentID == uuid.Nil || !validScene(in.Scene) || in.Levels.Single == uuid.Nil || in.Levels.Full == uuid.Nil || in.Levels.Single == in.Levels.Full {
		return Plan{}, errors.New("invalid plan input")
	}
	day := in.Day.Format(time.DateOnly)
	focus := Weakest(in.Scores)
	review := validFocus(in.ReviewTarget)
	if review {
		if in.ReviewLevelID == nil || *in.ReviewLevelID != in.Levels.Single || in.ReviewActivityID == nil || *in.ReviewActivityID == uuid.Nil {
			return Plan{}, errors.New("review plan requires its original level")
		}
		focus = in.ReviewTarget
	} else if in.ReviewActivityID != nil {
		return Plan{}, errors.New("non-review plan has a review activity")
	}
	ex, err := chooseExercise(c.Exercises, in, focus, in.Scene)
	if err != nil {
		return Plan{}, err
	}
	card, err := chooseCard(c.Cards, in, in.Scene)
	if err != nil {
		return Plan{}, err
	}
	assessment := in.AssessmentID
	var reviewActivityID *uuid.UUID
	if review {
		id := *in.ReviewActivityID
		reviewActivityID = &id
	}
	items := []PlanItem{
		{ID: PlanItemID(in.User, day, KindExercise, ex.ID), Kind: KindExercise, Title: "读人练习", ContentID: ex.ID},
		{ID: PlanItemID(in.User, day, KindLevel, in.Levels.Single), Kind: KindLevel, Title: "单项练习", ContentID: in.Levels.Single, Review: review, ReviewActivityID: reviewActivityID},
		{ID: PlanItemID(in.User, day, KindLevel, in.Levels.Full), Kind: KindLevel, Title: "完整对练", ContentID: in.Levels.Full},
		{ID: PlanItemID(in.User, day, KindCard, card.ID), Kind: KindCard, Title: card.Title, ContentID: card.ID},
	}
	return Plan{Day: day, Personalized: in.Personalized, Items: items, AssessmentID: &assessment}, nil
}

func chooseExercise(all []Exercise, in PlanInput, focus, scene string) (Exercise, error) {
	if in.ReviewExerciseID != nil {
		// Only an explicit exercise review may reuse content inside the
		// seven-day window. A due level review does not relax exercise dedup.
		for _, e := range all {
			if e.ID == *in.ReviewExerciseID {
				return e, nil
			}
		}
		return Exercise{}, errors.New("review exercise not found")
	}
	used := in.UsedExercises
	if e, ok := chooseExerciseCandidate(all, used, func(e Exercise) bool { return e.Focus == focus && e.Scene == scene }); ok {
		return e, nil
	}
	if e, ok := chooseExerciseCandidate(all, used, func(e Exercise) bool { return e.Focus == focus }); ok {
		return e, nil
	}
	return Exercise{}, errors.New("no unused exercise")
}

func chooseExerciseCandidate(all []Exercise, used map[uuid.UUID]bool, match func(Exercise) bool) (Exercise, bool) {
	var candidates []Exercise
	for _, e := range all {
		if match(e) && !used[e.ID] {
			candidates = append(candidates, e)
		}
	}
	if len(candidates) == 0 {
		return Exercise{}, false
	}
	return candidates[stableIndex(candidates, func(e Exercise) uuid.UUID { return e.ID })], true
}

func chooseCard(all []Card, in PlanInput, scene string) (Card, error) {
	if c, ok := chooseCardCandidate(all, in.UsedCards, scene); ok {
		return c, nil
	}
	if c, ok := chooseCardCandidate(all, in.UsedCards, ""); ok {
		return c, nil
	}
	return Card{}, errors.New("no unused card")
}

func chooseCardCandidate(all []Card, used map[uuid.UUID]bool, scene string) (Card, bool) {
	var candidates []Card
	for _, c := range all {
		if (scene == "" || c.Scene == scene) && !used[c.ID] {
			candidates = append(candidates, c)
		}
	}
	if len(candidates) == 0 {
		return Card{}, false
	}
	return candidates[stableIndex(candidates, func(c Card) uuid.UUID { return c.ID })], true
}

func stableIndex[T any](values []T, id func(T) uuid.UUID) int {
	sort.SliceStable(values, func(i, j int) bool { return id(values[i]).String() < id(values[j]).String() })
	v := id(values[0])
	return int(binary.BigEndian.Uint32(v[:4])) % len(values)
}

func sceneFor(user uuid.UUID, day, focus string) string {
	h := sha256.Sum256([]byte(user.String() + "|" + day + "|" + focus))
	return scenes[int(h[0])%len(scenes)]
}
