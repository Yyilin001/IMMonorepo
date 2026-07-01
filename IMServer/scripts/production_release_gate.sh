#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MONOREPO_DIR="$(cd "${ROOT_DIR}/.." && pwd)"
RUN_SWIFT_TESTS="${RUN_SWIFT_TESTS:-true}"
SWIFTPM_BUILD_JOBS="${SWIFTPM_BUILD_JOBS:-}"
PRODUCTION_RELEASE_GATE_SELF_TEST="${PRODUCTION_RELEASE_GATE_SELF_TEST:-false}"
VALIDATE_ARGS_ONLY=false
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
REPORT_JSON=""
STEP_LOG_DIR=""
STEP_RESULTS_FILE=""
STEP_INDEX=0
GATE_STATUS="running"
SWIFTPM_JOB_ARGS=()

usage() {
  cat <<'USAGE'
Usage: production_release_gate.sh [--swift-tests|--skip-swift-tests] [--report-file file] [real env preflight args]

Runs the local production release gate:
  - shell syntax checks for production scripts
  - production env preflight self-test
  - default production env template preflight
  - protobuf generated-file drift check
  - TCP load-driver release build on Darwin hosts
  - optional real production env preflight with --strict-secrets
  - Swift release build
  - full Swift tests by default with swift test --no-parallel

Use --skip-swift-tests or RUN_SWIFT_TESTS=false only for a local fast smoke gate.
Use --validate-args-only only from CI/static checks; it validates the gate CLI
contract and exits before builds, protobuf checks, or Swift tests.

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
  --report-json file
USAGE
}

configure_swiftpm_job_args() {
  local jobs="${SWIFTPM_BUILD_JOBS}"
  if [[ -z "${jobs}" && "$(uname -s)" != "Darwin" ]]; then
    jobs=1
  fi
  if [[ -n "${jobs}" ]]; then
    SWIFTPM_JOB_ARGS=(--jobs "${jobs}")
  else
    SWIFTPM_JOB_ARGS=()
  fi
}

is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

run_self_test() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' RETURN

  if ! PRODUCTION_RELEASE_GATE_SELF_TEST=false bash "${BASH_SOURCE[0]}" \
    --validate-args-only \
    --command-api "${tmpdir}/command-api.env" \
    --gateway "${tmpdir}/gateway.env" \
    --query-api "${tmpdir}/query-api.env" \
    --outbox-relay "${tmpdir}/outbox-relay.env" \
    --ops "${tmpdir}/ops.env" \
    --stream-consumer "${tmpdir}/stream-domain.env" \
    --require-groups domain-delivery-consumer \
    --strict-secrets >"${tmpdir}/valid.log" 2>&1; then
    printf 'production_release_gate_self_test result=fail reason=valid_args_failed\n' >&2
    cat "${tmpdir}/valid.log" >&2
    exit 1
  fi
  grep -q 'production_release_gate validate_args=pass' "${tmpdir}/valid.log" || {
    printf 'production_release_gate_self_test result=fail reason=valid_args_message_missing\n' >&2
    exit 1
  }

  if PRODUCTION_RELEASE_GATE_SELF_TEST=false bash "${BASH_SOURCE[0]}" \
    --validate-args-only \
    --command-api "${tmpdir}/command-api.env" \
    --strict-secrets >"${tmpdir}/missing-roles.log" 2>&1; then
    printf 'production_release_gate_self_test result=fail reason=missing_roles_passed\n' >&2
    exit 1
  fi
  grep -q 'Real env preflight requires --command-api, --gateway, --query-api, --outbox-relay, --ops, and at least one --stream-consumer' "${tmpdir}/missing-roles.log" || {
    printf 'production_release_gate_self_test result=fail reason=missing_roles_message_missing\n' >&2
    exit 1
  }

  if PRODUCTION_RELEASE_GATE_SELF_TEST=false bash "${BASH_SOURCE[0]}" \
    --validate-args-only \
    --command-api "${tmpdir}/command-api.env" \
    --gateway "${tmpdir}/gateway.env" \
    --query-api "${tmpdir}/query-api.env" \
    --outbox-relay "${tmpdir}/outbox-relay.env" \
    --ops "${tmpdir}/ops.env" \
    --stream-consumer "${tmpdir}/stream-domain.env" >"${tmpdir}/missing-strict.log" 2>&1; then
    printf 'production_release_gate_self_test result=fail reason=missing_strict_passed\n' >&2
    exit 1
  fi
  grep -q 'Real env preflight requires --strict-secrets' "${tmpdir}/missing-strict.log" || {
    printf 'production_release_gate_self_test result=fail reason=missing_strict_message_missing\n' >&2
    exit 1
  }

  if PRODUCTION_RELEASE_GATE_SELF_TEST=false bash "${BASH_SOURCE[0]}" --definitely-invalid >"${tmpdir}/unknown.log" 2>&1; then
    printf 'production_release_gate_self_test result=fail reason=unknown_arg_passed\n' >&2
    exit 1
  fi
  grep -q 'Unknown argument: --definitely-invalid' "${tmpdir}/unknown.log" || {
    printf 'production_release_gate_self_test result=fail reason=unknown_arg_message_missing\n' >&2
    exit 1
  }

  PRODUCTION_RELEASE_GATE_SELF_TEST=false bash "${BASH_SOURCE[0]}" --help >"${tmpdir}/help.log"
  grep -q 'Usage: production_release_gate.sh' "${tmpdir}/help.log" || {
    printf 'production_release_gate_self_test result=fail reason=help_missing\n' >&2
    exit 1
  }

  PRODUCTION_RELEASE_GATE_SELF_TEST=false bash "${BASH_SOURCE[0]}" \
    --validate-args-only \
    --skip-swift-tests \
    --report-file "${tmpdir}/release-gate.md" \
    --report-json "${tmpdir}/release-gate.json" >"${tmpdir}/receipt.log" 2>&1
  python3 - "${tmpdir}/release-gate.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
if payload.get("status") != "passed":
    raise SystemExit("production_release_gate_self_test result=fail reason=receipt_status_missing")
if payload.get("validateArgsOnly") is not True:
    raise SystemExit("production_release_gate_self_test result=fail reason=receipt_validate_args_only_missing")
if payload.get("swiftTests") is not False:
    raise SystemExit("production_release_gate_self_test result=fail reason=receipt_swift_tests_flag_wrong")
if payload.get("steps") != []:
    raise SystemExit("production_release_gate_self_test result=fail reason=receipt_steps_not_empty")
PY

  printf 'production_release_gate_self_test result=pass\n'
}

if is_true "${PRODUCTION_RELEASE_GATE_SELF_TEST}"; then
  run_self_test
  exit 0
fi

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
    printf '%s\t%s\t%s\tpassed\t0\n' "${STEP_INDEX}" "${name}" "${log_name}" >> "${STEP_RESULTS_FILE}"
  else
    {
      echo "- status: failed"
      echo "- exit_code: ${rc}"
    } >> "${REPORT_FILE}"
    printf '%s\t%s\t%s\tfailed\t%s\n' "${STEP_INDEX}" "${name}" "${log_name}" "${rc}" >> "${STEP_RESULTS_FILE}"
    return "${rc}"
  fi
}

record_skipped_step() {
  local name="$1"
  local reason="$2"
  STEP_INDEX=$((STEP_INDEX + 1))

  echo "==> ${name} skipped: ${reason}"
  {
    echo
    echo "## ${name}"
    echo
    echo "- status: skipped"
    echo "- reason: ${reason}"
  } >> "${REPORT_FILE}"
  printf '%s\t%s\t%s\tskipped\t0\n' "${STEP_INDEX}" "${name}" "" >> "${STEP_RESULTS_FILE}"
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
    write_json_receipt "failed" "${rc}" || true
    echo "Production release gate failed. Report: ${REPORT_FILE}" >&2
  fi
}

write_json_receipt() {
  local status="${1:?missing status}"
  local exit_code="${2:?missing exit code}"
  if [[ -z "${REPORT_JSON}" ]]; then
    return 0
  fi
  mkdir -p "$(dirname "${REPORT_JSON}")"
  python3 - \
    "${REPORT_JSON}" \
    "${status}" \
    "${exit_code}" \
    "${REPORT_FILE}" \
    "${STEP_RESULTS_FILE}" \
    "${RUN_SWIFT_TESTS}" \
    "${RUN_REAL_PREFLIGHT}" \
    "${REAL_STRICT_SECRETS}" \
    "${STREAM_CONSUMER_COUNT}" \
    "${VALIDATE_ARGS_ONLY}" \
    "${MONOREPO_DIR}" <<'PY'
import json
import subprocess
import sys
import time
from pathlib import Path

(
    output_path,
    status,
    exit_code,
    report_file,
    step_results_file,
    swift_tests,
    real_env_preflight,
    real_env_strict_secrets,
    stream_consumer_count,
    validate_args_only,
    repo_root,
) = sys.argv[1:12]

def as_bool(value: str) -> bool:
    return value.lower() in {"1", "true", "yes", "on"}

def git_value(*args: str) -> str:
    try:
        return subprocess.run(
            ["git", *args],
            cwd=repo_root,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        ).stdout.strip()
    except OSError:
        return ""

steps = []
step_path = Path(step_results_file) if step_results_file else None
if step_path and step_path.is_file():
    for line in step_path.read_text(encoding="utf-8").splitlines():
        parts = line.split("\t")
        if len(parts) != 5:
            continue
        index, name, log, step_status, step_exit = parts
        try:
            index_value = int(index)
        except ValueError:
            index_value = 0
        try:
            exit_value = int(step_exit)
        except ValueError:
            exit_value = 0
        steps.append(
            {
                "index": index_value,
                "name": name,
                "log": log,
                "status": step_status,
                "exitCode": exit_value,
            }
        )

payload = {
    "schemaVersion": 1,
    "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "status": status,
    "exitCode": int(exit_code),
    "validateArgsOnly": as_bool(validate_args_only),
    "swiftTests": as_bool(swift_tests),
    "realEnvPreflight": as_bool(real_env_preflight),
    "realEnvStrictSecrets": as_bool(real_env_strict_secrets),
    "streamConsumerEnvs": int(stream_consumer_count or 0),
    "reportFile": report_file,
    "source": {
        "gitCommit": git_value("rev-parse", "--verify", "HEAD"),
        "gitBranch": git_value("branch", "--show-current"),
        "gitDirty": bool(git_value("status", "--porcelain")),
    },
    "summary": {
        "stepCount": len(steps),
        "passed": sum(1 for step in steps if step.get("status") == "passed"),
        "failed": sum(1 for step in steps if step.get("status") == "failed"),
        "skipped": sum(1 for step in steps if step.get("status") == "skipped"),
    },
    "steps": steps,
}
Path(output_path).write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
latest_path = Path(output_path).with_name("latest-production-release-gate.json")
if latest_path != Path(output_path):
    latest_path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
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
    --report-json)
      REPORT_JSON="${2:?missing --report-json value}"
      shift 2
      ;;
    --validate-args-only)
      VALIDATE_ARGS_ONLY=true
      shift
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

if [[ "${VALIDATE_ARGS_ONLY}" == true ]]; then
  if [[ -n "${REPORT_FILE}" && -z "${REPORT_JSON}" ]]; then
    REPORT_JSON="${REPORT_FILE%.*}.json"
  fi
  STEP_RESULTS_FILE="$(mktemp)"
  write_json_receipt "passed" 0
  printf 'production_release_gate validate_args=pass real_env_preflight=%s strictSecrets=%s streamConsumers=%s swiftTests=%s\n' \
    "${RUN_REAL_PREFLIGHT}" \
    "${REAL_STRICT_SECRETS}" \
    "${STREAM_CONSUMER_COUNT}" \
    "${RUN_SWIFT_TESTS}"
  exit 0
fi

mkdir -p "${REPORT_DIR}"
configure_swiftpm_job_args
if [[ -z "${REPORT_FILE}" ]]; then
  REPORT_FILE="${REPORT_DIR}/$(date -u +%Y%m%dT%H%M%SZ)-production-release-gate.md"
fi
if [[ -z "${REPORT_JSON}" ]]; then
  REPORT_JSON="${REPORT_FILE%.*}.json"
fi
mkdir -p "$(dirname "${REPORT_FILE}")"
STEP_LOG_DIR="$(dirname "${REPORT_FILE}")"
STEP_RESULTS_FILE="${STEP_LOG_DIR}/$(basename "${REPORT_FILE%.*}").steps.tsv"
: > "${STEP_RESULTS_FILE}"

{
  echo "# Production release gate report"
  echo
  echo "- generated_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- git_sha: $(git -C "${MONOREPO_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "- swift_tests: ${RUN_SWIFT_TESTS}"
  echo "- swiftpm_build_jobs: ${SWIFTPM_BUILD_JOBS:-auto}"
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
if [[ "$(uname -s)" == "Darwin" ]]; then
  run_step "TCPDriver release build" swift build -c release "${SWIFTPM_JOB_ARGS[@]}" --package-path "${ROOT_DIR}/LoadTests/TCPDriver"
else
  record_skipped_step "TCPDriver release build" "TCPDriver uses Apple's Network framework and is built on Darwin load-generator hosts."
fi
run_step "IMServer release build" swift build -c release "${SWIFTPM_JOB_ARGS[@]}" --package-path "${ROOT_DIR}"

if is_true "${RUN_SWIFT_TESTS}"; then
  run_step "IMServer full Swift tests" swift test --no-parallel "${SWIFTPM_JOB_ARGS[@]}" --package-path "${ROOT_DIR}"
else
  record_skipped_step "IMServer full Swift tests" "explicitly skipped with --skip-swift-tests or RUN_SWIFT_TESTS=false"
  echo "==> swift test skipped by explicit request."
fi

{
  echo
  echo "## Result"
  echo
  echo "- status: passed"
} >> "${REPORT_FILE}"

GATE_STATUS="passed"
write_json_receipt "passed" 0
echo "production_release_gate passed."
echo "Production release gate report: ${REPORT_FILE}"
echo "Production release gate receipt: ${REPORT_JSON}"
