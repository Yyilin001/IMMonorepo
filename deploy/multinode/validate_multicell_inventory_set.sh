#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RENDER="${ROOT_DIR}/deploy/multinode/render_env.sh"
VALIDATE_CELL="${ROOT_DIR}/deploy/multinode/validate_inventory_set.sh"
TMP_DIR="$(mktemp -d)"

trap 'rm -rf "${TMP_DIR}"' EXIT

usage() {
  cat <<'USAGE'
Usage: validate_multicell_inventory_set.sh [--require-ha] <inventory.env> [inventory.env ...]

Validates a complete multi-Cell inventory set. Every Cell is validated as an
independent node set, then the shared control plane, Cell ingress maps, and
physical conversation-shard database boundaries are checked across Cells.
`--require-ha` additionally requires at least two node inventories in every
Cell. Use it for production rollout gates; omit it only for staged topology
development.
USAGE
}

fail() {
  printf 'multicell-inventory-set result=fail reason=%s\n' "$1" >&2
  exit 1
}

value_from_metadata() {
  local metadata="$1" key="$2"
  sed -n "s/^${key}=//p" "${metadata}" | head -n 1
}

sorted_pair_keys() {
  local pairs="$1"
  printf '%s' "${pairs}" | tr ',' '\n' | sed 's/=.*//' | LC_ALL=C sort -u
}

contains_cell() {
  local cell="$1" existing
  for existing in "${cells[@]:-}"; do
    [[ "${existing}" == "${cell}" ]] && return 0
  done
  return 1
}

require_ha=false
if [[ "${1:-}" == "--require-ha" ]]; then
  require_ha=true
  shift
fi
[[ $# -ge 2 ]] || { usage >&2; exit 2; }
for inventory in "$@"; do
  [[ -f "${inventory}" ]] || fail "inventory_missing_${inventory}"
done

cells=()
metadata_files=()
inventory_files=()
seen_availability_zones=""
index=0
for inventory in "$@"; do
  index=$((index + 1))
  "${RENDER}" "${inventory}" "${TMP_DIR}/rendered-${index}" >/dev/null

  metadata="${TMP_DIR}/inventory-${index}.metadata"
  (
    # Inventories are operator-maintained shell env files, as documented by
    # render_env.sh. Rendering above has already checked their required shape.
    # shellcheck source=/dev/null
    source "${inventory}"
    for key in \
      IM_REALTIME_CELL_ID \
      IM_REALTIME_CELL_INGRESS_ENDPOINTS \
      IM_CELL_INGRESS_COMMAND_ENDPOINTS \
      IM_CELL_INGRESS_QUERY_ENDPOINTS \
      IM_CELL_INGRESS_REALTIME_ENDPOINTS \
      IM_INTERNAL_SHARED_SECRET \
      IM_CELL_INGRESS_SHARED_SECRET \
      IM_COMMAND_INTERNAL_SHARED_SECRET \
      IM_AVAILABILITY_ZONE \
      POSTGRES_HOST POSTGRES_PORT POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB \
      IM_KAFKA_BROKERS IM_KAFKA_TOPIC IM_KAFKA_DEAD_LETTER_TOPIC \
      IM_KAFKA_EVENT_TOPIC_PARTITIONS IM_KAFKA_EVENT_TOPIC_REPLICATION_FACTOR \
      IM_KAFKA_EVENT_TOPIC_MIN_IN_SYNC_REPLICAS IM_KAFKA_EVENT_TOPIC_RETENTION_HOURS \
      IM_KAFKA_DEAD_LETTER_TOPIC_PARTITIONS IM_KAFKA_DEAD_LETTER_TOPIC_REPLICATION_FACTOR \
      IM_KAFKA_DEAD_LETTER_TOPIC_MIN_IN_SYNC_REPLICAS IM_KAFKA_DEAD_LETTER_TOPIC_RETENTION_HOURS \
      IM_CONVERSATION_SHARD_IDS
    do
      printf '%s=%s\n' "${key}" "${!key:-}"
    done
  ) > "${metadata}"
  metadata_files+=("${metadata}")
  inventory_files+=("${inventory}")

  cell="$(value_from_metadata "${metadata}" IM_REALTIME_CELL_ID)"
  [[ -n "${cell}" ]] || fail "missing_IM_REALTIME_CELL_ID"
  if ! contains_cell "${cell}"; then
    cells+=("${cell}")
  fi
  availability_zone="$(value_from_metadata "${metadata}" IM_AVAILABILITY_ZONE)"
  case ",${seen_availability_zones}," in
    *,"${availability_zone}",*) ;;
    *) seen_availability_zones="${seen_availability_zones:+${seen_availability_zones},}${availability_zone}" ;;
  esac
  printf '%s\n' "${inventory}" >> "${TMP_DIR}/cell-${cell}.inventories"
done

(( ${#cells[@]} >= 2 )) || fail "requires_at_least_two_cells"
IFS=',' read -r -a availability_zones <<< "${seen_availability_zones}"
(( ${#availability_zones[@]} >= 2 )) || fail "cells_must_span_at_least_two_availability_zones"

# Existing validation owns same-Cell node identities and endpoint counts.
for cell in "${cells[@]}"; do
  args=()
  while IFS= read -r inventory; do
    [[ -n "${inventory}" ]] && args+=("${inventory}")
  done < "${TMP_DIR}/cell-${cell}.inventories"
  if [[ "${require_ha}" == true && ${#args[@]} -lt 2 ]]; then
    fail "cell_requires_at_least_two_node_inventories_${cell}"
  fi
  "${VALIDATE_CELL}" "${args[@]}" >/dev/null
done

reference="${metadata_files[0]}"
for key in \
  IM_REALTIME_CELL_INGRESS_ENDPOINTS \
  IM_CELL_INGRESS_COMMAND_ENDPOINTS \
  IM_CELL_INGRESS_QUERY_ENDPOINTS \
  IM_CELL_INGRESS_REALTIME_ENDPOINTS \
  IM_INTERNAL_SHARED_SECRET \
  IM_CELL_INGRESS_SHARED_SECRET \
  IM_COMMAND_INTERNAL_SHARED_SECRET \
  POSTGRES_HOST POSTGRES_PORT POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB \
  IM_KAFKA_BROKERS IM_KAFKA_TOPIC IM_KAFKA_DEAD_LETTER_TOPIC \
  IM_KAFKA_EVENT_TOPIC_PARTITIONS IM_KAFKA_EVENT_TOPIC_REPLICATION_FACTOR \
  IM_KAFKA_EVENT_TOPIC_MIN_IN_SYNC_REPLICAS IM_KAFKA_EVENT_TOPIC_RETENTION_HOURS \
  IM_KAFKA_DEAD_LETTER_TOPIC_PARTITIONS IM_KAFKA_DEAD_LETTER_TOPIC_REPLICATION_FACTOR \
  IM_KAFKA_DEAD_LETTER_TOPIC_MIN_IN_SYNC_REPLICAS IM_KAFKA_DEAD_LETTER_TOPIC_RETENTION_HOURS
do
  expected="$(value_from_metadata "${reference}" "${key}")"
  for metadata in "${metadata_files[@]:1}"; do
    actual="$(value_from_metadata "${metadata}" "${key}")"
    [[ "${actual}" == "${expected}" ]] || fail "shared_value_mismatch_${key}"
  done
done

expected_cells="$(printf '%s\n' "${cells[@]}" | LC_ALL=C sort -u)"
for key in \
  IM_CELL_INGRESS_COMMAND_ENDPOINTS \
  IM_CELL_INGRESS_QUERY_ENDPOINTS \
  IM_CELL_INGRESS_REALTIME_ENDPOINTS
do
  map="$(value_from_metadata "${reference}" "${key}")"
  [[ "$(sorted_pair_keys "${map}")" == "${expected_cells}" ]] || fail "${key}_keys_must_match_inventory_cells"
done

# A Cell may have multiple nodes pointing at its own shard database. A physical
# conversation shard may not be shared by two different Cells: that would make
# a Cell migration a route-only change instead of a data-boundary move.
for metadata_index in "${!metadata_files[@]}"; do
  metadata="${metadata_files[metadata_index]}"
  cell="$(value_from_metadata "${metadata}" IM_REALTIME_CELL_ID)"
  inventory="${inventory_files[metadata_index]}"
  (
    # shellcheck source=/dev/null
    source "${inventory}"
    IFS=',' read -r -a shard_ids <<< "${IM_CONVERSATION_SHARD_IDS}"
    for shard_id in "${shard_ids[@]}"; do
      normalized="$(printf '%s' "${shard_id}" | tr '[:lower:]-' '[:upper:]_')"
      host_var="DATABASE_CONVERSATION_${normalized}_HOST"
      name_var="DATABASE_CONVERSATION_${normalized}_NAME"
      host="${!host_var}"
      name="${!name_var}"
      port="${POSTGRES_PORT:-5432}"
      printf '%s|%s:%s/%s\n' "${cell}" "${host}" "${port}" "${name}"
    done
  ) >> "${TMP_DIR}/conversation-shards"
done

while IFS='|' read -r cell triplet; do
  [[ -n "${cell}" && -n "${triplet}" ]] || continue
  previous_cell="$(awk -F'|' -v expected_triplet="${triplet}" '$1 == expected_triplet { print $2; exit }' "${TMP_DIR}/seen-conversation-shards" 2>/dev/null || true)"
  if [[ -n "${previous_cell}" && "${previous_cell}" != "${cell}" ]]; then
    fail "conversation_shard_database_reused_across_cells"
  fi
  printf '%s|%s\n' "${triplet}" "${cell}" >> "${TMP_DIR}/seen-conversation-shards"
done < "${TMP_DIR}/conversation-shards"

printf 'multicell-inventory-set result=pass cells=%s inventories=%s availability_zones=%s ha_required=%s\n' \
  "${#cells[@]}" "$#" "${#availability_zones[@]}" "${require_ha}"
