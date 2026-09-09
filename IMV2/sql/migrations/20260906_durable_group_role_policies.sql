-- Stop all schema-17 writers/readers/housekeeping before applying.
BEGIN;
DO $$ BEGIN
    IF (SELECT count(*) FROM im_v2.schema_contract WHERE schema_id = 'im-v2-current-17') <> 1 THEN
        RAISE EXCEPTION 'durable group policies require schema 17';
    END IF;
END $$;
LOCK TABLE im_v2.rooms, im_v2.group_role_permissions, im_v2.group_permission_operations, im_v2.room_events IN SHARE ROW EXCLUSIVE MODE;
CREATE TEMP TABLE group_policy_history ON COMMIT DROP AS
    SELECT room_id, role, resulting_revision AS revision FROM im_v2.group_permission_operations
    UNION
    SELECT room_id, payload->>'role', (payload->>'revision')::bigint
    FROM im_v2.room_events WHERE event_type = 'group.role_permissions_changed';
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM group_policy_history WHERE role IS NULL OR role NOT IN ('admin', 'member') OR revision IS NULL OR revision < 2)
       OR EXISTS (SELECT 1 FROM group_policy_history GROUP BY room_id, revision HAVING count(*) <> 1)
       OR EXISTS (
           SELECT 1 FROM im_v2.rooms AS room
           LEFT JOIN (SELECT room_id, count(*) AS count, min(revision) AS first, max(revision) AS last FROM group_policy_history GROUP BY room_id) AS history USING (room_id)
           WHERE (room.group_permission_revision > 1 AND (COALESCE(history.count, 0) <> room.group_permission_revision - 1 OR history.first <> 2 OR history.last <> room.group_permission_revision))
              OR (room.group_permission_revision = 1 AND history.count IS NOT NULL)
       ) THEN
        RAISE EXCEPTION 'incomplete group policy history: restore authoritative events before migration';
    END IF;
END $$;
CREATE TABLE im_v2.group_role_policies (
    room_id uuid NOT NULL,
    role text NOT NULL,
    CONSTRAINT group_role_policies_pkey PRIMARY KEY (room_id, role),
    CONSTRAINT group_role_policies_role_check CHECK (role IN ('admin', 'member'))
);

ALTER TABLE ONLY im_v2.group_role_policies
    ADD CONSTRAINT group_role_policies_room_id_fkey FOREIGN KEY (room_id) REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT;

INSERT INTO im_v2.group_role_policies (room_id, role)
    SELECT room_id, role FROM group_policy_history
    UNION SELECT room_id, role FROM im_v2.group_role_permissions;
ALTER TABLE im_v2.schema_contract DROP CONSTRAINT schema_contract_schema_id_check;
ALTER TABLE im_v2.schema_contract ALTER COLUMN schema_id SET DEFAULT 'im-v2-current-18';
UPDATE im_v2.schema_contract SET schema_id = 'im-v2-current-18';
ALTER TABLE im_v2.schema_contract ADD CONSTRAINT schema_contract_schema_id_check CHECK (schema_id = 'im-v2-current-18');
COMMIT;
