BEGIN;
DO $$ BEGIN
    IF (SELECT count(*) FROM im_v2.schema_contract WHERE schema_id = 'im-v2-current-15') <> 1 THEN
        RAISE EXCEPTION 'forward replay migration requires schema 15';
    END IF;
END $$;
CREATE TABLE im_v2.forward_work_replay_audit (
    operation_id uuid PRIMARY KEY,
    operator_principal text NOT NULL CHECK (char_length(operator_principal) BETWEEN 1 AND 128),
    shard_id text NOT NULL CHECK (char_length(shard_id) BETWEEN 1 AND 128),
    target_kind text NOT NULL,
    export_id uuid NOT NULL,
    ordinal integer,
    reason_code text NOT NULL CHECK (reason_code IN ('dependency_recovered', 'data_repaired', 'false_positive')),
    requested_at timestamptz NOT NULL,
    outcome text NOT NULL CHECK (outcome IN ('processing', 'requeued', 'not_paused')),
    CONSTRAINT forward_work_replay_audit_target_check CHECK (
        (target_kind = 'delivery' AND ordinal IS NULL)
        OR (target_kind = 'media' AND ordinal IS NOT NULL AND ordinal BETWEEN 0 AND 9)
    )
);
CREATE INDEX forward_work_replay_audit_requested_idx ON im_v2.forward_work_replay_audit (requested_at DESC);
CREATE FUNCTION im_v2.reject_forward_replay_audit_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'forward replay audit cannot be deleted' USING ERRCODE = '23514';
    END IF;
    IF ROW(NEW.operation_id, NEW.operator_principal, NEW.shard_id, NEW.target_kind, NEW.export_id, NEW.ordinal, NEW.reason_code, NEW.requested_at)
       IS DISTINCT FROM ROW(OLD.operation_id, OLD.operator_principal, OLD.shard_id, OLD.target_kind, OLD.export_id, OLD.ordinal, OLD.reason_code, OLD.requested_at)
       OR (OLD.outcome <> 'processing' AND NEW IS DISTINCT FROM OLD)
       OR (OLD.outcome = 'processing' AND NEW.outcome NOT IN ('requeued', 'not_paused')) THEN
        RAISE EXCEPTION 'forward replay audit identity and result are immutable' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER forward_work_replay_audit_immutable BEFORE UPDATE OR DELETE ON im_v2.forward_work_replay_audit
    FOR EACH ROW EXECUTE FUNCTION im_v2.reject_forward_replay_audit_mutation();

ALTER TABLE im_v2.schema_contract DROP CONSTRAINT schema_contract_schema_id_check;
ALTER TABLE im_v2.schema_contract ALTER COLUMN schema_id SET DEFAULT 'im-v2-current-16';
UPDATE im_v2.schema_contract SET schema_id = 'im-v2-current-16';
ALTER TABLE im_v2.schema_contract ADD CONSTRAINT schema_contract_schema_id_check CHECK (schema_id = 'im-v2-current-16');
COMMIT;
