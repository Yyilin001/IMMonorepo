#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="staging-baseline"
ENV_FILE=""
RUN_HTTP="true"
RUN_TCP="true"
REQUIRE_ACCEPTANCE="false"
TCP_CONNECTIONS=""
TCP_DEVICES_PER_USER=""
TCP_MESSAGES=""
TCP_SEND_INTERVAL_MS=""

usage() {
  cat <<'USAGE'
Usage: staging_baseline.sh [--profile local-smoke|staging-baseline|capacity-target] [--env-file path] [--skip-http] [--skip-tcp] [--require-acceptance]
                           [--tcp-connections n] [--tcp-devices-per-user n] [--tcp-messages n] [--tcp-send-interval-ms n]

Required for HTTP:
  BASE_URL, IM_EMAIL, IM_PASSWORD, IM_MEMBER_EMAILS

Required for TCP:
  BASE_URL, TCP_HOST, TCP_PORT, IM_EMAIL, IM_PASSWORD, IM_CONVERSATION_ID

Useful multi-device TCP scenarios:
  1 user x 5 devices:        --profile local-smoke --tcp-connections 5 --tcp-devices-per-user 5 --tcp-messages 1
  100 users x 2 devices:     pair this script with k6 HTTP user load and TCP --tcp-devices-per-user 2
  1 group x 500 x 2 devices: set IM_GROUP_CONVERSATION_ID and TCP_GROUP_* env vars for the large group run
  AI stream concurrency:      expose /internal/metrics and set IM_AI_STREAM_ACCEPTANCE=true after external AI load
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
    --require-acceptance)
      REQUIRE_ACCEPTANCE="true"
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
METRICS_URL="${IM_METRICS_URL:-${BASE_URL}/internal/metrics}"
METRICS_SECRET="${IM_METRICS_INTERNAL_SECRET:-${IM_INTERNAL_SHARED_SECRET:-}}"

case "${PROFILE}" in
  local-smoke)
    DEFAULT_100_USERS_CONNECTIONS=10
    DEFAULT_GROUP_CONNECTIONS=20
    ;;
  capacity-target)
    DEFAULT_100_USERS_CONNECTIONS=2000
    DEFAULT_GROUP_CONNECTIONS=50000
    ;;
  *)
    DEFAULT_100_USERS_CONNECTIONS=200
    DEFAULT_GROUP_CONNECTIONS=1000
    ;;
esac

failures=()

record_failure() {
  failures+=("$1")
  echo "ACCEPTANCE FAILURE: $1" >&2
}

metric_value() {
  local name="$1"
  local file="$2"
  awk -v metric="${name}" '$1 == metric { value=$2 } END { if (value != "") print value; else print "0" }' "${file}"
}

capture_metrics() {
  local label="$1"
  local output_file="${REPORT_DIR}/${label}.prom"
  local curl_args=(-fsS "${METRICS_URL}")
  [[ -n "${METRICS_SECRET}" ]] && curl_args=(-fsS -H "X-IM-Metrics-Secret: ${METRICS_SECRET}" "${METRICS_URL}")
  if command -v curl >/dev/null 2>&1 && curl "${curl_args[@]}" > "${output_file}"; then
    echo "${output_file}"
  else
    echo ""
  fi
}

append_metrics_summary() {
  local label="$1"
  local file="$2"
  {
    echo
    echo "## Metrics ${label}"
    echo
    if [[ -z "${file}" ]]; then
      echo "- status: skipped"
      echo "- reason: metrics endpoint unavailable"
    else
      echo "- file: $(basename "${file}")"
      echo
      echo '```text'
      grep -E '^(im_tcp_connections|im_outbox_backlog_events|im_cross_node_dispatch_failures_total|im_session_count_query_failures_total|im_redis_presence_stale_cleanup_total|im_ai_stream_|im_stream_failed_events_total)' "${file}" || true
      echo '```'
    fi
  } >> "${REPORT_FILE}"
}

run_tcp_scenario() {
  local label="$1"
  local conversation_id="$2"
  local connections="$3"
  local devices_per_user="$4"
  local messages="$5"
  local send_interval_ms="$6"
  local log_file="${REPORT_DIR}/staging-baseline-tcp-${label}.log"

  echo "Running TCP scenario ${label}"
  TCP_ARGS=(
    --profile "${PROFILE}"
    --base-url "${BASE_URL}"
    --tcp-host "${TCP_HOST}"
    --tcp-port "${TCP_PORT}"
    --email "${IM_EMAIL:?IM_EMAIL is required}"
    --password "${IM_PASSWORD:?IM_PASSWORD is required}"
    --conversation-id "${conversation_id}"
    --connections "${connections}"
    --devices-per-user "${devices_per_user}"
    --messages "${messages}"
  )
  [[ -n "${send_interval_ms}" ]] && TCP_ARGS+=(--send-interval-ms "${send_interval_ms}")
  (
    cd "${ROOT_DIR}/LoadTests/TCPDriver"
    swift run IMTCPLoadDriver "${TCP_ARGS[@]}"
  ) | tee "${log_file}"

  local ack_rate canonical_rate reconnect_count
  ack_rate="$(grep -Eo 'ackSuccessRate=[0-9.]+' "${log_file}" | tail -1 | cut -d= -f2)"
  canonical_rate="$(grep -Eo 'canonicalSuccessRate=[0-9.]+' "${log_file}" | tail -1 | cut -d= -f2)"
  reconnect_count="$(grep -Eo 'reconnects=[0-9]+' "${log_file}" | tail -1 | cut -d= -f2)"
  {
    echo
    echo "## TCPDriver ${label}"
    echo
    echo "- log: $(basename "${log_file}")"
    echo "- connections: ${connections}"
    echo "- devices_per_user: ${devices_per_user}"
    echo "- messages: ${messages}"
    echo "- ack_success_rate: ${ack_rate:-unknown}"
    echo "- canonical_success_rate: ${canonical_rate:-unknown}"
    echo "- reconnect_count: ${reconnect_count:-unknown}"
    echo
    echo '```text'
    tail -n 8 "${log_file}"
    echo '```'
  } >> "${REPORT_FILE}"

  if [[ "${REQUIRE_ACCEPTANCE}" == "true" ]]; then
    awk -v value="${ack_rate:-0}" 'BEGIN { exit(value >= 0.999 ? 0 : 1) }' || record_failure "${label}: TCP ack success rate below 99.9%"
    awk -v value="${canonical_rate:-0}" 'BEGIN { exit(value >= 0.999 ? 0 : 1) }' || record_failure "${label}: TCP canonical success rate below 99.9%"
    grep -q 'serverErrors=0' "${log_file}" || record_failure "${label}: server errors were reported"
  fi
}

append_external_scenario() {
  local label="$1"
  local flag_name="$2"
  local flag_value="${!flag_name:-false}"
  {
    echo
    echo "## Scenario ${label}"
    echo
    echo "- status: $([[ "${flag_value}" == "true" ]] && echo confirmed || echo not-confirmed)"
    echo "- confirmation_env: ${flag_name}"
  } >> "${REPORT_FILE}"
  if [[ "${REQUIRE_ACCEPTANCE}" == "true" && "${flag_value}" != "true" ]]; then
    record_failure "${label} not confirmed; set ${flag_name}=true after running the scenario"
  fi
}

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
  echo "- require_acceptance: ${REQUIRE_ACCEPTANCE}"
  echo "- tcp_connections: ${TCP_CONNECTIONS:-scenario-default}"
  echo "- tcp_devices_per_user: ${TCP_DEVICES_PER_USER:-scenario-default}"
  echo "- tcp_messages: ${TCP_MESSAGES:-scenario-default}"
  echo
} > "${REPORT_FILE}"

before_metrics="$(capture_metrics before)"
append_metrics_summary "before" "${before_metrics}"

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
  run_tcp_scenario \
    "one-user-five-devices" \
    "${IM_CONVERSATION_ID}" \
    "${TCP_CONNECTIONS:-5}" \
    "${TCP_DEVICES_PER_USER:-5}" \
    "${TCP_MESSAGES:-1}" \
    "${TCP_SEND_INTERVAL_MS}"

  run_tcp_scenario \
    "hundred-users-two-devices" \
    "${IM_CONVERSATION_ID}" \
    "${TCP_100_USERS_CONNECTIONS:-${DEFAULT_100_USERS_CONNECTIONS}}" \
    "${TCP_100_USERS_DEVICES_PER_USER:-2}" \
    "${TCP_100_USERS_MESSAGES:-1}" \
    "${TCP_100_USERS_SEND_INTERVAL_MS:-${TCP_SEND_INTERVAL_MS}}"

  run_tcp_scenario \
    "group-500-members-two-devices" \
    "${IM_GROUP_CONVERSATION_ID:-${IM_CONVERSATION_ID}}" \
    "${TCP_GROUP_CONNECTIONS:-${DEFAULT_GROUP_CONNECTIONS}}" \
    "${TCP_GROUP_DEVICES_PER_USER:-2}" \
    "${TCP_GROUP_MESSAGES:-1}" \
    "${TCP_GROUP_SEND_INTERVAL_MS:-${TCP_SEND_INTERVAL_MS}}"
fi

after_metrics="$(capture_metrics after)"
append_metrics_summary "after" "${after_metrics}"

append_external_scenario "AI stream concurrency" "IM_AI_STREAM_ACCEPTANCE"
append_external_scenario "reconnect storm" "IM_RECONNECT_STORM_ACCEPTANCE"

if [[ "${REQUIRE_ACCEPTANCE}" == "true" && -n "${after_metrics}" ]]; then
  outbox_backlog="$(metric_value im_outbox_backlog_events "${after_metrics}")"
  cross_node_failures="$(metric_value im_cross_node_dispatch_failures_total "${after_metrics}")"
  session_count_failures="$(metric_value im_session_count_query_failures_total "${after_metrics}")"
  ai_runtime_repairs="$(metric_value im_ai_stream_runtime_stale_repairs_total "${after_metrics}")"
  ai_startup_repairs="$(metric_value im_ai_stream_startup_stale_repairs_total "${after_metrics}")"
  ai_finalize_failures="$(metric_value im_ai_stream_finalize_failures_total "${after_metrics}")"

  awk -v value="${outbox_backlog}" 'BEGIN { exit(value <= 0 ? 0 : 1) }' || record_failure "outbox backlog did not drain"
  awk -v value="${cross_node_failures}" 'BEGIN { exit(value <= 0 ? 0 : 1) }' || record_failure "cross-node dispatch failures are non-zero"
  awk -v value="${session_count_failures}" 'BEGIN { exit(value <= 0 ? 0 : 1) }' || record_failure "session-count relay failures are non-zero"
  awk -v value="${ai_runtime_repairs}" 'BEGIN { exit(value <= 0 ? 0 : 1) }' || record_failure "AI stream runtime stale repairs are non-zero"
  awk -v value="${ai_startup_repairs}" 'BEGIN { exit(value <= 0 ? 0 : 1) }' || record_failure "AI stream startup stale repairs are non-zero"
  awk -v value="${ai_finalize_failures}" 'BEGIN { exit(value <= 0 ? 0 : 1) }' || record_failure "AI stream finalize failures are non-zero"
fi

cat <<'EOF' >> "${REPORT_FILE}"

## Go/No-Go Checklist

- HTTP/TCP error rate < 0.1%: TODO
- TCP ack success rate >= 99.9%: enforced by --require-acceptance
- TCP canonical message success rate >= 99.9%: enforced by --require-acceptance
- no duplicate canonical messages by clientMessageID in client-side sample: verify in attached client smoke notes
- message write P95/P99 meets runbook thresholds: verify from staging metrics/dashboard
- conversations/changes convergence P95 < 2s: verify from staging metrics/dashboard
- outbox backlog returns to zero or continuously drains after load stops: enforced when metrics are available
- reconnect messages/since success > 99.9%: confirm via IM_RECONNECT_STORM_ACCEPTANCE
- session-count relay failures stay at 0: enforced when metrics are available
- cross-node dispatch failures stay at 0: enforced when metrics are available
- AI stream concurrency limit rejects excess requests: confirm via IM_AI_STREAM_ACCEPTANCE
- AI stream stale repair/finalize failure metrics stay at 0: enforced when metrics are available
EOF

if [[ ${#failures[@]} -gt 0 ]]; then
  {
    echo
    echo "## Acceptance Failures"
    echo
    for failure in "${failures[@]}"; do
      echo "- ${failure}"
    done
  } >> "${REPORT_FILE}"
  echo "Staging baseline failed acceptance. Report: ${REPORT_FILE}" >&2
  exit 1
fi

echo "Staging baseline report: ${REPORT_FILE}"
