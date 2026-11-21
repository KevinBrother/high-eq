BEGIN;
DROP TABLE prompt_releases;
DROP TRIGGER immutable_prompt_versions ON prompt_versions;
DROP FUNCTION reject_prompt_version_change();
ALTER TABLE prompt_versions DROP CONSTRAINT prompt_versions_task_id_key;
ALTER TABLE model_configs DROP CONSTRAINT model_configs_id_kind_key;
COMMIT;
