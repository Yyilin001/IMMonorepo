-- Classify only newly-created, transactionally preplanned direct deliveries
-- for the no-lease fast path. Existing rows default to the ordinary fenced
-- path; this makes the expand safe while old and new binaries overlap.
ALTER TABLE im_v2.fanout_deliveries
    ADD COLUMN IF NOT EXISTS fresh_direct_eligible boolean
        DEFAULT false NOT NULL;

ALTER TABLE im_v2.fanout_deliveries
    DROP CONSTRAINT IF EXISTS fanout_deliveries_fresh_direct_kind_check;

ALTER TABLE im_v2.fanout_deliveries
    ADD CONSTRAINT fanout_deliveries_fresh_direct_kind_check
        CHECK (NOT fresh_direct_eligible OR projection_kind = 'message')
        NOT VALID;

ALTER TABLE im_v2.fanout_deliveries
    VALIDATE CONSTRAINT fanout_deliveries_fresh_direct_kind_check;

-- Direct work is source-owned so both recipients share one payload write.
-- The eligibility predicate prevents the optimizer from driving this scan
-- from transient, badly-estimated fanout plan state.
CREATE INDEX CONCURRENTLY IF NOT EXISTS
    fanout_deliveries_fresh_direct_source_lane_claim_idx
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
    WHERE fresh_direct_eligible
      AND state = 'pending'
      AND next_attempt_at IS NULL
      AND lease_expires_at IS NULL;

-- Every other brand-new delivery remains target-user-owned. Excluding direct
-- rows means message acceptance maintains only one fresh expression index.
CREATE INDEX CONCURRENTLY IF NOT EXISTS
    fanout_deliveries_fresh_generic_target_lane_claim_idx
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
    WHERE NOT fresh_direct_eligible
      AND state = 'pending'
      AND next_attempt_at IS NULL
      AND lease_expires_at IS NULL;

DROP INDEX CONCURRENTLY IF EXISTS
    im_v2.fanout_deliveries_fresh_source_lane_claim_idx;
