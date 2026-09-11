-- Add the conversation-ordering timestamp to rooms and maintain it from the
-- room sequence. New environments install schema.sql directly.
--
-- The backfill deliberately anchors on the newest durable room fact instead of
-- the migration clock: an old room must not look newly active because it
-- happened to be migrated today.
--
-- 该迁移可重复执行：迁移链夹具从 canonical schema 出发（其中已包含本列、索引与
-- 触发器），只把 schema 合同号回退到旧值，因此每个对象都必须幂等创建。
BEGIN;
DO $$ BEGIN
    IF (SELECT count(*) FROM im_v2.schema_contract
        WHERE schema_id IN ('im-v2-current-30', 'im-v2-current-31')) <> 1 THEN
        RAISE EXCEPTION 'expected current-30 before room activity migration';
    END IF;
END $$;

ALTER TABLE im_v2.rooms ADD COLUMN IF NOT EXISTS last_event_at timestamp with time zone;

UPDATE im_v2.rooms AS room
SET last_event_at = GREATEST(
    room.created_at,
    COALESCE(
        (
            SELECT max(event.created_at)
            FROM im_v2.room_events AS event
            WHERE event.room_id = room.room_id
        ),
        room.created_at
    ),
    COALESCE(
        (
            SELECT max(message.created_at)
            FROM im_v2.messages AS message
            WHERE message.room_id = room.room_id
              AND message.accepted_event_storage = 'message_row'
        ),
        room.created_at
    )
);

ALTER TABLE im_v2.rooms ALTER COLUMN last_event_at SET NOT NULL;
ALTER TABLE im_v2.rooms ALTER COLUMN last_event_at SET DEFAULT now();

CREATE OR REPLACE FUNCTION im_v2.touch_room_last_event_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.room_sequence IS DISTINCT FROM OLD.room_sequence THEN
        NEW.last_event_at := CURRENT_TIMESTAMP;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS rooms_touch_last_event_at ON im_v2.rooms;
CREATE TRIGGER rooms_touch_last_event_at BEFORE UPDATE ON im_v2.rooms
    FOR EACH ROW EXECUTE FUNCTION im_v2.touch_room_last_event_at();

CREATE INDEX IF NOT EXISTS rooms_last_event_at_idx
    ON im_v2.rooms (last_event_at DESC, room_id);

-- 支持"未读排除自己发的消息"：每个房间按发送者取最新序号时只走索引。
CREATE INDEX IF NOT EXISTS messages_room_sender_sequence_idx
    ON im_v2.messages (room_id, sender_user_id, room_sequence DESC);

ALTER TABLE im_v2.schema_contract DROP CONSTRAINT schema_contract_schema_id_check;
ALTER TABLE im_v2.schema_contract ALTER COLUMN schema_id SET DEFAULT 'im-v2-current-31';
UPDATE im_v2.schema_contract SET schema_id = 'im-v2-current-31';
ALTER TABLE im_v2.schema_contract ADD CONSTRAINT schema_contract_schema_id_check CHECK (schema_id = 'im-v2-current-31');
COMMIT;
