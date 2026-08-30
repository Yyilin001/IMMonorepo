#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$#" -ne 1 ]]; then
  printf 'usage: %s <capacity-profile-id>\n' "$0" >&2
  exit 64
fi

capacity_profile_id="$1"
command_window_limit="${IM_V2_LOAD_MAX_COMMANDS_PER_WINDOW:-100000}"
expected_shards="${IM_V2_LOAD_EXPECTED_SHARDS:-8}"
lease_hours="${IM_V2_LOAD_LEASE_HOURS:-24}"
[[ "${capacity_profile_id}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || {
  printf 'capacity-profile-id contains unsupported characters or is too long\n' >&2
  exit 64
}
[[ "${command_window_limit}" =~ ^[1-9][0-9]*$ ]] || {
  printf 'IM_V2_LOAD_MAX_COMMANDS_PER_WINDOW must be a positive integer\n' >&2
  exit 64
}
[[ "${expected_shards}" =~ ^[1-9][0-9]*$ ]] && (( expected_shards <= 1024 )) || {
  printf 'IM_V2_LOAD_EXPECTED_SHARDS must be between 1 and 1024\n' >&2
  exit 64
}
[[ "${lease_hours}" =~ ^[1-9][0-9]*$ ]] && (( lease_hours <= 168 )) || {
  printf 'IM_V2_LOAD_LEASE_HOURS must be between 1 and 168\n' >&2
  exit 64
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
v2_dir="$(cd "${script_dir}/.." && pwd)"
env_file="${v2_dir}/.env.local"
compose_file="${v2_dir}/docker-compose.local-account.yml"
compose_project="${V2_LOCAL_COMPOSE_PROJECT:-imv2localaccount}"

# shellcheck source=local_compose.sh
source "${script_dir}/local_compose.sh"

# A new profile deliberately has no relationship to rooms created under an
# older profile. The first open-direct-room request for a fresh user pair binds
# that new room to one of these fenced pools. If an existing pool has expired,
# renewing its lease updates bound room fences through the schema's ON UPDATE
# CASCADE foreign key while preserving any outstanding-capacity counters.
v2_local_compose "${env_file}" \
  --project-name "${compose_project}" \
  --file "${compose_file}" \
  exec -T postgres psql \
    --quiet \
    --set=ON_ERROR_STOP=1 \
    --set=capacity_profile_id="${capacity_profile_id}" \
    --set=command_window_limit="${command_window_limit}" \
    --set=expected_shards="${expected_shards}" \
    --set=lease_hours="${lease_hours}" \
    --username im_v2 \
    --dbname im_v2 <<'SQL'
INSERT INTO im_v2.shard_admission_pools AS pool
    (room_shard_id, capacity_profile_id, lease_id, generation, valid_until,
     command_window_limit, fanout_window_limit,
     max_outstanding_fanout_units, max_outstanding_plans)
SELECT
    'rooms-load-' || lpad(shard_number::text, 2, '0'),
    :'capacity_profile_id',
    gen_random_uuid(),
    1,
    CURRENT_TIMESTAMP + make_interval(hours => :lease_hours),
    :command_window_limit,
    100000,
    1000000,
    10000
FROM generate_series(0, :expected_shards - 1) AS shard_number
ON CONFLICT (room_shard_id, capacity_profile_id) DO UPDATE
SET lease_id = CASE WHEN pool.valid_until <= CURRENT_TIMESTAMP THEN EXCLUDED.lease_id ELSE pool.lease_id END,
    generation = CASE WHEN pool.valid_until <= CURRENT_TIMESTAMP THEN pool.generation + 1 ELSE pool.generation END,
    valid_until = CASE WHEN pool.valid_until <= CURRENT_TIMESTAMP THEN EXCLUDED.valid_until ELSE pool.valid_until END,
    command_window_limit = CASE WHEN pool.valid_until <= CURRENT_TIMESTAMP THEN EXCLUDED.command_window_limit ELSE pool.command_window_limit END,
    fanout_window_limit = CASE WHEN pool.valid_until <= CURRENT_TIMESTAMP THEN EXCLUDED.fanout_window_limit ELSE pool.fanout_window_limit END,
    max_outstanding_fanout_units = CASE WHEN pool.valid_until <= CURRENT_TIMESTAMP THEN EXCLUDED.max_outstanding_fanout_units ELSE pool.max_outstanding_fanout_units END,
    max_outstanding_plans = CASE WHEN pool.valid_until <= CURRENT_TIMESTAMP THEN EXCLUDED.max_outstanding_plans ELSE pool.max_outstanding_plans END,
    command_window_used = CASE WHEN pool.valid_until <= CURRENT_TIMESTAMP THEN 0 ELSE pool.command_window_used END,
    fanout_window_used = CASE WHEN pool.valid_until <= CURRENT_TIMESTAMP THEN 0 ELSE pool.fanout_window_used END;
SQL

printf 'gateway load admission pools ready: profile=%s shards=%s command_window_limit=%s lease_hours=%s\n' \
  "${capacity_profile_id}" "${expected_shards}" "${command_window_limit}" "${lease_hours}"
