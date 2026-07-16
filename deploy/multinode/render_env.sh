#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <inventory.env> <output-dir>" >&2
  exit 2
fi

inventory="$1"
output_dir="$2"
[[ -f "${inventory}" ]] || { echo "Inventory file not found: ${inventory}" >&2; exit 1; }

# The inventory is an operator-maintained shell env file. It is intentionally
# sourced so values containing punctuation do not require a second parser.
# shellcheck source=/dev/null
source "${inventory}"

# The legacy Cell-wide endpoint map is optional when the three role-specific
# maps are present. Normalize missing optional keys before enabling validation.
IM_REALTIME_CELL_INGRESS_ENDPOINTS="${IM_REALTIME_CELL_INGRESS_ENDPOINTS:-}"
IM_CELL_INGRESS_COMMAND_ENDPOINTS="${IM_CELL_INGRESS_COMMAND_ENDPOINTS:-}"
IM_CELL_INGRESS_QUERY_ENDPOINTS="${IM_CELL_INGRESS_QUERY_ENDPOINTS:-}"
IM_CELL_INGRESS_REALTIME_ENDPOINTS="${IM_CELL_INGRESS_REALTIME_ENDPOINTS:-}"

fail() {
  printf 'multinode-render result=fail reason=%s\n' "$1" >&2
  exit 1
}

require_value() {
  local name="$1"
  [[ -n "${!name:-}" ]] || fail "missing_${name}"
}

valid_identifier() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]]
}

valid_https_url() {
  [[ "$1" =~ ^https://[^/[:space:]]+(:[0-9]+)?(/.*)?$ ]]
}

valid_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

csv_pair_has_key() {
  local pairs="$1" expected_key="$2" item key value
  local -a items=()
  IFS=',' read -r -a items <<< "${pairs}"
  for item in "${items[@]}"; do
    key="${item%%=*}"
    value="${item#*=}"
    [[ "${item}" == *=* && "${key}" == "${expected_key}" && -n "${value}" ]] && return 0
  done
  return 1
}

validate_https_pairs() {
  local name="$1" pairs="$2" item key value
  local seen=','
  local -a items=()
  IFS=',' read -r -a items <<< "${pairs}"
  (( ${#items[@]} > 0 )) || fail "missing_${name}"
  for item in "${items[@]}"; do
    key="${item%%=*}"
    value="${item#*=}"
    [[ "${item}" == *=* ]] || fail "invalid_${name}_pair"
    valid_identifier "${key}" || fail "invalid_${name}_key_${key}"
    valid_https_url "${value}" || fail "invalid_${name}_endpoint_${key}"
    [[ "${seen}" != *",${key},"* ]] || fail "duplicate_${name}_key_${key}"
    seen="${seen}${key},"
  done
}

validate_command_pairs() {
  local pairs="$1" item key value
  local seen=','
  local -a items=()
  IFS=',' read -r -a items <<< "${pairs}"
  (( ${#items[@]} > 0 )) || fail "missing_IM_COMMAND_NODE_URLS"
  for item in "${items[@]}"; do
    key="${item%%=*}"
    value="${item#*=}"
    [[ "${item}" == *=* ]] || fail "invalid_IM_COMMAND_NODE_URLS_pair"
    valid_identifier "${key}" || fail "invalid_IM_COMMAND_NODE_URLS_key_${key}"
    valid_https_url "${value}" || fail "invalid_IM_COMMAND_NODE_URLS_endpoint_${key}"
    [[ "${seen}" != *",${key},"* ]] || fail "duplicate_IM_COMMAND_NODE_URLS_key_${key}"
    seen="${seen}${key},"
  done
}

for required in \
  APP_ENV JWT_SECRETS JWT_ACTIVE_KID IM_INTERNAL_SHARED_SECRET \
  IM_NODE_DISPATCH_SHARED_SECRET IM_CELL_INGRESS_SHARED_SECRET \
  IM_NODE_SUFFIX IM_GATEWAY_NODE_ID IM_COMMAND_NODE_ID IM_REALTIME_CELL_ID \
  IM_AVAILABILITY_ZONE \
  IM_NODE_DISPATCH_MODE \
  IM_GATEWAY_NODE_DISPATCH_ENDPOINTS IM_COMMAND_NODE_URLS REDIS_URL \
  IM_REDIS_DEPLOYMENT_TOPOLOGY IM_REDIS_CLUSTER_NODES \
  IM_COMMAND_API_INTERNAL_BASE_URL IM_GATEWAY_INTERNAL_BASE_URL \
  POSTGRES_HOST POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB \
  IM_CONVERSATION_SHARD_IDS IM_SUMMARY_SHARD_IDS IM_KAFKA_BROKERS \
  IM_KAFKA_TOPIC IM_KAFKA_DEAD_LETTER_TOPIC \
  IM_KAFKA_EVENT_TOPIC_PARTITIONS IM_KAFKA_EVENT_TOPIC_REPLICATION_FACTOR \
  IM_KAFKA_EVENT_TOPIC_MIN_IN_SYNC_REPLICAS IM_KAFKA_EVENT_TOPIC_RETENTION_HOURS \
  IM_KAFKA_DEAD_LETTER_TOPIC_PARTITIONS IM_KAFKA_DEAD_LETTER_TOPIC_REPLICATION_FACTOR \
  IM_KAFKA_DEAD_LETTER_TOPIC_MIN_IN_SYNC_REPLICAS IM_KAFKA_DEAD_LETTER_TOPIC_RETENTION_HOURS \
  MEDIA_STORAGE_PROVIDER
do
  require_value "${required}"
done

[[ "${APP_ENV}" == "production" ]] || fail "APP_ENV_must_be_production"
valid_identifier "${IM_NODE_SUFFIX}" || fail "invalid_IM_NODE_SUFFIX"
valid_identifier "${IM_GATEWAY_NODE_ID}" || fail "invalid_IM_GATEWAY_NODE_ID"
valid_identifier "${IM_COMMAND_NODE_ID}" || fail "invalid_IM_COMMAND_NODE_ID"
valid_identifier "${IM_REALTIME_CELL_ID}" || fail "invalid_IM_REALTIME_CELL_ID"
valid_identifier "${IM_AVAILABILITY_ZONE}" || fail "invalid_IM_AVAILABILITY_ZONE"
[[ "${IM_NODE_DISPATCH_MODE}" == "http" ]] || fail "IM_NODE_DISPATCH_MODE_must_be_http"
[[ "${IM_REDIS_DEPLOYMENT_TOPOLOGY}" == "cluster" ]] || fail "IM_REDIS_DEPLOYMENT_TOPOLOGY_must_be_cluster"
valid_https_url "${IM_COMMAND_API_INTERNAL_BASE_URL}" || fail "invalid_IM_COMMAND_API_INTERNAL_BASE_URL"
valid_https_url "${IM_GATEWAY_INTERNAL_BASE_URL}" || fail "invalid_IM_GATEWAY_INTERNAL_BASE_URL"

if [[ -n "${IM_REALTIME_CELL_INGRESS_ENDPOINTS}" ]]; then
  validate_https_pairs "IM_REALTIME_CELL_INGRESS_ENDPOINTS" "${IM_REALTIME_CELL_INGRESS_ENDPOINTS}"
  csv_pair_has_key "${IM_REALTIME_CELL_INGRESS_ENDPOINTS}" "${IM_REALTIME_CELL_ID}" || fail "cell_ingress_missing_local_cell"
else
  for role_map in \
    IM_CELL_INGRESS_COMMAND_ENDPOINTS \
    IM_CELL_INGRESS_QUERY_ENDPOINTS \
    IM_CELL_INGRESS_REALTIME_ENDPOINTS
  do
    require_value "${role_map}"
    validate_https_pairs "${role_map}" "${!role_map}"
    csv_pair_has_key "${!role_map}" "${IM_REALTIME_CELL_ID}" || fail "${role_map}_missing_local_cell"
  done
fi

# When a legacy map is present, role-specific maps can be introduced one at a
# time. Each non-empty map is still fully validated before it takes precedence.
for role_map in \
  IM_CELL_INGRESS_COMMAND_ENDPOINTS \
  IM_CELL_INGRESS_QUERY_ENDPOINTS \
  IM_CELL_INGRESS_REALTIME_ENDPOINTS
do
  if [[ -n "${!role_map}" ]]; then
    validate_https_pairs "${role_map}" "${!role_map}"
    csv_pair_has_key "${!role_map}" "${IM_REALTIME_CELL_ID}" || fail "${role_map}_missing_local_cell"
  fi
done

validate_https_pairs "IM_GATEWAY_NODE_DISPATCH_ENDPOINTS" "${IM_GATEWAY_NODE_DISPATCH_ENDPOINTS}"
validate_command_pairs "${IM_COMMAND_NODE_URLS}"
csv_pair_has_key "${IM_GATEWAY_NODE_DISPATCH_ENDPOINTS}" "${IM_GATEWAY_NODE_ID}" || fail "node_dispatch_missing_local_gateway"
csv_pair_has_key "${IM_COMMAND_NODE_URLS}" "${IM_COMMAND_NODE_ID}" || fail "command_routing_missing_local_command_node"

IFS=',' read -r -a redis_nodes <<< "${IM_REDIS_CLUSTER_NODES}"
(( ${#redis_nodes[@]} >= 3 )) || fail "IM_REDIS_CLUSTER_NODES_requires_at_least_three_seeds"
for node in "${redis_nodes[@]}"; do
  [[ "${node}" =~ ^[^,:[:space:]]+:[0-9]+$ ]] || fail "invalid_IM_REDIS_CLUSTER_NODES_entry_${node}"
done
IFS=',' read -r -a kafka_brokers <<< "${IM_KAFKA_BROKERS}"
(( ${#kafka_brokers[@]} >= 3 )) || fail "IM_KAFKA_BROKERS_requires_at_least_three_brokers"
[[ "${IM_KAFKA_TOPIC}" != "${IM_KAFKA_DEAD_LETTER_TOPIC}" ]] || fail "IM_KAFKA_TOPIC_must_differ_from_dead_letter_topic"
for topic_capacity_key in \
  IM_KAFKA_EVENT_TOPIC_PARTITIONS IM_KAFKA_EVENT_TOPIC_REPLICATION_FACTOR \
  IM_KAFKA_EVENT_TOPIC_MIN_IN_SYNC_REPLICAS IM_KAFKA_EVENT_TOPIC_RETENTION_HOURS \
  IM_KAFKA_DEAD_LETTER_TOPIC_PARTITIONS IM_KAFKA_DEAD_LETTER_TOPIC_REPLICATION_FACTOR \
  IM_KAFKA_DEAD_LETTER_TOPIC_MIN_IN_SYNC_REPLICAS IM_KAFKA_DEAD_LETTER_TOPIC_RETENTION_HOURS
do
  valid_positive_integer "${!topic_capacity_key}" || fail "invalid_${topic_capacity_key}"
done
(( IM_KAFKA_EVENT_TOPIC_MIN_IN_SYNC_REPLICAS <= IM_KAFKA_EVENT_TOPIC_REPLICATION_FACTOR )) || fail "IM_KAFKA_EVENT_TOPIC_MIN_IN_SYNC_REPLICAS_exceeds_replication_factor"
(( IM_KAFKA_DEAD_LETTER_TOPIC_MIN_IN_SYNC_REPLICAS <= IM_KAFKA_DEAD_LETTER_TOPIC_REPLICATION_FACTOR )) || fail "IM_KAFKA_DEAD_LETTER_TOPIC_MIN_IN_SYNC_REPLICAS_exceeds_replication_factor"

rm -rf "${output_dir}"
mkdir -p "${output_dir}/roles" "${output_dir}/preflight"

# Keep the inventory's explicitly declared settings as the shared service env.
# Comments and malformed lines are intentionally omitted from generated files.
awk '/^[A-Za-z_][A-Za-z0-9_]*=/' "${inventory}" > "${output_dir}/common.env"

cat >> "${output_dir}/common.env" <<EOF
DATABASE_HOST=${POSTGRES_HOST}
DATABASE_PORT=${POSTGRES_PORT:-5432}
DATABASE_USERNAME=${POSTGRES_USER}
DATABASE_PASSWORD=${POSTGRES_PASSWORD}
DATABASE_NAME=${POSTGRES_DB}
DATABASE_PRIMARY_HOST=${POSTGRES_HOST}
DATABASE_PRIMARY_PORT=${POSTGRES_PORT:-5432}
DATABASE_PRIMARY_USERNAME=${POSTGRES_USER}
DATABASE_PRIMARY_PASSWORD=${POSTGRES_PASSWORD}
DATABASE_PRIMARY_NAME=${POSTGRES_DB}
DATABASE_REPLICA_HOST=${POSTGRES_REPLICA_HOST:-${POSTGRES_HOST}}
DATABASE_REPLICA_PORT=${POSTGRES_PORT:-5432}
DATABASE_REPLICA_USERNAME=${POSTGRES_USER}
DATABASE_REPLICA_PASSWORD=${POSTGRES_PASSWORD}
DATABASE_REPLICA_NAME=${POSTGRES_DB}
EOF

append_shard_connection_settings() {
  local kind="$1" ids="$2" shard normalized host_var name_var
  IFS=',' read -r -a shards <<< "${ids}"
  for shard in "${shards[@]}"; do
    normalized="$(echo "${shard}" | tr '[:lower:]-' '[:upper:]_')"
    host_var="DATABASE_${kind}_${normalized}_HOST"
    name_var="DATABASE_${kind}_${normalized}_NAME"
    require_value "${host_var}"
    require_value "${name_var}"
    {
      echo "DATABASE_${kind}_${normalized}_PORT=${POSTGRES_PORT:-5432}"
      echo "DATABASE_${kind}_${normalized}_USERNAME=${POSTGRES_USER}"
      echo "DATABASE_${kind}_${normalized}_PASSWORD=${POSTGRES_PASSWORD}"
    } >> "${output_dir}/common.env"
  done
}

append_shard_connection_settings CONVERSATION "${IM_CONVERSATION_SHARD_IDS}"
append_shard_connection_settings SUMMARY "${IM_SUMMARY_SHARD_IDS}"

write_role() {
  local name="$1"
  shift
  local role_file="${output_dir}/roles/${name}.env"
  printf '%s\n' "$@" > "${role_file}"
  awk -F= '
    /^[A-Za-z_][A-Za-z0-9_]*=/ {
      key=$1
      if (!(key in seen)) order[++count]=key
      seen[key]=$0
    }
    END {
      for (position=1; position<=count; position++) print seen[order[position]]
    }
  ' "${output_dir}/common.env" "${role_file}" > "${output_dir}/preflight/${name}.env"
}

write_role gateway \
  "IM_NODE_ID=${IM_GATEWAY_NODE_ID}" \
  "IM_COMMAND_API_INTERNAL_BASE_URL=${IM_COMMAND_API_INTERNAL_BASE_URL}" \
  "IM_GATEWAY_RELAY_MODE=local"

write_role command-api \
  "IM_NODE_ID=command-api-${IM_NODE_SUFFIX}" \
  "IM_COMMAND_NODE_ID=${IM_COMMAND_NODE_ID}" \
  "IM_GATEWAY_RELAY_MODE=http" \
  "IM_GATEWAY_INTERNAL_BASE_URL=${IM_GATEWAY_INTERNAL_BASE_URL}" \
  "IM_KAFKA_CLIENT_ID=im-command-api-${IM_NODE_SUFFIX}"

write_role query-api "IM_NODE_ID=query-api-${IM_NODE_SUFFIX}"

write_role outbox-relay \
  "IM_NODE_ID=outbox-relay-${IM_NODE_SUFFIX}" \
  "IM_KAFKA_CLIENT_ID=im-outbox-relay-${IM_NODE_SUFFIX}" \
  "IM_OUTBOX_BATCH_SIZE=${IM_OUTBOX_BATCH_SIZE:-500}" \
  "IM_OUTBOX_POLL_INTERVAL_MS=${IM_OUTBOX_POLL_INTERVAL_MS:-200}" \
  "IM_OUTBOX_MAX_RETRIES=${IM_OUTBOX_MAX_RETRIES:-10}" \
  "IM_OUTBOX_CLAIM_TIMEOUT_MS=${IM_OUTBOX_CLAIM_TIMEOUT_MS:-60000}"

write_role ops \
  "IM_NODE_ID=ops-${IM_NODE_SUFFIX}" \
  "IM_KAFKA_CLIENT_ID=im-ops-${IM_NODE_SUFFIX}"

for group in \
  summary-projection-consumer \
  realtime-delivery-consumer \
  domain-delivery-consumer \
  changes-log-consumer \
  search-index-consumer \
  notification-consumer \
  repair-replay-consumer
do
  file_group="$(echo "${group}" | tr '-' '_')"
  role_lines=(
    "IM_NODE_ID=stream-consumer-${group}-${IM_NODE_SUFFIX}"
    "IM_KAFKA_CLIENT_ID=im-stream-consumer-${group}-${IM_NODE_SUFFIX}"
    "IM_STREAM_CONSUMER_GROUPS=${group}"
  )
  if [[ "${group}" == "realtime-delivery-consumer" || "${group}" == "domain-delivery-consumer" ]]; then
    role_lines+=(
      "IM_GATEWAY_RELAY_MODE=http"
      "IM_GATEWAY_INTERNAL_BASE_URL=${IM_GATEWAY_INTERNAL_BASE_URL}"
    )
  fi
  write_role "stream-consumer-${file_group}" "${role_lines[@]}"
done

chmod 0640 "${output_dir}/common.env" "${output_dir}"/roles/*.env "${output_dir}"/preflight/*.env
printf 'multinode-render result=pass output=%s roles=%s\n' "${output_dir}" "$(find "${output_dir}/roles" -name '*.env' | wc -l | tr -d ' ')"
