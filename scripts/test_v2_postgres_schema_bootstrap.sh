#!/usr/bin/env bash
set -Eeuo pipefail

# Disposable clean-bootstrap and schema-drift regression. It never reuses the
# developer's local PostgreSQL volume.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
compose_file="${repo_root}/IMV2/docker-compose.isolated-tests.yml"
schema_file="${repo_root}/IMV2/sql/schema.sql"
schema_contract_query="${repo_root}/IMV2/scripts/current_v2_schema_contract.sql"
project_name="${IMV2_SCHEMA_BOOTSTRAP_PROJECT:-imv2-schema-bootstrap-regression-$$}"
bootstrap_db="imv2_bootstrap_$$"
restore_db="imv2_restore_$$"
work_dir="$(mktemp -d)"

# Native mode uses standard PGHOST/PGPORT/PGUSER credentials and creates only
# uniquely named disposable databases. The connection must allow CREATE DATABASE.
if [[ "${IMV2_SCHEMA_BOOTSTRAP_NATIVE:-0}" == '1' ]]; then
  command -v psql >/dev/null
  admin_psql() { command psql -v ON_ERROR_STOP=1 -d postgres "$@"; }
  psql() { command psql -v ON_ERROR_STOP=1 -d "${bootstrap_db}" "$@"; }
  restore_psql() { command psql -v ON_ERROR_STOP=1 -d "${restore_db}" "$@"; }
  dump_schema() { command pg_dump --schema-only --schema=im_v2 --no-owner --no-privileges --no-comments -d "$1"; }
  dump_topology() { command pg_dump --data-only --table=im_v2.room_recovery_topology --table=im_v2.control_housekeeping_cursor --no-owner --no-privileges -d "$1"; }
  bootstrap_created=0
  restore_created=0
  cleanup() {
    if [[ "${bootstrap_created}" == 1 ]]; then
      admin_psql -c "DROP DATABASE IF EXISTS ${bootstrap_db}" >/dev/null 2>&1 || true
    fi
    if [[ "${restore_created}" == 1 ]]; then
      admin_psql -c "DROP DATABASE IF EXISTS ${restore_db}" >/dev/null 2>&1 || true
    fi
    rm -rf "${work_dir}"
  }
  trap cleanup EXIT
  admin_psql -c "CREATE DATABASE ${bootstrap_db} TEMPLATE template0" >/dev/null
  bootstrap_created=1
  admin_psql -c "CREATE DATABASE ${restore_db} TEMPLATE template0" >/dev/null
  restore_created=1
else
  command -v docker >/dev/null 2>&1 || {
    printf 'missing required command: docker\n' >&2
    exit 1
  }
  compose=(docker compose --project-name "${project_name}" --file "${compose_file}")
  cleanup() {
    "${compose[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
    rm -rf "${work_dir}"
  }
  trap cleanup EXIT
  "${compose[@]}" up --detach --wait postgres
  bootstrap_db=im_v2_test
  psql() { "${compose[@]}" exec -T postgres psql -v ON_ERROR_STOP=1 -U im_v2_test -d "${bootstrap_db}" "$@"; }
  restore_psql() { "${compose[@]}" exec -T postgres psql -v ON_ERROR_STOP=1 -U im_v2_test -d "${restore_db}" "$@"; }
  dump_schema() { "${compose[@]}" exec -T postgres pg_dump --schema-only --schema=im_v2 --no-owner --no-privileges --no-comments -U im_v2_test -d "$1"; }
  dump_topology() { "${compose[@]}" exec -T postgres pg_dump --data-only --table=im_v2.room_recovery_topology --table=im_v2.control_housekeeping_cursor --no-owner --no-privileges -U im_v2_test -d "$1"; }
  psql -c "CREATE DATABASE ${restore_db} TEMPLATE template0" >/dev/null
fi
scalar() {
  psql -tAc "$1" | tr -d '[:space:]'
}
current_schema_contract() {
  psql -tA < "${schema_contract_query}" | tr -d '[:space:]'
}

test "$(current_schema_contract)" = 'f'

psql < "${schema_file}" >/dev/null
test "$(current_schema_contract)" = 't'

# A login role named im_v2 makes the schema visible through PostgreSQL's
# default "$user" search path. The catalog contract must also work when
# pg_get_constraintdef / pg_get_indexdef would otherwise omit its qualifier.
visible_schema_contract="$({
  printf '%s\n' 'SET search_path TO im_v2, public;'
  cat "${schema_contract_query}"
} | psql -qAt | tr -d '[:space:]')"
test "${visible_schema_contract}" = 't'

assert_scalar() {
  local label="$1"
  local query="$2"
  local expected="$3"
  local actual
  actual="$(scalar "${query}")"
  if [[ "${actual}" != "${expected}" ]]; then
    printf '%s: expected %s, got %s\n' "${label}" "${expected}" "${actual}" >&2
    exit 1
  fi
}

# Fresh current66 canonical schema, including permanent typed receipts and
# remote-device security metadata. Counts include views and application-only
# triggers; retired ledgers must remain absent rather than be recreated.
assert_scalar 'im_v2 relation count' \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'im_v2'" '172'
assert_scalar 'im_v2 index count' \
  "SELECT count(*) FROM pg_indexes WHERE schemaname = 'im_v2'" '368'
assert_scalar 'im_v2 application trigger count' \
  "SELECT count(*) FROM pg_trigger AS trigger JOIN pg_class AS relation ON relation.oid = trigger.tgrelid JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace WHERE namespace.nspname = 'im_v2' AND NOT trigger.tgisinternal" '64'
assert_scalar 'im_v2 function count' \
  "SELECT count(*) FROM pg_proc AS procedure JOIN pg_namespace AS namespace ON namespace.oid = procedure.pronamespace WHERE namespace.nspname = 'im_v2'" '40'

# A same-named trigger function is not enough: replacing its body must fail
# readiness, as must a nullable ready-variant constraint or a weakened replay key.
for drift in \
  "DROP TABLE im_v2.mention_push_wake_intents;" \
  "ALTER TABLE im_v2.push_wake_outbox ADD FOREIGN KEY (source_event_id) REFERENCES im_v2.room_events(event_id);" \
  "DROP INDEX im_v2.account_password_login_rate_limits_cleanup_idx;" \
  "DROP TABLE im_v2.message_edit_visibility;" \
  "ALTER TABLE im_v2.message_edit_visibility DROP CONSTRAINT message_edit_visibility_pkey;" \
  "ALTER TABLE im_v2.message_edit_visibility ALTER COLUMN committed_membership_revision DROP NOT NULL;" \
  "DROP INDEX im_v2.message_edit_visibility_latest_idx;" \
  "DROP TRIGGER room_events_capture_message_edit_visibility ON im_v2.room_events;" \
  "ALTER TABLE im_v2.room_events DISABLE TRIGGER room_events_capture_message_edit_visibility;" \
  "DROP TRIGGER message_edit_visibility_immutable ON im_v2.message_edit_visibility;" \
  'CREATE OR REPLACE FUNCTION im_v2.capture_message_edit_visibility() RETURNS trigger LANGUAGE plpgsql VOLATILE AS $$ BEGIN RETURN NEW; END; $$;' \
  'CREATE OR REPLACE FUNCTION im_v2.reject_message_edit_visibility_mutation() RETURNS trigger LANGUAGE plpgsql VOLATILE AS $$ BEGIN RETURN OLD; END; $$;' \
  "DROP TABLE im_v2.resource_import_source_closures;" \
  "ALTER TABLE im_v2.resource_import_source_closures DROP CONSTRAINT resource_import_source_closures_pkey;" \
  "ALTER TABLE im_v2.resource_import_source_closures DROP CONSTRAINT resource_import_source_closures_finite_time;" \
  "DROP TRIGGER resource_import_source_closures_immutable ON im_v2.resource_import_source_closures;" \
  'CREATE OR REPLACE FUNCTION im_v2.reject_resource_import_source_closure_mutation() RETURNS trigger LANGUAGE plpgsql VOLATILE AS $$ BEGIN RETURN OLD; END; $$;' \
  "DROP TRIGGER device_revocation_events_commit_order ON im_v2.device_revocation_events;" \
  "ALTER TABLE im_v2.device_revocation_events DISABLE TRIGGER device_revocation_events_commit_order;" \
  "ALTER SEQUENCE im_v2.device_revocation_events_event_id_seq CACHE 8;" \
  "ALTER SEQUENCE im_v2.device_revocation_events_event_id_seq INCREMENT BY -1 MINVALUE -9223372036854775808;" \
  'CREATE OR REPLACE FUNCTION im_v2.serialize_device_revocation_events() RETURNS trigger LANGUAGE plpgsql VOLATILE AS $$ BEGIN RETURN NULL; END; $$;' \
  "DROP TRIGGER resource_group_avatar_operations_immutable ON im_v2.resource_group_avatar_operations;" \
  "DROP TRIGGER resource_group_avatar_closures_immutable ON im_v2.resource_group_avatar_closures;" \
  "DROP TRIGGER resource_group_avatar_operations_close_fence ON im_v2.resource_group_avatar_operations;" \
  "ALTER FUNCTION im_v2.fence_group_avatar_terminal_result() STABLE;" \
  "ALTER TABLE im_v2.resource_group_avatars DROP CONSTRAINT resource_group_avatars_media_id_fkey;" \
  "ALTER TABLE im_v2.resource_catalog DROP CONSTRAINT resource_catalog_check;" \
  "ALTER TABLE im_v2.resource_variants DROP CONSTRAINT resource_variants_variant_id_key;" \
  "ALTER TABLE im_v2.resource_storage_migrations DROP CONSTRAINT resource_storage_migrations_destination_placement_id_key;" \
  "DROP INDEX im_v2.resource_storage_migrations_active_media_idx;" \
  "DROP INDEX im_v2.resource_storage_migrations_retained_idx;" \
  "ALTER TABLE im_v2.resource_variants ALTER COLUMN variant_id DROP NOT NULL;" \
  "ALTER TABLE im_v2.resource_import_holds ALTER COLUMN sha256 DROP NOT NULL;" \
  "ALTER TABLE im_v2.resource_forward_outputs DROP CONSTRAINT resource_forward_outputs_export_id_ordinal_fkey;" \
  "ALTER TABLE im_v2.resource_upload_sessions DROP CONSTRAINT resource_upload_sessions_home_kind_home_id_actor_user_id_op_key;" \
  "ALTER TABLE im_v2.resource_variants DROP CONSTRAINT resource_variants_check; ALTER TABLE im_v2.resource_variants ADD CONSTRAINT resource_variants_check CHECK(state <> 'ready' OR (byte_count > 0 AND octet_length(sha256)=32));" \
  'CREATE OR REPLACE FUNCTION im_v2.reject_closed_message_acceptance() RETURNS trigger LANGUAGE plpgsql VOLATILE AS $$ BEGIN RETURN NEW; END; $$;'
do
  drift_result="$({
    printf '%s\n' 'BEGIN;' "${drift}"
    cat "${schema_contract_query}"
    printf '%s\n' 'ROLLBACK;'
  } | psql -qAt | tr -d '[:space:]')"
  test "${drift_result}" = 'f'
done

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

# Compare database-normalized DDL, not source formatting/order. A separate
# restore also verifies that every dependency in the canonical schema survives
# a normal PostgreSQL schema export/import.
dump_schema "${bootstrap_db}" > "${work_dir}/bootstrap.sql"
restore_psql < "${work_dir}/bootstrap.sql" >/dev/null
# Topology and housekeeping cursor values are required runtime state, not DDL. Preserve the
# actual value in this export/restore check instead of fabricating a new one.
dump_topology "${bootstrap_db}" > "${work_dir}/topology.sql"
restore_psql < "${work_dir}/topology.sql" >/dev/null
dump_schema "${restore_db}" > "${work_dir}/restored.sql"
normalize_schema < "${work_dir}/bootstrap.sql" > "${work_dir}/bootstrap.normalized.sql"
normalize_schema < "${work_dir}/restored.sql" > "${work_dir}/restored.normalized.sql"
diff --unified "${work_dir}/bootstrap.normalized.sql" "${work_dir}/restored.normalized.sql"

test "$(restore_psql -tA < "${schema_contract_query}" | tr -d '[:space:]')" = 't'
test "$(restore_psql -tAc 'SELECT count(*) = 1 AND bool_and(singleton AND rotation = 0) FROM im_v2.control_housekeeping_cursor' | tr -d '[:space:]')" = 't'
psql -c 'ALTER TABLE im_v2.control_housekeeping_cursor DROP CONSTRAINT control_housekeeping_cursor_rotation_check' >/dev/null
test "$(current_schema_contract)" = 'f'
psql -c 'ALTER TABLE im_v2.control_housekeeping_cursor ADD CONSTRAINT control_housekeeping_cursor_rotation_check CHECK (rotation >= 0)' >/dev/null
test "$(current_schema_contract)" = 't'


# Retired operation/draft tables are forbidden even if an old deployment
# recreates them with plausible keys. Check each independently, then restore
# the clean schema before testing the next drift.
for retired_table in \
  group_room_operations group_room_creation_drafts group_room_creation_draft_members \
  direct_room_operations user_relationship_operations user_block_operations \
  room_pinned_message_operations group_announcement_operations \
  group_permission_operations group_role_operations \
  message_edit_operations message_withdrawal_operations message_reaction_operations
do
  psql -c "CREATE TABLE im_v2.${retired_table} (operation_id UUID PRIMARY KEY)" >/dev/null
  test "$(current_schema_contract)" = 'f'
  psql -c "DROP TABLE im_v2.${retired_table}" >/dev/null
  test "$(current_schema_contract)" = 't'
done

psql -c 'ALTER TABLE im_v2.room_activation_leases DROP CONSTRAINT room_activation_leases_holder_check' >/dev/null
test "$(current_schema_contract)" = 'f'
psql -c "ALTER TABLE im_v2.room_activation_leases ADD CONSTRAINT room_activation_leases_holder_check CHECK ((host_id IS NULL AND host_incarnation_id IS NULL AND expires_at IS NULL) OR (host_id IS NOT NULL AND length(btrim(host_id)) > 0 AND host_incarnation_id IS NOT NULL AND expires_at IS NOT NULL AND isfinite(expires_at)))" >/dev/null
test "$(current_schema_contract)" = 't'

psql -c 'CREATE INDEX rooms_last_event_at_idx ON im_v2.rooms(last_event_at DESC, room_id)' >/dev/null
test "$(current_schema_contract)" = 'f'
psql -c 'DROP INDEX im_v2.rooms_last_event_at_idx' >/dev/null
test "$(current_schema_contract)" = 't'

psql -c 'DROP INDEX im_v2.messages_latest_visible_idx' >/dev/null
test "$(current_schema_contract)" = 'f'
psql -c 'CREATE INDEX messages_latest_visible_idx ON im_v2.messages(room_id)' >/dev/null
test "$(current_schema_contract)" = 'f'
psql -c 'DROP INDEX im_v2.messages_latest_visible_idx' >/dev/null
psql -c 'CREATE INDEX messages_latest_visible_idx ON im_v2.messages(room_id, room_sequence DESC, message_id DESC) WHERE withdrawn_at IS NULL' >/dev/null
test "$(current_schema_contract)" = 't'

psql -c 'DROP INDEX im_v2.messages_room_log_candidates_idx' >/dev/null
test "$(current_schema_contract)" = 'f'
psql -c 'CREATE INDEX messages_room_log_candidates_idx ON im_v2.messages(room_id, timeline_sequence)' >/dev/null
test "$(current_schema_contract)" = 'f'
psql -c 'DROP INDEX im_v2.messages_room_log_candidates_idx' >/dev/null
psql -c "CREATE INDEX messages_room_log_candidates_idx ON im_v2.messages(room_id, timeline_sequence) WHERE accepted_event_storage = 'message_row'" >/dev/null
test "$(current_schema_contract)" = 't'

psql -c 'DROP INDEX im_v2.messages_visible_membership_idx' >/dev/null
test "$(current_schema_contract)" = 'f'
psql -c 'CREATE INDEX messages_visible_membership_idx ON im_v2.messages(room_id)' >/dev/null
test "$(current_schema_contract)" = 'f'
psql -c 'DROP INDEX im_v2.messages_visible_membership_idx' >/dev/null
psql -c "CREATE INDEX messages_visible_membership_idx ON im_v2.messages(room_id, accepted_membership_revision, room_sequence DESC) WHERE accepted_event_storage = 'message_row' AND withdrawn_at IS NULL" >/dev/null
test "$(current_schema_contract)" = 't'

psql -c 'DROP INDEX im_v2.room_events_accepted_membership_idx' >/dev/null
test "$(current_schema_contract)" = 'f'
psql -c 'CREATE INDEX room_events_accepted_membership_idx ON im_v2.room_events(room_id)' >/dev/null
test "$(current_schema_contract)" = 'f'
psql -c 'DROP INDEX im_v2.room_events_accepted_membership_idx' >/dev/null
psql -c "CREATE INDEX room_events_accepted_membership_idx ON im_v2.room_events(room_id, committed_membership_revision, room_sequence DESC) WHERE event_type = 'message.accepted'" >/dev/null
test "$(current_schema_contract)" = 't'

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
