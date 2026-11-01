-- Read-only capacity evidence for permanent operation ledgers.
-- No COUNT(*) scans and no business IDs/payloads. Row counts are estimates;
-- NULL means ANALYZE has not supplied an estimate. Total bytes include indexes/TOAST.
-- Run once per physical database; replica/alias observations must not be summed.
BEGIN READ ONLY;
SET LOCAL statement_timeout = '5s';
SELECT clock_timestamp() AS observed_at,
       c.relname AS ledger,
       CASE WHEN c.reltuples >= 0 THEN c.reltuples::bigint END AS estimated_rows,
       pg_relation_size(c.oid) AS heap_bytes,
       pg_indexes_size(c.oid) AS index_bytes,
       pg_total_relation_size(c.oid) AS total_bytes,
       s.n_tup_ins AS inserts_since_stats_reset,
       s.n_tup_upd AS updates_since_stats_reset,
       s.n_tup_del AS deletes_since_stats_reset,
       s.last_analyze, s.last_autoanalyze,
       d.stats_reset AS database_stats_reset
FROM pg_catalog.pg_class AS c
JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
LEFT JOIN pg_catalog.pg_stat_user_tables AS s ON s.relid = c.oid
LEFT JOIN pg_catalog.pg_stat_database AS d ON d.datname = current_database()
WHERE n.nspname = 'im_v2' AND c.relkind = 'r'
  AND c.relname IN (
      'message_send_completions',
      'message_mutation_receipts',
      'message_reaction_receipts'
  )
ORDER BY c.relname;

-- This is cluster-wide WAL, NOT bytes attributable to these ledgers. Collect once
-- per PostgreSQL cluster, separately from physical-database relation totals.
-- Compare counters only within the same deployment and unchanged stats_reset.
SELECT clock_timestamp() AS observed_at, pg_postmaster_start_time() AS server_started_at,
       stats_reset AS cluster_wal_stats_reset, wal_records, wal_fpi, wal_bytes
FROM pg_catalog.pg_stat_wal;
COMMIT;
