BEGIN;
-- Keep the extension on down: it may already be in use by another schema.
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE TABLE manual_marks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  contact_id uuid, accepted_at timestamptz NOT NULL DEFAULT clock_timestamp(), mark_enc bytea NOT NULL, UNIQUE(user_id,id),
  FOREIGN KEY(user_id,contact_id) REFERENCES contacts(user_id,id) ON DELETE CASCADE,
  EXCLUDE USING gist (user_id WITH =, tsrange(accepted_at AT TIME ZONE 'UTC',
    (accepted_at AT TIME ZONE 'UTC') + interval '60 seconds','[)') WITH &&)
);
CREATE INDEX manual_marks_history ON manual_marks(user_id,accepted_at DESC);
CREATE INDEX manual_marks_expiry ON manual_marks(accepted_at);
CREATE TABLE mark_requests (
  user_id uuid NOT NULL, request_id uuid NOT NULL, mark_id uuid NOT NULL,
  PRIMARY KEY(user_id,request_id),
  FOREIGN KEY(user_id,mark_id) REFERENCES manual_marks(user_id,id) ON DELETE CASCADE
);
CREATE INDEX mark_requests_source ON mark_requests(mark_id);
CREATE TABLE signal_windows (
  user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE, starts_at timestamptz NOT NULL,
  channel text NOT NULL CHECK(channel IN ('health','voice')), stats_enc bytea NOT NULL,
  PRIMARY KEY(user_id,channel,starts_at), CHECK (starts_at=date_bin(interval '30 seconds',starts_at,timestamptz '2000-01-01 00:00:00+00'))
);
CREATE INDEX signal_windows_expiry ON signal_windows(starts_at);
CREATE TABLE signal_baselines (
  user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  signal text NOT NULL CHECK(signal IN ('heart_rate','hrv','speech_rate','volume','pitch')),
  baseline_enc bytea NOT NULL, updated_at timestamptz NOT NULL, PRIMARY KEY(user_id,signal)
);
CREATE TABLE signal_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  contact_id uuid, occurred_at timestamptz NOT NULL, event_enc bytea NOT NULL,
  FOREIGN KEY(user_id,contact_id) REFERENCES contacts(user_id,id) ON DELETE CASCADE
);
CREATE INDEX signal_events_history ON signal_events(user_id,occurred_at DESC);
CREATE INDEX signal_events_expiry ON signal_events(occurred_at);
COMMIT;
