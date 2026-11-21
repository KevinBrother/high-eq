BEGIN;
DROP TRIGGER admission_changed ON provider_admissions;
DROP TRIGGER model_config_changed ON model_configs;
DROP FUNCTION bump_gateway_revision();
DROP TABLE gateway_revision;
UPDATE model_configs SET enabled=false WHERE enabled;
ALTER TABLE model_configs DROP COLUMN active_ref, DROP COLUMN admitted_model, DROP COLUMN kind, DROP COLUMN protocol, DROP COLUMN model_name, DROP COLUMN provider;
DROP TABLE provider_admissions;
COMMIT;
