#!/usr/bin/env bash

# The production control plane owns admission leases.  The disposable local
# stack has no such control-plane service, but real room creation deliberately
# refuses to proceed without a live fenced pool.  This helper renews only the
# single local profile after schema bootstrap: a live fence is preserved; an expired
# one receives a fresh lease ID and generation with the same semantics as the
# tested replacement operation.  It is local test functionality, not a
# capacity approval or a production lease-management mechanism.
v2_local_admission_pool_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

v2_seed_local_admission_pool() {
  local admission_v2_dir
  local admission_env_file
  local admission_compose_file
  local admission_compose_project
  local replacement_lease_id

  admission_v2_dir="$(cd "${v2_local_admission_pool_script_dir}/.." && pwd)"
  admission_env_file="${admission_v2_dir}/.env.local"
  admission_compose_file="${admission_v2_dir}/docker-compose.local-account.yml"
  admission_compose_project="${V2_LOCAL_COMPOSE_PROJECT:-imv2localaccount}"
  replacement_lease_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"

  # shellcheck source=local_compose.sh
  source "${v2_local_admission_pool_script_dir}/local_compose.sh"
  v2_local_compose "${admission_env_file}" --project-name "${admission_compose_project}" --file "${admission_compose_file}" \
    exec -T postgres psql --quiet --set=ON_ERROR_STOP=1 --username im_v2 --dbname im_v2 <<SQL
INSERT INTO im_v2.shard_admission_pools AS pool
    (room_shard_id, capacity_profile_id, lease_id, generation, valid_until,
     command_window_limit, fanout_window_limit,
     max_outstanding_fanout_units, max_outstanding_plans)
VALUES
    ('rooms-primary', 'standard', '${replacement_lease_id}', 1, CURRENT_TIMESTAMP + INTERVAL '24 hours',
     1000, 100000, 1000000, 10000)
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
}
