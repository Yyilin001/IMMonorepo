#!/usr/bin/env bash
set -Eeuo pipefail

# Linux-native message matrix. It intentionally reuses a prewarmed cache so
# message delivery measurements do not include HTTP authentication work.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TCP_HOST="${TCP_HOST:-127.0.0.1}"
TCP_PORT="${TCP_PORT:-9000}"
ACCOUNT_FILE="${ACCOUNT_FILE:-}"
LOGIN_CACHE_FILE="${LOGIN_CACHE_FILE:-}"
DIRECT_CONVERSATION_ID="${DIRECT_CONVERSATION_ID:-}"
SMALL_GROUP_CONVERSATION_ID="${SMALL_GROUP_CONVERSATION_ID:-}"
LARGE_GROUP_CONVERSATION_ID="${LARGE_GROUP_CONVERSATION_ID:-}"
MULTI_GROUP_CONVERSATION_IDS="${MULTI_GROUP_CONVERSATION_IDS:-}"
RESULTS_DIR="${RESULTS_DIR:-/tmp/im-linux-message-matrix-$(date -u +%Y%m%d-%H%M%S)}"
MESSAGE_DURATION_SECONDS="${MESSAGE_DURATION_SECONDS:-180}"
HOLD_SECONDS="${HOLD_SECONDS:-240}"
METRICS_INTERVAL_SECONDS="${METRICS_INTERVAL_SECONDS:-5}"
DIRECT_CACHE_OFFSET="${DIRECT_CACHE_OFFSET:-0}"
SMALL_GROUP_CACHE_OFFSET="${SMALL_GROUP_CACHE_OFFSET:-100}"
LARGE_GROUP_CACHE_OFFSET="${LARGE_GROUP_CACHE_OFFSET:-1000}"
MULTI_GROUP_CACHE_OFFSET="${MULTI_GROUP_CACHE_OFFSET:-12000}"
SMALL_GROUP_CONNECTIONS="${SMALL_GROUP_CONNECTIONS:-500}"
LARGE_GROUP_CONNECTIONS="${LARGE_GROUP_CONNECTIONS:-10000}"
MULTI_GROUP_CONNECTIONS="${MULTI_GROUP_CONNECTIONS:-500}"
MIN_MESSAGE_DELIVERY_COVERAGE_PERCENT="${MIN_MESSAGE_DELIVERY_COVERAGE_PERCENT:-95}"
MAX_MESSAGE_DELIVERY_P99_MILLISECONDS="${MAX_MESSAGE_DELIVERY_P99_MILLISECONDS:-10000}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-imserver-production-smoke}"
BACKGROUND_CONNECTIONS="${BACKGROUND_CONNECTIONS:-0}"
BACKGROUND_CACHE_OFFSET="${BACKGROUND_CACHE_OFFSET:-20000}"
BACKGROUND_CONNECT_RAMP_SECONDS="${BACKGROUND_CONNECT_RAMP_SECONDS:-600}"
BACKGROUND_HOLD_SECONDS="${BACKGROUND_HOLD_SECONDS:-1500}"
BACKGROUND_DRIVER_SHARDS="${BACKGROUND_DRIVER_SHARDS:-1}"
BACKGROUND_LOCAL_BIND_HOSTS="${BACKGROUND_LOCAL_BIND_HOSTS:-}"
BACKGROUND_TIMEOUT_SECONDS="${BACKGROUND_TIMEOUT_SECONDS:-90}"
BACKGROUND_HEARTBEAT_INTERVAL_SECONDS="${BACKGROUND_HEARTBEAT_INTERVAL_SECONDS:-15}"
BACKGROUND_MIN_SUCCESS_RATE_PERCENT="${BACKGROUND_MIN_SUCCESS_RATE_PERCENT:-99.9}"

fail() {
  echo "run_linux_message_matrix result=fail reason=$1" >&2
  exit 1
}

require() {
  [[ -n "$2" ]] || fail "${1}_required"
}

require account_file "${ACCOUNT_FILE}"
[[ -f "${ACCOUNT_FILE}" ]] || fail "account_file_missing"
require login_cache_file "${LOGIN_CACHE_FILE}"
[[ -f "${LOGIN_CACHE_FILE}" ]] || fail "login_cache_file_missing"
require direct_conversation_id "${DIRECT_CONVERSATION_ID}"
require small_group_conversation_id "${SMALL_GROUP_CONVERSATION_ID}"
require large_group_conversation_id "${LARGE_GROUP_CONVERSATION_ID}"
require multi_group_conversation_ids "${MULTI_GROUP_CONVERSATION_IDS}"
IFS=',' read -r -a multi_group_ids <<<"${MULTI_GROUP_CONVERSATION_IDS}"
MULTI_GROUP_COUNT="${#multi_group_ids[@]}"
(( MULTI_GROUP_COUNT >= 2 )) || fail "at_least_two_multi_group_conversations_required"

if ! [[ "${BACKGROUND_CONNECTIONS}" =~ ^[0-9]+$ ]]; then
  fail "invalid_background_connections value=${BACKGROUND_CONNECTIONS}"
fi

required_cache_records=$((LARGE_GROUP_CACHE_OFFSET + LARGE_GROUP_CONNECTIONS))
multi_group_records=$((MULTI_GROUP_CACHE_OFFSET + MULTI_GROUP_COUNT * MULTI_GROUP_CONNECTIONS))
(( multi_group_records > required_cache_records )) && required_cache_records="${multi_group_records}"
background_records=$((BACKGROUND_CACHE_OFFSET + BACKGROUND_CONNECTIONS))
(( background_records > required_cache_records )) && required_cache_records="${background_records}"
python3 - "${LOGIN_CACHE_FILE}" "${required_cache_records}" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    records = json.load(handle)
required = int(sys.argv[2])
if len(records) < required:
    raise SystemExit(f"login_cache_records_insufficient actual={len(records)} expected={required}")
print(f"login_cache_records={len(records)} required={required}")
PY

mkdir -p "${RESULTS_DIR}"
printf 'startedAt=%s\ntcpHost=%s\ntcpPort=%s\nmessageDurationSeconds=%s\nholdSeconds=%s\nbackgroundConnections=%s\nbackgroundCacheOffset=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${TCP_HOST}" "${TCP_PORT}" \
  "${MESSAGE_DURATION_SECONDS}" "${HOLD_SECONDS}" "${BACKGROUND_CONNECTIONS}" "${BACKGROUND_CACHE_OFFSET}" >"${RESULTS_DIR}/run.txt"

sample_metrics() {
  "${SCRIPT_DIR}/collect_linux_runtime_metrics.sh" \
    --output "${RESULTS_DIR}/host-metrics.log" \
    --interval-seconds "${METRICS_INTERVAL_SECONDS}" \
    --compose-project "${COMPOSE_PROJECT}" \
    --tcp-port "${TCP_PORT}"
}

sample_metrics &
metrics_pid=$!
background_pid=""
cleanup_started=false
cleanup() {
  if [[ "${cleanup_started}" == "true" ]]; then
    return
  fi
  cleanup_started=true
  kill "${metrics_pid}" 2>/dev/null || true
  if [[ -n "${background_pid}" ]]; then
    # The background ladder owns multiple Python drivers. It is started in a
    # dedicated session below, so terminate the whole process group rather
    # than leaving authenticated TCP connections alive after the matrix exits.
    kill -TERM -- "-${background_pid}" 2>/dev/null || kill -TERM "${background_pid}" 2>/dev/null || true
    wait "${background_pid}" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

wait_for_background_auth() {
  local background_dir="$1" deadline now authenticated
  deadline=$(( $(date +%s) + BACKGROUND_CONNECT_RAMP_SECONDS + BACKGROUND_TIMEOUT_SECONDS + 60 ))
  while true; do
    authenticated="$(python3 - "${background_dir}" <<'PY'
import glob
import json
import sys

total = 0
for path in glob.glob(f"{sys.argv[1]}/connections-*/progress-shard-*.json"):
    try:
        total += int(json.load(open(path)).get("authOK", 0))
    except (OSError, ValueError, TypeError):
        pass
print(total)
PY
)"
    if (( authenticated >= BACKGROUND_CONNECTIONS )); then
      printf 'background_auth_ok=%s\n' "${authenticated}" | tee -a "${RESULTS_DIR}/run.txt"
      return
    fi
    if ! kill -0 "${background_pid}" 2>/dev/null; then
      fail "background_driver_exited authOK=${authenticated} log=${background_dir}/run.log"
    fi
    now=$(date +%s)
    if (( now >= deadline )); then
      fail "background_auth_timeout authOK=${authenticated} expected=${BACKGROUND_CONNECTIONS}"
    fi
    sleep 5
  done
}

start_background_online() {
  (( BACKGROUND_CONNECTIONS > 0 )) || return
  local background_dir="${RESULTS_DIR}/background-online-${BACKGROUND_CONNECTIONS}"
  mkdir -p "${background_dir}"
  # A separate session makes cleanup deterministic even while the ladder is
  # blocked in `wait` for one of its driver processes.
  env \
    TCP_HOST="${TCP_HOST}" \
    TCP_PORT="${TCP_PORT}" \
    ACCOUNT_FILE="${ACCOUNT_FILE}" \
    LOGIN_CACHE_FILE="${LOGIN_CACHE_FILE}" \
    LOGIN_CACHE_OFFSET="${BACKGROUND_CACHE_OFFSET}" \
    PREWARM_LOGIN_CACHE=false \
    REQUIRE_LOGIN_CACHE=true \
    ONLINE_LADDER="${BACKGROUND_CONNECTIONS}" \
    HOLD_SECONDS="${BACKGROUND_HOLD_SECONDS}" \
    CONNECT_RAMP_SECONDS="${BACKGROUND_CONNECT_RAMP_SECONDS}" \
    TIMEOUT_SECONDS="${BACKGROUND_TIMEOUT_SECONDS}" \
    HEARTBEAT_INTERVAL_SECONDS="${BACKGROUND_HEARTBEAT_INTERVAL_SECONDS}" \
    MIN_SUCCESS_RATE_PERCENT="${BACKGROUND_MIN_SUCCESS_RATE_PERCENT}" \
    DRIVER_SHARDS="${BACKGROUND_DRIVER_SHARDS}" \
    LOCAL_BIND_HOSTS="${BACKGROUND_LOCAL_BIND_HOSTS}" \
    RESULTS_DIR="${background_dir}" \
    setsid "${SCRIPT_DIR}/tcp_linux_capacity_ladder.sh" \
    >"${background_dir}/run.log" 2>&1 &
  background_pid=$!
  wait_for_background_auth "${background_dir}"
}

run_single_group() {
  local name="$1" conversation_id="$2" connections="$3" rate="$4" cache_offset="$5"
  local step_dir="${RESULTS_DIR}/${name}"
  mkdir -p "${step_dir}"
  env \
    TCP_HOST="${TCP_HOST}" \
    TCP_PORT="${TCP_PORT}" \
    ACCOUNT_FILE="${ACCOUNT_FILE}" \
    LOGIN_CACHE_FILE="${LOGIN_CACHE_FILE}" \
    LOGIN_CACHE_OFFSET="${cache_offset}" \
    PREWARM_LOGIN_CACHE=false \
    REQUIRE_LOGIN_CACHE=true \
    ONLINE_LADDER="${connections}" \
    HOLD_SECONDS="${HOLD_SECONDS}" \
    CONNECT_RAMP_SECONDS=120 \
    TIMEOUT_SECONDS=90 \
    HEARTBEAT_INTERVAL_SECONDS=15 \
    CONVERSATION_ID="${conversation_id}" \
    ACTIVE_CONVERSATION_USERS="${connections}" \
    MESSAGE_RATE_PER_SECOND="${rate}" \
    MESSAGE_DURATION_SECONDS="${MESSAGE_DURATION_SECONDS}" \
    MESSAGE_DRAIN_SECONDS=15 \
    EXPECTED_RECIPIENTS_PER_MESSAGE="$((connections - 1))" \
    MIN_MESSAGE_ACK_RATE_PERCENT=99.9 \
    MIN_MESSAGE_DELIVERY_COVERAGE_PERCENT="${MIN_MESSAGE_DELIVERY_COVERAGE_PERCENT}" \
    MAX_MESSAGE_DELIVERY_P99_MILLISECONDS="${MAX_MESSAGE_DELIVERY_P99_MILLISECONDS}" \
    COLLECT_REMOTE_METRICS=false \
    RESULTS_DIR="${step_dir}" \
    "${SCRIPT_DIR}/tcp_linux_capacity_ladder.sh" \
    >"${step_dir}/run.log" 2>&1
}

start_background_online
run_single_group direct "${DIRECT_CONVERSATION_ID}" 2 50 "${DIRECT_CACHE_OFFSET}"
run_single_group small-group-500-30 "${SMALL_GROUP_CONVERSATION_ID}" "${SMALL_GROUP_CONNECTIONS}" 30 "${SMALL_GROUP_CACHE_OFFSET}"
run_single_group large-group-10000-5 "${LARGE_GROUP_CONVERSATION_ID}" "${LARGE_GROUP_CONNECTIONS}" 5 "${LARGE_GROUP_CACHE_OFFSET}"
run_single_group large-group-10000-10 "${LARGE_GROUP_CONVERSATION_ID}" "${LARGE_GROUP_CONNECTIONS}" 10 "${LARGE_GROUP_CACHE_OFFSET}"

env \
  TCP_HOST="${TCP_HOST}" \
  TCP_PORT="${TCP_PORT}" \
  LOGIN_CACHE_FILE="${LOGIN_CACHE_FILE}" \
  IM_CONVERSATION_IDS="${MULTI_GROUP_CONVERSATION_IDS}" \
  CONNECTIONS_PER_GROUP="${MULTI_GROUP_CONNECTIONS}" \
  MESSAGE_RATE_PER_GROUP=10 \
  MESSAGE_DURATION_SECONDS="${MESSAGE_DURATION_SECONDS}" \
  HOLD_SECONDS="${HOLD_SECONDS}" \
  CONNECT_RAMP_SECONDS=120 \
  TIMEOUT_SECONDS=90 \
  ACCOUNT_CACHE_OFFSET="${MULTI_GROUP_CACHE_OFFSET}" \
  COMPOSE_PROJECT="${COMPOSE_PROJECT}" \
  MIN_MESSAGE_DELIVERY_COVERAGE_PERCENT="${MIN_MESSAGE_DELIVERY_COVERAGE_PERCENT}" \
  MAX_MESSAGE_DELIVERY_P99_MILLISECONDS="${MAX_MESSAGE_DELIVERY_P99_MILLISECONDS}" \
  RESULTS_DIR="${RESULTS_DIR}/multi-group-4x500-10" \
  "${SCRIPT_DIR}/tcp_multi_group_delivery.sh" \
  >"${RESULTS_DIR}/multi-group-4x500-10.log" 2>&1

echo "run_linux_message_matrix result=pass resultsDir=${RESULTS_DIR}"
