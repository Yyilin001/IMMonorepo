-- Migration 0020 replaced the mixed pending/retry/lease claim with three
-- mutually exclusive lane predicates and matching partial indexes. The old
-- mixed index no longer matches any lane's selection/order and only adds
-- maintenance/WAL on every plan, claim and terminal transition.
DROP INDEX IF EXISTS im_v2.fanout_deliveries_claim_idx;
