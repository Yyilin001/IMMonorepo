#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

LOCAL_ACCEPTANCE_SELF_TEST="${LOCAL_ACCEPTANCE_SELF_TEST:-false}"
LOCAL_ACCEPTANCE_PRINT_PLAN="${LOCAL_ACCEPTANCE_PRINT_PLAN:-false}"
LOCAL_ACCEPTANCE_START_STACK="${LOCAL_ACCEPTANCE_START_STACK:-true}"
if [[ -z "${LOCAL_ACCEPTANCE_BACKEND+x}" ]]; then
  if [[ "${LOCAL_ACCEPTANCE_START_STACK}" =~ ^(1|true|TRUE|yes|YES|on|ON)$ ]]; then
    LOCAL_ACCEPTANCE_BACKEND="swift-postgres"
  else
    LOCAL_ACCEPTANCE_BACKEND="none"
  fi
fi
LOCAL_ACCEPTANCE_RUN_PRODUCT_SCENARIOS="${LOCAL_ACCEPTANCE_RUN_PRODUCT_SCENARIOS:-false}"
LOCAL_ACCEPTANCE_RUN_HOT_CONVERSATION="${LOCAL_ACCEPTANCE_RUN_HOT_CONVERSATION:-false}"
LOCAL_ACCEPTANCE_RUN_MULTINODE_FAULT_CONTRACTS="${LOCAL_ACCEPTANCE_RUN_MULTINODE_FAULT_CONTRACTS:-false}"
LOCAL_ACCEPTANCE_HOT_CONVERSATION_PROFILE="${LOCAL_ACCEPTANCE_HOT_CONVERSATION_PROFILE:-local-hot-smoke}"
LOCAL_ACCEPTANCE_HOT_CONVERSATION_SETTLE_SECONDS="${LOCAL_ACCEPTANCE_HOT_CONVERSATION_SETTLE_SECONDS:-5}"
LOCAL_ACCEPTANCE_HOT_CONVERSATION_SEND_INTERVAL_MS="${LOCAL_ACCEPTANCE_HOT_CONVERSATION_SEND_INTERVAL_MS:-100}"
LOCAL_ACCEPTANCE_HOT_CONVERSATION_BATCH_ENABLED="${LOCAL_ACCEPTANCE_HOT_CONVERSATION_BATCH_ENABLED:-true}"
LOCAL_ACCEPTANCE_HOT_CONVERSATION_BATCH_MAX_SIZE="${LOCAL_ACCEPTANCE_HOT_CONVERSATION_BATCH_MAX_SIZE:-32}"
LOCAL_ACCEPTANCE_HOT_CONVERSATION_BATCH_MAX_DELAY_MS="${LOCAL_ACCEPTANCE_HOT_CONVERSATION_BATCH_MAX_DELAY_MS:-10}"
LOCAL_ACCEPTANCE_SUITE="${LOCAL_ACCEPTANCE_SUITE:-smoke}"
LOCAL_ACCEPTANCE_RUN_ID="${LOCAL_ACCEPTANCE_RUN_ID:-local-acceptance-$(date +%Y%m%d-%H%M%S)}"
LOCAL_ACCEPTANCE_RESULT_ROOT="${LOCAL_ACCEPTANCE_RESULT_ROOT:-${SCRIPT_DIR}/results/local-acceptance}"
LOCAL_ACCEPTANCE_BASE_URL="${LOCAL_ACCEPTANCE_BASE_URL:-http://127.0.0.1:8080}"
LOCAL_ACCEPTANCE_HTTP_HOST="${LOCAL_ACCEPTANCE_HTTP_HOST:-127.0.0.1}"
LOCAL_ACCEPTANCE_HTTP_PORT="${LOCAL_ACCEPTANCE_HTTP_PORT:-8080}"
LOCAL_ACCEPTANCE_TCP_HOST="${LOCAL_ACCEPTANCE_TCP_HOST:-127.0.0.1}"
LOCAL_ACCEPTANCE_TCP_PORT="${LOCAL_ACCEPTANCE_TCP_PORT:-9000}"
LOCAL_ACCEPTANCE_INTERNAL_SECRET="${LOCAL_ACCEPTANCE_INTERNAL_SECRET:-${IM_INTERNAL_SHARED_SECRET:-production-smoke-internal-secret}}"
LOCAL_ACCEPTANCE_STOP_ON_FAILURE="${LOCAL_ACCEPTANCE_STOP_ON_FAILURE:-true}"
LOCAL_ACCEPTANCE_DRY_RUN="${LOCAL_ACCEPTANCE_DRY_RUN:-false}"
LOCAL_ACCEPTANCE_K6_BIN="${LOCAL_ACCEPTANCE_K6_BIN:-${K6_BIN:-k6}}"
LOCAL_ACCEPTANCE_SKIP_POSTGRES_READY_CHECK="${LOCAL_ACCEPTANCE_SKIP_POSTGRES_READY_CHECK:-false}"
LOCAL_ACCEPTANCE_RESET_SCHEMA="${LOCAL_ACCEPTANCE_RESET_SCHEMA:-true}"
LOCAL_ACCEPTANCE_DATABASE_HOST="${LOCAL_ACCEPTANCE_DATABASE_HOST:-${DATABASE_HOST:-127.0.0.1}}"
LOCAL_ACCEPTANCE_DATABASE_PORT="${LOCAL_ACCEPTANCE_DATABASE_PORT:-${DATABASE_PORT:-5432}}"
LOCAL_ACCEPTANCE_DATABASE_NAME="${LOCAL_ACCEPTANCE_DATABASE_NAME:-imserver_local_acceptance}"
LOCAL_ACCEPTANCE_DATABASE_USERNAME="${LOCAL_ACCEPTANCE_DATABASE_USERNAME:-${DATABASE_USERNAME:-$(whoami)}}"
LOCAL_ACCEPTANCE_DATABASE_PASSWORD="${LOCAL_ACCEPTANCE_DATABASE_PASSWORD:-${DATABASE_PASSWORD:-}}"
LOCAL_ACCEPTANCE_ALLOW_UNSAFE_RESET_DATABASE="${LOCAL_ACCEPTANCE_ALLOW_UNSAFE_RESET_DATABASE:-false}"
LOCAL_ACCEPTANCE_SWIFT_BIN="${LOCAL_ACCEPTANCE_SWIFT_BIN:-swift}"
LOCAL_ACCEPTANCE_PG_ISREADY_BIN="${LOCAL_ACCEPTANCE_PG_ISREADY_BIN:-pg_isready}"
LOCAL_ACCEPTANCE_CREATEDB_BIN="${LOCAL_ACCEPTANCE_CREATEDB_BIN:-createdb}"
LOCAL_ACCEPTANCE_DROPDB_BIN="${LOCAL_ACCEPTANCE_DROPDB_BIN:-dropdb}"
LOCAL_ACCEPTANCE_SERVER_LOG_DIR="${LOCAL_ACCEPTANCE_SERVER_LOG_DIR:-${LOCAL_ACCEPTANCE_RESULT_ROOT}/server-logs}"
LOCAL_ACCEPTANCE_SERVER_LOG_FILE="${LOCAL_ACCEPTANCE_SERVER_LOG_FILE:-${LOCAL_ACCEPTANCE_SERVER_LOG_DIR}/${LOCAL_ACCEPTANCE_RUN_ID}-swift-postgres.log}"
LOCAL_ACCEPTANCE_HTTP_SMOKE_REPORT_FILE="${LOCAL_ACCEPTANCE_HTTP_SMOKE_REPORT_FILE:-${LOCAL_ACCEPTANCE_RESULT_ROOT}/http-smoke/${LOCAL_ACCEPTANCE_RUN_ID}-local-http-smoke.json}"
LOCAL_ACCEPTANCE_HOT_CONVERSATION_RESULT_DIR="${LOCAL_ACCEPTANCE_HOT_CONVERSATION_RESULT_DIR:-${LOCAL_ACCEPTANCE_RESULT_ROOT}/hot-conversation/${LOCAL_ACCEPTANCE_RUN_ID}}"
LOCAL_ACCEPTANCE_HOT_CONVERSATION_REPORT_FILE="${LOCAL_ACCEPTANCE_HOT_CONVERSATION_REPORT_FILE:-${LOCAL_ACCEPTANCE_HOT_CONVERSATION_RESULT_DIR}/stage-report.json}"
LOCAL_ACCEPTANCE_MULTINODE_FAULT_CONTRACTS_RESULT_DIR="${LOCAL_ACCEPTANCE_MULTINODE_FAULT_CONTRACTS_RESULT_DIR:-${LOCAL_ACCEPTANCE_RESULT_ROOT}/multinode-fault-contracts/${LOCAL_ACCEPTANCE_RUN_ID}}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

usage() {
  cat <<'EOF'
Usage:
  run_local_acceptance.sh [--print-plan|--check|run|self-test]

Purpose:
  Run the IMServer validation flow locally after the remote server is
  unavailable. This is local evidence only; it must not be used as final
  production acceptance evidence.

Default run:
  - starts a local Swift combined server against local PostgreSQL
  - runs run_local_http_smoke.sh
  - skips local hot-conversation k6 unless explicitly enabled
  - skips multi-node fault contracts unless explicitly enabled
  - skips broader product scenarios unless explicitly enabled

Common env:
  LOCAL_ACCEPTANCE_START_STACK=true|false
  LOCAL_ACCEPTANCE_BACKEND=swift-postgres|docker-compose|external|none
  LOCAL_ACCEPTANCE_RUN_MULTINODE_FAULT_CONTRACTS=true|false
  LOCAL_ACCEPTANCE_RUN_HOT_CONVERSATION=true|false
  LOCAL_ACCEPTANCE_HOT_CONVERSATION_PROFILE=local-hot-smoke
  LOCAL_ACCEPTANCE_HOT_CONVERSATION_SETTLE_SECONDS=5
  LOCAL_ACCEPTANCE_HOT_CONVERSATION_SEND_INTERVAL_MS=100
  LOCAL_ACCEPTANCE_HOT_CONVERSATION_BATCH_ENABLED=true|false
  LOCAL_ACCEPTANCE_HOT_CONVERSATION_BATCH_MAX_SIZE=32
  LOCAL_ACCEPTANCE_HOT_CONVERSATION_BATCH_MAX_DELAY_MS=10
  LOCAL_ACCEPTANCE_RUN_PRODUCT_SCENARIOS=true|false
  LOCAL_ACCEPTANCE_SUITE=smoke|recommended|baseline|capacity
  LOCAL_ACCEPTANCE_RESULT_ROOT=IMServer/LoadTests/results/local-acceptance
  LOCAL_ACCEPTANCE_BASE_URL=http://127.0.0.1:8080
  LOCAL_ACCEPTANCE_HTTP_HOST=127.0.0.1
  LOCAL_ACCEPTANCE_HTTP_PORT=8080
  LOCAL_ACCEPTANCE_TCP_HOST=127.0.0.1
  LOCAL_ACCEPTANCE_TCP_PORT=9000
  LOCAL_ACCEPTANCE_INTERNAL_SECRET=production-smoke-internal-secret
  LOCAL_ACCEPTANCE_K6_BIN=k6
  LOCAL_ACCEPTANCE_RESET_SCHEMA=true|false
  LOCAL_ACCEPTANCE_DATABASE_NAME=imserver_local_acceptance
  LOCAL_ACCEPTANCE_ALLOW_UNSAFE_RESET_DATABASE=false
  LOCAL_ACCEPTANCE_SWIFT_BIN=swift
  LOCAL_ACCEPTANCE_PG_ISREADY_BIN=pg_isready

Examples:
  ./run_local_acceptance.sh --print-plan
  ./run_local_acceptance.sh --check
  ./run_local_acceptance.sh run
  LOCAL_ACCEPTANCE_BACKEND=docker-compose ./run_local_acceptance.sh run
  LOCAL_ACCEPTANCE_BACKEND=external ./run_local_acceptance.sh run
  LOCAL_ACCEPTANCE_RUN_HOT_CONVERSATION=true ./run_local_acceptance.sh run
  LOCAL_ACCEPTANCE_RUN_PRODUCT_SCENARIOS=true LOCAL_ACCEPTANCE_SUITE=smoke ./run_local_acceptance.sh run
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'local_acceptance result=fail reason=command_missing command=%s\n' "$1" >&2
    exit 127
  fi
}

validate_reset_database_safety() {
  if bool_enabled "${LOCAL_ACCEPTANCE_RESET_SCHEMA}" \
      && [[ "${LOCAL_ACCEPTANCE_BACKEND}" == "swift-postgres" ]] \
      && ! bool_enabled "${LOCAL_ACCEPTANCE_ALLOW_UNSAFE_RESET_DATABASE}" \
      && [[ "${LOCAL_ACCEPTANCE_DATABASE_NAME}" != imserver_local_acceptance* ]]; then
    printf 'local_acceptance result=fail reason=unsafe_reset_database database=%s action=set_LOCAL_ACCEPTANCE_DATABASE_NAME_to_imserver_local_acceptance_or_set_LOCAL_ACCEPTANCE_ALLOW_UNSAFE_RESET_DATABASE=true\n' \
      "${LOCAL_ACCEPTANCE_DATABASE_NAME}" >&2
    exit 2
  fi
}

validate_hot_conversation_mode() {
  if bool_enabled "${LOCAL_ACCEPTANCE_RUN_HOT_CONVERSATION}" \
      && [[ "${LOCAL_ACCEPTANCE_BACKEND}" != "swift-postgres" ]] \
      && [[ "${LOCAL_ACCEPTANCE_BACKEND}" != "external" ]]; then
    printf 'local_acceptance result=fail reason=hot_conversation_requires_running_loopback_server backend=%s action=use_LOCAL_ACCEPTANCE_BACKEND_swift-postgres_or_external\n' \
      "${LOCAL_ACCEPTANCE_BACKEND}" >&2
    exit 2
  fi
}

check_prerequisites() {
  if [[ "${LOCAL_ACCEPTANCE_BACKEND}" == "none" ]] \
      && ! bool_enabled "${LOCAL_ACCEPTANCE_RUN_PRODUCT_SCENARIOS}" \
      && ! bool_enabled "${LOCAL_ACCEPTANCE_RUN_HOT_CONVERSATION}" \
      && ! bool_enabled "${LOCAL_ACCEPTANCE_RUN_MULTINODE_FAULT_CONTRACTS}"; then
    printf 'local_acceptance result=fail reason=no_local_checks_enabled action=enable_LOCAL_ACCEPTANCE_START_STACK_or_LOCAL_ACCEPTANCE_RUN_PRODUCT_SCENARIOS_or_LOCAL_ACCEPTANCE_RUN_MULTINODE_FAULT_CONTRACTS\n' >&2
    exit 2
  fi

  validate_reset_database_safety
  validate_hot_conversation_mode

  case "${LOCAL_ACCEPTANCE_BACKEND}" in
    swift-postgres)
      require_command "${LOCAL_ACCEPTANCE_SWIFT_BIN}"
      require_command curl
      require_command python3
      require_command psql
      require_command "${LOCAL_ACCEPTANCE_PG_ISREADY_BIN}"
      require_command "${LOCAL_ACCEPTANCE_CREATEDB_BIN}"
      require_command "${LOCAL_ACCEPTANCE_DROPDB_BIN}"
      if ! bool_enabled "${LOCAL_ACCEPTANCE_SKIP_POSTGRES_READY_CHECK}" \
          && ! "${LOCAL_ACCEPTANCE_PG_ISREADY_BIN}" \
            -h "${LOCAL_ACCEPTANCE_DATABASE_HOST}" \
            -p "${LOCAL_ACCEPTANCE_DATABASE_PORT}" >/dev/null 2>&1; then
        printf 'local_acceptance result=fail reason=postgres_not_ready host=%s port=%s action=start_local_postgres_or_set_LOCAL_ACCEPTANCE_BACKEND=docker-compose\n' \
          "${LOCAL_ACCEPTANCE_DATABASE_HOST}" "${LOCAL_ACCEPTANCE_DATABASE_PORT}" >&2
        exit 2
      fi
      ;;
    docker-compose)
      require_command docker
      if ! docker compose version >/dev/null 2>&1; then
        printf 'local_acceptance result=fail reason=command_missing command=%s\n' "docker compose" >&2
        exit 127
      fi
      ;;
    external)
      require_command curl
      require_command python3
      ;;
    none)
      ;;
    *)
      printf 'local_acceptance result=fail reason=invalid_backend backend=%s expected=swift-postgres,docker-compose,external,none\n' \
        "${LOCAL_ACCEPTANCE_BACKEND}" >&2
      exit 2
      ;;
  esac

  if bool_enabled "${LOCAL_ACCEPTANCE_RUN_HOT_CONVERSATION}" \
      || { bool_enabled "${LOCAL_ACCEPTANCE_RUN_PRODUCT_SCENARIOS}" && ! bool_enabled "${LOCAL_ACCEPTANCE_DRY_RUN}"; }; then
    require_command "${LOCAL_ACCEPTANCE_K6_BIN}"
  fi
  if bool_enabled "${LOCAL_ACCEPTANCE_RUN_MULTINODE_FAULT_CONTRACTS}"; then
    require_command "${LOCAL_ACCEPTANCE_SWIFT_BIN}"
  fi

  printf 'local_acceptance result=pass mode=check backend=%s productionEvidence=false\n' "${LOCAL_ACCEPTANCE_BACKEND}"
}

print_plan() {
  cat <<EOF
local_acceptance result=plan productionEvidence=false runID=${LOCAL_ACCEPTANCE_RUN_ID}
target baseURL=${LOCAL_ACCEPTANCE_BASE_URL} tcpHost=${LOCAL_ACCEPTANCE_TCP_HOST} tcpPort=${LOCAL_ACCEPTANCE_TCP_PORT}
backend=${LOCAL_ACCEPTANCE_BACKEND} start=${LOCAL_ACCEPTANCE_START_STACK} httpHost=${LOCAL_ACCEPTANCE_HTTP_HOST} httpPort=${LOCAL_ACCEPTANCE_HTTP_PORT}
database resetSchema=${LOCAL_ACCEPTANCE_RESET_SCHEMA} host=${LOCAL_ACCEPTANCE_DATABASE_HOST} port=${LOCAL_ACCEPTANCE_DATABASE_PORT} name=${LOCAL_ACCEPTANCE_DATABASE_NAME}
scripts docker=${SERVER_DIR}/scripts/production_smoke.sh localHTTP=${SCRIPT_DIR}/run_local_http_smoke.sh
hotConversation enabled=${LOCAL_ACCEPTANCE_RUN_HOT_CONVERSATION} profile=${LOCAL_ACCEPTANCE_HOT_CONVERSATION_PROFILE} settleSeconds=${LOCAL_ACCEPTANCE_HOT_CONVERSATION_SETTLE_SECONDS} sendIntervalMs=${LOCAL_ACCEPTANCE_HOT_CONVERSATION_SEND_INTERVAL_MS} batchEnabled=${LOCAL_ACCEPTANCE_HOT_CONVERSATION_BATCH_ENABLED} batchMaxSize=${LOCAL_ACCEPTANCE_HOT_CONVERSATION_BATCH_MAX_SIZE} batchMaxDelayMs=${LOCAL_ACCEPTANCE_HOT_CONVERSATION_BATCH_MAX_DELAY_MS}
multinodeFaultContracts enabled=${LOCAL_ACCEPTANCE_RUN_MULTINODE_FAULT_CONTRACTS} resultDir=${LOCAL_ACCEPTANCE_MULTINODE_FAULT_CONTRACTS_RESULT_DIR}
productScenarios enabled=${LOCAL_ACCEPTANCE_RUN_PRODUCT_SCENARIOS} suite=${LOCAL_ACCEPTANCE_SUITE} dryRun=${LOCAL_ACCEPTANCE_DRY_RUN}
resultRoot=${LOCAL_ACCEPTANCE_RESULT_ROOT}
artifacts httpSmokeReport=${LOCAL_ACCEPTANCE_HTTP_SMOKE_REPORT_FILE} hotConversationReport=${LOCAL_ACCEPTANCE_HOT_CONVERSATION_REPORT_FILE} serverLog=${LOCAL_ACCEPTANCE_SERVER_LOG_FILE}
note=local_results_do_not_satisfy_production_acceptance
EOF
}

wait_for_local_server() {
  for _ in $(seq 1 120); do
    if curl -fsS "${LOCAL_ACCEPTANCE_BASE_URL}/health" >/dev/null 2>&1 \
        || curl -fsS "${LOCAL_ACCEPTANCE_BASE_URL}/hello" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  printf 'local_acceptance result=fail reason=local_server_not_ready url=%s log=%s\n' \
    "${LOCAL_ACCEPTANCE_BASE_URL}" "${LOCAL_ACCEPTANCE_SERVER_LOG_FILE}" >&2
  tail -n 120 "${LOCAL_ACCEPTANCE_SERVER_LOG_FILE}" >&2 || true
  return 1
}

run_local_http_smoke() {
  LOCAL_HTTP_SMOKE_RUN_ID="${LOCAL_ACCEPTANCE_RUN_ID}" \
  LOCAL_HTTP_SMOKE_BASE_URL="${LOCAL_ACCEPTANCE_BASE_URL}" \
  LOCAL_HTTP_SMOKE_COMMAND_URL="${LOCAL_ACCEPTANCE_BASE_URL}" \
  LOCAL_HTTP_SMOKE_QUERY_URL="${LOCAL_ACCEPTANCE_BASE_URL}" \
  LOCAL_HTTP_SMOKE_INTERNAL_SECRET="${LOCAL_ACCEPTANCE_INTERNAL_SECRET}" \
  LOCAL_HTTP_SMOKE_REPORT_DIR="${LOCAL_ACCEPTANCE_RESULT_ROOT}/http-smoke" \
  LOCAL_HTTP_SMOKE_REPORT_FILE="${LOCAL_ACCEPTANCE_HTTP_SMOKE_REPORT_FILE}" \
    bash "${SCRIPT_DIR}/run_local_http_smoke.sh" run
}

run_local_hot_conversation() {
  LOCAL_HOT_CONVERSATION_RUN_ID="${LOCAL_ACCEPTANCE_RUN_ID}" \
  LOCAL_HOT_CONVERSATION_BASE_URL="${LOCAL_ACCEPTANCE_BASE_URL}" \
  LOCAL_HOT_CONVERSATION_INTERNAL_SECRET="${LOCAL_ACCEPTANCE_INTERNAL_SECRET}" \
  LOCAL_HOT_CONVERSATION_PROFILE="${LOCAL_ACCEPTANCE_HOT_CONVERSATION_PROFILE}" \
  LOCAL_HOT_CONVERSATION_SETTLE_SECONDS="${LOCAL_ACCEPTANCE_HOT_CONVERSATION_SETTLE_SECONDS}" \
  IM_SEND_INTERVAL_MS="${LOCAL_ACCEPTANCE_HOT_CONVERSATION_SEND_INTERVAL_MS}" \
  LOCAL_HOT_CONVERSATION_RESULT_DIR="${LOCAL_ACCEPTANCE_HOT_CONVERSATION_RESULT_DIR}" \
  LOCAL_HOT_CONVERSATION_K6_BIN="${LOCAL_ACCEPTANCE_K6_BIN}" \
    bash "${SCRIPT_DIR}/run_local_hot_conversation.sh" run
}

kill_local_acceptance_servers() {
  pkill -TERM -f "IMServer serve --hostname ${LOCAL_ACCEPTANCE_HTTP_HOST} --port ${LOCAL_ACCEPTANCE_HTTP_PORT}" >/dev/null 2>&1 || true
}

ensure_swift_postgres_database() {
  validate_reset_database_safety

  if bool_enabled "${LOCAL_ACCEPTANCE_RESET_SCHEMA}" \
      && [[ "${LOCAL_ACCEPTANCE_DATABASE_NAME}" == imserver_local_acceptance* ]]; then
    PGPASSWORD="${LOCAL_ACCEPTANCE_DATABASE_PASSWORD}" \
      "${LOCAL_ACCEPTANCE_DROPDB_BIN}" --if-exists --force \
        -h "${LOCAL_ACCEPTANCE_DATABASE_HOST}" \
        -p "${LOCAL_ACCEPTANCE_DATABASE_PORT}" \
        -U "${LOCAL_ACCEPTANCE_DATABASE_USERNAME}" \
        "${LOCAL_ACCEPTANCE_DATABASE_NAME}" >/dev/null
  fi

  if PGPASSWORD="${LOCAL_ACCEPTANCE_DATABASE_PASSWORD}" \
      psql \
        -h "${LOCAL_ACCEPTANCE_DATABASE_HOST}" \
        -p "${LOCAL_ACCEPTANCE_DATABASE_PORT}" \
        -U "${LOCAL_ACCEPTANCE_DATABASE_USERNAME}" \
        -d "${LOCAL_ACCEPTANCE_DATABASE_NAME}" \
        -c 'SELECT 1' >/dev/null 2>&1; then
    return 0
  fi

  PGPASSWORD="${LOCAL_ACCEPTANCE_DATABASE_PASSWORD}" \
    "${LOCAL_ACCEPTANCE_CREATEDB_BIN}" \
      -h "${LOCAL_ACCEPTANCE_DATABASE_HOST}" \
      -p "${LOCAL_ACCEPTANCE_DATABASE_PORT}" \
      -U "${LOCAL_ACCEPTANCE_DATABASE_USERNAME}" \
      "${LOCAL_ACCEPTANCE_DATABASE_NAME}" >/dev/null
}

run_swift_postgres_backend() {
  mkdir -p "${LOCAL_ACCEPTANCE_SERVER_LOG_DIR}"
  kill_local_acceptance_servers
  ensure_swift_postgres_database
  local message_write_batch_enabled="${IM_MESSAGE_WRITE_BATCH_ENABLED:-false}"
  local message_write_batch_max_size="${IM_MESSAGE_WRITE_BATCH_MAX_SIZE:-32}"
  local message_write_batch_max_delay_ms="${IM_MESSAGE_WRITE_BATCH_MAX_DELAY_MS:-10}"
  if bool_enabled "${LOCAL_ACCEPTANCE_RUN_HOT_CONVERSATION}"; then
    message_write_batch_enabled="${LOCAL_ACCEPTANCE_HOT_CONVERSATION_BATCH_ENABLED}"
    message_write_batch_max_size="${LOCAL_ACCEPTANCE_HOT_CONVERSATION_BATCH_MAX_SIZE}"
    message_write_batch_max_delay_ms="${LOCAL_ACCEPTANCE_HOT_CONVERSATION_BATCH_MAX_DELAY_MS}"
  fi
  (
    cd "${SERVER_DIR}"
    server_args=(run IMServer serve --hostname "${LOCAL_ACCEPTANCE_HTTP_HOST}" --port "${LOCAL_ACCEPTANCE_HTTP_PORT}")
    if bool_enabled "${LOCAL_ACCEPTANCE_RESET_SCHEMA}"; then
      server_args+=(--reset-im-schema)
    fi
    DATABASE_HOST="${LOCAL_ACCEPTANCE_DATABASE_HOST}" \
    DATABASE_PORT="${LOCAL_ACCEPTANCE_DATABASE_PORT}" \
    DATABASE_NAME="${LOCAL_ACCEPTANCE_DATABASE_NAME}" \
    DATABASE_USERNAME="${LOCAL_ACCEPTANCE_DATABASE_USERNAME}" \
    DATABASE_PASSWORD="${LOCAL_ACCEPTANCE_DATABASE_PASSWORD}" \
    DATABASE_PRIMARY_HOST="${LOCAL_ACCEPTANCE_DATABASE_HOST}" \
    DATABASE_PRIMARY_PORT="${LOCAL_ACCEPTANCE_DATABASE_PORT}" \
    DATABASE_PRIMARY_NAME="${LOCAL_ACCEPTANCE_DATABASE_NAME}" \
    DATABASE_PRIMARY_USERNAME="${LOCAL_ACCEPTANCE_DATABASE_USERNAME}" \
    DATABASE_PRIMARY_PASSWORD="${LOCAL_ACCEPTANCE_DATABASE_PASSWORD}" \
    JWT_SECRET="${JWT_SECRET:-local-acceptance-jwt-secret-change-me}" \
    IM_RUNTIME_ROLE=combined \
    IM_AUTO_MIGRATE_ON_START=true \
    IM_INLINE_OUTBOX_PROJECTION=true \
    IM_EVENT_STREAM_DRIVER=database-outbox \
    IM_ROUTING_MODE=local \
    IM_MESSAGE_WRITE_BATCH_ENABLED="${message_write_batch_enabled}" \
    IM_MESSAGE_WRITE_BATCH_MAX_SIZE="${message_write_batch_max_size}" \
    IM_MESSAGE_WRITE_BATCH_MAX_DELAY_MS="${message_write_batch_max_delay_ms}" \
    IM_NODE_ID="${IM_NODE_ID:-local-acceptance-node}" \
    IM_INTERNAL_SHARED_SECRET="${LOCAL_ACCEPTANCE_INTERNAL_SECRET}" \
    IM_COMMAND_INTERNAL_SHARED_SECRET="${LOCAL_ACCEPTANCE_INTERNAL_SECRET}" \
    IM_METRICS_ENABLED=true \
    IM_METRICS_INTERNAL_SECRET="${LOCAL_ACCEPTANCE_INTERNAL_SECRET}" \
    MEDIA_STORAGE_PROVIDER=local \
    SEED_USER_EMAIL="${SEED_USER_EMAIL:-demo@example.com}" \
    SEED_USER_PASSWORD="${SEED_USER_PASSWORD:-password1234}" \
      "${LOCAL_ACCEPTANCE_SWIFT_BIN}" "${server_args[@]}"
  ) >"${LOCAL_ACCEPTANCE_SERVER_LOG_FILE}" 2>&1 &

  local server_pid="$!"
  cleanup_swift_server() {
    pkill -TERM -P "${server_pid}" >/dev/null 2>&1 || true
    kill_local_acceptance_servers
    if kill -0 "${server_pid}" >/dev/null 2>&1; then
      kill "${server_pid}" >/dev/null 2>&1 || true
      wait "${server_pid}" >/dev/null 2>&1 || true
    fi
  }
  trap cleanup_swift_server EXIT INT TERM

  wait_for_local_server
  run_local_http_smoke
  if bool_enabled "${LOCAL_ACCEPTANCE_RUN_HOT_CONVERSATION}"; then
    run_local_hot_conversation
  fi
  cleanup_swift_server
  trap - EXIT INT TERM
}

run_selected_backend() {
  case "${LOCAL_ACCEPTANCE_BACKEND}" in
    swift-postgres)
      run_swift_postgres_backend
      ;;
    docker-compose)
      IM_INTERNAL_SHARED_SECRET="${LOCAL_ACCEPTANCE_INTERNAL_SECRET}" \
        bash "${SERVER_DIR}/scripts/production_smoke.sh" run
      ;;
    external)
      run_local_http_smoke
      if bool_enabled "${LOCAL_ACCEPTANCE_RUN_HOT_CONVERSATION}"; then
        run_local_hot_conversation
      fi
      ;;
    none)
      ;;
  esac
}

run_product_scenarios() {
  if ! bool_enabled "${LOCAL_ACCEPTANCE_RUN_PRODUCT_SCENARIOS}"; then
    return 0
  fi
  PRODUCT_SCENARIO_SUITE="${LOCAL_ACCEPTANCE_SUITE}" \
  PRODUCT_SCENARIO_EXECUTE=true \
  PRODUCT_SCENARIO_STOP_ON_FAILURE="${LOCAL_ACCEPTANCE_STOP_ON_FAILURE}" \
  PERF_DRY_RUN="${LOCAL_ACCEPTANCE_DRY_RUN}" \
  K6_BIN="${LOCAL_ACCEPTANCE_K6_BIN}" \
  PERF_PRODUCTION_GATE=false \
  PERF_GATE=false \
  BASE_URL="${LOCAL_ACCEPTANCE_BASE_URL}" \
  TCP_HOST="${LOCAL_ACCEPTANCE_TCP_HOST}" \
  TCP_PORT="${LOCAL_ACCEPTANCE_TCP_PORT}" \
  IM_INTERNAL_SECRET="${LOCAL_ACCEPTANCE_INTERNAL_SECRET}" \
  RESULT_ROOT="${LOCAL_ACCEPTANCE_RESULT_ROOT}" \
  PRODUCT_SCENARIO_RUN_ID_PREFIX="${LOCAL_ACCEPTANCE_RUN_ID}" \
    bash "${SCRIPT_DIR}/run_product_scenario_suite.sh"
}

run_local_multinode_fault_contracts() {
  if ! bool_enabled "${LOCAL_ACCEPTANCE_RUN_MULTINODE_FAULT_CONTRACTS}"; then
    return 0
  fi
  LOCAL_MULTINODE_FAULT_CONTRACTS_RUN_ID="${LOCAL_ACCEPTANCE_RUN_ID}" \
  LOCAL_MULTINODE_FAULT_CONTRACTS_RESULT_DIR="${LOCAL_ACCEPTANCE_MULTINODE_FAULT_CONTRACTS_RESULT_DIR}" \
  LOCAL_MULTINODE_FAULT_CONTRACTS_SWIFT_BIN="${LOCAL_ACCEPTANCE_SWIFT_BIN}" \
    bash "${SCRIPT_DIR}/run_local_multinode_fault_contracts.sh" run
}

run_local_acceptance() {
  mkdir -p "${LOCAL_ACCEPTANCE_RESULT_ROOT}"
  print_plan | tee "${LOCAL_ACCEPTANCE_RESULT_ROOT}/${LOCAL_ACCEPTANCE_RUN_ID}-plan.txt"
  check_prerequisites

  run_local_multinode_fault_contracts

  run_selected_backend

  run_product_scenarios

  cat >"${LOCAL_ACCEPTANCE_RESULT_ROOT}/${LOCAL_ACCEPTANCE_RUN_ID}-summary.json" <<EOF
{
  "schemaVersion": 1,
  "runID": "${LOCAL_ACCEPTANCE_RUN_ID}",
  "target": {
    "baseURL": "${LOCAL_ACCEPTANCE_BASE_URL}",
    "tcpHost": "${LOCAL_ACCEPTANCE_TCP_HOST}",
    "tcpPort": "${LOCAL_ACCEPTANCE_TCP_PORT}"
  },
  "database": {
    "host": "${LOCAL_ACCEPTANCE_DATABASE_HOST}",
    "port": "${LOCAL_ACCEPTANCE_DATABASE_PORT}",
    "name": "${LOCAL_ACCEPTANCE_DATABASE_NAME}"
  },
  "productionEvidence": false,
  "localOnly": true,
  "backend": "${LOCAL_ACCEPTANCE_BACKEND}",
  "resetSchema": $(bool_enabled "${LOCAL_ACCEPTANCE_RESET_SCHEMA}" && printf 'true' || printf 'false'),
  "startStack": $(bool_enabled "${LOCAL_ACCEPTANCE_START_STACK}" && printf 'true' || printf 'false'),
  "runHotConversation": $(bool_enabled "${LOCAL_ACCEPTANCE_RUN_HOT_CONVERSATION}" && printf 'true' || printf 'false'),
  "runMultinodeFaultContracts": $(bool_enabled "${LOCAL_ACCEPTANCE_RUN_MULTINODE_FAULT_CONTRACTS}" && printf 'true' || printf 'false'),
  "runProductScenarios": $(bool_enabled "${LOCAL_ACCEPTANCE_RUN_PRODUCT_SCENARIOS}" && printf 'true' || printf 'false'),
  "suite": "${LOCAL_ACCEPTANCE_SUITE}",
  "artifacts": {
    "httpSmokeReport": "${LOCAL_ACCEPTANCE_HTTP_SMOKE_REPORT_FILE}",
    "hotConversationReport": "${LOCAL_ACCEPTANCE_HOT_CONVERSATION_REPORT_FILE}",
    "multinodeFaultContractsResultDir": "${LOCAL_ACCEPTANCE_MULTINODE_FAULT_CONTRACTS_RESULT_DIR}",
    "serverLog": "${LOCAL_ACCEPTANCE_SERVER_LOG_FILE}"
  }
}
EOF
  printf 'local_acceptance result=pass productionEvidence=false summary=%s\n' \
    "${LOCAL_ACCEPTANCE_RESULT_ROOT}/${LOCAL_ACCEPTANCE_RUN_ID}-summary.json"
}

run_self_test() {
  local tmpdir log
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' RETURN
  log="${tmpdir}/local-acceptance-plan.log"

  LOCAL_ACCEPTANCE_SELF_TEST=false \
  LOCAL_ACCEPTANCE_PRINT_PLAN=true \
  LOCAL_ACCEPTANCE_START_STACK=false \
  LOCAL_ACCEPTANCE_BACKEND=none \
  LOCAL_ACCEPTANCE_RUN_PRODUCT_SCENARIOS=false \
  LOCAL_ACCEPTANCE_RUN_ID=local-self-test \
  LOCAL_ACCEPTANCE_RESULT_ROOT="${tmpdir}/results" \
    bash "${BASH_SOURCE[0]}" --print-plan >"${log}"
  grep -q 'local_acceptance result=plan productionEvidence=false runID=local-self-test' "${log}"
  grep -q 'note=local_results_do_not_satisfy_production_acceptance' "${log}"

  DATABASE_NAME=vapor_auth \
  LOCAL_ACCEPTANCE_SELF_TEST=false \
  LOCAL_ACCEPTANCE_PRINT_PLAN=true \
  LOCAL_ACCEPTANCE_START_STACK=true \
  LOCAL_ACCEPTANCE_RUN_PRODUCT_SCENARIOS=false \
  LOCAL_ACCEPTANCE_RUN_ID=local-self-test \
  LOCAL_ACCEPTANCE_RESULT_ROOT="${tmpdir}/results" \
    bash "${BASH_SOURCE[0]}" --print-plan >"${log}"
  grep -q 'database resetSchema=true .* name=imserver_local_acceptance' "${log}"

  if LOCAL_ACCEPTANCE_SELF_TEST=false \
      LOCAL_ACCEPTANCE_START_STACK=true \
      LOCAL_ACCEPTANCE_BACKEND=swift-postgres \
      LOCAL_ACCEPTANCE_RESET_SCHEMA=true \
      LOCAL_ACCEPTANCE_DATABASE_NAME=vapor_auth \
      LOCAL_ACCEPTANCE_RUN_PRODUCT_SCENARIOS=false \
      LOCAL_ACCEPTANCE_RUN_ID=local-self-test \
      LOCAL_ACCEPTANCE_RESULT_ROOT="${tmpdir}/results" \
        bash "${BASH_SOURCE[0]}" --check >"${log}" 2>&1; then
    printf 'local_acceptance_self_test result=fail reason=unsafe_reset_database_passed\n' >&2
    return 1
  fi
  grep -q 'reason=unsafe_reset_database' "${log}"

  if LOCAL_ACCEPTANCE_SELF_TEST=false \
      LOCAL_ACCEPTANCE_START_STACK=false \
      LOCAL_ACCEPTANCE_BACKEND=none \
      LOCAL_ACCEPTANCE_RUN_PRODUCT_SCENARIOS=false \
      LOCAL_ACCEPTANCE_RUN_ID=local-self-test \
      LOCAL_ACCEPTANCE_RESULT_ROOT="${tmpdir}/results" \
        bash "${BASH_SOURCE[0]}" run >"${log}" 2>&1; then
    printf 'local_acceptance_self_test result=fail reason=noop_run_passed\n' >&2
    return 1
  fi
  grep -q 'reason=no_local_checks_enabled' "${log}"

  LOCAL_ACCEPTANCE_SELF_TEST=false \
  LOCAL_ACCEPTANCE_START_STACK=false \
  LOCAL_ACCEPTANCE_BACKEND=none \
  LOCAL_ACCEPTANCE_RUN_MULTINODE_FAULT_CONTRACTS=true \
  LOCAL_ACCEPTANCE_RUN_PRODUCT_SCENARIOS=false \
  LOCAL_ACCEPTANCE_RUN_ID=local-self-test \
  LOCAL_ACCEPTANCE_RESULT_ROOT="${tmpdir}/results" \
    bash "${BASH_SOURCE[0]}" --check >"${log}"
  grep -q 'local_acceptance result=pass mode=check backend=none productionEvidence=false' "${log}"

  LOCAL_ACCEPTANCE_SELF_TEST=false \
  LOCAL_ACCEPTANCE_START_STACK=false \
  LOCAL_ACCEPTANCE_BACKEND=none \
  LOCAL_ACCEPTANCE_RUN_PRODUCT_SCENARIOS=true \
  LOCAL_ACCEPTANCE_DRY_RUN=true \
  LOCAL_ACCEPTANCE_RUN_ID=local-self-test \
  LOCAL_ACCEPTANCE_RESULT_ROOT="${tmpdir}/results" \
    bash "${BASH_SOURCE[0]}" --check >"${log}"
  grep -q 'local_acceptance result=pass mode=check backend=none productionEvidence=false' "${log}"

  LOCAL_ACCEPTANCE_SELF_TEST=false \
  LOCAL_ACCEPTANCE_START_STACK=true \
  LOCAL_ACCEPTANCE_BACKEND=external \
  LOCAL_ACCEPTANCE_RUN_PRODUCT_SCENARIOS=false \
  LOCAL_ACCEPTANCE_RUN_ID=local-self-test \
  LOCAL_ACCEPTANCE_RESULT_ROOT="${tmpdir}/results" \
    bash "${BASH_SOURCE[0]}" --check >"${log}"
  grep -q 'local_acceptance result=pass mode=check backend=external productionEvidence=false' "${log}"

  if LOCAL_ACCEPTANCE_SELF_TEST=false \
      LOCAL_ACCEPTANCE_START_STACK=false \
      LOCAL_ACCEPTANCE_BACKEND=none \
      LOCAL_ACCEPTANCE_RUN_HOT_CONVERSATION=true \
      LOCAL_ACCEPTANCE_RUN_PRODUCT_SCENARIOS=false \
      LOCAL_ACCEPTANCE_RUN_ID=local-self-test \
      LOCAL_ACCEPTANCE_RESULT_ROOT="${tmpdir}/results" \
        bash "${BASH_SOURCE[0]}" --check >"${log}" 2>&1; then
    printf 'local_acceptance_self_test result=fail reason=hot_conversation_without_server_passed\n' >&2
    return 1
  fi
  grep -q 'reason=hot_conversation_requires_running_loopback_server' "${log}"

  printf 'local_acceptance_self_test result=pass\n'
}

case "${1:-run}" in
  --help|-h)
    usage
    exit 0
    ;;
  --print-plan|plan)
    print_plan
    exit 0
    ;;
  --check|check)
    check_prerequisites
    exit 0
    ;;
  self-test)
    run_self_test
    exit 0
    ;;
  run)
    run_local_acceptance
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
