BEGIN;
DROP TRIGGER forget_bound_sms ON login_identities;
DROP FUNCTION forget_bound_sms();
DROP TABLE sms_challenges, auth_sessions;
DROP INDEX users_pending_closure, consents_latest_decision;
COMMIT;
