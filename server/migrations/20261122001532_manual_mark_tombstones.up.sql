BEGIN;
-- Technical replay evidence only. No mark content, timestamps, object, scene,
-- ciphertext or deletion history is retained. Account erasure cascades it.
CREATE TABLE manual_mark_tombstones (
  user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  request_id uuid NOT NULL,
  PRIMARY KEY(user_id, request_id)
);

CREATE FUNCTION record_manual_mark_tombstone() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  -- During account erasure the parent user may already be gone. Skipping the
  -- insert avoids a transient FK while still covering mark, contact, retention
  -- and explicit deletes, where the user remains.
  IF EXISTS (SELECT 1 FROM users WHERE id = OLD.user_id) THEN
    INSERT INTO manual_mark_tombstones(user_id, request_id)
    SELECT user_id, request_id FROM mark_requests
    WHERE user_id = OLD.user_id AND mark_id = OLD.id
    ON CONFLICT DO NOTHING;
  END IF;
  RETURN OLD;
END;
$$;

CREATE TRIGGER manual_mark_tombstone
BEFORE DELETE ON manual_marks
FOR EACH ROW EXECUTE FUNCTION record_manual_mark_tombstone();
COMMIT;
