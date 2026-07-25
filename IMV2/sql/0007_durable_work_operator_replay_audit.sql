-- Operator replay is an explicit, authenticated control-plane action. Its
-- audit evidence and its paused->pending transition commit atomically; this
-- table is never a generic job runner or a place for free-form incident text.

CREATE TABLE im_v2.durable_work_replay_audit (
    operation_id UUID PRIMARY KEY,
    operator_principal TEXT NOT NULL CHECK (char_length(operator_principal) BETWEEN 1 AND 128),
    target_kind TEXT NOT NULL CHECK (target_kind IN ('room_outbox', 'fanout_delivery')),
    source_event_id UUID NOT NULL,
    target_user_id UUID NULL,
    projection_kind TEXT NULL CHECK (projection_kind IS NULL OR char_length(projection_kind) BETWEEN 1 AND 64),
    reason_code TEXT NOT NULL CHECK (reason_code IN ('dependency_recovered', 'data_repaired', 'false_positive')),
    requested_at TIMESTAMPTZ NOT NULL,
    outcome TEXT NOT NULL CHECK (outcome IN ('processing', 'requeued', 'not_paused')),
    CHECK (
        (target_kind = 'room_outbox' AND target_user_id IS NULL AND projection_kind IS NULL) OR
        (target_kind = 'fanout_delivery' AND target_user_id IS NOT NULL AND projection_kind IS NOT NULL)
    )
);

CREATE INDEX durable_work_replay_audit_requested_at_idx
    ON im_v2.durable_work_replay_audit (requested_at DESC);
