package profile

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/emotion"
	"high-eq/server/internal/events"
	"high-eq/server/internal/fieldcrypt"
)

// Transaction double supplies a canonical encrypted source, not a pre-decided verdict.
// Any unexpected query or write fails. The integration suite repeats this against PG.
type scanFn func(...any) error

func (f scanFn) Scan(v ...any) error { return f(v...) }

type sourceFixture struct {
	pgx.Tx
	t         *testing.T
	owner, id uuid.UUID
	source    []byte
	writes    int
}

func (f *sourceFixture) QueryRow(_ context.Context, q string, args ...any) pgx.Row {
	return scanFn(func(out ...any) error {
		switch {
		case strings.Contains(q, "from activities"):
			return pgx.ErrNoRows
		case strings.Contains(q, "from signal_events"):
			if args[0] != f.owner || args[1] != f.id || f.source == nil {
				return pgx.ErrNoRows
			}
			*out[0].(*[]byte) = f.source
			return nil
		case strings.Contains(q, "from consents"):
			*out[0].(*bool) = true
			return nil
		}
		f.t.Fatalf("unexpected source query: %s", q)
		return nil
	})
}
func (f *sourceFixture) Exec(_ context.Context, q string, _ ...any) (pgconn.CommandTag, error) {
	if !strings.HasPrefix(q, "insert into profile_observations") {
		f.t.Fatal("unexpected write")
	}
	f.writes++
	return pgconn.NewCommandTag("INSERT 0 1"), nil
}
func TestSyntheticAttribution(t *testing.T) {
	ctx := context.Background()
	fields, e := fieldcrypt.New(1, map[uint32][]byte{1: make([]byte, 32)})
	if e != nil {
		t.Fatal(e)
	}
	s := Service{Fields: fields}
	a, b := uuid.New(), uuid.New()
	now := time.Now().UTC()
	for _, tc := range []struct {
		kind, confirmation string
		ok                 bool
	}{{"manual_mark", "yes", false}, {"conversation_rhythm", "yes", false}, {"self_fluctuation", "pending", false}, {"self_fluctuation", "no", true}, {"self_fluctuation", "yes", true}} {
		t.Run(tc.kind+tc.confirmation, func(t *testing.T) {
			f := &sourceFixture{t: t, owner: a, id: uuid.New()}
			r := emotion.FeedbackSource{SignalEvent: app.SignalEvent{Kind: app.SignalEventKind(tc.kind), Confirmation: app.SignalEventConfirmation(tc.confirmation), Id: f.id}, ConfirmedAt: &now, FeedbackID: uuid.New()}
			if tc.kind != "manual_mark" {
				f.source, e = s.seal("event", a, f.id, r)
				if e != nil {
					t.Fatal(e)
				}
			}
			in := app.SendProfileFeedbackInput{Confirmed: true, SourceId: f.id, Subject: "self"}
			if e := s.Explicit(ctx, f, b, in); e == nil || f.writes != 0 {
				t.Fatal("other synthetic account accepted")
			}
			forged := events.Feedback{UserID: a, SourceID: f.id, SourceKind: "self_event", Subject: "self", FeedbackID: uuid.New(), OccurredAt: now}
			if e := s.Consume(ctx, f, forged); e == nil || f.writes != 0 {
				t.Fatal("unverified event accepted")
			}
			if e := s.Explicit(ctx, f, a, in); (e == nil) != tc.ok || (f.writes == 1) != tc.ok {
				t.Fatal("unexpected attribution", e, f.writes)
			}
			if r.Positive() != (tc.kind == "self_fluctuation" && tc.confirmation == "yes") {
				t.Fatal("negative confirmation promoted")
			}
		})
	}
}
func TestSafeOutputVocabulary(t *testing.T) {
	bad := strings.Split("一定 绝对 肯定 必然 总是 每次都 毫无例外 永远 从不 从来不 天生 注定 必定 百分之百 100% 人格障碍 抑郁症 躁郁症 双相 精神病 焦虑症 自恋狂 控制狂 有病 诊断 确诊", " ")
	for i, a := range axes {
		for j := range a.options {
			d := dossier{Scene: "partner"}
			d.Answers[i] = j + 1
			b, _ := json.Marshal(d.render(nil))
			for _, word := range bad {
				if strings.Contains(string(b), word) {
					t.Fatal(i, j, word)
				}
			}
		}
	}
	for _, bad := range []string{`{"choices":[1,1,1,1,1,4,1]}`, `{"choices":[1,1,1,null,1,1,0]}`, `{"choices":[1,1,1,1,1,1,0],"summary":"诊断"}`, `{"choices":[9]}`} {
		if _, e := decodeChoices([]byte(bad), "work"); e == nil {
			t.Fatal("accepted unsafe model object")
		}
	}
	if _, e := decodeChoices([]byte(`{"choices":[1,2,1,2,0,4,0]}`), "work"); e != nil {
		t.Fatal(e)
	}
}
