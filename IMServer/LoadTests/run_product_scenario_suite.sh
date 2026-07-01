#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT_ROOT="${RESULT_ROOT:-${SCRIPT_DIR}/results}"
RESULT_ROOT="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve())' "${RESULT_ROOT}")"

PRODUCT_SCENARIO_SUITE="${PRODUCT_SCENARIO_SUITE:-recommended}"
PRODUCT_SCENARIO_RUN_ID_PREFIX="${PRODUCT_SCENARIO_RUN_ID_PREFIX:-product-scenario-$(date +%Y%m%d-%H%M%S)}"
PRODUCT_SCENARIO_EXECUTE="${PRODUCT_SCENARIO_EXECUTE:-true}"
PRODUCT_SCENARIO_STOP_ON_FAILURE="${PRODUCT_SCENARIO_STOP_ON_FAILURE:-true}"
PRODUCT_SCENARIO_INCLUDE_LARGE_GROUP="${PRODUCT_SCENARIO_INCLUDE_LARGE_GROUP:-false}"
PRODUCT_SCENARIO_RUN_PRODUCT_PLAN="${PRODUCT_SCENARIO_RUN_PRODUCT_PLAN:-${SCRIPT_DIR}/run_product_test_plan.sh}"
PRODUCT_SCENARIO_RUN_NON_LARGE_GROUP="${PRODUCT_SCENARIO_RUN_NON_LARGE_GROUP:-${SCRIPT_DIR}/run_non_large_group_regression.sh}"
PRODUCT_SCENARIO_RUN_PRODUCT_CAMPAIGN="${PRODUCT_SCENARIO_RUN_PRODUCT_CAMPAIGN:-${SCRIPT_DIR}/run_product_campaign.py}"
PRODUCT_SCENARIO_SELF_TEST="${PRODUCT_SCENARIO_SELF_TEST:-false}"
PRODUCT_SCENARIO_RECEIPT_DIR="${PRODUCT_SCENARIO_RECEIPT_DIR:-${RESULT_ROOT}/${PRODUCT_SCENARIO_RUN_ID_PREFIX}-suite}"
PRODUCT_SCENARIO_RECEIPT_DIR="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve())' "${PRODUCT_SCENARIO_RECEIPT_DIR}")"
PRODUCT_SCENARIO_RECEIPT_JSON="${PRODUCT_SCENARIO_RECEIPT_JSON:-${PRODUCT_SCENARIO_RECEIPT_DIR}/product-scenario-suite-run.json}"
PRODUCT_SCENARIO_RECEIPT_MD="${PRODUCT_SCENARIO_RECEIPT_MD:-${PRODUCT_SCENARIO_RECEIPT_DIR}/product-scenario-suite-run.md}"

PERF_DRY_RUN="${PERF_DRY_RUN:-false}"
BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
TCP_HOST="${TCP_HOST:-}"
TCP_PORT="${TCP_PORT:-9000}"
ACCOUNT_FILE="${ACCOUNT_FILE:-}"
IM_CONVERSATION_ID="${IM_CONVERSATION_ID:-}"
IM_INTERNAL_SECRET="${IM_INTERNAL_SECRET:-${IM_INTERNAL_SHARED_SECRET:-}}"

host_from_url() {
  python3 - "$1" <<'PY'
from urllib.parse import urlparse
import sys

parsed = urlparse(sys.argv[1])
print(parsed.hostname or "")
PY
}

if [[ -z "${TCP_HOST}" ]]; then
  TCP_HOST="$(host_from_url "${BASE_URL}")"
fi
TCP_HOST="${TCP_HOST:-127.0.0.1}"
if [[ -n "${ACCOUNT_FILE}" ]]; then
  ACCOUNT_FILE="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve())' "${ACCOUNT_FILE}")"
fi

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

suite_names() {
  cat <<'EOF'
smoke
breadth
workflow
realtime
baseline
capacity
regression
acceptance
recommended
full
EOF
}

suite_stage_rows() {
  case "$1" in
    smoke)
      printf '%s\t%s\t%s\t%s\n' "normal-smoke" "product-plan" "normal-smoke" "Fast cross-product smoke excluding large-group fanout."
      ;;
    breadth)
      printf '%s\t%s\t%s\t%s\n' "normal-breadth" "product-plan" "normal-breadth" "Broad ordinary IM breadth excluding large-group fanout."
      ;;
    workflow)
      printf '%s\t%s\t%s\t%s\n' "workflow-regression" "product-plan" "workflow-regression" "Auth, sync, direct chat, ordinary groups, contacts, media, recovery, and governance."
      ;;
    realtime)
      printf '%s\t%s\t%s\t%s\n' "realtime-focused" "product-plan" "realtime-focused" "TCP online, reconnect, pair delivery, multi-device delivery, and ordinary group realtime."
      ;;
    baseline)
      printf '%s\t%s\t%s\t%s\n' "normal-baseline" "product-plan" "normal-baseline" "Release-quality normal-product baseline excluding large-group fanout."
      ;;
    capacity)
      printf '%s\t%s\t%s\t%s\n' "normal-capacity" "product-plan" "normal-capacity" "Capacity-pressure normal-product breadth excluding isolated large-group fanout."
      ;;
    regression)
      printf '%s\t%s\t%s\t%s\n' "product-scenario-regression" "non-large-campaign" "product-scenario-regression" "Domain-by-domain normal IM regression campaign."
      ;;
    acceptance)
      printf '%s\t%s\t%s\t%s\n' "product-scenario-acceptance" "non-large-acceptance" "product-scenario-acceptance" "Full normal-product acceptance campaign, still excluding large-group fanout."
      ;;
    recommended)
      suite_stage_rows smoke
      suite_stage_rows breadth
      suite_stage_rows workflow
      suite_stage_rows realtime
      suite_stage_rows baseline
      ;;
    full)
      printf '%s\t%s\t%s\t%s\n' "production-full-acceptance" "full-campaign" "production-full-acceptance" "Long-term production ladder; large-group stress is isolated as the final stage."
      ;;
    *)
      printf 'product_scenario_suite result=fail reason=unknown_suite suite=%s\n' "$1" >&2
      return 2
      ;;
  esac
}

usage() {
  cat <<'EOF'
Usage:
  run_product_scenario_suite.sh [--list|--print-plan|--validate-plan]

Purpose:
  Run broader IM product performance suites instead of only large-group fanout.
  The default PRODUCT_SCENARIO_SUITE=recommended runs smoke, breadth, workflow,
  realtime, and baseline stages while excluding isolated large-group scenarios.

Suites:
  smoke        Fast cross-product smoke.
  breadth      Broad ordinary IM breadth.
  workflow     Business workflow regression.
  realtime     TCP/realtime-focused regression.
  baseline     Release-quality normal-product baseline.
  capacity     Capacity-pressure normal-product breadth.
  regression   Domain-by-domain normal-product campaign.
  acceptance   Full normal-product acceptance campaign.
  recommended  smoke -> breadth -> workflow -> realtime -> baseline.
  full         production-full-acceptance; requires PRODUCT_SCENARIO_INCLUDE_LARGE_GROUP=true.

Common env:
  PRODUCT_SCENARIO_SUITE=recommended
  PRODUCT_SCENARIO_EXECUTE=true|false
  PRODUCT_SCENARIO_STOP_ON_FAILURE=true|false
  PRODUCT_SCENARIO_INCLUDE_LARGE_GROUP=false
  PRODUCT_SCENARIO_RUN_ID_PREFIX=product-scenario-YYYYMMDD-HHMMSS
  PRODUCT_SCENARIO_RECEIPT_DIR=results/product-scenario-YYYYMMDD-HHMMSS-suite
  PRODUCT_SCENARIO_RECEIPT_JSON=.../product-scenario-suite-run.json
  PRODUCT_SCENARIO_RECEIPT_MD=.../product-scenario-suite-run.md
  RESULT_ROOT=IMServer/LoadTests/results
  PERF_DRY_RUN=true|false
  BASE_URL=https://chat.yourdomain.com
  TCP_HOST=tcp.yourdomain.com
  TCP_PORT=9000
  ACCOUNT_FILE=/path/load-5000.csv
  IM_CONVERSATION_ID=<uuid>
  IM_INTERNAL_SECRET=<secret>
  Replace *.yourdomain.com before running; production gates reject literal placeholder domains.
  For local development only, override BASE_URL=http://127.0.0.1:8080 and TCP_HOST=127.0.0.1.

Examples:
  ./run_product_scenario_suite.sh --print-plan
  PRODUCT_SCENARIO_SUITE=smoke ./run_product_scenario_suite.sh
  PRODUCT_SCENARIO_SUITE=recommended ./run_product_scenario_suite.sh
  PRODUCT_SCENARIO_SUITE=capacity ./run_product_scenario_suite.sh
  PRODUCT_SCENARIO_SUITE=full PRODUCT_SCENARIO_INCLUDE_LARGE_GROUP=true ./run_product_scenario_suite.sh
EOF
}

quote_command_redacted() {
  local first=true
  local arg name value
  for arg in "$@"; do
    if [[ "${first}" == true ]]; then
      first=false
    else
      printf ' '
    fi
    name="${arg%%=*}"
    value="${arg#*=}"
    case "${name}" in
      IM_INTERNAL_SECRET|IM_INTERNAL_SHARED_SECRET)
        if [[ "${arg}" == *=* && -n "${value}" ]]; then
          printf '%s=<redacted>' "${name}"
        else
          printf '%q' "${arg}"
        fi
        ;;
      *)
        printf '%q' "${arg}"
        ;;
    esac
  done
  printf '\n'
}

require_suite_policy() {
  suite_stage_rows "${PRODUCT_SCENARIO_SUITE}" >/dev/null
  if [[ "${PRODUCT_SCENARIO_SUITE}" == "full" ]] && ! bool_enabled "${PRODUCT_SCENARIO_INCLUDE_LARGE_GROUP}"; then
    printf 'product_scenario_suite result=fail reason=full_suite_requires_large_group_opt_in suite=%s\n' "${PRODUCT_SCENARIO_SUITE}" >&2
    printf 'Set PRODUCT_SCENARIO_INCLUDE_LARGE_GROUP=true because production-full-acceptance intentionally runs isolated large-group stress last.\n' >&2
    return 2
  fi
}

print_plan() {
  require_suite_policy
  printf 'product_scenario_suite result=pass mode=print suite=%s resultRoot=%s dryRun=%s execute=%s stopOnFailure=%s includeLargeGroup=%s\n' \
    "${PRODUCT_SCENARIO_SUITE}" \
    "${RESULT_ROOT}" \
    "${PERF_DRY_RUN}" \
    "${PRODUCT_SCENARIO_EXECUTE}" \
    "${PRODUCT_SCENARIO_STOP_ON_FAILURE}" \
    "${PRODUCT_SCENARIO_INCLUDE_LARGE_GROUP}"
  printf 'target baseURL=%q tcpHost=%q tcpPort=%q accountFile=%q conversationID=%q\n' \
    "${BASE_URL}" \
    "${TCP_HOST}" \
    "${TCP_PORT}" \
    "${ACCOUNT_FILE}" \
    "${IM_CONVERSATION_ID}"
  local stage_id runner value description index=0
  while IFS=$'\t' read -r stage_id runner value description; do
    index=$((index + 1))
    printf 'stage=%s id=%q runner=%q value=%q description=%q\n' \
      "${index}" \
      "${stage_id}" \
      "${runner}" \
      "${value}" \
      "${description}"
    printf '  command='
    stage_command "${stage_id}" "${runner}" "${value}" true
  done < <(suite_stage_rows "${PRODUCT_SCENARIO_SUITE}")
}

stage_command() {
  local stage_id="$1"
  local runner="$2"
  local value="$3"
  local dry_print="${4:-false}"
  local stage_result_root="${RESULT_ROOT}/${PRODUCT_SCENARIO_RUN_ID_PREFIX}-${stage_id}"
  case "${runner}" in
    product-plan)
      quote_command_redacted \
        RESULT_ROOT="${stage_result_root}" \
        BASE_URL="${BASE_URL}" \
        TCP_HOST="${TCP_HOST}" \
        TCP_PORT="${TCP_PORT}" \
        ACCOUNT_FILE="${ACCOUNT_FILE}" \
        IM_CONVERSATION_ID="${IM_CONVERSATION_ID}" \
        IM_INTERNAL_SECRET="${IM_INTERNAL_SECRET}" \
        PRODUCT_TEST_PRESET="${value}" \
        PRODUCT_TEST_RUN_ID_PREFIX="${PRODUCT_SCENARIO_RUN_ID_PREFIX}-${stage_id}" \
        "${PRODUCT_SCENARIO_RUN_PRODUCT_PLAN}"
      ;;
    non-large-campaign)
      quote_command_redacted \
        RESULT_ROOT="${stage_result_root}" \
        BASE_URL="${BASE_URL}" \
        TCP_HOST="${TCP_HOST}" \
        TCP_PORT="${TCP_PORT}" \
        ACCOUNT_FILE="${ACCOUNT_FILE}" \
        IM_CONVERSATION_ID="${IM_CONVERSATION_ID}" \
        IM_INTERNAL_SECRET="${IM_INTERNAL_SECRET}" \
        NON_LARGE_GROUP_MODE=campaign \
        NON_LARGE_GROUP_CAMPAIGN="${value}" \
        NON_LARGE_GROUP_RUN_ID_PREFIX="${PRODUCT_SCENARIO_RUN_ID_PREFIX}-${stage_id}" \
        "${PRODUCT_SCENARIO_RUN_NON_LARGE_GROUP}"
      ;;
    non-large-acceptance)
      quote_command_redacted \
        RESULT_ROOT="${stage_result_root}" \
        BASE_URL="${BASE_URL}" \
        TCP_HOST="${TCP_HOST}" \
        TCP_PORT="${TCP_PORT}" \
        ACCOUNT_FILE="${ACCOUNT_FILE}" \
        IM_CONVERSATION_ID="${IM_CONVERSATION_ID}" \
        IM_INTERNAL_SECRET="${IM_INTERNAL_SECRET}" \
        NON_LARGE_GROUP_MODE=acceptance \
        NON_LARGE_GROUP_ACCEPTANCE_CAMPAIGN="${value}" \
        NON_LARGE_GROUP_RUN_ID_PREFIX="${PRODUCT_SCENARIO_RUN_ID_PREFIX}-${stage_id}" \
        "${PRODUCT_SCENARIO_RUN_NON_LARGE_GROUP}"
      ;;
    full-campaign)
      local execute_arg=""
      bool_enabled "${PRODUCT_SCENARIO_EXECUTE}" && execute_arg="--execute"
      if [[ "${dry_print}" == true ]]; then
        quote_command_redacted \
          PERF_DRY_RUN="${PERF_DRY_RUN}" \
          BASE_URL="${BASE_URL}" \
          TCP_HOST="${TCP_HOST}" \
          TCP_PORT="${TCP_PORT}" \
          ACCOUNT_FILE="${ACCOUNT_FILE}" \
          IM_CONVERSATION_ID="${IM_CONVERSATION_ID}" \
          IM_INTERNAL_SECRET="${IM_INTERNAL_SECRET}" \
          python3 "${PRODUCT_SCENARIO_RUN_PRODUCT_CAMPAIGN}" \
          --campaign "${value}" \
          --result-dir "${stage_result_root}" \
          --json-output "${stage_result_root}/product-campaign-run.json" \
          --runbook-output "${stage_result_root}/product-campaign-runbook.md" \
          ${execute_arg}
      else
        return 0
      fi
      ;;
    *)
      printf 'product_scenario_suite result=fail reason=unknown_runner runner=%s\n' "${runner}" >&2
      return 2
      ;;
  esac
}

validate_stage() {
  local stage_id="$1"
  local runner="$2"
  local value="$3"
  local stage_result_root="${RESULT_ROOT}/${PRODUCT_SCENARIO_RUN_ID_PREFIX}-${stage_id}-validate"
  case "${runner}" in
    product-plan)
      RESULT_ROOT="${stage_result_root}" \
      BASE_URL="${BASE_URL}" \
      TCP_HOST="${TCP_HOST}" \
      TCP_PORT="${TCP_PORT}" \
      ACCOUNT_FILE="${ACCOUNT_FILE}" \
      IM_CONVERSATION_ID="${IM_CONVERSATION_ID}" \
      IM_INTERNAL_SECRET="${IM_INTERNAL_SECRET}" \
      PRODUCT_TEST_PRESET="${value}" \
      PERF_DRY_RUN=true \
        "${PRODUCT_SCENARIO_RUN_PRODUCT_PLAN}" --validate-plan >/dev/null
      ;;
    non-large-campaign)
      RESULT_ROOT="${stage_result_root}" \
      BASE_URL="${BASE_URL}" \
      TCP_HOST="${TCP_HOST}" \
      TCP_PORT="${TCP_PORT}" \
      ACCOUNT_FILE="${ACCOUNT_FILE}" \
      IM_CONVERSATION_ID="${IM_CONVERSATION_ID}" \
      IM_INTERNAL_SECRET="${IM_INTERNAL_SECRET}" \
      NON_LARGE_GROUP_MODE=campaign \
      NON_LARGE_GROUP_CAMPAIGN="${value}" \
      PERF_DRY_RUN=true \
        "${PRODUCT_SCENARIO_RUN_NON_LARGE_GROUP}" --validate-plan >/dev/null
      ;;
    non-large-acceptance)
      RESULT_ROOT="${stage_result_root}" \
      BASE_URL="${BASE_URL}" \
      TCP_HOST="${TCP_HOST}" \
      TCP_PORT="${TCP_PORT}" \
      ACCOUNT_FILE="${ACCOUNT_FILE}" \
      IM_CONVERSATION_ID="${IM_CONVERSATION_ID}" \
      IM_INTERNAL_SECRET="${IM_INTERNAL_SECRET}" \
      NON_LARGE_GROUP_MODE=acceptance \
      NON_LARGE_GROUP_ACCEPTANCE_CAMPAIGN="${value}" \
      PERF_DRY_RUN=true \
        "${PRODUCT_SCENARIO_RUN_NON_LARGE_GROUP}" --validate-plan >/dev/null
      ;;
    full-campaign)
      mkdir -p "${stage_result_root}"
      PERF_DRY_RUN=true \
      BASE_URL="${BASE_URL}" \
      TCP_HOST="${TCP_HOST}" \
      TCP_PORT="${TCP_PORT}" \
      ACCOUNT_FILE="${ACCOUNT_FILE}" \
      IM_CONVERSATION_ID="${IM_CONVERSATION_ID}" \
      IM_INTERNAL_SECRET="${IM_INTERNAL_SECRET}" \
        python3 "${PRODUCT_SCENARIO_RUN_PRODUCT_CAMPAIGN}" \
          --campaign "${value}" \
          --result-dir "${stage_result_root}" \
          --json-output "${stage_result_root}/product-campaign-run.json" \
          --runbook-output "${stage_result_root}/product-campaign-runbook.md" >/dev/null
      ;;
    *)
      printf 'product_scenario_suite result=fail reason=unknown_runner runner=%s\n' "${runner}" >&2
      return 2
      ;;
  esac
}

validate_plan() {
  require_suite_policy
  local stage_id runner value description
  while IFS=$'\t' read -r stage_id runner value description; do
    validate_stage "${stage_id}" "${runner}" "${value}"
  done < <(suite_stage_rows "${PRODUCT_SCENARIO_SUITE}")
  printf 'product_scenario_suite result=pass mode=validate suite=%s\n' "${PRODUCT_SCENARIO_SUITE}"
}

run_product_plan_stage() {
  local stage_id="$1"
  local preset="$2"
  local stage_result_root="${RESULT_ROOT}/${PRODUCT_SCENARIO_RUN_ID_PREFIX}-${stage_id}"
  RESULT_ROOT="${stage_result_root}" \
  BASE_URL="${BASE_URL}" \
  TCP_HOST="${TCP_HOST}" \
  TCP_PORT="${TCP_PORT}" \
  ACCOUNT_FILE="${ACCOUNT_FILE}" \
  IM_CONVERSATION_ID="${IM_CONVERSATION_ID}" \
  IM_INTERNAL_SECRET="${IM_INTERNAL_SECRET}" \
  PRODUCT_TEST_PRESET="${preset}" \
  PRODUCT_TEST_RUN_ID_PREFIX="${PRODUCT_SCENARIO_RUN_ID_PREFIX}-${stage_id}" \
  PERF_DRY_RUN="${PERF_DRY_RUN}" \
    "${PRODUCT_SCENARIO_RUN_PRODUCT_PLAN}"
}

run_non_large_campaign_stage() {
  local stage_id="$1"
  local mode="$2"
  local campaign="$3"
  local stage_result_root="${RESULT_ROOT}/${PRODUCT_SCENARIO_RUN_ID_PREFIX}-${stage_id}"
  RESULT_ROOT="${stage_result_root}" \
  BASE_URL="${BASE_URL}" \
  TCP_HOST="${TCP_HOST}" \
  TCP_PORT="${TCP_PORT}" \
  ACCOUNT_FILE="${ACCOUNT_FILE}" \
  IM_CONVERSATION_ID="${IM_CONVERSATION_ID}" \
  IM_INTERNAL_SECRET="${IM_INTERNAL_SECRET}" \
  NON_LARGE_GROUP_MODE="${mode}" \
  NON_LARGE_GROUP_CAMPAIGN="${campaign}" \
  NON_LARGE_GROUP_ACCEPTANCE_CAMPAIGN="${campaign}" \
  NON_LARGE_GROUP_RUN_ID_PREFIX="${PRODUCT_SCENARIO_RUN_ID_PREFIX}-${stage_id}" \
  PERF_DRY_RUN="${PERF_DRY_RUN}" \
    "${PRODUCT_SCENARIO_RUN_NON_LARGE_GROUP}"
}

run_full_campaign_stage() {
  local stage_id="$1"
  local campaign="$2"
  local stage_result_root="${RESULT_ROOT}/${PRODUCT_SCENARIO_RUN_ID_PREFIX}-${stage_id}"
  local execute_args=()
  bool_enabled "${PRODUCT_SCENARIO_EXECUTE}" && execute_args+=(--execute)
  mkdir -p "${stage_result_root}"
  PERF_DRY_RUN="${PERF_DRY_RUN}" \
  BASE_URL="${BASE_URL}" \
  TCP_HOST="${TCP_HOST}" \
  TCP_PORT="${TCP_PORT}" \
  ACCOUNT_FILE="${ACCOUNT_FILE}" \
  IM_CONVERSATION_ID="${IM_CONVERSATION_ID}" \
  IM_INTERNAL_SECRET="${IM_INTERNAL_SECRET}" \
    python3 "${PRODUCT_SCENARIO_RUN_PRODUCT_CAMPAIGN}" \
      --campaign "${campaign}" \
      --result-dir "${stage_result_root}" \
      --json-output "${stage_result_root}/product-campaign-run.json" \
      --runbook-output "${stage_result_root}/product-campaign-runbook.md" \
      "${execute_args[@]}"
}

stage_result_root_for() {
  local stage_id="$1"
  printf '%s\n' "${RESULT_ROOT}/${PRODUCT_SCENARIO_RUN_ID_PREFIX}-${stage_id}"
}

append_suite_stage_receipt() {
  local stage_file="$1"
  local stage_id="$2"
  local runner="$3"
  local value="$4"
  local description="$5"
  local stage_result_root="$6"
  local status="$7"
  local rc="$8"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${stage_id}" \
    "${runner}" \
    "${value}" \
    "${description}" \
    "${stage_result_root}" \
    "${status}" \
    "${rc}" >>"${stage_file}"
}

write_suite_receipt() {
  local final_status="$1"
  local reason="$2"
  local started_at="$3"
  local ended_at="$4"
  local stage_file="$5"
  mkdir -p "${PRODUCT_SCENARIO_RECEIPT_DIR}"
  python3 - \
    "${PRODUCT_SCENARIO_RECEIPT_JSON}" \
    "${PRODUCT_SCENARIO_RECEIPT_MD}" \
    "${stage_file}" \
    "${final_status}" \
    "${reason}" \
    "${started_at}" \
    "${ended_at}" \
    "${PRODUCT_SCENARIO_SUITE}" \
    "${PRODUCT_SCENARIO_RUN_ID_PREFIX}" \
    "${RESULT_ROOT}" \
    "${BASE_URL}" \
    "${TCP_HOST}" \
    "${TCP_PORT}" \
    "${ACCOUNT_FILE}" \
    "${IM_CONVERSATION_ID}" \
    "${PERF_DRY_RUN}" \
    "${PRODUCT_SCENARIO_EXECUTE}" \
    "${PRODUCT_SCENARIO_STOP_ON_FAILURE}" \
    "${PRODUCT_SCENARIO_INCLUDE_LARGE_GROUP}" \
    "${PRODUCT_SCENARIO_RUN_PRODUCT_PLAN}" <<'PY'
import json
import os
import subprocess
import sys
from pathlib import Path

(
    json_path,
    md_path,
    stage_file,
    final_status,
    reason,
    started_at,
    ended_at,
    suite,
    run_id_prefix,
    result_root,
    base_url,
    tcp_host,
    tcp_port,
    account_file,
    conversation_id,
    dry_run,
    execute,
    stop_on_failure,
    include_large_group,
    product_plan_script,
) = sys.argv[1:]

stages = []
stage_path = Path(stage_file)

def as_bool(value):
    return str(value).lower() in {"1", "true", "yes", "on"}

def read_optional_json(path):
    try:
        if path.is_file():
            return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        return {"readError": str(exc), "path": str(path)}
    return {}


def first_failed_phase(payload):
    for phase in payload.get("phases") or payload.get("stages") or []:
        if not isinstance(phase, dict):
            continue
        if str(phase.get("status") or "") == "FAIL":
            return phase
    return {}


def entrypoint_probe_from_phase(phase):
    run_dir = Path(str(phase.get("runDir") or ""))
    if not run_dir.is_dir():
        return {}
    return read_optional_json(run_dir / "entrypoint-probe.json")


def stage_diagnostics(runner, run_dir):
    root = Path(run_dir)
    diagnostics = {}
    if runner == "product-plan":
        artifact = root / "product-test-plan-run.json"
        payload = read_optional_json(artifact)
        if payload:
            failed_phase = first_failed_phase(payload)
            probe = entrypoint_probe_from_phase(failed_phase)
            blocker = probe.get("blocker") if isinstance(probe.get("blocker"), dict) else {}
            diagnostics = {
                "artifact": str(artifact),
                "finalStatus": payload.get("finalStatus") or "",
                "reason": payload.get("reason") or "",
                "blockerType": payload.get("blockerType") or "",
                "failedPhase": failed_phase.get("phase") or "",
                "failedPhaseReason": failed_phase.get("reason") or "",
                "entrypointDiagnosis": probe.get("diagnosis") or "",
                "entrypointAction": blocker.get("action") or "",
                "entrypointSeverity": blocker.get("severity") or "",
                "preventsPerformanceEvidence": bool(blocker.get("preventsPerformanceEvidence")),
            }
            rescue = (payload.get("entrypoint") or {}).get("rescueArtifact") or {}
            if isinstance(rescue, dict) and rescue:
                diagnostics["entrypointRescueStatus"] = rescue.get("status") or ""
                diagnostics["entrypointRescueReason"] = rescue.get("reason") or ""
                diagnostics["entrypointRescueArtifactDir"] = rescue.get("artifactDir") or ""
                diagnostics["entrypointRescueTarball"] = rescue.get("tarball") or ""
                diagnostics["entrypointRescueLogFile"] = rescue.get("logFile") or ""
    else:
        artifact = root / "product-campaign-run.json"
        payload = read_optional_json(artifact)
        if payload:
            diagnostics = {
                "artifact": str(artifact),
                "finalStatus": payload.get("finalStatus") or payload.get("status") or "",
                "reason": payload.get("reason") or "",
                "campaign": payload.get("campaign") or "",
                "failureCount": payload.get("failureCount"),
                "requiredFailureCount": payload.get("requiredFailureCount"),
                "attemptedStageCount": payload.get("attemptedStageCount"),
            }
    return {key: value for key, value in diagnostics.items() if value not in ("", None)}


if stage_path.is_file():
    for raw in stage_path.read_text(encoding="utf-8").splitlines():
        parts = raw.split("\t")
        if len(parts) != 7:
            continue
        stage_id, runner, value, description, run_dir, status, rc = parts
        stage = {
            "id": stage_id,
            "runner": runner,
            "value": value,
            "description": description,
            "runDir": run_dir,
            "status": status,
            "exitCode": None if rc == "" else int(rc),
        }
        diagnostics = stage_diagnostics(runner, run_dir)
        if diagnostics:
            stage["diagnostics"] = diagnostics
        stages.append(stage)

def product_plan_preview(stage):
    env = os.environ.copy()
    env.update({
        "RESULT_ROOT": str(Path(stage["runDir"]) / "coverage-preview"),
        "PRODUCT_TEST_PRESET": stage["value"],
        "PRODUCT_TEST_RUN_ID_PREFIX": f"{run_id_prefix}-{stage['id']}-coverage-preview",
        "PRODUCT_TEST_PACKAGE_EVIDENCE": "false",
        "PERF_DRY_RUN": "true",
        "BASE_URL": base_url,
        "TCP_HOST": tcp_host,
        "TCP_PORT": tcp_port,
        "ACCOUNT_FILE": account_file,
        "IM_CONVERSATION_ID": conversation_id,
    })
    script = Path(product_plan_script)
    try:
        proc = subprocess.run(
            [str(script), "--print-plan-json"],
            cwd=str(script.parent),
            env=env,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except Exception as exc:
        return {
            "stage": stage["id"],
            "runner": stage["runner"],
            "value": stage["value"],
            "coverageStatus": "ERROR",
            "coverageError": str(exc),
        }
    if proc.returncode != 0:
        return {
            "stage": stage["id"],
            "runner": stage["runner"],
            "value": stage["value"],
            "coverageStatus": "ERROR",
            "coverageError": proc.stderr.strip() or proc.stdout.strip() or f"exit {proc.returncode}",
        }
    try:
        preview = json.loads(proc.stdout)
    except Exception as exc:
        return {
            "stage": stage["id"],
            "runner": stage["runner"],
            "value": stage["value"],
            "coverageStatus": "ERROR",
            "coverageError": f"invalid preview json: {exc}",
        }
    summary = preview.get("summary") or {}
    phases = preview.get("phases") or []
    selected = [str(item) for item in preview.get("selectedScenarios") or [] if str(item)]
    return {
        "stage": stage["id"],
        "runner": stage["runner"],
        "value": stage["value"],
        "coverageStatus": "READY",
        "phaseCount": summary.get("phaseCount", len(phases)),
        "scenarioPhaseCount": summary.get("scenarioPhaseCount"),
        "uniqueScenarioCount": summary.get("uniqueScenarioCount", len(selected)),
        "largeGroupIncluded": bool(summary.get("largeGroupIncluded")),
        "coveredProductDomains": summary.get("coveredProductDomains") or [],
        "requiredProductDomains": summary.get("requiredProductDomains") or [],
        "missingProductDomains": summary.get("missingProductDomains") or [],
        "requiredProductDomainsCovered": bool(summary.get("requiredProductDomainsCovered")),
        "requestedPhases": preview.get("requestedPhases") or [],
        "sampleScenarios": selected[:12],
        "selectedScenarios": selected,
    }

def campaign_coverage(stage):
    value = stage["value"]
    large = "large-group" in value or value in {"production-acceptance", "production-full-acceptance"}
    return {
        "stage": stage["id"],
        "runner": stage["runner"],
        "value": value,
        "coverageStatus": "READY",
        "campaign": value,
        "largeGroupIncluded": large,
        "uniqueScenarioCount": 0,
        "coveredProductDomains": [],
        "requiredProductDomains": [],
        "missingProductDomains": [],
    }

stage_coverage = []
unique_scenarios = []
seen_scenarios = set()
covered_domains = set()
required_domains = set()
missing_domains = set()
large_group_included = as_bool(include_large_group)
coverage_error_count = 0
for stage in stages:
    if stage["runner"] == "product-plan":
        coverage = product_plan_preview(stage)
    else:
        coverage = campaign_coverage(stage)
    stage_coverage.append(coverage)
    if coverage.get("coverageStatus") == "ERROR":
        coverage_error_count += 1
    large_group_included = large_group_included or bool(coverage.get("largeGroupIncluded"))
    for scenario in coverage.get("selectedScenarios") or []:
        if scenario not in seen_scenarios:
            seen_scenarios.add(scenario)
            unique_scenarios.append(scenario)
    covered_domains.update(str(item) for item in coverage.get("coveredProductDomains") or [] if str(item))
    required_domains.update(str(item) for item in coverage.get("requiredProductDomains") or [] if str(item))
    missing_domains.update(str(item) for item in coverage.get("missingProductDomains") or [] if str(item))

coverage_summary = {
    "stageCount": len(stage_coverage),
    "productPlanStageCount": sum(1 for item in stage_coverage if item.get("runner") == "product-plan"),
    "campaignStageCount": sum(1 for item in stage_coverage if item.get("runner") != "product-plan"),
    "coverageErrorCount": coverage_error_count,
    "uniqueScenarioCount": len(unique_scenarios),
    "largeGroupIncluded": large_group_included,
    "coveredProductDomains": sorted(covered_domains),
    "requiredProductDomains": sorted(required_domains),
    "missingProductDomains": sorted(missing_domains),
    "requiredProductDomainsCovered": not missing_domains if required_domains else False,
    "sampleScenarios": unique_scenarios[:16],
}

failure_summary = []
for stage in stages:
    if stage["status"] != "FAIL":
        continue
    diagnostics = stage.get("diagnostics") or {}
    failure_summary.append({
        "stage": stage["id"],
        "runner": stage["runner"],
        "value": stage["value"],
        "exitCode": stage["exitCode"],
        "reason": diagnostics.get("reason") or "",
        "blockerType": diagnostics.get("blockerType") or "",
        "failedPhase": diagnostics.get("failedPhase") or "",
        "failedPhaseReason": diagnostics.get("failedPhaseReason") or "",
        "entrypointDiagnosis": diagnostics.get("entrypointDiagnosis") or "",
        "entrypointAction": diagnostics.get("entrypointAction") or "",
        "entrypointRescueStatus": diagnostics.get("entrypointRescueStatus") or "",
        "entrypointRescueReason": diagnostics.get("entrypointRescueReason") or "",
        "entrypointRescueArtifactDir": diagnostics.get("entrypointRescueArtifactDir") or "",
        "entrypointRescueTarball": diagnostics.get("entrypointRescueTarball") or "",
        "preventsPerformanceEvidence": bool(diagnostics.get("preventsPerformanceEvidence")),
        "artifact": diagnostics.get("artifact") or stage["runDir"],
    })

payload = {
    "schemaVersion": 1,
    "suite": suite,
    "runIDPrefix": run_id_prefix,
    "status": final_status,
    "reason": reason,
    "startedAt": started_at,
    "endedAt": ended_at,
    "target": {
        "baseURL": base_url,
        "tcpHost": tcp_host,
        "tcpPort": tcp_port,
        "accountFile": account_file,
        "conversationIDPresent": bool(conversation_id),
    },
    "settings": {
        "dryRun": dry_run.lower() in {"1", "true", "yes", "on"},
        "execute": execute.lower() in {"1", "true", "yes", "on"},
        "stopOnFailure": stop_on_failure.lower() in {"1", "true", "yes", "on"},
        "includeLargeGroup": include_large_group.lower() in {"1", "true", "yes", "on"},
    },
    "stageCount": len(stages),
    "failedStageCount": sum(1 for stage in stages if stage["status"] == "FAIL"),
    "plannedStageCount": sum(1 for stage in stages if stage["status"] == "PLANNED"),
    "coverageSummary": coverage_summary,
    "failureSummary": failure_summary,
    "stageCoverage": stage_coverage,
    "stages": stages,
    "artifacts": {
        "json": json_path,
        "markdown": md_path,
    },
}

Path(json_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")

lines = [
    "# Product Scenario Suite Run",
    "",
    f"- suite: `{suite}`",
    f"- status: `{final_status}`",
    f"- reason: `{reason}`",
    f"- runIDPrefix: `{run_id_prefix}`",
    f"- baseURL: `{base_url}`",
    f"- tcpHost: `{tcp_host}`",
    f"- tcpPort: `{tcp_port}`",
    f"- dryRun: `{payload['settings']['dryRun']}`",
    f"- execute: `{payload['settings']['execute']}`",
    f"- includeLargeGroup: `{payload['settings']['includeLargeGroup']}`",
    f"- coverageUniqueScenarios: `{coverage_summary['uniqueScenarioCount']}`",
    f"- coverageDomains: `{','.join(coverage_summary['coveredProductDomains']) or '-'}`",
    f"- coverageMissingDomains: `{','.join(coverage_summary['missingProductDomains']) or '-'}`",
    f"- coverageLargeGroupIncluded: `{coverage_summary['largeGroupIncluded']}`",
    "",
    "## Coverage",
    "",
    "| Stage | Runner | Coverage | Scenarios | Domains | Missing Domains | Large Group |",
    "| --- | --- | --- | --- | --- | --- | --- |",
]
for item in stage_coverage:
    lines.append(
        f"| `{item['stage']}` | `{item['runner']}` | `{item.get('coverageStatus') or '-'}` | "
        f"`{item.get('uniqueScenarioCount', 0)}` | "
        f"`{','.join(item.get('coveredProductDomains') or []) or '-'}` | "
        f"`{','.join(item.get('missingProductDomains') or []) or '-'}` | "
        f"`{bool(item.get('largeGroupIncluded'))}` |"
    )
lines.extend([
    "",
    "## Stages",
    "",
    "| Stage | Runner | Value | Status | Exit | Run Dir |",
    "| --- | --- | --- | --- | --- | --- |",
])
for stage in stages:
    exit_code = "-" if stage["exitCode"] is None else str(stage["exitCode"])
    lines.append(
        f"| `{stage['id']}` | `{stage['runner']}` | `{stage['value']}` | "
        f"`{stage['status']}` | `{exit_code}` | `{stage['runDir']}` |"
    )
if failure_summary:
    lines.extend([
        "",
        "## Failure Summary",
        "",
        "| Stage | Reason | Blocker | Failed Phase | Entrypoint Diagnosis | Action | Rescue | Artifact |",
        "| --- | --- | --- | --- | --- | --- | --- | --- |",
    ])
    for item in failure_summary:
        rescue_text = item["entrypointRescueStatus"] or "-"
        if item["entrypointRescueReason"]:
            rescue_text = f"{rescue_text}:{item['entrypointRescueReason']}"
        lines.append(
            f"| `{item['stage']}` | `{item['reason'] or '-'}` | `{item['blockerType'] or '-'}` | "
            f"`{item['failedPhase'] or '-'}` | `{item['entrypointDiagnosis'] or '-'}` | "
            f"`{item['entrypointAction'] or '-'}` | `{rescue_text}` | `{item['artifact']}` |"
        )
Path(md_path).write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
}

run_suite() {
  require_suite_policy
  local stage_id runner value description stage_rc stage_status
  local started_at ended_at stage_file final_status final_reason
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "${PRODUCT_SCENARIO_RECEIPT_DIR}"
  stage_file="${PRODUCT_SCENARIO_RECEIPT_DIR}/product-scenario-suite-stages.tsv"
  : >"${stage_file}"
  final_status="PASS"
  final_reason="all_stages_passed"
  while IFS=$'\t' read -r stage_id runner value description; do
    printf 'product_scenario_suite stage=start suite=%s stage=%s runner=%s value=%s\n' \
      "${PRODUCT_SCENARIO_SUITE}" \
      "${stage_id}" \
      "${runner}" \
      "${value}"
    if ! bool_enabled "${PRODUCT_SCENARIO_EXECUTE}"; then
      append_suite_stage_receipt \
        "${stage_file}" \
        "${stage_id}" \
        "${runner}" \
        "${value}" \
        "${description}" \
        "$(stage_result_root_for "${stage_id}")" \
        "PLANNED" \
        ""
      stage_command "${stage_id}" "${runner}" "${value}" true
      continue
    fi
    set +e
    case "${runner}" in
      product-plan)
        run_product_plan_stage "${stage_id}" "${value}"
        ;;
      non-large-campaign)
        run_non_large_campaign_stage "${stage_id}" "campaign" "${value}"
        ;;
      non-large-acceptance)
        run_non_large_campaign_stage "${stage_id}" "acceptance" "${value}"
        ;;
      full-campaign)
        run_full_campaign_stage "${stage_id}" "${value}"
        ;;
      *)
        printf 'product_scenario_suite result=fail reason=unknown_runner runner=%s\n' "${runner}" >&2
        ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        append_suite_stage_receipt \
          "${stage_file}" \
          "${stage_id}" \
          "${runner}" \
          "${value}" \
          "${description}" \
          "$(stage_result_root_for "${stage_id}")" \
          "FAIL" \
          "2"
        write_suite_receipt "FAIL" "unknown_runner" "${started_at}" "${ended_at}" "${stage_file}"
        return 2
        ;;
    esac
    stage_rc=$?
    set -e
    stage_status="PASS"
    [[ "${stage_rc}" -ne 0 ]] && stage_status="FAIL"
    append_suite_stage_receipt \
      "${stage_file}" \
      "${stage_id}" \
      "${runner}" \
      "${value}" \
      "${description}" \
      "$(stage_result_root_for "${stage_id}")" \
      "${stage_status}" \
      "${stage_rc}"
    printf 'product_scenario_suite stage=done suite=%s stage=%s rc=%s\n' \
      "${PRODUCT_SCENARIO_SUITE}" \
      "${stage_id}" \
      "${stage_rc}"
    if [[ "${stage_rc}" -ne 0 ]] && bool_enabled "${PRODUCT_SCENARIO_STOP_ON_FAILURE}"; then
      final_status="FAIL"
      final_reason="stage_failed:${stage_id}"
      ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      write_suite_receipt "${final_status}" "${final_reason}" "${started_at}" "${ended_at}" "${stage_file}"
      printf 'product_scenario_suite result=fail reason=stage_failed suite=%s stage=%s rc=%s\n' \
        "${PRODUCT_SCENARIO_SUITE}" \
        "${stage_id}" \
        "${stage_rc}" >&2
      return "${stage_rc}"
    fi
    if [[ "${stage_rc}" -ne 0 ]]; then
      final_status="FAIL"
      final_reason="one_or_more_stages_failed"
    fi
  done < <(suite_stage_rows "${PRODUCT_SCENARIO_SUITE}")
  if ! bool_enabled "${PRODUCT_SCENARIO_EXECUTE}"; then
    final_status="PLANNED"
    final_reason="execute_disabled"
  fi
  ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  write_suite_receipt "${final_status}" "${final_reason}" "${started_at}" "${ended_at}" "${stage_file}"
  if [[ "${final_status}" == "PASS" || "${final_status}" == "PLANNED" ]]; then
    printf 'product_scenario_suite result=pass suite=%s receipt=%s\n' "${PRODUCT_SCENARIO_SUITE}" "${PRODUCT_SCENARIO_RECEIPT_JSON}"
  else
    printf 'product_scenario_suite result=fail reason=%s suite=%s receipt=%s\n' "${final_reason}" "${PRODUCT_SCENARIO_SUITE}" "${PRODUCT_SCENARIO_RECEIPT_JSON}" >&2
    return 1
  fi
}

self_test() {
  local tmpdir account_file suite
  tmpdir="$(mktemp -d)"
  trap "rm -rf '${tmpdir}'" EXIT
  account_file="${tmpdir}/accounts.csv"
  for index in $(seq 1 5000); do
    printf 'load%04d@example.com,password1234\n' "${index}"
  done >"${account_file}"

  PRODUCT_SCENARIO_SUITE=recommended \
  RESULT_ROOT="${tmpdir}/results" \
  PERF_DRY_RUN=true \
  ACCOUNT_FILE="${account_file}" \
  IM_CONVERSATION_ID="00000000-0000-4000-8000-000000000001" \
  IM_INTERNAL_SECRET="self-test-secret" \
  PRODUCT_SCENARIO_SELF_TEST=false \
    "${BASH_SOURCE[0]}" --print-plan >"${tmpdir}/recommended-plan.txt"
  for expected in normal-smoke normal-breadth workflow-regression realtime-focused normal-baseline; do
    grep -q "${expected}" "${tmpdir}/recommended-plan.txt" || {
      printf 'product_scenario_suite_self_test result=fail reason=recommended_stage_missing stage=%s\n' "${expected}" >&2
      return 1
    }
  done
  if PRODUCT_SCENARIO_SUITE=full \
    RESULT_ROOT="${tmpdir}/results" \
    PERF_DRY_RUN=true \
    ACCOUNT_FILE="${account_file}" \
    IM_CONVERSATION_ID="00000000-0000-4000-8000-000000000001" \
    IM_INTERNAL_SECRET="self-test-secret" \
    PRODUCT_SCENARIO_SELF_TEST=false \
      "${BASH_SOURCE[0]}" --validate-plan >"${tmpdir}/full.out" 2>"${tmpdir}/full.err"; then
    printf 'product_scenario_suite_self_test result=fail reason=full_suite_allowed_without_opt_in\n' >&2
    return 1
  fi
  grep -q 'reason=full_suite_requires_large_group_opt_in' "${tmpdir}/full.err" || {
    printf 'product_scenario_suite_self_test result=fail reason=full_suite_guard_reason_missing\n' >&2
    return 1
  }
  for suite in smoke breadth workflow realtime baseline capacity regression acceptance recommended; do
    PRODUCT_SCENARIO_SUITE="${suite}" \
    PRODUCT_SCENARIO_RUN_ID_PREFIX="self-test-${suite}" \
    RESULT_ROOT="${tmpdir}/results" \
    PERF_DRY_RUN=true \
    ACCOUNT_FILE="${account_file}" \
    IM_CONVERSATION_ID="00000000-0000-4000-8000-000000000001" \
    IM_INTERNAL_SECRET="self-test-secret" \
    PRODUCT_SCENARIO_SELF_TEST=false \
      "${BASH_SOURCE[0]}" --validate-plan >/dev/null
  done
  PRODUCT_SCENARIO_SUITE=full \
  PRODUCT_SCENARIO_INCLUDE_LARGE_GROUP=true \
  RESULT_ROOT="${tmpdir}/results" \
  PERF_DRY_RUN=true \
  ACCOUNT_FILE="${account_file}" \
  IM_CONVERSATION_ID="00000000-0000-4000-8000-000000000001" \
  IM_INTERNAL_SECRET="self-test-secret" \
  PRODUCT_SCENARIO_SELF_TEST=false \
    "${BASH_SOURCE[0]}" --validate-plan >/dev/null
  PRODUCT_SCENARIO_SUITE=smoke \
  PRODUCT_SCENARIO_EXECUTE=false \
  PRODUCT_SCENARIO_RUN_ID_PREFIX="self-test-planned" \
  RESULT_ROOT="${tmpdir}/results" \
  PERF_DRY_RUN=true \
  ACCOUNT_FILE="${account_file}" \
  IM_CONVERSATION_ID="00000000-0000-4000-8000-000000000001" \
  IM_INTERNAL_SECRET="self-test-secret" \
  PRODUCT_SCENARIO_SELF_TEST=false \
    "${BASH_SOURCE[0]}" >/dev/null
  python3 "${SCRIPT_DIR}/perf_product_scenario_suite_verify.py" \
    --suite-run-json "${tmpdir}/results/self-test-planned-suite/product-scenario-suite-run.json" \
    --markdown "${tmpdir}/results/self-test-planned-suite/product-scenario-suite-run.md" \
    --allow-planned \
    --require-no-large-group >/dev/null
  python3 - "${tmpdir}/results/self-test-planned-suite/product-scenario-suite-run.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
if payload.get("status") != "PLANNED":
    raise SystemExit(f"Expected PLANNED suite receipt, got {payload.get('status')}")
if payload.get("reason") != "execute_disabled":
    raise SystemExit(f"Expected execute_disabled reason, got {payload.get('reason')}")
if payload.get("stageCount") != 1 or payload.get("plannedStageCount") != 1:
    raise SystemExit("Expected one planned stage in smoke plan receipt.")
if payload.get("settings", {}).get("includeLargeGroup"):
    raise SystemExit("Smoke suite receipt must not include large group.")
PY
  fake_plan="${tmpdir}/fake-product-plan.sh"
  cat >"${fake_plan}" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "--print-plan-json" ]]; then
cat <<'JSON'
{
  "schemaVersion": 1,
  "requestedPhases": ["entrypoint", "real-world-smoke"],
  "summary": {
    "phaseCount": 2,
    "scenarioPhaseCount": 1,
    "uniqueScenarioCount": 3,
    "largeGroupIncluded": false,
    "coveredProductDomains": ["auth-session", "client-sync", "message-workflow"],
    "requiredProductDomains": ["auth-session", "client-sync", "message-workflow"],
    "missingProductDomains": [],
    "requiredProductDomainsCovered": true
  },
  "selectedScenarios": ["login-smoke", "client-sync-mix-smoke", "direct-message-lifecycle-smoke"],
  "phases": [
    {"phase": "entrypoint", "kind": "entrypoint", "scenarioCount": 0},
    {"phase": "real-world-smoke", "kind": "scenario-groups", "scenarioCount": 3}
  ]
}
JSON
exit 0
fi
mkdir -p "${RESULT_ROOT}/fake-entrypoint"
cat >"${RESULT_ROOT}/fake-entrypoint/entrypoint-probe.json" <<'JSON'
{
  "diagnosis": "cloud_edge_http_403_intercept",
  "blocker": {
    "action": "cloud_console_rescue_required",
    "severity": "P0",
    "preventsPerformanceEvidence": true
  }
}
JSON
cat >"${RESULT_ROOT}/product-test-plan-run.json" <<JSON
{
  "finalStatus": "FAIL",
  "reason": "entrypoint_failed",
  "blockerType": "entrypoint",
  "entrypoint": {
    "required": true,
    "rescueArtifact": {
      "schemaVersion": 1,
      "status": "SKIPPED",
      "reason": "missing_ssh_key_source",
      "enabled": true,
      "packageEnabled": true,
      "dryRun": false,
      "artifactDir": "${RESULT_ROOT}/current-node-access-rescue",
      "artifactDirExists": false,
      "tarball": "${RESULT_ROOT}/current-node-access-rescue.tar.gz",
      "tarballExists": false,
      "logFile": "",
      "logFileExists": false
    }
  },
  "phases": [
    {
      "phase": "entrypoint",
      "status": "FAIL",
      "reason": "entrypoint_probe_failed",
      "runDir": "${RESULT_ROOT}/fake-entrypoint"
    }
  ]
}
JSON
exit 7
SH
  chmod +x "${fake_plan}"
  if PRODUCT_SCENARIO_SUITE=smoke \
    PRODUCT_SCENARIO_RUN_PRODUCT_PLAN="${fake_plan}" \
    PRODUCT_SCENARIO_RUN_ID_PREFIX="self-test-fail" \
    RESULT_ROOT="${tmpdir}/results" \
    PERF_DRY_RUN=false \
    ACCOUNT_FILE="${account_file}" \
    IM_CONVERSATION_ID="00000000-0000-4000-8000-000000000001" \
    IM_INTERNAL_SECRET="self-test-secret" \
  PRODUCT_SCENARIO_SELF_TEST=false \
      "${BASH_SOURCE[0]}" >"${tmpdir}/fail-suite.out" 2>"${tmpdir}/fail-suite.err"; then
    printf 'product_scenario_suite_self_test result=fail reason=failing_stage_allowed\n' >&2
    return 1
  fi
  python3 "${SCRIPT_DIR}/perf_product_scenario_suite_verify.py" \
    --suite-run-json "${tmpdir}/results/self-test-fail-suite/product-scenario-suite-run.json" \
    --markdown "${tmpdir}/results/self-test-fail-suite/product-scenario-suite-run.md" \
    --require-no-large-group >/dev/null
  if python3 "${SCRIPT_DIR}/perf_product_scenario_suite_verify.py" \
    --suite-run-json "${tmpdir}/results/self-test-fail-suite/product-scenario-suite-run.json" \
    --markdown "${tmpdir}/results/self-test-fail-suite/product-scenario-suite-run.md" \
    --require-pass >"${tmpdir}/fail-suite-require-pass.out" 2>"${tmpdir}/fail-suite-require-pass.err"; then
    printf 'product_scenario_suite_self_test result=fail reason=failing_receipt_passed_require_pass\n' >&2
    return 1
  fi
  grep -q 'reason=status_not_pass' "${tmpdir}/fail-suite-require-pass.err" || {
    printf 'product_scenario_suite_self_test result=fail reason=failing_receipt_require_pass_reason_missing\n' >&2
    return 1
  }
  python3 - "${tmpdir}/results/self-test-fail-suite/product-scenario-suite-run.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
if payload.get("status") != "FAIL":
    raise SystemExit(f"Expected FAIL suite receipt, got {payload.get('status')}")
if payload.get("reason") != "stage_failed:normal-smoke":
    raise SystemExit(f"Unexpected fail reason: {payload.get('reason')}")
stages = payload.get("stages") or []
if len(stages) != 1 or stages[0].get("status") != "FAIL" or stages[0].get("exitCode") != 7:
    raise SystemExit(f"Unexpected stage receipt: {stages}")
diagnostics = stages[0].get("diagnostics") or {}
if diagnostics.get("reason") != "entrypoint_failed":
    raise SystemExit(f"Expected promoted stage diagnostics reason, got {diagnostics}")
if diagnostics.get("entrypointDiagnosis") != "cloud_edge_http_403_intercept":
    raise SystemExit(f"Expected promoted entrypoint diagnosis, got {diagnostics}")
if diagnostics.get("entrypointRescueStatus") != "SKIPPED" or diagnostics.get("entrypointRescueReason") != "missing_ssh_key_source":
    raise SystemExit(f"Expected promoted rescue status, got {diagnostics}")
summary = payload.get("failureSummary") or []
if len(summary) != 1 or summary[0].get("entrypointAction") != "cloud_console_rescue_required":
    raise SystemExit(f"Unexpected failure summary: {summary}")
if summary[0].get("entrypointRescueStatus") != "SKIPPED" or summary[0].get("entrypointRescueReason") != "missing_ssh_key_source":
    raise SystemExit(f"Unexpected failure summary rescue fields: {summary}")
PY
  grep -q '## Failure Summary' "${tmpdir}/results/self-test-fail-suite/product-scenario-suite-run.md" || {
    printf 'product_scenario_suite_self_test result=fail reason=failure_summary_markdown_missing\n' >&2
    return 1
  }
  grep -q 'cloud_edge_http_403_intercept' "${tmpdir}/results/self-test-fail-suite/product-scenario-suite-run.md" || {
    printf 'product_scenario_suite_self_test result=fail reason=failure_summary_diagnosis_missing\n' >&2
    return 1
  }
  grep -q 'SKIPPED:missing_ssh_key_source' "${tmpdir}/results/self-test-fail-suite/product-scenario-suite-run.md" || {
    printf 'product_scenario_suite_self_test result=fail reason=failure_summary_rescue_missing\n' >&2
    return 1
  }
  printf 'product_scenario_suite_self_test result=pass\n'
}

case "${1:-}" in
  --help|-h)
    usage
    ;;
  --list)
    usage
    ;;
  --print-plan)
    print_plan
    ;;
  --validate-plan)
    validate_plan
    ;;
  "")
    if bool_enabled "${PRODUCT_SCENARIO_SELF_TEST}"; then
      self_test
    else
      run_suite
    fi
    ;;
  *)
    printf 'product_scenario_suite result=fail reason=unknown_argument arg=%s\n' "$1" >&2
    usage >&2
    exit 2
    ;;
esac
