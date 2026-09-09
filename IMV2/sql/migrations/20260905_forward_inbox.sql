BEGIN;
DO $$ BEGIN
    IF (SELECT count(*) FROM im_v2.schema_contract WHERE schema_id = 'im-v2-current-11') <> 1 THEN
        RAISE EXCEPTION 'forward inbox migration requires schema 11';
    END IF;
END $$;
-- Attribution is an immutable reference, not a same-database source row.
ALTER TABLE im_v2.messages DROP CONSTRAINT messages_forwarded_from_message_id_fkey;
-- An inbox receipt is independent of mutable message projections. No source
-- message/room FK crosses the physical owner boundary.
CREATE TABLE im_v2.message_forward_inbox (
    export_id uuid PRIMARY KEY,
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    source_message_id uuid NOT NULL,
    target_room_id uuid NOT NULL,
    target_client_message_id uuid NOT NULL,
    payload bytea NOT NULL CHECK (octet_length(payload) BETWEEN 1 AND 1048576),
    payload_digest bytea NOT NULL CHECK (octet_length(payload_digest) = 32),
    state text NOT NULL CHECK (state IN ('pending', 'accepted', 'completed', 'rejected')),
    result_message_id uuid,
    result_room_sequence bigint,
    error_code text,
    created_at timestamptz NOT NULL,
    accepted_at timestamptz,
    completed_at timestamptz,
    CONSTRAINT message_forward_inbox_pair_key UNIQUE (actor_user_id, operation_id, source_message_id, target_room_id),
    CONSTRAINT message_forward_inbox_client_key UNIQUE (actor_user_id, target_client_message_id),
    CONSTRAINT message_forward_inbox_outcome_check CHECK (
        (state = 'pending' AND result_message_id IS NULL AND result_room_sequence IS NULL AND error_code IS NULL AND accepted_at IS NULL AND completed_at IS NULL)
        OR (state IN ('accepted', 'completed') AND result_message_id IS NOT NULL AND result_room_sequence IS NOT NULL AND result_room_sequence > 0 AND error_code IS NULL AND accepted_at IS NOT NULL AND ((state = 'completed') = (completed_at IS NOT NULL)))
        OR (state = 'rejected' AND result_message_id IS NULL AND result_room_sequence IS NULL AND error_code IS NOT NULL AND length(error_code) BETWEEN 1 AND 64 AND accepted_at IS NULL AND completed_at IS NOT NULL)
    )
);
CREATE INDEX message_forward_inbox_pending_idx ON im_v2.message_forward_inbox (target_room_id, created_at, export_id) WHERE state IN ('pending', 'accepted');
CREATE FUNCTION im_v2.reject_forward_inbox_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'forward inbox receipt cannot be deleted' USING ERRCODE = '23514';
    END IF;
    IF ROW(NEW.export_id, NEW.actor_user_id, NEW.operation_id, NEW.source_message_id, NEW.target_room_id, NEW.target_client_message_id, NEW.payload, NEW.payload_digest, NEW.created_at)
       IS DISTINCT FROM ROW(OLD.export_id, OLD.actor_user_id, OLD.operation_id, OLD.source_message_id, OLD.target_room_id, OLD.target_client_message_id, OLD.payload, OLD.payload_digest, OLD.created_at)
       OR (OLD.state IN ('completed', 'rejected') AND NEW IS DISTINCT FROM OLD)
       OR (OLD.state = 'pending' AND NEW.state NOT IN ('pending', 'accepted', 'rejected'))
       OR (OLD.state = 'accepted' AND (
            NEW.state NOT IN ('accepted', 'completed')
            OR ROW(NEW.result_message_id, NEW.result_room_sequence, NEW.accepted_at, NEW.error_code)
               IS DISTINCT FROM ROW(OLD.result_message_id, OLD.result_room_sequence, OLD.accepted_at, OLD.error_code))) THEN
        RAISE EXCEPTION 'forward inbox identity and terminal outcome are immutable' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER message_forward_inbox_immutable BEFORE UPDATE OR DELETE ON im_v2.message_forward_inbox
    FOR EACH ROW EXECUTE FUNCTION im_v2.reject_forward_inbox_mutation();
CREATE TABLE im_v2.message_forward_inbox_media (
    export_id uuid NOT NULL REFERENCES im_v2.message_forward_inbox(export_id) ON DELETE RESTRICT,
    ordinal integer NOT NULL CHECK (ordinal BETWEEN 0 AND 9),
    source_media_id uuid NOT NULL,
    target_media_id uuid UNIQUE CHECK (target_media_id IS NULL OR target_media_id <> source_media_id),
    object_digest bytea,
    state text NOT NULL CHECK (state IN ('pending', 'ready')),
    PRIMARY KEY (export_id, ordinal),
    UNIQUE (export_id, source_media_id),
    CONSTRAINT message_forward_inbox_media_ready_check CHECK (
        (state = 'pending' AND target_media_id IS NULL AND object_digest IS NULL)
        OR (state = 'ready' AND target_media_id IS NOT NULL AND object_digest IS NOT NULL AND octet_length(object_digest) = 32)
    )
);
CREATE FUNCTION im_v2.reject_forward_inbox_media_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'forward inbox media identity cannot be deleted' USING ERRCODE = '23514';
    END IF;
    IF ROW(NEW.export_id, NEW.ordinal, NEW.source_media_id) IS DISTINCT FROM ROW(OLD.export_id, OLD.ordinal, OLD.source_media_id)
       OR (OLD.state = 'ready' AND NEW IS DISTINCT FROM OLD) THEN
        RAISE EXCEPTION 'forward inbox media identity and ready mapping are immutable' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER message_forward_inbox_media_immutable BEFORE UPDATE OR DELETE ON im_v2.message_forward_inbox_media
    FOR EACH ROW EXECUTE FUNCTION im_v2.reject_forward_inbox_media_mutation();

ALTER TABLE im_v2.schema_contract DROP CONSTRAINT schema_contract_schema_id_check;
ALTER TABLE im_v2.schema_contract ALTER COLUMN schema_id SET DEFAULT 'im-v2-current-12';
UPDATE im_v2.schema_contract SET schema_id = 'im-v2-current-12';
ALTER TABLE im_v2.schema_contract ADD CONSTRAINT schema_contract_schema_id_check CHECK (schema_id = 'im-v2-current-12');
COMMIT;
