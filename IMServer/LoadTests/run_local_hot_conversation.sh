#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_ID="${LOCAL_HOT_CONVERSATION_RUN_ID:-local-hot-conversation-$(date +%Y%m%d-%H%M%S)}"
BASE_URL="${LOCAL_HOT_CONVERSATION_BASE_URL:-http://127.0.0.1:8080}"
PROFILE="${LOCAL_HOT_CONVERSATION_PROFILE:-local-hot-smoke}"
INTERNAL_SECRET="${LOCAL_HOT_CONVERSATION_INTERNAL_SECRET:-${IM_INTERNAL_SHARED_SECRET:-}}"
RESULT_DIR="${LOCAL_HOT_CONVERSATION_RESULT_DIR:-${SCRIPT_DIR}/results/local-hot-conversation/${RUN_ID}}"
K6_BIN="${LOCAL_HOT_CONVERSATION_K6_BIN:-${K6_BIN:-k6}}"
SETTLE_SECONDS="${LOCAL_HOT_CONVERSATION_SETTLE_SECONDS:-5}"

usage() {
  cat <<'EOF'
Usage: run_local_hot_conversation.sh [check|run]

Runs only against a loopback IMServer and writes a local-only stage report.
It does not start services, reset a database, or provide production capacity evidence.

Required environment:
  LOCAL_HOT_CONVERSATION_INTERNAL_SECRET

Optional environment:
  LOCAL_HOT_CONVERSATION_BASE_URL=http://127.0.0.1:8080
  LOCAL_HOT_CONVERSATION_PROFILE=local-hot-smoke
  LOCAL_HOT_CONVERSATION_RESULT_DIR=IMServer/LoadTests/results/local-hot-conversation/<run-id>
  LOCAL_HOT_CONVERSATION_SETTLE_SECONDS=5
  IM_EMAIL, IM_PASSWORD, IM_CONVERSATION_ID, IM_MEMBER_EMAILS, IM_SEND_INTERVAL_MS
EOF
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'local_hot_conversation result=fail reason=command_missing command=%s\n' "$1" >&2
    exit 127
  }
}

require_loopback_url() {
  python3 - "$1" <<'PY'
import ipaddress
import sys
from urllib.parse import urlparse

parsed = urlparse(sys.argv[1])
host = parsed.hostname
if parsed.scheme not in {"http", "https"} or not host:
    raise SystemExit("base_url_must_include_http_scheme_and_host")
if host == "localhost":
    raise SystemExit(0)
try:
    if ipaddress.ip_address(host).is_loopback:
        raise SystemExit(0)
except ValueError:
    pass
raise SystemExit("base_url_must_target_loopback")
PY
}

check() {
  require_command curl
  require_command python3
  require_command "${K6_BIN}"
  if [[ -z "${INTERNAL_SECRET}" ]]; then
    printf 'local_hot_conversation result=fail reason=internal_secret_missing action=set_LOCAL_HOT_CONVERSATION_INTERNAL_SECRET\n' >&2
    exit 2
  fi
  if ! require_loopback_url "${BASE_URL}"; then
    printf 'local_hot_conversation result=fail reason=non_loopback_target baseURL=%s\n' "${BASE_URL}" >&2
    exit 2
  fi
  verify_k6_message_payload_contract
  printf 'local_hot_conversation result=pass mode=check productionEvidence=false baseURL=%s profile=%s\n' "${BASE_URL}" "${PROFILE}"
}

verify_k6_message_payload_contract() {
  local script
  local has_stale_payload=false
  local stale_payload_pattern='richTextContent\(\)|content: \{ type: .text.|derivedState: \{ reactions: \[\], editedAt'

  if rg -n "${stale_payload_pattern}" "${SCRIPT_DIR}/k6"/http-*.js >&2; then
    has_stale_payload=true
  fi
  if [[ "${has_stale_payload}" == true ]]; then
    printf 'local_hot_conversation result=fail reason=stale_k6_message_payload action=use_im-message-payload_helper\n' >&2
    exit 2
  fi

  while IFS= read -r -d '' script; do
    if ! rg -q "^import http from 'k6/http';" "${script}" \
        || ! rg -q "^import \\{ richTextContent, initialDerivedState \\} from './im-message-payload.js';" "${script}"; then
      printf 'local_hot_conversation result=fail reason=invalid_k6_message_payload_import script=%s\n' "${script}" >&2
      exit 2
    fi
    "${K6_BIN}" inspect "${script}" >/dev/null
  done < <(rg -l -0 'richTextContent\(' "${SCRIPT_DIR}/k6"/http-*.js)
}

fetch_metrics() {
  local output="$1"
  curl --fail --silent --show-error \
    -H "X-IM-Metrics-Secret: ${INTERNAL_SECRET}" \
    "${BASE_URL%/}/internal/metrics" >"${output}"
}

run() {
  check
  mkdir -p "${RESULT_DIR}"
  local before_metrics="${RESULT_DIR}/metrics-before.prom"
  local after_metrics="${RESULT_DIR}/metrics-after.prom"
  local k6_summary="${RESULT_DIR}/k6-summary.json"
  local report="${RESULT_DIR}/stage-report.json"

  fetch_metrics "${before_metrics}"
  local k6_exit=0
  set +e
  "${K6_BIN}" run \
    --summary-export "${k6_summary}" \
    -e "PROFILE=${PROFILE}" \
    -e "BASE_URL=${BASE_URL}" \
    -e "IM_INTERNAL_SECRET=${INTERNAL_SECRET}" \
    -e "IM_METRICS_URL=${BASE_URL%/}/internal/metrics" \
    -e "IM_METRICS_SECRET=${INTERNAL_SECRET}" \
    -e "IM_EMAIL=${IM_EMAIL:-demo@example.com}" \
    -e "IM_PASSWORD=${IM_PASSWORD:-password1234}" \
    -e "IM_CONVERSATION_ID=${IM_CONVERSATION_ID:-}" \
    -e "IM_MEMBER_EMAILS=${IM_MEMBER_EMAILS:-alice@example.com}" \
    -e "IM_SEND_INTERVAL_MS=${IM_SEND_INTERVAL_MS:-0}" \
    "${SCRIPT_DIR}/k6/http-hot-conversation-write.js"
  k6_exit=$?
  set -e
  sleep "${SETTLE_SECONDS}"
  fetch_metrics "${after_metrics}"
  python3 "${SCRIPT_DIR}/local_hot_conversation_report.py" \
    --before "${before_metrics}" \
    --after "${after_metrics}" \
    --k6-summary "${k6_summary}" \
    --output "${report}" \
    --run-id "${RUN_ID}" \
    --base-url "${BASE_URL}" \
    --profile "${PROFILE}"
  if [[ "${k6_exit}" -ne 0 ]]; then
    printf 'local_hot_conversation result=fail reason=k6_threshold_or_runtime_failure exitCode=%s productionEvidence=false report=%s\n' \
      "${k6_exit}" "${report}" >&2
    return "${k6_exit}"
  fi
  printf 'local_hot_conversation result=pass productionEvidence=false report=%s\n' "${report}"
}

case "${1:-run}" in
  --help|-h) usage ;;
  check) check ;;
  run) run ;;
  self-test)
    python3 "${SCRIPT_DIR}/local_hot_conversation_report.py" --self-test
    if require_loopback_url "https://example.com"; then
      printf 'local_hot_conversation_self_test result=fail reason=remote_target_was_accepted\n' >&2
      exit 1
    fi
    printf 'local_hot_conversation_self_test result=pass\n'
    ;;
  *) usage >&2; exit 2 ;;
esac
