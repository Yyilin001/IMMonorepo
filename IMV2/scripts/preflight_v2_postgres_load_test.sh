#!/usr/bin/env bash
set -Eeuo pipefail

credentials_path="${1:-}"
duration_seconds="${2:-}"
expected_messages="${3:-}"
database_url="${IM_V2_PROFILE_DATABASE_URL:-}"
capacity_profile_id="${IM_V2_LOAD_CAPACITY_PROFILE_ID:-loadtest-v17}"
expiry_margin_seconds="${IM_V2_LOAD_TOKEN_EXPIRY_MARGIN_SECONDS:-120}"
lease_margin_seconds="${IM_V2_LOAD_LEASE_MARGIN_SECONDS:-1800}"
credit_headroom_percent="${IM_V2_LOAD_CREDIT_HEADROOM_PERCENT:-10}"
maximum_starting_messages="${IM_V2_LOAD_MAX_MESSAGES_AT_START:-}"

usage() {
  printf 'usage: IM_V2_PROFILE_DATABASE_URL=... %s CREDENTIALS_JSONL DURATION_SECONDS EXPECTED_MESSAGES\n' "$0" >&2
}

fail() {
  printf 'preflight failed: %s\n' "$1" >&2
  exit 1
}

[[ -n "${database_url}" ]] || fail 'IM_V2_PROFILE_DATABASE_URL is required'
[[ -f "${credentials_path}" ]] || { usage; fail 'credentials JSONL does not exist'; }
[[ "${duration_seconds}" =~ ^[1-9][0-9]*$ ]] || { usage; fail 'duration must be a positive integer'; }
[[ "${expected_messages}" =~ ^[0-9]+$ ]] || { usage; fail 'expected messages must be a non-negative integer'; }
[[ "${expiry_margin_seconds}" =~ ^[0-9]+$ ]] || fail 'token expiry margin must be a non-negative integer'
[[ "${lease_margin_seconds}" =~ ^[0-9]+$ ]] || fail 'lease margin must be a non-negative integer'
[[ "${credit_headroom_percent}" =~ ^[0-9]+$ ]] || fail 'credit headroom percent must be a non-negative integer'
if [[ -n "${maximum_starting_messages}" ]]; then
  [[ "${maximum_starting_messages}" =~ ^[0-9]+$ ]] || fail 'maximum starting messages must be a non-negative integer'
fi

for command in jq psql; do
  command -v "${command}" >/dev/null 2>&1 || fail "missing required command: ${command}"
done

credential_count="$(wc -l < "${credentials_path}" | tr -d ' ')"
[[ "${credential_count}" =~ ^[1-9][0-9]*$ ]] || fail 'credentials JSONL is empty'

# Reduce the file as a stream. No token value is printed or copied into
# diagnostics; only aggregate counts and the minimum expiry escape jq.
credential_summary="$({
  jq -n -r '
    reduce inputs as $credential (
      {count: 0, valid: true, minimum_expiry: null};
      .count += 1
      | .valid = (.valid
          and ($credential.accessToken | type == "string" and length > 0)
          and ($credential.deviceID | type == "string" and length > 0)
          and ($credential.userID | type == "string" and length > 0)
          and ($credential.accessTokenExpiresAtMilliseconds | type == "number")
          and ($credential.targetRoomIDs | type == "array" and length == 2)
          and ($credential.targetRoomIDs | all(type == "string" and length > 0))
          and (($credential.targetRoomIDs | unique | length) == 2))
      | .minimum_expiry = if .minimum_expiry == null
          or $credential.accessTokenExpiresAtMilliseconds < .minimum_expiry
        then $credential.accessTokenExpiresAtMilliseconds
        else .minimum_expiry end
    )
    | [.count, .valid, .minimum_expiry] | @tsv
  ' "${credentials_path}"
} 2>/dev/null)" || fail 'credentials JSONL is malformed'
IFS=$'\t' read -r parsed_count credentials_valid earliest_expiry_ms <<< "${credential_summary}"
[[ "${parsed_count}" == "${credential_count}" && "${credentials_valid}" == 'true' ]] \
  || fail 'credentials JSONL is missing required fields'

now_epoch="$(date +%s)"
expected_end_epoch="$((now_epoch + duration_seconds))"
required_token_expiry_ms="$(((expected_end_epoch + expiry_margin_seconds) * 1000))"
(( earliest_expiry_ms >= required_token_expiry_ms )) \
  || fail 'at least one access token expires before test end plus safety margin'

# Materialize only user/room identifiers in a private temporary file so the
# database can prove that every workload target belongs to this deployment's
# profile and remains authoritatively sendable. The clear access token never
# enters this file, SQL, logs, or command arguments.
target_memberships_path="$(mktemp "${TMPDIR:-/tmp}/imv2-load-targets.XXXXXX")"
chmod 600 "${target_memberships_path}"
trap 'rm -f "${target_memberships_path}"' EXIT
jq -r '.targetRoomIDs[] as $room | [.userID, $room] | @tsv' \
  "${credentials_path}" > "${target_memberships_path}" \
  || fail 'cannot extract credential target rooms'
target_membership_count="$(wc -l < "${target_memberships_path}" | tr -d ' ')"
(( target_membership_count == credential_count * 2 )) \
  || fail 'credentials must contain exactly two target rooms per user'

target_summary="$({
  psql "${database_url}" -qAtF '|' -v ON_ERROR_STOP=1 \
    -v profile_id="${capacity_profile_id}" \
    -v minimum_valid_epoch="$((expected_end_epoch + lease_margin_seconds))" <<SQL
      CREATE TEMP TABLE load_target_memberships (
        user_id uuid NOT NULL,
        room_id uuid NOT NULL
      );
      \copy load_target_memberships FROM '${target_memberships_path}' WITH (FORMAT csv, DELIMITER E'\t')
      SELECT COUNT(*),
             COUNT(*) FILTER (WHERE room.room_id IS NULL),
             COUNT(*) FILTER (WHERE room.room_kind IS DISTINCT FROM 'direct'),
             COUNT(*) FILTER (WHERE room.capacity_profile_id IS DISTINCT FROM :'profile_id'),
             COUNT(*) FILTER (WHERE room.frozen_at IS NOT NULL),
             COUNT(*) FILTER (WHERE shard.room_shard_id IS NULL),
             COUNT(*) FILTER (WHERE shard.valid_until <= to_timestamp(:minimum_valid_epoch)),
             COUNT(*) FILTER (WHERE membership.room_id IS NULL),
             COUNT(*) FILTER (WHERE profile.user_id IS NULL OR disabled.user_id IS NOT NULL),
             COUNT(*) FILTER (WHERE mute.room_id IS NOT NULL),
             COUNT(*) FILTER (WHERE pair.room_id IS NULL),
             COUNT(*) FILTER (
               WHERE pair.room_id IS NOT NULL
                 AND target.user_id <> pair.lower_user_id
                 AND target.user_id <> pair.higher_user_id
             )
      FROM load_target_memberships AS target
      LEFT JOIN im_v2.rooms AS room ON room.room_id = target.room_id
      LEFT JOIN im_v2.shard_admission_pools AS shard
        ON shard.room_shard_id = room.room_shard_id
       AND shard.capacity_profile_id = room.capacity_profile_id
      LEFT JOIN im_v2.room_memberships AS membership
        ON membership.room_id = target.room_id
       AND membership.user_id = target.user_id
       AND membership.joined_revision <= room.membership_revision
       AND (membership.left_revision IS NULL
            OR membership.left_revision > room.membership_revision)
      LEFT JOIN im_v2.public_user_profiles AS profile
        ON profile.user_id = target.user_id
       AND profile.state = 'active'
      LEFT JOIN im_v2.account_disables AS disabled ON disabled.user_id = target.user_id
      LEFT JOIN im_v2.room_member_mutes AS mute
        ON mute.room_id = target.room_id
       AND mute.user_id = target.user_id
       AND mute.mute_until > now()
      LEFT JOIN im_v2.direct_room_pairs AS pair ON pair.room_id = target.room_id;
SQL
} 2>/dev/null)" || fail 'cannot validate credential target rooms'
IFS='|' read -r checked_targets missing_rooms non_direct_rooms wrong_profile_rooms \
  frozen_rooms missing_target_pools expiring_target_pools missing_memberships \
  inactive_senders muted_senders missing_pairs sender_pair_mismatches <<< "${target_summary}"
(( checked_targets == target_membership_count )) || fail 'database target validation was incomplete'
(( missing_rooms == 0 )) || fail 'one or more credential target rooms do not exist'
(( non_direct_rooms == 0 )) || fail 'one or more credential targets are not direct rooms'
(( wrong_profile_rooms == 0 )) || fail 'one or more credential targets use another capacity profile'
(( frozen_rooms == 0 )) || fail 'one or more credential target rooms are frozen'
(( missing_target_pools == 0 )) || fail 'one or more credential targets lack a shard admission pool'
(( expiring_target_pools == 0 )) || fail 'one or more target shard leases end before the safety margin'
(( missing_memberships == 0 )) || fail 'one or more users lack active target-room membership'
(( inactive_senders == 0 )) || fail 'one or more target users are inactive or disabled'
(( muted_senders == 0 )) || fail 'one or more target users are currently muted'
(( missing_pairs == 0 )) || fail 'one or more credential targets lack a direct-room pair'
(( sender_pair_mismatches == 0 )) || fail 'one or more target users are not members of the direct pair'

settings="$({
  psql "${database_url}" -v ON_ERROR_STOP=1 -AtF '|' -c "
    SELECT current_setting('server_version_num')::integer,
           current_setting('fsync'),
           current_setting('full_page_writes'),
           current_setting('synchronous_commit'),
           current_setting('track_io_timing'),
           current_setting('track_wal_io_timing'),
           current_setting('log_checkpoints'),
           current_setting('checkpoint_timeout'),
           current_setting('checkpoint_completion_target'),
           current_setting('max_wal_size'),
           current_setting('wal_compression'),
           current_setting('checkpoint_flush_after'),
           current_setting('backend_flush_after'),
           current_setting('bgwriter_delay'),
           current_setting('bgwriter_lru_maxpages'),
           current_setting('bgwriter_lru_multiplier')
  "
} 2>/dev/null)" || fail 'cannot query PostgreSQL safety settings'
IFS='|' read -r server_version fsync full_page_writes synchronous_commit \
  track_io_timing track_wal_io_timing log_checkpoints checkpoint_timeout \
  checkpoint_completion_target max_wal_size wal_compression \
  checkpoint_flush_after backend_flush_after bgwriter_delay bgwriter_maxpages \
  bgwriter_multiplier <<< "${settings}"
(( server_version >= 160000 )) || fail 'PostgreSQL 16 or newer is required for this profile'
[[ "${fsync}" == 'on' ]] || fail 'fsync must remain enabled'
[[ "${full_page_writes}" == 'on' ]] || fail 'full_page_writes must remain enabled'
[[ "${synchronous_commit}" == 'on' ]] || fail 'synchronous_commit must remain enabled'
[[ "${track_io_timing}" == 'on' ]] || fail 'track_io_timing must be enabled'
[[ "${track_wal_io_timing}" == 'on' ]] || fail 'track_wal_io_timing must be enabled'
[[ "${log_checkpoints}" == 'on' ]] || fail 'log_checkpoints must be enabled'

pool_summary="$({
  psql "${database_url}" -v ON_ERROR_STOP=1 -AtF '|' \
    -v profile_id="${capacity_profile_id}" \
    -v minimum_valid_epoch="$((expected_end_epoch + lease_margin_seconds))" <<'SQL'
      SELECT COUNT(*),
             COALESCE(SUM(command_window_limit - command_window_used), 0),
             COALESCE(MIN(command_window_limit - command_window_used), 0),
             COALESCE(MIN(EXTRACT(EPOCH FROM valid_until))::bigint, 0),
             COUNT(*) FILTER (
               WHERE valid_until <= to_timestamp(:minimum_valid_epoch)
             )
      FROM im_v2.shard_admission_pools
      WHERE capacity_profile_id = :'profile_id';
SQL
} 2>/dev/null)" || fail 'cannot query shard admission pools'
IFS='|' read -r pool_count total_remaining minimum_remaining earliest_lease_epoch expired_pool_count \
  <<< "${pool_summary}"
(( pool_count > 0 )) || fail 'no shard admission pools match the capacity profile'
(( expired_pool_count == 0 )) || fail 'a shard admission lease ends before test end plus safety margin'

required_total_credits="$((
  (expected_messages * (100 + credit_headroom_percent) + 99) / 100
))"
required_per_pool="$(((required_total_credits + pool_count - 1) / pool_count))"
(( total_remaining >= required_total_credits )) \
  || fail 'total shard command credits do not cover expected messages plus headroom'
(( minimum_remaining >= required_per_pool )) \
  || fail 'one shard command pool lacks its even-share credit budget plus headroom'

storage_summary="$({
  psql "${database_url}" -v ON_ERROR_STOP=1 -AtF '|' -c "
    WITH message_storage AS (
      SELECT COUNT(*) AS message_count,
             pg_relation_size('im_v2.messages') AS heap_bytes,
             pg_indexes_size('im_v2.messages') AS index_bytes,
             pg_total_relation_size('im_v2.messages') AS total_bytes
      FROM im_v2.messages
    ), checkpoint AS (
      SELECT EXTRACT(EPOCH FROM checkpoint_time)::bigint AS checkpoint_epoch
      FROM pg_control_checkpoint()
    )
    SELECT message_count, heap_bytes, index_bytes, total_bytes,
           checkpoint_epoch, checkpoints_timed, checkpoints_req,
           buffers_checkpoint, buffers_clean, maxwritten_clean,
           buffers_backend
    FROM message_storage
    CROSS JOIN checkpoint
    CROSS JOIN pg_stat_bgwriter
  "
} 2>/dev/null)" || fail 'cannot query message/checkpoint starting state'
IFS='|' read -r message_count message_heap_bytes message_index_bytes message_total_bytes \
  checkpoint_epoch checkpoints_timed checkpoints_requested buffers_checkpoint \
  buffers_clean maxwritten_clean buffers_backend <<< "${storage_summary}"
if [[ -n "${maximum_starting_messages}" ]]; then
  (( message_count <= maximum_starting_messages )) \
    || fail 'message count exceeds IM_V2_LOAD_MAX_MESSAGES_AT_START'
fi

printf 'preflight ok credentials=%s duration_seconds=%s expected_messages=%s profile=%s\n' \
  "${credential_count}" "${duration_seconds}" "${expected_messages}" "${capacity_profile_id}"
printf 'token earliest_expiry_epoch=%s required_expiry_epoch=%s\n' \
  "$((earliest_expiry_ms / 1000))" "$((required_token_expiry_ms / 1000))"
printf 'targets checked=%s direct=%s profile=%s active_memberships=%s\n' \
  "${checked_targets}" "${checked_targets}" "${capacity_profile_id}" "${checked_targets}"
printf 'credits pools=%s total_remaining=%s minimum_remaining=%s required_total=%s required_per_pool=%s earliest_lease_epoch=%s\n' \
  "${pool_count}" "${total_remaining}" "${minimum_remaining}" \
  "${required_total_credits}" "${required_per_pool}" "${earliest_lease_epoch}"
printf 'postgres checkpoint_timeout=%s completion_target=%s max_wal_size=%s wal_compression=%s flush_after=%s/%s bgwriter=%s/%s/%s\n' \
  "${checkpoint_timeout}" "${checkpoint_completion_target}" "${max_wal_size}" "${wal_compression}" \
  "${checkpoint_flush_after}" "${backend_flush_after}" \
  "${bgwriter_delay}" "${bgwriter_maxpages}" "${bgwriter_multiplier}"
printf 'storage messages=%s heap_bytes=%s index_bytes=%s total_bytes=%s checkpoint_epoch=%s\n' \
  "${message_count}" "${message_heap_bytes}" "${message_index_bytes}" \
  "${message_total_bytes}" "${checkpoint_epoch}"
printf 'writer counters timed=%s requested=%s checkpoint=%s clean=%s capped=%s backend=%s\n' \
  "${checkpoints_timed}" "${checkpoints_requested}" "${buffers_checkpoint}" \
  "${buffers_clean}" "${maxwritten_clean}" "${buffers_backend}"
