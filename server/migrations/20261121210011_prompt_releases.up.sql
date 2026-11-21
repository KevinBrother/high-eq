BEGIN;
-- Both arms must refer to immutable versions of this task, including for direct SQL writes.
ALTER TABLE prompt_versions ADD UNIQUE (task,id);
ALTER TABLE model_configs ADD UNIQUE (id,kind);
CREATE TABLE prompt_releases (
  task ai_task NOT NULL,
  model_id uuid NOT NULL,
  model_kind text GENERATED ALWAYS AS ('model'::text) STORED,
  primary_version_id uuid NOT NULL,
  experiment_version_id uuid,
  experiment_percent smallint NOT NULL CHECK (experiment_percent BETWEEN 0 AND 100),
  PRIMARY KEY (task,model_id),
  FOREIGN KEY (model_id,model_kind) REFERENCES model_configs(id,kind),
  FOREIGN KEY (task,primary_version_id) REFERENCES prompt_versions(task,id),
  FOREIGN KEY (task,experiment_version_id) REFERENCES prompt_versions(task,id),
  CHECK (experiment_percent = 0 OR experiment_version_id IS NOT NULL),
  CHECK (experiment_version_id IS DISTINCT FROM primary_version_id)
);
CREATE FUNCTION reject_prompt_version_change() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'prompt versions are append only'; END $$;
CREATE TRIGGER immutable_prompt_versions BEFORE UPDATE OR DELETE OR TRUNCATE ON prompt_versions
FOR EACH STATEMENT EXECUTE FUNCTION reject_prompt_version_change();
COMMIT;
