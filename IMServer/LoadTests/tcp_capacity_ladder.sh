#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TCP_DRIVER_DIR="${SCRIPT_DIR}/TCPDriver"

BASE_URL="${BASE_URL:-http://120.25.106.200:8080}"
TCP_HOST="${TCP_HOST:-120.25.106.200}"
TCP_PORT="${TCP_PORT:-9000}"
IM_EMAIL="${IM_EMAIL:-demo@example.com}"
IM_PASSWORD="${IM_PASSWORD:-password1234}"
ACCOUNT_FILE="${ACCOUNT_FILE:-}"
IM_CONVERSATION_ID="${IM_CONVERSATION_ID:-}"
LADDER="${LADDER:-100 500 1000 2000 5000 10000}"
DEVICES_PER_USER="${DEVICES_PER_USER:-}"
MESSAGES="${MESSAGES:-1}"
SEND_INTERVAL_MS="${SEND_INTERVAL_MS:-0}"
MESSAGE_PROFILE="${MESSAGE_PROFILE:-per-connection}"
MESSAGE_RATE_PER_SECOND="${MESSAGE_RATE_PER_SECOND:-0}"
MESSAGE_SENDER_EVERY="${MESSAGE_SENDER_EVERY:-1}"
MESSAGE_RECEIVER_OFFSET="${MESSAGE_RECEIVER_OFFSET:-1}"
HOLD_SECONDS="${HOLD_SECONDS:-0}"
CONNECT_RAMP_SECONDS="${CONNECT_RAMP_SECONDS:-0}"
LOGIN_CONCURRENCY="${LOGIN_CONCURRENCY:-5}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-30}"
HEARTBEAT_INTERVAL_SECONDS="${HEARTBEAT_INTERVAL_SECONDS:-0}"
HEARTBEAT_JITTER_SECONDS="${HEARTBEAT_JITTER_SECONDS:--1}"
HEARTBEAT_LOG_MODE="${HEARTBEAT_LOG_MODE:-errors}"
HEARTBEAT_LOG_SAMPLE_RATE="${HEARTBEAT_LOG_SAMPLE_RATE:-100}"
CONNECTION_QUEUE_POOL_SIZE="${CONNECTION_QUEUE_POOL_SIZE:-256}"
MAX_RECONNECTS="${MAX_RECONNECTS:-0}"
RECONNECT_DELAY_MS="${RECONNECT_DELAY_MS:-1000}"
LOGIN_RETRIES="${LOGIN_RETRIES:-2}"
LOGIN_RETRY_DELAY_MS="${LOGIN_RETRY_DELAY_MS:-1000}"
LOGIN_MODE="${LOGIN_MODE:-upfront}"
LOGIN_CACHE_DIR="${LOGIN_CACHE_DIR:-/tmp/imtcp-login-cache}"
LOGIN_CACHE_FILE="${LOGIN_CACHE_FILE:-}"
PREWARM_LOGIN_CACHE="${PREWARM_LOGIN_CACHE:-auto}"
REQUIRE_LOGIN_CACHE="${REQUIRE_LOGIN_CACHE:-false}"
LOGIN_CACHE_TTL_GUARD_SECONDS="${LOGIN_CACHE_TTL_GUARD_SECONDS:-60}"
LOAD_GENERATOR_ID="${LOAD_GENERATOR_ID:-1}"
LOAD_GENERATOR_COUNT="${LOAD_GENERATOR_COUNT:-1}"
ACCOUNT_SHARD_OFFSET="${ACCOUNT_SHARD_OFFSET:-}"
ACCOUNT_SHARD_LIMIT="${ACCOUNT_SHARD_LIMIT:-}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-15}"
SAMPLE_DURING_SECONDS="${SAMPLE_DURING_SECONDS:-15}"
PROTOCOL_VERSION="${PROTOCOL_VERSION:-9}"
SSH_HOST="${SSH_HOST:-}"
CONNECTION_LOG_DIR="${CONNECTION_LOG_DIR:-}"
REMOTE_METRICS_TIMEOUT_SECONDS="${REMOTE_METRICS_TIMEOUT_SECONDS:-10}"
COLLECT_REMOTE_METRICS="${COLLECT_REMOTE_METRICS:-true}"

if [[ -z "${IM_CONVERSATION_ID}" ]]; then
  echo "IM_CONVERSATION_ID is required." >&2
  exit 1
fi

collect_remote_metrics() {
  local label="$1"
  if ! bool_enabled "${COLLECT_REMOTE_METRICS}"; then
    return
  fi
  if [[ -z "${SSH_HOST}" ]]; then
    return
  fi

  echo "== remote metrics: ${label} =="
  ssh "${SSH_HOST}" "REMOTE_METRICS_TIMEOUT_SECONDS='${REMOTE_METRICS_TIMEOUT_SECONDS}' bash -s" <<'REMOTE'
set -euo pipefail
run_with_timeout() {
  local seconds="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "${seconds}" "$@" || true
  else
    "$@" || true
  fi
}
echo "-- memory --"
free -m
echo "-- tcp established on 9000 --"
ss -tan state established "( sport = :9000 )" | wc -l
echo "-- services --"
systemctl is-active imserver-gateway imserver-outbox-relay imserver-stream-consumer imserver-domain-delivery-consumer
echo "-- domain delivery lag --"
run_with_timeout "${REMOTE_METRICS_TIMEOUT_SECONDS}" /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server 127.0.0.1:9092 --describe --group domain-delivery-consumer
echo "-- summary projection lag --"
run_with_timeout "${REMOTE_METRICS_TIMEOUT_SECONDS}" /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server 127.0.0.1:9092 --describe --group summary-projection-consumer
REMOTE
}

bool_enabled() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "${value}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

effective_prewarm_login_cache() {
  if [[ "${PREWARM_LOGIN_CACHE}" == "auto" ]]; then
    [[ "${MESSAGES}" == "0" ]]
    return
  fi
  bool_enabled "${PREWARM_LOGIN_CACHE}"
}

effective_require_login_cache() {
  bool_enabled "${REQUIRE_LOGIN_CACHE}"
}

login_cache_file_for_step() {
  local connections="$1"
  if [[ -n "${LOGIN_CACHE_FILE}" ]]; then
    echo "${LOGIN_CACHE_FILE}"
    return
  fi
  echo "${LOGIN_CACHE_DIR}/tcp-login-cache-lg${LOAD_GENERATOR_ID}-${connections}.json"
}

make_account_shard() {
  local connections="$1"
  if [[ -z "${ACCOUNT_FILE}" ]]; then
    return
  fi

  local total_accounts
  total_accounts="$(grep -v '^[[:space:]]*#' "${ACCOUNT_FILE}" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
  if [[ "${total_accounts}" -eq 0 ]]; then
    echo "ACCOUNT_FILE has no usable rows: ${ACCOUNT_FILE}" >&2
    exit 1
  fi

  local offset limit
  if [[ -n "${ACCOUNT_SHARD_OFFSET}" ]]; then
    offset="${ACCOUNT_SHARD_OFFSET}"
  else
    offset=$(( (LOAD_GENERATOR_ID - 1) * ((total_accounts + LOAD_GENERATOR_COUNT - 1) / LOAD_GENERATOR_COUNT) ))
  fi
  if [[ -n "${ACCOUNT_SHARD_LIMIT}" ]]; then
    limit="${ACCOUNT_SHARD_LIMIT}"
  else
    limit=$(( (total_accounts + LOAD_GENERATOR_COUNT - 1) / LOAD_GENERATOR_COUNT ))
  fi

  if (( offset < 0 || offset >= total_accounts )); then
    echo "Account shard offset is out of range: offset=${offset}, total=${total_accounts}" >&2
    exit 1
  fi
  if (( limit < connections )); then
    echo "Account shard limit ${limit} is smaller than connections ${connections}; increase ACCOUNT_SHARD_LIMIT or reduce this ladder step." >&2
    exit 1
  fi

  local shard_file="${TMPDIR:-/tmp}/imtcp-accounts-lg${LOAD_GENERATOR_ID}-of-${LOAD_GENERATOR_COUNT}-${offset}-${limit}.csv"
  grep -v '^[[:space:]]*#' "${ACCOUNT_FILE}" \
    | sed '/^[[:space:]]*$/d' \
    | awk -v offset="${offset}" -v limit="${limit}" 'NR > offset && NR <= offset + limit { print }' >"${shard_file}"

  local shard_count
  shard_count="$(wc -l <"${shard_file}" | tr -d ' ')"
  if (( shard_count < connections )); then
    echo "Account shard has ${shard_count} rows, smaller than connections ${connections}." >&2
    exit 1
  fi
  echo "${shard_file}"
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

ensure_login_cache_hit() {
  local file="$1"
  if [[ "$(jsonl_count "login_cache_hit" "${file}")" == "0" ]]; then
    echo "Expected login_cache_hit in ${file}; TCP online capacity run is invalid without cached login tokens." >&2
    exit 1
  fi
  if [[ "$(jsonl_count "login_start" "${file}")" != "0" ]]; then
    echo "Unexpected HTTP login_start in strict TCP online capacity run: ${file}" >&2
    exit 1
  fi
}

echo "Building TCP load driver..."
swift build -c release --package-path "${TCP_DRIVER_DIR}"

for connections in ${LADDER}; do
  if [[ -n "${DEVICES_PER_USER}" ]]; then
    devices_per_user="${DEVICES_PER_USER}"
  elif [[ "${MESSAGES}" == "0" ]]; then
    devices_per_user="${connections}"
  else
    devices_per_user="1"
  fi

  echo
  echo "== TCP ladder step: connections=${connections}, devices=${devices_per_user}, messages=${MESSAGES}, hold=${HOLD_SECONDS}s, ramp=${CONNECT_RAMP_SECONDS}s =="
  collect_remote_metrics "before ${connections}"

  step_account_file="${ACCOUNT_FILE}"
  if [[ -n "${ACCOUNT_FILE}" ]]; then
    step_account_file="$(make_account_shard "${connections}")"
    echo "Account shard: ${step_account_file}"
  fi

  effective_connection_log_dir="${CONNECTION_LOG_DIR}"
  if { effective_prewarm_login_cache || effective_require_login_cache; } && [[ -z "${effective_connection_log_dir}" ]]; then
    effective_connection_log_dir="/tmp/imtcp-driver-logs"
  fi

  driver_args=(
    --profile custom
    --base-url "${BASE_URL}"
    --tcp-host "${TCP_HOST}"
    --tcp-port "${TCP_PORT}"
    --email "${IM_EMAIL}"
    --password "${IM_PASSWORD}"
    --conversation-id "${IM_CONVERSATION_ID}"
    --connections "${connections}"
    --devices-per-user "${devices_per_user}"
    --messages "${MESSAGES}"
    --send-interval-ms "${SEND_INTERVAL_MS}"
    --message-profile "${MESSAGE_PROFILE}"
    --message-rate-per-second "${MESSAGE_RATE_PER_SECOND}"
    --message-sender-every "${MESSAGE_SENDER_EVERY}"
    --message-receiver-offset "${MESSAGE_RECEIVER_OFFSET}"
    --hold-seconds "${HOLD_SECONDS}"
    --connect-ramp-seconds "${CONNECT_RAMP_SECONDS}"
    --login-concurrency "${LOGIN_CONCURRENCY}"
    --timeout-seconds "${TIMEOUT_SECONDS}"
    --protocol-version "${PROTOCOL_VERSION}"
    --heartbeat-interval-seconds "${HEARTBEAT_INTERVAL_SECONDS}"
    --heartbeat-jitter-seconds "${HEARTBEAT_JITTER_SECONDS}"
    --heartbeat-log-mode "${HEARTBEAT_LOG_MODE}"
    --heartbeat-log-sample-rate "${HEARTBEAT_LOG_SAMPLE_RATE}"
    --connection-queue-pool-size "${CONNECTION_QUEUE_POOL_SIZE}"
    --max-reconnects "${MAX_RECONNECTS}"
    --reconnect-delay-ms "${RECONNECT_DELAY_MS}"
    --login-retries "${LOGIN_RETRIES}"
    --login-retry-delay-ms "${LOGIN_RETRY_DELAY_MS}"
    --login-mode "${LOGIN_MODE}"
    --login-cache-ttl-guard-seconds "${LOGIN_CACHE_TTL_GUARD_SECONDS}"
  )
  if [[ -n "${step_account_file}" ]]; then
    driver_args+=(--account-file "${step_account_file}")
  fi
  if [[ -n "${effective_connection_log_dir}" ]]; then
    mkdir -p "${effective_connection_log_dir}"
    connection_log_file="${effective_connection_log_dir}/tcp-driver-lg${LOAD_GENERATOR_ID}-${connections}.jsonl"
    driver_args+=(--connection-log-file "${connection_log_file}")
    echo "Connection lifecycle log: ${connection_log_file}"
  fi
  if effective_prewarm_login_cache; then
    mkdir -p "${LOGIN_CACHE_DIR}"
    login_cache_file="$(login_cache_file_for_step "${connections}")"
    prewarm_log_file="${effective_connection_log_dir:-/tmp}/tcp-driver-prewarm-lg${LOAD_GENERATOR_ID}-${connections}.jsonl"
    echo "Prewarming login cache: ${login_cache_file}"
    prewarm_args=(
      --profile custom
      --base-url "${BASE_URL}"
      --tcp-host "${TCP_HOST}"
      --tcp-port "${TCP_PORT}"
      --email "${IM_EMAIL}"
      --password "${IM_PASSWORD}"
      --conversation-id "${IM_CONVERSATION_ID}"
      --connections "${connections}"
      --devices-per-user "${devices_per_user}"
      --messages "0"
      --message-profile "per-connection"
      --message-rate-per-second "0"
      --hold-seconds "${HOLD_SECONDS}"
      --connect-ramp-seconds "${CONNECT_RAMP_SECONDS}"
      --login-concurrency "${LOGIN_CONCURRENCY}"
      --timeout-seconds "${TIMEOUT_SECONDS}"
      --protocol-version "${PROTOCOL_VERSION}"
      --login-retries "${LOGIN_RETRIES}"
      --login-retry-delay-ms "${LOGIN_RETRY_DELAY_MS}"
      --login-cache-ttl-guard-seconds "${LOGIN_CACHE_TTL_GUARD_SECONDS}"
      --login-cache-file "${login_cache_file}"
      --connection-log-file "${prewarm_log_file}"
      --login-only true
    )
    if [[ -n "${step_account_file}" ]]; then
      prewarm_args+=(--account-file "${step_account_file}")
    fi
    "${TCP_DRIVER_DIR}/.build/release/IMTCPLoadDriver" "${prewarm_args[@]}"

    driver_args+=(
      --login-cache-file "${login_cache_file}"
      --require-login-cache true
      --login-mode upfront
    )
  elif [[ -n "${LOGIN_CACHE_FILE}" ]] || effective_require_login_cache; then
    login_cache_file="$(login_cache_file_for_step "${connections}")"
    echo "Using login cache: ${login_cache_file}"
    driver_args+=(
      --login-cache-file "${login_cache_file}"
      --login-mode upfront
    )
    if effective_require_login_cache; then
      driver_args+=(--require-login-cache true)
    fi
  fi

  "${TCP_DRIVER_DIR}/.build/release/IMTCPLoadDriver" "${driver_args[@]}" &
  driver_pid="$!"

  sampler_pid=""
  if [[ -n "${SSH_HOST}" && "${SAMPLE_DURING_SECONDS}" != "0" ]]; then
    (
      while kill -0 "${driver_pid}" 2>/dev/null; do
        sleep "${SAMPLE_DURING_SECONDS}"
        if kill -0 "${driver_pid}" 2>/dev/null; then
          collect_remote_metrics "during ${connections}"
        fi
      done
    ) &
    sampler_pid="$!"
  fi

  if ! wait "${driver_pid}"; then
    if [[ -n "${sampler_pid}" ]]; then
      kill "${sampler_pid}" 2>/dev/null || true
    fi
    exit 1
  fi
  if [[ -n "${sampler_pid}" ]]; then
    kill "${sampler_pid}" 2>/dev/null || true
    wait "${sampler_pid}" 2>/dev/null || true
  fi

  if effective_prewarm_login_cache || effective_require_login_cache; then
    ensure_login_cache_hit "${connection_log_file}"
  fi

  collect_remote_metrics "after ${connections}"

  if [[ "${COOLDOWN_SECONDS}" != "0" ]]; then
    echo "Cooling down for ${COOLDOWN_SECONDS}s..."
    sleep "${COOLDOWN_SECONDS}"
  fi
done
