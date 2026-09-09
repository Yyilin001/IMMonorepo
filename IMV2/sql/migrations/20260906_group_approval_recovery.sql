-- Drain every old membership, approval and housekeeping writer first.
-- Historical membership intervals must be complete; recovery never uses
-- current membership as evidence of a legacy operation's outcome.
BEGIN;
DO $$ BEGIN
    IF (SELECT count(*) FROM im_v2.schema_contract WHERE schema_id = 'im-v2-current-20') <> 1 THEN
        RAISE EXCEPTION 'expected current-20 before approval recovery migration';
    END IF;
END $$;
CREATE TABLE im_v2.group_join_approval_recovery_audit (
    operation_id uuid PRIMARY KEY,
    operator_principal text NOT NULL,
    shard_id text NOT NULL,
    owner_epoch bigint NOT NULL CHECK (owner_epoch >= 0),
    room_id uuid NOT NULL,
    request_id uuid NOT NULL,
    reviewer_user_id uuid NOT NULL,
    decision_operation_id uuid NOT NULL,
    reason_code text NOT NULL CHECK (reason_code IN ('dependency_recovered', 'data_repaired', 'false_positive')),
    outcome text NOT NULL CHECK (outcome IN ('completed', 'released', 'quarantined', 'not_approving')),
    detail text NOT NULL CHECK (detail IN ('committed_operation', 'no_historical_add', 'operation_mismatch', 'historical_add_without_receipt', 'invalid_revision', 'invite_exhausted', 'not_approving')),
    requested_at timestamp with time zone NOT NULL,
    applicant_user_id uuid NOT NULL,
    prepared_revision bigint,
    member_room_id uuid,
    member_target_user_id uuid,
    member_action text,
    expected_revision bigint,
    resulting_revision bigint,
    room_sequence bigint,
    event_id uuid,
    plan_id uuid,
    CONSTRAINT group_join_approval_recovery_audit_result_check CHECK (
        (member_room_id IS NULL AND member_target_user_id IS NULL AND member_action IS NULL AND expected_revision IS NULL AND resulting_revision IS NULL AND room_sequence IS NULL AND event_id IS NULL AND plan_id IS NULL)
        OR (member_room_id IS NOT NULL AND member_target_user_id IS NOT NULL AND member_action IS NOT NULL AND expected_revision IS NOT NULL AND resulting_revision IS NOT NULL AND room_sequence IS NOT NULL AND event_id IS NOT NULL AND plan_id IS NOT NULL)
    ),
    CONSTRAINT group_join_approval_recovery_audit_completed_check CHECK (outcome <> 'completed' OR expected_revision IS NOT NULL)
);

CREATE TABLE im_v2.room_membership_operation_fences (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    room_id uuid NOT NULL,
    request_id uuid NOT NULL,
    recovery_operation_id uuid NOT NULL REFERENCES im_v2.group_join_approval_recovery_audit(operation_id) ON DELETE RESTRICT,
    created_at timestamp with time zone NOT NULL,
    PRIMARY KEY (actor_user_id, operation_id)
);

CREATE FUNCTION im_v2.reject_approval_recovery_mutation() RETURNS trigger
    LANGUAGE plpgsql AS $$BEGIN RAISE EXCEPTION 'approval recovery evidence is immutable'; END;$$;

CREATE TRIGGER group_join_approval_recovery_audit_immutable
    BEFORE UPDATE OR DELETE ON im_v2.group_join_approval_recovery_audit
    FOR EACH ROW EXECUTE FUNCTION im_v2.reject_approval_recovery_mutation();
CREATE TRIGGER room_membership_operation_fences_immutable
    BEFORE UPDATE OR DELETE ON im_v2.room_membership_operation_fences
    FOR EACH ROW EXECUTE FUNCTION im_v2.reject_approval_recovery_mutation();
CREATE INDEX group_join_requests_approving_recovery_idx
    ON im_v2.group_join_requests (room_id, request_id) WHERE state = 'approving';

ALTER TABLE im_v2.schema_contract DROP CONSTRAINT schema_contract_schema_id_check;
ALTER TABLE im_v2.schema_contract ALTER COLUMN schema_id SET DEFAULT 'im-v2-current-21';
UPDATE im_v2.schema_contract SET schema_id = 'im-v2-current-21';
ALTER TABLE im_v2.schema_contract ADD CONSTRAINT schema_contract_schema_id_check CHECK (schema_id = 'im-v2-current-21');
COMMIT;
