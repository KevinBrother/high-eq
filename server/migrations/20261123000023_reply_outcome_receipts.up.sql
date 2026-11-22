BEGIN;
-- Non-profile delivery receipts keep only the opaque source key and suggestion
-- index. Effect, chat and suggestion prose intentionally stay in reply_feedback.
CREATE TABLE reply_outcome_receipts (
  feedback_id uuid PRIMARY KEY REFERENCES reply_feedback(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  source_id uuid NOT NULL REFERENCES activities(source_id) ON DELETE CASCADE,
  source_kind text NOT NULL CHECK(source_kind='reply'),
  occurred_at timestamptz NOT NULL,
  suggestion_index smallint NOT NULL CHECK(suggestion_index BETWEEN 0 AND 2),
  accepted_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX reply_outcome_receipts_user ON reply_outcome_receipts(user_id);
CREATE INDEX reply_outcome_receipts_source ON reply_outcome_receipts(source_id);
COMMIT;
