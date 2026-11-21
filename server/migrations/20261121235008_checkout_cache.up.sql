BEGIN;
ALTER TABLE payment_facts ADD COLUMN checkout_enc bytea, ADD COLUMN checkout_expires_at timestamptz,
  ADD CONSTRAINT checkout_cache_pair CHECK ((checkout_enc IS NULL) = (checkout_expires_at IS NULL));
COMMIT;
