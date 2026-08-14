-- Disabling direct read receipts can affect an arbitrarily large direct-room
-- graph. Keep that graph traversal off the interactive command transaction
-- and advance it in lease-fenced, cursor-bounded worker pages.
CREATE TABLE im_v2.read_receipt_preference_propagation_outbox (
    actor_user_id UUID NOT NULL,
    operation_id UUID NOT NULL,
    recorded_at TIMESTAMPTZ NOT NULL,
    state TEXT NOT NULL DEFAULT 'pending'
        CHECK (state IN ('pending', 'claimed', 'completed', 'paused')),
    claim_token UUID NULL,
    lease_expires_at TIMESTAMPTZ NULL,
    next_attempt_at TIMESTAMPTZ NULL,
    paused_at TIMESTAMPTZ NULL,
    last_failure_code TEXT NULL,
    enumeration_checkpoint UUID NULL,
    retry_count BIGINT NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
    created_at TIMESTAMPTZ NOT NULL,
    completed_at TIMESTAMPTZ NULL,
    PRIMARY KEY (actor_user_id, operation_id),
    FOREIGN KEY (actor_user_id, operation_id)
        REFERENCES im_v2.read_receipt_preference_operations(actor_user_id, operation_id)
        ON DELETE RESTRICT,
    CHECK ((state = 'claimed') = (claim_token IS NOT NULL)),
    CHECK ((state = 'claimed') = (lease_expires_at IS NOT NULL)),
    CHECK ((state = 'completed') = (completed_at IS NOT NULL)),
    CHECK ((state = 'paused') = (paused_at IS NOT NULL)),
    CHECK (next_attempt_at IS NULL OR state = 'pending')
);

CREATE INDEX read_receipt_preference_propagation_claim_idx
    ON im_v2.read_receipt_preference_propagation_outbox
        (state, next_attempt_at, lease_expires_at, created_at, actor_user_id, operation_id)
    WHERE state IN ('pending', 'claimed');

CREATE INDEX read_receipt_preference_propagation_completed_cleanup_idx
    ON im_v2.read_receipt_preference_propagation_outbox
        (completed_at, actor_user_id, operation_id)
    WHERE state = 'completed';

-- The stable preference operation UUID is the replay source_event_id; its
-- owning account is target_user_id. This preserves the existing single-row,
-- audited operator replay shape without exposing room/contact identifiers.
ALTER TABLE im_v2.durable_work_replay_audit
    DROP CONSTRAINT durable_work_replay_audit_target_kind_check,
    DROP CONSTRAINT durable_work_replay_audit_target_shape_check;
ALTER TABLE im_v2.durable_work_replay_audit
    ADD CONSTRAINT durable_work_replay_audit_target_kind_check
        CHECK (target_kind IN ('room_outbox', 'fanout_delivery', 'content_review',
                              'media_scan', 'media_purge', 'read_receipt_preference_propagation')),
    ADD CONSTRAINT durable_work_replay_audit_target_shape_check
        CHECK (
            (target_kind IN ('room_outbox', 'content_review', 'media_scan', 'media_purge')
                AND target_user_id IS NULL AND projection_kind IS NULL)
            OR (target_kind = 'fanout_delivery'
                AND target_user_id IS NOT NULL AND projection_kind IS NOT NULL)
            OR (target_kind = 'read_receipt_preference_propagation'
                AND target_user_id IS NOT NULL AND projection_kind IS NULL)
        );
