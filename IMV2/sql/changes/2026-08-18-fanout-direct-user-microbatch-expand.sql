-- Let fresh-direct replicas arbitrate target users before locking delivery
-- rows, then drain a small ordered run for each owned user. Build the new
-- online path before dropping the older source-first lane index.
CREATE INDEX CONCURRENTLY IF NOT EXISTS
    fanout_deliveries_fresh_direct_user_microbatch_claim_idx
    ON im_v2.fanout_deliveries (
        target_shard_bucket,
        mod(
            hashtextextended(target_user_id::text, 0)
                & 9223372036854775807,
            8
        ),
        target_user_id,
        source_event_id,
        projection_kind
    )
    WHERE fresh_direct_eligible
      AND state = 'pending'
      AND claim_token IS NULL
      AND next_attempt_at IS NULL
      AND lease_expires_at IS NULL
      AND paused_at IS NULL
      AND retry_count = 0;

DROP INDEX CONCURRENTLY IF EXISTS
    im_v2.fanout_deliveries_fresh_direct_target_lane_claim_idx;
