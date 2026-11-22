BEGIN;
DROP TRIGGER manual_mark_tombstone ON manual_marks;
DROP FUNCTION record_manual_mark_tombstone();
DROP TABLE manual_mark_tombstones;
COMMIT;
