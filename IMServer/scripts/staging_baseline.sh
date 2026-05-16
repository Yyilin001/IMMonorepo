#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="staging-baseline"
ENV_FILE=""
RUN_HTTP="true"
RUN_TCP="true"
TCP_CONNECTIONS=""
TCP_DEVICES_PER_USER=""
TCP_MESSAGES=""
TCP_SEND_INTERVAL_MS=""

usage() {
  cat <<'USAGE'
Usage: staging_baseline.sh [--profile local-smoke|staging-baseline|capacity-target] [--env-file path] [--skip-http] [--skip-tcp]
                           [--tcp-connections n] [--tcp-devices-per-user n] [--tcp-messages n] [--tcp-send-interval-ms n]

Required for HTTP:
  BASE_URL, IM_EMAIL, IM_PASSWORD, IM_MEMBER_EMAILS

Required for TCP:
  BASE_URL, TCP_HOST, TCP_PORT, IM_EMAIL, IM_PASSWORD, IM_CONVERSATION_ID

Useful multi-device TCP scenarios:
  1 user x 5 devices:        --profile local-smoke --tcp-connections 5 --tcp-devices-per-user 5 --tcp-messages 1
  100 users x 2 devices:     pair this script with k6 HTTP user load and TCP --tcp-devices-per-user 2
  reconnect/logout storms:   run against staging while externally restarting gateway or calling logout-all
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      PROFILE="${2:?missing --profile value}"
      shift 2
      ;;
    --env-file)
      ENV_FILE="${2:?missing --env-file value}"
      shift 2
      ;;
    --skip-http)
      RUN_HTTP="false"
      shift
      ;;
    --skip-tcp)
      RUN_TCP="false"
      shift
      ;;
    --tcp-connections)
      TCP_CONNECTIONS="${2:?missing --tcp-connections value}"
      shift 2
      ;;
    --tcp-devices-per-user)
      TCP_DEVICES_PER_USER="${2:?missing --tcp-devices-per-user value}"
      shift 2
      ;;
    --tcp-messages)
      TCP_MESSAGES="${2:?missing --tcp-messages value}"
      shift 2
      ;;
    --tcp-send-interval-ms)
      TCP_SEND_INTERVAL_MS="${2:?missing --tcp-send-interval-ms value}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

CLI_TCP_CONNECTIONS="${TCP_CONNECTIONS}"
CLI_TCP_DEVICES_PER_USER="${TCP_DEVICES_PER_USER}"
CLI_TCP_MESSAGES="${TCP_MESSAGES}"
CLI_TCP_SEND_INTERVAL_MS="${TCP_SEND_INTERVAL_MS}"

if [[ -n "${ENV_FILE}" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set +a
fi

[[ -n "${CLI_TCP_CONNECTIONS}" ]] && TCP_CONNECTIONS="${CLI_TCP_CONNECTIONS}"
[[ -n "${CLI_TCP_DEVICES_PER_USER}" ]] && TCP_DEVICES_PER_USER="${CLI_TCP_DEVICES_PER_USER}"
[[ -n "${CLI_TCP_MESSAGES}" ]] && TCP_MESSAGES="${CLI_TCP_MESSAGES}"
[[ -n "${CLI_TCP_SEND_INTERVAL_MS}" ]] && TCP_SEND_INTERVAL_MS="${CLI_TCP_SEND_INTERVAL_MS}"

REPORT_DIR="${ROOT_DIR}/reports"
REPORT_FILE="${REPORT_DIR}/$(date -u +%Y%m%dT%H%M%SZ)-staging-baseline.md"
mkdir -p "${REPORT_DIR}"

BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
TCP_HOST="${TCP_HOST:-127.0.0.1}"
TCP_PORT="${TCP_PORT:-9001}"
TCP_CONNECTIONS="${TCP_CONNECTIONS:-}"
TCP_DEVICES_PER_USER="${TCP_DEVICES_PER_USER:-}"
TCP_MESSAGES="${TCP_MESSAGES:-}"
TCP_SEND_INTERVAL_MS="${TCP_SEND_INTERVAL_MS:-}"

if [[ "${RUN_HTTP}" == "true" ]]; then
  command -v k6 >/dev/null 2>&1 || {
    echo "k6 is required for HTTP baseline. Install k6 or pass --skip-http." >&2
    exit 127
  }
fi

if [[ "${RUN_TCP}" == "true" ]]; then
  command -v swift >/dev/null 2>&1 || {
    echo "Swift is required for TCPDriver. Install Swift or pass --skip-tcp." >&2
    exit 127
  }
  : "${IM_CONVERSATION_ID:?IM_CONVERSATION_ID is required for TCP baseline}"
fi

{
  echo "# IMServer staging baseline report"
  echo
  echo "- generated_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- profile: ${PROFILE}"
  echo "- base_url: ${BASE_URL}"
  echo "- tcp_host: ${TCP_HOST}"
  echo "- tcp_port: ${TCP_PORT}"
  echo "- tcp_connections: ${TCP_CONNECTIONS:-profile-default}"
  echo "- tcp_devices_per_user: ${TCP_DEVICES_PER_USER:-profile-default}"
  echo "- tcp_messages: ${TCP_MESSAGES:-profile-default}"
  echo
} > "${REPORT_FILE}"

if [[ "${RUN_HTTP}" == "true" ]]; then
  echo "Running k6 HTTP profile=${PROFILE}"
  (
    cd "${ROOT_DIR}/LoadTests/k6"
    PROFILE="${PROFILE}" BASE_URL="${BASE_URL}" k6 run http-small-group.js
  ) | tee "${REPORT_DIR}/staging-baseline-k6.log"
  {
    echo "## HTTP k6"
    echo
    echo "- log: staging-baseline-k6.log"
  } >> "${REPORT_FILE}"
fi

if [[ "${RUN_TCP}" == "true" ]]; then
  echo "Running Swift TCPDriver profile=${PROFILE}"
  TCP_ARGS=(
    --profile "${PROFILE}"
    --base-url "${BASE_URL}"
    --tcp-host "${TCP_HOST}"
    --tcp-port "${TCP_PORT}"
    --email "${IM_EMAIL:?IM_EMAIL is required}"
    --password "${IM_PASSWORD:?IM_PASSWORD is required}"
    --conversation-id "${IM_CONVERSATION_ID}"
  )
  [[ -n "${TCP_CONNECTIONS}" ]] && TCP_ARGS+=(--connections "${TCP_CONNECTIONS}")
  [[ -n "${TCP_DEVICES_PER_USER}" ]] && TCP_ARGS+=(--devices-per-user "${TCP_DEVICES_PER_USER}")
  [[ -n "${TCP_MESSAGES}" ]] && TCP_ARGS+=(--messages "${TCP_MESSAGES}")
  [[ -n "${TCP_SEND_INTERVAL_MS}" ]] && TCP_ARGS+=(--send-interval-ms "${TCP_SEND_INTERVAL_MS}")
  (
    cd "${ROOT_DIR}/LoadTests/TCPDriver"
    swift run IMTCPLoadDriver "${TCP_ARGS[@]}"
  ) | tee "${REPORT_DIR}/staging-baseline-tcp.log"
  {
    echo
    echo "## TCPDriver"
    echo
    echo "- log: staging-baseline-tcp.log"
    echo "- devices_per_user: ${TCP_DEVICES_PER_USER:-profile-default}"
  } >> "${REPORT_FILE}"
fi

cat <<'EOF' >> "${REPORT_FILE}"

## Go/No-Go Checklist

- HTTP/TCP error rate < 0.1%: TODO
- TCP ack success rate >= 99.9%: TODO
- TCP canonical message success rate >= 99.9%: TODO
- no duplicate canonical messages by clientMessageID in client-side sample: TODO
- message write P95/P99 meets runbook thresholds: TODO
- conversations/changes convergence P95 < 2s: TODO
- outbox backlog returns to zero or continuously drains after load stops: TODO
- reconnect messages/since success > 99.9%: TODO
- session-count relay failures stay at 0: TODO
- cross-node dispatch failures stay at 0: TODO
EOF

echo "Staging baseline report: ${REPORT_FILE}"
