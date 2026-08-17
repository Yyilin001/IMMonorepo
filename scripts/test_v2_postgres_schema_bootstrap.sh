#!/usr/bin/env bash
set -Eeuo pipefail

# Disposable clean-bootstrap and schema-drift regression. It never reuses the
# developer's local PostgreSQL volume.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
compose_file="${repo_root}/IMV2/docker-compose.isolated-tests.yml"
schema_file="${repo_root}/IMV2/sql/schema.sql"
schema_contract_query="${repo_root}/IMV2/scripts/current_v2_schema_contract.sql"
project_name="imv2-schema-bootstrap-regression"

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
scalar() {
  psql -tAc "$1" | tr -d '[:space:]'
}
current_schema_contract() {
  psql -tA < "${schema_contract_query}" | tr -d '[:space:]'
}

test "$(current_schema_contract)" = 'f'

psql < "${schema_file}" >/dev/null
test "$(current_schema_contract)" = 't'

test "$(scalar "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'im_v2'")" = '120'
test "$(scalar "SELECT count(*) FROM pg_indexes WHERE schemaname = 'im_v2'")" = '296'
test "$(scalar "SELECT count(*) FROM pg_trigger AS trigger JOIN pg_class AS relation ON relation.oid = trigger.tgrelid JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace WHERE namespace.nspname = 'im_v2' AND NOT trigger.tgisinternal")" = '4'
test "$(scalar "SELECT count(*) FROM pg_proc AS procedure JOIN pg_namespace AS namespace ON namespace.oid = procedure.pronamespace WHERE namespace.nspname = 'im_v2'")" = '4'

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
  <(normalize_schema < "${schema_file}") \
  <("${compose[@]}" exec -T postgres \
      pg_dump --schema-only --schema=im_v2 --no-owner --no-privileges --no-comments \
      -U im_v2_test -d im_v2_test | normalize_schema)

psql -c 'CREATE TABLE im_v2.local_schema_migrations (migration_id TEXT PRIMARY KEY)' >/dev/null
test "$(current_schema_contract)" = 'f'
psql -c 'DROP TABLE im_v2.local_schema_migrations' >/dev/null
test "$(current_schema_contract)" = 't'

if psql < "${schema_file}" >/dev/null 2>&1; then
  printf 'canonical schema unexpectedly accepted a stale non-empty database\n' >&2
  exit 1
fi

bash "${script_dir}/check_v2_schema_readiness_tables.sh"
printf 'V2 canonical PostgreSQL bootstrap and drift check passed.\n'
