-- Keep both recipients of a fresh direct event on one database lane. This
-- lets the delivery transaction materialize the immutable shared payload once
-- without racing a second target-user worker on the same unique key.
CREATE INDEX CONCURRENTLY IF NOT EXISTS
    fanout_deliveries_fresh_source_lane_claim_idx
    ON im_v2.fanout_deliveries (
        target_shard_bucket,
        mod(
            hashtextextended(source_event_id::text, 0)
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

-- Superseded by source-event ownership. Retaining the target-user expression
-- index would add write amplification to every delivery without serving the
-- fresh claim query.
DROP INDEX CONCURRENTLY IF EXISTS
    im_v2.fanout_deliveries_fresh_partition_claim_idx;
