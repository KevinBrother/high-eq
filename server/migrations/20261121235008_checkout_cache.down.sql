BEGIN;
ALTER TABLE payment_facts DROP CONSTRAINT checkout_cache_pair, DROP COLUMN checkout_enc, DROP COLUMN checkout_expires_at;
COMMIT;
