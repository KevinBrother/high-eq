BEGIN;
DROP INDEX assessments_pending_completion;
ALTER TABLE assessments DROP COLUMN completion_pending;
COMMIT;
