#!/usr/bin/env bash
set -Eeuo pipefail

# Disposable logical-backup drill for the V2 authoritative schema. This proves
# that a generated dump can recreate the canonical im_v2 schema and a
# durable replay-audit record. It is intentionally not a claim of WAL/PITR,
# cross-region, RPO, or RTO readiness.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
v2_dir="$(cd "${script_dir}/.." && pwd)"
compose_file="${v2_dir}/docker-compose.isolated-tests.yml"
project_name="imv2-logical-restore-regression-$$"

command -v docker >/dev/null 2>&1 || {
  printf 'missing required command: docker\n' >&2
  exit 1
}

compose=(docker compose --project-name "${project_name}" --file "${compose_file}")
cleanup() {
  "${compose[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

"${compose[@]}" up -d --wait postgres

psql() {
  "${compose[@]}" exec -T postgres psql -v ON_ERROR_STOP=1 -U im_v2_test -d im_v2_test "$@"
}
scalar() {
  psql -tAc "$1" | tr -d '[:space:]'
}

psql < "${v2_dir}/sql/schema.sql" >/dev/null

psql -c "INSERT INTO im_v2.durable_work_replay_audit (operation_id, operator_principal, target_kind, source_event_id, target_user_id, projection_kind, reason_code, requested_at, outcome) VALUES ('00000000-0000-0000-0000-00000000d701', 'logical-restore-drill', 'user_state_event', '00000000-0000-0000-0000-00000000d702', '00000000-0000-0000-0000-00000000d703', 'membership', 'dependency_recovered', now(), 'requeued')" >/dev/null

audit_query="SELECT row_to_json(a)::text FROM im_v2.durable_work_replay_audit AS a ORDER BY operation_id"
table_count_query="SELECT count(*) FROM information_schema.tables WHERE table_schema = 'im_v2'"
original_audit="$(psql -tAc "${audit_query}")"
original_table_count="$(scalar "${table_count_query}")"

backup_path=/tmp/im_v2_logical_restore_regression.dump
"${compose[@]}" exec -T postgres pg_dump -U im_v2_test -d im_v2_test --format=custom --schema=im_v2 --file="${backup_path}"
psql -q -c 'SET client_min_messages = warning; DROP SCHEMA im_v2 CASCADE' >/dev/null
"${compose[@]}" exec -T postgres pg_restore -U im_v2_test -d im_v2_test --no-owner --exit-on-error "${backup_path}"

test "$(scalar "SELECT to_regclass('im_v2.durable_work_replay_audit') IS NOT NULL")" = 't'
test "$(scalar "SELECT count(*) FROM im_v2.durable_work_replay_audit WHERE operation_id = '00000000-0000-0000-0000-00000000d701' AND outcome = 'requeued'")" = '1'
test "$(psql -tAc "${audit_query}")" = "${original_audit}"
test "$(scalar "${table_count_query}")" = "${original_table_count}"
test "$(psql -tA < "${script_dir}/current_v2_schema_contract.sql" | tr -d '[:space:]')" = 't'

printf 'V2 PostgreSQL logical restore drill passed\n'
