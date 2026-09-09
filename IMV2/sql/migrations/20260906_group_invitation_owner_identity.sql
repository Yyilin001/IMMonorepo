-- Drain old invitation writers before enabling control-validated owner access.
-- User UUIDs remain stable references, but a physical owner is not an account DB.
BEGIN;
DO $$ BEGIN
    IF (SELECT count(*) FROM im_v2.schema_contract WHERE schema_id = 'im-v2-current-22') <> 1 THEN
        RAISE EXCEPTION 'expected current-22 before invitation owner identity migration';
    END IF;
END $$;
ALTER TABLE im_v2.group_invite_links DROP CONSTRAINT group_invite_links_created_by_user_id_fkey;
ALTER TABLE im_v2.group_invite_links DROP CONSTRAINT group_invite_links_revoked_by_user_id_fkey;
ALTER TABLE im_v2.group_join_requests DROP CONSTRAINT group_join_requests_applicant_user_id_fkey;
ALTER TABLE im_v2.group_join_requests DROP CONSTRAINT group_join_requests_decided_by_user_id_fkey;
ALTER TABLE im_v2.schema_contract DROP CONSTRAINT schema_contract_schema_id_check;
ALTER TABLE im_v2.schema_contract ALTER COLUMN schema_id SET DEFAULT 'im-v2-current-23';
UPDATE im_v2.schema_contract SET schema_id = 'im-v2-current-23';
ALTER TABLE im_v2.schema_contract ADD CONSTRAINT schema_contract_schema_id_check CHECK (schema_id = 'im-v2-current-23');
COMMIT;
