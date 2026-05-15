#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.production-smoke.yml"
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-imserver-production-smoke}"
REPORT_DIR="${ROOT_DIR}/reports"
STATE_FILE="${REPORT_DIR}/production-smoke-state.env"
REPORT_FILE="${REPORT_DIR}/$(date -u +%Y%m%dT%H%M%SZ)-production-smoke.md"

GATEWAY_URL="${IM_SMOKE_GATEWAY_URL:-http://127.0.0.1:8080}"
COMMAND_URL="${IM_SMOKE_COMMAND_URL:-http://127.0.0.1:8081}"
QUERY_URL="${IM_SMOKE_QUERY_URL:-http://127.0.0.1:8082}"
INTERNAL_SECRET="${IM_INTERNAL_SHARED_SECRET:-production-smoke-internal-secret}"
OWNER_EMAIL="${IM_SMOKE_OWNER_EMAIL:-smoke-owner@example.com}"
PEER_A_EMAIL="${IM_SMOKE_PEER_A_EMAIL:-smoke-peer-a@example.com}"
PEER_B_EMAIL="${IM_SMOKE_PEER_B_EMAIL:-smoke-peer-b@example.com}"
SMOKE_PASSWORD="${IM_SMOKE_PASSWORD:-Password1234!}"

compose() {
  docker compose -p "${PROJECT_NAME}" -f "${COMPOSE_FILE}" "$@"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 127
  fi
}

usage() {
  cat <<'USAGE'
Usage: production_smoke.sh <up|run|down|logs>

Commands:
  up     Build image, start infra, run ops migrations, and start all production roles.
  run    Reset the smoke stack, start it, execute HTTP/Kafka/summary checks, and write a report.
  down   Stop the stack and remove smoke volumes.
  logs   Print role and infra logs.
USAGE
}

json_get() {
  local path="$1"
  python3 - "$path" <<'PY'
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
PY
}

json_quote() {
  python3 - "$1" <<'PY'
import json
import sys
print(json.dumps(sys.argv[1]))
PY
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
  local tmp
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

  local status
  status="$(curl "${args[@]}" "${url}")" || {
    cat "${tmp}" >&2 || true
    rm -f "${tmp}"
    return 1
  }
  local response
  response="$(cat "${tmp}")"
  rm -f "${tmp}"

  if [[ "${status}" -lt 200 || "${status}" -ge 300 ]]; then
    echo "Request failed: ${method} ${url} -> ${status}" >&2
    echo "${response}" >&2
    return 1
  fi
  printf '%s' "${response}"
}

wait_for_http() {
  local name="$1"
  local url="$2"
  echo "Waiting for ${name} at ${url}"
  for _ in $(seq 1 90); do
    if curl -fsS "${url}/hello" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "Timed out waiting for ${name}" >&2
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
        "deviceName": "production-smoke",
        "platform": "smoke"
    }
}))
PY
)"
  request_json POST "${GATEWAY_URL}/api/auth/register" "${body}"
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
        "deviceName": "production-smoke",
        "platform": "smoke"
    }
}))
PY
)"
  request_json POST "${GATEWAY_URL}/api/auth/login" "${body}"
}

register_or_login_user() {
  local email="$1"
  local device_id="$2"
  register_user "${email}" "${device_id}" 2>/dev/null || login_user "${email}" "${device_id}"
}

create_conversation() {
  create_conversation_at "${COMMAND_URL}" "$@"
}

create_conversation_via_gateway() {
  create_conversation_at "${GATEWAY_URL}" "$@"
}

create_conversation_at() {
  local base_url="$1"
  local token="$2"
  local kind="$3"
  local title="$4"
  shift 4
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
  request_json POST "${base_url}/api/im/conversations" "${body}" "${token}"
}

send_internal_message() {
  local token="$1"
  local sender_user_id="$2"
  local conversation_id="$3"
  local text="$4"
  local client_message_id="smoke-$(date +%s)-${RANDOM}"
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
        "content": {"type": "text", "text": sys.argv[4]},
        "derivedState": {"recallState": "active", "edits": [], "reactions": []}
    }
}))
PY
)"
  request_json POST "${COMMAND_URL}/internal/im/messages/send" "${body}" "${token}" "${INTERNAL_SECRET}"
}

conversation_has_last_message() {
  local conversation_id="$1"
  python3 - "$conversation_id" <<'PY'
import json
import sys
conversation_id = sys.argv[1]
data = json.load(sys.stdin)
for item in data.get("items", []):
    if item.get("id") == conversation_id and item.get("lastMessage"):
        sys.exit(0)
sys.exit(1)
PY
}

changes_include_conversation() {
  local conversation_id="$1"
  python3 - "$conversation_id" <<'PY'
import json
import sys
conversation_id = sys.argv[1]
data = json.load(sys.stdin)
for item in data.get("upserts", []):
    if item.get("id") == conversation_id:
        sys.exit(0)
sys.exit(1)
PY
}

wait_for_summary() {
  local token="$1"
  local conversation_id="$2"
  for _ in $(seq 1 90); do
    local body
    body="$(request_json GET "${QUERY_URL}/api/im/conversations?limit=20" "" "${token}")"
    if printf '%s' "${body}" | conversation_has_last_message "${conversation_id}"; then
      return 0
    fi
    sleep 2
  done
  echo "Timed out waiting for summary projection for conversation ${conversation_id}" >&2
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
    sleep 2
  done
  echo "Timed out waiting for changes projection for conversation ${conversation_id}" >&2
  return 1
}

metric_value() {
  local metric="$1"
  awk -v metric="$metric" '$1 == metric { print int($2); found=1 } END { if (!found) print "" }'
}

wait_for_outbox_recovery() {
  for _ in $(seq 1 60); do
    local inspect pending claimed failed
    inspect="$(compose run --rm ops ops --env production --inspect-conversation-outbox 2>/dev/null || true)"
    pending="$(printf '%s\n' "${inspect}" | awk -F'[ =]' '/^shard=/{for(i=1;i<=NF;i++) if($i=="pending") print $(i+1)}' | awk '{s+=$1} END{print s+0}')"
    claimed="$(printf '%s\n' "${inspect}" | awk -F'[ =]' '/^shard=/{for(i=1;i<=NF;i++) if($i=="claimed") print $(i+1)}' | awk '{s+=$1} END{print s+0}')"
    failed="$(printf '%s\n' "${inspect}" | awk -F'[ =]' '/^shard=/{for(i=1;i<=NF;i++) if($i=="failed") print $(i+1)}' | awk '{s+=$1} END{print s+0}')"
    if [[ "${pending}" == "0" && "${claimed}" == "0" && "${failed}" == "0" ]]; then
      echo "outbox_backlog_events=0"
      echo "outbox_oldest_pending_age_millis=0"
      return 0
    fi
    sleep 2
  done
  echo "Outbox backlog did not recover" >&2
  compose run --rm ops ops --env production --inspect-conversation-outbox >&2 || true
  return 1
}

assert_metrics_protected() {
  local status
  status="$(curl -sS -o /dev/null -w "%{http_code}" "${COMMAND_URL}/internal/metrics" || true)"
  if [[ "${status}" != "401" ]]; then
    echo "Expected /internal/metrics without secret to return 401, got ${status}" >&2
    return 1
  fi
  curl -fsS -H "X-IM-Internal-Secret: ${INTERNAL_SECRET}" "${COMMAND_URL}/internal/metrics" >/dev/null
}

write_state() {
  local owner_token="$1"
  local owner_user_id="$2"
  local direct_conversation_id="$3"
  local group_conversation_id="$4"
  mkdir -p "${REPORT_DIR}"
  {
    printf 'GATEWAY_URL=%q\n' "${GATEWAY_URL}"
    printf 'COMMAND_URL=%q\n' "${COMMAND_URL}"
    printf 'QUERY_URL=%q\n' "${QUERY_URL}"
    printf 'INTERNAL_SECRET=%q\n' "${INTERNAL_SECRET}"
    printf 'OWNER_TOKEN=%q\n' "${owner_token}"
    printf 'OWNER_USER_ID=%q\n' "${owner_user_id}"
    printf 'DIRECT_CONVERSATION_ID=%q\n' "${direct_conversation_id}"
    printf 'GROUP_CONVERSATION_ID=%q\n' "${group_conversation_id}"
  } > "${STATE_FILE}"
}

collect_logs() {
  mkdir -p "${REPORT_DIR}"
  compose ps > "${REPORT_DIR}/production-smoke-compose-ps.txt" 2>&1 || true
  compose logs --no-color --tail=300 > "${REPORT_DIR}/production-smoke-compose.log" 2>&1 || true
}

print_diagnostics() {
  echo "Collecting production smoke diagnostics" >&2
  collect_logs
  compose run --rm ops ops --env production --inspect-conversation-outbox >&2 || true
  curl -fsS -H "X-IM-Internal-Secret: ${INTERNAL_SECRET}" "${COMMAND_URL}/internal/metrics" >&2 || true
}

up_stack() {
  require_command docker
  require_command curl
  require_command python3

  mkdir -p "${REPORT_DIR}"
  compose build gateway
  compose up -d postgres redpanda redis minio redpanda-init minio-init
  compose run --rm ops
  compose up -d \
    gateway \
    command-api \
    query-api \
    outbox-relay \
    stream-consumer-summary \
    stream-consumer-changes \
    stream-consumer-search \
    stream-consumer-notification \
    stream-consumer-repair

  wait_for_http gateway "${GATEWAY_URL}"
  wait_for_http command-api "${COMMAND_URL}"
  wait_for_http query-api "${QUERY_URL}"
}

down_stack() {
  compose down --volumes --remove-orphans
}

run_smoke() {
  trap print_diagnostics ERR

  if [[ "${IM_SMOKE_KEEP_STATE:-false}" != "true" ]]; then
    down_stack || true
  fi
  up_stack

  local owner_response peer_a_response peer_b_response
  owner_response="$(register_or_login_user "${OWNER_EMAIL}" "smoke-owner")"
  peer_a_response="$(register_or_login_user "${PEER_A_EMAIL}" "smoke-peer-a")"
  peer_b_response="$(register_or_login_user "${PEER_B_EMAIL}" "smoke-peer-b")"

  local owner_token owner_user_id
  owner_token="$(printf '%s' "${owner_response}" | json_get accessToken)"
  owner_user_id="$(printf '%s' "${owner_response}" | json_get user.id)"
  : "${peer_a_response:?}"
  : "${peer_b_response:?}"

  local direct_response group_response direct_id group_id
  direct_response="$(create_conversation_via_gateway "${owner_token}" direct "" "${PEER_A_EMAIL}")"
  group_response="$(create_conversation "${owner_token}" group "Smoke Group" "${PEER_A_EMAIL}" "${PEER_B_EMAIL}")"
  direct_id="$(printf '%s' "${direct_response}" | json_get id)"
  group_id="$(printf '%s' "${group_response}" | json_get id)"

  local before_changes
  before_changes="$(request_json GET "${QUERY_URL}/api/im/conversations?limit=20" "" "${owner_token}" | json_get snapshotToken)"
  if [[ -z "${before_changes}" ]]; then
    before_changes="$(initial_change_token)"
  fi

  send_internal_message "${owner_token}" "${owner_user_id}" "${direct_id}" "production smoke direct message" >/dev/null
  send_internal_message "${owner_token}" "${owner_user_id}" "${group_id}" "production smoke group message" >/dev/null

  wait_for_summary "${owner_token}" "${direct_id}"
  wait_for_changes "${owner_token}" "${direct_id}" "${before_changes}"
  request_json GET "${QUERY_URL}/api/im/conversations/${direct_id}/messages/since?afterSequence=0&limit=10" "" "${owner_token}" >/dev/null
  assert_metrics_protected
  wait_for_outbox_recovery >/tmp/imserver-production-smoke-outbox.txt
  compose run --rm ops ops --env production --inspect-conversation-outbox > "${REPORT_DIR}/production-smoke-outbox-inspect.txt"

  write_state "${owner_token}" "${owner_user_id}" "${direct_id}" "${group_id}"
  collect_logs

  {
    echo "# IMServer production smoke report"
    echo
    echo "- generated_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "- project: ${PROJECT_NAME}"
    echo "- direct_conversation_id: ${direct_id}"
    echo "- group_conversation_id: ${group_id}"
    echo "- summary_projection: ok"
    echo "- changes_projection: ok"
    echo "- messages_since: ok"
    echo "- gateway_command_bridge: ok"
    echo "- metrics_secret: ok"
    echo "- im_runtime_role_query_api: ok"
    cat /tmp/imserver-production-smoke-outbox.txt
    echo
    echo "## Outbox inspect"
    echo '```'
    cat "${REPORT_DIR}/production-smoke-outbox-inspect.txt"
    echo '```'
  } > "${REPORT_FILE}"

  echo "Production smoke passed: ${REPORT_FILE}"
}

case "${1:-}" in
  up)
    up_stack
    ;;
  run)
    run_smoke
    ;;
  down)
    down_stack
    ;;
  logs)
    compose logs --no-color --tail="${LOG_TAIL:-300}"
    ;;
  *)
    usage
    exit 2
    ;;
esac
