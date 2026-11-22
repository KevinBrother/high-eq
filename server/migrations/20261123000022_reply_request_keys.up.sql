BEGIN;
-- Keep only the non-content idempotency key after a reply source is erased. The
-- nullable activity reference becomes NULL when the activity is deleted, so a
-- delayed retry cannot allocate a fresh activity and charge the account again.
CREATE TABLE reply_request_keys (
  user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  request_id uuid NOT NULL,
  input_mac bytea NOT NULL CHECK(octet_length(input_mac)=32),
  activity_id uuid UNIQUE REFERENCES activities ON DELETE SET NULL,
  PRIMARY KEY(user_id,request_id)
);
INSERT INTO reply_request_keys(user_id,request_id,input_mac,activity_id)
SELECT user_id,request_id,input_mac,activity_id FROM reply_requests;
COMMIT;
