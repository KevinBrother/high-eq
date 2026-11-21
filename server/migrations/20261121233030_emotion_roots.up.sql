BEGIN;
ALTER TABLE signal_windows ADD COLUMN purge_id uuid NOT NULL UNIQUE DEFAULT gen_random_uuid();
ALTER TABLE signal_events ADD COLUMN feedback_pending boolean NOT NULL DEFAULT false;
CREATE INDEX signal_events_pending ON signal_events(id) WHERE feedback_pending;
-- Preserve all pre-existing (and in-flight) scopes without copying their SELECTs.
ALTER VIEW erasure_roots RENAME TO erasure_roots_before_emotion;
CREATE VIEW erasure_roots(user_id,scope,root_id,parent_id) AS
 SELECT * FROM erasure_roots_before_emotion UNION ALL
 SELECT user_id,'signal_windows',purge_id,NULL::uuid FROM signal_windows;
COMMIT;
