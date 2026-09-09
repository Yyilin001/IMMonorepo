BEGIN;

DO $$
BEGIN
    IF (SELECT count(*) FROM im_v2.schema_contract WHERE schema_id = 'im-v2-current-7') <> 1 THEN
        RAISE EXCEPTION 'forward source revision migration requires schema 7';
    END IF;
END
$$;

-- Do not invent revision 1 for old pending operations. NULL means unknown;
-- completed pairs replay their result, while new acceptance fails closed.
ALTER TABLE im_v2.message_forward_operations
    ADD COLUMN source_content_revision bigint CHECK (source_content_revision > 0);

CREATE FUNCTION im_v2.reject_forward_operation_identity_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF ROW(NEW.actor_user_id, NEW.operation_id, NEW.source_message_id,
           NEW.target_room_id, NEW.target_client_message_id, NEW.source_content_revision, NEW.created_at)
       IS DISTINCT FROM
       ROW(OLD.actor_user_id, OLD.operation_id, OLD.source_message_id,
           OLD.target_room_id, OLD.target_client_message_id, OLD.source_content_revision, OLD.created_at)
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

ALTER TABLE im_v2.message_send_completions
    DROP CONSTRAINT message_send_completions_fingerprint_version_check,
    ADD CONSTRAINT message_send_completions_fingerprint_version_check
        CHECK (fingerprint_version IN (1, 2));
ALTER TABLE im_v2.direct_message_denials
    DROP CONSTRAINT direct_message_denials_fingerprint_version_check,
    ADD CONSTRAINT direct_message_denials_fingerprint_version_check
        CHECK (fingerprint_version IN (1, 2));

-- Bump the contract last, in the same transaction as the new representation.
ALTER TABLE im_v2.schema_contract DROP CONSTRAINT schema_contract_schema_id_check;
ALTER TABLE im_v2.schema_contract ALTER COLUMN schema_id SET DEFAULT 'im-v2-current-8';
UPDATE im_v2.schema_contract SET schema_id = 'im-v2-current-8';
ALTER TABLE im_v2.schema_contract ADD CONSTRAINT schema_contract_schema_id_check
    CHECK (schema_id = 'im-v2-current-8');

COMMIT;
