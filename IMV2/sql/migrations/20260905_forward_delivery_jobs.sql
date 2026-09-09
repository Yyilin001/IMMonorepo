BEGIN;
DO $$ BEGIN
    IF (SELECT count(*) FROM im_v2.schema_contract WHERE schema_id = 'im-v2-current-14') <> 1 THEN
        RAISE EXCEPTION 'forward delivery migration requires schema 14';
    END IF;
END $$;
CREATE TABLE im_v2.message_forward_delivery_jobs (
    export_id uuid PRIMARY KEY REFERENCES im_v2.message_forward_exports(export_id) ON DELETE RESTRICT,
    state text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'claimed', 'paused', 'completed')),
    claim_token uuid,
    lease_expires_at timestamptz,
    next_attempt_at timestamptz,
    retry_count bigint NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
    created_at timestamptz NOT NULL,
    completed_at timestamptz,
    CONSTRAINT message_forward_delivery_jobs_shape_check CHECK (
        ((state = 'claimed') = (claim_token IS NOT NULL)) AND ((state = 'claimed') = (lease_expires_at IS NOT NULL))
        AND ((state = 'pending') = (next_attempt_at IS NOT NULL))
        AND ((state = 'completed') = (completed_at IS NOT NULL))
    )
);
CREATE INDEX message_forward_delivery_jobs_ready_idx ON im_v2.message_forward_delivery_jobs (next_attempt_at, created_at, export_id) WHERE state = 'pending';
CREATE INDEX message_forward_delivery_jobs_lease_idx ON im_v2.message_forward_delivery_jobs (lease_expires_at, export_id) WHERE state = 'claimed';
CREATE FUNCTION im_v2.reject_forward_delivery_job_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'forward delivery identity cannot be deleted' USING ERRCODE = '23514';
    END IF;
    IF ROW(NEW.export_id, NEW.created_at) IS DISTINCT FROM ROW(OLD.export_id, OLD.created_at)
       OR (OLD.state = 'completed' AND NEW IS DISTINCT FROM OLD)
       OR (OLD.state = 'pending' AND NEW.state NOT IN ('pending', 'claimed'))
       OR (OLD.state = 'paused' AND NEW.state NOT IN ('paused', 'pending')) THEN
        RAISE EXCEPTION 'forward delivery identity and terminal result are immutable' USING ERRCODE = '23514';
    END IF;
    IF NEW.state = 'completed' AND NOT EXISTS(SELECT 1 FROM im_v2.message_forward_export_receipts WHERE export_id = NEW.export_id) THEN
        RAISE EXCEPTION 'forward delivery completion requires source receipt' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER message_forward_delivery_jobs_immutable BEFORE UPDATE OR DELETE ON im_v2.message_forward_delivery_jobs
    FOR EACH ROW EXECUTE FUNCTION im_v2.reject_forward_delivery_job_mutation();

INSERT INTO im_v2.message_forward_delivery_jobs (export_id, state, next_attempt_at, created_at)
SELECT export.export_id, 'pending', export.created_at, export.created_at FROM im_v2.message_forward_exports AS export
WHERE NOT EXISTS(SELECT 1 FROM im_v2.message_forward_export_receipts AS receipt WHERE receipt.export_id = export.export_id);
ALTER TABLE im_v2.schema_contract DROP CONSTRAINT schema_contract_schema_id_check;
ALTER TABLE im_v2.schema_contract ALTER COLUMN schema_id SET DEFAULT 'im-v2-current-15';
UPDATE im_v2.schema_contract SET schema_id = 'im-v2-current-15';
ALTER TABLE im_v2.schema_contract ADD CONSTRAINT schema_contract_schema_id_check CHECK (schema_id = 'im-v2-current-15');
COMMIT;
