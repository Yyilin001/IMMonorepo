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
  local -a compose_arguments=(--file "${admission_compose_file}")
  local -a shards=(rooms-primary)
  local shard target
  if [[ "${V2_LOCAL_ACTOR_CLUSTER:-0}" == 1 ]]; then
    shards+=(rooms-01)
  else
    compose_arguments+=(--file "${admission_v2_dir}/docker-compose.local-account-core.yml")
    v2_local_compose "${admission_env_file}" --project-name "${admission_compose_project}" "${compose_arguments[@]}" \
      exec -T postgres psql --quiet --set=ON_ERROR_STOP=1 --username im_v2 --dbname im_v2 <<'SQL'
INSERT INTO im_v2.user_shard_router_configuration
  (configuration_key, router_epoch, default_write_bucket, updated_at)
VALUES (TRUE, 1, 'users-primary', CURRENT_TIMESTAMP)
ON CONFLICT (configuration_key) DO NOTHING;
SQL
  fi
  for shard in "${shards[@]}"; do
    target=im_v2
    if [[ "${V2_LOCAL_ACTOR_CLUSTER:-0}" == 1 ]]; then target="imv2_${shard/-/_}"; fi
    v2_local_compose "${admission_env_file}" --project-name "${admission_compose_project}" "${compose_arguments[@]}" \
    exec -T postgres psql --quiet --set=ON_ERROR_STOP=1 --username im_v2 --dbname "${target}" <<SQL
INSERT INTO im_v2.shard_admission_pools AS pool
    (room_shard_id, capacity_profile_id, lease_id, generation, valid_until, command_window_limit)
VALUES
    ('${shard}', 'standard', '${replacement_lease_id}', 1, CURRENT_TIMESTAMP + INTERVAL '24 hours', 1000)
ON CONFLICT (room_shard_id, capacity_profile_id) DO UPDATE
SET lease_id = CASE WHEN pool.valid_until <= CURRENT_TIMESTAMP THEN EXCLUDED.lease_id ELSE pool.lease_id END,
    generation = CASE WHEN pool.valid_until <= CURRENT_TIMESTAMP THEN pool.generation + 1 ELSE pool.generation END,
    valid_until = CASE WHEN pool.valid_until <= CURRENT_TIMESTAMP THEN EXCLUDED.valid_until ELSE pool.valid_until END,
    command_window_limit = CASE WHEN pool.valid_until <= CURRENT_TIMESTAMP THEN EXCLUDED.command_window_limit ELSE pool.command_window_limit END,
    command_window_used = CASE WHEN pool.valid_until <= CURRENT_TIMESTAMP THEN 0 ELSE pool.command_window_used END;
SQL
  done
}
