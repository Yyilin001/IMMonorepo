-- Opt-in for the measured small shared-disk host; not a schema migration.
-- Keep autovacuum, analyze/insert thresholds and freeze safeguards unchanged.
-- Lower the per-worker cost budget only for the two large append-heavy tables.
-- Check completion times and dead tuples before retaining this profile.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '2s';
SET LOCAL statement_timeout = '5s';
ALTER TABLE im_v2.messages SET (
    autovacuum_vacuum_cost_limit = 20,
    autovacuum_vacuum_cost_delay = 2
);
ALTER TABLE im_v2.message_send_completions SET (
    autovacuum_vacuum_cost_limit = 20,
    autovacuum_vacuum_cost_delay = 2
);
COMMIT;
