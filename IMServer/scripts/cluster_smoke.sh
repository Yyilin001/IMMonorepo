#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SMOKE_SCRIPT="${ROOT_DIR}/scripts/production_smoke.sh"
FAILURE_DRILL_SCRIPT="${ROOT_DIR}/scripts/failure_drill.sh"
COMPOSE_OVERLAY="${ROOT_DIR}/docker-compose.cluster-smoke.yml"

usage() {
  cat <<'USAGE'
Usage: cluster_smoke.sh <up|run|down|logs|self-test|failure-drill> [drill]

Runs the existing production smoke topology with a three-primary Valkey Cluster
overlay. This validates Cluster startup, routing, auth/cache state, timeline
invalidation, and the normal Kafka/outbox smoke path. It is not a capacity test.

Examples:
  scripts/cluster_smoke.sh self-test
  scripts/cluster_smoke.sh run
  IM_CLUSTER_SMOKE_REQUIRE_GATEWAY_TCP_RELAY=true scripts/cluster_smoke.sh run
  scripts/cluster_smoke.sh failure-drill redis-outage
USAGE
}

static_self_test() {
  bash -n "${SMOKE_SCRIPT}" "${FAILURE_DRILL_SCRIPT}" "${BASH_SOURCE[0]}"
  python3 - "${COMPOSE_OVERLAY}" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
required = (
    "valkey-1:",
    "valkey-2:",
    "valkey-3:",
    "valkey-cluster-init:",
    "valkey-cli --cluster create",
    "IM_REDIS_DEPLOYMENT_TOPOLOGY: cluster",
    "IM_REDIS_CLUSTER_NODES:",
    "IM_NODE_DISPATCH_MODE: http",
    "IM_DELIVERY_TRACE_SAMPLING_ENABLED: \"true\"",
    "IM_DELIVERY_TRACE_SAMPLE_RATE_BPS: \"10000\"",
    "IM_DELIVERY_TRACE_MAX_LOGS_PER_MINUTE: \"20\"",
    "stream-consumer-realtime:",
)
missing = [value for value in required if value not in text]
if missing:
    raise SystemExit(f"cluster-smoke-self-test result=fail missing={','.join(missing)}")
print("cluster-smoke-self-test result=pass")
PY
}

run_smoke() {
  local command="$1"
  shift
  local require_delivery_trace="false"
  local require_gateway_tcp_relay="${IM_CLUSTER_SMOKE_REQUIRE_GATEWAY_TCP_RELAY:-false}"
  if [[ "${command}" == "run" ]]; then
    require_delivery_trace="true"
  fi
    IM_SMOKE_COMPOSE_EXTRA_FILE="${COMPOSE_OVERLAY}" \
    IM_SMOKE_REQUIRE_DELIVERY_TRACE="${require_delivery_trace}" \
    IM_SMOKE_REQUIRE_GATEWAY_TCP_RELAY="${require_gateway_tcp_relay}" \
    COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-imserver-cluster-smoke}" \
    "${SMOKE_SCRIPT}" "${command}" "$@"
}

case "${1:-}" in
  up|run|down|logs)
    run_smoke "$@"
    ;;
  self-test)
    static_self_test
    run_smoke self-test
    ;;
  failure-drill)
    drill="${2:-}"
    if [[ -z "${drill}" ]]; then
      usage >&2
      exit 2
    fi
    IM_SMOKE_COMPOSE_EXTRA_FILE="${COMPOSE_OVERLAY}" \
      COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-imserver-cluster-smoke}" \
      "${FAILURE_DRILL_SCRIPT}" "${drill}"
    ;;
  -h|--help|"")
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
