-- 给房间加"已裁剪的历史下界"，并让保留裁剪成为唯一允许删除房间事件的路径。
--
-- 保留窗口的依据是**活跃读者的已读线下界**：读者还在窗口内活动时，其已读线以下的
-- 历史不承担送达义务；超出窗口不再活跃的读者不再钉住下界，返回时会被显式告知
-- "历史不完整"（该标记由房间列暴露给读取方）。
--
-- 该迁移可重复执行：迁移链夹具从 canonical schema 出发（其中已包含列、约束与触发器），
-- 只把 schema 合同号回退到旧值，因此每个对象都必须幂等创建。
BEGIN;
DO $$ BEGIN
    IF (SELECT count(*) FROM im_v2.schema_contract
        WHERE schema_id IN ('im-v2-current-32', 'im-v2-current-33')) <> 1 THEN
        RAISE EXCEPTION 'expected current-32 before room log retention migration';
    END IF;
END $$;

ALTER TABLE im_v2.rooms
    ADD COLUMN IF NOT EXISTS log_trimmed_through_room_sequence bigint;

UPDATE im_v2.rooms
SET log_trimmed_through_room_sequence = 0
WHERE log_trimmed_through_room_sequence IS NULL;

ALTER TABLE im_v2.rooms ALTER COLUMN log_trimmed_through_room_sequence SET NOT NULL;
ALTER TABLE im_v2.rooms ALTER COLUMN log_trimmed_through_room_sequence SET DEFAULT 0;
ALTER TABLE im_v2.rooms DROP CONSTRAINT IF EXISTS rooms_log_trimmed_through_check;
ALTER TABLE im_v2.rooms ADD CONSTRAINT rooms_log_trimmed_through_check
    CHECK (log_trimmed_through_room_sequence >= 0);

CREATE OR REPLACE FUNCTION im_v2.reject_room_event_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF TG_OP = 'DELETE' AND current_setting('im_v2.retention_trim', TRUE) = 'on' THEN
        IF EXISTS (
            SELECT 1 FROM im_v2.rooms AS room
            WHERE room.room_id = OLD.room_id
              AND OLD.room_sequence < room.log_trimmed_through_room_sequence
        ) THEN
            RETURN OLD;
        END IF;
    END IF;
    RAISE EXCEPTION 'room events are append-only';
END;
$$;

ALTER TABLE im_v2.schema_contract DROP CONSTRAINT schema_contract_schema_id_check;
ALTER TABLE im_v2.schema_contract ALTER COLUMN schema_id SET DEFAULT 'im-v2-current-33';
UPDATE im_v2.schema_contract SET schema_id = 'im-v2-current-33';
ALTER TABLE im_v2.schema_contract ADD CONSTRAINT schema_contract_schema_id_check CHECK (schema_id = 'im-v2-current-33');
COMMIT;
