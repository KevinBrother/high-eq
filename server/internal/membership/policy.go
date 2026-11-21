// Package membership gates operations inside the caller's account-locked transaction.
package membership

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"slices"
	"time"
	_ "time/tzdata" // scratch runtime has no zoneinfo directory

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/redis/go-redis/v9"

	"high-eq/server/internal/api/app"
)

type Capability string

const (
	Assessment     Capability = "assessment"
	Radar          Capability = "radar"
	Exercise       Capability = "exercise"
	Card           Capability = "card"
	GenericPlan    Capability = "generic_plan"
	ManualMark     Capability = "manual_mark"
	History        Capability = "history"
	Collection     Capability = "collection"
	AlignedReplay  Capability = "aligned_replay"
	EmotionSummary Capability = "emotion_summary"
	PersonalPlan   Capability = "personal_plan"
	WatchAlert     Capability = "watch_alert"
)

var (
	ErrForbidden = errors.New("capability unavailable")
	ErrLimit     = errors.New("daily allowance exhausted")
	ErrConflict  = errors.New("stale or invalid quota operation")
)
var features = []string{"practice", "reply", "review"}

//go:embed policy.json
var defaults []byte

type tier struct {
	Daily    map[string]*int
	Contacts *int
	Allow    []Capability
}

func (t tier) allows(c Capability) bool { return slices.Contains(t.Allow, c) }

type policy struct {
	Free, Member tier
	LeaseSeconds int `json:"lease_seconds"`
}
type Service struct {
	cache  *redis.Client
	policy policy
	now    func() time.Time
}

func New(cache *redis.Client) (*Service, error) {
	s := &Service{cache: cache, now: time.Now}
	if err := json.Unmarshal(defaults, &s.policy); err != nil {
		return nil, err
	}
	for _, t := range []tier{s.policy.Free, s.policy.Member} {
		for _, f := range features {
			if n, ok := t.Daily[f]; !ok || (n != nil && *n < 0) {
				return nil, errors.New("invalid daily policy")
			}
		}
		if t.Contacts != nil && *t.Contacts < 0 {
			return nil, errors.New("invalid contact limit")
		}
	}
	if s.policy.LeaseSeconds <= 0 {
		return nil, errors.New("invalid lease period")
	}
	return s, nil
}
func dayWindow(at time.Time, zone string) (string, time.Time, error) {
	loc, e := time.LoadLocation(zone)
	if e != nil {
		return "", time.Time{}, e
	}
	local := at.In(loc)
	day := local.Format(time.DateOnly)
	// Compute midnight in the current UTC offset. If the zone changes first,
	// inspect the transition itself (midnight can be skipped or repeated).
	for {
		y, m, d := local.Date()
		_, offset := local.Zone()
		next := time.Date(y, m, d+1, 0, 0, 0, 0, time.UTC).Add(-time.Duration(offset) * time.Second).In(loc)
		_, boundary := local.ZoneBounds()
		if !boundary.After(local) || next.Before(boundary) {
			return day, next, nil
		}
		if boundary.Format(time.DateOnly) != day {
			return day, boundary, nil
		}
		local = boundary
	}
}

type access struct {
	tier
	member bool
	end    *time.Time
	day    string
	reset  time.Time
	at     time.Time
}

func (s *Service) access(ctx context.Context, tx pgx.Tx, user uuid.UUID) (access, error) {
	a := access{tier: s.policy.Free, at: s.now()}
	var zone string
	// Merge adjoining verified periods so expires_at is the end of continuous access, not the next billing boundary.
	e := tx.QueryRow(ctx, `select timezone, (
        select upper(r) from unnest((
            select range_agg(tstzrange(starts_at, ends_at, '[)'))
            from entitlements e join orders o on o.id=e.order_id
            where e.user_id=u.id and o.state='paid'
        )) r where r @> $2::timestamptz
    ) from users u where id=$1 and closure_requested_at is null`, user, a.at).Scan(&zone, &a.end)
	if e != nil {
		return a, e
	}
	if a.end != nil {
		a.tier = s.policy.Member
		a.member = true
	}
	a.day, a.reset, e = dayWindow(a.at, zone)
	return a, e
}

// Require does not inspect AI quota. Use at each protected read/write, not just at login.
func (s *Service) Require(ctx context.Context, tx pgx.Tx, user uuid.UUID, c Capability) error {
	// WithSession/Access already checked ownership, freeze and erasure. Do not
	// make an all-tier feature depend on membership storage or AI quota.
	if s.policy.Free.allows(c) && s.policy.Member.allows(c) {
		return nil
	}
	a, e := s.access(ctx, tx, user)
	if e == nil && !a.allows(c) {
		return ErrForbidden
	}
	return e
}
func (s *Service) Entitlements(ctx context.Context, tx pgx.Tx, user uuid.UUID) (app.Entitlements, error) {
	var out app.Entitlements
	a, e := s.access(ctx, tx, user)
	if e != nil {
		return out, e
	}
	out.Tier = "free"
	if a.member {
		out.Tier = "member"
	}
	out.ExpiresAt = a.end
	out.MaxActiveContacts = a.Contacts
	out.AutoWatchAlertAvailable = a.allows(WatchAlert)
	for _, f := range features {
		v := app.Allowance{Feature: app.AllowanceFeature(f), ResetsAt: a.reset}
		if limit := a.Daily[f]; limit != nil {
			n, e := s.capacity(ctx, tx, user, f, a, uuid.Nil, false)
			if e != nil {
				return out, e
			}
			v.Remaining = &n
		}
		out.Allowances = append(out.Allowances, v)
	}
	return out, nil
}
