#!/usr/bin/env bash
set -Eeuo pipefail

# Proves that the online expand script transforms the previous committed
# canonical schema into the current canonical schema without data loss.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
compose_file="${repo_root}/IMV2/docker-compose.isolated-tests.yml"
current_schema="${repo_root}/IMV2/sql/schema.sql"
expand_sql="${repo_root}/IMV2/sql/changes/2026-08-17-message-projection-sharing-expand.sql"
fanout_payload_expand_sql="${repo_root}/IMV2/sql/changes/2026-08-17-fanout-payload-reference-expand.sql"
projection_ready_index_expand_sql="${repo_root}/IMV2/sql/changes/2026-08-17-user-projection-ready-index-expand.sql"
room_event_storage_expand_sql="${repo_root}/IMV2/sql/changes/2026-08-18-message-projection-room-event-storage-expand.sql"
fanout_fresh_partition_index_expand_sql="${repo_root}/IMV2/sql/changes/2026-08-18-fanout-fresh-partition-index-expand.sql"
expand_sql_relative="IMV2/sql/changes/2026-08-17-message-projection-sharing-expand.sql"
schema_relative="IMV2/sql/schema.sql"
project_name="imv2-message-projection-expand-regression"

command -v docker >/dev/null 2>&1 || {
  printf 'missing required command: docker\n' >&2
  exit 1
}

compose=(docker compose --project-name "${project_name}" --file "${compose_file}")
cleanup() {
  "${compose[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

"${compose[@]}" up --detach --wait postgres

psql() {
  "${compose[@]}" exec -T postgres \
    psql -v ON_ERROR_STOP=1 -U im_v2_test -d im_v2_test "$@"
}

migration_commit="$(
  git -C "${repo_root}" log --diff-filter=A --format=%H -1 -- "${expand_sql_relative}"
)"
test -n "${migration_commit}" || {
  printf 'cannot locate the commit that introduced %s\n' "${expand_sql_relative}" >&2
  exit 1
}

# The migration and canonical schema intentionally land in the same commit.
# Use the parent of that commit as the stable pre-expand fixture; using HEAD
# would reapply CREATE TABLE statements to an already-expanded schema.
git -C "${repo_root}" show "${migration_commit}^:${schema_relative}" | psql >/dev/null
psql < "${expand_sql}" >/dev/null
psql < "${fanout_payload_expand_sql}" >/dev/null
psql < "${projection_ready_index_expand_sql}" >/dev/null
psql < "${room_event_storage_expand_sql}" >/dev/null
psql < "${fanout_fresh_partition_index_expand_sql}" >/dev/null

normalize_schema() {
  awk '
    /^--/ || /^\\restrict / || /^\\unrestrict / || /^BEGIN;$/ || /^COMMIT;$/ { next }
    { sub(/[[:space:]]+$/, "") }
    /^[[:space:]]*$/ {
      if (started && !blank) print ""
      blank = 1
      next
    }
    { print; started = 1; blank = 0 }
  '
}

diff --unified \
  <(normalize_schema < "${current_schema}") \
  <("${compose[@]}" exec -T postgres \
      pg_dump --schema-only --schema=im_v2 --no-owner --no-privileges --no-comments \
      -U im_v2_test -d im_v2_test | normalize_schema)

printf 'V2 message projection online expand migration passed.\n'
