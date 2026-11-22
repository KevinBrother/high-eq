BEGIN;
DROP TABLE profile_inference_requests;
DROP TABLE activity_profile_context;
DROP TABLE profile_observations;
ALTER TABLE signal_events DROP CONSTRAINT profile_signal_owner;
-- T11 drafts are immutable and may already be referenced by historical calls.
COMMIT;
