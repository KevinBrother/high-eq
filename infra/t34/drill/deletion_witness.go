package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/redis/go-redis/v9"
	"high-eq/server/internal/emotion"
	"high-eq/server/internal/privacy"
)

const windowChannel = "health"

func fixtureWindow(at time.Time) emotion.Window {
	val, n, ex := 75., 30, false
	return emotion.Window{
		At: at, Channel: windowChannel, Source: "apple_history", Duration: 30, Exercise: &ex,
		Heart: &emotion.Stat{Mean: &val, Maximum: &val, Count: 3, Seconds: &n},
	}
}

// Derive the expected UUID independently of the coordinator's Redis writes.
// This uses the stored tuple and the same domain and byte encoding as T35.
func replayRoot(master []byte, user uuid.UUID, channel string, at time.Time) uuid.UUID {
	domain := hmac.New(sha256.New, master)
	domain.Write([]byte("privacy/signal-window-replay/v1"))
	mac := hmac.New(sha256.New, domain.Sum(nil))
	mac.Write(user[:])
	mac.Write(binary.BigEndian.AppendUint64(nil, uint64(at.Unix())))
	mac.Write([]byte(channel))
	var root uuid.UUID
	copy(root[:], mac.Sum(nil))
	root[6] = root[6]&0x0f | 0x80
	root[8] = root[8]&0x3f | 0x80
	return root
}

func (f *fixture) captureDeletionRoots(key []byte) {
	var channel string
	var startsAt time.Time
	must(db.QueryRow(ctx, `select channel, starts_at from signal_windows where user_id=$1 and purge_id=$2`,
		f.A.UserId, f.Windows[0]).Scan(&channel, &startsAt))
	logical := replayRoot(key, f.A.UserId, channel, startsAt).String()
	physical := f.Windows[0].String()
	cutoff := startsAt.Add(privacy.SignalWindowRetention).UnixMilli()
	f.WindowCutoffs = map[string]int64{physical: cutoff, logical: cutoff}
	f.Expected = append([]string{f.AssessmentID.String(), f.DrillSource.String(), f.Sources[0].String(),
		physical, logical}, f.AccountRoots...)
}

type deletionWitness struct {
	Seal string `json:"seal"`
	// Each value is [Redis time before, Redis time after, upload cutoff or zero].
	Writes map[string][3]int64 `json:"writes"`
}

func (w deletionWitness) observe(r *redis.Client, floors map[string]int64, ids []string, delete func()) {
	before, err := r.Time(ctx).Result()
	must(err)
	delete()
	after, err := r.Time(ctx).Result()
	must(err)
	for _, id := range ids {
		_, duplicate := w.Writes[id]
		require(!duplicate && before.UnixMilli() <= after.UnixMilli())
		w.Writes[id] = [3]int64{before.UnixMilli(), after.UnixMilli(), floors[id]}
	}
}

func (f fixture) delete(r *redis.Client) deletionWitness {
	w := deletionWitness{Seal: f.Seal, Writes: make(map[string][3]int64)}
	for _, target := range []struct {
		scope string
		id    uuid.UUID
	}{
		{"assessments", f.AssessmentID},
		{"sessions", f.DrillSource},
		{"reviews", f.Sources[0]},
	} {
		w.observe(r, nil, []string{target.id.String()}, func() { f.erase(target.scope, target.id) })
	}
	var windows []string
	for root := range f.WindowCutoffs {
		windows = append(windows, root)
	}
	w.observe(r, f.WindowCutoffs, windows, func() { f.erase("signal_windows", f.Windows[0]) })
	exec(`update users set closure_requested_at=now()-interval '361 hours' where id=$1`, f.B.UserId)
	w.observe(r, nil, f.AccountRoots, func() { must(auth.PurgeDue(ctx)) })
	return w
}

func (f fixture) verifyWindowReplay() {
	window := fixtureWindow(f.At.Truncate(30 * time.Second))
	err := data.Access(ctx, f.A.UserId, func(tx pgx.Tx) error {
		return signals.Upload(ctx, tx, f.A.UserId, window, time.Now())
	})
	require(errors.Is(err, emotion.WindowDeleted))
	var exists bool
	must(db.QueryRow(ctx, `select exists(select 1 from signal_windows where user_id=$1 and channel=$2 and starts_at=$3)`,
		f.A.UserId, window.Channel, window.At).Scan(&exists))
	require(!exists)
}

type windowReplayPlan struct {
	Physical uuid.UUID `json:"physical"`
	Logical  uuid.UUID `json:"logical"`
	Cutoff   int64     `json:"cutoff_ms"`
}

func (f fixture) windowReplayPlan(key []byte) windowReplayPlan {
	at := f.At.Truncate(30 * time.Second)
	plan := windowReplayPlan{
		Logical: replayRoot(key, f.A.UserId, windowChannel, at),
		Cutoff:  at.Add(privacy.SignalWindowRetention).UnixMilli(),
	}
	require(f.WindowCutoffs[f.Windows[0].String()] == plan.Cutoff &&
		f.WindowCutoffs[plan.Logical.String()] == plan.Cutoff)
	var encrypted []byte
	must(db.QueryRow(ctx, `
		select w.purge_id,w.stats_enc from signal_windows w
		join erasure_roots r on r.user_id=w.user_id and r.root_id=w.purge_id and r.scope='signal_windows'
		where w.user_id=$1 and w.channel=$2 and w.starts_at=$3`,
		f.A.UserId, windowChannel, at).Scan(&plan.Physical, &encrypted))
	require(plan.Physical.Version() == 4)
	aad := []byte("window/" + f.A.UserId.String() + "/" + plan.Physical.String())
	plain, err := fields.Open(encrypted, aad)
	must(err)
	var window emotion.Window
	must(json.Unmarshal(plain, &window))
	require(window.At.Equal(at) && window.Channel == windowChannel)
	return plan
}

type replayObservation struct {
	Window windowReplayPlan `json:"window"`
	Before int64            `json:"before_ms"`
	After  int64            `json:"after_ms"`
}

func (f fixture) restore(r *redis.Client, key []byte) replayObservation {
	plan := f.windowReplayPlan(key)
	for _, root := range f.Expected {
		require(plan.Physical == f.Windows[0] || plan.Physical.String() != root)
	}
	f.Windows[0] = plan.Physical
	// Prove the archive was pre-delete, not an empty or already scrubbed database.
	f.counts(true)
	if f.ChatImports != nil {
		f.ChatImports.checkStored(true)
	}
	before, err := r.Time(ctx).Result()
	must(err)
	must(data.Resume(ctx))
	must(auth.PurgeDue(ctx))
	after, err := r.Time(ctx).Result()
	must(err)
	f.verify()
	return replayObservation{Window: plan, Before: before.UnixMilli(), After: after.UnixMilli()}
}
