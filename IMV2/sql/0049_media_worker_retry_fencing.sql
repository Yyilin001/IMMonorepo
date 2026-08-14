-- External scanner and object-provider outages must not hot-loop one media
-- row forever. Persist exponential retry deadlines and a paused state that an
-- audited operator action can explicitly requeue after exhaustion.
ALTER TABLE im_v2.media_scan_outbox
    DROP CONSTRAINT media_scan_outbox_state_check,
    ADD COLUMN next_attempt_at TIMESTAMPTZ NULL,
    ADD COLUMN paused_at TIMESTAMPTZ NULL,
    ADD CONSTRAINT media_scan_outbox_state_check
        CHECK (state IN ('pending', 'claimed', 'completed', 'paused')),
    ADD CONSTRAINT media_scan_outbox_paused_shape_check
        CHECK ((state = 'paused') = (paused_at IS NOT NULL)),
    ADD CONSTRAINT media_scan_outbox_retry_deadline_shape_check
        CHECK (next_attempt_at IS NULL OR state = 'pending');

DROP INDEX im_v2.media_scan_outbox_claim_idx;
CREATE INDEX media_scan_outbox_claim_idx
    ON im_v2.media_scan_outbox (state, next_attempt_at, lease_expires_at, created_at)
    WHERE state IN ('pending', 'claimed');

ALTER TABLE im_v2.media_purge_outbox
    DROP CONSTRAINT media_purge_outbox_state_check,
    ADD COLUMN next_attempt_at TIMESTAMPTZ NULL,
    ADD COLUMN paused_at TIMESTAMPTZ NULL,
    ADD CONSTRAINT media_purge_outbox_state_check
        CHECK (state IN ('pending', 'claimed', 'completed', 'paused')),
    ADD CONSTRAINT media_purge_outbox_paused_shape_check
        CHECK ((state = 'paused') = (paused_at IS NOT NULL)),
    ADD CONSTRAINT media_purge_outbox_retry_deadline_shape_check
        CHECK (next_attempt_at IS NULL OR state = 'pending'),
    ADD CONSTRAINT media_purge_outbox_claim_shape_check
        CHECK ((state = 'claimed') = (claim_token IS NOT NULL)),
    ADD CONSTRAINT media_purge_outbox_lease_shape_check
        CHECK ((state = 'claimed') = (lease_expires_at IS NOT NULL)),
    ADD CONSTRAINT media_purge_outbox_completion_shape_check
        CHECK ((state = 'completed') = (completed_at IS NOT NULL));

DROP INDEX im_v2.media_purge_outbox_claim_idx;
CREATE INDEX media_purge_outbox_claim_idx
    ON im_v2.media_purge_outbox (state, next_attempt_at, lease_expires_at, created_at)
    WHERE state IN ('pending', 'claimed');

-- Paused media jobs use the same authenticated and audited single-target
-- replay boundary as the other durable workers. source_event_id carries the
-- opaque media UUID; user/projection selectors are not legal for these kinds.
ALTER TABLE im_v2.durable_work_replay_audit
    DROP CONSTRAINT IF EXISTS durable_work_replay_audit_target_kind_check,
    DROP CONSTRAINT IF EXISTS durable_work_replay_audit_target_shape_check;
ALTER TABLE im_v2.durable_work_replay_audit
    ADD CONSTRAINT durable_work_replay_audit_target_kind_check
        CHECK (target_kind IN ('room_outbox', 'fanout_delivery', 'content_review', 'media_scan', 'media_purge')),
    ADD CONSTRAINT durable_work_replay_audit_target_shape_check
        CHECK (
            (target_kind IN ('room_outbox', 'content_review', 'media_scan', 'media_purge')
                AND target_user_id IS NULL AND projection_kind IS NULL)
            OR (target_kind = 'fanout_delivery' AND target_user_id IS NOT NULL AND projection_kind IS NOT NULL)
        );
