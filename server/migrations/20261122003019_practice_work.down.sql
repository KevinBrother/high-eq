-- T11 drafts are append-only; releases and historical call references may exist.
DROP TABLE practice_work;
UPDATE activities SET state='failed' WHERE state='capped';
ALTER TABLE activities DROP CONSTRAINT activities_state_check;
ALTER TABLE activities ADD CONSTRAINT activities_state_check
 CHECK (state IN ('pending','active','complete','exited','safety','moderation_unavailable','failed'));
