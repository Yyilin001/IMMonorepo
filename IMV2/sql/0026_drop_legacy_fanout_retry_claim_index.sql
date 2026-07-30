-- Migration 0020's retry-due lane index adds the required unleased/due
-- predicate and complete deterministic order. This older broad pending index
-- is no longer selected by any claim lane and only adds write maintenance.
DROP INDEX IF EXISTS im_v2.fanout_deliveries_retry_claim_idx;
