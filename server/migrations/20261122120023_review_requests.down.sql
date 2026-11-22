BEGIN;
-- Losing live idempotency mappings or tombstones would make encrypted journals
-- unreachable or allow deleted request IDs to be reused. Roll back the
-- application/release instead; only empty installations downgrade.
LOCK TABLE review_requests, review_tombstones IN ACCESS EXCLUSIVE MODE;
DO $$ BEGIN
 IF EXISTS (SELECT FROM review_requests) OR EXISTS (SELECT FROM review_tombstones) THEN
  RAISE EXCEPTION 'cannot drop non-empty review request inventory';
 END IF;
END $$;
DROP TRIGGER review_tombstone_activity ON activities;
DROP TRIGGER review_request_tombstone_guard ON review_requests;
DROP TRIGGER review_tombstone_account_cleanup_before ON users;
DROP TRIGGER review_tombstone_account_cleanup_after ON users;
DROP FUNCTION review_tombstone_activity();
DROP FUNCTION review_request_tombstone_guard();
DROP FUNCTION review_tombstone_account_cleanup();
DROP TABLE review_tombstones;
DROP TABLE review_requests;
-- T11 historical versions are immutable; do not erase a published template.
COMMIT;
