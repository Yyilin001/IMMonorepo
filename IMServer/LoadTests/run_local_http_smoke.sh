#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_DIR="${LOCAL_HTTP_SMOKE_REPORT_DIR:-${SCRIPT_DIR}/results/local-acceptance/http-smoke}"
RUN_ID="${LOCAL_HTTP_SMOKE_RUN_ID:-local-http-smoke-$(date +%Y%m%d-%H%M%S)}"
REPORT_FILE="${LOCAL_HTTP_SMOKE_REPORT_FILE:-${REPORT_DIR}/${RUN_ID}-local-http-smoke.json}"
BASE_URL="${LOCAL_HTTP_SMOKE_BASE_URL:-${LOCAL_ACCEPTANCE_BASE_URL:-http://127.0.0.1:8080}}"
COMMAND_URL="${LOCAL_HTTP_SMOKE_COMMAND_URL:-${LOCAL_HTTP_SMOKE_BASE_URL:-${BASE_URL}}}"
QUERY_URL="${LOCAL_HTTP_SMOKE_QUERY_URL:-${LOCAL_HTTP_SMOKE_BASE_URL:-${BASE_URL}}}"
INTERNAL_SECRET="${LOCAL_HTTP_SMOKE_INTERNAL_SECRET:-${LOCAL_ACCEPTANCE_INTERNAL_SECRET:-${IM_INTERNAL_SHARED_SECRET:-production-smoke-internal-secret}}}"
SMOKE_PASSWORD="${LOCAL_HTTP_SMOKE_PASSWORD:-password1234}"
OWNER_EMAIL="${LOCAL_HTTP_SMOKE_OWNER_EMAIL:-local-smoke-owner-${RUN_ID}@example.com}"
PEER_A_EMAIL="${LOCAL_HTTP_SMOKE_PEER_A_EMAIL:-local-smoke-peer-a-${RUN_ID}@example.com}"
PEER_B_EMAIL="${LOCAL_HTTP_SMOKE_PEER_B_EMAIL:-local-smoke-peer-b-${RUN_ID}@example.com}"

usage() {
  cat <<'EOF'
Usage:
  run_local_http_smoke.sh [run|self-test]

Purpose:
  Validate a local single-process IMServer over HTTP without Docker Compose.
  The output is local-only evidence and is never production acceptance evidence.

Common env:
  LOCAL_HTTP_SMOKE_BASE_URL=http://127.0.0.1:8080
  LOCAL_HTTP_SMOKE_COMMAND_URL=http://127.0.0.1:8080
  LOCAL_HTTP_SMOKE_QUERY_URL=http://127.0.0.1:8080
  LOCAL_HTTP_SMOKE_INTERNAL_SECRET=production-smoke-internal-secret
  LOCAL_HTTP_SMOKE_REPORT_DIR=IMServer/LoadTests/results/local-acceptance/http-smoke
  LOCAL_HTTP_SMOKE_REPORT_FILE=IMServer/LoadTests/results/local-acceptance/http-smoke/<run-id>-local-http-smoke.json
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'local_http_smoke result=fail reason=command_missing command=%s\n' "$1" >&2
    exit 127
  fi
}

json_get() {
  local path="$1"
  python3 -c '
import json
import sys

path = sys.argv[1].split(".")
data = json.load(sys.stdin)
for part in path:
    if isinstance(data, list):
        data = data[int(part)]
    else:
        data = data[part]
if data is None:
    print("")
else:
    print(data)
' "$path"
}

json_get_first() {
  python3 -c '
import json
import sys

data = json.load(sys.stdin)

def get_path(root, path):
    current = root
    for part in path.split("."):
        if isinstance(current, list):
            current = current[int(part)]
        elif isinstance(current, dict) and part in current:
            current = current[part]
        else:
            return None
    return current

for path in sys.argv[1:]:
    value = get_path(data, path)
    if value is not None:
        print(value)
        raise SystemExit(0)
raise SystemExit(1)
' "$@"
}

url_encode() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import quote
print(quote(sys.argv[1], safe=""))
PY
}

initial_change_token() {
  python3 - <<'PY'
import base64
import json
payload = {"updatedAt": "0001-01-01T00:00:00Z", "recordID": ""}
print(base64.b64encode(json.dumps(payload, separators=(",", ":")).encode()).decode())
PY
}

request_json() {
  local method="$1"
  local url="$2"
  local body="${3:-}"
  local token="${4:-}"
  local secret="${5:-}"
  local tmp status response
  tmp="$(mktemp)"
  local args=(-sS -X "${method}" -H "Content-Type: application/json" -o "${tmp}" -w "%{http_code}")
  if [[ -n "${token}" ]]; then
    args+=(-H "Authorization: Bearer ${token}")
  fi
  if [[ -n "${secret}" ]]; then
    args+=(-H "X-IM-Internal-Secret: ${secret}")
  fi
  if [[ -n "${body}" ]]; then
    args+=(--data "${body}")
  fi

  status="$(curl "${args[@]}" "${url}")" || {
    cat "${tmp}" >&2 || true
    rm -f "${tmp}"
    return 1
  }
  response="$(cat "${tmp}")"
  rm -f "${tmp}"

  if [[ "${status}" -lt 200 || "${status}" -ge 300 ]]; then
    printf 'Request failed: %s %s -> %s\n' "${method}" "${url}" "${status}" >&2
    printf '%s\n' "${response}" >&2
    return 1
  fi
  printf '%s' "${response}"
}

wait_for_http() {
  local name="$1"
  local url="$2"
  for _ in $(seq 1 90); do
    if curl -fsS "${url}/health" >/dev/null 2>&1 || curl -fsS "${url}/hello" >/dev/null 2>&1; then
      printf 'local_http_smoke status=ready target=%s url=%s\n' "${name}" "${url}"
      return 0
    fi
    sleep 1
  done
  printf 'local_http_smoke result=fail reason=http_not_ready target=%s url=%s\n' "${name}" "${url}" >&2
  return 1
}

register_user() {
  local email="$1"
  local device_id="$2"
  local body
  body="$(python3 - "$email" "$SMOKE_PASSWORD" "$device_id" <<'PY'
import json
import sys
print(json.dumps({
    "email": sys.argv[1],
    "password": sys.argv[2],
    "device": {
        "deviceID": sys.argv[3],
        "deviceName": "local-http-smoke",
        "platform": "smoke"
    }
}))
PY
)"
  request_json POST "${BASE_URL}/api/auth/register" "${body}"
}

login_user() {
  local email="$1"
  local device_id="$2"
  local body
  body="$(python3 - "$email" "$SMOKE_PASSWORD" "$device_id" <<'PY'
import json
import sys
print(json.dumps({
    "email": sys.argv[1],
    "password": sys.argv[2],
    "device": {
        "deviceID": sys.argv[3],
        "deviceName": "local-http-smoke",
        "platform": "smoke"
    }
}))
PY
)"
  request_json POST "${BASE_URL}/api/auth/login" "${body}"
}

register_or_login_user() {
  local email="$1"
  local device_id="$2"
  register_user "${email}" "${device_id}" 2>/dev/null || login_user "${email}" "${device_id}"
}

create_conversation() {
  local token="$1"
  local kind="$2"
  local title="$3"
  shift 3
  local body
  body="$(python3 - "$kind" "$title" "$@" <<'PY'
import json
import sys
kind = sys.argv[1]
title = sys.argv[2] or None
emails = sys.argv[3:]
print(json.dumps({"kind": kind, "title": title, "memberEmails": emails}))
PY
)"
  request_json POST "${COMMAND_URL}/api/im/conversations" "${body}" "${token}"
}

send_internal_message() {
  local token="$1"
  local sender_user_id="$2"
  local conversation_id="$3"
  local text="$4"
  local client_message_id="local-smoke-$(date +%s)-${RANDOM}"
  local body
  body="$(python3 - "$sender_user_id" "$conversation_id" "$client_message_id" "$text" <<'PY'
import json
import sys
print(json.dumps({
    "senderUserID": sys.argv[1],
    "payload": {
        "clientMessageID": sys.argv[3],
        "messageID": None,
        "conversationID": sys.argv[2],
        "senderUserID": None,
        "serverSequence": None,
        "serverTimestamp": None,
        "content": {"type": "rich_text", "body": {"text": sys.argv[4], "entities": []}},
        "derivedState": {
            "recallState": {"active": {}},
            "edits": [],
            "reactions": [],
            "streamState": None
        }
    }
}))
PY
)"
  request_json POST "${COMMAND_URL}/internal/im/messages/send" "${body}" "${token}" "${INTERNAL_SECRET}"
}

conversation_has_last_message() {
  local conversation_id="$1"
  python3 -c '
import json
import sys
conversation_id = sys.argv[1]
data = json.load(sys.stdin)
for item in data.get("items", []):
    if item.get("id") == conversation_id and item.get("lastMessage"):
        sys.exit(0)
sys.exit(1)
' "$conversation_id"
}

changes_include_conversation() {
  local conversation_id="$1"
  python3 -c '
import json
import sys
conversation_id = sys.argv[1]
data = json.load(sys.stdin)
for item in data.get("upserts", []):
    if item.get("id") == conversation_id:
        sys.exit(0)
sys.exit(1)
' "$conversation_id"
}

timeline_has_message() {
  local conversation_id="$1"
  python3 -c '
import json
import sys
conversation_id = sys.argv[1]
data = json.load(sys.stdin)
for item in data.get("items", []):
    message = item.get("message") or {}
    if message.get("conversationID") == conversation_id:
        sys.exit(0)
sys.exit(1)
' "$conversation_id"
}

wait_for_summary() {
  local token="$1"
  local conversation_id="$2"
  for _ in $(seq 1 60); do
    local body
    body="$(request_json GET "${QUERY_URL}/api/im/conversations?limit=20" "" "${token}")"
    if printf '%s' "${body}" | conversation_has_last_message "${conversation_id}"; then
      return 0
    fi
    sleep 1
  done
  printf 'Timed out waiting for summary projection for conversation %s\n' "${conversation_id}" >&2
  return 1
}

wait_for_changes() {
  local token="$1"
  local conversation_id="$2"
  local after_token="$3"
  local encoded
  encoded="$(url_encode "${after_token}")"
  for _ in $(seq 1 60); do
    local body
    body="$(request_json GET "${QUERY_URL}/api/im/conversations/changes?afterToken=${encoded}&limit=20" "" "${token}")"
    if printf '%s' "${body}" | changes_include_conversation "${conversation_id}"; then
      return 0
    fi
    sleep 1
  done
  printf 'Timed out waiting for changes projection for conversation %s\n' "${conversation_id}" >&2
  return 1
}

wait_for_timeline() {
  local token="$1"
  local conversation_id="$2"
  for _ in $(seq 1 60); do
    local body
    body="$(request_json GET "${QUERY_URL}/api/im/conversations/${conversation_id}/timeline/since?afterSequence=0&limit=10" "" "${token}")"
    if printf '%s' "${body}" | timeline_has_message "${conversation_id}"; then
      return 0
    fi
    sleep 1
  done
  printf 'Timed out waiting for timeline for conversation %s\n' "${conversation_id}" >&2
  return 1
}

assert_metrics_protected() {
  local status
  status="$(curl -sS -o /dev/null -w "%{http_code}" "${BASE_URL}/internal/metrics" || true)"
  if [[ "${status}" != "401" ]]; then
    printf 'Expected /internal/metrics without secret to return 401, got %s\n' "${status}" >&2
    return 1
  fi
  curl -fsS -H "X-IM-Internal-Secret: ${INTERNAL_SECRET}" "${BASE_URL}/internal/metrics" >/dev/null
}

run_smoke() {
  require_command curl
  require_command python3
  mkdir -p "${REPORT_DIR}"

  wait_for_http gateway "${BASE_URL}"
  wait_for_http command-api "${COMMAND_URL}"
  wait_for_http query-api "${QUERY_URL}"

  local owner_response peer_a_response peer_b_response
  owner_response="$(register_or_login_user "${OWNER_EMAIL}" "local-smoke-owner-${RUN_ID}")"
  peer_a_response="$(register_or_login_user "${PEER_A_EMAIL}" "local-smoke-peer-a-${RUN_ID}")"
  peer_b_response="$(register_or_login_user "${PEER_B_EMAIL}" "local-smoke-peer-b-${RUN_ID}")"

  local owner_token owner_user_id
  owner_token="$(printf '%s' "${owner_response}" | json_get_first accessToken auth.accessToken)"
  owner_user_id="$(printf '%s' "${owner_response}" | json_get_first user.id auth.user.id)"
  : "${peer_a_response:?}"
  : "${peer_b_response:?}"

  local direct_response group_response direct_id group_id before_changes
  direct_response="$(create_conversation "${owner_token}" direct "" "${PEER_A_EMAIL}")"
  group_response="$(create_conversation "${owner_token}" group "Local Smoke Group" "${PEER_A_EMAIL}" "${PEER_B_EMAIL}")"
  direct_id="$(printf '%s' "${direct_response}" | json_get id)"
  group_id="$(printf '%s' "${group_response}" | json_get id)"

  before_changes="$(request_json GET "${QUERY_URL}/api/im/conversations?limit=20" "" "${owner_token}" | json_get snapshotToken)"
  if [[ -z "${before_changes}" ]]; then
    before_changes="$(initial_change_token)"
  fi

  send_internal_message "${owner_token}" "${owner_user_id}" "${direct_id}" "local smoke direct message" >/dev/null
  send_internal_message "${owner_token}" "${owner_user_id}" "${group_id}" "local smoke group message" >/dev/null

  wait_for_summary "${owner_token}" "${direct_id}"
  wait_for_changes "${owner_token}" "${direct_id}" "${before_changes}"
  wait_for_timeline "${owner_token}" "${direct_id}"
  assert_metrics_protected

  mkdir -p "$(dirname "${REPORT_FILE}")"
  cat >"${REPORT_FILE}" <<EOF
{
  "schemaVersion": 1,
  "runID": "${RUN_ID}",
  "productionEvidence": false,
  "localOnly": true,
  "baseURL": "${BASE_URL}",
  "commandURL": "${COMMAND_URL}",
  "queryURL": "${QUERY_URL}",
  "directConversationID": "${direct_id}",
  "groupConversationID": "${group_id}",
  "checks": {
    "auth": "ok",
    "conversationCreate": "ok",
    "internalSend": "ok",
    "summaryProjection": "ok",
    "changesProjection": "ok",
    "timelineSince": "ok",
    "metricsSecret": "ok"
  }
}
EOF
  printf 'local_http_smoke result=pass productionEvidence=false report=%s\n' "${REPORT_FILE}"
}

run_self_test() {
  require_command python3
  local token encoded
  token="$(initial_change_token)"
  encoded="$(url_encode "${token}")"
  if [[ -z "${token}" || -z "${encoded}" ]]; then
    printf 'local_http_smoke_self_test result=fail reason=helper_output_empty\n' >&2
    return 1
  fi
  printf '{"a":{"b":"ok"}}' | json_get a.b | grep -q '^ok$'
  printf 'local_http_smoke_self_test result=pass\n'
}

case "${1:-run}" in
  --help|-h)
    usage
    exit 0
    ;;
  run)
    run_smoke
    ;;
  self-test)
    run_self_test
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
