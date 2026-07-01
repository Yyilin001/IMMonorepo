#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.production-smoke.yml"
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-imserver-production-smoke}"
REPORT_DIR="${ROOT_DIR}/reports"
STATE_FILE="${REPORT_DIR}/production-smoke-state.env"
REPORT_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT_FILE="${REPORT_DIR}/${REPORT_STAMP}-production-smoke.md"
RECEIPT_FILE="${REPORT_DIR}/${REPORT_STAMP}-production-smoke.json"
LATEST_RECEIPT_FILE="${REPORT_DIR}/latest-production-smoke.json"

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
Usage: production_smoke.sh <up|run|down|logs|self-test>

Commands:
  up     Build image, start infra, run ops migrations, and start all production roles.
  run    Reset the smoke stack, start it, execute HTTP/Kafka/summary checks, and write a report.
  down   Stop the stack and remove smoke volumes.
  logs   Print role and infra logs.
  self-test
         Validate static production-smoke config that does not require Docker.
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
    if curl -fsS "${url}/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "Timed out waiting for ${name}" >&2
  return 1
}

compose_container_health_status() {
  local service="$1"
  local container_id
  container_id="$(compose ps -q "${service}" 2>/dev/null | head -n 1)"
  if [[ -z "${container_id}" ]]; then
    echo "missing missing"
    return 0
  fi
  docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${container_id}" 2>/dev/null || echo "missing missing"
}

wait_for_compose_service_health() {
  local service="$1"
  echo "Waiting for ${service} container health"
  for _ in $(seq 1 90); do
    local state health
    read -r state health < <(compose_container_health_status "${service}")
    if [[ "${state}" == "running" && ( "${health}" == "healthy" || "${health}" == "none" ) ]]; then
      return 0
    fi
    if [[ "${state}" == "exited" || "${state}" == "dead" ]]; then
      echo "Service ${service} stopped while waiting for health: state=${state} health=${health}" >&2
      compose logs --no-color --tail=80 "${service}" >&2 || true
      return 1
    fi
    sleep 2
  done
  echo "Timed out waiting for ${service} container health" >&2
  compose ps "${service}" >&2 || true
  compose logs --no-color --tail=80 "${service}" >&2 || true
  return 1
}

wait_for_runtime_services_health() {
  local services=(
    gateway
    command-api
    query-api
    outbox-relay
    stream-consumer-summary
    stream-consumer-changes
    stream-consumer-search
    stream-consumer-notification
    stream-consumer-repair
    stream-consumer-domain
    stream-consumer-realtime
  )
  local service
  for service in "${services[@]}"; do
    wait_for_compose_service_health "${service}"
  done
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
        "content": {"type": "rich_text", "body": {"text": sys.argv[4], "entities": []}},
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
    inspect="$(compose run --rm ops ops --env production-smoke --inspect-conversation-outbox 2>/dev/null || true)"
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
  compose run --rm ops ops --env production-smoke --inspect-conversation-outbox >&2 || true
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
  local _access_token="$1"
  local owner_user_id="$2"
  local direct_conversation_id="$3"
  local group_conversation_id="$4"
  mkdir -p "${REPORT_DIR}"
  {
    printf 'GATEWAY_URL=%q\n' "${GATEWAY_URL}"
    printf 'COMMAND_URL=%q\n' "${COMMAND_URL}"
    printf 'QUERY_URL=%q\n' "${QUERY_URL}"
    printf 'OWNER_USER_ID=%q\n' "${owner_user_id}"
    printf 'DIRECT_CONVERSATION_ID=%q\n' "${direct_conversation_id}"
    printf 'GROUP_CONVERSATION_ID=%q\n' "${group_conversation_id}"
  } > "${STATE_FILE}"
}

write_smoke_receipt() {
  local generated_at="$1"
  local direct_conversation_id="$2"
  local group_conversation_id="$3"
  python3 - \
    "${generated_at}" \
    "${PROJECT_NAME}" \
    "${COMPOSE_FILE}" \
    "${REPORT_FILE}" \
    "${STATE_FILE}" \
    "${REPORT_DIR}/production-smoke-compose-ps.txt" \
    "${REPORT_DIR}/production-smoke-compose.log" \
    "${REPORT_DIR}/production-smoke-outbox-inspect.txt" \
    "${direct_conversation_id}" \
    "${group_conversation_id}" \
    "${GATEWAY_URL}" \
    "${COMMAND_URL}" \
    "${QUERY_URL}" \
    "${RECEIPT_FILE}" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

(
    generated_at,
    project,
    compose_file,
    report_file,
    state_file,
    compose_ps_file,
    compose_log_file,
    outbox_inspect_file,
    direct_conversation_id,
    group_conversation_id,
    gateway_url,
    command_url,
    query_url,
    receipt_file,
) = sys.argv[1:]

def git_value(*args: str) -> str:
    try:
        return subprocess.check_output(["git", *args], text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        return ""

dirty = bool(git_value("status", "--porcelain"))
payload = {
    "schemaVersion": 1,
    "generatedAt": generated_at,
    "status": "passed",
    "exitCode": 0,
    "environment": "production-smoke",
    "project": project,
    "runtimeEvidence": True,
    "composeFile": compose_file,
    "endpoints": {
        "gateway": gateway_url,
        "command": command_url,
        "query": query_url,
    },
    "conversations": {
        "directConversationID": direct_conversation_id,
        "groupConversationID": group_conversation_id,
    },
    "source": {
        "gitCommit": git_value("rev-parse", "HEAD"),
        "gitBranch": git_value("rev-parse", "--abbrev-ref", "HEAD"),
        "gitDirty": dirty,
    },
    "artifacts": {
        "markdownReport": report_file,
        "stateFile": state_file,
        "composePs": compose_ps_file,
        "composeLog": compose_log_file,
        "outboxInspect": outbox_inspect_file,
    },
    "checks": [
        {"name": "docker_compose_runtime_roles", "status": "passed"},
        {"name": "runtime_services_health", "status": "passed"},
        {"name": "http_health", "status": "passed"},
        {"name": "auth_register_or_login", "status": "passed"},
        {"name": "conversation_create", "status": "passed"},
        {"name": "message_write", "status": "passed"},
        {"name": "summary_projection", "status": "passed"},
        {"name": "changes_projection", "status": "passed"},
        {"name": "messages_since", "status": "passed"},
        {"name": "metrics_secret", "status": "passed"},
        {"name": "outbox_recovery", "status": "passed"},
    ],
}
path = Path(receipt_file)
path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
  cp "${RECEIPT_FILE}" "${LATEST_RECEIPT_FILE}"
}

collect_logs() {
  mkdir -p "${REPORT_DIR}"
  compose ps > "${REPORT_DIR}/production-smoke-compose-ps.txt" 2>&1 || true
  compose logs --no-color --tail=300 > "${REPORT_DIR}/production-smoke-compose.log" 2>&1 || true
}

print_diagnostics() {
  echo "Collecting production smoke diagnostics" >&2
  collect_logs
  compose run --rm ops ops --env production-smoke --inspect-conversation-outbox >&2 || true
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
    stream-consumer-repair \
    stream-consumer-domain \
    stream-consumer-realtime

  wait_for_runtime_services_health
  wait_for_http gateway "${GATEWAY_URL}"
  wait_for_http command-api "${COMMAND_URL}"
  wait_for_http query-api "${QUERY_URL}"
}

down_stack() {
  compose down --volumes --remove-orphans
}

production_smoke_config_self_test() {
  require_command python3
  python3 - "${COMPOSE_FILE}" "${BASH_SOURCE[0]}" <<'PY'
import re
import sys
from pathlib import Path

compose_path = Path(sys.argv[1])
script_path = Path(sys.argv[2])
text = compose_path.read_text(encoding="utf-8")
script_text = script_path.read_text(encoding="utf-8")

def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"production-smoke-config-self-test result=fail reason={message}")

def value_for(key: str) -> str:
    match = re.search(rf"^\s*{re.escape(key)}:\s*\"?([^\"\n]+)\"?\s*$", text, re.MULTILINE)
    require(match is not None, f"missing_{key}")
    return match.group(1).strip()

def compose_service_names() -> set[str]:
    services = set()
    in_services = False
    for line in text.splitlines():
        if line == "services:":
            in_services = True
            continue
        if not in_services:
            continue
        if line and not line.startswith(" ") and not line.startswith("#"):
            break
        match = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if match:
            services.add(match.group(1))
    return services

def service_block(service_name: str) -> str:
    pattern = rf"^  {re.escape(service_name)}:\n(?P<body>(?:    .*\n|      .*\n|        .*\n|          .*\n)*)"
    match = re.search(pattern, text, re.MULTILINE)
    require(match is not None, f"missing_service_block:{service_name}")
    return match.group("body")

def up_stack_services() -> set[str]:
    match = re.search(
        r"compose up -d \\\n(?P<body>.*?)(?:\n\n|\n\s*wait_for_http)",
        script_text,
        re.DOTALL,
    )
    require(match is not None, "missing_runtime_compose_up_block")
    services = set()
    for line in match.group("body").splitlines():
        stripped = line.strip().rstrip("\\").strip()
        if stripped:
            services.add(stripped)
    return services

def wait_for_http_body() -> str:
    match = re.search(
        r"wait_for_http\(\) \{\n(?P<body>.*?)\n\}",
        script_text,
        re.DOTALL,
    )
    require(match is not None, "missing_wait_for_http_function")
    return match.group("body")

def write_state_body() -> str:
    match = re.search(
        r"write_state\(\) \{\n(?P<body>.*?)\n\}",
        script_text,
        re.DOTALL,
    )
    require(match is not None, "missing_write_state_function")
    return match.group("body")

def runtime_health_wait_services() -> set[str]:
    match = re.search(
        r"wait_for_runtime_services_health\(\) \{\n(?P<body>.*?)\n\}",
        script_text,
        re.DOTALL,
    )
    require(match is not None, "missing_wait_for_runtime_services_health_function")
    array_match = re.search(r"local services=\(\n(?P<array>.*?)\n\s*\)", match.group("body"), re.DOTALL)
    require(array_match is not None, "missing_runtime_health_services_array")
    services = set()
    for line in array_match.group("array").splitlines():
        stripped = line.strip().strip('"').strip("'")
        if stripped:
            services.add(stripped)
    return services

access_key = value_for("MEDIA_STORAGE_S3_ACCESS_KEY_ID")
secret_key = value_for("MEDIA_STORAGE_S3_SECRET_ACCESS_KEY")
root_user = value_for("MINIO_ROOT_USER")
root_password = value_for("MINIO_ROOT_PASSWORD")
endpoint = value_for("MEDIA_STORAGE_S3_ENDPOINT")
allow_insecure = value_for("IM_PRODUCTION_ALLOW_INSECURE_MEDIA_STORAGE_ENDPOINT")
compose_services = compose_service_names()
started_services = up_stack_services()
health_wait_services = runtime_health_wait_services()
runtime_services = {
    "gateway",
    "command-api",
    "query-api",
    "outbox-relay",
} | {name for name in compose_services if name.startswith("stream-consumer-")}

placeholder_values = {
    "minioadmin",
    "access-key",
    "secret-key",
    "password",
    "password1234",
    "replace-me",
    "change_me",
    "changeme",
}
require(access_key == root_user, "minio_root_user_must_match_media_access_key")
require(secret_key == root_password, "minio_root_password_must_match_media_secret")
require(secret_key.lower() not in placeholder_values, "media_secret_must_not_be_placeholder")
require(len(secret_key) >= 16, "media_secret_min_length_16")
require(endpoint.startswith("http://minio:"), "smoke_endpoint_must_target_local_minio")
require(allow_insecure == "true", "local_minio_requires_explicit_insecure_endpoint_override")
require("minioadmin" not in text, "default_minioadmin_credentials_forbidden")
require(
    f"mc alias set smoke http://minio:9000 {access_key} {secret_key}" in text,
    "minio_init_alias_must_use_same_credentials",
)
require("compose run --rm ops" in script_text, "ops_migration_runner_must_start_before_runtime_roles")
outbox_inspect_commands = [
    line.strip()
    for line in script_text.splitlines()
    if "--inspect-conversation-outbox" in line
    and (line.strip().startswith('inspect="$(compose run --rm ops ops') or line.strip().startswith("compose run --rm ops ops"))
]
require(outbox_inspect_commands, "missing_outbox_inspect_commands")
for command in outbox_inspect_commands:
    require("--env production-smoke" in command, "outbox_inspect_must_use_smoke_env:" + command)
    require(
        re.search(r"--env\s+production(\s|$)", command) is None,
        "outbox_inspect_must_not_use_real_production_env:" + command,
    )
missing_runtime_services = sorted(runtime_services - started_services)
require(not missing_runtime_services, "runtime_services_not_started:" + ",".join(missing_runtime_services))
missing_health_wait_services = sorted(runtime_services - health_wait_services)
require(not missing_health_wait_services, "runtime_services_not_health_waited:" + ",".join(missing_health_wait_services))
http_wait_body = wait_for_http_body()
state_body = write_state_body()
require('curl -fsS "${url}/health"' in http_wait_body, "http_readiness_must_use_health_endpoint")
require('curl -fsS "${url}/hello"' not in http_wait_body, "http_readiness_must_not_use_hello_endpoint")
require("INTERNAL_SECRET" not in state_body, "state_file_must_not_persist_internal_secret")
require("OWNER_TOKEN" not in state_body, "state_file_must_not_persist_owner_token")
require("\n  wait_for_runtime_services_health\n" in script_text, "missing_runtime_services_health_wait_call")
require("wait_for_compose_service_health" in script_text, "missing_compose_service_health_wait")
require("docker inspect --format" in script_text, "compose_health_wait_must_inspect_container_state")
require("write_smoke_receipt()" in script_text, "missing_write_smoke_receipt_function")
require("latest-production-smoke.json" in script_text, "missing_latest_production_smoke_receipt")
require('"runtimeEvidence": True' in script_text, "smoke_receipt_must_mark_runtime_evidence")
require('"checks": [' in script_text, "smoke_receipt_must_include_checks")
require('"runtime_services_health"' in script_text, "smoke_receipt_must_include_runtime_health_check")
require("write_smoke_receipt \"${generated_at}\"" in script_text, "missing_write_smoke_receipt_call")
require("x-imserver-worker-healthcheck: &imserver_worker_healthcheck" in text, "missing_worker_healthcheck_anchor")
require('test: ["CMD-SHELL", "kill -0 1"]' in text, "worker_healthcheck_must_probe_pid1")
for service_name in sorted({"outbox-relay"} | {name for name in compose_services if name.startswith("stream-consumer-")}):
    require(
        "healthcheck: *imserver_worker_healthcheck" in service_block(service_name),
        f"worker_service_missing_worker_healthcheck:{service_name}",
    )

print("production-smoke-config-self-test result=pass")
PY
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
  compose run --rm ops ops --env production-smoke --inspect-conversation-outbox > "${REPORT_DIR}/production-smoke-outbox-inspect.txt"

  write_state "${owner_token}" "${owner_user_id}" "${direct_id}" "${group_id}"
  collect_logs

  local generated_at
  generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  {
    echo "# IMServer production smoke report"
    echo
    echo "- generated_at: ${generated_at}"
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
  write_smoke_receipt "${generated_at}" "${direct_id}" "${group_id}"

  echo "Production smoke passed: ${REPORT_FILE}"
  echo "Production smoke receipt: ${LATEST_RECEIPT_FILE}"
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
  self-test)
    production_smoke_config_self_test
    ;;
  *)
    usage
    exit 2
    ;;
esac
