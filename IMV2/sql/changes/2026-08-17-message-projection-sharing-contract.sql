\set ON_ERROR_STOP on

-- Optional final contract. Apply only after every binary uses write=shared,
-- read=shared and both backfill/inline-payload metrics have remained zero.
-- This is intentionally not part of the expand deployment or canonical
-- current-2 bootstrap because it removes the instant inline-read rollback.

ALTER TABLE im_v2.user_projection_versions
    ADD CONSTRAINT user_projection_versions_message_shared_contract_check
    CHECK (
        projection_kind <> 'message'
        OR (message_state_id IS NOT NULL AND payload IS NULL)
    ) NOT VALID;
ALTER TABLE im_v2.user_projection_versions
    VALIDATE CONSTRAINT user_projection_versions_message_shared_contract_check;

DROP INDEX CONCURRENTLY IF EXISTS im_v2.user_projection_versions_message_backfill_idx;
DROP INDEX CONCURRENTLY IF EXISTS im_v2.user_projection_versions_message_inline_idx;
