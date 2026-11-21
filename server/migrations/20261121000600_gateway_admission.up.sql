BEGIN;
-- Presence is an operator's approval, not a vendor claim. No providers are seeded.
CREATE TABLE provider_admissions (
  ref text PRIMARY KEY CHECK (ref ~ '[^[:space:]]'),
  provider text NOT NULL CHECK (provider ~ '[^[:space:]]'),
  endpoint text NOT NULL CHECK (endpoint ~ '^https://[A-Za-z0-9.:-]+(/[A-Za-z0-9._~/-]*)?$' AND endpoint !~ '/\.{1,2}(/|$)'),
  model_scope text NOT NULL CHECK (model_scope ~ '[^[:space:]]'), -- '*' only for endpoint-wide contracts
  kind text NOT NULL CHECK (kind IN ('model','moderation')),
  purpose text NOT NULL CHECK (purpose ~ '[^[:space:]]'),
  sent_fields text[] NOT NULL CHECK (sent_fields @> ARRAY['model','messages.role','messages.content','stream','response_format.type']),
  processing_country text NOT NULL CHECK (processing_country='CN'),
  storage_country text NOT NULL CHECK (storage_country='CN'),
  cross_border boolean NOT NULL CHECK (NOT cross_border),
  max_retention_days integer NOT NULL CHECK (max_retention_days >= 0),
  deletion_method text NOT NULL CHECK (deletion_method ~ '[^[:space:]]'),
  terms_evidence text NOT NULL CHECK (terms_evidence ~ '[^[:space:]]'),
  UNIQUE(ref, provider, endpoint, kind, model_scope)
);
-- Old string references did not attest to any of these facts.
UPDATE model_configs SET enabled=false WHERE enabled;
ALTER TABLE model_configs
  ADD provider text NOT NULL DEFAULT '', ADD model_name text NOT NULL DEFAULT '',
  ADD protocol text NOT NULL DEFAULT 'openai_compatible',
  ADD kind text NOT NULL DEFAULT 'model' CHECK(kind IN ('model','moderation')),
  ADD admitted_model text NOT NULL DEFAULT '*',
  ADD CHECK (NOT enabled OR admitted_model IN ('*',model_name)),
  ADD active_ref text GENERATED ALWAYS AS (CASE WHEN enabled THEN admission_ref END) STORED,
  ADD CHECK (NOT enabled OR (model_name ~ '[^[:space:]]' AND octet_length(api_key_enc) > 32)),
  ADD FOREIGN KEY(active_ref,provider,endpoint,kind,admitted_model) REFERENCES provider_admissions(ref,provider,endpoint,kind,model_scope);
-- The version is transactional, including changes made outside the admin service.
CREATE TABLE gateway_revision (singleton boolean PRIMARY KEY CHECK(singleton), version uuid NOT NULL DEFAULT gen_random_uuid());
INSERT INTO gateway_revision(singleton) VALUES(true);
CREATE FUNCTION bump_gateway_revision() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN UPDATE gateway_revision SET version=gen_random_uuid(); RETURN NULL; END $$;
CREATE TRIGGER model_config_changed AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON model_configs FOR EACH STATEMENT EXECUTE FUNCTION bump_gateway_revision();
CREATE TRIGGER admission_changed AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON provider_admissions FOR EACH STATEMENT EXECUTE FUNCTION bump_gateway_revision();
COMMIT;
