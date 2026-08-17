\set ON_ERROR_STOP on

-- Online expand for reference-backed accepted-message sync payloads. Apply
-- independently to the control database and every physical user-shard store
-- before deploying a binary that may write a NULL payload.
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

ALTER TABLE im_v2.fanout_sync_payloads
    ALTER COLUMN payload DROP NOT NULL;
ALTER TABLE im_v2.fanout_sync_payloads
    ADD CONSTRAINT fanout_sync_payloads_payload_reference_check CHECK (
        payload IS NOT NULL OR message_state_id IS NOT NULL
    ) NOT VALID;
ALTER TABLE im_v2.fanout_sync_payloads
    ADD CONSTRAINT fanout_sync_payloads_message_state_kind_check CHECK (
        message_state_id IS NULL OR projection_kind = 'message'
    ) NOT VALID;

ALTER TABLE im_v2.fanout_sync_payloads
    VALIDATE CONSTRAINT fanout_sync_payloads_payload_reference_check;
ALTER TABLE im_v2.fanout_sync_payloads
    VALIDATE CONSTRAINT fanout_sync_payloads_message_state_kind_check;
COMMIT;
