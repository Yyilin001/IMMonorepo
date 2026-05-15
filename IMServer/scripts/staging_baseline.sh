#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="staging-baseline"
ENV_FILE=""
RUN_HTTP="true"
RUN_TCP="true"

usage() {
  cat <<'USAGE'
Usage: staging_baseline.sh [--profile local-smoke|staging-baseline|capacity-target] [--env-file path] [--skip-http] [--skip-tcp]

Required for HTTP:
  BASE_URL, IM_EMAIL, IM_PASSWORD, IM_MEMBER_EMAILS

Required for TCP:
  BASE_URL, TCP_HOST, TCP_PORT, IM_EMAIL, IM_PASSWORD, IM_CONVERSATION_ID
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

if [[ -n "${ENV_FILE}" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set +a
fi

REPORT_DIR="${ROOT_DIR}/reports"
REPORT_FILE="${REPORT_DIR}/$(date -u +%Y%m%dT%H%M%SZ)-staging-baseline.md"
mkdir -p "${REPORT_DIR}"

BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
TCP_HOST="${TCP_HOST:-127.0.0.1}"
TCP_PORT="${TCP_PORT:-9001}"

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
  (
    cd "${ROOT_DIR}/LoadTests/TCPDriver"
    swift run IMTCPLoadDriver \
      --profile "${PROFILE}" \
      --base-url "${BASE_URL}" \
      --tcp-host "${TCP_HOST}" \
      --tcp-port "${TCP_PORT}" \
      --email "${IM_EMAIL:?IM_EMAIL is required}" \
      --password "${IM_PASSWORD:?IM_PASSWORD is required}" \
      --conversation-id "${IM_CONVERSATION_ID}"
  ) | tee "${REPORT_DIR}/staging-baseline-tcp.log"
  {
    echo
    echo "## TCPDriver"
    echo
    echo "- log: staging-baseline-tcp.log"
  } >> "${REPORT_FILE}"
fi

cat <<'EOF' >> "${REPORT_FILE}"

## Go/No-Go Checklist

- HTTP/TCP error rate < 0.1%: TODO
- message write P95/P99 meets runbook thresholds: TODO
- conversations/changes convergence P95 < 2s: TODO
- outbox backlog returns to zero or continuously drains after load stops: TODO
- reconnect messages/since success > 99.9%: TODO
EOF

echo "Staging baseline report: ${REPORT_FILE}"
