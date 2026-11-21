BEGIN;
ALTER TABLE assessments ADD COLUMN completion_pending boolean NOT NULL DEFAULT false;
CREATE INDEX assessments_pending_completion ON assessments(id) WHERE completion_pending;
COMMIT;
