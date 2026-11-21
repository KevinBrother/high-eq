BEGIN;
CREATE TABLE admin_accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), login text NOT NULL UNIQUE,
  password_hash bytea NOT NULL, role text NOT NULL CHECK (role IN ('operator','super_admin'))
);
CREATE TABLE admin_sessions (
  token_hash bytea PRIMARY KEY CHECK(octet_length(token_hash)=32),
  admin_id uuid NOT NULL REFERENCES admin_accounts ON DELETE CASCADE, expires_at timestamptz NOT NULL
);
CREATE INDEX admin_sessions_actor ON admin_sessions(admin_id);
CREATE TABLE admin_audit_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  actor_id uuid NOT NULL, action text NOT NULL, target text NOT NULL,
  result text NOT NULL CHECK(result IN ('ok','denied','failed'))
);
CREATE INDEX admin_audit_time ON admin_audit_logs(occurred_at DESC,id DESC);
CREATE INDEX admin_audit_actor ON admin_audit_logs(actor_id,occurred_at DESC,id DESC);
COMMIT;
