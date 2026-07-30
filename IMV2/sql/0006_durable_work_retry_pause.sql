-- Durable work remains retryable until its receiver-side effect commits. A
-- repeatedly failing row is paused for explicit operator replay, never turned
-- into a terminal skip. `next_attempt_at` supplies bounded exponential retry
-- scheduling without relying on an in-process timer.

ALTER TABLE im_v2.room_outbox
    ADD COLUMN next_attempt_at TIMESTAMPTZ NULL,
    ADD COLUMN paused_at TIMESTAMPTZ NULL,
    ADD COLUMN last_failure_code TEXT NULL;

ALTER TABLE im_v2.room_outbox
    DROP CONSTRAINT room_outbox_state_check,
    ADD CONSTRAINT room_outbox_state_check
        CHECK (state IN ('pending', 'published', 'terminal', 'paused')),
    ADD CONSTRAINT room_outbox_pause_state_check
        CHECK ((state = 'paused') = (paused_at IS NOT NULL));

ALTER TABLE im_v2.fanout_deliveries
    ADD COLUMN next_attempt_at TIMESTAMPTZ NULL,
    ADD COLUMN paused_at TIMESTAMPTZ NULL,
    ADD COLUMN last_failure_code TEXT NULL;

ALTER TABLE im_v2.fanout_deliveries
    DROP CONSTRAINT fanout_deliveries_state_check,
    ADD CONSTRAINT fanout_deliveries_state_check
        CHECK (state IN ('pending', 'terminal', 'paused')),
    ADD CONSTRAINT fanout_deliveries_pause_state_check
        CHECK ((state = 'paused') = (paused_at IS NOT NULL));

CREATE INDEX room_outbox_retry_claim_idx
    ON im_v2.room_outbox (next_attempt_at, created_at)
    WHERE state = 'pending';
