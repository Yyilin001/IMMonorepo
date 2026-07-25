#!/usr/bin/env bash
set -Eeuo pipefail

# Run several independent group conversations at once on Linux. Each group uses
# a disjoint token-cache slice so a result represents concurrent hot groups,
# not the same accounts duplicated across every group.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
TCP_HOST="${TCP_HOST:-127.0.0.1}"
TCP_PORT="${TCP_PORT:-9000}"
LOGIN_CACHE_FILE="${LOGIN_CACHE_FILE:-}"
IM_CONVERSATION_IDS="${IM_CONVERSATION_IDS:-}"
CONNECTIONS_PER_GROUP="${CONNECTIONS_PER_GROUP:-500}"
MESSAGE_RATE_PER_GROUP="${MESSAGE_RATE_PER_GROUP:-10}"
MESSAGE_DURATION_SECONDS="${MESSAGE_DURATION_SECONDS:-180}"
HOLD_SECONDS="${HOLD_SECONDS:-240}"
CONNECT_RAMP_SECONDS="${CONNECT_RAMP_SECONDS:-60}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-60}"
HEARTBEAT_INTERVAL_SECONDS="${HEARTBEAT_INTERVAL_SECONDS:-15}"
RESULTS_DIR="${RESULTS_DIR:-/tmp/im-multi-group-results-$(date -u +%Y%m%d-%H%M%S)}"
METRICS_INTERVAL_SECONDS="${METRICS_INTERVAL_SECONDS:-5}"
ACCOUNT_CACHE_OFFSET="${ACCOUNT_CACHE_OFFSET:-0}"
MIN_MESSAGE_ACK_RATE_PERCENT="${MIN_MESSAGE_ACK_RATE_PERCENT:-99.9}"
MIN_MESSAGE_DELIVERY_COVERAGE_PERCENT="${MIN_MESSAGE_DELIVERY_COVERAGE_PERCENT:-0}"
MAX_MESSAGE_DELIVERY_P99_MILLISECONDS="${MAX_MESSAGE_DELIVERY_P99_MILLISECONDS:-10000}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-imserver-production-smoke}"

fail() {
  echo "tcp_multi_group_delivery result=fail reason=$1" >&2
  exit 1
}

positive_integer() {
  [[ "$2" =~ ^[1-9][0-9]*$ ]] || fail "invalid_$1 value=$2"
}

[[ -n "${LOGIN_CACHE_FILE}" && -f "${LOGIN_CACHE_FILE}" ]] || fail "login_cache_file_missing"
[[ -n "${IM_CONVERSATION_IDS}" ]] || fail "conversation_ids_required"
[[ -f "${SCRIPT_DIR}/tcp_online_driver.py" ]] || fail "tcp_online_driver_missing"
positive_integer tcp_port "${TCP_PORT}"
positive_integer connections_per_group "${CONNECTIONS_PER_GROUP}"
positive_integer message_duration_seconds "${MESSAGE_DURATION_SECONDS}"
positive_integer hold_seconds "${HOLD_SECONDS}"
positive_integer metrics_interval_seconds "${METRICS_INTERVAL_SECONDS}"
positive_integer max_message_delivery_p99_milliseconds "${MAX_MESSAGE_DELIVERY_P99_MILLISECONDS}"

IFS=',' read -r -a conversation_ids <<<"${IM_CONVERSATION_IDS}"
(( ${#conversation_ids[@]} >= 2 )) || fail "at_least_two_conversations_required"
for conversation_id in "${conversation_ids[@]}"; do
  [[ -n "${conversation_id}" ]] || fail "empty_conversation_id"
done

required_records=$((ACCOUNT_CACHE_OFFSET + ${#conversation_ids[@]} * CONNECTIONS_PER_GROUP))
"${PYTHON_BIN}" - "${LOGIN_CACHE_FILE}" "${required_records}" <<'PY'
import json
import sys
with open(sys.argv[1]) as handle:
    records = json.load(handle)
required = int(sys.argv[2])
if len(records) < required:
    raise SystemExit(f"login_cache_records_insufficient actual={len(records)} expected={required}")
print(f"login_cache_records={len(records)}")
PY

mkdir -p "${RESULTS_DIR}"
printf 'startedAt=%s\ntcpHost=%s\ntcpPort=%s\ngroups=%s\nconnectionsPerGroup=%s\nmessageRatePerGroup=%s\nmessageDurationSeconds=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${TCP_HOST}" "${TCP_PORT}" "${#conversation_ids[@]}" \
  "${CONNECTIONS_PER_GROUP}" "${MESSAGE_RATE_PER_GROUP}" "${MESSAGE_DURATION_SECONDS}" \
  >"${RESULTS_DIR}/run.txt"

sample_metrics() {
  "${SCRIPT_DIR}/collect_linux_runtime_metrics.sh" \
    --output "${RESULTS_DIR}/host-metrics.log" \
    --interval-seconds "${METRICS_INTERVAL_SECONDS}" \
    --compose-project "${COMPOSE_PROJECT}" \
    --tcp-port "${TCP_PORT}"
}

sample_metrics &
metrics_pid=$!
cleanup() {
  kill "${metrics_pid}" 2>/dev/null || true
}
trap cleanup EXIT

declare -a pids=()
for group_index in "${!conversation_ids[@]}"; do
  conversation_id="${conversation_ids[$group_index]}"
  cache_offset=$((ACCOUNT_CACHE_OFFSET + group_index * CONNECTIONS_PER_GROUP))
  group_dir="${RESULTS_DIR}/group-${group_index}"
  mkdir -p "${group_dir}"
  "${PYTHON_BIN}" "${SCRIPT_DIR}/tcp_online_driver.py" \
    --tcp-host "${TCP_HOST}" \
    --tcp-port "${TCP_PORT}" \
    --connections "${CONNECTIONS_PER_GROUP}" \
    --connect-ramp-seconds "${CONNECT_RAMP_SECONDS}" \
    --hold-seconds "${HOLD_SECONDS}" \
    --timeout-seconds "${TIMEOUT_SECONDS}" \
    --heartbeat-interval-seconds "${HEARTBEAT_INTERVAL_SECONDS}" \
    --login-cache-file "${LOGIN_CACHE_FILE}" \
    --login-cache-offset "${cache_offset}" \
    --login-cache-ttl-guard-seconds "${TIMEOUT_SECONDS}" \
    --connection-log-file "${group_dir}/connections.jsonl" \
    --progress-file "${group_dir}/progress.json" \
    --suppress-packet-received-log \
    --conversation-id "${conversation_id}" \
    --active-conversation-users "${CONNECTIONS_PER_GROUP}" \
    --message-rate-per-second "${MESSAGE_RATE_PER_GROUP}" \
    --message-duration-seconds "${MESSAGE_DURATION_SECONDS}" \
    --message-drain-seconds 15 \
    --expected-recipients-per-message "$((CONNECTIONS_PER_GROUP - 1))" \
    --min-message-ack-rate-percent "${MIN_MESSAGE_ACK_RATE_PERCENT}" \
    --min-message-delivery-coverage-percent "${MIN_MESSAGE_DELIVERY_COVERAGE_PERCENT}" \
    --max-message-delivery-p99-milliseconds "${MAX_MESSAGE_DELIVERY_P99_MILLISECONDS}" \
    >"${group_dir}/summary.log" 2>&1 &
  pids+=("$!")
done

status=0
for pid in "${pids[@]}"; do
  wait "${pid}" || status=1
done

cat "${RESULTS_DIR}"/group-*/summary.log >"${RESULTS_DIR}/summary.log" || true
if (( status != 0 )); then
  fail "one_or_more_group_drivers_failed resultsDir=${RESULTS_DIR}"
fi

# ACK only proves durable command acceptance. Require a bounded client-side
# realtime latency too, otherwise a queued multi-group relay could be marked
# successful despite users waiting minutes for its activity hint.
"${PYTHON_BIN}" - "${MAX_MESSAGE_DELIVERY_P99_MILLISECONDS}" "${RESULTS_DIR}"/group-*/summary.log <<'PY'
import ast
import re
import sys

limit = int(sys.argv[1])
violations = []
for path in sys.argv[2:]:
    lines = open(path, encoding="utf-8").read().splitlines()
    profile = next((line for line in reversed(lines) if line.startswith("profile=")), "")
    match = re.search(r"messageDeliveryLatencyMs=(\{.*?\})", profile)
    if not match:
        violations.append(f"{path}: latency_summary_missing")
        continue
    latency = ast.literal_eval(match.group(1))
    p99 = latency.get("p99")
    if p99 is None or p99 > limit:
        violations.append(f"{path}: p99={p99} limit={limit} overflow={latency.get('overflowCount', 0)}")

if violations:
    raise SystemExit("message_delivery_latency_gate_failed " + "; ".join(violations))
print(f"message_delivery_latency_gate=pass p99LimitMs={limit}")
PY

echo "tcp_multi_group_delivery result=pass groups=${#conversation_ids[@]} totalConnections=$(( ${#conversation_ids[@]} * CONNECTIONS_PER_GROUP )) resultsDir=${RESULTS_DIR}"
