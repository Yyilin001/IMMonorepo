#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_SMOKE_SCRIPT="${ROOT_DIR}/scripts/production_smoke.sh"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.production-smoke.yml"
COMPOSE_OVERLAY="${ROOT_DIR}/docker-compose.multicell-smoke.yml"
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-imserver-multicell-smoke}"
CELL_A_GATEWAY_URL="${IM_MULTICELL_SMOKE_CELL_A_GATEWAY_URL:-http://127.0.0.1:8080}"
CELL_A_COMMAND_URL="${IM_MULTICELL_SMOKE_CELL_A_COMMAND_URL:-http://127.0.0.1:8081}"
CELL_A_QUERY_URL="${IM_MULTICELL_SMOKE_CELL_A_QUERY_URL:-http://127.0.0.1:8082}"
CELL_B_GATEWAY_URL="${IM_MULTICELL_SMOKE_CELL_B_GATEWAY_URL:-http://127.0.0.1:18080}"
CELL_B_COMMAND_URL="${IM_MULTICELL_SMOKE_CELL_B_COMMAND_URL:-http://127.0.0.1:18081}"
CELL_B_QUERY_URL="${IM_MULTICELL_SMOKE_CELL_B_QUERY_URL:-http://127.0.0.1:18082}"
INTERNAL_SECRET="${IM_INTERNAL_SHARED_SECRET:-production-smoke-internal-secret}"
PASSWORD="${IM_MULTICELL_SMOKE_PASSWORD:-Password1234!}"
OWNER_EMAIL="${IM_MULTICELL_SMOKE_OWNER_EMAIL:-multicell-owner@example.com}"
PEER_EMAIL="${IM_MULTICELL_SMOKE_PEER_EMAIL:-multicell-peer@example.com}"
REPORT_DIR="${IM_MULTICELL_SMOKE_REPORT_DIR:-${ROOT_DIR}/reports}"
RECEIPT_FILE="${IM_MULTICELL_SMOKE_RECEIPT_JSON:-${REPORT_DIR}/latest-multicell-smoke.json}"

compose() {
  docker compose -p "${PROJECT_NAME}" -f "${COMPOSE_FILE}" -f "${COMPOSE_OVERLAY}" "$@"
}

usage() {
  cat <<'USAGE'
Usage: multicell_smoke.sh <up|run|failure-drill|down|logs|self-test> [redis-outage|kafka-outage|target-gateway-outage]

Creates Cell B through the multi-Cell compose overlay, then performs a
physical Cell A -> Cell B conversation migration between isolated shard
databases. It verifies post-cutover writes and reads forwarded through Cell A.
Set
IM_MULTICELL_SMOKE_REQUIRE_GATEWAY_TCP_RELAY=true on macOS to also verify that
a peer connected to Cell A's Gateway receives a message written through Cell A
and persisted by the migrated Cell B.
For a remote Linux stack, run the same gate from this macOS host through SSH
with scripts/multicell_remote_tcp_relay_probe.sh after the physical migration.
`failure-drill` runs the physical Cell A -> Cell B migration first, then
checks a post-cutover write after the selected dependency recovers.
`target-gateway-outage` requires the macOS TCP recipient gate because it needs
an authenticated Cell A recipient presence before the target Gateway is killed.
USAGE
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'multicell-smoke result=fail reason=command_missing command=%s\n' "$1" >&2
    exit 127
  }
}

require_compose_version() {
  require_command docker
  require_command python3
  local version
  version="$(docker compose version --short 2>/dev/null || true)"
  [[ -n "${version}" ]] || {
    printf 'multicell-smoke result=fail reason=docker_compose_v2_required\n' >&2
    exit 127
  }
  python3 - "${version}" <<'PY'
import re
import sys

match = re.search(r'(\d+)\.(\d+)\.(\d+)', sys.argv[1])
if not match:
    raise SystemExit('multicell-smoke result=fail reason=unparseable_docker_compose_version')
version = tuple(map(int, match.groups()))
if version < (2, 24, 4):
    raise SystemExit(
        'multicell-smoke result=fail reason=docker_compose_2_24_4_or_newer_required '
        f'version={sys.argv[1]}'
    )
PY
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

conversation_id_from_response() {
  python3 -c '
import json
import sys

payload = json.load(sys.stdin)
conversation_id = payload.get("conversationID") or payload.get("id")
if not conversation_id:
    raise SystemExit("conversation_response_missing_conversation_id")
print(conversation_id)
'
}

request_json() {
  local method="$1" url="$2" body="${3:-}" token="${4:-}" secret="${5:-}"
  local output status
  output="$(mktemp)"
  # This topology has a shared, independent summary database. Command calls
  # must opt into the asynchronous summary receipt contract.
  local args=(-sS -X "${method}" -H "Content-Type: application/json" -H "Accept: application/vnd.im.conversation-command-receipt+json" -o "${output}" -w "%{http_code}")
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
    printf 'multicell-smoke request_failed method=%s url=%s status=%s body=%s\n' \
      "${method}" "${url}" "${status}" "${response}" >&2
    return 1
  fi
  printf '%s' "${response}"
}

wait_for_http() {
  local name="$1" url="$2"
  for _ in $(seq 1 90); do
    curl -fsS "${url}/health" >/dev/null 2>&1 && return 0
    sleep 2
  done
  printf 'multicell-smoke result=fail reason=health_timeout service=%s url=%s\n' "${name}" "${url}" >&2
  return 1
}

register_or_login() {
  local email="$1" device_id="$2" body
  body="$(python3 - "$email" "$PASSWORD" "$device_id" <<'PY'
import json
import sys
print(json.dumps({
    'email': sys.argv[1],
    'password': sys.argv[2],
    'device': {'deviceID': sys.argv[3], 'deviceName': 'multicell-smoke', 'platform': 'smoke'},
}))
PY
)"
  request_json POST "${CELL_A_GATEWAY_URL}/api/auth/register" "${body}" \
    || request_json POST "${CELL_A_GATEWAY_URL}/api/auth/login" "${body}"
}

assert_timeline_contains_message() {
  local expected_client_message_id="$1"
  python3 -c '
import json
import sys

payload = json.load(sys.stdin)
items = payload.get("items", [])
message_ids = [
    (item.get("message") or item).get("clientMessageID")
    for item in items
]
if sys.argv[1] not in message_ids:
    observed = [message_id for message_id in message_ids if message_id]
    raise SystemExit(
        "timeline_missing_forwarded_message expected={} observed={}".format(
            sys.argv[1], ",".join(observed)
        )
    )
' "$expected_client_message_id"
}

send_internal_message_at() {
  local base_url="$1" token="$2" sender_user_id="$3" conversation_id="$4" client_message_id="$5" text="$6"
  local body
  body="$(python3 - "$sender_user_id" "$conversation_id" "$client_message_id" "$text" <<'PY'
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
        'content': {'type': 'rich_text', 'body': {'text': sys.argv[4], 'entities': []}},
        'derivedState': {
            'recallState': {'active': {}},
            'edits': [],
            'reactions': [],
            'streamState': None,
        },
    },
}))
PY
)"
  request_json POST "${base_url}/internal/im/messages/send" "${body}" "${token}" "${INTERNAL_SECRET}"
}

run_source_migration_ops() {
  run_migration_ops ops "$@"
}

run_target_migration_ops() {
  run_migration_ops ops-cell-b "$@"
}

run_source_migration_step() {
  local step="$1"
  shift
  local output
  if ! output="$(run_source_migration_ops "$@" 2>&1)"; then
    printf 'multicell-smoke result=fail migration_step=%s\n' "${step}" >&2
    printf '%s\n' "${output}" >&2
    return 1
  fi
  printf 'multicell-smoke migration_step=%s result=completed\n' "${step}"
}

run_migration_ops() {
  local service="$1"
  shift
  compose run --rm -T --no-deps --entrypoint /bin/sh "${service}" -ec '
    : >/tmp/migration-ops.log
    ./IMServer ops --env production-smoke "$@" >/tmp/migration-ops.log 2>&1 &
    child=$!
    for attempt in $(seq 1 90); do
      if grep -Eq "^(conversation_shard_migration_|shard=)" /tmp/migration-ops.log; then
        kill "$child" 2>/dev/null || true
        wait "$child" 2>/dev/null || true
        cat /tmp/migration-ops.log
        exit 0
      fi
      if ! kill -0 "$child" 2>/dev/null; then
        set +e
        wait "$child"
        status=$?
        set -e
        cat /tmp/migration-ops.log
        exit "$status"
      fi
      sleep 1
    done
    cat /tmp/migration-ops.log
    kill "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    exit 1
  ' migration-ops "$@"
}

wait_for_source_migration_preflight() {
  local conversation_id="$1"
  for _ in $(seq 1 90); do
    local output
    output="$(run_source_migration_ops \
      --inspect-conversation-shard-migration \
      --conversation-id "${conversation_id}" \
      --target-cell cell-b \
      --target-shard shard-0 2>&1 || true)"
    if printf '%s\n' "${output}" | grep -Fq 'ready=true'; then
      return 0
    fi
    sleep 2
  done
  printf 'multicell-smoke result=fail reason=migration_preflight_not_ready conversation=%s\n' "${conversation_id}" >&2
  run_source_migration_ops \
    --inspect-conversation-shard-migration \
    --conversation-id "${conversation_id}" \
    --target-cell cell-b \
    --target-shard shard-0 >&2 || true
  return 1
}

require_cross_cell_tcp_recipient_relay() {
  local conversation_id="$1" owner_user_id="$2" owner_token="$3"
  case "${IM_MULTICELL_SMOKE_REQUIRE_GATEWAY_TCP_RELAY:-false}" in
    true|TRUE|1|yes|YES)
      ;;
    *)
      return 0
      ;;
  esac

  [[ "$(uname -s)" == "Darwin" ]] || {
    printf 'multicell-smoke result=fail reason=tcp_driver_requires_macos_load_generator\n' >&2
    return 1
  }
  require_command swift
  require_command rg

  local account_file receiver_log receiver_output receiver_pid client_message_id message_body
  account_file="$(mktemp)"
  receiver_log="${ROOT_DIR}/reports/multicell-smoke-cell-a-receiver.jsonl"
  receiver_output="${ROOT_DIR}/reports/multicell-smoke-cell-a-receiver.txt"
  mkdir -p "${ROOT_DIR}/reports"
  printf '%s,%s\n' "${PEER_EMAIL}" "${PASSWORD}" > "${account_file}"

  (
    cd "${ROOT_DIR}/LoadTests/TCPDriver"
    swift run -c release IMTCPLoadDriver \
      --profile custom \
      --base-url "${CELL_A_GATEWAY_URL}" \
      --tcp-host 127.0.0.1 \
      --tcp-port 9001 \
      --account-file "${account_file}" \
      --account-devices-per-user 1 \
      --conversation-id "${conversation_id}" \
      --connections 1 \
      --messages 0 \
      --active-conversation-users 1 \
      --hold-seconds 30 \
      --timeout-seconds 30 \
      --login-concurrency 1 \
      --connection-queue-pool-size 1 \
      --connection-log-file "${receiver_log}"
  ) > "${receiver_output}" 2>&1 &
  receiver_pid=$!

  local receiver_ready=false
  for _ in $(seq 1 120); do
    if [[ -f "${receiver_log}" ]] && rg -F '"event":"auth_ok_received"' "${receiver_log}" >/dev/null; then
      receiver_ready=true
      break
    fi
    if ! kill -0 "${receiver_pid}" 2>/dev/null; then
      break
    fi
    sleep 1
  done
  if [[ "${receiver_ready}" != true ]]; then
    kill "${receiver_pid}" 2>/dev/null || true
    wait "${receiver_pid}" 2>/dev/null || true
    rm -f "${account_file}"
    printf 'multicell-smoke result=fail reason=cell_a_tcp_receiver_auth_timeout output=%s\n' "${receiver_output}" >&2
    return 1
  fi

  client_message_id="multicell-tcp-relay-$(date +%s)-${RANDOM}"
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
        'content': {'type': 'rich_text', 'body': {'text': 'multicell tcp recipient relay', 'entities': []}},
        'derivedState': {
            'recallState': {'active': {}},
            'edits': [],
            'reactions': [],
            'streamState': None,
        },
    },
}))
PY
)"
  if ! request_json POST "${CELL_A_COMMAND_URL}/internal/im/messages/send" "${message_body}" "${owner_token}" "${INTERNAL_SECRET}" >/dev/null; then
    kill "${receiver_pid}" 2>/dev/null || true
    wait "${receiver_pid}" 2>/dev/null || true
    rm -f "${account_file}"
    return 1
  fi

  local delivered=false
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
    printf 'multicell-smoke result=fail reason=cell_a_tcp_receiver_failed output=%s\n' "${receiver_output}" >&2
    return 1
  }
  rm -f "${account_file}"

  if [[ "${delivered}" != true ]]; then
    printf 'multicell-smoke result=fail reason=cell_a_tcp_recipient_delivery_timeout receiverLog=%s receiverOutput=%s\n' \
      "${receiver_log}" "${receiver_output}" >&2
    return 1
  fi
  printf 'multicell-smoke tcpRecipientDelivery=true receiverCell=cell-a receiverLog=%s\n' "${receiver_log}"
}

metric_value() {
  local name="$1"
  awk -v name="$name" '$1 == name { print $2; found=1 } END { if (!found) print 0 }'
}

write_runtime_receipt() {
  local conversation_id="$1" fault_drill="$2" command_forwarded="$3" query_forwarded="$4"
  local compose_log git_commit git_branch git_dirty tcp_requested source_cross_cell_outbox_recovered
  mkdir -p "${REPORT_DIR}" "$(dirname "${RECEIPT_FILE}")"
  compose_log="${REPORT_DIR}/multicell-smoke-$(date -u +%Y%m%dT%H%M%SZ).log"
  compose logs --no-color --tail=500 >"${compose_log}" 2>&1 || true
  git_commit="$(git -C "${ROOT_DIR}/.." rev-parse HEAD 2>/dev/null || printf unknown)"
  git_branch="$(git -C "${ROOT_DIR}/.." branch --show-current 2>/dev/null || true)"
  [[ -n "${git_branch}" ]] || git_branch=detached
  git_dirty=false
  [[ -z "$(git -C "${ROOT_DIR}/.." status --porcelain 2>/dev/null || printf dirty)" ]] || git_dirty=true
  case "${IM_MULTICELL_SMOKE_REQUIRE_GATEWAY_TCP_RELAY:-false}" in
    true|TRUE|1|yes|YES) tcp_requested=true ;;
    *) tcp_requested=false ;;
  esac
  case "${fault_drill}" in
    target-gateway-outage) source_cross_cell_outbox_recovered=true ;;
    *) source_cross_cell_outbox_recovered=false ;;
  esac
  python3 - "${RECEIPT_FILE}" "${compose_log}" "${conversation_id}" "${fault_drill}" \
    "${command_forwarded}" "${query_forwarded}" "${tcp_requested}" "${source_cross_cell_outbox_recovered}" \
    "${git_commit}" "${git_branch}" "${git_dirty}" <<'PY'
import json
import sys
from datetime import datetime, timezone

(
    receipt_path,
    compose_log,
    conversation_id,
    fault_drill,
    command_forwarded,
    query_forwarded,
    tcp_requested,
    source_cross_cell_outbox_recovered,
    git_commit,
    git_branch,
    git_dirty,
) = sys.argv[1:]

payload = {
    "schemaVersion": 1,
    "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "status": "passed",
    "exitCode": 0,
    "runtimeEvidence": True,
    "environment": "multicell-smoke",
    "project": "imserver-multicell-smoke",
    "conversationID": conversation_id,
    "physicalMigration": True,
    "targetOutboxRecovered": True,
    "sourceCrossCellOutboxRecovered": source_cross_cell_outbox_recovered == "true",
    "faultDrill": fault_drill or None,
    "tcpRecipientDelivery": {
        "required": tcp_requested == "true",
        "verified": tcp_requested == "true",
    },
    "remoteCellForwardSuccesses": {
        "command": int(float(command_forwarded)),
        "query": int(float(query_forwarded)),
    },
    "source": {
        "gitCommit": git_commit,
        "gitBranch": git_branch,
        "gitDirty": git_dirty == "true",
    },
    "artifacts": {"composeLog": compose_log},
}
with open(receipt_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

write_failed_runtime_receipt() {
  local fault_drill="$1" exit_code="$2"
  local compose_log git_commit git_branch git_dirty
  mkdir -p "${REPORT_DIR}" "$(dirname "${RECEIPT_FILE}")"
  compose_log="${REPORT_DIR}/multicell-smoke-failed-$(date -u +%Y%m%dT%H%M%SZ).log"
  compose logs --no-color --tail=500 >"${compose_log}" 2>&1 || true
  git_commit="$(git -C "${ROOT_DIR}/.." rev-parse HEAD 2>/dev/null || printf unknown)"
  git_branch="$(git -C "${ROOT_DIR}/.." branch --show-current 2>/dev/null || true)"
  [[ -n "${git_branch}" ]] || git_branch=detached
  git_dirty=false
  [[ -z "$(git -C "${ROOT_DIR}/.." status --porcelain 2>/dev/null || printf dirty)" ]] || git_dirty=true
  python3 - "${RECEIPT_FILE}" "${compose_log}" "${fault_drill}" "${exit_code}" \
    "${git_commit}" "${git_branch}" "${git_dirty}" <<'PY'
import json
import sys
from datetime import datetime, timezone

receipt_path, compose_log, fault_drill, exit_code, git_commit, git_branch, git_dirty = sys.argv[1:]
payload = {
    "schemaVersion": 1,
    "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "status": "failed",
    "exitCode": int(exit_code),
    "runtimeEvidence": True,
    "environment": "multicell-smoke",
    "project": "imserver-multicell-smoke",
    "conversationID": None,
    "physicalMigration": False,
    "targetOutboxRecovered": False,
    "sourceCrossCellOutboxRecovered": False,
    "faultDrill": fault_drill or None,
    "tcpRecipientDelivery": {"required": False, "verified": False},
    "remoteCellForwardSuccesses": {"command": 0, "query": 0},
    "source": {"gitCommit": git_commit, "gitBranch": git_branch, "gitDirty": git_dirty == "true"},
    "artifacts": {"composeLog": compose_log},
}
with open(receipt_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

on_run_error() {
  local fault_drill="$1" exit_code="$2"
  trap - ERR
  write_failed_runtime_receipt "${fault_drill}" "${exit_code}" || true
  return "${exit_code}"
}

up_stack() {
  IM_SMOKE_COMPOSE_EXTRA_FILE="${COMPOSE_OVERLAY}" \
    COMPOSE_PROJECT_NAME="${PROJECT_NAME}" \
    "${BASE_SMOKE_SCRIPT}" up
  compose up -d \
    gateway-cell-b command-api-cell-b query-api-cell-b outbox-relay-cell-b \
    stream-consumer-summary-cell-b stream-consumer-changes-cell-b \
    stream-consumer-search-cell-b stream-consumer-notification-cell-b \
    stream-consumer-repair-cell-b stream-consumer-domain-cell-b \
    stream-consumer-realtime-cell-b
  wait_for_http cell-b-gateway "${CELL_B_GATEWAY_URL}"
  wait_for_http cell-b-command "${CELL_B_COMMAND_URL}"
  wait_for_http cell-b-query "${CELL_B_QUERY_URL}"
  wait_for_http cell-a-command "${CELL_A_COMMAND_URL}"
  wait_for_http cell-a-query "${CELL_A_QUERY_URL}"
}

down_stack() {
  IM_SMOKE_COMPOSE_EXTRA_FILE="${COMPOSE_OVERLAY}" \
    COMPOSE_PROJECT_NAME="${PROJECT_NAME}" \
    "${BASE_SMOKE_SCRIPT}" down
}

outbox_is_drained() {
  local inspect="$1" pending claimed failed
  [[ "${inspect}" == *"shard="* ]] || return 1
  pending="$(printf '%s\n' "${inspect}" | awk -F'[ =]' '/^shard=/{for(i=1;i<=NF;i++) if($i=="pending") print $(i+1)}' | awk '{s+=$1} END{print s+0}')"
  claimed="$(printf '%s\n' "${inspect}" | awk -F'[ =]' '/^shard=/{for(i=1;i<=NF;i++) if($i=="claimed") print $(i+1)}' | awk '{s+=$1} END{print s+0}')"
  failed="$(printf '%s\n' "${inspect}" | awk -F'[ =]' '/^shard=/{for(i=1;i<=NF;i++) if($i=="failed") print $(i+1)}' | awk '{s+=$1} END{print s+0}')"
  [[ "${pending}" == 0 && "${claimed}" == 0 && "${failed}" == 0 ]]
}

wait_for_target_outbox_recovery() {
  for _ in $(seq 1 90); do
    local inspect
    inspect="$(run_target_migration_ops --inspect-conversation-outbox 2>/dev/null || true)"
    if outbox_is_drained "${inspect}"; then
      return 0
    fi
    sleep 2
  done
  printf 'multicell-smoke result=fail reason=target_outbox_not_drained\n' >&2
  run_target_migration_ops --inspect-conversation-outbox >&2 || true
  return 1
}

require_cell_b_dead_letter_empty() {
  local output
  output="$(compose exec -T redpanda sh -ec '
    timeout 3 rpk topic consume \
      --brokers redpanda:9092 \
      --offset start \
      --num 1 \
      conversation-domain-events-cell-b-dead-letter 2>/dev/null || true
  ' || true)"
  if [[ -n "$(printf '%s' "${output}" | tr -d '[:space:]')" ]]; then
    printf 'multicell-smoke result=fail reason=cell_b_dead_letter_not_empty payload=%s\n' "${output}" >&2
    return 1
  fi
}

source_cross_cell_dispatch_counts() {
  compose exec -T postgres psql -X -q -A -t \
    -U imserver -d imserver_smoke \
    -c "SELECT COUNT(*), COUNT(*) FILTER (WHERE status = 'delivered'), COUNT(*) FILTER (WHERE status = 'pending'), COUNT(*) FILTER (WHERE status = 'processing') FROM im_cross_cell_realtime_dispatches WHERE origin_cell_id = 'cell-b' AND target_cell_id = 'cell-a'"
}

wait_for_source_cross_cell_dispatch_pending_after() {
  local baseline_total="$1"
  for _ in $(seq 1 60); do
    local total delivered pending processing
    read -r total delivered pending processing <<< "$(source_cross_cell_dispatch_counts)"
    if [[ "${total}" -gt "${baseline_total}" && "${pending}" -gt 0 ]]; then
      return 0
    fi
    sleep 1
  done
  printf 'multicell-smoke result=fail reason=source_cross_cell_dispatch_not_pending baseline=%s counts=%s\n' \
    "${baseline_total}" "$(source_cross_cell_dispatch_counts)" >&2
  return 1
}

wait_for_source_cross_cell_dispatch_recovery_after() {
  local baseline_total="$1" baseline_delivered="$2"
  for _ in $(seq 1 90); do
    local total delivered pending processing
    read -r total delivered pending processing <<< "$(source_cross_cell_dispatch_counts)"
    if [[ "${total}" -gt "${baseline_total}" && "${delivered}" -gt "${baseline_delivered}" \
      && "${pending}" == 0 && "${processing}" == 0 ]]; then
      return 0
    fi
    sleep 1
  done
  printf 'multicell-smoke result=fail reason=source_cross_cell_dispatch_not_recovered baselineTotal=%s baselineDelivered=%s counts=%s\n' \
    "${baseline_total}" "${baseline_delivered}" "$(source_cross_cell_dispatch_counts)" >&2
  return 1
}

start_cell_a_tcp_presence_for_gateway_outage() {
  case "${IM_MULTICELL_SMOKE_REQUIRE_GATEWAY_TCP_RELAY:-false}" in
    true|TRUE|1|yes|YES)
      ;;
    *)
      printf 'multicell-smoke result=fail reason=target_gateway_outage_requires_gateway_tcp_relay\n' >&2
      return 2
      ;;
  esac
  [[ "$(uname -s)" == "Darwin" ]] || {
    printf 'multicell-smoke result=fail reason=target_gateway_outage_requires_macos_tcp_driver\n' >&2
    return 2
  }
  require_command swift
  require_command rg

  local account_file receiver_log receiver_output receiver_pid hold_seconds
  account_file="$(mktemp)"
  receiver_log="${ROOT_DIR}/reports/multicell-smoke-target-gateway-outage-receiver.jsonl"
  receiver_output="${ROOT_DIR}/reports/multicell-smoke-target-gateway-outage-receiver.txt"
  hold_seconds="${IM_MULTICELL_SMOKE_TARGET_GATEWAY_OUTAGE_HOLD_SECONDS:-120}"
  mkdir -p "${ROOT_DIR}/reports"
  printf '%s,%s\n' "${PEER_EMAIL}" "${PASSWORD}" > "${account_file}"

  (
    cd "${ROOT_DIR}/LoadTests/TCPDriver"
    swift run -c release IMTCPLoadDriver \
      --profile custom \
      --base-url "${CELL_A_GATEWAY_URL}" \
      --tcp-host 127.0.0.1 \
      --tcp-port 9001 \
      --account-file "${account_file}" \
      --account-devices-per-user 1 \
      --conversation-id "$1" \
      --connections 1 \
      --messages 0 \
      --active-conversation-users 1 \
      --hold-seconds "${hold_seconds}" \
      --timeout-seconds 30 \
      --login-concurrency 1 \
      --connection-queue-pool-size 1 \
      --connection-log-file "${receiver_log}"
  ) > "${receiver_output}" 2>&1 &
  receiver_pid=$!

  for _ in $(seq 1 120); do
    if [[ -f "${receiver_log}" ]] && rg -F '"event":"auth_ok_received"' "${receiver_log}" >/dev/null; then
      TARGET_GATEWAY_OUTAGE_RECEIVER_PID="${receiver_pid}"
      TARGET_GATEWAY_OUTAGE_RECEIVER_ACCOUNT_FILE="${account_file}"
      TARGET_GATEWAY_OUTAGE_RECEIVER_OUTPUT="${receiver_output}"
      return 0
    fi
    if ! kill -0 "${receiver_pid}" 2>/dev/null; then
      break
    fi
    sleep 1
  done
  kill "${receiver_pid}" 2>/dev/null || true
  wait "${receiver_pid}" 2>/dev/null || true
  rm -f "${account_file}"
  printf 'multicell-smoke result=fail reason=target_gateway_outage_receiver_auth_timeout output=%s\n' "${receiver_output}" >&2
  return 1
}

stop_cell_a_tcp_presence_for_gateway_outage() {
  if [[ -n "${TARGET_GATEWAY_OUTAGE_RECEIVER_PID:-}" ]]; then
    kill "${TARGET_GATEWAY_OUTAGE_RECEIVER_PID}" 2>/dev/null || true
    wait "${TARGET_GATEWAY_OUTAGE_RECEIVER_PID}" 2>/dev/null || true
  fi
  rm -f "${TARGET_GATEWAY_OUTAGE_RECEIVER_ACCOUNT_FILE:-}"
}

wait_for_timeline_message() {
  local conversation_id="$1" token="$2" expected_client_message_id="$3" target_sequence="${4:-}"
  local target_sequence_query=""
  if [[ -n "${target_sequence}" ]]; then
    target_sequence_query="&targetSequence=${target_sequence}"
  fi
  for _ in $(seq 1 60); do
    local timeline
    timeline="$(request_json GET "${CELL_A_QUERY_URL}/api/im/conversations/${conversation_id}/timeline/since?afterSequence=0&limit=50${target_sequence_query}" "" "${token}" 2>/dev/null || true)"
    if [[ -n "${timeline}" ]] && printf '%s' "${timeline}" | assert_timeline_contains_message "${expected_client_message_id}"; then
      return 0
    fi
    sleep 2
  done
  printf 'multicell-smoke result=fail reason=post_recovery_timeline_message_missing message=%s\n' "${expected_client_message_id}" >&2
  return 1
}

run_post_cutover_fault_drill() {
  local scenario="$1" conversation_id="$2" owner_token="$3" owner_user_id="$4"
  local message_id pause_seconds
  pause_seconds="${IM_MULTICELL_SMOKE_FAULT_PAUSE_SECONDS:-15}"
  case "${scenario}" in
    redis-outage)
      compose stop redis
      sleep "${pause_seconds}"
      compose start redis
      wait_for_http cell-a-command "${CELL_A_COMMAND_URL}"
      ;;
    kafka-outage)
      compose stop kafka
      message_id="multicell-kafka-outage-$(date +%s)-${RANDOM}"
      send_internal_message_at \
        "${CELL_A_COMMAND_URL}" "${owner_token}" "${owner_user_id}" "${conversation_id}" \
        "${message_id}" "queued while Kafka is unavailable"
      sleep "${pause_seconds}"
      compose start kafka
      wait_for_http cell-a-command "${CELL_A_COMMAND_URL}"
      ;;
    target-gateway-outage)
      start_cell_a_tcp_presence_for_gateway_outage "${conversation_id}"
      local baseline_total baseline_delivered baseline_pending baseline_processing
      read -r baseline_total baseline_delivered baseline_pending baseline_processing <<< "$(source_cross_cell_dispatch_counts)"
      compose kill -s SIGKILL gateway
      message_id="multicell-target-gateway-outage-$(date +%s)-${RANDOM}"
      send_internal_message_at \
        "${CELL_A_COMMAND_URL}" "${owner_token}" "${owner_user_id}" "${conversation_id}" \
        "${message_id}" "queued while target Gateway is unavailable"
      wait_for_source_cross_cell_dispatch_pending_after "${baseline_total}"
      compose up -d gateway
      wait_for_http cell-a-gateway "${CELL_A_GATEWAY_URL}"
      wait_for_source_cross_cell_dispatch_recovery_after "${baseline_total}" "${baseline_delivered}"
      stop_cell_a_tcp_presence_for_gateway_outage
      ;;
    *)
      printf 'multicell-smoke result=fail reason=unsupported_failure_drill scenario=%s\n' "${scenario}" >&2
      return 2
      ;;
  esac

  if [[ "${scenario}" == redis-outage ]]; then
    message_id="multicell-redis-recovery-$(date +%s)-${RANDOM}"
    send_internal_message_at \
      "${CELL_A_COMMAND_URL}" "${owner_token}" "${owner_user_id}" "${conversation_id}" \
      "${message_id}" "after Redis recovery"
  fi
  wait_for_timeline_message "${conversation_id}" "${owner_token}" "${message_id}"
  wait_for_target_outbox_recovery
  printf 'multicell-smoke faultDrill=%s postRecoveryMessage=%s targetOutboxRecovered=true\n' \
    "${scenario}" "${message_id}"
}

self_test() {
  require_command python3
  local remote_probe_script="${ROOT_DIR}/scripts/multicell_remote_tcp_relay_probe.sh"
  bash -n "${BASE_SMOKE_SCRIPT}" "${BASH_SOURCE[0]}" "${remote_probe_script}"
  python3 - "${COMPOSE_OVERLAY}" "${BASH_SOURCE[0]}" "${remote_probe_script}" <<'PY'
from pathlib import Path
import sys

compose = Path(sys.argv[1]).read_text(encoding='utf-8')
script = Path(sys.argv[2]).read_text(encoding='utf-8')
remote_probe = Path(sys.argv[3])
required_compose = (
    'postgres-cell-b:',
    'ops-cell-b:',
    'imserver_smoke_cell_b',
    'gateway-cell-b:',
    'command-api-cell-b:',
    'query-api-cell-b:',
    'outbox-relay-cell-b:',
    'stream-consumer-summary-cell-b:',
    'stream-consumer-changes-cell-b:',
    'stream-consumer-search-cell-b:',
    'stream-consumer-notification-cell-b:',
    'stream-consumer-repair-cell-b:',
    'stream-consumer-domain-cell-b:',
    'stream-consumer-realtime-cell-b:',
    'conversation-domain-events-cell-b',
    'IM_CELL_INGRESS_COMMAND_ENDPOINTS:',
    'IM_CELL_INGRESS_QUERY_ENDPOINTS:',
    'IM_CELL_INGRESS_REALTIME_ENDPOINTS:',
    'IM_REALTIME_CELL_ID: cell-b',
    'IM_COMMAND_NODE_ID: command-b',
    'file: docker-compose.production-smoke.yml',
    'ports: !override',
)
required_script = (
    'physical Cell A -> Cell B conversation migration',
    'gateway-cell-b command-api-cell-b query-api-cell-b',
    'run_source_migration_ops',
    '--prepare-conversation-shard-migration',
    '--copy-conversation-shard-migration',
    '--verify-conversation-shard-migration',
    '--cutover-conversation-shard-migration',
    'im_conversation_shard_remote_cell_forward_successes_total',
    'assert_timeline_contains_message',
    'IM_MULTICELL_SMOKE_REQUIRE_GATEWAY_TCP_RELAY',
    'multicell_remote_tcp_relay_probe.sh',
    'cell_a_tcp_recipient_delivery_timeout',
    'wait_for_target_outbox_recovery',
    'require_cell_b_dead_letter_empty',
    'run_post_cutover_fault_drill',
    'kafka-outage',
    'target-gateway-outage',
    'source_cross_cell_dispatch_counts',
    'wait_for_source_cross_cell_dispatch_pending_after',
    'wait_for_source_cross_cell_dispatch_recovery_after',
    'write_runtime_receipt',
    'write_failed_runtime_receipt',
    'on_run_error',
    'latest-multicell-smoke.json',
)
missing = [value for value in required_compose if value not in compose]
missing += [value for value in required_script if value not in script]
if not remote_probe.is_file():
    missing.append(str(remote_probe))
if missing:
    raise SystemExit(f"multicell-smoke-self-test result=fail missing={','.join(missing)}")
print('multicell-smoke-self-test result=pass')
PY
}

run_smoke() {
  local fault_drill="${1:-}"
  trap 'on_run_error "${fault_drill}" "$?"' ERR
  down_stack || true
  up_stack

  local owner_response peer_response owner_token owner_user_id peer_token peer_user_id conversation_body conversation_response conversation_id
  owner_response="$(register_or_login "${OWNER_EMAIL}" "multicell-owner")"
  peer_response="$(register_or_login "${PEER_EMAIL}" "multicell-peer")"
  owner_token="$(printf '%s' "${owner_response}" | json_get auth.accessToken)"
  owner_user_id="$(printf '%s' "${owner_response}" | json_get auth.user.id)"
  peer_token="$(printf '%s' "${peer_response}" | json_get auth.accessToken)"
  peer_user_id="$(printf '%s' "${peer_response}" | json_get auth.user.id)"

  conversation_body="$(python3 - "$PEER_EMAIL" <<'PY'
import json
import sys
print(json.dumps({'kind': 'direct', 'title': None, 'memberEmails': [sys.argv[1]]}))
PY
)"
  conversation_response="$(request_json POST "${CELL_A_COMMAND_URL}/api/im/conversations" "${conversation_body}" "${owner_token}")"
  conversation_id="$(printf '%s' "${conversation_response}" | conversation_id_from_response)"

  local source_message_id migrated_message_id timeline command_metrics query_metrics command_forwarded query_forwarded
  source_message_id="multicell-source-$(date +%s)-${RANDOM}"
  send_internal_message_at \
    "${CELL_A_COMMAND_URL}" "${owner_token}" "${owner_user_id}" "${conversation_id}" \
    "${source_message_id}" "before physical Cell migration" >/dev/null
  wait_for_source_migration_preflight "${conversation_id}"

  run_source_migration_step prepare \
    --prepare-conversation-shard-migration \
    --conversation-id "${conversation_id}" \
    --target-cell cell-b \
    --target-shard shard-0
  run_source_migration_step copy \
    --copy-conversation-shard-migration \
    --conversation-id "${conversation_id}" \
    --page-size 100
  run_source_migration_step verify \
    --verify-conversation-shard-migration \
    --conversation-id "${conversation_id}" \
    --page-size 100
  run_source_migration_step cutover \
    --cutover-conversation-shard-migration \
    --conversation-id "${conversation_id}" \
    --page-size 100

  local migrated_message_response migrated_target_sequence
  migrated_message_id="multicell-cutover-$(date +%s)-${RANDOM}"
  migrated_message_response="$(send_internal_message_at \
    "${CELL_A_COMMAND_URL}" "${peer_token}" "${peer_user_id}" "${conversation_id}" \
    "${migrated_message_id}" "peer reply after Cell A to Cell B cutover")"
  migrated_target_sequence="$(printf '%s' "${migrated_message_response}" | json_get message.serverSequence)"
  [[ -n "${migrated_target_sequence}" ]] || {
    printf 'multicell-smoke result=fail reason=missing_post_cutover_message_sequence\n' >&2
    return 1
  }

  # The target Cell accepts the post-cutover write before every query-side
  # cache/consumer has observed it. Verify the eventual read contract instead
  # of treating the first query's short visibility window as a migration error.
  wait_for_timeline_message "${conversation_id}" "${owner_token}" "${source_message_id}" "${migrated_target_sequence}"
  wait_for_timeline_message "${conversation_id}" "${owner_token}" "${migrated_message_id}" "${migrated_target_sequence}"
  command_metrics="$(request_json GET "${CELL_A_COMMAND_URL}/internal/metrics" "" "" "${INTERNAL_SECRET}")"
  query_metrics="$(request_json GET "${CELL_A_QUERY_URL}/internal/metrics" "" "" "${INTERNAL_SECRET}")"
  command_forwarded="$(printf '%s\n' "${command_metrics}" | metric_value im_conversation_shard_remote_cell_forward_successes_total)"
  query_forwarded="$(printf '%s\n' "${query_metrics}" | metric_value im_conversation_shard_remote_cell_forward_successes_total)"
  [[ "${command_forwarded}" -ge 1 && "${query_forwarded}" -ge 1 ]] || {
    printf 'multicell-smoke result=fail reason=missing_post_cutover_forward_metric command=%s query=%s\n' \
      "${command_forwarded}" "${query_forwarded}" >&2
    return 1
  }
  wait_for_target_outbox_recovery
  require_cell_b_dead_letter_empty
  require_cross_cell_tcp_recipient_relay "${conversation_id}" "${owner_user_id}" "${owner_token}"
  if [[ -n "${fault_drill}" ]]; then
    run_post_cutover_fault_drill "${fault_drill}" "${conversation_id}" "${owner_token}" "${owner_user_id}"
  fi
  write_runtime_receipt "${conversation_id}" "${fault_drill}" "${command_forwarded}" "${query_forwarded}"
  trap - ERR

  printf 'multicell-smoke result=pass conversation=%s physicalMigration=true tcpRecipientDelivery=%s commandForwardSuccesses=%s queryForwardSuccesses=%s receipt=%s\n' \
    "${conversation_id}" "${IM_MULTICELL_SMOKE_REQUIRE_GATEWAY_TCP_RELAY:-false}" "${command_forwarded}" "${query_forwarded}" "${RECEIPT_FILE}"
}

case "${1:-}" in
  up)
    require_compose_version
    up_stack
    ;;
  run)
    require_compose_version
    run_smoke
    ;;
  failure-drill)
    require_compose_version
    [[ -n "${2:-}" ]] || { usage >&2; exit 2; }
    run_smoke "${2}"
    ;;
  down)
    require_compose_version
    down_stack
    ;;
  logs)
    require_compose_version
    compose logs --no-color --tail="${LOG_TAIL:-300}"
    ;;
  self-test)
    self_test
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
