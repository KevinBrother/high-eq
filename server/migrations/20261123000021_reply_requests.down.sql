BEGIN;
DROP TRIGGER reply_import_guard ON chat_imports;
DROP FUNCTION reject_reply_import();
DROP TABLE reply_feedback, reply_requests;
-- T11 versions are append-only, including when already referenced by an audit row.
COMMIT;
