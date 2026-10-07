-- Run after old send/recovery processes have drained. Preserve historical
-- receipts and closures; remove only the per-message close fence.
BEGIN;
DROP TRIGGER IF EXISTS message_send_completion_close_fence ON im_v2.message_send_completions;
DROP FUNCTION IF EXISTS im_v2.reject_closed_message_acceptance();
COMMIT;
