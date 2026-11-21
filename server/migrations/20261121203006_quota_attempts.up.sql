BEGIN;
-- Source ownership/kind remain on the activity. Tokens fence delayed workers after retry.
CREATE TABLE quota_attempts (
 activity_id uuid PRIMARY KEY REFERENCES activities ON DELETE CASCADE,
 token uuid NOT NULL, state text NOT NULL CHECK (state IN ('held','accepted','complete','exited','failed','safety','moderation_unavailable')),
 held_day date NOT NULL, valid_until timestamptz NOT NULL, metered boolean NOT NULL
);
CREATE INDEX quota_live_holds ON quota_attempts(held_day,activity_id) WHERE state='held' AND metered;
COMMIT;
