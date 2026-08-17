#!/usr/bin/env bash
set -Eeuo pipefail

action="${1:-}"
profile_directory="${2:-}"
database_url="${IM_V2_PROFILE_DATABASE_URL:-}"

if [[ -z "${database_url}" ]]; then
  printf 'IM_V2_PROFILE_DATABASE_URL is required\n' >&2
  exit 1
fi
if [[ "${action}" != 'reset' && "${action}" != 'report' ]]; then
  printf 'usage: IM_V2_PROFILE_DATABASE_URL=... %s reset|report [report-directory]\n' "$0" >&2
  exit 1
fi
command -v psql >/dev/null 2>&1 || {
  printf 'missing required command: psql\n' >&2
  exit 1
}

if [[ "${action}" == 'reset' ]]; then
  psql "${database_url}" -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SELECT pg_stat_statements_reset();
SELECT pg_stat_reset();
SELECT pg_stat_reset_shared('wal');
SQL
  printf 'PostgreSQL profile counters reset\n'
  exit 0
fi

if [[ -z "${profile_directory}" ]]; then
  printf 'report-directory is required for report\n' >&2
  exit 1
fi
mkdir -p "${profile_directory}"

psql "${database_url}" -v ON_ERROR_STOP=1 --csv -c "
SELECT current_timestamp AS captured_at,
       current_setting('server_version') AS server_version,
       current_setting('shared_preload_libraries') AS shared_preload_libraries,
       current_setting('track_io_timing') AS track_io_timing,
       current_setting('track_wal_io_timing') AS track_wal_io_timing,
       current_setting('max_connections') AS max_connections,
       current_setting('shared_buffers') AS shared_buffers,
       current_setting('work_mem') AS work_mem,
       current_setting('effective_cache_size') AS effective_cache_size
" > "${profile_directory}/settings.csv"

psql "${database_url}" -v ON_ERROR_STOP=1 --csv -c "
SELECT datname, numbackends, xact_commit, xact_rollback,
       blks_read, blks_hit, blk_read_time, blk_write_time,
       temp_files, temp_bytes, deadlocks, conflicts,
       sessions, sessions_abandoned, sessions_fatal, sessions_killed
FROM pg_stat_database
WHERE datname = current_database()
" > "${profile_directory}/database.csv"

psql "${database_url}" -v ON_ERROR_STOP=1 --csv -c "
SELECT wal_records, wal_fpi, wal_bytes, wal_buffers_full,
       wal_write, wal_sync, wal_write_time, wal_sync_time,
       stats_reset
FROM pg_stat_wal
" > "${profile_directory}/wal.csv"

psql "${database_url}" -v ON_ERROR_STOP=1 --csv -c "
SELECT backend_type, object, context, reads, read_time,
       writes, write_time, writebacks, writeback_time,
       extends, extend_time, hits, evictions, reuses,
       fsyncs, fsync_time
FROM pg_stat_io
ORDER BY backend_type, object, context
" > "${profile_directory}/io.csv"

psql "${database_url}" -v ON_ERROR_STOP=1 --csv -c "
SELECT wait_event_type, wait_event, COUNT(*) AS backend_count
FROM pg_stat_activity
WHERE datname = current_database()
  AND state IS DISTINCT FROM 'idle'
GROUP BY wait_event_type, wait_event
ORDER BY backend_count DESC, wait_event_type, wait_event
" > "${profile_directory}/waits.csv"

psql "${database_url}" -v ON_ERROR_STOP=1 --csv -c "
SELECT queryid, calls, rows,
       round(total_plan_time::numeric, 3) AS total_plan_ms,
       round(total_exec_time::numeric, 3) AS total_exec_ms,
       round(mean_exec_time::numeric, 3) AS mean_exec_ms,
       shared_blks_hit, shared_blks_read,
       shared_blks_dirtied, shared_blks_written,
       temp_blks_read, temp_blks_written,
       wal_records, wal_fpi, wal_bytes,
       left(regexp_replace(query, '[[:space:]]+', ' ', 'g'), 500) AS normalized_query
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
ORDER BY total_exec_time DESC
LIMIT 50
" > "${profile_directory}/statements.csv"

psql "${database_url}" -v ON_ERROR_STOP=1 --csv -c "
SELECT schemaname, relname,
       pg_total_relation_size(relid) AS total_bytes,
       n_live_tup, n_dead_tup,
       seq_scan, idx_scan, n_tup_ins, n_tup_upd, n_tup_del,
       heap_blks_read, heap_blks_hit,
       idx_blks_read, idx_blks_hit
FROM pg_stat_user_tables
JOIN pg_statio_user_tables USING (relid, schemaname, relname)
WHERE schemaname = 'im_v2'
ORDER BY total_bytes DESC
" > "${profile_directory}/relations.csv"

printf 'PostgreSQL profile written to %s\n' "${profile_directory}"
