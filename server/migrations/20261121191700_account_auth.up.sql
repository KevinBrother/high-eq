BEGIN;
CREATE TABLE auth_sessions (
 id uuid PRIMARY KEY, user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
 refresh_hash bytea NOT NULL UNIQUE, expires_at timestamptz NOT NULL
);
CREATE INDEX auth_sessions_owner ON auth_sessions(user_id);
CREATE INDEX auth_sessions_expiry ON auth_sessions(expires_at);
CREATE INDEX consents_latest_decision ON consents(user_id,purpose,granted_at DESC,id DESC);
CREATE INDEX users_pending_closure ON users(closure_requested_at) WHERE closure_requested_at IS NOT NULL;
-- Registration challenges predate an account. Store no phone or readable code.
CREATE TABLE sms_challenges (
 phone_hmac bytea PRIMARY KEY, sent_at timestamptz NOT NULL, quota_day date NOT NULL,
 sends integer NOT NULL CHECK(sends BETWEEN 1 AND 10), otp_hash bytea, attempts integer NOT NULL
);
CREATE INDEX sms_expiry ON sms_challenges(sent_at);
CREATE FUNCTION forget_bound_sms() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF OLD.provider='phone' THEN DELETE FROM sms_challenges WHERE phone_hmac=OLD.subject_hmac; END IF;
 RETURN OLD;
END $$;
CREATE TRIGGER forget_bound_sms AFTER DELETE ON login_identities FOR EACH ROW EXECUTE FUNCTION forget_bound_sms();
COMMIT;
