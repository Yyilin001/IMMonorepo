-- Bound fresh-delivery scans to stable hash lanes. Process worker counts map
-- onto these lanes at runtime, so increasing or decreasing concurrency does
-- not require rebuilding the index or changing durable row ownership.
CREATE INDEX CONCURRENTLY IF NOT EXISTS
    fanout_deliveries_fresh_partition_claim_idx
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
    WHERE state = 'pending'
      AND next_attempt_at IS NULL
      AND lease_expires_at IS NULL;
