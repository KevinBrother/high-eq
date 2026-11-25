BEGIN;
ALTER TABLE daily_plans DROP COLUMN completed_without_timestamp;
DROP TRIGGER practice_request_tombstone ON activities;
DROP FUNCTION record_practice_request_tombstone();
DROP TABLE practice_request_tombstones;
COMMIT;
