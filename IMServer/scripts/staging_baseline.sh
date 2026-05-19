#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="staging-baseline"
ENV_FILE=""
RUN_HTTP="true"
RUN_TCP="true"
RUN_AI_STREAM="true"
RUN_RECONNECT_STORM="true"
REQUIRE_ACCEPTANCE="false"
TCP_CONNECTIONS=""
TCP_DEVICES_PER_USER=""
TCP_MESSAGES=""
TCP_SEND_INTERVAL_MS=""

usage() {
  cat <<'USAGE'
Usage: staging_baseline.sh [--profile local-smoke|staging-baseline|capacity-target] [--env-file path] [--skip-http] [--skip-tcp] [--skip-ai-stream] [--skip-reconnect-storm] [--require-acceptance]
                           [--tcp-connections n] [--tcp-devices-per-user n] [--tcp-messages n] [--tcp-send-interval-ms n]

Required for HTTP:
  BASE_URL, IM_EMAIL, IM_PASSWORD, IM_MEMBER_EMAILS

Required for TCP:
  BASE_URL, TCP_HOST, TCP_PORT, IM_EMAIL, IM_PASSWORD, IM_CONVERSATION_ID

Useful multi-device TCP scenarios:
  1 user x 5 devices:        --profile local-smoke --tcp-connections 5 --tcp-devices-per-user 5 --tcp-messages 1
  100 users x 2 devices:     pair this script with k6 HTTP user load and TCP --tcp-devices-per-user 2
  1 group x 500 x 2 devices: set IM_GROUP_CONVERSATION_ID and TCP_GROUP_* env vars for the large group run
  AI stream concurrency:      set IM_AI_STREAM_ATTEMPTS / IM_AI_STREAM_CONCURRENCY to tune start pressure
  reconnect storm:            set IM_RECONNECT_STORM_COMMAND to a gateway restart/failover command
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
    --skip-ai-stream)
      RUN_AI_STREAM="false"
      shift
      ;;
    --skip-reconnect-storm)
      RUN_RECONNECT_STORM="false"
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

run_ai_stream_concurrency() {
  local log_file="${REPORT_DIR}/staging-baseline-ai-stream-concurrency.log"
  local attempts="${IM_AI_STREAM_ATTEMPTS:-8}"
  local concurrency="${IM_AI_STREAM_CONCURRENCY:-8}"
  local expected_rejections="${IM_AI_STREAM_EXPECT_REJECTIONS:-true}"

  echo "Running AI stream concurrency"
  python3 - "${BASE_URL}" "${IM_EMAIL:?IM_EMAIL is required}" "${IM_PASSWORD:?IM_PASSWORD is required}" "${IM_CONVERSATION_ID:?IM_CONVERSATION_ID is required}" "${attempts}" "${concurrency}" > "${log_file}" <<'PY'
import concurrent.futures
import json
import sys
import urllib.error
import urllib.request

base_url, email, password, conversation_id = sys.argv[1:5]
attempts = int(sys.argv[5])
concurrency = int(sys.argv[6])

def request_json(method, url, payload=None, token=None):
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            raw = response.read().decode("utf-8")
            return response.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        raw = error.read().decode("utf-8")
        try:
            body = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            body = {"raw": raw}
        return error.code, body

login_status, login_body = request_json("POST", f"{base_url}/api/auth/login", {
    "email": email,
    "password": password,
    "device": {
        "deviceID": "staging-ai-stream-concurrency",
        "deviceName": "staging-baseline",
        "platform": "staging"
    }
})
if login_status >= 400:
    print(f"loginStatus={login_status}")
    print("success=0 rejected=0 errors=1")
    sys.exit(0)

token = login_body.get("accessToken")
if not token:
    print("loginStatus=missing-token")
    print("success=0 rejected=0 errors=1")
    sys.exit(0)

def start_stream(index):
    status, body = request_json("POST", f"{base_url}/api/im/conversations/{conversation_id}/ai/messages", {
        "prompt": f"staging concurrency probe {index}"
    }, token=token)
    if 200 <= status < 300:
        return ("success", status, body.get("message", {}).get("id"))
    if status in (409, 423, 429):
        return ("rejected", status, None)
    return ("error", status, None)

results = []
with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as executor:
    futures = [executor.submit(start_stream, index) for index in range(attempts)]
    for future in concurrent.futures.as_completed(futures):
        results.append(future.result())

success = sum(1 for kind, _, _ in results if kind == "success")
rejected = sum(1 for kind, _, _ in results if kind == "rejected")
errors = sum(1 for kind, _, _ in results if kind == "error")
cancel_errors = 0
statuses = {}
for _, status, _ in results:
    statuses[status] = statuses.get(status, 0) + 1
for kind, _, message_id in results:
    if kind != "success" or not message_id:
        continue
    cancel_status, _ = request_json("POST", f"{base_url}/api/im/conversations/{conversation_id}/messages/{message_id}/stream/cancel", None, token=token)
    if cancel_status >= 500:
        cancel_errors += 1

print(f"loginStatus={login_status}")
print(f"attempts={attempts} concurrency={concurrency}")
print(f"success={success} rejected={rejected} errors={errors} cancelErrors={cancel_errors}")
print("statuses=" + ",".join(f"{key}:{statuses[key]}" for key in sorted(statuses)))
PY

  cat "${log_file}"
  local success rejected errors cancel_errors
  success="$(grep -Eo 'success=[0-9]+' "${log_file}" | tail -1 | cut -d= -f2)"
  rejected="$(grep -Eo 'rejected=[0-9]+' "${log_file}" | tail -1 | cut -d= -f2)"
  errors="$(grep -Eo 'errors=[0-9]+' "${log_file}" | tail -1 | cut -d= -f2)"
  cancel_errors="$(grep -Eo 'cancelErrors=[0-9]+' "${log_file}" | tail -1 | cut -d= -f2)"
  {
    echo
    echo "## Scenario AI stream concurrency"
    echo
    echo "- log: $(basename "${log_file}")"
    echo "- attempts: ${attempts}"
    echo "- concurrency: ${concurrency}"
    echo "- success: ${success:-unknown}"
    echo "- rejected: ${rejected:-unknown}"
    echo "- errors: ${errors:-unknown}"
    echo "- cancel_errors: ${cancel_errors:-unknown}"
    echo
    echo '```text'
    cat "${log_file}"
    echo '```'
  } >> "${REPORT_FILE}"

  if [[ "${REQUIRE_ACCEPTANCE}" == "true" ]]; then
    awk -v value="${success:-0}" 'BEGIN { exit(value >= 1 ? 0 : 1) }' || record_failure "AI stream concurrency did not start any streams"
    awk -v value="${errors:-1}" 'BEGIN { exit(value == 0 ? 0 : 1) }' || record_failure "AI stream concurrency returned unexpected errors"
    awk -v value="${cancel_errors:-1}" 'BEGIN { exit(value == 0 ? 0 : 1) }' || record_failure "AI stream concurrency cleanup returned server errors"
    if [[ "${expected_rejections}" == "true" ]]; then
      awk -v value="${rejected:-0}" 'BEGIN { exit(value >= 1 ? 0 : 1) }' || record_failure "AI stream concurrency did not reject excess streams"
    fi
  fi
}

run_reconnect_storm() {
  local log_file="${REPORT_DIR}/staging-baseline-reconnect-storm-command.log"
  if [[ -z "${IM_RECONNECT_STORM_COMMAND:-}" ]]; then
    {
      echo
      echo "## Scenario reconnect storm"
      echo
      echo "- status: skipped"
      echo "- reason: IM_RECONNECT_STORM_COMMAND not set"
    } >> "${REPORT_FILE}"
    if [[ "${REQUIRE_ACCEPTANCE}" == "true" ]]; then
      record_failure "reconnect storm command is required; set IM_RECONNECT_STORM_COMMAND"
    fi
    return
  fi

  echo "Running reconnect storm command"
  bash -lc "${IM_RECONNECT_STORM_COMMAND}" | tee "${log_file}"
  local command_status=${PIPESTATUS[0]}
  {
    echo
    echo "## Scenario reconnect storm"
    echo
    echo "- command: ${IM_RECONNECT_STORM_COMMAND}"
    echo "- status: $([[ ${command_status} -eq 0 ]] && echo passed || echo failed)"
    echo "- log: $(basename "${log_file}")"
    echo
    echo '```text'
    tail -n 40 "${log_file}"
    echo '```'
  } >> "${REPORT_FILE}"
  if [[ "${REQUIRE_ACCEPTANCE}" == "true" && ${command_status} -ne 0 ]]; then
    record_failure "reconnect storm command failed"
  fi
}

if [[ "${RUN_HTTP}" == "true" ]]; then
  command -v k6 >/dev/null 2>&1 || {
    echo "k6 is required for HTTP baseline. Install k6 or pass --skip-http." >&2
    exit 127
  }
fi

if [[ "${RUN_AI_STREAM}" == "true" ]]; then
  command -v python3 >/dev/null 2>&1 || {
    echo "python3 is required for AI stream concurrency. Install python3 or pass --skip-ai-stream." >&2
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
  echo "- ai_stream_scenario: ${RUN_AI_STREAM}"
  echo "- reconnect_storm_scenario: ${RUN_RECONNECT_STORM}"
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

if [[ "${RUN_AI_STREAM}" == "true" ]]; then
  run_ai_stream_concurrency
fi

if [[ "${RUN_RECONNECT_STORM}" == "true" ]]; then
  run_reconnect_storm
fi

after_metrics="$(capture_metrics after)"
append_metrics_summary "after" "${after_metrics}"

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
- reconnect messages/since success > 99.9%: enforced by IM_RECONNECT_STORM_COMMAND when --require-acceptance is set
- session-count relay failures stay at 0: enforced when metrics are available
- cross-node dispatch failures stay at 0: enforced when metrics are available
- AI stream concurrency limit rejects excess requests: enforced by scripted AI stream scenario when --require-acceptance is set
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
