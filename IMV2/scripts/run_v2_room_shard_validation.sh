#!/usr/bin/env bash
#
# Disposable, single-host validation for the physical control/room-owner/user
# topology. It validates routing and isolation; it is not a horizontal-capacity
# benchmark because every container shares one Docker host.
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
v2_dir="$(cd "${script_dir}/.." && pwd)"
repo_root="$(cd "${v2_dir}/.." && pwd)"
env_file="${v2_dir}/.env.local"
base_compose_file="${v2_dir}/docker-compose.local-account.yml"
topology_compose_file="${v2_dir}/docker-compose.room-shard-validation.yml"
project="${V2_ROOM_SHARD_VALIDATION_PROJECT:-imv2roomshard}"
connections="${V2_ROOM_SHARD_VALIDATION_CONNECTIONS:-1000}"
messages_per_second="${V2_ROOM_SHARD_VALIDATION_MESSAGES_PER_SECOND:-600}"
hold_seconds="${V2_ROOM_SHARD_VALIDATION_HOLD_SECONDS:-60}"
credential_parallelism="${V2_ROOM_SHARD_VALIDATION_CREDENTIAL_PARALLELISM:-16}"
workload_ramp="${V2_ROOM_SHARD_VALIDATION_WORKLOAD_RAMP_PER_SECOND:-30}"

[[ "${connections}" =~ ^[1-9][0-9]*$ ]] || { echo 'invalid V2_ROOM_SHARD_VALIDATION_CONNECTIONS' >&2; exit 64; }
[[ "${messages_per_second}" =~ ^[0-9]+$ ]] || { echo 'invalid V2_ROOM_SHARD_VALIDATION_MESSAGES_PER_SECOND' >&2; exit 64; }
[[ "${hold_seconds}" =~ ^[1-9][0-9]*$ ]] || { echo 'invalid V2_ROOM_SHARD_VALIDATION_HOLD_SECONDS' >&2; exit 64; }
[[ "${credential_parallelism}" =~ ^[1-9][0-9]*$ ]] && (( credential_parallelism <= 64 )) || { echo 'invalid V2_ROOM_SHARD_VALIDATION_CREDENTIAL_PARALLELISM' >&2; exit 64; }
[[ "${workload_ramp}" =~ ^[1-9][0-9]*$ ]] || { echo 'invalid V2_ROOM_SHARD_VALIDATION_WORKLOAD_RAMP_PER_SECOND' >&2; exit 64; }

# shellcheck source=local_compose.sh
source "${script_dir}/local_compose.sh"
compose() {
  v2_local_compose "${env_file}" --project-name "${project}" \
    --file "${base_compose_file}" --file "${topology_compose_file}" "$@"
}

for command in docker jq openssl pg_dump sed uuidgen; do
  command -v "${command}" >/dev/null || { echo "missing required command: ${command}" >&2; exit 69; }
done

# Build the three local Swift binaries and bootstrap the control-plane schema.
# The base helper neither removes a volume nor alters a remote environment.
V2_LOCAL_COMPOSE_PROJECT="${project}" "${script_dir}/run_v2_local_account_stack.sh"
compose up -d --wait --force-recreate postgres-room-00 postgres-room-01 postgres-user-projection account caddy gateway

# Direct room creation requires a live, fenced admission lease on its physical
# owner. These deliberately overprovisioned values apply only to the disposable
# local topology, letting the load client pre-warm a bounded synthetic corpus.
for service_and_shard in 'postgres-room-00 rooms-00' 'postgres-room-01 rooms-01'; do
  read -r service shard <<<"${service_and_shard}"
  lease_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  compose exec -T "${service}" psql --quiet --set=ON_ERROR_STOP=1 --username im_v2 --dbname im_v2 <<SQL
INSERT INTO im_v2.shard_admission_pools
    (room_shard_id, capacity_profile_id, lease_id, generation, valid_until,
     command_window_limit, fanout_window_limit,
     max_outstanding_fanout_units, max_outstanding_plans)
VALUES
    ('${shard}', 'standard', '${lease_id}', 1, CURRENT_TIMESTAMP + INTERVAL '24 hours',
     1000000, 1000000, 1000000, 1000000)
ON CONFLICT (room_shard_id, capacity_profile_id) DO UPDATE
SET lease_id = EXCLUDED.lease_id,
    generation = im_v2.shard_admission_pools.generation + 1,
    valid_until = EXCLUDED.valid_until,
    command_window_limit = EXCLUDED.command_window_limit,
    fanout_window_limit = EXCLUDED.fanout_window_limit,
    max_outstanding_fanout_units = EXCLUDED.max_outstanding_fanout_units,
    max_outstanding_plans = EXCLUDED.max_outstanding_plans,
    command_window_used = 0,
    fanout_window_used = 0;
SQL
done

validation_dir="${V2_ROOM_SHARD_VALIDATION_OUTPUT_DIR:-$(mktemp -d /tmp/imv2-room-shard-validation.XXXXXX)}"
umask 077
mkdir -p "${validation_dir}"
chmod 700 "${validation_dir}"
ca_path="${validation_dir}/root.crt"
credentials_path="${validation_dir}/credentials.jsonl"
report_path="${validation_dir}/report-$(date -u +%Y%m%dT%H%M%SZ).json"

compose cp caddy:/data/caddy/pki/authorities/local/root.crt "${ca_path}" >/dev/null
chmod 600 "${ca_path}"
IM_V2_LOAD_CREDENTIAL_PREPARE_PARALLELISM="${credential_parallelism}" \
  "${script_dir}/prepare_v2_gateway_load_credentials.sh" \
  https://localhost:8443 "${ca_path}" "${connections}" "${credentials_path}"

# Owner databases need only the public, authorization-relevant profile
# fixture; credentials and account secrets never leave the control database.
# This is test seeding, not the production policy-replication mechanism.
for target in postgres-room-00 postgres-room-01; do
  compose exec -T postgres pg_dump --username im_v2 --dbname im_v2 --data-only --inserts \
    --table=im_v2.public_user_profiles \
    | sed -E '/^INSERT INTO im_v2\.public_user_profiles / s/;$/ ON CONFLICT (user_id) DO NOTHING;/' \
    | compose exec -T "${target}" psql --quiet --set=ON_ERROR_STOP=1 --username im_v2 --dbname im_v2
done

cd "${repo_root}"
IM_V2_LOAD_LOCAL_MAX_RSS_MB=4096 \
IM_V2_LOAD_LOCAL_MAX_CPU_PERCENT=700 \
IM_V2_LOAD_LOCAL_MAX_CPU_SAMPLES=5 \
  "${script_dir}/run_v2_gateway_load_guarded.sh" \
    --host 127.0.0.1 --port 7443 --server-name localhost \
    --ca-path "${ca_path}" --credentials "${credentials_path}" --report "${report_path}" \
    --revision "room-shard-local-${connections}c-${messages_per_second}m" \
    --connections "${connections}" --ramp-per-second 100 --ramp-batch-size 100 \
    --workload-ramp-per-second "${workload_ramp}" --hold-seconds "${hold_seconds}" --event-loops 4 \
    --messages-per-second "${messages_per_second}" --max-inflight-messages-per-connection 1 \
    --message-bytes 128 --targets-per-connection 3 --target-offset 1 \
    --sync-reads 0 --room-log-reads 1 --max-rss-mb 4096 --max-failure-percent 1

echo 'room-owner distribution (rooms-00 | rooms-01 | total):'
compose exec -T postgres psql --quiet --tuples-only --username im_v2 --dbname im_v2 -c \
  "SELECT COUNT(*) FILTER (WHERE room_shard_id = 'rooms-00'), COUNT(*) FILTER (WHERE room_shard_id = 'rooms-01'), COUNT(*) FROM im_v2.room_owner_routes"
echo 'message distribution (rooms-00 | rooms-01):'
for target in postgres-room-00 postgres-room-01; do
  compose exec -T "${target}" psql --quiet --tuples-only --username im_v2 --dbname im_v2 -c 'SELECT COUNT(*) FROM im_v2.messages' | tr -d '[:space:]'
  printf ' '
done
printf '\nreport: %s\n' "${report_path}"
