BEGIN;
-- Not a deletion history. Bind this database to exactly one independent ledger.
CREATE TABLE ledger_binding (singleton boolean PRIMARY KEY CHECK(singleton), ledger_id uuid NOT NULL);
-- Durable work queue, not part of the user's export. Only opaque root IDs;
-- removed in the same transaction that finishes physical cleanup.
CREATE TABLE pending_erasure (root_id uuid PRIMARY KEY);
-- All independently erasable roots and the contact cascades in T02.
CREATE VIEW erasure_roots(user_id, scope, root_id, parent_id) AS
 SELECT id, 'account', purge_id, NULL::uuid FROM users UNION ALL
 SELECT user_id, 'assessments', id, NULL FROM assessments UNION ALL
 SELECT user_id, 'contacts', id, NULL FROM contacts UNION ALL
 SELECT user_id, CASE kind WHEN 'review' THEN 'reviews' WHEN 'reply' THEN 'replies' ELSE 'sessions' END, source_id, contact_id FROM activities UNION ALL
 SELECT user_id, 'manual_marks', id, contact_id FROM manual_marks UNION ALL
 SELECT user_id, 'signal_events', id, contact_id FROM signal_events;
COMMIT;
