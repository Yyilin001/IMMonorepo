-- Fan-out rows transition through several indexed states before the bounded
-- housekeeping worker reaches its retention cutoff. PostgreSQL's default
-- 20% scale factor leaves too many dead tuples on a high-throughput node, so
-- trigger vacuum/analyze by a small absolute-plus-relative threshold.
--
-- These reloptions are online metadata changes. Existing dead tuples are
-- intentionally left to ordinary autovacuum; rollout does not take a blocking
-- VACUUM FULL or rewrite any table.
ALTER TABLE im_v2.fanout_deliveries SET (
    autovacuum_vacuum_scale_factor = 0.02,
    autovacuum_vacuum_threshold = 1000,
    autovacuum_analyze_scale_factor = 0.02,
    autovacuum_analyze_threshold = 1000
);

ALTER TABLE im_v2.fanout_completion_units SET (
    autovacuum_vacuum_scale_factor = 0.02,
    autovacuum_vacuum_threshold = 1000,
    autovacuum_analyze_scale_factor = 0.02,
    autovacuum_analyze_threshold = 1000
);

ALTER TABLE im_v2.fanout_plans SET (
    autovacuum_vacuum_scale_factor = 0.02,
    autovacuum_vacuum_threshold = 1000,
    autovacuum_analyze_scale_factor = 0.02,
    autovacuum_analyze_threshold = 1000
);
