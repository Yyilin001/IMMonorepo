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
HOLD_SECONDS="${HOLD_SECONDS:-0}"
CONNECT_RAMP_SECONDS="${CONNECT_RAMP_SECONDS:-0}"
LOGIN_CONCURRENCY="${LOGIN_CONCURRENCY:-5}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-30}"
HEARTBEAT_INTERVAL_SECONDS="${HEARTBEAT_INTERVAL_SECONDS:-0}"
CONNECTION_QUEUE_POOL_SIZE="${CONNECTION_QUEUE_POOL_SIZE:-256}"
MAX_RECONNECTS="${MAX_RECONNECTS:-0}"
RECONNECT_DELAY_MS="${RECONNECT_DELAY_MS:-1000}"
LOGIN_RETRIES="${LOGIN_RETRIES:-2}"
LOGIN_RETRY_DELAY_MS="${LOGIN_RETRY_DELAY_MS:-1000}"
LOGIN_MODE="${LOGIN_MODE:-upfront}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-15}"
SAMPLE_DURING_SECONDS="${SAMPLE_DURING_SECONDS:-15}"
PROTOCOL_VERSION="${PROTOCOL_VERSION:-9}"
SSH_HOST="${SSH_HOST:-}"
CONNECTION_LOG_DIR="${CONNECTION_LOG_DIR:-}"

if [[ -z "${IM_CONVERSATION_ID}" ]]; then
  echo "IM_CONVERSATION_ID is required." >&2
  exit 1
fi

collect_remote_metrics() {
  local label="$1"
  if [[ -z "${SSH_HOST}" ]]; then
    return
  fi

  echo "== remote metrics: ${label} =="
  ssh "${SSH_HOST}" 'bash -s' <<'REMOTE'
set -euo pipefail
echo "-- memory --"
free -m
echo "-- tcp established on 9000 --"
ss -tan state established "( sport = :9000 )" | wc -l
echo "-- services --"
systemctl is-active imserver-gateway imserver-outbox-relay imserver-stream-consumer imserver-domain-delivery-consumer
echo "-- domain delivery lag --"
/opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server 127.0.0.1:9092 --describe --group domain-delivery-consumer || true
echo "-- summary projection lag --"
/opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server 127.0.0.1:9092 --describe --group summary-projection-consumer || true
REMOTE
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
    --hold-seconds "${HOLD_SECONDS}"
    --connect-ramp-seconds "${CONNECT_RAMP_SECONDS}"
    --login-concurrency "${LOGIN_CONCURRENCY}"
    --timeout-seconds "${TIMEOUT_SECONDS}"
    --protocol-version "${PROTOCOL_VERSION}"
    --heartbeat-interval-seconds "${HEARTBEAT_INTERVAL_SECONDS}"
    --connection-queue-pool-size "${CONNECTION_QUEUE_POOL_SIZE}"
    --max-reconnects "${MAX_RECONNECTS}"
    --reconnect-delay-ms "${RECONNECT_DELAY_MS}"
    --login-retries "${LOGIN_RETRIES}"
    --login-retry-delay-ms "${LOGIN_RETRY_DELAY_MS}"
    --login-mode "${LOGIN_MODE}"
  )
  if [[ -n "${ACCOUNT_FILE}" ]]; then
    driver_args+=(--account-file "${ACCOUNT_FILE}")
  fi
  if [[ -n "${CONNECTION_LOG_DIR}" ]]; then
    mkdir -p "${CONNECTION_LOG_DIR}"
    connection_log_file="${CONNECTION_LOG_DIR}/tcp-driver-${connections}.jsonl"
    driver_args+=(--connection-log-file "${connection_log_file}")
    echo "Connection lifecycle log: ${connection_log_file}"
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

  collect_remote_metrics "after ${connections}"

  if [[ "${COOLDOWN_SECONDS}" != "0" ]]; then
    echo "Cooling down for ${COOLDOWN_SECONDS}s..."
    sleep "${COOLDOWN_SECONDS}"
  fi
done
