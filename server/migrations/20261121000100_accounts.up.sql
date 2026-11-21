BEGIN;
CREATE TABLE users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  purge_id uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(), -- opaque key for isolated restore
  timezone text NOT NULL DEFAULT 'Asia/Shanghai',
  age_confirmed_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  closure_requested_at timestamptz,
  app_account_token uuid UNIQUE NOT NULL DEFAULT gen_random_uuid()
);
CREATE TABLE login_identities (
  provider text NOT NULL CHECK (provider IN ('phone','apple','wechat')),
  subject_hmac bytea NOT NULL, subject_enc bytea NOT NULL,
  user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  PRIMARY KEY (provider,subject_hmac), UNIQUE (user_id,provider)
);
CREATE TABLE consents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  purpose text NOT NULL, version text NOT NULL, granted_at timestamptz NOT NULL DEFAULT now(),
  withdrawn_at timestamptz CHECK (withdrawn_at >= granted_at)
);
CREATE UNIQUE INDEX consents_active ON consents(user_id,purpose) WHERE withdrawn_at IS NULL;
CREATE TABLE orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid REFERENCES users ON DELETE SET NULL,
  platform text NOT NULL CHECK (platform IN ('apple','wechat','alipay')), transaction_hmac bytea NOT NULL,
  product_code text NOT NULL, amount_fen integer NOT NULL CHECK (amount_fen >= 0),
  state text NOT NULL CHECK (state IN ('pending','paid','expired','refunded')),
  created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(platform,transaction_hmac), UNIQUE(id,user_id)
);
CREATE INDEX orders_owner ON orders(user_id);
CREATE TABLE entitlements (
  order_id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  starts_at timestamptz NOT NULL, ends_at timestamptz NOT NULL CHECK (ends_at > starts_at),
  FOREIGN KEY(order_id,user_id) REFERENCES orders(id,user_id) ON DELETE CASCADE
);
CREATE INDEX entitlements_range ON entitlements(user_id,ends_at);
CREATE TABLE assessments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  instrument_version text NOT NULL, answers_enc bytea NOT NULL, scores_enc bytea NOT NULL,
  completed_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX assessments_latest ON assessments(user_id,completed_at DESC);
CREATE TABLE contacts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  profile_enc bytea NOT NULL, last_used_at timestamptz, UNIQUE(user_id,id)
);
CREATE TABLE personal_profiles (
  user_id uuid PRIMARY KEY REFERENCES users ON DELETE CASCADE, profile_enc bytea NOT NULL, updated_at timestamptz NOT NULL
);
COMMIT;
