-- Feed to psql inside a single rollback-only session. Same SQL as the monitor.
BEGIN;
CREATE TEMP TABLE ai_calls(started_at timestamptz, cost_cny numeric);
INSERT INTO ai_calls SELECT date_trunc('day', now() at time zone 'Asia/Shanghai') at time zone 'Asia/Shanghai' - i*interval '1 day', 1 FROM generate_series(1,7) i;
INSERT INTO ai_calls VALUES(now(),2);
\i /ops/cost.sql
INSERT INTO ai_calls VALUES(now(),0.00000001);
\i /ops/cost.sql
INSERT INTO ai_calls VALUES(now(),NULL);
\i /ops/cost.sql
DELETE FROM ai_calls;
\i /ops/cost.sql
INSERT INTO ai_calls VALUES(now(),1);
\i /ops/cost.sql
DELETE FROM ai_calls;
INSERT INTO ai_calls VALUES(now(),NULL);
\i /ops/cost.sql
ROLLBACK;
