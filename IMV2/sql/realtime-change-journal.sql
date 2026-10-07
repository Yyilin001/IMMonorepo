-- Atomic repeatable installation. Fresh entrypoint and explicit retained-source
-- installation may overlap; serialize their DDL per database/schema.
BEGIN;
SELECT pg_advisory_xact_lock(hashtext(current_database()),hashtext('im_v2.realtime-change-journal-install'));
-- Install after schema.sql on every room/control database. This extension is
-- repeatable; no business nextval/max value is a consumption checkpoint.
-- These leases fence publishers on this database; routing leases on the
-- central maintenance database are intentionally a separate authority.
CREATE TABLE IF NOT EXISTS im_v2.realtime_journal_source_identity (
 singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
 source_id uuid NOT NULL DEFAULT gen_random_uuid(),
 database_incarnation uuid NOT NULL DEFAULT gen_random_uuid()
);
INSERT INTO im_v2.realtime_journal_source_identity(singleton) VALUES(true) ON CONFLICT DO NOTHING;
-- Rotate database_incarnation explicitly when cloning/restoring into a new
-- independent source. Never regenerate it on ordinary restart or SQL install.
CREATE TABLE IF NOT EXISTS im_v2.realtime_journal_publisher_leases (
 partition_id integer PRIMARY KEY CHECK(partition_id BETWEEN 0 AND 255),
 host_id text CHECK(octet_length(host_id) BETWEEN 1 AND 128),
 service_id text CHECK(octet_length(service_id) BETWEEN 1 AND 128),
 process_incarnation uuid, lease_epoch bigint NOT NULL DEFAULT 0 CHECK(lease_epoch>=0),
 lease_token uuid, expires_at timestamptz NOT NULL DEFAULT '1970-01-01T00:00:00Z' CHECK(isfinite(expires_at)),
 updated_at timestamptz NOT NULL DEFAULT clock_timestamp() CHECK(isfinite(updated_at)),
 CHECK((lease_epoch=0 AND host_id IS NULL AND service_id IS NULL AND process_incarnation IS NULL AND lease_token IS NULL)
 OR(lease_epoch>0 AND host_id IS NOT NULL AND service_id IS NOT NULL AND process_incarnation IS NOT NULL AND lease_token IS NOT NULL))
);
INSERT INTO im_v2.realtime_journal_publisher_leases(partition_id) SELECT generate_series(0,255) ON CONFLICT DO NOTHING;
CREATE TABLE IF NOT EXISTS im_v2.realtime_journal_partitions (
 partition_id integer PRIMARY KEY CHECK (partition_id BETWEEN 0 AND 255),
 published_through bigint NOT NULL DEFAULT 0 CHECK (published_through >= 0),
 trimmed_through bigint NOT NULL DEFAULT 0 CHECK (trimmed_through BETWEEN 0 AND published_through)
);
INSERT INTO im_v2.realtime_journal_partitions(partition_id) SELECT generate_series(0,255) ON CONFLICT DO NOTHING;
CREATE TABLE IF NOT EXISTS im_v2.realtime_change_outbox (
 source_event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 partition_id integer NOT NULL REFERENCES im_v2.realtime_journal_partitions,
 topic_kind text NOT NULL, topic_id text NOT NULL, change_kind text NOT NULL,
 room_sequence bigint, room_control_version bigint, user_control_version bigint, device_id uuid,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX IF NOT EXISTS realtime_change_outbox_partition_idx ON im_v2.realtime_change_outbox(partition_id,created_at,source_event_id);
CREATE INDEX IF NOT EXISTS realtime_change_outbox_topic_idx ON im_v2.realtime_change_outbox(topic_kind,topic_id,created_at);
CREATE TABLE IF NOT EXISTS im_v2.realtime_change_journal (
 partition_id integer NOT NULL REFERENCES im_v2.realtime_journal_partitions,
 sequence bigint NOT NULL CHECK(sequence > 0), source_event_id uuid NOT NULL UNIQUE,
 topic_kind text NOT NULL, topic_id text NOT NULL, change_kind text NOT NULL,
 room_sequence bigint, room_control_version bigint, user_control_version bigint, device_id uuid,
 PRIMARY KEY(partition_id,sequence)
);
ALTER TABLE im_v2.realtime_change_outbox ADD COLUMN IF NOT EXISTS owner_epoch bigint;
ALTER TABLE im_v2.realtime_change_journal ADD COLUMN IF NOT EXISTS owner_epoch bigint;
ALTER TABLE im_v2.realtime_change_outbox ADD COLUMN IF NOT EXISTS membership_room_id uuid;
ALTER TABLE im_v2.realtime_change_journal ADD COLUMN IF NOT EXISTS membership_room_id uuid;
-- One durable publication floor per independently versioned control topic.
-- Version allocation holds the topic row lock until source transaction COMMIT:
-- a later version cannot become visible before its predecessor. Publisher
-- additionally checks exact contiguous versions before advancing this floor.
CREATE TABLE IF NOT EXISTS im_v2.realtime_control_publication_floors (
 topic_kind text NOT NULL, topic_id text NOT NULL, published_version bigint NOT NULL CHECK(published_version>0),
 PRIMARY KEY(topic_kind,topic_id)
);
CREATE TABLE IF NOT EXISTS im_v2.realtime_dirty_room_heads (
 room_id uuid PRIMARY KEY, partition_id integer NOT NULL CHECK(partition_id BETWEEN 0 AND 255),
 room_sequence bigint NOT NULL CHECK(room_sequence>=0), owner_epoch bigint NOT NULL CHECK(owner_epoch>=0),
 room_control_version bigint NOT NULL CHECK(room_control_version>=0),
 revision bigint NOT NULL DEFAULT 1 CHECK(revision>0), pending boolean NOT NULL DEFAULT true
);
CREATE INDEX IF NOT EXISTS realtime_dirty_room_heads_pending_idx ON im_v2.realtime_dirty_room_heads(partition_id,room_id) WHERE pending;
CREATE TABLE IF NOT EXISTS im_v2.realtime_control_versions (
 topic_kind text NOT NULL, topic_id text NOT NULL, version bigint NOT NULL CHECK(version > 0),
 PRIMARY KEY(topic_kind,topic_id)
);
ALTER TABLE im_v2.realtime_control_versions ADD COLUMN IF NOT EXISTS membership_discovery_version bigint NOT NULL DEFAULT 0;
ALTER TABLE im_v2.realtime_control_versions ADD COLUMN IF NOT EXISTS session_control_version bigint NOT NULL DEFAULT 0;
CREATE TABLE IF NOT EXISTS im_v2.realtime_device_control_versions (
 user_id uuid NOT NULL, device_id uuid NOT NULL, latest_change_version bigint NOT NULL CHECK(latest_change_version>0),
 PRIMARY KEY(user_id,device_id)
);
CREATE TABLE IF NOT EXISTS im_v2.realtime_journal_consumers (
 partition_id integer NOT NULL REFERENCES im_v2.realtime_journal_partitions,
 gateway_incarnation uuid NOT NULL, gateway_node text NOT NULL, gateway_service text NOT NULL,
 session_id uuid NOT NULL, session_generation bigint NOT NULL DEFAULT 1 CHECK(session_generation>0), session_revision bigint NOT NULL CHECK(session_revision>0),
 routing_epoch bigint NOT NULL CHECK(routing_epoch>0), routing_token uuid NOT NULL,
 coverage_expires_at timestamptz NOT NULL CHECK(isfinite(coverage_expires_at)),
 room_ids uuid[] NOT NULL, user_ids uuid[] NOT NULL,
 control_cursor bigint NOT NULL DEFAULT 0 CHECK(control_cursor>=0),
 offered_through bigint NOT NULL DEFAULT 0 CHECK(offered_through>=control_cursor),
 PRIMARY KEY(partition_id,gateway_incarnation)
);
ALTER TABLE im_v2.realtime_journal_consumers ADD COLUMN IF NOT EXISTS session_generation bigint NOT NULL DEFAULT 1;
CREATE INDEX IF NOT EXISTS realtime_journal_consumers_pending_idx ON im_v2.realtime_journal_consumers(partition_id,gateway_incarnation) WHERE offered_through>control_cursor;
CREATE TABLE IF NOT EXISTS im_v2.realtime_journal_consumer_heads (
 partition_id integer NOT NULL, gateway_incarnation uuid NOT NULL, room_id uuid NOT NULL,
 room_sequence bigint NOT NULL CHECK(room_sequence>=0), owner_epoch bigint NOT NULL CHECK(owner_epoch>=0),
 room_control_version bigint NOT NULL CHECK(room_control_version>=0), revision bigint NOT NULL CHECK(revision>0),
 PRIMARY KEY(partition_id,gateway_incarnation,room_id),
 FOREIGN KEY(partition_id,gateway_incarnation) REFERENCES im_v2.realtime_journal_consumers ON DELETE CASCADE
);
-- Low byte of FNV-1a is sufficient modulo 256; lengths remain big endian.
CREATE OR REPLACE FUNCTION im_v2.realtime_topic_partition(kind text,id text) RETURNS integer LANGUAGE plpgsql IMMUTABLE STRICT AS $$
DECLARE bytes bytea := decode('01','hex'); value text; encoded bytea; h integer := 37; i integer;
BEGIN
 FOREACH value IN ARRAY ARRAY[kind,id] LOOP
  encoded := convert_to(value,'UTF8'); bytes := bytes || int4send(octet_length(encoded)) || encoded;
 END LOOP;
 FOR i IN 0..octet_length(bytes)-1 LOOP h := ((h # get_byte(bytes,i)) * 179) % 256; END LOOP;
 RETURN h;
END $$;
CREATE OR REPLACE FUNCTION im_v2.capture_realtime_change() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE r jsonb; oldr jsonb; kind text; id text; ck text; seq bigint; rv bigint; uv bigint; dev uuid; source uuid; oe bigint;
BEGIN
 IF TG_OP='DELETE' THEN r:=to_jsonb(OLD); ELSE r:=to_jsonb(NEW); END IF;
 IF TG_OP='UPDATE' THEN oldr:=to_jsonb(OLD); END IF;
 IF TG_TABLE_NAME='rooms' THEN
  IF TG_OP='UPDATE' AND r->>'owner_epoch'=oldr->>'owner_epoch'
   AND r->>'membership_revision'=oldr->>'membership_revision'
   AND r->>'group_permission_revision'=oldr->>'group_permission_revision'
   AND (r->>'frozen_at') IS NOT DISTINCT FROM (oldr->>'frozen_at') THEN RETURN NULL; END IF;
  kind:='roomEvents'; id:=r->>'room_id'; ck:='room.authorization.changed';
  INSERT INTO im_v2.realtime_control_versions(topic_kind,topic_id,version) VALUES(kind,id,1)
   ON CONFLICT(topic_kind,topic_id) DO UPDATE SET version=im_v2.realtime_control_versions.version+1 RETURNING version INTO rv;
 ELSIF TG_TABLE_NAME='room_memberships' THEN
  IF TG_OP='UPDATE' AND r->>'role'=oldr->>'role' AND r->>'joined_revision'=oldr->>'joined_revision' AND (r->>'left_revision') IS NOT DISTINCT FROM (oldr->>'left_revision') THEN RETURN NULL; END IF;
  -- The user topic is the durable invalidation for membership authorization.
  kind:='userSync'; id:=r->>'user_id'; ck:='membership.changed';
 ELSE
  IF TG_OP='UPDATE' AND (r->>'revoked_at') IS NOT DISTINCT FROM (oldr->>'revoked_at') AND (r->>'session_expires_at') IS NOT DISTINCT FROM (oldr->>'session_expires_at') AND (r->>'expires_at') IS NOT DISTINCT FROM (oldr->>'expires_at') AND (r->>'family_generation') IS NOT DISTINCT FROM (oldr->>'family_generation') THEN RETURN NULL; END IF;
  kind:='userSync'; id:=r->>'user_id'; ck:='session.changed'; dev:=(r->>'device_id')::uuid;
 END IF;
 IF kind='userSync' THEN
  INSERT INTO im_v2.realtime_control_versions(topic_kind,topic_id,version) VALUES(kind,id,1)
   ON CONFLICT(topic_kind,topic_id) DO UPDATE SET version=im_v2.realtime_control_versions.version+1 RETURNING version INTO uv;
 END IF;
 IF kind='userSync' THEN
  IF TG_TABLE_NAME='room_memberships' THEN
   UPDATE im_v2.realtime_control_versions SET membership_discovery_version=uv WHERE topic_kind=kind AND topic_id=id;
  ELSE
   UPDATE im_v2.realtime_control_versions SET session_control_version=uv WHERE topic_kind=kind AND topic_id=id;
   INSERT INTO im_v2.realtime_device_control_versions(user_id,device_id,latest_change_version)
    VALUES(id::uuid,dev,uv) ON CONFLICT(user_id,device_id) DO UPDATE SET latest_change_version=EXCLUDED.latest_change_version;
  END IF;
 END IF;
 IF TG_TABLE_NAME='room_memberships' THEN
  INSERT INTO im_v2.realtime_control_versions(topic_kind,topic_id,version) VALUES('roomEvents',r->>'room_id',1)
   ON CONFLICT(topic_kind,topic_id) DO UPDATE SET version=im_v2.realtime_control_versions.version+1 RETURNING version INTO rv;
  INSERT INTO im_v2.realtime_change_outbox(partition_id,topic_kind,topic_id,change_kind,room_control_version,owner_epoch)
   VALUES(im_v2.realtime_topic_partition('roomEvents',r->>'room_id'),'roomEvents',r->>'room_id','membership.changed',rv,(SELECT owner_epoch FROM im_v2.rooms WHERE room_id=(r->>'room_id')::uuid));
 END IF;
 IF kind='roomEvents' THEN
  SELECT owner_epoch INTO oe FROM im_v2.rooms WHERE room_id=id::uuid;
  IF rv IS NULL THEN SELECT coalesce((SELECT version FROM im_v2.realtime_control_versions WHERE topic_kind=kind AND topic_id=id),0) INTO rv; END IF;
 END IF;
 -- Control changes refresh metadata on an existing H, without merging their
 -- journal history. Pending H delivery must carry the current version floor.
 IF TG_TABLE_NAME='rooms' AND TG_OP='DELETE' THEN
  DELETE FROM im_v2.realtime_dirty_room_heads WHERE room_id=(r->>'room_id')::uuid;
 END IF;
 IF TG_TABLE_NAME IN ('rooms','room_memberships') THEN
  SELECT owner_epoch INTO oe FROM im_v2.rooms WHERE room_id=(r->>'room_id')::uuid;
  IF oe IS NOT NULL THEN
   INSERT INTO im_v2.realtime_dirty_room_heads(room_id,partition_id,room_sequence,owner_epoch,room_control_version)
    SELECT room_id,im_v2.realtime_topic_partition('roomEvents',room_id::text),room_sequence,oe,rv
    FROM im_v2.rooms WHERE room_id=(r->>'room_id')::uuid
   ON CONFLICT(room_id) DO UPDATE SET owner_epoch=EXCLUDED.owner_epoch,
    room_sequence=greatest(im_v2.realtime_dirty_room_heads.room_sequence,EXCLUDED.room_sequence),
    room_control_version=EXCLUDED.room_control_version,
    revision=im_v2.realtime_dirty_room_heads.revision+1,pending=true;
  END IF;
 END IF;
 INSERT INTO im_v2.realtime_change_outbox(source_event_id,partition_id,topic_kind,topic_id,change_kind,room_sequence,room_control_version,user_control_version,device_id,owner_epoch,membership_room_id)
 VALUES(coalesce(source,gen_random_uuid()),im_v2.realtime_topic_partition(kind,id),kind,id,ck,seq,rv,uv,dev,oe,CASE WHEN TG_TABLE_NAME='room_memberships' THEN (r->>'room_id')::uuid ELSE NULL END) ON CONFLICT(source_event_id) DO NOTHING;
 RETURN NULL;
END $$;
-- Transition-table aggregation captures every INSERT writer, including COPY
-- and fast append, while locking/updating each affected room only once per statement.
CREATE OR REPLACE FUNCTION im_v2.capture_realtime_room_events_heads() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 INSERT INTO im_v2.realtime_dirty_room_heads(room_id,partition_id,room_sequence,owner_epoch,room_control_version)
 SELECT h.room_id,im_v2.realtime_topic_partition('roomEvents',h.room_id::text),h.room_sequence,
        r.owner_epoch,coalesce(v.version,0)
 FROM (SELECT room_id,max(room_sequence) AS room_sequence FROM new_realtime_rows GROUP BY room_id) h
 JOIN im_v2.rooms r USING(room_id)
 LEFT JOIN im_v2.realtime_control_versions v ON v.topic_kind='roomEvents' AND v.topic_id=h.room_id::text
 ORDER BY h.room_id
 ON CONFLICT(room_id) DO UPDATE SET
  room_sequence=greatest(im_v2.realtime_dirty_room_heads.room_sequence,EXCLUDED.room_sequence),
  owner_epoch=greatest(im_v2.realtime_dirty_room_heads.owner_epoch,EXCLUDED.owner_epoch),
  room_control_version=greatest(im_v2.realtime_dirty_room_heads.room_control_version,EXCLUDED.room_control_version),
  revision=im_v2.realtime_dirty_room_heads.revision+1,pending=true;
 RETURN NULL;
END $$;
-- Transition-table aggregation captures every INSERT writer, including COPY
-- and fast append, while locking/updating each affected room only once per statement.
CREATE OR REPLACE FUNCTION im_v2.capture_realtime_messages_heads() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 INSERT INTO im_v2.realtime_dirty_room_heads(room_id,partition_id,room_sequence,owner_epoch,room_control_version)
 SELECT h.room_id,im_v2.realtime_topic_partition('roomEvents',h.room_id::text),h.room_sequence,
        r.owner_epoch,coalesce(v.version,0)
 FROM (SELECT room_id,max(room_sequence) AS room_sequence FROM new_realtime_rows WHERE accepted_event_storage='message_row' GROUP BY room_id) h
 JOIN im_v2.rooms r USING(room_id)
 LEFT JOIN im_v2.realtime_control_versions v ON v.topic_kind='roomEvents' AND v.topic_id=h.room_id::text
 ORDER BY h.room_id
 ON CONFLICT(room_id) DO UPDATE SET
  room_sequence=greatest(im_v2.realtime_dirty_room_heads.room_sequence,EXCLUDED.room_sequence),
  owner_epoch=greatest(im_v2.realtime_dirty_room_heads.owner_epoch,EXCLUDED.owner_epoch),
  room_control_version=greatest(im_v2.realtime_dirty_room_heads.room_control_version,EXCLUDED.room_control_version),
  revision=im_v2.realtime_dirty_room_heads.revision+1,pending=true;
 RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS realtime_journal_capture ON im_v2.room_events;
CREATE TRIGGER realtime_journal_capture AFTER INSERT ON im_v2.room_events REFERENCING NEW TABLE AS new_realtime_rows FOR EACH STATEMENT EXECUTE FUNCTION im_v2.capture_realtime_room_events_heads();
DROP TRIGGER IF EXISTS realtime_journal_capture ON im_v2.messages;
CREATE TRIGGER realtime_journal_capture AFTER INSERT ON im_v2.messages REFERENCING NEW TABLE AS new_realtime_rows FOR EACH STATEMENT EXECUTE FUNCTION im_v2.capture_realtime_messages_heads();
DROP TRIGGER IF EXISTS realtime_journal_capture ON im_v2.room_memberships;
CREATE TRIGGER realtime_journal_capture AFTER INSERT OR UPDATE OR DELETE ON im_v2.room_memberships FOR EACH ROW EXECUTE FUNCTION im_v2.capture_realtime_change();
DROP TRIGGER IF EXISTS realtime_journal_capture ON im_v2.auth_devices;
CREATE TRIGGER realtime_journal_capture AFTER INSERT OR UPDATE OR DELETE ON im_v2.auth_devices FOR EACH ROW EXECUTE FUNCTION im_v2.capture_realtime_change();
DROP TRIGGER IF EXISTS realtime_journal_capture ON im_v2.device_refresh_sessions;
CREATE TRIGGER realtime_journal_capture AFTER INSERT OR UPDATE OR DELETE ON im_v2.device_refresh_sessions FOR EACH ROW EXECUTE FUNCTION im_v2.capture_realtime_change();

DROP TRIGGER IF EXISTS realtime_journal_capture ON im_v2.rooms;
CREATE TRIGGER realtime_journal_capture AFTER INSERT OR UPDATE OR DELETE ON im_v2.rooms FOR EACH ROW EXECUTE FUNCTION im_v2.capture_realtime_change();

-- Unlike payload journal retention, publication floors cannot be time-trimmed.
-- Their cardinality is control topics, not messages/events. A floor can retire
-- only with its permanently retired source topic and version allocator together.

COMMIT;
