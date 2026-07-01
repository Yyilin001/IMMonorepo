#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT_ROOT="${RESULT_ROOT:-${SCRIPT_DIR}/results}"
RESULT_ROOT="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve())' "${RESULT_ROOT}")"

NON_LARGE_GROUP_MODE="${NON_LARGE_GROUP_MODE:-release}"
NON_LARGE_GROUP_RELEASE_CAMPAIGN="${NON_LARGE_GROUP_RELEASE_CAMPAIGN:-non-large-group-release}"
NON_LARGE_GROUP_CAMPAIGN="${NON_LARGE_GROUP_CAMPAIGN:-product-scenario-regression}"
NON_LARGE_GROUP_ACCEPTANCE_CAMPAIGN="${NON_LARGE_GROUP_ACCEPTANCE_CAMPAIGN:-product-scenario-acceptance}"
NON_LARGE_GROUP_DOMAIN="${NON_LARGE_GROUP_DOMAIN:-}"
NON_LARGE_GROUP_RUN_ID_PREFIX="${NON_LARGE_GROUP_RUN_ID_PREFIX:-non-large-group-$(date +%Y%m%d-%H%M%S)}"
NON_LARGE_GROUP_REQUIRE_NO_LARGE_GROUP="${NON_LARGE_GROUP_REQUIRE_NO_LARGE_GROUP:-true}"
NON_LARGE_GROUP_ENTRYPOINT_PROBE="${NON_LARGE_GROUP_ENTRYPOINT_PROBE:-true}"
NON_LARGE_GROUP_FAIL_ON_ENTRYPOINT_ERROR="${NON_LARGE_GROUP_FAIL_ON_ENTRYPOINT_ERROR:-true}"
NON_LARGE_GROUP_PROBE_PROTOCOL_PORTS="${NON_LARGE_GROUP_PROBE_PROTOCOL_PORTS:-22 ${TCP_PORT:-9000}}"
NON_LARGE_GROUP_PROBE_ADDITIONAL_HOSTS="${NON_LARGE_GROUP_PROBE_ADDITIONAL_HOSTS:-${TCP_HOST:-}}"
NON_LARGE_GROUP_HTTP_ENTRYPOINT_PROBE="${NON_LARGE_GROUP_HTTP_ENTRYPOINT_PROBE:-${SCRIPT_DIR}/http_entrypoint_probe.sh}"
NON_LARGE_GROUP_ENTRYPOINT_RESCUE_ARTIFACT="${NON_LARGE_GROUP_ENTRYPOINT_RESCUE_ARTIFACT:-true}"
NON_LARGE_GROUP_ENTRYPOINT_RESCUE_ARTIFACT_DIR="${NON_LARGE_GROUP_ENTRYPOINT_RESCUE_ARTIFACT_DIR:-${RESULT_ROOT}/current-node-access-rescue}"
NON_LARGE_GROUP_ENTRYPOINT_RESCUE_ARTIFACT_DIR="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve())' "${NON_LARGE_GROUP_ENTRYPOINT_RESCUE_ARTIFACT_DIR}")"
NON_LARGE_GROUP_ENTRYPOINT_RESCUE_ARTIFACT_PACKAGE="${NON_LARGE_GROUP_ENTRYPOINT_RESCUE_ARTIFACT_PACKAGE:-true}"
NON_LARGE_GROUP_EXECUTE="${NON_LARGE_GROUP_EXECUTE:-true}"
NON_LARGE_GROUP_VERIFY_ARTIFACTS="${NON_LARGE_GROUP_VERIFY_ARTIFACTS:-true}"
NON_LARGE_GROUP_ALLOW_UNVERIFIED_ARTIFACTS="${NON_LARGE_GROUP_ALLOW_UNVERIFIED_ARTIFACTS:-false}"
NON_LARGE_GROUP_RUN_PRODUCT_CAMPAIGN="${NON_LARGE_GROUP_RUN_PRODUCT_CAMPAIGN:-${SCRIPT_DIR}/run_product_campaign.py}"
PERF_DRY_RUN="${PERF_DRY_RUN:-false}"

BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
TCP_HOST="${TCP_HOST:-}"
TCP_PORT="${TCP_PORT:-9000}"
ACCOUNT_FILE="${ACCOUNT_FILE:-}"
IM_CONVERSATION_ID="${IM_CONVERSATION_ID:-}"
IM_INTERNAL_SECRET="${IM_INTERNAL_SECRET:-${IM_INTERNAL_SHARED_SECRET:-}}"
if [[ -n "${ACCOUNT_FILE}" ]]; then
  ACCOUNT_FILE="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve())' "${ACCOUNT_FILE}")"
fi

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
if [[ -z "${NON_LARGE_GROUP_PROBE_ADDITIONAL_HOSTS}" ]]; then
  NON_LARGE_GROUP_PROBE_ADDITIONAL_HOSTS="${TCP_HOST}"
fi

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

usage() {
  cat <<'EOF'
Usage:
  run_non_large_group_regression.sh [--list|--print-plan|--validate-plan]

Purpose:
  Run or plan ordinary IM product scenarios without large-group fanout stress.
  Use this before judging normal chat capacity or before running isolated
  large-group scenarios.

Modes:
  NON_LARGE_GROUP_MODE=release    Run the production-gate non-large-group campaign.
  NON_LARGE_GROUP_MODE=acceptance Run the full normal-product scenario acceptance campaign.
  NON_LARGE_GROUP_MODE=campaign   Run NON_LARGE_GROUP_CAMPAIGN for diagnostics.
  NON_LARGE_GROUP_MODE=smoke      Run normal-product-smoke.
  NON_LARGE_GROUP_MODE=baseline   Run normal-product-baseline.
  NON_LARGE_GROUP_MODE=capacity   Run normal-product-capacity.
  NON_LARGE_GROUP_MODE=domain     Run one named domain group.

Domain values:
  Set NON_LARGE_GROUP_DOMAIN to any scenario group accepted by
  run_perf_scenarios.sh --list, except groups that expand to large-group-*.
  Common focused groups:
    daily-core-smoke
    daily-core-baseline
    daily-traffic-smoke
    daily-traffic-baseline
    account-security
    account-security-baseline
    sync-read
    sync-read-baseline
    sync-recovery
    sync-recovery-baseline
    direct-chat
    direct-chat-baseline
    message-workflow
    message-workflow-baseline
    group-workflow
    group-workflow-baseline
    group-delivery-smoke
    group-delivery
    group-delivery-baseline
    contacts-social
    contacts-social-baseline
    social-profile
    social-profile-baseline
    media-ai-admin
    media-ai-admin-baseline
    message-spike
    message-spike-baseline
    reliability-recovery
    reliability-recovery-baseline
    lifecycle-governance
    lifecycle-governance-baseline
    realtime-direct
    realtime-direct-baseline

Common env:
  RESULT_ROOT=IMServer/LoadTests/results
  PERF_DRY_RUN=true|false
  NON_LARGE_GROUP_EXECUTE=true|false
  NON_LARGE_GROUP_ACCEPTANCE_CAMPAIGN=product-scenario-acceptance
  NON_LARGE_GROUP_ENTRYPOINT_PROBE=true|false
  NON_LARGE_GROUP_FAIL_ON_ENTRYPOINT_ERROR=true|false
  NON_LARGE_GROUP_PROBE_PROTOCOL_PORTS="22 9000"
  NON_LARGE_GROUP_PROBE_ADDITIONAL_HOSTS="tcp-host"
  NON_LARGE_GROUP_ENTRYPOINT_RESCUE_ARTIFACT=true|false
  NON_LARGE_GROUP_ENTRYPOINT_RESCUE_ARTIFACT_DIR=results/current-node-access-rescue
  NON_LARGE_GROUP_ENTRYPOINT_RESCUE_ARTIFACT_PACKAGE=true|false
  NON_LARGE_GROUP_VERIFY_ARTIFACTS=true|false
  NON_LARGE_GROUP_ALLOW_UNVERIFIED_ARTIFACTS=true|false
  NON_LARGE_GROUP_RUN_PRODUCT_CAMPAIGN=/path/run_product_campaign.py
  BASE_URL=https://chat.yourdomain.com
  TCP_HOST=tcp.yourdomain.com  # optional; derived from BASE_URL when empty
  TCP_PORT=9000
  ACCOUNT_FILE=/path/load-5000.csv
  IM_CONVERSATION_ID=<uuid>
  IM_INTERNAL_SECRET=<secret>
  Replace *.yourdomain.com before running; production gates reject literal placeholder domains.
  For local development only, override BASE_URL=http://127.0.0.1:8080 and TCP_HOST=127.0.0.1.
EOF
}

scenario_group_for_mode() {
  case "$1" in
    smoke)
      printf '%s\n' "normal-product-smoke"
      ;;
    baseline)
      printf '%s\n' "normal-product-baseline"
      ;;
    capacity)
      printf '%s\n' "normal-product-capacity"
      ;;
    domain)
      if [[ -z "${NON_LARGE_GROUP_DOMAIN}" ]]; then
        echo "NON_LARGE_GROUP_DOMAIN is required when NON_LARGE_GROUP_MODE=domain." >&2
        return 2
      fi
      printf '%s\n' "${NON_LARGE_GROUP_DOMAIN}"
      ;;
    *)
      echo "Mode ${1} does not map to a scenario group." >&2
      return 2
      ;;
  esac
}

expanded_scenarios_for_group() {
  local group="$1"
  SCENARIO_GROUPS="${group}" "${SCRIPT_DIR}/run_perf_scenarios.sh" --expand-groups
}

assert_no_large_group() {
  local label="$1"
  local payload="$2"
  if ! bool_enabled "${NON_LARGE_GROUP_REQUIRE_NO_LARGE_GROUP}"; then
    return 0
  fi
  if grep -Eq '(^|[[:space:]])large-group-|SCENARIO_GROUPS=large-group' <<<"${payload}"; then
    printf 'non_large_group_regression result=fail reason=large_group_included label=%s\n' "${label}" >&2
    return 1
  fi
}

print_plan() {
  local group scenarios
  case "${NON_LARGE_GROUP_MODE}" in
    release)
      printf 'mode=%s campaign=%s resultRoot=%s dryRun=%s execute=%s verifyArtifacts=%s allowUnverifiedArtifacts=%s entrypointProbe=campaign-stage productionGateCampaign=true\n' \
        "${NON_LARGE_GROUP_MODE}" \
        "${NON_LARGE_GROUP_RELEASE_CAMPAIGN}" \
        "${RESULT_ROOT}" \
        "${PERF_DRY_RUN}" \
        "${NON_LARGE_GROUP_EXECUTE}" \
        "${NON_LARGE_GROUP_VERIFY_ARTIFACTS}" \
        "${NON_LARGE_GROUP_ALLOW_UNVERIFIED_ARTIFACTS}"
      ;;
    acceptance)
      printf 'mode=%s campaign=%s resultRoot=%s dryRun=%s execute=%s verifyArtifacts=%s allowUnverifiedArtifacts=%s entrypointProbe=campaign-stage productionGateCampaign=false\n' \
        "${NON_LARGE_GROUP_MODE}" \
        "${NON_LARGE_GROUP_ACCEPTANCE_CAMPAIGN}" \
        "${RESULT_ROOT}" \
        "${PERF_DRY_RUN}" \
        "${NON_LARGE_GROUP_EXECUTE}" \
        "${NON_LARGE_GROUP_VERIFY_ARTIFACTS}" \
        "${NON_LARGE_GROUP_ALLOW_UNVERIFIED_ARTIFACTS}"
      ;;
    campaign)
      printf 'mode=%s campaign=%s resultRoot=%s dryRun=%s execute=%s verifyArtifacts=%s allowUnverifiedArtifacts=%s entrypointProbe=campaign-stage productionGateCampaign=false\n' \
        "${NON_LARGE_GROUP_MODE}" \
        "${NON_LARGE_GROUP_CAMPAIGN}" \
        "${RESULT_ROOT}" \
        "${PERF_DRY_RUN}" \
        "${NON_LARGE_GROUP_EXECUTE}" \
        "${NON_LARGE_GROUP_VERIFY_ARTIFACTS}" \
        "${NON_LARGE_GROUP_ALLOW_UNVERIFIED_ARTIFACTS}"
      ;;
    smoke|baseline|capacity|domain)
      group="$(scenario_group_for_mode "${NON_LARGE_GROUP_MODE}")"
      scenarios="$(expanded_scenarios_for_group "${group}")"
      assert_no_large_group "${group}" "${scenarios}"
      printf 'mode=%s scenarioGroups=%s scenarioCount=%s resultRoot=%s dryRun=%s entrypointProbe=%s failOnEntrypointError=%s probeProtocolPorts=%q probeAdditionalHosts=%q\n' \
        "${NON_LARGE_GROUP_MODE}" \
        "${group}" \
        "$(wc -w <<<"${scenarios}" | tr -d ' ')" \
        "${RESULT_ROOT}" \
        "${PERF_DRY_RUN}" \
        "${NON_LARGE_GROUP_ENTRYPOINT_PROBE}" \
        "${NON_LARGE_GROUP_FAIL_ON_ENTRYPOINT_ERROR}" \
        "${NON_LARGE_GROUP_PROBE_PROTOCOL_PORTS}" \
        "${NON_LARGE_GROUP_PROBE_ADDITIONAL_HOSTS}"
      printf '%s\n' "${scenarios}"
      ;;
    *)
      echo "Unknown NON_LARGE_GROUP_MODE: ${NON_LARGE_GROUP_MODE}" >&2
      return 2
      ;;
  esac
}

validate_plan() {
  local plan group scenarios campaign_dir
  case "${NON_LARGE_GROUP_MODE}" in
    release)
      campaign_dir="$(mktemp -d)"
      PERF_DRY_RUN=true \
      BASE_URL="${BASE_URL}" \
      TCP_HOST="${TCP_HOST}" \
      TCP_PORT="${TCP_PORT}" \
      ACCOUNT_FILE="${ACCOUNT_FILE}" \
      IM_CONVERSATION_ID="${IM_CONVERSATION_ID}" \
      IM_INTERNAL_SECRET="${IM_INTERNAL_SECRET}" \
        python3 "${SCRIPT_DIR}/run_product_campaign.py" \
          --campaign "${NON_LARGE_GROUP_RELEASE_CAMPAIGN}" \
          --result-dir "${campaign_dir}" \
          --json-output "${campaign_dir}/product-campaign-run.json" \
          --runbook-output "${campaign_dir}/product-campaign-runbook.md" >/dev/null
      plan="$(cat "${campaign_dir}/product-campaign-run.json" "${campaign_dir}/product-campaign-runbook.md")"
      assert_no_large_group "${NON_LARGE_GROUP_RELEASE_CAMPAIGN}" "${plan}"
      python3 "${SCRIPT_DIR}/perf_product_campaign_artifacts_verify.py" \
        --campaign-run-json "${campaign_dir}/product-campaign-run.json" \
        --runbook "${campaign_dir}/product-campaign-runbook.md" \
        --allow-planned \
        --require-production-gate-campaign >/dev/null
      rm -rf "${campaign_dir}"
      ;;
    acceptance)
      campaign_dir="$(mktemp -d)"
      PERF_DRY_RUN=true \
      BASE_URL="${BASE_URL}" \
      TCP_HOST="${TCP_HOST}" \
      TCP_PORT="${TCP_PORT}" \
      ACCOUNT_FILE="${ACCOUNT_FILE}" \
      IM_CONVERSATION_ID="${IM_CONVERSATION_ID}" \
      IM_INTERNAL_SECRET="${IM_INTERNAL_SECRET}" \
        python3 "${SCRIPT_DIR}/run_product_campaign.py" \
          --campaign "${NON_LARGE_GROUP_ACCEPTANCE_CAMPAIGN}" \
          --result-dir "${campaign_dir}" \
          --json-output "${campaign_dir}/product-campaign-run.json" \
          --runbook-output "${campaign_dir}/product-campaign-runbook.md" >/dev/null
      plan="$(cat "${campaign_dir}/product-campaign-run.json" "${campaign_dir}/product-campaign-runbook.md")"
      assert_no_large_group "${NON_LARGE_GROUP_ACCEPTANCE_CAMPAIGN}" "${plan}"
      python3 "${SCRIPT_DIR}/perf_product_campaign_artifacts_verify.py" \
        --campaign-run-json "${campaign_dir}/product-campaign-run.json" \
        --runbook "${campaign_dir}/product-campaign-runbook.md" \
        --allow-planned >/dev/null
      rm -rf "${campaign_dir}"
      ;;
    campaign)
      campaign_dir="$(mktemp -d)"
      PERF_DRY_RUN=true \
      BASE_URL="${BASE_URL}" \
      TCP_HOST="${TCP_HOST}" \
      TCP_PORT="${TCP_PORT}" \
      ACCOUNT_FILE="${ACCOUNT_FILE}" \
      IM_CONVERSATION_ID="${IM_CONVERSATION_ID}" \
      IM_INTERNAL_SECRET="${IM_INTERNAL_SECRET}" \
        python3 "${SCRIPT_DIR}/run_product_campaign.py" \
          --campaign "${NON_LARGE_GROUP_CAMPAIGN}" \
          --result-dir "${campaign_dir}" \
          --json-output "${campaign_dir}/product-campaign-run.json" \
          --runbook-output "${campaign_dir}/product-campaign-runbook.md" >/dev/null
      plan="$(cat "${campaign_dir}/product-campaign-run.json" "${campaign_dir}/product-campaign-runbook.md")"
      assert_no_large_group "${NON_LARGE_GROUP_CAMPAIGN}" "${plan}"
      rm -rf "${campaign_dir}"
      ;;
    smoke|baseline|capacity|domain)
      group="$(scenario_group_for_mode "${NON_LARGE_GROUP_MODE}")"
      scenarios="$(expanded_scenarios_for_group "${group}")"
      [[ -n "${scenarios}" ]] || {
        printf 'non_large_group_regression result=fail reason=empty_scenario_group group=%s\n' "${group}" >&2
        return 1
      }
      assert_no_large_group "${group}" "${scenarios}"
      ;;
    *)
      echo "Unknown NON_LARGE_GROUP_MODE: ${NON_LARGE_GROUP_MODE}" >&2
      return 2
      ;;
  esac
  local selected_campaign="${NON_LARGE_GROUP_CAMPAIGN}"
  [[ "${NON_LARGE_GROUP_MODE}" == "release" ]] && selected_campaign="${NON_LARGE_GROUP_RELEASE_CAMPAIGN}"
  [[ "${NON_LARGE_GROUP_MODE}" == "acceptance" ]] && selected_campaign="${NON_LARGE_GROUP_ACCEPTANCE_CAMPAIGN}"
  printf 'non_large_group_regression result=pass mode=%s campaign=%s domain=%s\n' \
    "${NON_LARGE_GROUP_MODE}" \
    "${selected_campaign}" \
    "${NON_LARGE_GROUP_DOMAIN:-}"
}

assert_verification_policy() {
  if bool_enabled "${NON_LARGE_GROUP_VERIFY_ARTIFACTS}"; then
    return 0
  fi
  if [[ "${NON_LARGE_GROUP_MODE}" == "release" ]] \
    && bool_enabled "${NON_LARGE_GROUP_EXECUTE}" \
    && ! bool_enabled "${PERF_DRY_RUN}" \
    && ! bool_enabled "${NON_LARGE_GROUP_ALLOW_UNVERIFIED_ARTIFACTS}"; then
    printf 'non_large_group_regression result=fail reason=release_requires_artifact_verification mode=%s execute=%s verifyArtifacts=%s\n' \
      "${NON_LARGE_GROUP_MODE}" \
      "${NON_LARGE_GROUP_EXECUTE}" \
      "${NON_LARGE_GROUP_VERIFY_ARTIFACTS}" >&2
    printf 'Set NON_LARGE_GROUP_VERIFY_ARTIFACTS=true for production evidence. Use NON_LARGE_GROUP_ALLOW_UNVERIFIED_ARTIFACTS=true only for local wrapper tests with fake campaign output.\n' >&2
    return 2
  fi
}

verify_campaign_artifacts() {
  local campaign_name="$1"
  local result_dir="$2"
  local campaign_rc="$3"
  if ! bool_enabled "${NON_LARGE_GROUP_VERIFY_ARTIFACTS}"; then
    return 0
  fi

  local verify_args=(
    --campaign-run-json "${result_dir}/product-campaign-run.json"
    --runbook "${result_dir}/product-campaign-runbook.md"
  )
  if ! bool_enabled "${NON_LARGE_GROUP_EXECUTE}"; then
    verify_args+=(--allow-planned)
  fi
  if [[ "${NON_LARGE_GROUP_MODE}" == "release" ]]; then
    verify_args+=(--require-production-gate-campaign)
    if bool_enabled "${NON_LARGE_GROUP_EXECUTE}" && [[ "${campaign_rc}" -eq 0 ]]; then
      verify_args+=(--require-pass)
    fi
  fi

  python3 "${SCRIPT_DIR}/perf_product_campaign_artifacts_verify.py" "${verify_args[@]}"
}

run_campaign() {
  local campaign_name="$1"
  local result_dir="${RESULT_ROOT}/${NON_LARGE_GROUP_RUN_ID_PREFIX}-${campaign_name}"
  local campaign_rc
  local execute_args=()
  assert_verification_policy
  bool_enabled "${NON_LARGE_GROUP_EXECUTE}" && execute_args+=(--execute)
  mkdir -p "${result_dir}"
  set +e
  PERF_DRY_RUN="${PERF_DRY_RUN}" \
  BASE_URL="${BASE_URL}" \
  TCP_HOST="${TCP_HOST}" \
  TCP_PORT="${TCP_PORT}" \
  ACCOUNT_FILE="${ACCOUNT_FILE}" \
  IM_CONVERSATION_ID="${IM_CONVERSATION_ID}" \
  PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT="${NON_LARGE_GROUP_ENTRYPOINT_RESCUE_ARTIFACT}" \
  PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT_DIR="${NON_LARGE_GROUP_ENTRYPOINT_RESCUE_ARTIFACT_DIR}" \
  PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT_PACKAGE="${NON_LARGE_GROUP_ENTRYPOINT_RESCUE_ARTIFACT_PACKAGE}" \
  SSH_PRIVATE_KEY_PATH="${SSH_PRIVATE_KEY_PATH:-}" \
  SSH_AUTHORIZED_KEY="${SSH_AUTHORIZED_KEY:-}" \
    IM_INTERNAL_SECRET="${IM_INTERNAL_SECRET}" \
    python3 "${NON_LARGE_GROUP_RUN_PRODUCT_CAMPAIGN}" \
      --campaign "${campaign_name}" \
      --result-dir "${result_dir}" \
      --json-output "${result_dir}/product-campaign-run.json" \
      --runbook-output "${result_dir}/product-campaign-runbook.md" \
      "${execute_args[@]}"
  campaign_rc=$?
  set -e
  verify_campaign_artifacts "${campaign_name}" "${result_dir}" "${campaign_rc}"
  return "${campaign_rc}"
}

run_entrypoint_probe() {
  local run_dir="$1"
  if bool_enabled "${PERF_DRY_RUN}" || ! bool_enabled "${NON_LARGE_GROUP_ENTRYPOINT_PROBE}"; then
    return 0
  fi
  mkdir -p "${run_dir}"
  local probe_log="${run_dir}/entrypoint-probe.log"
  local probe_json="${run_dir}/entrypoint-probe.json"
  local fail_on_error="false"
  bool_enabled "${NON_LARGE_GROUP_FAIL_ON_ENTRYPOINT_ERROR}" && fail_on_error="true"
  if ! BASE_URL="${BASE_URL}" \
    ACCOUNT_FILE="${ACCOUNT_FILE}" \
    IM_EMAIL="${IM_EMAIL:-demo@example.com}" \
    IM_PASSWORD="${IM_PASSWORD:-password1234}" \
    PROBE_FAIL_ON_ENTRYPOINT_ERROR="${fail_on_error}" \
    PROBE_PROTOCOL_PORTS="${NON_LARGE_GROUP_PROBE_PROTOCOL_PORTS}" \
    PROBE_ADDITIONAL_PROTOCOL_HOSTS="${NON_LARGE_GROUP_PROBE_ADDITIONAL_HOSTS}" \
    PROBE_JSON_OUTPUT="${probe_json}" \
      "${NON_LARGE_GROUP_HTTP_ENTRYPOINT_PROBE}" >"${probe_log}" 2>&1; then
    generate_entrypoint_rescue_artifact "${run_dir}"
    printf 'non_large_group_regression result=fail reason=entrypoint_probe_failed log=%s json=%s\n' \
      "${probe_log}" \
      "${probe_json}" >&2
    return 1
  fi
}

generate_entrypoint_rescue_artifact() {
  local run_dir="$1"
  local log_file
  if ! bool_enabled "${NON_LARGE_GROUP_ENTRYPOINT_RESCUE_ARTIFACT}"; then
    return 0
  fi
  if bool_enabled "${PERF_DRY_RUN}"; then
    printf 'non_large_group_regression entrypoint_rescue_artifact=skipped reason=dry_run\n'
    return 0
  fi
  if [[ -z "${SSH_PRIVATE_KEY_PATH:-}" && -z "${SSH_AUTHORIZED_KEY:-}" ]]; then
    printf 'non_large_group_regression entrypoint_rescue_artifact=skipped reason=missing_ssh_key_source\n'
    return 0
  fi
  if [[ ! -x "${SCRIPT_DIR}/generate_node_access_rescue_artifact.sh" ]]; then
    printf 'non_large_group_regression entrypoint_rescue_artifact=skipped reason=generator_missing\n'
    return 0
  fi

  mkdir -p "${run_dir}"
  log_file="${run_dir}/entrypoint-rescue-artifact.log"
  printf 'non_large_group_regression entrypoint_rescue_artifact=start dir=%s log=%s\n' \
    "${NON_LARGE_GROUP_ENTRYPOINT_RESCUE_ARTIFACT_DIR}" \
    "${log_file}"
  if PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT=false \
    NODE_ACCESS_RESCUE_ARTIFACT_DIR="${NON_LARGE_GROUP_ENTRYPOINT_RESCUE_ARTIFACT_DIR}" \
    NODE_ACCESS_RESCUE_ARTIFACT_PACKAGE="${NON_LARGE_GROUP_ENTRYPOINT_RESCUE_ARTIFACT_PACKAGE}" \
    PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-${BASE_URL}}" \
    BASE_URL="${BASE_URL}" \
    TCP_HOST="${TCP_HOST}" \
    TCP_PORT="${TCP_PORT}" \
    IM_TCP_PORT="${TCP_PORT}" \
    ACCOUNT_FILE="${ACCOUNT_FILE}" \
    PRODUCT_TEST_PHASES="entrypoint real-world-smoke" \
    PRODUCT_TEST_STOP_ON_FAILURE=true \
    PRODUCT_TEST_RUN_FULL_PROFILE=false \
    PERF_DRY_RUN=false \
      bash "${SCRIPT_DIR}/generate_node_access_rescue_artifact.sh" >"${log_file}" 2>&1; then
    printf 'non_large_group_regression entrypoint_rescue_artifact=pass dir=%s\n' \
      "${NON_LARGE_GROUP_ENTRYPOINT_RESCUE_ARTIFACT_DIR}"
    return 0
  fi
  printf 'non_large_group_regression entrypoint_rescue_artifact=fail log=%s\n' "${log_file}" >&2
  return 0
}

run_group() {
  local group run_id run_dir
  group="$(scenario_group_for_mode "${NON_LARGE_GROUP_MODE}")"
  assert_no_large_group "${group}" "$(expanded_scenarios_for_group "${group}")"
  run_id="${NON_LARGE_GROUP_RUN_ID_PREFIX}-${NON_LARGE_GROUP_MODE}"
  run_dir="${RESULT_ROOT}/${run_id}"
  run_entrypoint_probe "${run_dir}"
  RUN_ID="${run_id}" \
  RESULT_ROOT="${RESULT_ROOT}" \
  SCENARIO_GROUPS="${group}" \
  PERF_DRY_RUN="${PERF_DRY_RUN}" \
  BASE_URL="${BASE_URL}" \
  TCP_HOST="${TCP_HOST}" \
  TCP_PORT="${TCP_PORT}" \
  ACCOUNT_FILE="${ACCOUNT_FILE}" \
  IM_CONVERSATION_ID="${IM_CONVERSATION_ID}" \
  IM_INTERNAL_SECRET="${IM_INTERNAL_SECRET}" \
    "${SCRIPT_DIR}/run_perf_scenarios.sh"
}

self_test() {
  local tmpdir account_file
  tmpdir="$(mktemp -d)"
  trap "rm -rf '${tmpdir}'" EXIT
  account_file="${tmpdir}/accounts.csv"
  for index in $(seq 1 5000); do
    printf 'load%04d@example.com,password1234\n' "${index}"
  done >"${account_file}"

  "${BASH_SOURCE[0]}" --list >"${tmpdir}/list.txt"
  grep -q 'NON_LARGE_GROUP_MODE=release' "${tmpdir}/list.txt" || {
    printf 'non_large_group_regression_self_test result=fail reason=list_missing_release_mode\n' >&2
    return 1
  }
  grep -q 'NON_LARGE_GROUP_MODE=acceptance' "${tmpdir}/list.txt" || {
    printf 'non_large_group_regression_self_test result=fail reason=list_missing_acceptance_mode\n' >&2
    return 1
  }
  RESULT_ROOT="${tmpdir}/results" \
  ACCOUNT_FILE="${account_file}" \
  IM_CONVERSATION_ID="00000000-0000-4000-8000-000000000001" \
  IM_INTERNAL_SECRET="self-test-secret" \
  NON_LARGE_GROUP_MODE=release \
    "${BASH_SOURCE[0]}" --validate-plan >/dev/null
  RESULT_ROOT="${tmpdir}/results" \
  ACCOUNT_FILE="${account_file}" \
  IM_CONVERSATION_ID="00000000-0000-4000-8000-000000000001" \
  IM_INTERNAL_SECRET="self-test-secret" \
  NON_LARGE_GROUP_MODE=acceptance \
    "${BASH_SOURCE[0]}" --validate-plan >/dev/null
  RESULT_ROOT="${tmpdir}/results" \
  ACCOUNT_FILE="${account_file}" \
  IM_CONVERSATION_ID="00000000-0000-4000-8000-000000000001" \
  IM_INTERNAL_SECRET="self-test-secret" \
  NON_LARGE_GROUP_MODE=smoke \
    "${BASH_SOURCE[0]}" --validate-plan >/dev/null
  RESULT_ROOT="${tmpdir}/results" \
  ACCOUNT_FILE="${account_file}" \
  IM_CONVERSATION_ID="00000000-0000-4000-8000-000000000001" \
  IM_INTERNAL_SECRET="self-test-secret" \
  NON_LARGE_GROUP_MODE=baseline \
    "${BASH_SOURCE[0]}" --validate-plan >/dev/null
  RESULT_ROOT="${tmpdir}/results" \
  ACCOUNT_FILE="${account_file}" \
  IM_CONVERSATION_ID="00000000-0000-4000-8000-000000000001" \
  IM_INTERNAL_SECRET="self-test-secret" \
  NON_LARGE_GROUP_MODE=domain \
  NON_LARGE_GROUP_DOMAIN=direct-chat \
    "${BASH_SOURCE[0]}" --validate-plan >/dev/null
  RESULT_ROOT="${tmpdir}/results" \
  ACCOUNT_FILE="${account_file}" \
  IM_CONVERSATION_ID="00000000-0000-4000-8000-000000000001" \
  IM_INTERNAL_SECRET="self-test-secret" \
  NON_LARGE_GROUP_MODE=domain \
  NON_LARGE_GROUP_DOMAIN=group-delivery \
    "${BASH_SOURCE[0]}" --validate-plan >/dev/null
  RESULT_ROOT="${tmpdir}/results" \
  ACCOUNT_FILE="${account_file}" \
  IM_CONVERSATION_ID="00000000-0000-4000-8000-000000000001" \
  IM_INTERNAL_SECRET="self-test-secret" \
  NON_LARGE_GROUP_MODE=domain \
  NON_LARGE_GROUP_DOMAIN=sync-recovery-baseline \
    "${BASH_SOURCE[0]}" --validate-plan >/dev/null
  RESULT_ROOT="${tmpdir}/results" \
  ACCOUNT_FILE="${account_file}" \
  IM_CONVERSATION_ID="00000000-0000-4000-8000-000000000001" \
  IM_INTERNAL_SECRET="self-test-secret" \
  NON_LARGE_GROUP_MODE=domain \
  NON_LARGE_GROUP_DOMAIN=daily-traffic-smoke \
    "${BASH_SOURCE[0]}" --validate-plan >/dev/null
  if RESULT_ROOT="${tmpdir}/results" \
    ACCOUNT_FILE="${account_file}" \
    IM_CONVERSATION_ID="00000000-0000-4000-8000-000000000001" \
    IM_INTERNAL_SECRET="self-test-secret" \
    NON_LARGE_GROUP_MODE=domain \
    NON_LARGE_GROUP_DOMAIN=large-group \
      "${BASH_SOURCE[0]}" --validate-plan >"${tmpdir}/large-group-domain.out" 2>"${tmpdir}/large-group-domain.err"; then
    printf 'non_large_group_regression_self_test result=fail reason=large_group_domain_allowed\n' >&2
    return 1
  fi
  grep -q 'reason=large_group_included' "${tmpdir}/large-group-domain.err" || {
    printf 'non_large_group_regression_self_test result=fail reason=large_group_domain_rejection_missing\n' >&2
    return 1
  }
  RESULT_ROOT="${tmpdir}/results" \
  ACCOUNT_FILE="${account_file}" \
  IM_CONVERSATION_ID="00000000-0000-4000-8000-000000000001" \
  IM_INTERNAL_SECRET="self-test-secret" \
  NON_LARGE_GROUP_MODE=campaign \
    "${BASH_SOURCE[0]}" --validate-plan >/dev/null
  RESULT_ROOT="${tmpdir}/results" \
  PERF_DRY_RUN=true \
  ACCOUNT_FILE="${account_file}" \
  IM_CONVERSATION_ID="00000000-0000-4000-8000-000000000001" \
  IM_INTERNAL_SECRET="self-test-secret" \
  NON_LARGE_GROUP_MODE=smoke \
    "${BASH_SOURCE[0]}" --print-plan >"${tmpdir}/print-plan.txt"
  grep -q 'entrypointProbe=true' "${tmpdir}/print-plan.txt" || {
    printf 'non_large_group_regression_self_test result=fail reason=print_plan_missing_entrypoint_probe\n' >&2
    return 1
  }
  grep -q 'probeProtocolPorts=' "${tmpdir}/print-plan.txt" || {
    printf 'non_large_group_regression_self_test result=fail reason=print_plan_missing_probe_protocol_ports\n' >&2
    return 1
  }
  RESULT_ROOT="${tmpdir}/results" \
  BASE_URL="http://203.0.113.10:8080" \
  TCP_HOST="" \
  ACCOUNT_FILE="${account_file}" \
  IM_CONVERSATION_ID="00000000-0000-4000-8000-000000000001" \
  IM_INTERNAL_SECRET="self-test-secret" \
  NON_LARGE_GROUP_MODE=smoke \
    "${BASH_SOURCE[0]}" --print-plan >"${tmpdir}/derived-target-plan.txt"
  grep -q 'probeAdditionalHosts=203.0.113.10' "${tmpdir}/derived-target-plan.txt" || {
    printf 'non_large_group_regression_self_test result=fail reason=derived_tcp_host_missing\n' >&2
    return 1
  }
  fake_entrypoint_probe="${tmpdir}/fake-entrypoint-probe.sh"
  cat >"${fake_entrypoint_probe}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat >"${PROBE_JSON_OUTPUT}" <<'JSON'
{
  "schemaVersion": 1,
  "failed": true,
  "diagnosis": "cloud_edge_http_403_intercept",
  "detail": "self-test entrypoint failure",
  "signals": {
    "nginxHealthStatus": "403",
    "healthStatus": "403",
    "loginStatus": "403",
    "tcpStatus": "http_403_intercepted"
  },
  "blocker": {
    "type": "entrypoint",
    "severity": "P0",
    "preventsPerformanceEvidence": true,
    "action": "cloud_console_rescue_required"
  }
}
JSON
printf 'fake_entrypoint_probe result=fail\n'
exit 1
SH
  chmod +x "${fake_entrypoint_probe}"
  if RESULT_ROOT="${tmpdir}/probe-fail-results" \
    ACCOUNT_FILE="${account_file}" \
    IM_CONVERSATION_ID="00000000-0000-4000-8000-000000000001" \
    IM_INTERNAL_SECRET="self-test-secret" \
    NON_LARGE_GROUP_MODE=smoke \
    NON_LARGE_GROUP_HTTP_ENTRYPOINT_PROBE="${fake_entrypoint_probe}" \
    NON_LARGE_GROUP_REGRESSION_SELF_TEST=false \
      "${BASH_SOURCE[0]}" >"${tmpdir}/probe-fail.out" 2>"${tmpdir}/probe-fail.err"; then
    printf 'non_large_group_regression_self_test result=fail reason=failing_entrypoint_probe_passed\n' >&2
    return 1
  fi
  grep -q 'entrypoint_rescue_artifact=skipped reason=missing_ssh_key_source' "${tmpdir}/probe-fail.out" || {
    printf 'non_large_group_regression_self_test result=fail reason=rescue_artifact_missing_key_skip_absent\n' >&2
    return 1
  }
  grep -q 'reason=entrypoint_probe_failed' "${tmpdir}/probe-fail.err" || {
    printf 'non_large_group_regression_self_test result=fail reason=failing_entrypoint_probe_reason_missing\n' >&2
    return 1
  }
  [[ "$(find "${tmpdir}/probe-fail-results" -path '*-smoke/entrypoint-probe.json' -type f | wc -l | tr -d ' ')" -gt 0 ]] || {
    printf 'non_large_group_regression_self_test result=fail reason=failing_entrypoint_probe_json_missing\n' >&2
    return 1
  }
  fake_campaign_runner="${tmpdir}/fake-run-product-campaign.py"
  cat >"${fake_campaign_runner}" <<'PY'
#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--campaign", required=True)
parser.add_argument("--result-dir", required=True)
parser.add_argument("--json-output", required=True)
parser.add_argument("--runbook-output", required=True)
parser.add_argument("--execute", action="store_true")
args = parser.parse_args()
Path(args.result_dir).mkdir(parents=True, exist_ok=True)
Path(args.json_output).write_text(json.dumps({
    "schemaVersion": 1,
    "campaign": args.campaign,
    "execute": args.execute,
    "finalStatus": "PASS" if args.execute else "PLANNED",
    "stageCount": 1,
    "failureCount": 0,
    "requiredFailureCount": 0,
    "attemptedStageCount": 1 if args.execute else 0,
    "skippedStageCount": 0,
    "receivedEnv": {
        "PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT": os.environ.get("PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT", ""),
        "PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT_DIR": os.environ.get("PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT_DIR", ""),
        "PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT_PACKAGE": os.environ.get("PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT_PACKAGE", ""),
        "SSH_PRIVATE_KEY_PATH": os.environ.get("SSH_PRIVATE_KEY_PATH", ""),
        "SSH_AUTHORIZED_KEY_PRESENT": str(bool(os.environ.get("SSH_AUTHORIZED_KEY"))).lower(),
    },
    "stages": [{"id": "fake", "runner": "product-plan", "required": True, "status": "PASS" if args.execute else "PLANNED", "command": "fake"}],
}, indent=2), encoding="utf-8")
Path(args.runbook_output).write_text("fake runbook\n", encoding="utf-8")
PY
  chmod +x "${fake_campaign_runner}"
  RESULT_ROOT="${tmpdir}/execute-results" \
  ACCOUNT_FILE="${account_file}" \
  IM_CONVERSATION_ID="00000000-0000-4000-8000-000000000001" \
  IM_INTERNAL_SECRET="self-test-secret" \
  NON_LARGE_GROUP_MODE=release \
  NON_LARGE_GROUP_RUN_ID_PREFIX=self-test-release \
  NON_LARGE_GROUP_RUN_PRODUCT_CAMPAIGN="${fake_campaign_runner}" \
  NON_LARGE_GROUP_ENTRYPOINT_RESCUE_ARTIFACT_DIR="${tmpdir}/release-rescue" \
  SSH_AUTHORIZED_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakePublicKeyForSelfTest non-large-group-self-test" \
  NON_LARGE_GROUP_VERIFY_ARTIFACTS=false \
  NON_LARGE_GROUP_ALLOW_UNVERIFIED_ARTIFACTS=true \
  NON_LARGE_GROUP_REGRESSION_SELF_TEST=false \
    "${BASH_SOURCE[0]}" >/dev/null
  python3 - "${tmpdir}/execute-results/self-test-release-non-large-group-release/product-campaign-run.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if payload.get("campaign") != "non-large-group-release":
    raise SystemExit("non_large_group_regression_self_test result=fail reason=default_campaign_not_release")
if payload.get("execute") is not True:
    raise SystemExit("non_large_group_regression_self_test result=fail reason=default_release_not_executed")
if payload.get("finalStatus") == "PLANNED":
    raise SystemExit("non_large_group_regression_self_test result=fail reason=default_release_planned")
received = payload.get("receivedEnv") or {}
if received.get("PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT") != "true":
    raise SystemExit("non_large_group_regression_self_test result=fail reason=campaign_rescue_artifact_toggle_not_forwarded")
if not received.get("PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT_DIR", "").endswith("/release-rescue"):
    raise SystemExit("non_large_group_regression_self_test result=fail reason=campaign_rescue_artifact_dir_not_forwarded")
if received.get("PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT_PACKAGE") != "true":
    raise SystemExit("non_large_group_regression_self_test result=fail reason=campaign_rescue_artifact_package_not_forwarded")
if received.get("SSH_AUTHORIZED_KEY_PRESENT") != "true":
    raise SystemExit("non_large_group_regression_self_test result=fail reason=campaign_ssh_authorized_key_not_forwarded")
PY
  if RESULT_ROOT="${tmpdir}/guard-results" \
    ACCOUNT_FILE="${account_file}" \
    IM_CONVERSATION_ID="00000000-0000-4000-8000-000000000001" \
    IM_INTERNAL_SECRET="self-test-secret" \
    NON_LARGE_GROUP_MODE=release \
    NON_LARGE_GROUP_RUN_ID_PREFIX=self-test-guard \
    NON_LARGE_GROUP_RUN_PRODUCT_CAMPAIGN="${fake_campaign_runner}" \
    NON_LARGE_GROUP_VERIFY_ARTIFACTS=false \
    NON_LARGE_GROUP_ALLOW_UNVERIFIED_ARTIFACTS=false \
    NON_LARGE_GROUP_REGRESSION_SELF_TEST=false \
      "${BASH_SOURCE[0]}" >"${tmpdir}/guard.out" 2>"${tmpdir}/guard.err"; then
    printf 'non_large_group_regression_self_test result=fail reason=unguarded_unverified_release_passed\n' >&2
    return 1
  fi
  grep -q 'reason=release_requires_artifact_verification' "${tmpdir}/guard.err" || {
    printf 'non_large_group_regression_self_test result=fail reason=unverified_release_guard_missing\n' >&2
    return 1
  }
  printf 'non_large_group_regression_self_test result=pass\n'
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
    if bool_enabled "${NON_LARGE_GROUP_REGRESSION_SELF_TEST:-false}"; then
      self_test
    elif [[ "${NON_LARGE_GROUP_MODE}" == "release" ]]; then
      validate_plan >/dev/null
      run_campaign "${NON_LARGE_GROUP_RELEASE_CAMPAIGN}"
    elif [[ "${NON_LARGE_GROUP_MODE}" == "acceptance" ]]; then
      validate_plan >/dev/null
      run_campaign "${NON_LARGE_GROUP_ACCEPTANCE_CAMPAIGN}"
    elif [[ "${NON_LARGE_GROUP_MODE}" == "campaign" ]]; then
      validate_plan >/dev/null
      run_campaign "${NON_LARGE_GROUP_CAMPAIGN}"
    else
      validate_plan >/dev/null
      run_group
    fi
    ;;
  *)
    printf 'non_large_group_regression result=fail reason=unknown_argument arg=%s\n' "$1" >&2
    usage >&2
    exit 2
    ;;
esac
