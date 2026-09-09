BEGIN;

DO $$
BEGIN
    IF (SELECT count(*) FROM im_v2.schema_contract WHERE schema_id = 'im-v2-current-8') <> 1 THEN
        RAISE EXCEPTION 'message version audience migration requires schema 8';
    END IF;
END
$$;

-- A content revision has one authoritative edit event. This partial index
-- supports both current and legacy projections without scanning room history
-- or treating an idempotency-operation retention table as read authority.
CREATE UNIQUE INDEX room_events_message_edit_revision_idx
    ON im_v2.room_events
    (room_id, lower(payload->>'message_id'), (payload->>'message_revision'))
    WHERE event_type = 'message.edited';

ALTER TABLE im_v2.schema_contract DROP CONSTRAINT schema_contract_schema_id_check;
ALTER TABLE im_v2.schema_contract ALTER COLUMN schema_id SET DEFAULT 'im-v2-current-9';
UPDATE im_v2.schema_contract SET schema_id = 'im-v2-current-9';
ALTER TABLE im_v2.schema_contract ADD CONSTRAINT schema_contract_schema_id_check
    CHECK (schema_id = 'im-v2-current-9');

COMMIT;
