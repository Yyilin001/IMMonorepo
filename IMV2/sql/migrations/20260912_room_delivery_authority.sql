-- 给房间加"权威副本形态"这一列，让标准群也能在不重建房间的前提下切到读模型。
--
-- 投递模式（delivery_mode）描述用哪种扇出规划器，并在房间创建后不可变；把两者分开之后，
-- 群聊的权威副本形态可以按房间推进，而单聊继续由部署开关决定、忽略本列。
--
-- 回填必须与既有行为逐字相同：混合大群一直是房间日志，其余（含单聊）填 fanout；
-- 单聊的写入路径不读本列，因此部署开关的回滚能力不受影响。
--
-- 该迁移可重复执行：迁移链夹具从 canonical schema 出发（其中已包含本列与约束），
-- 只把 schema 合同号回退到旧值，因此每个对象都必须幂等创建。
BEGIN;
DO $$ BEGIN
    IF (SELECT count(*) FROM im_v2.schema_contract
        WHERE schema_id IN ('im-v2-current-31', 'im-v2-current-32')) <> 1 THEN
        RAISE EXCEPTION 'expected current-31 before room delivery authority migration';
    END IF;
END $$;

ALTER TABLE im_v2.rooms ADD COLUMN IF NOT EXISTS delivery_authority text;

UPDATE im_v2.rooms
SET delivery_authority = CASE
    WHEN delivery_mode = 'large_group_hybrid' THEN 'room_log'
    ELSE 'fanout'
END
WHERE delivery_authority IS NULL;

ALTER TABLE im_v2.rooms ALTER COLUMN delivery_authority SET NOT NULL;
ALTER TABLE im_v2.rooms ALTER COLUMN delivery_authority SET DEFAULT 'fanout';
ALTER TABLE im_v2.rooms DROP CONSTRAINT IF EXISTS rooms_delivery_authority_check;
ALTER TABLE im_v2.rooms ADD CONSTRAINT rooms_delivery_authority_check
    CHECK (delivery_authority = ANY (ARRAY['fanout'::text, 'room_log'::text]));

ALTER TABLE im_v2.schema_contract DROP CONSTRAINT schema_contract_schema_id_check;
ALTER TABLE im_v2.schema_contract ALTER COLUMN schema_id SET DEFAULT 'im-v2-current-32';
UPDATE im_v2.schema_contract SET schema_id = 'im-v2-current-32';
ALTER TABLE im_v2.schema_contract ADD CONSTRAINT schema_contract_schema_id_check CHECK (schema_id = 'im-v2-current-32');
COMMIT;
