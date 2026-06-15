#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MONOREPO_DIR="$(cd "${ROOT_DIR}/.." && pwd)"
RUN_SWIFT_TESTS="${RUN_SWIFT_TESTS:-true}"
RUN_REAL_PREFLIGHT=false
REAL_STRICT_SECRETS=false
COMMAND_API_SET=false
GATEWAY_SET=false
QUERY_API_SET=false
OUTBOX_RELAY_SET=false
OPS_SET=false
STREAM_CONSUMER_COUNT=0
REAL_PREFLIGHT_ARGS=()
REPORT_DIR="${ROOT_DIR}/reports"
REPORT_FILE=""
STEP_LOG_DIR=""
STEP_INDEX=0
GATE_STATUS="running"

usage() {
  cat <<'USAGE'
Usage: production_release_gate.sh [--swift-tests|--skip-swift-tests] [--report-file file] [real env preflight args]

Runs the local production release gate:
  - shell syntax checks for production scripts
  - production env preflight self-test
  - default production env template preflight
  - protobuf generated-file drift check
  - TCP load-driver release build
  - optional real production env preflight with --strict-secrets
  - Swift release build
  - full Swift tests by default with swift test --no-parallel

Use --skip-swift-tests or RUN_SWIFT_TESTS=false only for a local fast smoke gate.

Real env preflight args mirror production_env_preflight.sh:
  --command-api file
  --gateway file
  --query-api file
  --outbox-relay file
  --ops file
  --stream-consumer file
  --require-groups csv
  --strict-secrets

Report options:
  --report-file file
USAGE
}

is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

run_step() {
  local name="$1"
  shift
  STEP_INDEX=$((STEP_INDEX + 1))
  local slug log_file log_name rc
  slug="$(printf '%s' "${name}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  slug="${slug:0:80}"
  log_name="$(printf 'production-release-gate-step-%02d-%s.log' "${STEP_INDEX}" "${slug}")"
  log_file="${STEP_LOG_DIR}/${log_name}"

  echo "==> ${name}"
  {
    echo
    echo "## ${name}"
    echo
    echo "- log: ${log_name}"
    echo
    echo '```text'
    printf '$'
    printf ' %q' "$@"
    echo
    echo '```'
  } >> "${REPORT_FILE}"

  set +e
  "$@" > >(tee "${log_file}") 2>&1
  rc=$?
  set -e

  if (( rc == 0 )); then
    echo "- status: passed" >> "${REPORT_FILE}"
  else
    {
      echo "- status: failed"
      echo "- exit_code: ${rc}"
    } >> "${REPORT_FILE}"
    return "${rc}"
  fi
}

append_real_preflight_arg() {
  RUN_REAL_PREFLIGHT=true
  REAL_PREFLIGHT_ARGS+=("$@")
}

write_failure_report() {
  local rc=$?
  if [[ "${GATE_STATUS}" != "passed" && -n "${REPORT_FILE}" && -f "${REPORT_FILE}" ]]; then
    {
      echo
      echo "## Result"
      echo
      echo "- status: failed"
      echo "- exit_code: ${rc}"
    } >> "${REPORT_FILE}"
    echo "Production release gate failed. Report: ${REPORT_FILE}" >&2
  fi
}

trap write_failure_report EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --swift-tests)
      RUN_SWIFT_TESTS=true
      shift
      ;;
    --skip-swift-tests)
      RUN_SWIFT_TESTS=false
      shift
      ;;
    --report-file)
      REPORT_FILE="${2:?missing --report-file value}"
      shift 2
      ;;
    --command-api)
      COMMAND_API_SET=true
      append_real_preflight_arg --command-api "${2:?missing --command-api value}"
      shift 2
      ;;
    --gateway)
      GATEWAY_SET=true
      append_real_preflight_arg --gateway "${2:?missing --gateway value}"
      shift 2
      ;;
    --query-api)
      QUERY_API_SET=true
      append_real_preflight_arg --query-api "${2:?missing --query-api value}"
      shift 2
      ;;
    --outbox-relay)
      OUTBOX_RELAY_SET=true
      append_real_preflight_arg --outbox-relay "${2:?missing --outbox-relay value}"
      shift 2
      ;;
    --ops)
      OPS_SET=true
      append_real_preflight_arg --ops "${2:?missing --ops value}"
      shift 2
      ;;
    --stream-consumer)
      STREAM_CONSUMER_COUNT=$((STREAM_CONSUMER_COUNT + 1))
      append_real_preflight_arg --stream-consumer "${2:?missing --stream-consumer value}"
      shift 2
      ;;
    --require-groups)
      append_real_preflight_arg --require-groups "${2:?missing --require-groups value}"
      shift 2
      ;;
    --strict-secrets)
      REAL_STRICT_SECRETS=true
      append_real_preflight_arg --strict-secrets
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "${RUN_REAL_PREFLIGHT}" == true ]]; then
  if [[ "${COMMAND_API_SET}" != true
    || "${GATEWAY_SET}" != true
    || "${QUERY_API_SET}" != true
    || "${OUTBOX_RELAY_SET}" != true
    || "${OPS_SET}" != true
    || "${STREAM_CONSUMER_COUNT}" -eq 0 ]]; then
    echo "Real env preflight requires --command-api, --gateway, --query-api, --outbox-relay, --ops, and at least one --stream-consumer." >&2
    exit 2
  fi
  if [[ "${REAL_STRICT_SECRETS}" != true ]]; then
    echo "Real env preflight requires --strict-secrets." >&2
    exit 2
  fi
fi

mkdir -p "${REPORT_DIR}"
if [[ -z "${REPORT_FILE}" ]]; then
  REPORT_FILE="${REPORT_DIR}/$(date -u +%Y%m%dT%H%M%SZ)-production-release-gate.md"
fi
mkdir -p "$(dirname "${REPORT_FILE}")"
STEP_LOG_DIR="$(dirname "${REPORT_FILE}")"

{
  echo "# Production release gate report"
  echo
  echo "- generated_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- git_sha: $(git -C "${MONOREPO_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "- swift_tests: ${RUN_SWIFT_TESTS}"
  echo "- real_env_preflight: ${RUN_REAL_PREFLIGHT}"
  echo "- real_env_strict_secrets: ${REAL_STRICT_SECRETS}"
  echo "- stream_consumer_envs: ${STREAM_CONSUMER_COUNT}"
  echo "- report_dir: ${STEP_LOG_DIR}"
} > "${REPORT_FILE}"

run_step "Shell syntax: production_env_preflight.sh" bash -n "${ROOT_DIR}/scripts/production_env_preflight.sh"
run_step "Shell syntax: production_env_preflight_test.sh" bash -n "${ROOT_DIR}/scripts/production_env_preflight_test.sh"
run_step "Shell syntax: production_release_gate.sh" bash -n "${ROOT_DIR}/scripts/production_release_gate.sh"
run_step "Shell syntax: production_smoke.sh" bash -n "${ROOT_DIR}/scripts/production_smoke.sh"
run_step "Shell syntax: failure_drill.sh" bash -n "${ROOT_DIR}/scripts/failure_drill.sh"
run_step "Shell syntax: staging_baseline.sh" bash -n "${ROOT_DIR}/scripts/staging_baseline.sh"
run_step "Shell syntax: multidevice_release_gate.sh" bash -n "${ROOT_DIR}/scripts/multidevice_release_gate.sh"
run_step "Shell syntax: tcp_capacity_ladder.sh" bash -n "${ROOT_DIR}/LoadTests/tcp_capacity_ladder.sh"
run_step "Shell syntax: tcp_capacity_ladder_test.sh" bash -n "${ROOT_DIR}/LoadTests/tcp_capacity_ladder_test.sh"
run_step "Shell syntax: tcp_capacity_local_shards.sh" bash -n "${ROOT_DIR}/LoadTests/tcp_capacity_local_shards.sh"
run_step "Shell syntax: tcp_message_send_ladder.sh" bash -n "${ROOT_DIR}/LoadTests/tcp_message_send_ladder.sh"
run_step "Shell syntax: prewarm_login_cache_slow.sh" bash -n "${ROOT_DIR}/LoadTests/prewarm_login_cache_slow.sh"
run_step "Shell syntax: provision_load_accounts.sh" bash -n "${ROOT_DIR}/LoadTests/provision_load_accounts.sh"
run_step "Shell syntax: generate_protobuf.sh" bash -n "${MONOREPO_DIR}/scripts/generate_protobuf.sh"
run_step "Shell syntax: check_protobuf_generated.sh" bash -n "${MONOREPO_DIR}/scripts/check_protobuf_generated.sh"

run_step "Production env preflight self-test" "${ROOT_DIR}/scripts/production_env_preflight_test.sh"
run_step "TCP capacity ladder self-test" "${ROOT_DIR}/LoadTests/tcp_capacity_ladder_test.sh"
run_step "Production env template preflight" "${ROOT_DIR}/scripts/production_env_preflight.sh"
run_step "Protobuf generated drift check" "${MONOREPO_DIR}/scripts/check_protobuf_generated.sh"
if [[ "${RUN_REAL_PREFLIGHT}" == true ]]; then
  run_step "Production real env preflight" "${ROOT_DIR}/scripts/production_env_preflight.sh" "${REAL_PREFLIGHT_ARGS[@]}"
fi
run_step "TCPDriver release build" swift build -c release --package-path "${ROOT_DIR}/LoadTests/TCPDriver"
run_step "IMServer release build" swift build -c release --package-path "${ROOT_DIR}"

if is_true "${RUN_SWIFT_TESTS}"; then
  run_step "IMServer full Swift tests" swift test --no-parallel --package-path "${ROOT_DIR}"
else
  {
    echo
    echo "## IMServer full Swift tests"
    echo
    echo "- status: skipped"
    echo "- reason: explicitly skipped with --skip-swift-tests or RUN_SWIFT_TESTS=false"
  } >> "${REPORT_FILE}"
  echo "==> swift test skipped by explicit request."
fi

{
  echo
  echo "## Result"
  echo
  echo "- status: passed"
} >> "${REPORT_FILE}"

GATE_STATUS="passed"
echo "production_release_gate passed."
echo "Production release gate report: ${REPORT_FILE}"
