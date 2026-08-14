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
    0029_shared_fanout_sync_payloads.sql)
      printf "%s" "SELECT to_regclass('im_v2.fanout_sync_payloads') IS NOT NULL AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'user_sync_log' AND column_name = 'payload_storage')"
      ;;
    0030_group_room_staged_audience_import.sql)
      printf "%s" "SELECT to_regclass('im_v2.group_room_creation_drafts') IS NOT NULL"
      ;;
    0031_group_room_finalizing_recovery_index.sql)
      printf "%s" "SELECT to_regclass('im_v2.group_room_creation_drafts_finalizing_recovery_idx') IS NOT NULL"
      ;;
    0032_profile_views.sql)
      printf "%s" "SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'public_user_profiles' AND column_name = 'avatar_media_id')"
      ;;
    0033_profile_update_operations.sql)
      printf "%s" "SELECT to_regclass('im_v2.public_profile_update_operations') IS NOT NULL"
      ;;
    0034_user_add_preferences.sql)
      printf "%s" "SELECT to_regclass('im_v2.user_add_preferences') IS NOT NULL"
      ;;
    0035_rich_message_content.sql)
      printf "%s" "SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'messages' AND column_name = 'rich_entities')"
      ;;
    0036_read_receipt_visibility.sql)
      printf "%s" "SELECT to_regclass('im_v2.user_read_receipt_preferences') IS NOT NULL"
      ;;
    0037_live_activity.sql)
      printf "%s" "SELECT to_regclass('im_v2.user_live_activity_preferences') IS NOT NULL"
      ;;
    0038_conversation_message_group_capabilities.sql)
      printf "%s" "SELECT to_regclass('im_v2.message_forward_operations') IS NOT NULL"
      ;;
    0039_device_revocation_worker_cursor_namespace.sql)
      printf "%s" "SELECT NOT EXISTS (SELECT 1 FROM im_v2.gateway_worker_cursors AS retired LEFT JOIN im_v2.gateway_worker_cursors AS current ON current.worker_name = 'device-revocation' AND current.node_id = retired.node_id WHERE retired.worker_name = 'device-revocation-v1' AND (current.last_event_id IS NULL OR current.last_event_id < retired.last_event_id))"
      ;;
    0040_device_session_management.sql)
      printf "%s" "SELECT to_regclass('im_v2.device_session_operations') IS NOT NULL AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'auth_devices' AND column_name = 'last_active_at')"
      ;;
    0041_private_timeline_activities.sql)
      printf "%s" "SELECT to_regclass('im_v2.room_timeline_activities') IS NOT NULL AND to_regclass('im_v2.direct_message_denials') IS NOT NULL AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'messages' AND column_name = 'timeline_sequence')"
      ;;
    0042_special_accounts.sql)
      printf "%s" "SELECT to_regclass('im_v2.special_accounts') IS NOT NULL AND to_regclass('im_v2.support_conversation_sessions') IS NOT NULL AND to_regclass('im_v2.special_account_message_operations') IS NOT NULL"
      ;;
    0043_profile_presentations.sql)
      printf "%s" "SELECT to_regclass('im_v2.user_contact_aliases') IS NOT NULL AND to_regclass('im_v2.room_member_nicknames') IS NOT NULL"
      ;;
    0044_content_review_pipeline.sql)
      printf "%s" "SELECT to_regclass('im_v2.content_review_jobs') IS NOT NULL AND to_regclass('im_v2.content_review_decisions') IS NOT NULL AND to_regclass('im_v2.content_review_findings') IS NOT NULL AND to_regclass('im_v2.content_review_cases') IS NOT NULL"
      ;;
    0045_content_review_retry_fencing.sql)
      printf "%s" "SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'content_review_jobs' AND column_name = 'next_attempt_at') AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'content_review_jobs' AND column_name = 'paused_at') AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'content_review_jobs' AND column_name = 'finding_category') AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'content_review_jobs' AND column_name = 'finding_severity') AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'content_review_jobs' AND column_name = 'finding_confidence') AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'im_v2.content_review_jobs'::regclass AND conname = 'content_review_jobs_staged_finding_check')"
      ;;
    0046_account_lifecycle_and_profile_state.sql)
      printf "%s" "SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'public_profile_update_outbox' AND column_name = 'profile_state') AND to_regclass('im_v2.public_user_profiles_active_handle_idx') IS NOT NULL"
      ;;
    0047_hot_path_lookup_indexes.sql)
      printf "%s" "SELECT to_regclass('im_v2.room_memberships_current_user_rooms_idx') IS NOT NULL AND to_regclass('im_v2.direct_room_pairs_higher_user_idx') IS NOT NULL AND to_regclass('im_v2.user_blocks_blocked_blocker_idx') IS NOT NULL AND to_regclass('im_v2.user_sync_log_direct_room_profile_room_idx') IS NOT NULL AND to_regclass('im_v2.user_sync_log_direct_receipt_event_idx') IS NOT NULL"
      ;;
    0048_staged_group_operation_fingerprint.sql)
      printf "%s" "SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'group_room_operations' AND column_name = 'audience_kind') AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'group_room_operations' AND column_name = 'initial_member_count')"
      ;;
    0049_media_worker_retry_fencing.sql)
      printf "%s" "SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'media_scan_outbox' AND column_name = 'next_attempt_at') AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'media_purge_outbox' AND column_name = 'paused_at')"
      ;;
    0050_bounded_housekeeping_indexes.sql)
      # Snapshot V3 intentionally drops the V2 sync_snapshots relation and its
      # cleanup index. The other immutable 0050 indexes remain valid markers.
      printf "%s" "SELECT to_regclass('im_v2.sync_tokens_expiry_idx') IS NOT NULL AND to_regclass('im_v2.sync_receipts_expiry_idx') IS NOT NULL AND to_regclass('im_v2.fanout_plans_terminal_cleanup_idx') IS NOT NULL"
      ;;
    0051_read_receipt_preference_propagation.sql)
      printf "%s" "SELECT to_regclass('im_v2.read_receipt_preference_propagation_outbox') IS NOT NULL AND to_regclass('im_v2.read_receipt_preference_propagation_claim_idx') IS NOT NULL AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'read_receipt_preference_propagation_outbox' AND column_name = 'paused_at')"
      ;;
    0052_snapshot_v3.sql)
      printf "%s" "SELECT to_regclass('im_v2.user_projection_versions') IS NOT NULL AND to_regclass('im_v2.user_projection_effects') IS NOT NULL AND to_regclass('im_v2.user_sync_retention') IS NOT NULL AND to_regclass('im_v2.sync_snapshot_artifacts') IS NOT NULL AND to_regclass('im_v2.device_snapshot_resets') IS NOT NULL AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'im_v2' AND table_name = 'read_receipt_operations' AND column_name = 'projection_recipient_user_id') AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'user_sync_log_snapshot_v3_projection' AND NOT tgisinternal) AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'user_sync_log_projection_effect_v3' AND NOT tgisinternal)"
      ;;
    0053_shared_snapshot_and_revoked_device_cleanup.sql)
      printf "%s" "SELECT to_regclass('im_v2.sync_snapshot_artifacts_reusable_idx') IS NOT NULL AND to_regclass('im_v2.auth_devices_revoked_cleanup_idx') IS NOT NULL"
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
