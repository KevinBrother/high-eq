// Package scoring grades one completed practice or review. It owns no user storage,
// account ledger or event publisher. Source owners persist only successful results.
package scoring

import (
	"errors"

	"github.com/google/uuid"
	"high-eq/server/internal/events"
	"high-eq/server/internal/gateway"
)

var ErrSchema = errors.New("invalid score format")
var ErrInput = errors.New("invalid scoring input")

type Turn struct {
	Role string `json:"role"`
	Text string `json:"text"`
}
type Item struct {
	Score  int    `json:"score"`
	Reason string `json:"reason"`
}
type Level struct {
	Level  int    `json:"level"`
	Reason string `json:"reason"`
}
type NVC struct {
	Observation Item `json:"observation"`
	Feeling     Item `json:"feeling"`
	Need        Item `json:"need"`
	Request     Item `json:"request"`
	Total       int  `json:"total"`
}
type Emotion struct {
	ReadOthers     Level `json:"read_others"`
	SelfManagement Level `json:"self_management"`
	Relationship   Level `json:"relationship"`
}
type Full struct {
	Mode          string  `json:"mode"`
	NVC           NVC     `json:"nvc"`
	Emotion       Emotion `json:"emotion"`
	BetterVersion string  `json:"better_version"`
	WhyBetter     string  `json:"why_better"`
	TargetTurn    *int    `json:"target_turn,omitempty"`
}

// Values is the numeric-only projection of a validated source score. Drill
// progress intentionally has no such conversion. Neither method publishes events.
func (f Full) Values() events.ScoreValues {
	var v events.ScoreValues
	v.NVC.Observation = f.NVC.Observation.Score
	v.NVC.Feeling = f.NVC.Feeling.Score
	v.NVC.Need = f.NVC.Need.Score
	v.NVC.Request = f.NVC.Request.Score
	v.NVC.Total = f.NVC.Total
	v.Emotion.ReadOthers = f.Emotion.ReadOthers.Level
	v.Emotion.SelfManagement = f.Emotion.SelfManagement.Level
	v.Emotion.Relationship = f.Emotion.Relationship.Level
	return v
}

type Progress struct {
	TargetItem string `json:"target_item"`
	Item
	NextAction string `json:"next_action"`
}

type Status string

const (
	Success               Status = "success"
	Failed                Status = "scoring_failed"
	Safety                Status = "safety"
	ModerationUnavailable Status = "moderation_unavailable"
)

// Outcome is internal, not the app wire response. CallID identifies only a
// successful attempt. A terminal and a settlement error can coexist.
type Outcome[T any] struct {
	Status   Status
	Value    *T
	CallID   uuid.UUID
	Terminal *gateway.Terminal
}
