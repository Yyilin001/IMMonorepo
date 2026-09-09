BEGIN;
DO $$
BEGIN
    IF (SELECT count(*) FROM im_v2.schema_contract WHERE schema_id = 'im-v2-current-9') <> 1 THEN
        RAISE EXCEPTION 'forward source location migration requires schema 9';
    END IF;
END
$$;
ALTER TABLE im_v2.message_forward_operations ADD COLUMN source_room_id uuid;
-- Message identity has an immutable room, and legacy operation rows retain a
-- source FK. Backfill only that authoritative location, never a content version.
-- Replace the old trigger first: the new identity becomes immutable afterwards.
DROP TRIGGER message_forward_operations_identity_immutable ON im_v2.message_forward_operations;
UPDATE im_v2.message_forward_operations AS operation
SET source_room_id = source.room_id
FROM im_v2.messages AS source WHERE source.message_id = operation.source_message_id;
CREATE OR REPLACE FUNCTION im_v2.reject_forward_operation_identity_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF ROW(NEW.actor_user_id, NEW.operation_id, NEW.source_message_id,
           NEW.target_room_id, NEW.target_client_message_id, NEW.source_content_revision, NEW.source_room_id, NEW.created_at)
       IS DISTINCT FROM
       ROW(OLD.actor_user_id, OLD.operation_id, OLD.source_message_id,
           OLD.target_room_id, OLD.target_client_message_id, OLD.source_content_revision, OLD.source_room_id, OLD.created_at)
       OR (OLD.result_message_id IS NOT NULL AND NEW.result_message_id IS DISTINCT FROM OLD.result_message_id) THEN
        RAISE EXCEPTION 'forward operation identity and completed result are immutable'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER message_forward_operations_identity_immutable
    BEFORE UPDATE ON im_v2.message_forward_operations FOR EACH ROW
    EXECUTE FUNCTION im_v2.reject_forward_operation_identity_mutation();
ALTER TABLE im_v2.schema_contract DROP CONSTRAINT schema_contract_schema_id_check;
ALTER TABLE im_v2.schema_contract ALTER COLUMN schema_id SET DEFAULT 'im-v2-current-10';
UPDATE im_v2.schema_contract SET schema_id = 'im-v2-current-10';
ALTER TABLE im_v2.schema_contract ADD CONSTRAINT schema_contract_schema_id_check CHECK (schema_id = 'im-v2-current-10');
COMMIT;
