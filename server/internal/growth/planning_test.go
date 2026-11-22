package growth

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/assessment"
	"high-eq/server/internal/membership"
)

type testMembership struct {
	err error
}

func (m testMembership) Require(context.Context, pgx.Tx, uuid.UUID, membership.Capability) error {
	return m.err
}

type testProfiles struct {
	calls int
	scene string
	ok    bool
	err   error
}

func (p *testProfiles) AuthorizedScene(context.Context, pgx.Tx, uuid.UUID) (string, bool, error) {
	p.calls++
	return p.scene, p.ok, p.err
}

type testLevels struct {
	levels LevelIDs
	calls  int
	focus  string
	scene  string
}

func (l *testLevels) PlanLevels(_ context.Context, _ pgx.Tx, _ uuid.UUID, focus, scene string) (LevelIDs, error) {
	l.calls++
	l.focus, l.scene = focus, scene
	return l.levels, nil
}

func TestPlanSceneFreeNeverReadsProfile(t *testing.T) {
	user := uuid.New()
	day := "2026-11-22"
	profiles := &testProfiles{scene: "partner", ok: true}
	service := &PlanService{
		Membership: testMembership{err: membership.ErrForbidden},
		Profiles:   profiles,
	}

	scene, personalized, err := service.planScene(context.Background(), nil, user, day, "observation")
	if err != nil {
		t.Fatal(err)
	}
	if profiles.calls != 0 {
		t.Fatalf("free plan read profile %d times", profiles.calls)
	}
	if !validScene(scene) || personalized {
		t.Fatalf("free plan scene=%q personalized=%v", scene, personalized)
	}
	if scene != sceneFor(user, day, "observation") {
		t.Fatalf("free plan did not use deterministic scene: %q", scene)
	}
}

func TestPlanSceneMemberUsesAuthorizedProfile(t *testing.T) {
	user := uuid.New()
	profiles := &testProfiles{scene: "partner", ok: true}
	service := &PlanService{Membership: testMembership{}, Profiles: profiles}

	scene, personalized, err := service.planScene(context.Background(), nil, user, "2026-11-22", "feeling")
	if err != nil {
		t.Fatal(err)
	}
	if profiles.calls != 1 {
		t.Fatalf("member plan read profile %d times", profiles.calls)
	}
	if scene != "partner" || !personalized {
		t.Fatalf("member plan scene=%q personalized=%v", scene, personalized)
	}
}

func TestPlanSceneMembershipFailureDoesNotReadProfile(t *testing.T) {
	boom := errors.New("membership unavailable")
	profiles := &testProfiles{scene: "partner", ok: true}
	service := &PlanService{Membership: testMembership{err: boom}, Profiles: profiles}

	if _, _, err := service.planScene(context.Background(), nil, uuid.New(), "2026-11-22", "need"); !errors.Is(err, boom) {
		t.Fatalf("got %v, want membership failure", err)
	}
	if profiles.calls != 0 {
		t.Fatalf("profile read after membership failure: %d", profiles.calls)
	}
}

func TestListCardsPaginationAndInvalidCursor(t *testing.T) {
	service, err := NewPlanService(PlanDependencies{
		Fields:  testCipher(t),
		Results: noResultReader{},
	})
	if err != nil {
		t.Fatal(err)
	}

	page, err := service.ListCards("work", "", 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Items) != 1 || page.NextCursor == nil {
		t.Fatalf("first page=%+v", page)
	}
	next, err := service.ListCards("work", *page.NextCursor, 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(next.Items) != 1 || next.Items[0].ID == page.Items[0].ID {
		t.Fatalf("next page=%+v after=%+v", next, page.Items[0])
	}

	if _, err = service.ListCards("", "not-a-uuid", 20); !errors.Is(err, ErrInvalid) {
		t.Fatalf("invalid cursor: %v", err)
	}
	if _, err = service.ListCards("invalid", "", 20); !errors.Is(err, ErrInvalid) {
		t.Fatalf("invalid scene: %v", err)
	}
}

type noResultReader struct{}

func (noResultReader) ReadResult(context.Context, pgx.Tx, uuid.UUID, uuid.UUID) (assessment.Result, error) {
	return assessment.Result{}, errors.New("not used")
}

func TestLocalDayUsesAccountTimezone(t *testing.T) {
	at := time.Date(2026, 11, 22, 17, 30, 0, 0, time.UTC)
	day, err := localDay(at, "Asia/Shanghai")
	if err != nil {
		t.Fatal(err)
	}
	if day != "2026-11-23" {
		t.Fatalf("day=%s", day)
	}
}
