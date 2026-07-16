#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RENDER="${ROOT_DIR}/deploy/multinode/render_env.sh"
TMP_DIR="$(mktemp -d)"

trap 'rm -rf "${TMP_DIR}"' EXIT

usage() {
  cat <<'USAGE'
Usage: validate_inventory_set.sh <inventory-node-a.env> <inventory-node-b.env> [...]

Validates one complete realtime Cell inventory set before deploying its rendered
role environment files. Every supplied inventory represents one Gateway and one
command routing slot in the Cell.
USAGE
}

fail() {
  printf 'multinode-inventory-set result=fail reason=%s\n' "$1" >&2
  exit 1
}

[[ $# -ge 1 ]] || { usage >&2; exit 2; }

for inventory in "$@"; do
  [[ -f "${inventory}" ]] || fail "inventory_missing_${inventory}"
done

pair_value_count() {
  local pairs="$1" item count=0
  local -a items=()
  IFS=',' read -r -a items <<< "${pairs}"
  for item in "${items[@]}"; do
    [[ "${item}" == *=* && -n "${item%%=*}" && -n "${item#*=}" ]] && count=$((count + 1))
  done
  printf '%s' "${count}"
}

pair_has_key() {
  local pairs="$1" expected="$2" item key
  local -a items=()
  IFS=',' read -r -a items <<< "${pairs}"
  for item in "${items[@]}"; do
    key="${item%%=*}"
    [[ "${item}" == *=* && "${key}" == "${expected}" ]] && return 0
  done
  return 1
}

require_shared_value() {
  local name="$1" value="$2" expected="$3"
  [[ "${value}" == "${expected}" ]] || fail "shared_value_mismatch_${name}"
}

require_unique_value() {
  local label="$1" value="$2" seen_csv="$3"
  case ",${seen_csv}," in
    *,"${value}",*) fail "duplicate_${label}_${value}" ;;
  esac
}

expected_cell_id=""
expected_cell_endpoints=""
expected_cell_command_endpoints=""
expected_cell_query_endpoints=""
expected_cell_realtime_endpoints=""
expected_gateway_endpoints=""
expected_command_endpoints=""
expected_redis_topology=""
expected_redis_seeds=""
expected_redis_url=""
expected_kafka_brokers=""
expected_kafka_topic_spec=""
expected_node_dispatch_mode=""
expected_internal_secret=""
expected_node_dispatch_secret=""
expected_cell_ingress_secret=""
expected_command_secret=""
seen_suffixes=""
seen_gateways=""
seen_commands=""
seen_availability_zones=""
render_index=0

for inventory in "$@"; do
  render_index=$((render_index + 1))
  "${RENDER}" "${inventory}" "${TMP_DIR}/rendered-${render_index}" >/dev/null

  # Inventories are operator-maintained shell env files and have already been
  # syntactically and semantically checked by render_env.sh above.
  # shellcheck source=/dev/null
  source "${inventory}"
  IM_REALTIME_CELL_INGRESS_ENDPOINTS="${IM_REALTIME_CELL_INGRESS_ENDPOINTS:-}"
  IM_CELL_INGRESS_COMMAND_ENDPOINTS="${IM_CELL_INGRESS_COMMAND_ENDPOINTS:-}"
  IM_CELL_INGRESS_QUERY_ENDPOINTS="${IM_CELL_INGRESS_QUERY_ENDPOINTS:-}"
  IM_CELL_INGRESS_REALTIME_ENDPOINTS="${IM_CELL_INGRESS_REALTIME_ENDPOINTS:-}"

  if [[ -z "${expected_cell_id}" ]]; then
    expected_cell_id="${IM_REALTIME_CELL_ID}"
    expected_cell_endpoints="${IM_REALTIME_CELL_INGRESS_ENDPOINTS}"
    expected_cell_command_endpoints="${IM_CELL_INGRESS_COMMAND_ENDPOINTS}"
    expected_cell_query_endpoints="${IM_CELL_INGRESS_QUERY_ENDPOINTS}"
    expected_cell_realtime_endpoints="${IM_CELL_INGRESS_REALTIME_ENDPOINTS}"
    expected_gateway_endpoints="${IM_GATEWAY_NODE_DISPATCH_ENDPOINTS}"
    expected_command_endpoints="${IM_COMMAND_NODE_URLS}"
    expected_redis_topology="${IM_REDIS_DEPLOYMENT_TOPOLOGY}"
    expected_redis_seeds="${IM_REDIS_CLUSTER_NODES}"
    expected_redis_url="${REDIS_URL}"
    expected_kafka_brokers="${IM_KAFKA_BROKERS}"
    expected_kafka_topic_spec="${IM_KAFKA_TOPIC}|${IM_KAFKA_DEAD_LETTER_TOPIC}|${IM_KAFKA_EVENT_TOPIC_PARTITIONS}|${IM_KAFKA_EVENT_TOPIC_REPLICATION_FACTOR}|${IM_KAFKA_EVENT_TOPIC_MIN_IN_SYNC_REPLICAS}|${IM_KAFKA_EVENT_TOPIC_RETENTION_HOURS}|${IM_KAFKA_DEAD_LETTER_TOPIC_PARTITIONS}|${IM_KAFKA_DEAD_LETTER_TOPIC_REPLICATION_FACTOR}|${IM_KAFKA_DEAD_LETTER_TOPIC_MIN_IN_SYNC_REPLICAS}|${IM_KAFKA_DEAD_LETTER_TOPIC_RETENTION_HOURS}"
    expected_node_dispatch_mode="${IM_NODE_DISPATCH_MODE}"
    expected_internal_secret="${IM_INTERNAL_SHARED_SECRET}"
    expected_node_dispatch_secret="${IM_NODE_DISPATCH_SHARED_SECRET}"
    expected_cell_ingress_secret="${IM_CELL_INGRESS_SHARED_SECRET}"
    expected_command_secret="${IM_COMMAND_INTERNAL_SHARED_SECRET}"
  else
    require_shared_value IM_REALTIME_CELL_ID "${IM_REALTIME_CELL_ID}" "${expected_cell_id}"
    require_shared_value IM_REALTIME_CELL_INGRESS_ENDPOINTS "${IM_REALTIME_CELL_INGRESS_ENDPOINTS}" "${expected_cell_endpoints}"
    require_shared_value IM_CELL_INGRESS_COMMAND_ENDPOINTS "${IM_CELL_INGRESS_COMMAND_ENDPOINTS}" "${expected_cell_command_endpoints}"
    require_shared_value IM_CELL_INGRESS_QUERY_ENDPOINTS "${IM_CELL_INGRESS_QUERY_ENDPOINTS}" "${expected_cell_query_endpoints}"
    require_shared_value IM_CELL_INGRESS_REALTIME_ENDPOINTS "${IM_CELL_INGRESS_REALTIME_ENDPOINTS}" "${expected_cell_realtime_endpoints}"
    require_shared_value IM_GATEWAY_NODE_DISPATCH_ENDPOINTS "${IM_GATEWAY_NODE_DISPATCH_ENDPOINTS}" "${expected_gateway_endpoints}"
    require_shared_value IM_COMMAND_NODE_URLS "${IM_COMMAND_NODE_URLS}" "${expected_command_endpoints}"
    require_shared_value IM_REDIS_DEPLOYMENT_TOPOLOGY "${IM_REDIS_DEPLOYMENT_TOPOLOGY}" "${expected_redis_topology}"
    require_shared_value IM_REDIS_CLUSTER_NODES "${IM_REDIS_CLUSTER_NODES}" "${expected_redis_seeds}"
    require_shared_value REDIS_URL "${REDIS_URL}" "${expected_redis_url}"
    require_shared_value IM_KAFKA_BROKERS "${IM_KAFKA_BROKERS}" "${expected_kafka_brokers}"
    require_shared_value IM_KAFKA_TOPIC_SPEC "${IM_KAFKA_TOPIC}|${IM_KAFKA_DEAD_LETTER_TOPIC}|${IM_KAFKA_EVENT_TOPIC_PARTITIONS}|${IM_KAFKA_EVENT_TOPIC_REPLICATION_FACTOR}|${IM_KAFKA_EVENT_TOPIC_MIN_IN_SYNC_REPLICAS}|${IM_KAFKA_EVENT_TOPIC_RETENTION_HOURS}|${IM_KAFKA_DEAD_LETTER_TOPIC_PARTITIONS}|${IM_KAFKA_DEAD_LETTER_TOPIC_REPLICATION_FACTOR}|${IM_KAFKA_DEAD_LETTER_TOPIC_MIN_IN_SYNC_REPLICAS}|${IM_KAFKA_DEAD_LETTER_TOPIC_RETENTION_HOURS}" "${expected_kafka_topic_spec}"
    require_shared_value IM_NODE_DISPATCH_MODE "${IM_NODE_DISPATCH_MODE}" "${expected_node_dispatch_mode}"
    require_shared_value IM_INTERNAL_SHARED_SECRET "${IM_INTERNAL_SHARED_SECRET}" "${expected_internal_secret}"
    require_shared_value IM_NODE_DISPATCH_SHARED_SECRET "${IM_NODE_DISPATCH_SHARED_SECRET}" "${expected_node_dispatch_secret}"
    require_shared_value IM_CELL_INGRESS_SHARED_SECRET "${IM_CELL_INGRESS_SHARED_SECRET}" "${expected_cell_ingress_secret}"
    require_shared_value IM_COMMAND_INTERNAL_SHARED_SECRET "${IM_COMMAND_INTERNAL_SHARED_SECRET}" "${expected_command_secret}"
  fi

  require_unique_value node_suffix "${IM_NODE_SUFFIX}" "${seen_suffixes}"
  require_unique_value gateway_node_id "${IM_GATEWAY_NODE_ID}" "${seen_gateways}"
  require_unique_value command_node_id "${IM_COMMAND_NODE_ID}" "${seen_commands}"
  seen_suffixes="${seen_suffixes:+${seen_suffixes},}${IM_NODE_SUFFIX}"
  seen_gateways="${seen_gateways:+${seen_gateways},}${IM_GATEWAY_NODE_ID}"
  seen_commands="${seen_commands:+${seen_commands},}${IM_COMMAND_NODE_ID}"
  case ",${seen_availability_zones}," in
    *,"${IM_AVAILABILITY_ZONE}",*) ;;
    *) seen_availability_zones="${seen_availability_zones:+${seen_availability_zones},}${IM_AVAILABILITY_ZONE}" ;;
  esac
done

inventory_count="$#"
[[ "$(pair_value_count "${expected_gateway_endpoints}")" == "${inventory_count}" ]] || fail "gateway_endpoint_count_must_match_inventory_count"
[[ "$(pair_value_count "${expected_command_endpoints}")" == "${inventory_count}" ]] || fail "command_endpoint_count_must_match_inventory_count"
if (( inventory_count >= 2 )); then
  IFS=',' read -r -a availability_zones <<< "${seen_availability_zones}"
  (( ${#availability_zones[@]} >= 2 )) || fail "gateway_and_command_replicas_must_span_at_least_two_availability_zones"
fi

IFS=',' read -r -a gateway_ids <<< "${seen_gateways}"
for gateway_id in "${gateway_ids[@]}"; do
  pair_has_key "${expected_gateway_endpoints}" "${gateway_id}" || fail "gateway_endpoint_missing_${gateway_id}"
done
IFS=',' read -r -a command_ids <<< "${seen_commands}"
for command_id in "${command_ids[@]}"; do
  pair_has_key "${expected_command_endpoints}" "${command_id}" || fail "command_endpoint_missing_${command_id}"
done

printf 'multinode-inventory-set result=pass cell=%s inventories=%s gateway_nodes=%s command_nodes=%s availability_zones=%s\n' \
  "${expected_cell_id}" "${inventory_count}" \
  "$(pair_value_count "${expected_gateway_endpoints}")" \
  "$(pair_value_count "${expected_command_endpoints}")" \
  "$(wc -w <<<"${seen_availability_zones//,/ }" | tr -d ' ')"
