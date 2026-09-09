BEGIN;
DO $$ BEGIN
    IF (SELECT count(*) FROM im_v2.schema_contract WHERE schema_id = 'im-v2-current-10') <> 1 THEN
        RAISE EXCEPTION 'forward export migration requires schema 10';
    END IF;
END $$;
ALTER TABLE im_v2.rooms ADD COLUMN owner_epoch bigint DEFAULT 0 NOT NULL CHECK (owner_epoch >= 0);
-- Only authoritative co-located directory rows can seed a nonzero local epoch.
-- Remote owner deployments must bootstrap their local epoch from the control
-- directory before enabling exports; a mismatch fails closed in the store.
UPDATE im_v2.rooms AS room SET owner_epoch = route.route_epoch
FROM im_v2.room_owner_routes AS route
WHERE route.room_id = room.room_id AND route.room_shard_id = room.room_shard_id;
-- Immutable source authorization envelopes double as the durable export outbox.
-- No source/target message FK: source retention cannot erase committed evidence,
-- and the destination room deliberately lives in a different physical database.
CREATE TABLE im_v2.message_forward_exports (
    export_id uuid PRIMARY KEY,
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    source_room_id uuid NOT NULL,
    source_message_id uuid NOT NULL,
    source_content_revision bigint NOT NULL CHECK (source_content_revision > 0),
    source_shard_id text NOT NULL CHECK (length(btrim(source_shard_id)) > 0),
    source_epoch bigint NOT NULL CHECK (source_epoch >= 0),
    target_room_id uuid NOT NULL,
    target_client_message_id uuid NOT NULL,
    target_shard_id text NOT NULL CHECK (length(btrim(target_shard_id)) > 0),
    target_epoch bigint NOT NULL CHECK (target_epoch >= 0),
    payload bytea NOT NULL CHECK (octet_length(payload) BETWEEN 1 AND 1048576),
    payload_digest bytea NOT NULL CHECK (octet_length(payload_digest) = 32),
    media_ids uuid[] NOT NULL CHECK (cardinality(media_ids) <= 10 AND array_position(media_ids, NULL) IS NULL),
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT message_forward_exports_pair_key UNIQUE (actor_user_id, operation_id, source_message_id, target_room_id),
    CONSTRAINT message_forward_exports_client_key UNIQUE (actor_user_id, target_client_message_id)
);
CREATE INDEX message_forward_exports_room_idx ON im_v2.message_forward_exports (source_room_id, created_at, export_id);
CREATE INDEX message_forward_exports_delivery_idx ON im_v2.message_forward_exports (source_shard_id, created_at, export_id);
CREATE INDEX message_forward_exports_media_idx ON im_v2.message_forward_exports USING gin (media_ids);
CREATE FUNCTION im_v2.reject_forward_export_mutation() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'committed forward export is immutable' USING ERRCODE = '23514';
END;
$$;
CREATE TRIGGER message_forward_exports_immutable
    BEFORE UPDATE OR DELETE ON im_v2.message_forward_exports FOR EACH ROW
    EXECUTE FUNCTION im_v2.reject_forward_export_mutation();

ALTER TABLE im_v2.schema_contract DROP CONSTRAINT schema_contract_schema_id_check;
ALTER TABLE im_v2.schema_contract ALTER COLUMN schema_id SET DEFAULT 'im-v2-current-11';
UPDATE im_v2.schema_contract SET schema_id = 'im-v2-current-11';
ALTER TABLE im_v2.schema_contract ADD CONSTRAINT schema_contract_schema_id_check CHECK (schema_id = 'im-v2-current-11');
COMMIT;
