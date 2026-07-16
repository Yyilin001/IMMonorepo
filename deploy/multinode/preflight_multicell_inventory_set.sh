#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RENDER="${ROOT_DIR}/deploy/multinode/render_env.sh"
VALIDATE_MULTICELL="${ROOT_DIR}/deploy/multinode/validate_multicell_inventory_set.sh"
PREFLIGHT="${ROOT_DIR}/IMServer/scripts/production_env_preflight.sh"
TMP_DIR="$(mktemp -d)"

trap 'rm -rf "${TMP_DIR}"' EXIT

usage() {
  cat <<'USAGE'
Usage: preflight_multicell_inventory_set.sh [--allow-placeholders] [--require-ha] <inventory.env> [inventory.env ...]

Validates a complete multi-Cell topology, then runs the production environment
preflight for every rendered role set in every supplied Cell inventory.
Strict secret validation is enabled unless --allow-placeholders is explicitly
provided for template development only. --require-ha requires two or more
nodes in every Cell and should be used for production rollout.
USAGE
}

allow_placeholders=false
require_ha=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-placeholders)
      allow_placeholders=true
      shift
      ;;
    --require-ha)
      require_ha=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      usage >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

[[ $# -ge 2 ]] || { usage >&2; exit 2; }

if [[ "${require_ha}" == true ]]; then
  "${VALIDATE_MULTICELL}" --require-ha "$@"
else
  "${VALIDATE_MULTICELL}" "$@"
fi

run_role_preflight() {
  local output_dir="$1"
  local args=(
    --command-api "${output_dir}/preflight/command-api.env"
    --gateway "${output_dir}/preflight/gateway.env"
    --query-api "${output_dir}/preflight/query-api.env"
    --outbox-relay "${output_dir}/preflight/outbox-relay.env"
    --ops "${output_dir}/preflight/ops.env"
    --stream-consumer "${output_dir}/preflight/stream-consumer-summary_projection_consumer.env"
    --stream-consumer "${output_dir}/preflight/stream-consumer-domain_delivery_consumer.env"
    --stream-consumer "${output_dir}/preflight/stream-consumer-realtime_delivery_consumer.env"
    --stream-consumer "${output_dir}/preflight/stream-consumer-changes_log_consumer.env"
    --stream-consumer "${output_dir}/preflight/stream-consumer-search_index_consumer.env"
    --stream-consumer "${output_dir}/preflight/stream-consumer-notification_consumer.env"
    --stream-consumer "${output_dir}/preflight/stream-consumer-repair_replay_consumer.env"
    --require-groups summary-projection-consumer,domain-delivery-consumer,realtime-delivery-consumer,changes-log-consumer,search-index-consumer,notification-consumer,repair-replay-consumer
  )
  if [[ "${allow_placeholders}" != true ]]; then
    args+=(--strict-secrets)
  fi
  "${PREFLIGHT}" "${args[@]}"
}

index=0
for inventory in "$@"; do
  index=$((index + 1))
  output_dir="${TMP_DIR}/rendered-${index}"
  "${RENDER}" "${inventory}" "${output_dir}" >/dev/null
  run_role_preflight "${output_dir}"
done

printf 'multicell-preflight result=pass inventories=%s strict_secrets=%s ha_required=%s\n' \
  "$#" "$([[ "${allow_placeholders}" == true ]] && printf false || printf true)" "${require_ha}"
