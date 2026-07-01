#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TCP_DRIVER_DIR="${SCRIPT_DIR}/TCPDriver"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

default_protocol_version() {
  local version_file="${REPO_ROOT}/Protocol/im_realtime/v1/protocol_version.txt"
  if [[ -f "${version_file}" ]]; then
    tr -d '[:space:]' <"${version_file}"
  else
    echo "12"
  fi
}

default_tcp_host_from_base_url() {
  local url="$1"
  python3 - "${url}" <<'PY'
import sys
from urllib.parse import urlsplit

print(urlsplit(sys.argv[1]).hostname or "127.0.0.1")
PY
}

BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
TCP_HOST="${TCP_HOST:-$(default_tcp_host_from_base_url "${BASE_URL}")}"
TCP_PORT="${TCP_PORT:-9000}"
IM_EMAIL="${IM_EMAIL:-demo@example.com}"
IM_PASSWORD="${IM_PASSWORD:-password1234}"
ACCOUNT_FILE="${ACCOUNT_FILE:-}"
IM_CONVERSATION_ID="${IM_CONVERSATION_ID:-}"
CONNECTIONS="${CONNECTIONS:-5000}"
LOCAL_DRIVER_SHARDS="${LOCAL_DRIVER_SHARDS:-5}"
MESSAGES="${MESSAGES:-0}"
SEND_INTERVAL_MS="${SEND_INTERVAL_MS:-0}"
MESSAGE_PROFILE="${MESSAGE_PROFILE:-per-connection}"
MESSAGE_RATE_PER_SECOND="${MESSAGE_RATE_PER_SECOND:-0}"
MESSAGE_SENDER_EVERY="${MESSAGE_SENDER_EVERY:-1}"
MESSAGE_RECEIVER_OFFSET="${MESSAGE_RECEIVER_OFFSET:-1}"
ACTIVE_CONVERSATION_USERS="${ACTIVE_CONVERSATION_USERS:-0}"
GLOBAL_HOLD_BARRIER_MIN_RATIO="${GLOBAL_HOLD_BARRIER_MIN_RATIO:-1.0}"
HOLD_SECONDS="${HOLD_SECONDS:-1800}"
CONNECT_RAMP_SECONDS="${CONNECT_RAMP_SECONDS:-900}"
LOGIN_CONCURRENCY="${LOGIN_CONCURRENCY:-5}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-30}"
HEARTBEAT_INTERVAL_SECONDS="${HEARTBEAT_INTERVAL_SECONDS:-15}"
HEARTBEAT_JITTER_SECONDS="${HEARTBEAT_JITTER_SECONDS:--1}"
HEARTBEAT_LOG_MODE="${HEARTBEAT_LOG_MODE:-errors}"
HEARTBEAT_LOG_SAMPLE_RATE="${HEARTBEAT_LOG_SAMPLE_RATE:-100}"
CONNECTION_QUEUE_POOL_SIZE="${CONNECTION_QUEUE_POOL_SIZE:-256}"
MAX_RECONNECTS="${MAX_RECONNECTS:-3}"
RECONNECT_DELAY_MS="${RECONNECT_DELAY_MS:-1000}"
LOGIN_RETRIES="${LOGIN_RETRIES:-2}"
LOGIN_RETRY_DELAY_MS="${LOGIN_RETRY_DELAY_MS:-1000}"
LOGIN_MODE="${LOGIN_MODE:-upfront}"
LOGIN_CACHE_DIR="${LOGIN_CACHE_DIR:-/tmp/imtcp-login-cache-local-shards}"
LOGIN_CACHE_TTL_GUARD_SECONDS="${LOGIN_CACHE_TTL_GUARD_SECONDS:-60}"
CONNECTION_LOG_DIR="${CONNECTION_LOG_DIR:-/tmp/imtcp-driver-logs-local-shards}"
PROTOCOL_VERSION="${PROTOCOL_VERSION:-$(default_protocol_version)}"
SSH_HOST="${SSH_HOST:-}"
PREWARM_LOGIN_CACHE="${PREWARM_LOGIN_CACHE:-true}"
SAMPLE_DURING_SECONDS="${SAMPLE_DURING_SECONDS:-60}"
LOCAL_SHARDS_DRY_RUN="${LOCAL_SHARDS_DRY_RUN:-false}"

if [[ -z "${IM_CONVERSATION_ID}" ]]; then
  echo "IM_CONVERSATION_ID is required." >&2
  exit 1
fi
if [[ -z "${ACCOUNT_FILE}" ]]; then
  echo "ACCOUNT_FILE is required for local sharded capacity runs." >&2
  exit 1
fi
if (( CONNECTIONS < 1 || LOCAL_DRIVER_SHARDS < 1 )); then
  echo "CONNECTIONS and LOCAL_DRIVER_SHARDS must be positive." >&2
  exit 1
fi
if (( LOCAL_DRIVER_SHARDS > CONNECTIONS )); then
  echo "LOCAL_DRIVER_SHARDS must be <= CONNECTIONS so every shard owns at least one connection." >&2
  exit 1
fi

bool_enabled() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "${value}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

jsonl_count() {
  local event="$1"
  local file="$2"
  if [[ ! -f "${file}" ]]; then
    echo 0
    return
  fi
  grep -c "\"event\":\"${event}\"" "${file}" || true
}

collect_remote_metrics() {
  local label="$1"
  if [[ -z "${SSH_HOST}" ]]; then
    return
  fi

  echo "== remote metrics: ${label} =="
  ssh "${SSH_HOST}" 'bash -s' <<'REMOTE' || true
set -euo pipefail
echo "-- memory --"
free -m
echo "-- tcp established on 9000 --"
ss -tan state established "( sport = :9000 )" | wc -l
echo "-- services --"
systemctl is-active imserver-gateway imserver-command-api imserver-outbox-relay imserver-stream-consumer imserver-domain-delivery-consumer
REMOTE
}

IM_TCP_CAPACITY_LADDER_SOURCE_ONLY=true source "${SCRIPT_DIR}/tcp_capacity_ladder.sh"
unset IM_TCP_CAPACITY_LADDER_SOURCE_ONLY

make_shard_file() {
  local shard_index="$1"
  local offset="$2"
  local limit="$3"
  local shard_file="${TMPDIR:-/tmp}/imtcp-local-shard-${CONNECTIONS}-${LOCAL_DRIVER_SHARDS}-${shard_index}.csv"
  grep -v '^[[:space:]]*#' "${ACCOUNT_FILE}" \
    | sed '/^[[:space:]]*$/d' \
    | awk -v offset="${offset}" -v limit="${limit}" 'NR > offset && NR <= offset + limit { print }' >"${shard_file}"
  local shard_count
  shard_count="$(wc -l <"${shard_file}" | tr -d ' ')"
  if (( shard_count < limit )); then
    echo "Shard ${shard_index} has ${shard_count} account rows, expected ${limit}." >&2
    exit 1
  fi
  echo "${shard_file}"
}

driver_common_args() {
  local shard_connections="$1"
  local shard_account_file="$2"
  printf '%s\n' \
    --profile custom \
    --base-url "${BASE_URL}" \
    --tcp-host "${TCP_HOST}" \
    --tcp-port "${TCP_PORT}" \
    --email "${IM_EMAIL}" \
    --password "${IM_PASSWORD}" \
    --conversation-id "${IM_CONVERSATION_ID}" \
    --connections "${shard_connections}" \
    --devices-per-user "${shard_connections}" \
    --messages "${MESSAGES}" \
    --send-interval-ms "${SEND_INTERVAL_MS}" \
    --message-profile "${MESSAGE_PROFILE}" \
    --message-rate-per-second "${MESSAGE_RATE_PER_SECOND}" \
    --message-sender-every "${MESSAGE_SENDER_EVERY}" \
    --message-receiver-offset "${MESSAGE_RECEIVER_OFFSET}" \
    --active-conversation-users "${ACTIVE_CONVERSATION_USERS}" \
    --global-hold-barrier-min-ratio "${GLOBAL_HOLD_BARRIER_MIN_RATIO}" \
    --hold-seconds "${HOLD_SECONDS}" \
    --connect-ramp-seconds "${CONNECT_RAMP_SECONDS}" \
    --login-concurrency "${LOGIN_CONCURRENCY}" \
    --timeout-seconds "${TIMEOUT_SECONDS}" \
    --protocol-version "${PROTOCOL_VERSION}" \
    --heartbeat-interval-seconds "${HEARTBEAT_INTERVAL_SECONDS}" \
    --heartbeat-jitter-seconds "${HEARTBEAT_JITTER_SECONDS}" \
    --heartbeat-log-mode "${HEARTBEAT_LOG_MODE}" \
    --heartbeat-log-sample-rate "${HEARTBEAT_LOG_SAMPLE_RATE}" \
    --connection-queue-pool-size "${CONNECTION_QUEUE_POOL_SIZE}" \
    --max-reconnects "${MAX_RECONNECTS}" \
    --reconnect-delay-ms "${RECONNECT_DELAY_MS}" \
    --login-retries "${LOGIN_RETRIES}" \
    --login-retry-delay-ms "${LOGIN_RETRY_DELAY_MS}" \
    --login-mode "${LOGIN_MODE}" \
    --login-cache-ttl-guard-seconds "${LOGIN_CACHE_TTL_GUARD_SECONDS}" \
    --account-file "${shard_account_file}"
}

base_connections=$(( CONNECTIONS / LOCAL_DRIVER_SHARDS ))
remainder=$(( CONNECTIONS % LOCAL_DRIVER_SHARDS ))
offset=0

shard_connection_counts=()
shard_account_files=()
shard_cache_files=()
shard_log_files=()
shard_stdout_files=()

for shard in $(seq 1 "${LOCAL_DRIVER_SHARDS}"); do
  shard_connections="${base_connections}"
  if (( shard <= remainder )); then
    shard_connections=$(( shard_connections + 1 ))
  fi
  shard_account_file="$(make_shard_file "${shard}" "${offset}" "${shard_connections}")"
  offset=$(( offset + shard_connections ))

  shard_connection_counts+=("${shard_connections}")
  shard_account_files+=("${shard_account_file}")
  shard_cache_files+=("${LOGIN_CACHE_DIR}/tcp-login-cache-local-shard-${shard}-of-${LOCAL_DRIVER_SHARDS}.json")
  shard_log_files+=("${CONNECTION_LOG_DIR}/tcp-driver-local-shard-${shard}-of-${LOCAL_DRIVER_SHARDS}.jsonl")
  shard_stdout_files+=("${CONNECTION_LOG_DIR}/tcp-driver-local-shard-${shard}-of-${LOCAL_DRIVER_SHARDS}.stdout")
done

if bool_enabled "${LOCAL_SHARDS_DRY_RUN}"; then
  for index in "${!shard_connection_counts[@]}"; do
    shard=$(( index + 1 ))
    echo "dry-run local-shard ${shard}/${LOCAL_DRIVER_SHARDS}: connections=${shard_connection_counts[$index]} cacheFile=${shard_cache_files[$index]} logFile=${shard_log_files[$index]}"
    driver_common_args "${shard_connection_counts[$index]}" "${shard_account_files[$index]}" | sed 's/^/  /'
  done
  exit 0
fi

validate_im_metrics_gate_runtime_config "local-shards preflight"
step_metrics_before="$(mktemp "${TMPDIR:-/tmp}/im-local-shards-metrics-before.XXXXXX")"
step_metrics_after="$(mktemp "${TMPDIR:-/tmp}/im-local-shards-metrics-after.XXXXXX")"

echo "Building TCP load driver..."
swift build -c release --package-path "${TCP_DRIVER_DIR}"

mkdir -p "${LOGIN_CACHE_DIR}" "${CONNECTION_LOG_DIR}"
capture_remote_im_metrics "${step_metrics_before}"
collect_remote_metrics "before local-shards"

if bool_enabled "${PREWARM_LOGIN_CACHE}"; then
  for index in "${!shard_connection_counts[@]}"; do
    shard=$(( index + 1 ))
    echo "Prewarming shard ${shard}/${LOCAL_DRIVER_SHARDS}: connections=${shard_connection_counts[$index]}"
    common_args=()
    while IFS= read -r arg; do
      common_args+=("${arg}")
    done < <(driver_common_args "${shard_connection_counts[$index]}" "${shard_account_files[$index]}")
    "${TCP_DRIVER_DIR}/.build/release/IMTCPLoadDriver" \
      "${common_args[@]}" \
      --login-cache-file "${shard_cache_files[$index]}" \
      --connection-log-file "${CONNECTION_LOG_DIR}/tcp-driver-prewarm-local-shard-${shard}-of-${LOCAL_DRIVER_SHARDS}.jsonl" \
      --login-only true
  done
fi

pids=()
for index in "${!shard_connection_counts[@]}"; do
  shard=$(( index + 1 ))
  echo "Starting shard ${shard}/${LOCAL_DRIVER_SHARDS}: connections=${shard_connection_counts[$index]}"
  common_args=()
  while IFS= read -r arg; do
    common_args+=("${arg}")
  done < <(driver_common_args "${shard_connection_counts[$index]}" "${shard_account_files[$index]}")
  "${TCP_DRIVER_DIR}/.build/release/IMTCPLoadDriver" \
    "${common_args[@]}" \
    --login-cache-file "${shard_cache_files[$index]}" \
    --require-login-cache true \
    --login-mode upfront \
    --connection-log-file "${shard_log_files[$index]}" \
    >"${shard_stdout_files[$index]}" 2>&1 &
  pids+=("$!")
done

sampler_pid=""
if [[ -n "${SSH_HOST}" && "${SAMPLE_DURING_SECONDS}" != "0" ]]; then
  (
    while true; do
      any_running=0
      for pid in "${pids[@]}"; do
        if kill -0 "${pid}" 2>/dev/null; then
          any_running=1
          break
        fi
      done
      if [[ "${any_running}" == "0" ]]; then
        break
      fi
      sleep "${SAMPLE_DURING_SECONDS}"
      collect_remote_metrics "during local-shards"
    done
  ) &
  sampler_pid="$!"
fi

exit_code=0
for index in "${!pids[@]}"; do
  shard=$(( index + 1 ))
  if ! wait "${pids[$index]}"; then
    echo "Shard ${shard} process failed. See ${shard_stdout_files[$index]}" >&2
    exit_code=1
  fi
done
if [[ -n "${sampler_pid}" ]]; then
  kill "${sampler_pid}" 2>/dev/null || true
  wait "${sampler_pid}" 2>/dev/null || true
fi

total_successes=0
total_expected=0
for index in "${!shard_connection_counts[@]}"; do
  shard=$(( index + 1 ))
  stdout_file="${shard_stdout_files[$index]}"
  log_file="${shard_log_files[$index]}"
  expected="${shard_connection_counts[$index]}"
  total_expected=$(( total_expected + expected ))

  echo
  echo "== shard ${shard}/${LOCAL_DRIVER_SHARDS} stdout =="
  cat "${stdout_file}"

  if [[ "$(jsonl_count "login_cache_hit" "${log_file}")" == "0" ]]; then
    echo "Shard ${shard} missing login_cache_hit." >&2
    exit_code=1
  fi
  if [[ "$(jsonl_count "login_start" "${log_file}")" != "0" ]]; then
    echo "Shard ${shard} unexpectedly performed HTTP login in formal run." >&2
    exit_code=1
  fi

  successes="$(sed -n 's/.*successes=\([0-9][0-9]*\).*/\1/p' "${stdout_file}" | head -1)"
  successes="${successes:-0}"
  total_successes=$(( total_successes + successes ))
  if (( successes != expected )); then
    echo "Shard ${shard} did not reach target: successes=${successes}, expected=${expected}" >&2
    exit_code=1
  fi
done

collect_remote_metrics "after local-shards"
capture_remote_im_metrics "${step_metrics_after}"
print_im_metrics_delta "${step_metrics_before}" "${step_metrics_after}" "local-shards"
print_timeline_read_latency_summary "${step_metrics_before}" "${step_metrics_after}" "local-shards"
print_stream_batch_fill_summary "${step_metrics_before}" "${step_metrics_after}" "local-shards"
if ! evaluate_im_metrics_gate "${step_metrics_before}" "${step_metrics_after}" "local-shards"; then
  exit_code=1
fi
rm -f "${step_metrics_before}" "${step_metrics_after}"
echo
echo "localShards=${LOCAL_DRIVER_SHARDS} totalSuccesses=${total_successes} totalExpected=${total_expected}"
exit "${exit_code}"
