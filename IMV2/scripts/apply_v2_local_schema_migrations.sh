#!/usr/bin/env bash
set -Eeuo pipefail

# This is deliberately a local-development helper, not a production migration
# runner. The production release path must use its approved migration system.
# Local Compose initializes numbered SQL files only when its PostgreSQL volume
# is first created; this ledger lets a retained local volume catch up safely.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
v2_dir="$(cd "${script_dir}/.." && pwd)"
compose_project="${V2_LOCAL_COMPOSE_PROJECT:-imv2localaccount}"
compose_file="${V2_LOCAL_COMPOSE_FILE:-${v2_dir}/docker-compose.local-account.yml}"
env_file="${V2_LOCAL_ENV_FILE:-${v2_dir}/.env.local}"

source "${script_dir}/local_compose.sh"

command -v docker >/dev/null 2>&1 || {
  printf 'missing required command: docker\n' >&2
  exit 1
}
test -f "${env_file}" || {
  printf 'missing local V2 environment: %s\n' "${env_file}" >&2
  exit 1
}

compose() {
  v2_local_compose "${env_file}" --project-name "${compose_project}" --file "${compose_file}" "$@"
}
psql() {
  compose exec -T postgres psql -v ON_ERROR_STOP=1 -U im_v2 -d im_v2 "$@"
}

# `docker compose up --wait --force-recreate` reports the healthcheck from the
# newly-created container, but on a cold Linux runner PostgreSQL can still be
# finishing the handoff from its bootstrap process when the first `exec` is
# issued.  Wait for an actual SQL round trip rather than treating the Compose
# health transition as a schema-migration readiness guarantee.
wait_for_postgres_sql() {
  for _ in {1..60}; do
    if compose exec -T postgres psql -v ON_ERROR_STOP=1 -U im_v2 -d im_v2 -c 'SELECT 1' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  printf 'PostgreSQL did not accept a local schema-migration SQL connection within 60 seconds.\n' >&2
  exit 1
}

wait_for_postgres_sql

scalar() {
  psql -tAc "$1" | tr -d '[:space:]'
}

test "$(scalar "SELECT to_regnamespace('im_v2') IS NOT NULL")" = 't' || {
  printf 'local V2 schema is absent; wait for PostgreSQL initialization before applying migrations.\n' >&2
  exit 1
}

psql -c 'CREATE TABLE IF NOT EXISTS im_v2.local_schema_migrations (migration_name TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now())' >/dev/null

# Each marker is an immutable schema fact introduced by exactly one numbered
# migration. It permits safe bootstrap of a volume that was initialized before
# this local ledger existed, without re-running non-idempotent historical SQL.
migration_marker() {
  case "$1" in
    0001_core.sql)
      printf "%s" "SELECT to_regclass('im_v2.rooms') IS NOT NULL"
      ;;
    0002_device_credential_rotation.sql)
      printf "%s" "SELECT to_regclass('im_v2.device_refresh_sessions') IS NOT NULL"
      ;;
    0003_account_password_fallback.sql)
      printf "%s" "SELECT to_regclass('im_v2.account_password_credentials') IS NOT NULL"
      ;;
    0004_group_room_creation.sql)
      printf "%s" "SELECT to_regclass('im_v2.group_rooms') IS NOT NULL"
      ;;
    0005_media_upload_device_grants.sql)
      printf "%s" "SELECT to_regclass('im_v2.media_upload_grants') IS NOT NULL"
      ;;
    0006_durable_work_retry_pause.sql)
      printf "%s" "SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'room_outbox' AND column_name = 'paused_at')"
      ;;
    0007_durable_work_operator_replay_audit.sql)
      printf "%s" "SELECT to_regclass('im_v2.durable_work_replay_audit') IS NOT NULL"
      ;;
    0008_push_wake_admission_recovery.sql)
      printf "%s" "SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'push_wake_outbox' AND column_name = 'admitted_at')"
      ;;
    0009_push_device_endpoints.sql)
      printf "%s" "SELECT to_regclass('im_v2.push_device_endpoints') IS NOT NULL"
      ;;
    0010_user_shard_router_control.sql)
      printf "%s" "SELECT to_regclass('im_v2.user_shard_router_configuration') IS NOT NULL"
      ;;
    0011_user_shard_migrations.sql)
      printf "%s" "SELECT to_regclass('im_v2.user_shard_migrations') IS NOT NULL"
      ;;
    0012_user_shard_migration_retention_leases.sql)
      printf "%s" "SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'user_shard_migrations' AND column_name = 'retention_claim_token')"
      ;;
    0013_user_shard_migration_forwarding.sql)
      printf "%s" "SELECT EXISTS (SELECT 1 FROM pg_constraint AS c JOIN pg_class AS relation ON relation.oid = c.conrelid JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace WHERE namespace.nspname = 'im_v2' AND relation.relname = 'user_shard_migrations' AND c.conname = 'user_shard_migrations_phase_check' AND pg_get_constraintdef(c.oid) LIKE '%forwarding%')"
      ;;
    0014_account_password_login_rate_limit.sql)
      printf "%s" "SELECT to_regclass('im_v2.account_password_login_rate_limits') IS NOT NULL"
      ;;
    0015_public_identities.sql)
      printf "%s" "SELECT to_regclass('im_v2.public_user_profiles') IS NOT NULL"
      ;;
    0016_account_password_authentication_audit.sql)
      printf "%s" "SELECT to_regclass('im_v2.account_password_authentication_audit') IS NOT NULL"
      ;;
    0017_public_profile_update_outbox.sql)
      printf "%s" "SELECT to_regclass('im_v2.public_profile_update_outbox') IS NOT NULL"
      ;;
    0018_account_edge_client_rate_limit.sql)
      printf "%s" "SELECT to_regclass('im_v2.account_edge_client_rate_limits') IS NOT NULL"
      ;;
    0019_account_disable.sql)
      printf "%s" "SELECT to_regclass('im_v2.account_disables') IS NOT NULL"
      ;;
    0020_fanout_delivery_claim_lanes.sql)
      printf "%s" "SELECT to_regclass('im_v2.fanout_deliveries_fresh_claim_idx') IS NOT NULL"
      ;;
    0021_group_delivery_modes.sql)
      printf "%s" "SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'rooms' AND column_name = 'delivery_mode')"
      ;;
    0022_group_event_wake_outbox.sql)
      printf "%s" "SELECT to_regclass('im_v2.group_event_wake_outbox') IS NOT NULL"
      ;;
    0023_fanout_set_based_planner.sql)
      printf "%s" "SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'fanout_plans' AND column_name = 'enumerated_target_count')"
      ;;
    0024_drop_redundant_user_sync_pull_index.sql)
      printf "%s" "SELECT to_regclass('im_v2.user_sync_log_pull_idx') IS NULL"
      ;;
    0025_drop_legacy_fanout_delivery_claim_index.sql)
      printf "%s" "SELECT to_regclass('im_v2.fanout_deliveries_claim_idx') IS NULL"
      ;;
    0026_drop_legacy_fanout_retry_claim_index.sql)
      printf "%s" "SELECT to_regclass('im_v2.fanout_deliveries_retry_claim_idx') IS NULL"
      ;;
    0027_drop_redundant_fanout_delivery_event_foreign_key.sql)
      printf "%s" "SELECT NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fanout_deliveries_source_event_id_fkey' AND conrelid = 'im_v2.fanout_deliveries'::regclass)"
      ;;
    0028_narrow_user_sync_log_identity_uniqueness.sql)
      printf "%s" "SELECT to_regclass('im_v2.user_sync_log_nonfanout_identity_idx') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'user_sync_log_user_id_source_event_id_projection_kind_key' AND conrelid = 'im_v2.user_sync_log'::regclass)"
      ;;
    0029_shared_fanout_sync_payloads.sql)
      printf "%s" "SELECT to_regclass('im_v2.fanout_sync_payloads') IS NOT NULL AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'user_sync_log' AND column_name = 'payload_storage')"
      ;;
    *)
      printf 'missing local migration marker for %s; add one before using a retained volume.\n' "$1" >&2
      return 1
      ;;
  esac
}

for migration_path in "${v2_dir}"/sql/[0-9][0-9][0-9][0-9]_*.sql; do
  migration_name="$(basename "${migration_path}")"
  already_recorded="$(scalar "SELECT EXISTS (SELECT 1 FROM im_v2.local_schema_migrations WHERE migration_name = '${migration_name}')")"
  test "${already_recorded}" = 'f' || continue

  marker_query="$(migration_marker "${migration_name}")"
  if test "$(scalar "${marker_query}")" = 't'; then
    psql -c "INSERT INTO im_v2.local_schema_migrations (migration_name) VALUES ('${migration_name}') ON CONFLICT DO NOTHING" >/dev/null
    printf 'local V2 migration recorded: %s\n' "${migration_name}"
    continue
  fi

  psql -f "/docker-entrypoint-initdb.d/${migration_name}" >/dev/null
  test "$(scalar "${marker_query}")" = 't' || {
    printf 'local V2 migration did not establish its marker: %s\n' "${migration_name}" >&2
    exit 1
  }
  psql -c "INSERT INTO im_v2.local_schema_migrations (migration_name) VALUES ('${migration_name}')" >/dev/null
  printf 'local V2 migration applied: %s\n' "${migration_name}"
done
