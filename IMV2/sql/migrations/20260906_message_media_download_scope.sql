BEGIN;
DO $$ BEGIN
    IF (SELECT count(*) FROM im_v2.schema_contract WHERE schema_id = 'im-v2-current-16') <> 1 THEN
        RAISE EXCEPTION 'message media download scope requires schema 16';
    END IF;
END $$;
ALTER TABLE im_v2.media_download_grants
    ADD COLUMN message_room_id uuid,
    ADD COLUMN message_id uuid,
    ADD COLUMN owner_shard_id text,
    ADD COLUMN owner_epoch bigint,
    DROP CONSTRAINT media_download_grants_user_id_device_id_fkey,
    ADD CONSTRAINT media_download_grants_scope_check CHECK (
        (message_room_id IS NULL AND message_id IS NULL AND owner_shard_id IS NULL AND owner_epoch IS NULL)
        OR (message_room_id IS NOT NULL AND message_id IS NOT NULL AND owner_shard_id IS NOT NULL
            AND length(btrim(owner_shard_id)) > 0 AND owner_epoch IS NOT NULL AND owner_epoch >= 0)
    );
CREATE FUNCTION im_v2.reject_media_download_grant_identity_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF ROW(NEW.download_session_id, NEW.media_id, NEW.user_id, NEW.device_id, NEW.expires_at, NEW.created_at,
           NEW.message_room_id, NEW.message_id, NEW.owner_shard_id, NEW.owner_epoch)
       IS DISTINCT FROM ROW(OLD.download_session_id, OLD.media_id, OLD.user_id, OLD.device_id, OLD.expires_at, OLD.created_at,
           OLD.message_room_id, OLD.message_id, OLD.owner_shard_id, OLD.owner_epoch)
       OR (OLD.state = 'consumed' AND NEW IS DISTINCT FROM OLD) THEN
        RAISE EXCEPTION 'media download grant identity is immutable' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER media_download_grants_identity BEFORE UPDATE ON im_v2.media_download_grants
    FOR EACH ROW EXECUTE FUNCTION im_v2.reject_media_download_grant_identity_mutation();

ALTER TABLE im_v2.schema_contract DROP CONSTRAINT schema_contract_schema_id_check;
ALTER TABLE im_v2.schema_contract ALTER COLUMN schema_id SET DEFAULT 'im-v2-current-17';
UPDATE im_v2.schema_contract SET schema_id = 'im-v2-current-17';
ALTER TABLE im_v2.schema_contract ADD CONSTRAINT schema_contract_schema_id_check CHECK (schema_id = 'im-v2-current-17');
COMMIT;
