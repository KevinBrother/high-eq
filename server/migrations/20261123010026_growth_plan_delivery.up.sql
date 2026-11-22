BEGIN;
ALTER TABLE daily_plans
  ADD COLUMN assessment_id uuid REFERENCES assessments(id) ON DELETE CASCADE;

CREATE INDEX daily_plans_completion
  ON daily_plans(user_id, completed_at)
  WHERE completed_at IS NOT NULL;
CREATE INDEX daily_plans_assessment
  ON daily_plans(user_id, assessment_id)
  WHERE assessment_id IS NOT NULL;

-- T26 owns this scheduling projection. T19 drill_progress remains the
-- canonical encrypted skill history and is never rewritten by plan delivery.
-- The exact score and band live only in schedule_enc; the plaintext columns are
-- opaque scheduling metadata. closed_at is a durable terminal fact so replaying
-- an older completion can never resurrect a cleared three-day retry.
CREATE TABLE growth_drill_schedules (
  activity_id uuid PRIMARY KEY REFERENCES activities ON DELETE CASCADE,
  target_item text NOT NULL CHECK (
    target_item IN ('observation','feeling','need','request')
  ),
  level_id uuid NOT NULL,
  schedule_enc bytea NOT NULL,
  occurred_at timestamptz NOT NULL,
  retry_at timestamptz,
  closed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX growth_drill_schedules_due
  ON growth_drill_schedules(retry_at,activity_id)
  WHERE retry_at IS NOT NULL AND closed_at IS NULL;
CREATE INDEX growth_drill_schedules_level
  ON growth_drill_schedules(level_id,target_item,occurred_at);
COMMIT;
