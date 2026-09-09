BEGIN;
DO $$ BEGIN
    IF (SELECT count(*) FROM im_v2.schema_contract WHERE schema_id = 'im-v2-current-12') <> 1 THEN
        RAISE EXCEPTION 'forward media import migration requires schema 12';
    END IF;
END $$;
CREATE TABLE im_v2.message_forward_media_imports (
    export_id uuid NOT NULL,
    ordinal integer NOT NULL CHECK (ordinal BETWEEN 0 AND 9),
    target_media_id uuid NOT NULL UNIQUE,
    target_upload_session_id uuid NOT NULL UNIQUE,
    state text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'claimed', 'paused', 'ready', 'failed')),
    copied_digest bytea,
    copied_at timestamptz,
    claim_token uuid,
    lease_expires_at timestamptz,
    next_attempt_at timestamptz,
    retry_count bigint NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
    created_at timestamptz NOT NULL,
    completed_at timestamptz,
    PRIMARY KEY (export_id, ordinal),
    FOREIGN KEY (export_id, ordinal) REFERENCES im_v2.message_forward_inbox_media(export_id, ordinal) ON DELETE RESTRICT,
    CONSTRAINT message_forward_media_imports_shape_check CHECK (
        ((state = 'claimed') = (claim_token IS NOT NULL)) AND ((state = 'claimed') = (lease_expires_at IS NOT NULL))
        AND ((state IN ('ready', 'failed')) = (completed_at IS NOT NULL))
        AND ((copied_digest IS NOT NULL) = (copied_at IS NOT NULL))
        AND (copied_digest IS NULL OR octet_length(copied_digest) = 32)
        AND (state <> 'ready' OR copied_digest IS NOT NULL)
        AND (next_attempt_at IS NULL OR state = 'pending')
    )
);
CREATE INDEX message_forward_media_imports_work_idx ON im_v2.message_forward_media_imports (state, next_attempt_at, lease_expires_at, created_at) WHERE state IN ('pending', 'claimed');
CREATE FUNCTION im_v2.reject_forward_media_import_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'forward media import identity cannot be deleted' USING ERRCODE = '23514';
    END IF;
    IF ROW(NEW.export_id, NEW.ordinal, NEW.target_media_id, NEW.target_upload_session_id, NEW.created_at)
       IS DISTINCT FROM ROW(OLD.export_id, OLD.ordinal, OLD.target_media_id, OLD.target_upload_session_id, OLD.created_at)
       OR (OLD.copied_digest IS NOT NULL AND ROW(NEW.copied_digest, NEW.copied_at) IS DISTINCT FROM ROW(OLD.copied_digest, OLD.copied_at))
       OR (OLD.state IN ('ready', 'failed') AND NEW IS DISTINCT FROM OLD)
       OR (OLD.state = 'pending' AND NEW.state NOT IN ('pending', 'claimed'))
       OR (OLD.state = 'paused' AND NEW.state NOT IN ('paused', 'pending')) THEN
        RAISE EXCEPTION 'forward media object, copied digest and terminal outcome are immutable' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER message_forward_media_imports_immutable BEFORE UPDATE OR DELETE ON im_v2.message_forward_media_imports
    FOR EACH ROW EXECUTE FUNCTION im_v2.reject_forward_media_import_mutation();

ALTER TABLE ONLY im_v2.message_forward_media_imports
    ADD CONSTRAINT message_forward_media_imports_target_media_id_fkey FOREIGN KEY (target_media_id) REFERENCES im_v2.media_objects(media_id) ON DELETE RESTRICT;

ALTER TABLE im_v2.schema_contract DROP CONSTRAINT schema_contract_schema_id_check;
ALTER TABLE im_v2.schema_contract ALTER COLUMN schema_id SET DEFAULT 'im-v2-current-13';
UPDATE im_v2.schema_contract SET schema_id = 'im-v2-current-13';
ALTER TABLE im_v2.schema_contract ADD CONSTRAINT schema_contract_schema_id_check CHECK (schema_id = 'im-v2-current-13');
COMMIT;
