-- A user's monotonic Sync Sequence is a single-writer hotspot. Direct fresh
-- work must therefore use the same stable target-user ownership rule as every
-- other fresh projection. Create the replacement before dropping the old
-- source-event index so the online transition never loses an indexed claim
-- path.
CREATE INDEX CONCURRENTLY IF NOT EXISTS
    fanout_deliveries_fresh_direct_target_lane_claim_idx
    ON im_v2.fanout_deliveries (
        target_shard_bucket,
        mod(
            hashtextextended(target_user_id::text, 0)
                & 9223372036854775807,
            8
        ),
        source_event_id,
        target_user_id,
        projection_kind
    )
    WHERE fresh_direct_eligible
      AND state = 'pending'
      AND next_attempt_at IS NULL
      AND lease_expires_at IS NULL;

DROP INDEX CONCURRENTLY IF EXISTS
    im_v2.fanout_deliveries_fresh_direct_source_lane_claim_idx;
