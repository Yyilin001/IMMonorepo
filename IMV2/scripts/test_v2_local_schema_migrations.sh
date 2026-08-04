#!/usr/bin/env bash
set -Eeuo pipefail

# Disposable regression for the local-only migration ledger. It never uses the
# developer's imv2localaccount project or its persistent PostgreSQL volume.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
v2_dir="$(cd "${script_dir}/.." && pwd)"
compose_file="${v2_dir}/docker-compose.local-account.yml"
env_file="${v2_dir}/.env.local"
project_name="imv2-local-migration-regression"
created_env_file=false

source "${script_dir}/local_compose.sh"

command -v docker >/dev/null 2>&1 || {
  printf 'missing required command: docker\n' >&2
  exit 1
}
if [[ ! -f "${env_file}" ]]; then
  # CI has no developer-local secret file. Only PostgreSQL starts in this
  # regression, so a disposable password is sufficient; account/gateway are
  # never created. Do not overwrite a real local `.env.local`.
  umask 077
  printf 'IM_V2_LOCAL_POSTGRES_PASSWORD=imv2-local-migration-regression\n' > "${env_file}"
  created_env_file=true
fi

compose() {
  v2_local_compose "${env_file}" --project-name "${project_name}" --file "${compose_file}" "$@"
}
cleanup() {
  compose down -v --remove-orphans >/dev/null 2>&1 || true
  if [[ "${created_env_file}" = true ]]; then
    rm -f "${env_file}"
  fi
}
trap cleanup EXIT

compose up -d --wait postgres

run_migrator() {
  V2_LOCAL_COMPOSE_PROJECT="${project_name}" \
  V2_LOCAL_COMPOSE_FILE="${compose_file}" \
  V2_LOCAL_ENV_FILE="${env_file}" \
    bash "${script_dir}/apply_v2_local_schema_migrations.sh"
}

bootstrap_output="$(run_migrator)"
expected_migration_count="$(find "${v2_dir}/sql" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]_*.sql' | wc -l | tr -d '[:space:]')"
test "$(printf '%s\n' "${bootstrap_output}" | grep -Fc 'local V2 migration recorded:')" = "${expected_migration_count}"

psql() {
  compose exec -T postgres psql -v ON_ERROR_STOP=1 -U im_v2 -d im_v2 "$@"
}
psql -c 'DROP TABLE im_v2.user_shard_route_operations, im_v2.user_shard_route_overrides, im_v2.user_shard_router_configuration' >/dev/null
psql -c "DELETE FROM im_v2.local_schema_migrations WHERE migration_name = '0010_user_shard_router_control.sql'" >/dev/null

repair_output="$(run_migrator)"
printf '%s\n' "${repair_output}" | grep -Fxq 'local V2 migration applied: 0010_user_shard_router_control.sql'
test "$(psql -tAc "SELECT to_regclass('im_v2.user_shard_router_configuration') IS NOT NULL")" = 't'
test "$(psql -tAc "SELECT EXISTS (SELECT 1 FROM im_v2.local_schema_migrations WHERE migration_name = '0010_user_shard_router_control.sql')")" = 't'

psql -c "INSERT INTO im_v2.gateway_worker_cursors (worker_name, node_id, last_event_id, updated_at) VALUES ('device-revocation-v1', 'retired-gateway', 42, '2026-08-03T00:00:00Z')" >/dev/null
psql -c "DELETE FROM im_v2.local_schema_migrations WHERE migration_name = '0039_device_revocation_worker_cursor_namespace.sql'" >/dev/null

cursor_migration_output="$(run_migrator)"
printf '%s\n' "${cursor_migration_output}" | grep -Fxq 'local V2 migration applied: 0039_device_revocation_worker_cursor_namespace.sql'
test "$(psql -tAc "SELECT last_event_id FROM im_v2.gateway_worker_cursors WHERE worker_name = 'device-revocation' AND node_id = 'retired-gateway'")" = '42'
test "$(psql -tAc "SELECT EXISTS (SELECT 1 FROM im_v2.local_schema_migrations WHERE migration_name = '0039_device_revocation_worker_cursor_namespace.sql')")" = 't'

psql -c "DELETE FROM im_v2.local_schema_migrations WHERE migration_name = '0040_device_session_management.sql'" >/dev/null
device_session_migration_output="$(run_migrator)"
printf '%s\n' "${device_session_migration_output}" | grep -Fxq 'local V2 migration recorded: 0040_device_session_management.sql'
test "$(psql -tAc "SELECT to_regclass('im_v2.device_session_operations') IS NOT NULL")" = 't'
test "$(psql -tAc "SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'auth_devices' AND column_name = 'last_active_at')")" = 't'
test "$(psql -tAc "SELECT EXISTS (SELECT 1 FROM im_v2.local_schema_migrations WHERE migration_name = '0040_device_session_management.sql')")" = 't'

test -z "$(run_migrator)"
printf 'local V2 schema migration ledger regression passed\n'
