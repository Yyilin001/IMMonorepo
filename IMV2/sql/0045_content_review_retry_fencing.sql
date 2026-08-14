-- Content review providers can be slower than one lease and can fail for long
-- periods. Keep transient failures out of the hot claim lane and pause work
-- after the shared durable retry budget is exhausted.
ALTER TABLE im_v2.content_review_jobs
    DROP CONSTRAINT IF EXISTS content_review_jobs_state_check;
ALTER TABLE im_v2.content_review_jobs
    ADD CONSTRAINT content_review_jobs_state_check
    CHECK (state IN ('pending', 'claimed', 'completed', 'superseded', 'paused'));

ALTER TABLE im_v2.content_review_jobs
    ADD COLUMN next_attempt_at TIMESTAMPTZ NULL,
    ADD COLUMN paused_at TIMESTAMPTZ NULL,
    ADD COLUMN finding_category TEXT NULL,
    ADD COLUMN finding_severity SMALLINT NULL,
    ADD COLUMN finding_confidence DOUBLE PRECISION NULL;

ALTER TABLE im_v2.content_review_jobs
    ADD CONSTRAINT content_review_jobs_retry_state_check
    CHECK (
        (state = 'paused' AND paused_at IS NOT NULL AND next_attempt_at IS NULL)
        OR (state <> 'paused' AND paused_at IS NULL)
    ),
    ADD CONSTRAINT content_review_jobs_staged_finding_check
    CHECK (
        (finding_category IS NULL AND finding_severity IS NULL AND finding_confidence IS NULL)
        OR (
            decision IN ('review_required', 'violation')
            AND octet_length(finding_category) BETWEEN 1 AND 64
            AND finding_severity BETWEEN 0 AND 4
            AND finding_confidence >= 0 AND finding_confidence <= 1
        )
    );

DROP INDEX IF EXISTS im_v2.content_review_jobs_claim_idx;
CREATE INDEX content_review_jobs_claim_idx
    ON im_v2.content_review_jobs (state, next_attempt_at, lease_expires_at, created_at, message_id);

-- Paused review work uses the existing authenticated, audited, single-target
-- operator replay boundary. The source_event_id column carries the stable
-- message UUID for this target kind; no user or projection selector is legal.
ALTER TABLE im_v2.durable_work_replay_audit
    DROP CONSTRAINT IF EXISTS durable_work_replay_audit_target_kind_check,
    DROP CONSTRAINT IF EXISTS durable_work_replay_audit_check;
ALTER TABLE im_v2.durable_work_replay_audit
    ADD CONSTRAINT durable_work_replay_audit_target_kind_check
        CHECK (target_kind IN ('room_outbox', 'fanout_delivery', 'content_review')),
    ADD CONSTRAINT durable_work_replay_audit_target_shape_check
        CHECK (
            (target_kind IN ('room_outbox', 'content_review') AND target_user_id IS NULL AND projection_kind IS NULL)
            OR (target_kind = 'fanout_delivery' AND target_user_id IS NOT NULL AND projection_kind IS NOT NULL)
        );
