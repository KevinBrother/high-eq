package privacy

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

const SignalWindowRetention = 180 * 24 * time.Hour

type CoordinatorOption func(*Coordinator)

// Use the same durable master in live, retry, and restore processes.
func WithWindowReplayKey(master []byte) CoordinatorOption {
	var key []byte
	if len(master) != 0 {
		mac := hmac.New(sha256.New, master)
		mac.Write([]byte("privacy/signal-window-replay/v1"))
		key = mac.Sum(nil)
	}
	return func(c *Coordinator) { c.windowReplayKey = key }
}

func validSignalWindowKey(user uuid.UUID, channel string, at time.Time) bool {
	return user != uuid.Nil && !at.IsZero() && at.Equal(at.Truncate(30*time.Second)) && (channel == "health" || channel == "voice")
}

func (c *Coordinator) signalWindowReplayID(user uuid.UUID, channel string, at time.Time) (uuid.UUID, error) {
	if len(c.windowReplayKey) == 0 || !validSignalWindowKey(user, channel, at) {
		return uuid.Nil, ErrUnavailable
	}
	mac := hmac.New(sha256.New, c.windowReplayKey)
	mac.Write(user[:])
	mac.Write(binary.BigEndian.AppendUint64(nil, uint64(at.Unix())))
	mac.Write([]byte(channel))
	var id uuid.UUID
	copy(id[:], mac.Sum(nil))
	id[6] = (id[6] & 0x0f) | 0x80 // RFC 9562 custom UUID
	id[8] = (id[8] & 0x3f) | 0x80
	return id, nil
}

// DeleteSignalWindowAuthorized resolves the public tuple after taking the same
// account lock that protects session validation and pending erasure.
func (c *Coordinator) DeleteSignalWindowAuthorized(ctx context.Context, user uuid.UUID, channel string, at time.Time, validate func(pgx.Tx) error) error {
	if len(c.windowReplayKey) == 0 {
		return ErrUnavailable
	}
	if !validSignalWindowKey(user, channel, at) {
		return ErrNotFound
	}
	d := Deletion{OperationID: uuid.New(), UserID: user, Scope: "signal_windows"}
	return c.deleteAuthorized(ctx, d, validate, func(tx pgx.Tx) (uuid.UUID, bool, error) {
		var id uuid.UUID
		err := tx.QueryRow(ctx, `select purge_id from signal_windows where user_id=$1 and channel=$2 and starts_at=$3`, user, channel, at).Scan(&id)
		if errors.Is(err, pgx.ErrNoRows) {
			return uuid.Nil, false, nil
		}
		return id, err == nil, err
	})
}

// SignalWindowDeleted must be checked inside the caller's guarded account
// transaction before inserting a window. All deletion writes use that lock.
func (c *Coordinator) SignalWindowDeleted(ctx context.Context, user uuid.UUID, channel string, at time.Time) (bool, error) {
	id, err := c.signalWindowReplayID(user, channel, at)
	if err != nil {
		return false, err
	}
	return c.ledger.blocked(ctx, []uuid.UUID{id})
}

func (c *Coordinator) markSignalWindowDeleted(ctx context.Context, tx pgx.Tx, d Deletion) error {
	var channel string
	var at time.Time
	err := tx.QueryRow(ctx, `select channel,starts_at from signal_windows where user_id=$1 and purge_id=$2`, d.UserID, d.SourceID).Scan(&channel, &at)
	if err != nil {
		return err
	}
	id, err := c.signalWindowReplayID(d.UserID, channel, at)
	if err != nil {
		return err
	}
	// Keep the original root for snapshots and the logical key for delayed
	// uploads and snapshots with an older random root. Both values are empty.
	return c.ledger.markWindow(ctx, d.SourceID, id, at.Add(SignalWindowRetention))
}
