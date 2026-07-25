-- A generic Push wake may be retried after a provider failure or worker crash,
-- but its already-admitted device-key budget must never be consumed again.
-- `admitted_at` is therefore durable admission evidence, independent from the
-- short-lived provider lease.

ALTER TABLE im_v2.push_wake_outbox
    ADD COLUMN admitted_at TIMESTAMPTZ NULL;

CREATE INDEX push_wake_outbox_reclaim_idx
    ON im_v2.push_wake_outbox (lease_expires_at, created_at)
    WHERE state = 'claimed';
