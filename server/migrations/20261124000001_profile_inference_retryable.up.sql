BEGIN;
ALTER TABLE profile_inference_requests ADD COLUMN owner_id uuid;
ALTER TABLE profile_inference_requests ADD COLUMN lease_expires_at timestamptz;
ALTER TABLE profile_inference_requests DROP CONSTRAINT profile_inference_requests_state_check;
ALTER TABLE profile_inference_requests ADD CONSTRAINT profile_inference_requests_state_check
 CHECK(state IN ('processing','retryable','complete','invalidated'));

-- The previous rollback parked retryable attempts as processing at infinity.
-- Restore only rows carrying that explicit rollback marker; invalidated,
-- completed and ordinary processing attempts must retain their authority.
UPDATE profile_inference_requests
SET state='retryable',owner_id=NULL,lease_expires_at=NULL,updated_at=clock_timestamp()
WHERE state='processing' AND updated_at='infinity';

-- A rolling upgrade can encounter attempts written by the previous binary.
-- Give those in-flight reservations their full execution boundary instead of
-- making them immediately reclaimable by another process.
UPDATE profile_inference_requests
SET lease_expires_at=clock_timestamp()+interval '70 seconds'
WHERE state='processing' AND lease_expires_at IS NULL;

-- Find pre-migration attempts whose request binding was discarded on failure.
CREATE INDEX ai_calls_profile_inference_request ON ai_calls(user_id,operation_id)
 WHERE task='profile_inference' AND operation_id IS NOT NULL;
COMMIT;
