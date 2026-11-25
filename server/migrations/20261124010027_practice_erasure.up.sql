BEGIN;

-- The public practice ID doubles as the request key. Keep just its
-- account-bound digest so erasure does not turn a retry into a new activity.
CREATE TABLE practice_request_tombstones (
  user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  request_digest bytea NOT NULL CHECK (octet_length(request_digest) = 32),
  PRIMARY KEY(user_id, request_digest)
);

CREATE FUNCTION record_practice_request_tombstone() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM users WHERE id = OLD.user_id) THEN
    INSERT INTO practice_request_tombstones(user_id, request_digest)
    VALUES (OLD.user_id, sha256(uuid_send(OLD.user_id) || uuid_send(OLD.id)))
    ON CONFLICT DO NOTHING;
  END IF;
  RETURN OLD;
END;
$$;

CREATE TRIGGER practice_request_tombstone
BEFORE DELETE ON activities
FOR EACH ROW WHEN (OLD.kind IN ('practice','drill'))
EXECUTE FUNCTION record_practice_request_tombstone();

-- Legacy plans can prove a manual completion without its exact time.
ALTER TABLE daily_plans ADD COLUMN completed_without_timestamp boolean NOT NULL DEFAULT false;

COMMIT;
