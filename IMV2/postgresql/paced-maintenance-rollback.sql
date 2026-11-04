-- Use only when these options were unset before paced-maintenance.sql.
-- If an environment had existing overrides, restore its recorded values instead.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '2s';
SET LOCAL statement_timeout = '5s';
ALTER TABLE im_v2.messages RESET (
    autovacuum_vacuum_cost_limit, autovacuum_vacuum_cost_delay
);
ALTER TABLE im_v2.message_send_completions RESET (
    autovacuum_vacuum_cost_limit, autovacuum_vacuum_cost_delay
);
COMMIT;
