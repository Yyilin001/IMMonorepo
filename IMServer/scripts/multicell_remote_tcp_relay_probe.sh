#!/usr/bin/env bash
set -Eeuo pipefail

# Runs the macOS-only TCPDriver against a remote multi-Cell smoke stack through
# SSH tunnels. The receiving TCP client is intentionally local because the
# driver uses Apple's Network framework; the message path and Cell outbox stay
# entirely on the remote stack.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE_TARGET="${IM_MULTICELL_REMOTE_SSH_TARGET:-}"
REMOTE_IDENTITY_FILE="${IM_MULTICELL_REMOTE_SSH_IDENTITY_FILE:-}"
REMOTE_ROOT_DIR="${IM_MULTICELL_REMOTE_ROOT_DIR:-/opt/IMMonorepo/IMServer}"
REMOTE_PROJECT_NAME="${IM_MULTICELL_REMOTE_PROJECT_NAME:-imserver-multicell-smoke}"
PASSWORD="${IM_MULTICELL_SMOKE_PASSWORD:-Password1234!}"
OWNER_EMAIL="${IM_MULTICELL_SMOKE_OWNER_EMAIL:-multicell-owner@example.com}"
INTERNAL_SECRET="${IM_INTERNAL_SHARED_SECRET:-production-smoke-internal-secret}"
REPORT_DIR="${IM_MULTICELL_REMOTE_TCP_RELAY_REPORT_DIR:-${ROOT_DIR}/reports}"
LOCAL_CELL_A_GATEWAY_PORT="${IM_MULTICELL_REMOTE_LOCAL_CELL_A_GATEWAY_PORT:-28080}"
LOCAL_CELL_A_COMMAND_PORT="${IM_MULTICELL_REMOTE_LOCAL_CELL_A_COMMAND_PORT:-28081}"
LOCAL_CELL_A_TCP_PORT="${IM_MULTICELL_REMOTE_LOCAL_CELL_A_TCP_PORT:-29001}"
CELL_A_GATEWAY_URL="http://127.0.0.1:${LOCAL_CELL_A_GATEWAY_PORT}"
CELL_A_COMMAND_URL="http://127.0.0.1:${LOCAL_CELL_A_COMMAND_PORT}"

usage() {
  cat <<'USAGE'
Usage: multicell_remote_tcp_relay_probe.sh run

Required environment:
  IM_MULTICELL_REMOTE_SSH_TARGET=root@remote-host

Optional environment:
  IM_MULTICELL_REMOTE_SSH_IDENTITY_FILE=/path/to/key.pem
  IM_MULTICELL_REMOTE_CONVERSATION_ID=<migrated conversation UUID>
  IM_MULTICELL_REMOTE_ROOT_DIR=/opt/IMMonorepo/IMServer

The default conversation comes from the remote latest-multicell-smoke receipt.
USAGE
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'multicell-remote-tcp-relay result=fail reason=command_missing command=%s\n' "$1" >&2
    exit 127
  }
}

require_darwin() {
  [[ "$(uname -s)" == "Darwin" ]] || {
    printf 'multicell-remote-tcp-relay result=fail reason=tcp_driver_requires_macos_load_generator\n' >&2
    exit 2
  }
}

SSH=(ssh -F /dev/null -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10)
if [[ -n "${REMOTE_IDENTITY_FILE}" ]]; then
  SSH+=(-i "${REMOTE_IDENTITY_FILE}")
fi

remote() {
  "${SSH[@]}" "${REMOTE_TARGET}" "$@"
}

json_get() {
  local path="$1"
  python3 -c '
import json
import sys

value = json.load(sys.stdin)
for part in sys.argv[1].split("."):
    value = value[int(part)] if isinstance(value, list) else value[part]
print("" if value is None else value)
' "$path"
}

request_json() {
  local method="$1" url="$2" body="${3:-}" token="${4:-}" secret="${5:-}"
  local output status
  output="$(mktemp)"
  local args=(-sS -X "${method}" -H "Content-Type: application/json" -o "${output}" -w "%{http_code}")
  [[ -n "${token}" ]] && args+=(-H "Authorization: Bearer ${token}")
  [[ -n "${secret}" ]] && args+=(-H "X-IM-Internal-Secret: ${secret}")
  [[ -n "${body}" ]] && args+=(--data "${body}")
  status="$(curl "${args[@]}" "${url}")" || {
    rm -f "${output}"
    return 1
  }
  local response
  response="$(cat "${output}")"
  rm -f "${output}"
  if [[ "${status}" -lt 200 || "${status}" -ge 300 ]]; then
    printf 'multicell-remote-tcp-relay request_failed method=%s url=%s status=%s body=%s\n' \
      "${method}" "${url}" "${status}" "${response}" >&2
    return 1
  fi
  printf '%s' "${response}"
}

wait_for_http() {
  local name="$1" url="$2"
  for _ in $(seq 1 45); do
    curl -fsS "${url}/health" >/dev/null 2>&1 && return 0
    sleep 1
  done
  printf 'multicell-remote-tcp-relay result=fail reason=health_timeout service=%s url=%s\n' \
    "${name}" "${url}" >&2
  return 1
}

register_or_login_owner() {
  local body
  body="$(python3 - "${OWNER_EMAIL}" "${PASSWORD}" <<'PY'
import json
import sys
print(json.dumps({
    'email': sys.argv[1],
    'password': sys.argv[2],
    'device': {
        'deviceID': 'multicell-owner',
        'deviceName': 'multicell-smoke',
        'platform': 'smoke',
    },
}))
PY
)"
  # The remote physical-migration smoke already provisions this owner. Login
  # first so repeated probe runs do not consume the registration rate limit.
  request_json POST "${CELL_A_GATEWAY_URL}/api/auth/login" "${body}" \
    || request_json POST "${CELL_A_GATEWAY_URL}/api/auth/register" "${body}"
}

remote_cross_cell_dispatch_count() {
  remote "cd '${REMOTE_ROOT_DIR}' && docker compose -p '${REMOTE_PROJECT_NAME}' -f docker-compose.production-smoke.yml -f docker-compose.multicell-smoke.yml exec -T postgres psql -U imserver -d imserver_smoke -Atqc \"SELECT count(*) FROM im_cross_cell_realtime_dispatches WHERE origin_cell_id = 'cell-b' AND target_cell_id = 'cell-a' AND status = 'delivered';\""
}

read_remote_conversation_id() {
  remote "python3 - '${REMOTE_ROOT_DIR}/reports/latest-multicell-smoke.json' <<'PY'
import json
import sys
with open(sys.argv[1], encoding='utf-8') as handle:
    payload = json.load(handle)
if payload.get('status') != 'passed' or not payload.get('physicalMigration'):
    raise SystemExit('remote_multicell_smoke_receipt_not_passed')
print(payload['conversationID'])
PY"
}

TUNNEL_PID=""
cleanup() {
  if [[ -n "${TUNNEL_PID}" ]]; then
    kill "${TUNNEL_PID}" 2>/dev/null || true
    wait "${TUNNEL_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

start_tunnel() {
  "${SSH[@]}" -N \
    -L "127.0.0.1:${LOCAL_CELL_A_GATEWAY_PORT}:127.0.0.1:8080" \
    -L "127.0.0.1:${LOCAL_CELL_A_COMMAND_PORT}:127.0.0.1:8081" \
    -L "127.0.0.1:${LOCAL_CELL_A_TCP_PORT}:127.0.0.1:9001" \
    "${REMOTE_TARGET}" &
  TUNNEL_PID=$!
  sleep 1
  kill -0 "${TUNNEL_PID}" 2>/dev/null || {
    printf 'multicell-remote-tcp-relay result=fail reason=ssh_tunnel_start_failed\n' >&2
    return 1
  }
}

run_probe() {
  [[ -n "${REMOTE_TARGET}" ]] || {
    printf 'multicell-remote-tcp-relay result=fail reason=missing_remote_ssh_target\n' >&2
    return 2
  }
  require_darwin
  require_command swift
  require_command curl
  require_command python3
  require_command rg
  remote true

  mkdir -p "${REPORT_DIR}"
  start_tunnel
  wait_for_http cell-a-gateway "${CELL_A_GATEWAY_URL}"
  wait_for_http cell-a-command "${CELL_A_COMMAND_URL}"

  local conversation_id owner_response owner_token owner_user_id baseline_count final_count
  conversation_id="${IM_MULTICELL_REMOTE_CONVERSATION_ID:-}"
  [[ -n "${conversation_id}" ]] || conversation_id="$(read_remote_conversation_id)"
  owner_response="$(register_or_login_owner)"
  owner_token="$(printf '%s' "${owner_response}" | json_get accessToken)"
  owner_user_id="$(printf '%s' "${owner_response}" | json_get user.id)"
  baseline_count="$(remote_cross_cell_dispatch_count)"

  local account_file receiver_log receiver_output receiver_pid client_message_id message_body delivered=false
  account_file="$(mktemp)"
  receiver_log="${REPORT_DIR}/multicell-remote-tcp-relay-receiver.jsonl"
  receiver_output="${REPORT_DIR}/multicell-remote-tcp-relay-receiver.txt"
  printf '%s,%s\n' "${IM_MULTICELL_SMOKE_PEER_EMAIL:-multicell-peer@example.com}" "${PASSWORD}" > "${account_file}"

  (
    cd "${ROOT_DIR}/LoadTests/TCPDriver"
    swift run -c release IMTCPLoadDriver \
      --profile custom \
      --base-url "${CELL_A_GATEWAY_URL}" \
      --tcp-host 127.0.0.1 \
      --tcp-port "${LOCAL_CELL_A_TCP_PORT}" \
      --account-file "${account_file}" \
      --account-devices-per-user 1 \
      --conversation-id "${conversation_id}" \
      --connections 1 \
      --messages 0 \
      --active-conversation-users 1 \
      --hold-seconds 45 \
      --timeout-seconds 30 \
      --login-concurrency 1 \
      --connection-queue-pool-size 1 \
      --connection-log-file "${receiver_log}"
  ) > "${receiver_output}" 2>&1 &
  receiver_pid=$!

  for _ in $(seq 1 60); do
    if [[ -f "${receiver_log}" ]] \
      && rg -F '"event":"auth_ok_received"' "${receiver_log}" >/dev/null \
      && rg -F '"event":"conversation_activity_send_ok"' "${receiver_log}" >/dev/null; then
      break
    fi
    if ! kill -0 "${receiver_pid}" 2>/dev/null; then
      cat "${receiver_output}" >&2 || true
      rm -f "${account_file}"
      printf 'multicell-remote-tcp-relay result=fail reason=cell_a_tcp_receiver_auth_timeout\n' >&2
      return 1
    fi
    sleep 1
  done
  [[ -f "${receiver_log}" ]] \
    && rg -F '"event":"auth_ok_received"' "${receiver_log}" >/dev/null \
    && rg -F '"event":"conversation_activity_send_ok"' "${receiver_log}" >/dev/null || {
    kill "${receiver_pid}" 2>/dev/null || true
    wait "${receiver_pid}" 2>/dev/null || true
    rm -f "${account_file}"
    printf 'multicell-remote-tcp-relay result=fail reason=cell_a_tcp_receiver_activity_timeout\n' >&2
    return 1
  }

  client_message_id="multicell-remote-tcp-relay-$(date +%s)-${RANDOM}"
  message_body="$(python3 - "${owner_user_id}" "${conversation_id}" "${client_message_id}" <<'PY'
import json
import sys
print(json.dumps({
    'senderUserID': sys.argv[1],
    'payload': {
        'clientMessageID': sys.argv[3],
        'messageID': None,
        'conversationID': sys.argv[2],
        'senderUserID': None,
        'serverSequence': None,
        'serverTimestamp': None,
        'content': {'type': 'rich_text', 'body': {'text': 'multicell remote tcp relay', 'entities': []}},
        'derivedState': {'recallState': {'active': {}}, 'edits': [], 'reactions': [], 'streamState': None},
    },
}))
PY
)"
  request_json POST "${CELL_A_COMMAND_URL}/internal/im/messages/send" "${message_body}" "${owner_token}" "${INTERNAL_SECRET}" >/dev/null

  for _ in $(seq 1 30); do
    if [[ -f "${receiver_log}" ]] \
      && rg -F '"event":"packet_received"' "${receiver_log}" \
      | rg -F "\"clientMessageID\":\"${client_message_id}\"" >/dev/null; then
      delivered=true
      break
    fi
    sleep 1
  done
  wait "${receiver_pid}" || {
    rm -f "${account_file}"
    printf 'multicell-remote-tcp-relay result=fail reason=cell_a_tcp_receiver_failed output=%s\n' "${receiver_output}" >&2
    return 1
  }
  rm -f "${account_file}"
  [[ "${delivered}" == true ]] || {
    printf 'multicell-remote-tcp-relay result=fail reason=cell_a_tcp_recipient_delivery_timeout receiverLog=%s receiverOutput=%s\n' \
      "${receiver_log}" "${receiver_output}" >&2
    return 1
  }

  for _ in $(seq 1 30); do
    final_count="$(remote_cross_cell_dispatch_count)"
    if [[ "${final_count}" -gt "${baseline_count}" ]]; then
      break
    fi
    sleep 1
  done
  final_count="$(remote_cross_cell_dispatch_count)"
  [[ "${final_count}" -gt "${baseline_count}" ]] || {
    printf 'multicell-remote-tcp-relay result=fail reason=cross_cell_outbox_delivery_missing baseline=%s final=%s\n' \
      "${baseline_count}" "${final_count}" >&2
    return 1
  }

  local receipt_file
  receipt_file="${REPORT_DIR}/latest-multicell-remote-tcp-relay.json"
  python3 - "${receipt_file}" "${conversation_id}" "${client_message_id}" "${baseline_count}" "${final_count}" \
    "${receiver_log}" "${receiver_output}" <<'PY'
import json
import sys
from datetime import datetime, timezone

path, conversation_id, message_id, baseline, final, receiver_log, receiver_output = sys.argv[1:]
payload = {
    'schemaVersion': 1,
    'generatedAt': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'status': 'passed',
    'conversationID': conversation_id,
    'clientMessageID': message_id,
    'tcpRecipientDelivery': {'required': True, 'verified': True, 'receiverCell': 'cell-a'},
    'crossCellRealtimeOutbox': {
        'originCellID': 'cell-b',
        'targetCellID': 'cell-a',
        'deliveredBefore': int(baseline),
        'deliveredAfter': int(final),
    },
    'artifacts': {'receiverLog': receiver_log, 'receiverOutput': receiver_output},
}
with open(path, 'w', encoding='utf-8') as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write('\n')
PY
  printf 'multicell-remote-tcp-relay result=pass conversation=%s message=%s outboxDeliveredBefore=%s outboxDeliveredAfter=%s receipt=%s\n' \
    "${conversation_id}" "${client_message_id}" "${baseline_count}" "${final_count}" "${receipt_file}"
}

case "${1:-}" in
  run)
    run_probe
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
