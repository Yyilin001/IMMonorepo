#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SMOKE_SCRIPT="${ROOT_DIR}/scripts/production_smoke.sh"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.production-smoke.yml"
COMPOSE_EXTRA_FILE="${IM_SMOKE_COMPOSE_EXTRA_FILE:-}"
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-imserver-production-smoke}"
REPORT_DIR="${ROOT_DIR}/reports"
STATE_FILE="${REPORT_DIR}/production-smoke-state.env"
SCENARIO="${1:-}"

compose() {
  local args=(docker compose -p "${PROJECT_NAME}" -f "${COMPOSE_FILE}")
  if [[ -n "${COMPOSE_EXTRA_FILE}" ]]; then
    args+=(-f "${COMPOSE_EXTRA_FILE}")
  fi
  "${args[@]}" "$@"
}

usage() {
  cat <<'USAGE'
Usage: failure_drill.sh <restart-gateway|pause-stream-consumer|stop-outbox-relay|redis-outage>

The drill first runs production_smoke.sh run to reset and seed the smoke topology.
USAGE
}

if [[ -z "${SCENARIO}" || "${SCENARIO}" == "-h" || "${SCENARIO}" == "--help" ]]; then
  usage
  exit 2
fi

mkdir -p "${REPORT_DIR}"
REPORT_FILE="${REPORT_DIR}/$(date -u +%Y%m%dT%H%M%SZ)-failure-drill-${SCENARIO}.md"

"${SMOKE_SCRIPT}" run

# shellcheck source=/dev/null
source "${STATE_FILE}"

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
  status="$(curl "${args[@]}" "${url}")"
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

send_drill_message() {
  local text="$1"
  local body
  body="$(python3 - "$OWNER_USER_ID" "$DIRECT_CONVERSATION_ID" "drill-$(date +%s)-${RANDOM}" "$text" <<'PY'
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
        "derivedState": {"recallState": "active", "edits": [], "reactions": []}
    }
}))
PY
)"
  request_json POST "${COMMAND_URL}/internal/im/messages/send" "${body}" "${OWNER_TOKEN}" "${INTERNAL_SECRET}" >/dev/null
}

wait_for_gap_fill() {
  for _ in $(seq 1 60); do
    if request_json GET "${QUERY_URL}/api/im/conversations/${DIRECT_CONVERSATION_ID}/messages/since?afterSequence=0&limit=50" "" "${OWNER_TOKEN}" >/dev/null; then
      return 0
    fi
    sleep 2
  done
  echo "messages/since did not recover" >&2
  return 1
}

wait_for_outbox_recovery() {
  for _ in $(seq 1 60); do
    local inspect pending claimed failed
    inspect="$(compose run --rm ops ops --env production --inspect-conversation-outbox 2>/dev/null || true)"
    pending="$(printf '%s\n' "${inspect}" | awk -F'[ =]' '/^shard=/{for(i=1;i<=NF;i++) if($i=="pending") print $(i+1)}' | awk '{s+=$1} END{print s+0}')"
    claimed="$(printf '%s\n' "${inspect}" | awk -F'[ =]' '/^shard=/{for(i=1;i<=NF;i++) if($i=="claimed") print $(i+1)}' | awk '{s+=$1} END{print s+0}')"
    failed="$(printf '%s\n' "${inspect}" | awk -F'[ =]' '/^shard=/{for(i=1;i<=NF;i++) if($i=="failed") print $(i+1)}' | awk '{s+=$1} END{print s+0}')"
    if [[ "${pending}" == "0" && "${claimed}" == "0" && "${failed}" == "0" ]]; then
      return 0
    fi
    sleep 2
  done
  echo "Outbox did not recover" >&2
  compose run --rm ops ops --env production --inspect-conversation-outbox >&2 || true
  return 1
}

{
  echo "# IMServer failure drill report"
  echo
  echo "- generated_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- scenario: ${SCENARIO}"
  echo "- direct_conversation_id: ${DIRECT_CONVERSATION_ID}"
  echo
} > "${REPORT_FILE}"

send_drill_message "failure drill baseline ${SCENARIO}"

case "${SCENARIO}" in
  restart-gateway)
    compose restart gateway
    sleep 10
    send_drill_message "after gateway restart"
    ;;
  pause-stream-consumer)
    compose stop stream-consumer-summary stream-consumer-changes stream-consumer-search stream-consumer-notification stream-consumer-repair
    send_drill_message "during stream consumer pause"
    sleep "${IM_DRILL_PAUSE_SECONDS:-30}"
    compose start stream-consumer-summary stream-consumer-changes stream-consumer-search stream-consumer-notification stream-consumer-repair
    ;;
  stop-outbox-relay)
    compose stop outbox-relay
    send_drill_message "during outbox relay stop"
    sleep "${IM_DRILL_PAUSE_SECONDS:-30}"
    compose start outbox-relay
    ;;
  redis-outage)
    compose stop redis
    sleep "${IM_DRILL_REDIS_OUTAGE_SECONDS:-15}"
    compose start redis
    sleep 10
    send_drill_message "after redis outage"
    ;;
  *)
    echo "Unknown scenario: ${SCENARIO}" >&2
    usage
    exit 2
    ;;
esac

wait_for_gap_fill
wait_for_outbox_recovery
compose run --rm ops ops --env production --inspect-conversation-outbox > "${REPORT_DIR}/failure-drill-outbox-${SCENARIO}.txt"
compose logs --no-color --tail=300 > "${REPORT_DIR}/failure-drill-${SCENARIO}.log" 2>&1 || true

cat <<EOF >> "${REPORT_FILE}"
## Result

- messages_since_recovered: ok
- outbox_recovered: ok
- durable_message_loss: not_detected_by_smoke
- outbox_inspect: failure-drill-outbox-${SCENARIO}.txt
- logs: failure-drill-${SCENARIO}.log
EOF

echo "Failure drill passed: ${REPORT_FILE}"
