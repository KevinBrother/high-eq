BEGIN;
-- The anonymous order stub remains after erasure; no signed payload, token or external ID is retained.
CREATE TABLE payment_facts (
 order_id uuid PRIMARY KEY, user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
 request_id uuid, apple_chain_hmac bytea, provider_hmac bytea UNIQUE, paid_at timestamptz, apple_until timestamptz,
 refunded_at timestamptz, card_days integer NOT NULL CHECK (card_days BETWEEN 0 AND 366),
 CHECK (refunded_at >= paid_at), CHECK (apple_until > paid_at),
 UNIQUE(user_id,request_id), FOREIGN KEY(order_id,user_id) REFERENCES orders(id,user_id) ON DELETE CASCADE
);
CREATE INDEX payment_facts_account ON payment_facts(user_id);
CREATE TABLE apple_purchase_chains (chain_hmac bytea PRIMARY KEY, first_order_id uuid NOT NULL REFERENCES orders);
CREATE TABLE payment_notices (notice_hmac bytea PRIMARY KEY, evidence_hmac bytea NOT NULL, user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE);
CREATE INDEX payment_notices_account ON payment_notices(user_id);
COMMIT;
