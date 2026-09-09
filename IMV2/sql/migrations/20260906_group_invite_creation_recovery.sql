-- Drain old invitation writers so every prepared intent has a durable job.
BEGIN;
DO $$ BEGIN
    IF (SELECT count(*) FROM im_v2.schema_contract WHERE schema_id = 'im-v2-current-23') <> 1 THEN
        RAISE EXCEPTION 'expected current-23 before invite creation recovery migration';
    END IF;
END $$;
CREATE TABLE im_v2.group_invite_creation_recovery (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    state text NOT NULL,
    attempt_count bigint NOT NULL,
    next_attempt_at timestamptz NOT NULL,
    claim_token uuid,
    lease_expires_at timestamptz,
    last_error_code text,
    updated_at timestamptz NOT NULL,
    completed_at timestamptz,
    CONSTRAINT group_invite_creation_recovery_pkey PRIMARY KEY (actor_user_id, operation_id),
    CONSTRAINT group_invite_creation_recovery_intent_fkey FOREIGN KEY (actor_user_id, operation_id)
        REFERENCES im_v2.group_invite_directory(actor_user_id, operation_id) ON DELETE RESTRICT,
    CONSTRAINT group_invite_creation_recovery_state_check CHECK (state IN ('pending','claimed','completed','paused')),
    CONSTRAINT group_invite_creation_recovery_attempt_check CHECK (attempt_count >= 0 AND attempt_count <= 1000),
    CONSTRAINT group_invite_creation_recovery_claim_check CHECK ((state = 'claimed') = (claim_token IS NOT NULL)),
    CONSTRAINT group_invite_creation_recovery_lease_check CHECK ((state = 'claimed') = (lease_expires_at IS NOT NULL)),
    CONSTRAINT group_invite_creation_recovery_completed_check CHECK ((state = 'completed') = (completed_at IS NOT NULL)),
    CONSTRAINT group_invite_creation_recovery_paused_check CHECK (state <> 'paused' OR last_error_code IS NOT NULL),
    CONSTRAINT group_invite_creation_recovery_error_check CHECK (last_error_code IN ('dependency_unavailable','owner_changed','rate_limited','permission_denied','creation_expired','conflicting_evidence'))
);
CREATE INDEX group_invite_creation_recovery_pending_idx ON im_v2.group_invite_creation_recovery
    (next_attempt_at, actor_user_id, operation_id) WHERE state = 'pending';
CREATE INDEX group_invite_creation_recovery_lease_idx ON im_v2.group_invite_creation_recovery
    (lease_expires_at, actor_user_id, operation_id) WHERE state = 'claimed';

INSERT INTO im_v2.group_invite_creation_recovery
    (actor_user_id, operation_id, state, attempt_count, next_attempt_at, updated_at)
SELECT actor_user_id, operation_id, 'pending', 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
FROM im_v2.group_invite_directory WHERE state = 'prepared';
ALTER TABLE im_v2.schema_contract DROP CONSTRAINT schema_contract_schema_id_check;
ALTER TABLE im_v2.schema_contract ALTER COLUMN schema_id SET DEFAULT 'im-v2-current-24';
UPDATE im_v2.schema_contract SET schema_id = 'im-v2-current-24';
ALTER TABLE im_v2.schema_contract ADD CONSTRAINT schema_contract_schema_id_check CHECK (schema_id = 'im-v2-current-24');
COMMIT;
