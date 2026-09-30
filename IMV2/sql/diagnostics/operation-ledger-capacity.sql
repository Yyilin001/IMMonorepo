-- Read-only capacity evidence for permanent operation ledgers.
-- No COUNT(*) scans and no business IDs/payloads. Row counts are estimates;
-- -1 means ANALYZE has not supplied an estimate. Total bytes include indexes/TOAST.
SELECT c.relname AS ledger,
       c.reltuples::bigint AS estimated_rows,
       pg_relation_size(c.oid) AS heap_bytes,
       pg_indexes_size(c.oid) AS index_bytes,
       pg_total_relation_size(c.oid) AS total_bytes,
       s.last_analyze, s.last_autoanalyze
FROM pg_catalog.pg_class AS c
JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
LEFT JOIN pg_catalog.pg_stat_user_tables AS s ON s.relid = c.oid
WHERE n.nspname = 'im_v2' AND c.relkind IN ('r', 'p')
  AND c.relname IN (
      'message_send_completions', 'message_send_operation_receipts',
      'message_operation_closures', 'direct_authorization_intents',
      'direct_authorization_receipts', 'message_mutation_receipts',
      'message_reaction_receipts'
  )
ORDER BY c.relname;
