BEGIN;
DROP TABLE growth_drill_schedules;
DROP INDEX daily_plans_assessment;
DROP INDEX daily_plans_completion;
ALTER TABLE daily_plans DROP COLUMN assessment_id;
COMMIT;
