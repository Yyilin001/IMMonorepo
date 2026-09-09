-- Drain every old invitation/account-edge writer before this migration.
-- Duplicate legacy decisions must be investigated; never silently pick a row.
BEGIN;
DO $$ BEGIN
    IF (SELECT count(*) FROM im_v2.schema_contract WHERE schema_id = 'im-v2-current-19') <> 1 THEN
        RAISE EXCEPTION 'expected current-19 before atomic approval migration';
    END IF;
    IF EXISTS (
        SELECT 1 FROM im_v2.group_join_requests
        WHERE decided_by_user_id IS NOT NULL AND decision_operation_id IS NOT NULL
        GROUP BY decided_by_user_id, decision_operation_id HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'duplicate legacy group decision keys require investigation';
    END IF;
END $$;
ALTER TABLE im_v2.group_join_requests
    ADD CONSTRAINT group_join_requests_reviewer_decision_key UNIQUE (decided_by_user_id, decision_operation_id);
ALTER TABLE im_v2.schema_contract DROP CONSTRAINT schema_contract_schema_id_check;
ALTER TABLE im_v2.schema_contract ALTER COLUMN schema_id SET DEFAULT 'im-v2-current-20';
UPDATE im_v2.schema_contract SET schema_id = 'im-v2-current-20';
ALTER TABLE im_v2.schema_contract ADD CONSTRAINT schema_contract_schema_id_check CHECK (schema_id = 'im-v2-current-20');
COMMIT;
