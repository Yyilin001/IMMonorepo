#!/usr/bin/env bash
set -Eeuo pipefail

# Linux-compatible TCP online-capacity ladder. The existing Swift driver relies
# on Apple's Network framework; this entry point uses the portable Python driver.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
TCP_HOST="${TCP_HOST:-127.0.0.1}"
TCP_PORT="${TCP_PORT:-9000}"
ACCOUNT_FILE="${ACCOUNT_FILE:-}"
ONLINE_LADDER="${ONLINE_LADDER:-100 500 1000 2000 5000}"
HOLD_SECONDS="${HOLD_SECONDS:-180}"
CONNECT_RAMP_SECONDS="${CONNECT_RAMP_SECONDS:-60}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-30}"
HEARTBEAT_INTERVAL_SECONDS="${HEARTBEAT_INTERVAL_SECONDS:-15}"
BARRIER_KEEPALIVE_SECONDS="${BARRIER_KEEPALIVE_SECONDS:-0}"
BARRIER_BATCH_SIZE="${BARRIER_BATCH_SIZE:-0}"
BARRIER_MIN_AUTH_RATIO="${BARRIER_MIN_AUTH_RATIO:-}"
BARRIER_TIMEOUT_SECONDS="${BARRIER_TIMEOUT_SECONDS:-0}"
LOGIN_CACHE_DIR="${LOGIN_CACHE_DIR:-/tmp/im-linux-tcp-login-cache}"
LOGIN_CACHE_FILE="${LOGIN_CACHE_FILE:-}"
LOGIN_CACHE_OFFSET="${LOGIN_CACHE_OFFSET:-0}"
RESULTS_DIR="${RESULTS_DIR:-/tmp/im-linux-tcp-capacity-results}"
PREWARM_LOGIN_CACHE="${PREWARM_LOGIN_CACHE:-true}"
REQUIRE_LOGIN_CACHE="${REQUIRE_LOGIN_CACHE:-true}"
LOGIN_CACHE_TTL_GUARD_SECONDS="${LOGIN_CACHE_TTL_GUARD_SECONDS:-60}"
LOGIN_CONCURRENCY="${LOGIN_CONCURRENCY:-96}"
LOAD_GENERATOR_ID="${LOAD_GENERATOR_ID:-1}"
LOAD_GENERATOR_COUNT="${LOAD_GENERATOR_COUNT:-1}"
ACCOUNT_SHARD_OFFSET="${ACCOUNT_SHARD_OFFSET:-}"
ACCOUNT_SHARD_LIMIT="${ACCOUNT_SHARD_LIMIT:-}"
DEVICE_ID_PREFIX="${DEVICE_ID_PREFIX:-tcp-linux-lg${LOAD_GENERATOR_ID}}"
CONVERSATION_ID="${CONVERSATION_ID:-}"
ACTIVE_CONVERSATION_USERS="${ACTIVE_CONVERSATION_USERS:-0}"
MESSAGE_RATE_PER_SECOND="${MESSAGE_RATE_PER_SECOND:-0}"
MESSAGE_DURATION_SECONDS="${MESSAGE_DURATION_SECONDS:-0}"
MESSAGE_SENDER_EVERY="${MESSAGE_SENDER_EVERY:-1}"
MESSAGE_DRAIN_SECONDS="${MESSAGE_DRAIN_SECONDS:-0}"
EXPECTED_RECIPIENTS_PER_MESSAGE="${EXPECTED_RECIPIENTS_PER_MESSAGE:-0}"
MIN_MESSAGE_ACK_RATE_PERCENT="${MIN_MESSAGE_ACK_RATE_PERCENT:-0}"
MIN_MESSAGE_DELIVERY_COVERAGE_PERCENT="${MIN_MESSAGE_DELIVERY_COVERAGE_PERCENT:-0}"
MAX_MESSAGE_DELIVERY_P99_MILLISECONDS="${MAX_MESSAGE_DELIVERY_P99_MILLISECONDS:-0}"
MIN_SUCCESS_RATE_PERCENT="${MIN_SUCCESS_RATE_PERCENT:-99.9}"
DRIVER_SHARDS="${DRIVER_SHARDS:-1}"
LOCAL_BIND_HOSTS="${LOCAL_BIND_HOSTS:-}"
TCP_LINUX_CAPACITY_LADDER_DRY_RUN="${TCP_LINUX_CAPACITY_LADDER_DRY_RUN:-false}"
COLLECT_HOST_METRICS="${COLLECT_HOST_METRICS:-false}"
METRICS_INTERVAL_SECONDS="${METRICS_INTERVAL_SECONDS:-5}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-imserver-production-smoke}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

ACTIVE_DRIVER_PIDS=()
metrics_pid=""

cleanup_active_drivers() {
  local pid
  for pid in "${ACTIVE_DRIVER_PIDS[@]:-}"; do
    kill "${pid}" 2>/dev/null || true
  done
  for pid in "${ACTIVE_DRIVER_PIDS[@]:-}"; do
    wait "${pid}" 2>/dev/null || true
  done
  ACTIVE_DRIVER_PIDS=()
  if [[ -n "${metrics_pid}" ]]; then
    kill "${metrics_pid}" 2>/dev/null || true
    wait "${metrics_pid}" 2>/dev/null || true
    metrics_pid=""
  fi
}

trap cleanup_active_drivers EXIT
trap 'cleanup_active_drivers; exit 130' INT
trap 'cleanup_active_drivers; exit 143' TERM

fail() {
  echo "tcp_linux_capacity_ladder result=fail reason=$1" >&2
  exit 1
}

require_positive_integer() {
  local name="$1" value="$2"
  [[ "${value}" =~ ^[1-9][0-9]*$ ]] || fail "invalid_${name} value=${value}"
}

snapshot_load_generator() {
  local path="$1"
  {
    date -u +"timestamp=%Y-%m-%dT%H:%M:%SZ"
    uptime || true
    free -h || true
    ss -s || true
  } >"${path}"
}

cache_path_for() {
  local connections="$1"
  if [[ -n "${LOGIN_CACHE_FILE}" ]]; then
    printf '%s' "${LOGIN_CACHE_FILE}"
    return
  fi
  printf '%s/tcp-login-cache-lg%s-%s.json' "${LOGIN_CACHE_DIR}" "${LOAD_GENERATOR_ID}" "${connections}"
}

assert_cache_records() {
  local cache_path="$1" connections="$2" cache_offset="$3"
  "${PYTHON_BIN}" - "${cache_path}" "${connections}" "${cache_offset}" <<'PY'
import json
import sys

path, expected, offset = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(path) as handle:
    records = json.load(handle)
required = offset + expected
if len(records) < required:
    raise SystemExit(f"cache_records_insufficient actual={len(records)} expected={required}")
for record in records[offset:required]:
    if not record.get("accessToken") or not record.get("expiresAtMs"):
        raise SystemExit("cache_record_invalid")
print(f"login_cache_records={len(records)} login_cache_offset={offset}")
PY
}

validate_step_result() {
  local step_dir="$1" connections="$2"
  local auth_count successes rate summary_path
  auth_count="$(grep -h -c '"event":"auth_ok_received"' "${step_dir}"/connections-shard-*.jsonl 2>/dev/null | awk '{sum += $1} END {print sum + 0}')"
  [[ "${auth_count}" == "${connections}" ]] || fail "auth_ok_incomplete expected=${connections} actual=${auth_count} stepDir=${step_dir}"

  successes="$(sed -nE 's/.* successes=([0-9]+).*/\1/p' "${step_dir}"/summary-shard-*.log 2>/dev/null | awk '{sum += $1} END {print sum + 0}')"
  [[ "${successes}" -gt 0 ]] || fail "summary_successes_missing stepDir=${step_dir}"
  rate="$("${PYTHON_BIN}" - "${successes}" "${connections}" <<'PY'
import sys
print(f"{int(sys.argv[1]) * 100 / int(sys.argv[2]):.4f}")
PY
)"
  if ! "${PYTHON_BIN}" - "${rate}" "${MIN_SUCCESS_RATE_PERCENT}" <<'PY'
import sys
if float(sys.argv[1]) + 1e-9 < float(sys.argv[2]):
    raise SystemExit(1)
PY
  then
    fail "success_rate_below_threshold actual=${rate} threshold=${MIN_SUCCESS_RATE_PERCENT}"
  fi
  echo "step_result=pass connections=${connections} authOK=${auth_count} successes=${successes} successRatePercent=${rate}"
}

run_step() {
  local connections="$1"
  local cache_path step_dir prewarm_log
  cache_path="$(cache_path_for "${connections}")"
  step_dir="${RESULTS_DIR}/connections-${connections}"
  prewarm_log="${step_dir}/prewarm.log"
  mkdir -p "${step_dir}" "${LOGIN_CACHE_DIR}"

  snapshot_load_generator "${step_dir}/load-generator-before.txt"
  if bool_enabled "${COLLECT_HOST_METRICS}"; then
    "${SCRIPT_DIR}/collect_linux_runtime_metrics.sh" \
      --output "${step_dir}/host-metrics.log" \
      --interval-seconds "${METRICS_INTERVAL_SECONDS}" \
      --compose-project "${COMPOSE_PROJECT}" \
      --tcp-port "${TCP_PORT}" &
    metrics_pid=$!
  fi
  if bool_enabled "${PREWARM_LOGIN_CACHE}"; then
    local -a prewarm_args=(
      "${PYTHON_BIN}" "${SCRIPT_DIR}/prewarm_login_cache_parallel.py"
      --base-url "${BASE_URL}"
      --account-file "${ACCOUNT_FILE}"
      --connections "${connections}"
      --login-cache-file "${cache_path}"
      --concurrency "${LOGIN_CONCURRENCY}"
      --load-generator-id "${LOAD_GENERATOR_ID}"
      --load-generator-count "${LOAD_GENERATOR_COUNT}"
      --device-id-prefix "${DEVICE_ID_PREFIX}"
    )
    [[ -z "${ACCOUNT_SHARD_OFFSET}" ]] || prewarm_args+=(--account-shard-offset "${ACCOUNT_SHARD_OFFSET}")
    [[ -z "${ACCOUNT_SHARD_LIMIT}" ]] || prewarm_args+=(--account-shard-limit "${ACCOUNT_SHARD_LIMIT}")
    "${prewarm_args[@]}" | tee "${prewarm_log}"
  elif bool_enabled "${REQUIRE_LOGIN_CACHE}" && [[ ! -f "${cache_path}" ]]; then
    fail "login_cache_missing cache=${cache_path}"
  fi

  [[ -f "${cache_path}" ]] || fail "login_cache_missing cache=${cache_path}"
  assert_cache_records "${cache_path}" "${connections}" "${LOGIN_CACHE_OFFSET}" | tee "${step_dir}/cache-validation.log"

  local shard offset shard_connections active_users summary_path connection_log progress_path local_bind_host
  local -a local_bind_hosts=()
  if [[ -n "${LOCAL_BIND_HOSTS}" ]]; then
    IFS=',' read -r -a local_bind_hosts <<<"${LOCAL_BIND_HOSTS}"
  fi
  ACTIVE_DRIVER_PIDS=()
  for ((shard = 0; shard < DRIVER_SHARDS; shard++)); do
    offset=$((connections * shard / DRIVER_SHARDS))
    shard_connections=$((connections * (shard + 1) / DRIVER_SHARDS - offset))
    active_users=0
    if [[ "${ACTIVE_CONVERSATION_USERS}" -gt "${offset}" ]]; then
      active_users=$((ACTIVE_CONVERSATION_USERS - offset))
      [[ "${active_users}" -le "${shard_connections}" ]] || active_users="${shard_connections}"
    fi
    summary_path="${step_dir}/summary-shard-${shard}.log"
    connection_log="${step_dir}/connections-shard-${shard}.jsonl"
    progress_path="${step_dir}/progress-shard-${shard}.json"
    local_bind_host=""
    if ((${#local_bind_hosts[@]})); then
      local_bind_host="${local_bind_hosts[$((shard % ${#local_bind_hosts[@]}))]}"
    fi
    local -a driver_args=(
      "${PYTHON_BIN}" "${SCRIPT_DIR}/tcp_online_driver.py"
      --tcp-host "${TCP_HOST}"
      --tcp-port "${TCP_PORT}"
      --connections "${shard_connections}"
      --connect-ramp-seconds "${CONNECT_RAMP_SECONDS}"
      --hold-seconds "${HOLD_SECONDS}"
      --timeout-seconds "${TIMEOUT_SECONDS}"
      --heartbeat-interval-seconds "${HEARTBEAT_INTERVAL_SECONDS}"
      --barrier-batch-size "${BARRIER_BATCH_SIZE}"
      --barrier-min-auth-ratio "${BARRIER_MIN_AUTH_RATIO}"
      --barrier-timeout-seconds "${BARRIER_TIMEOUT_SECONDS}"
      --login-cache-file "${cache_path}"
      --login-cache-offset "$((LOGIN_CACHE_OFFSET + offset))"
      --login-cache-ttl-guard-seconds "${LOGIN_CACHE_TTL_GUARD_SECONDS}"
      --connection-log-file "${connection_log}"
      --progress-file "${progress_path}"
      --suppress-packet-received-log
    )
    [[ -z "${local_bind_host}" ]] || driver_args+=(--local-bind-host "${local_bind_host}")
    [[ -z "${CONVERSATION_ID}" ]] || driver_args+=(--conversation-id "${CONVERSATION_ID}")
    driver_args+=(
      --active-conversation-users "${active_users}"
      --message-rate-per-second "${MESSAGE_RATE_PER_SECOND}"
      --message-duration-seconds "${MESSAGE_DURATION_SECONDS}"
      --message-sender-every "${MESSAGE_SENDER_EVERY}"
      --message-drain-seconds "${MESSAGE_DRAIN_SECONDS}"
      --expected-recipients-per-message "${EXPECTED_RECIPIENTS_PER_MESSAGE}"
      --min-message-ack-rate-percent "${MIN_MESSAGE_ACK_RATE_PERCENT}"
      --min-message-delivery-coverage-percent "${MIN_MESSAGE_DELIVERY_COVERAGE_PERCENT}"
      --max-message-delivery-p99-milliseconds "${MAX_MESSAGE_DELIVERY_P99_MILLISECONDS}"
    )
    "${driver_args[@]}" | tee "${summary_path}" &
    ACTIVE_DRIVER_PIDS+=("$!")
  done
  local driver_status=0
  for driver_pid in "${ACTIVE_DRIVER_PIDS[@]}"; do
    wait "${driver_pid}" || driver_status=1
  done
  ACTIVE_DRIVER_PIDS=()
  [[ "${driver_status}" == "0" ]] || fail "driver_process_failed stepDir=${step_dir}"
  snapshot_load_generator "${step_dir}/load-generator-after.txt"
  if [[ -n "${metrics_pid}" ]]; then
    kill "${metrics_pid}" 2>/dev/null || true
    wait "${metrics_pid}" 2>/dev/null || true
    metrics_pid=""
  fi
  validate_step_result "${step_dir}" "${connections}" | tee "${step_dir}/result.log"
}

require_positive_integer "tcp_port" "${TCP_PORT}"
require_positive_integer "hold_seconds" "${HOLD_SECONDS}"
require_positive_integer "timeout_seconds" "${TIMEOUT_SECONDS}"
require_positive_integer "heartbeat_interval_seconds" "${HEARTBEAT_INTERVAL_SECONDS}"
[[ "${BARRIER_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]] || fail "invalid_barrier_timeout_seconds value=${BARRIER_TIMEOUT_SECONDS}"
require_positive_integer "metrics_interval_seconds" "${METRICS_INTERVAL_SECONDS}"
require_positive_integer "login_concurrency" "${LOGIN_CONCURRENCY}"
require_positive_integer "driver_shards" "${DRIVER_SHARDS}"
require_positive_integer "load_generator_id" "${LOAD_GENERATOR_ID}"
require_positive_integer "load_generator_count" "${LOAD_GENERATOR_COUNT}"
[[ "${LOGIN_CACHE_OFFSET}" =~ ^[0-9]+$ ]] || fail "invalid_login_cache_offset value=${LOGIN_CACHE_OFFSET}"
[[ "${MAX_MESSAGE_DELIVERY_P99_MILLISECONDS}" =~ ^[0-9]+$ ]] || fail "invalid_max_message_delivery_p99_milliseconds value=${MAX_MESSAGE_DELIVERY_P99_MILLISECONDS}"
if [[ -z "${BARRIER_MIN_AUTH_RATIO}" ]]; then
  BARRIER_MIN_AUTH_RATIO="$("${PYTHON_BIN}" - "${MIN_SUCCESS_RATE_PERCENT}" <<'PY'
import sys
ratio = float(sys.argv[1]) / 100
if not 0 < ratio <= 1:
    raise SystemExit(1)
print(f"{ratio:.12g}")
PY
)" || fail "invalid_min_success_rate_percent value=${MIN_SUCCESS_RATE_PERCENT}"
fi
if ! "${PYTHON_BIN}" - "${BARRIER_MIN_AUTH_RATIO}" <<'PY'
import sys
ratio = float(sys.argv[1])
if not 0 < ratio <= 1:
    raise SystemExit(1)
PY
then
  fail "invalid_barrier_min_auth_ratio value=${BARRIER_MIN_AUTH_RATIO}"
fi
[[ "${LOAD_GENERATOR_ID}" -le "${LOAD_GENERATOR_COUNT}" ]] || fail "load_generator_id_exceeds_count"
[[ -n "${ACCOUNT_FILE}" ]] || fail "account_file_required"
[[ -f "${ACCOUNT_FILE}" ]] || fail "account_file_missing path=${ACCOUNT_FILE}"
[[ -f "${SCRIPT_DIR}/tcp_online_driver.py" ]] || fail "tcp_online_driver_missing"
[[ -f "${SCRIPT_DIR}/prewarm_login_cache_parallel.py" ]] || fail "prewarm_driver_missing"

if bool_enabled "${TCP_LINUX_CAPACITY_LADDER_DRY_RUN}"; then
  printf 'dry-run tcp_linux_capacity_ladder baseURL=%s tcpHost=%s tcpPort=%s ladder=%s hold=%s ramp=%s lg=%s/%s driverShards=%s cacheDir=%s resultsDir=%s messagesPerSecond=%s minAckRatePercent=%s minDeliveryCoveragePercent=%s\n' \
    "${BASE_URL}" "${TCP_HOST}" "${TCP_PORT}" "${ONLINE_LADDER}" "${HOLD_SECONDS}" "${CONNECT_RAMP_SECONDS}" \
    "${LOAD_GENERATOR_ID}" "${LOAD_GENERATOR_COUNT}" "${DRIVER_SHARDS}" "${LOGIN_CACHE_DIR}" "${RESULTS_DIR}" "${MESSAGE_RATE_PER_SECOND}" \
    "${MIN_MESSAGE_ACK_RATE_PERCENT}" "${MIN_MESSAGE_DELIVERY_COVERAGE_PERCENT}"
  exit 0
fi

mkdir -p "${RESULTS_DIR}"
for connections in ${ONLINE_LADDER}; do
  require_positive_integer "connections" "${connections}"
  echo "==> tcp_linux_capacity_step connections=${connections} lg=${LOAD_GENERATOR_ID}/${LOAD_GENERATOR_COUNT}"
  run_step "${connections}"
done

echo "tcp_linux_capacity_ladder result=pass resultsDir=${RESULTS_DIR}"
