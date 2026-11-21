BEGIN;
CREATE TYPE ai_task AS ENUM ('role_play','reply_suggestion','scoring','profile_inference','review_analysis','content_generation','classification');
CREATE TABLE model_configs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text NOT NULL, endpoint text NOT NULL,
  api_key_enc bytea NOT NULL, admission_ref text, enabled boolean NOT NULL DEFAULT false,
  CHECK (NOT enabled OR nullif(trim(admission_ref),'') IS NOT NULL)
);
CREATE TABLE model_routes (
  task ai_task PRIMARY KEY, primary_model uuid NOT NULL REFERENCES model_configs,
  fallback_model uuid NOT NULL REFERENCES model_configs, canary_model uuid REFERENCES model_configs,
  canary_percent smallint NOT NULL DEFAULT 0 CHECK (canary_percent BETWEEN 0 AND 100),
  CHECK(primary_model <> fallback_model), CHECK(canary_percent=0 OR canary_model IS NOT NULL)
);
CREATE TABLE prompt_versions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), task ai_task NOT NULL, version integer NOT NULL CHECK(version>0),
  template text NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(task,version)
);
CREATE TABLE ai_calls (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), activity_id uuid REFERENCES activities ON DELETE CASCADE,
  user_id uuid REFERENCES users ON DELETE CASCADE, contact_id uuid,
  score_id uuid, model_id uuid NOT NULL REFERENCES model_configs, task ai_task NOT NULL,
  prompt_version_id uuid REFERENCES prompt_versions, started_at timestamptz NOT NULL DEFAULT now(),
  outcome text NOT NULL CHECK(outcome IN ('ok','timeout','safety','moderation_unavailable','failed')),
  latency_ms integer CHECK(latency_ms>=0), input_tokens integer CHECK(input_tokens>=0),
  output_tokens integer CHECK(output_tokens>=0), cost_cny numeric(16,8) CHECK(cost_cny>=0),
  CHECK(contact_id IS NULL OR user_id IS NOT NULL),
  FOREIGN KEY(user_id,contact_id) REFERENCES contacts(user_id,id) ON DELETE CASCADE,
  FOREIGN KEY(user_id,activity_id) REFERENCES activities(user_id,id) ON DELETE CASCADE,
  CHECK(score_id IS NULL OR activity_id IS NOT NULL),
  FOREIGN KEY(activity_id,score_id) REFERENCES scores(activity_id,id) ON DELETE CASCADE
);
CREATE INDEX ai_calls_source ON ai_calls(activity_id,score_id);
CREATE INDEX ai_calls_dashboard ON ai_calls(task,model_id,started_at);
COMMIT;
