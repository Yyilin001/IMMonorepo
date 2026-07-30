-- Separate hot-path and recovery-path indexes for fan-out delivery claims.
-- The three predicates are mutually exclusive at claim time. Keeping their
-- order keys aligned with each lane removes the 100k-member hot path's global
-- sort while retaining lease expiry and explicit retry recovery.

CREATE INDEX fanout_deliveries_fresh_claim_idx
    ON im_v2.fanout_deliveries
        (target_shard_bucket, source_event_id, target_user_id, projection_kind)
    WHERE state = 'pending'
      AND next_attempt_at IS NULL
      AND lease_expires_at IS NULL;

CREATE INDEX fanout_deliveries_retry_due_claim_idx
    ON im_v2.fanout_deliveries
        (target_shard_bucket, next_attempt_at, source_event_id, target_user_id, projection_kind)
    WHERE state = 'pending'
      AND next_attempt_at IS NOT NULL
      AND lease_expires_at IS NULL;

CREATE INDEX fanout_deliveries_expired_lease_claim_idx
    ON im_v2.fanout_deliveries
        (target_shard_bucket, lease_expires_at, source_event_id, target_user_id, projection_kind)
    WHERE state = 'pending'
      AND lease_expires_at IS NOT NULL;
