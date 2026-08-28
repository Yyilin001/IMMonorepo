#!/usr/bin/env bash
set -Eeuo pipefail

action="${1:-}"
profile_directory="${2:-}"
baseline_directory="${3:-${IM_V2_PROFILE_BASELINE_DIRECTORY:-}}"
database_url="${IM_V2_PROFILE_DATABASE_URL:-}"
script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  printf 'usage:\n' >&2
  printf '  IM_V2_PROFILE_DATABASE_URL=... %s baseline BASELINE_DIRECTORY\n' "$0" >&2
  printf '  IM_V2_PROFILE_DATABASE_URL=... %s report REPORT_DIRECTORY BASELINE_DIRECTORY\n' "$0" >&2
  printf '  IM_V2_PROFILE_DATABASE_URL=... IM_V2_PROFILE_DATABASE_IS_DISPOSABLE=1 %s reset\n' "$0" >&2
}

if [[ -z "${database_url}" ]]; then
  printf 'IM_V2_PROFILE_DATABASE_URL is required\n' >&2
  exit 1
fi
if [[ "${action}" != 'baseline' && "${action}" != 'report' && "${action}" != 'reset' ]]; then
  usage
  exit 1
fi
command -v psql >/dev/null 2>&1 || {
  printf 'missing required command: psql\n' >&2
  exit 1
}

if [[ "${action}" == 'reset' ]]; then
  if [[ "${IM_V2_PROFILE_DATABASE_IS_DISPOSABLE:-}" != '1' ]]; then
    printf 'reset is destructive to shared PostgreSQL statistics and requires IM_V2_PROFILE_DATABASE_IS_DISPOSABLE=1\n' >&2
    exit 1
  fi
  psql "${database_url}" -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SELECT pg_stat_statements_reset();
SELECT pg_stat_reset();
SELECT pg_stat_reset_shared('bgwriter');
SELECT pg_stat_reset_shared('wal');
SQL
  printf 'Disposable PostgreSQL profile counters reset\n'
  exit 0
fi

if [[ -z "${profile_directory}" ]]; then
  usage
  exit 1
fi
if [[ "${action}" == 'report' && -z "${baseline_directory}" ]]; then
  printf 'BASELINE_DIRECTORY is required for a delta report\n' >&2
  usage
  exit 1
fi
if [[ -e "${profile_directory}" && -n "$(find "${profile_directory}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  printf 'refusing to mix a profile with existing files: %s\n' "${profile_directory}" >&2
  exit 1
fi
mkdir -p "${profile_directory}"

extension_available="$({
  psql "${database_url}" -v ON_ERROR_STOP=1 -Atc \
    "SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements')"
} 2>/dev/null)"
if [[ "${extension_available}" != 't' ]]; then
  printf 'pg_stat_statements must be installed before profiling\n' >&2
  exit 1
fi

psql "${database_url}" -v ON_ERROR_STOP=1 --csv -c "
SELECT current_timestamp AS captured_at,
       current_setting('server_version') AS server_version,
       current_setting('shared_preload_libraries') AS shared_preload_libraries,
       current_setting('track_io_timing') AS track_io_timing,
       current_setting('track_wal_io_timing') AS track_wal_io_timing,
       current_setting('max_connections') AS max_connections,
       current_setting('shared_buffers') AS shared_buffers,
       current_setting('work_mem') AS work_mem,
       current_setting('effective_cache_size') AS effective_cache_size,
       current_setting('fsync') AS fsync,
       current_setting('synchronous_commit') AS synchronous_commit,
       current_setting('full_page_writes') AS full_page_writes,
       current_setting('wal_sync_method') AS wal_sync_method,
       current_setting('wal_buffers') AS wal_buffers,
       current_setting('wal_writer_delay') AS wal_writer_delay,
       current_setting('commit_delay') AS commit_delay,
       current_setting('commit_siblings') AS commit_siblings,
       current_setting('wal_compression') AS wal_compression,
       current_setting('checkpoint_timeout') AS checkpoint_timeout,
       current_setting('checkpoint_completion_target') AS checkpoint_completion_target,
       current_setting('checkpoint_flush_after') AS checkpoint_flush_after,
       current_setting('backend_flush_after') AS backend_flush_after,
       current_setting('max_wal_size') AS max_wal_size,
       current_setting('min_wal_size') AS min_wal_size,
       current_setting('bgwriter_delay') AS bgwriter_delay,
       current_setting('bgwriter_lru_maxpages') AS bgwriter_lru_maxpages,
       current_setting('bgwriter_lru_multiplier') AS bgwriter_lru_multiplier,
       current_setting('bgwriter_flush_after') AS bgwriter_flush_after,
       current_setting('autovacuum') AS autovacuum,
       current_setting('autovacuum_max_workers') AS autovacuum_max_workers
" > "${profile_directory}/settings.csv"

psql "${database_url}" -v ON_ERROR_STOP=1 --csv -c "
SELECT 'database' AS counter, stats_reset
FROM pg_stat_database WHERE datname = current_database()
UNION ALL
SELECT 'bgwriter', stats_reset FROM pg_stat_bgwriter
UNION ALL
SELECT 'wal', stats_reset FROM pg_stat_wal
UNION ALL
SELECT 'statements', stats_reset FROM pg_stat_statements_info
UNION ALL
SELECT 'io', min(stats_reset) FROM pg_stat_io
ORDER BY counter
" > "${profile_directory}/counter_epochs.csv"

psql "${database_url}" -v ON_ERROR_STOP=1 --csv -c "
SELECT datname, numbackends, xact_commit, xact_rollback,
       blks_read, blks_hit, blk_read_time, blk_write_time,
       temp_files, temp_bytes, deadlocks, conflicts,
       sessions, sessions_abandoned, sessions_fatal, sessions_killed
FROM pg_stat_database
WHERE datname = current_database()
" > "${profile_directory}/database.csv"

# PostgreSQL 16 keeps both checkpointer and background-writer counters in
# pg_stat_bgwriter. Capture explicit columns so the delta tool can distinguish
# foreground buffer writes from deliberately paced background/checkpoint work.
psql "${database_url}" -v ON_ERROR_STOP=1 --csv -c "
SELECT checkpoints_timed, checkpoints_req,
       checkpoint_write_time, checkpoint_sync_time,
       buffers_checkpoint, buffers_clean, maxwritten_clean,
       buffers_backend, buffers_backend_fsync, buffers_alloc
FROM pg_stat_bgwriter
" > "${profile_directory}/bgwriter.csv"

psql "${database_url}" -v ON_ERROR_STOP=1 --csv -c "
SELECT wal_records, wal_fpi, wal_bytes, wal_buffers_full,
       wal_write, wal_sync, wal_write_time, wal_sync_time
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
" > "${profile_directory}/statements.csv"

psql "${database_url}" -v ON_ERROR_STOP=1 --csv -c "
SELECT schemaname, relname,
       pg_total_relation_size(relid) AS total_bytes,
       n_live_tup, n_dead_tup,
       seq_scan, idx_scan, n_tup_ins, n_tup_upd, n_tup_del,
       n_tup_hot_upd, n_tup_newpage_upd,
       heap_blks_read, heap_blks_hit,
       idx_blks_read, idx_blks_hit
FROM pg_stat_user_tables
JOIN pg_statio_user_tables USING (relid, schemaname, relname)
WHERE schemaname = 'im_v2'
ORDER BY total_bytes DESC
" > "${profile_directory}/relations.csv"

psql "${database_url}" -v ON_ERROR_STOP=1 --csv -c "
SELECT index_stats.schemaname, index_stats.relname,
       index_stats.indexrelname,
       pg_relation_size(index_stats.indexrelid) AS index_bytes,
       index_stats.idx_scan, index_stats.idx_tup_read,
       index_stats.idx_tup_fetch,
       io.idx_blks_read, io.idx_blks_hit
FROM pg_stat_user_indexes AS index_stats
JOIN pg_statio_user_indexes AS io
  USING (schemaname, relname, indexrelname)
WHERE index_stats.schemaname = 'im_v2'
ORDER BY index_bytes DESC, index_stats.indexrelname
" > "${profile_directory}/indexes.csv"

if [[ "${action}" == 'baseline' ]]; then
  printf 'PostgreSQL profile baseline written to %s; no server counters were reset\n' "${profile_directory}"
  exit 0
fi

if [[ ! -d "${baseline_directory}" ]]; then
  printf 'profile baseline does not exist: %s\n' "${baseline_directory}" >&2
  exit 1
fi
command -v python3 >/dev/null 2>&1 || {
  printf 'missing required command for profile delta: python3\n' >&2
  exit 1
}
python3 "${script_directory}/compare_v2_postgres_profiles.py" \
  "${baseline_directory}" "${profile_directory}"
printf 'PostgreSQL profile and counter deltas written to %s\n' "${profile_directory}"
