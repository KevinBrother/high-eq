BEGIN;
-- One root per practice session, drill, assistant request or review. The client reuses this ID on retry.
CREATE TYPE activity_kind AS ENUM ('practice','drill','reply','review');
CREATE TABLE activities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  source_id uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(),
  kind activity_kind NOT NULL, contact_id uuid, created_at timestamptz NOT NULL DEFAULT now(),
  state text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending','active','complete','exited','safety','moderation_unavailable','failed')),
  content_enc bytea, UNIQUE(id,kind,source_id), UNIQUE(id,kind), UNIQUE(user_id,id),
  FOREIGN KEY(user_id,contact_id) REFERENCES contacts(user_id,id) ON DELETE CASCADE
);
CREATE INDEX activities_history ON activities(user_id,kind,created_at DESC);
CREATE INDEX activities_contact ON activities(contact_id) WHERE contact_id IS NOT NULL;
CREATE TABLE practice_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), activity_id uuid NOT NULL,
  kind activity_kind NOT NULL CHECK (kind IN ('practice','drill')),
  client_message_id uuid NOT NULL, seq integer NOT NULL CHECK(seq>0),
  role text NOT NULL CHECK (role IN ('user','assistant')), content_enc bytea NOT NULL,
  FOREIGN KEY(activity_id,kind) REFERENCES activities(id,kind) ON DELETE CASCADE,
  UNIQUE(activity_id,seq), UNIQUE(activity_id,client_message_id,role)
);
-- Input is separate from the approved answer so the 24h cleanup never drops the idempotency key.
CREATE TABLE chat_imports (
  activity_id uuid PRIMARY KEY REFERENCES activities ON DELETE CASCADE,
  received_at timestamptz NOT NULL DEFAULT now(), original_enc bytea NOT NULL
);
CREATE INDEX chat_imports_expiry ON chat_imports(received_at);
CREATE TABLE quota_ledger (
  activity_id uuid PRIMARY KEY REFERENCES activities ON DELETE CASCADE,
  charged_day date NOT NULL, charged_at timestamptz NOT NULL, refunded_at timestamptz CHECK(refunded_at >= charged_at)
);
-- Only daily totals survive single-source erasure; no message or source IDs here.
CREATE TABLE daily_quota_usage (
  user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  feature text NOT NULL CHECK(feature IN ('practice','reply','review')),
  charged_day date NOT NULL, used integer NOT NULL CHECK(used>=0), PRIMARY KEY(user_id,feature,charged_day)
);
CREATE TABLE scores (
  id uuid PRIMARY KEY, -- allocated before generation, never replaced on retry
  activity_id uuid NOT NULL UNIQUE, activity_kind activity_kind NOT NULL CHECK (activity_kind <> 'reply'),
  detail_enc bytea NOT NULL, occurred_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(id,activity_kind), UNIQUE(activity_id,id),
  FOREIGN KEY(activity_id,activity_kind,id) REFERENCES activities(id,kind,source_id) ON DELETE CASCADE
);
CREATE TABLE growth_scores (
  score_id uuid PRIMARY KEY, kind activity_kind NOT NULL CHECK(kind IN ('practice','review')),
  nvc_enc bytea NOT NULL, emotion_enc bytea NOT NULL,
  FOREIGN KEY(score_id,kind) REFERENCES scores(id,activity_kind) ON DELETE CASCADE
);
CREATE TABLE drill_progress (
  activity_id uuid PRIMARY KEY, kind activity_kind NOT NULL DEFAULT 'drill' CHECK (kind='drill'),
  target_item text NOT NULL CHECK(target_item IN ('observation','feeling','need','request')),
  progress_enc bytea NOT NULL, retry_at timestamptz,
  FOREIGN KEY(activity_id,kind) REFERENCES activities(id,kind) ON DELETE CASCADE
);
CREATE TABLE daily_plans (
  user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE, plan_day date NOT NULL,
  plan_enc bytea NOT NULL, completed_at timestamptz, PRIMARY KEY(user_id,plan_day)
);
COMMIT;
