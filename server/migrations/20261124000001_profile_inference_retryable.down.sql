BEGIN;
DROP INDEX ai_calls_profile_inference_request;
-- The previous binary cannot represent retryable attempts. Park them as
-- processing with a durable marker so the next upgrade can restore only these
-- legitimate business rows. They were not authorization failures and must not
-- become invalidated merely because the binary was rolled back.
UPDATE profile_inference_requests
SET state='processing',owner_id=NULL,lease_expires_at=NULL,updated_at='infinity'
WHERE state='retryable';
ALTER TABLE profile_inference_requests DROP CONSTRAINT profile_inference_requests_state_check;
ALTER TABLE profile_inference_requests ADD CONSTRAINT profile_inference_requests_state_check
 CHECK(state IN ('processing','complete','invalidated'));
ALTER TABLE profile_inference_requests DROP COLUMN lease_expires_at;
ALTER TABLE profile_inference_requests DROP COLUMN owner_id;
COMMIT;
