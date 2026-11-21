BEGIN;
DROP VIEW erasure_roots;
ALTER VIEW erasure_roots_before_emotion RENAME TO erasure_roots;
DROP INDEX signal_events_pending;
ALTER TABLE signal_events DROP COLUMN feedback_pending;
ALTER TABLE signal_windows DROP COLUMN purge_id;
COMMIT;
