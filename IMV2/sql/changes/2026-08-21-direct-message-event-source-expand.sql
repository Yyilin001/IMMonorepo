-- Expand phase for direct accepted events materialized from `messages`.
--
-- Existing rows remain `room_event`; no historical rewrite is needed.  New
-- plain direct room-log appends may use `message_row` only after readers that
-- understand both sources are deployed.  Do not enable the writer before
-- that binary is live.
--
-- `CREATE INDEX CONCURRENTLY` cannot run inside a transaction. Execute this
-- file as-is in a migration runner that permits non-transactional statements.
ALTER TABLE im_v2.messages
    ADD COLUMN IF NOT EXISTS accepted_event_id uuid;

ALTER TABLE im_v2.messages
    ADD COLUMN IF NOT EXISTS accepted_event_storage text
        NOT NULL DEFAULT 'room_event';

ALTER TABLE im_v2.messages
    ADD COLUMN IF NOT EXISTS accepted_membership_revision bigint;

ALTER TABLE im_v2.messages
    ADD CONSTRAINT messages_accepted_event_storage_check
    CHECK (
        (accepted_event_storage = 'room_event'
         AND accepted_event_id IS NULL
         AND accepted_membership_revision IS NULL)
        OR
        (accepted_event_storage = 'message_row'
         AND accepted_event_id IS NOT NULL
         AND accepted_membership_revision >= 0)
    ) NOT VALID;

CREATE INDEX CONCURRENTLY IF NOT EXISTS messages_direct_event_cursor_idx
    ON im_v2.messages (room_id, room_sequence)
    WHERE accepted_event_storage = 'message_row';

ALTER TABLE im_v2.messages
    VALIDATE CONSTRAINT messages_accepted_event_storage_check;

-- This is intentionally last: startup readiness must not admit a binary
-- whose reader understands message-row events until all columns, integrity
-- checks, and the cursor index are present.
ALTER TABLE im_v2.schema_contract
    DROP CONSTRAINT schema_contract_schema_id_check;

UPDATE im_v2.schema_contract
SET schema_id = 'im-v2-current-3'
WHERE schema_id = 'im-v2-current-2';

ALTER TABLE im_v2.schema_contract
    ALTER COLUMN schema_id SET DEFAULT 'im-v2-current-3';

ALTER TABLE im_v2.schema_contract
    ADD CONSTRAINT schema_contract_schema_id_check
        CHECK (schema_id = 'im-v2-current-3');
