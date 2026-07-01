#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRODUCTION_TARGET_POLICY="${PRODUCTION_TARGET_POLICY:-${SCRIPT_DIR}/production_target_policy.py}"
RESULT_ROOT="${RESULT_ROOT:-${SCRIPT_DIR}/results}"
RESULT_ROOT="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve())' "${RESULT_ROOT}")"
PRODUCT_TEST_PLAN="${PRODUCT_TEST_PLAN:-non-large-group}"
DEFAULT_PRODUCT_TEST_PHASES="entrypoint daily-core account-security sync-read direct-chat group-workflow contacts-social media-ai-admin message-spike reliability-recovery lifecycle-governance realtime-direct"
PRODUCT_TEST_PRESET="${PRODUCT_TEST_PRESET:-}"
PRODUCT_TEST_PHASES="${PRODUCT_TEST_PHASES:-}"
PRODUCT_TEST_RUN_FULL_PROFILE="${PRODUCT_TEST_RUN_FULL_PROFILE:-false}"
PRODUCT_TEST_FULL_PROFILE="${PRODUCT_TEST_FULL_PROFILE:-normal-product-baseline}"
PRODUCT_TEST_PACKAGE_EVIDENCE="${PRODUCT_TEST_PACKAGE_EVIDENCE:-true}"
PRODUCT_TEST_RUN_ID_PREFIX="${PRODUCT_TEST_RUN_ID_PREFIX:-product-${PRODUCT_TEST_PLAN}-$(date +%Y%m%d-%H%M%S)}"
PRODUCT_TEST_PLAN_JSON="${PRODUCT_TEST_PLAN_JSON:-${RESULT_ROOT}/product-test-plan-run.json}"
PRODUCT_TEST_PLAN_PREVIEW_JSON="${PRODUCT_TEST_PLAN_PREVIEW_JSON:-${RESULT_ROOT}/product-test-plan-preview.json}"
PRODUCT_TEST_STATUS_TSV="${PRODUCT_TEST_STATUS_TSV:-${RESULT_ROOT}/product-test-plan-phases.tsv}"
PRODUCT_TEST_STOP_ON_FAILURE="${PRODUCT_TEST_STOP_ON_FAILURE:-true}"
PRODUCT_TEST_OPERATOR_NETWORK_PREFLIGHT="${PRODUCT_TEST_OPERATOR_NETWORK_PREFLIGHT:-true}"
PRODUCT_TEST_FAIL_ON_OPERATOR_NETWORK="${PRODUCT_TEST_FAIL_ON_OPERATOR_NETWORK:-true}"
PRODUCT_TEST_FAIL_ON_LOCAL_NETWORK="${PRODUCT_TEST_FAIL_ON_LOCAL_NETWORK:-${PRODUCT_TEST_FAIL_ON_OPERATOR_NETWORK}}"
PRODUCT_TEST_OPERATOR_NETWORK_PREFLIGHT_SCRIPT="${PRODUCT_TEST_OPERATOR_NETWORK_PREFLIGHT_SCRIPT:-${SCRIPT_DIR}/../../deploy/ubuntu/20_verify_operator_network.sh}"
PRODUCT_TEST_ENTRYPOINT_PROBE="${PRODUCT_TEST_ENTRYPOINT_PROBE:-true}"
PRODUCT_TEST_REQUIRE_ENTRYPOINT="${PRODUCT_TEST_REQUIRE_ENTRYPOINT:-true}"
PRODUCT_TEST_PREREQ_GATE="${PRODUCT_TEST_PREREQ_GATE:-true}"
PRODUCT_TEST_PREREQ_PLAN_JSON="${PRODUCT_TEST_PREREQ_PLAN_JSON:-${RESULT_ROOT}/product-test-prereq-plan.json}"
PRODUCT_TEST_PREREQ_AUDIT_JSON="${PRODUCT_TEST_PREREQ_AUDIT_JSON:-${RESULT_ROOT}/product-test-prereq-audit.json}"
PRODUCT_TEST_PREREQ_AUDIT_MD="${PRODUCT_TEST_PREREQ_AUDIT_MD:-${RESULT_ROOT}/product-test-prereq-audit.md}"
PRODUCT_TEST_SCENARIO_CATALOG_JSON="${PRODUCT_TEST_SCENARIO_CATALOG_JSON:-${RESULT_ROOT}/product-test-scenario-catalog.json}"
PRODUCT_TEST_RUNBOOK_JSON="${PRODUCT_TEST_RUNBOOK_JSON:-${RESULT_ROOT}/product-test-runbook.json}"
PRODUCT_TEST_RUNBOOK_MD="${PRODUCT_TEST_RUNBOOK_MD:-${RESULT_ROOT}/product-test-runbook.md}"
PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT="${PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT:-true}"
PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT_DIR="${PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT_DIR:-${RESULT_ROOT}/current-node-access-rescue}"
PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT_PACKAGE="${PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT_PACKAGE:-true}"
PRODUCT_TEST_ENTRYPOINT_RESCUE_JSON="${PRODUCT_TEST_ENTRYPOINT_RESCUE_JSON:-${RESULT_ROOT}/entrypoint-rescue-artifact.json}"
PRODUCT_TEST_REQUIRE_PUBLIC_TARGET="${PRODUCT_TEST_REQUIRE_PUBLIC_TARGET:-}"
PRODUCT_TEST_SELF_TEST="${PRODUCT_TEST_SELF_TEST:-false}"

PERF_DRY_RUN="${PERF_DRY_RUN:-false}"
PERF_STATUS_FILTER_TARGET="${PERF_STATUS_FILTER_TARGET:-true}"
PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET="${PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET:-}"
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

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_product_test_require_public_target() {
  if [[ -n "${PRODUCT_TEST_REQUIRE_PUBLIC_TARGET}" ]]; then
    printf '%s\n' "${PRODUCT_TEST_REQUIRE_PUBLIC_TARGET}"
  elif bool_enabled "${PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET}"; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

PRODUCT_TEST_REQUIRE_PUBLIC_TARGET_EFFECTIVE="$(resolve_product_test_require_public_target)"

validate_public_target() {
  if ! bool_enabled "${PRODUCT_TEST_REQUIRE_PUBLIC_TARGET_EFFECTIVE}"; then
    return 0
  fi
  if bool_enabled "${PERF_DRY_RUN}"; then
    return 0
  fi
  python3 "${PRODUCTION_TARGET_POLICY}" \
    --base-url "${BASE_URL}" \
    --tcp-host "${TCP_HOST}" \
    --tcp-port "${TCP_PORT}" \
    --result-prefix "product_test_plan"
}

product_test_preset_names() {
  cat <<'EOF'
normal-smoke
normal-breadth
normal-acceptance
normal-baseline
normal-capacity
workflow-regression
realtime-focused
EOF
}

product_test_preset_phases() {
  case "$1" in
    normal-smoke)
      printf '%s\n' "entrypoint real-world-smoke daily-core sync-read direct-chat group-workflow contacts-social media-ai-admin reliability-recovery realtime-direct"
      ;;
    normal-breadth)
      printf '%s\n' "entrypoint real-world-smoke daily-core daily-traffic account-security sync-read direct-chat group-workflow contacts-social media-ai-admin message-spike reliability-recovery lifecycle-governance realtime-direct group-delivery"
      ;;
    normal-acceptance)
      printf '%s\n' "entrypoint real-world-baseline daily-core daily-traffic account-security-baseline sync-read-baseline direct-chat-baseline group-workflow-baseline contacts-social-baseline media-ai-admin-baseline message-spike-baseline reliability-recovery-baseline lifecycle-governance-baseline realtime-direct-baseline group-delivery-baseline"
      ;;
    normal-baseline)
      printf '%s\n' "entrypoint real-world-baseline account-security-baseline sync-read-baseline direct-chat-baseline group-workflow-baseline contacts-social-baseline media-ai-admin-baseline message-spike-baseline reliability-recovery-baseline lifecycle-governance-baseline realtime-direct-baseline group-delivery-baseline"
      ;;
    normal-capacity)
      printf '%s\n' "entrypoint real-world-capacity product-breadth-capacity group-delivery-capacity"
      ;;
    workflow-regression)
      printf '%s\n' "entrypoint account-security-baseline sync-read-baseline direct-chat-baseline group-workflow-baseline contacts-social-baseline media-ai-admin-baseline reliability-recovery-baseline lifecycle-governance-baseline"
      ;;
    realtime-focused)
      printf '%s\n' "entrypoint message-spike realtime-direct realtime-direct-baseline group-delivery group-delivery-baseline"
      ;;
    *)
      printf 'product_test_plan result=fail reason=unknown_preset preset=%s\n' "$1" >&2
      return 2
      ;;
  esac
}

resolve_product_test_phases() {
  if [[ -n "${PRODUCT_TEST_PHASES//[[:space:]]/}" ]]; then
    return 0
  fi
  if [[ -n "${PRODUCT_TEST_PRESET}" ]]; then
    PRODUCT_TEST_PHASES="$(product_test_preset_phases "${PRODUCT_TEST_PRESET}")"
    return $?
  fi
  PRODUCT_TEST_PHASES="${DEFAULT_PRODUCT_TEST_PHASES}"
}

quote_command() {
  local first=true
  for arg in "$@"; do
    if [[ "${first}" == true ]]; then
      first=false
    else
      printf ' '
    fi
    printf '%q' "${arg}"
  done
  printf '\n'
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
      IM_INTERNAL_SECRET|IM_PASSWORD)
        if [[ "${arg}" == *=* && -n "${value}" ]]; then
          printf '%s=${%s:?set-%s}' "${name}" "${name}" "${name}"
        else
          printf '%q' "${arg}"
        fi
        ;;
      IM_INTERNAL_SHARED_SECRET)
        if [[ "${arg}" == *=* && -n "${value}" ]]; then
          printf '%s=${%s:-${IM_INTERNAL_SECRET:?set-IM_INTERNAL_SECRET}}' "${name}" "${name}"
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

phase_names() {
  cat <<'EOF'
entrypoint
daily-core
daily-traffic
real-world-smoke
real-world-baseline
real-world-capacity
sync-message
social-governance
realtime-direct
realtime-direct-baseline
account-security
account-security-baseline
sync-read
sync-read-baseline
direct-chat
direct-chat-baseline
group-workflow
group-workflow-baseline
group-delivery
group-delivery-baseline
group-delivery-capacity
im-scenario-breadth-smoke
im-scenario-breadth-baseline
im-scenario-breadth-capacity
contacts-social
contacts-social-baseline
media-ai-admin
media-ai-admin-baseline
message-spike
message-spike-baseline
reliability-recovery
reliability-recovery-baseline
lifecycle-governance
lifecycle-governance-baseline
product-smoke
product-baseline
product-breadth-smoke
product-breadth-baseline
product-breadth-capacity
normal-product-smoke
normal-product-baseline
normal-product-capacity
non-large-group-smoke
non-large-group-baseline
non-large-group-capacity
EOF
}

phase_groups() {
  case "$1" in
    daily-core)
      printf '%s\n' "daily-core-smoke daily-traffic-smoke"
      ;;
    daily-traffic)
      printf '%s\n' "daily-traffic-smoke"
      ;;
    real-world-smoke)
      printf '%s\n' "real-world-smoke"
      ;;
    real-world-baseline)
      printf '%s\n' "real-world-baseline"
      ;;
    real-world-capacity)
      printf '%s\n' "real-world-capacity"
      ;;
    sync-message)
      printf '%s\n' "sync-recovery message-workflow"
      ;;
    social-governance)
      printf '%s\n' "social-profile lifecycle-governance-smoke"
      ;;
    realtime-direct)
      printf '%s\n' "realtime-direct"
      ;;
    realtime-direct-baseline)
      printf '%s\n' "realtime-direct-baseline"
      ;;
    account-security)
      printf '%s\n' "account-security"
      ;;
    account-security-baseline)
      printf '%s\n' "account-security-baseline"
      ;;
    sync-read)
      printf '%s\n' "sync-read"
      ;;
    sync-read-baseline)
      printf '%s\n' "sync-read-baseline"
      ;;
    direct-chat)
      printf '%s\n' "direct-chat"
      ;;
    direct-chat-baseline)
      printf '%s\n' "direct-chat-baseline"
      ;;
    group-workflow)
      printf '%s\n' "group-workflow"
      ;;
    group-workflow-baseline)
      printf '%s\n' "group-workflow-baseline"
      ;;
    group-delivery)
      printf '%s\n' "group-delivery-smoke"
      ;;
    group-delivery-baseline)
      printf '%s\n' "group-delivery-baseline"
      ;;
    group-delivery-capacity)
      printf '%s\n' "group-delivery-capacity"
      ;;
    im-scenario-breadth-smoke)
      printf '%s\n' "im-scenario-breadth-smoke"
      ;;
    im-scenario-breadth-baseline)
      printf '%s\n' "im-scenario-breadth-baseline"
      ;;
    im-scenario-breadth-capacity)
      printf '%s\n' "im-scenario-breadth-capacity"
      ;;
    contacts-social)
      printf '%s\n' "contacts-social"
      ;;
    contacts-social-baseline)
      printf '%s\n' "contacts-social-baseline"
      ;;
    media-ai-admin)
      printf '%s\n' "media-ai-admin"
      ;;
    media-ai-admin-baseline)
      printf '%s\n' "media-ai-admin-baseline"
      ;;
    message-spike)
      printf '%s\n' "message-spike-smoke"
      ;;
    message-spike-baseline)
      printf '%s\n' "message-spike-baseline"
      ;;
    reliability-recovery)
      printf '%s\n' "reliability-recovery-smoke"
      ;;
    reliability-recovery-baseline)
      printf '%s\n' "reliability-recovery-baseline"
      ;;
    lifecycle-governance)
      printf '%s\n' "lifecycle-governance-smoke"
      ;;
    lifecycle-governance-baseline)
      printf '%s\n' "lifecycle-governance-baseline"
      ;;
    product-smoke)
      printf '%s\n' "product-smoke"
      ;;
    product-baseline)
      printf '%s\n' "product-baseline"
      ;;
    product-breadth-smoke)
      printf '%s\n' "product-breadth-smoke"
      ;;
    product-breadth-baseline)
      printf '%s\n' "product-breadth-baseline"
      ;;
    product-breadth-capacity)
      printf '%s\n' "product-breadth-capacity"
      ;;
    normal-product-smoke)
      printf '%s\n' "normal-product-smoke"
      ;;
    normal-product-baseline)
      printf '%s\n' "normal-product-baseline"
      ;;
    normal-product-capacity)
      printf '%s\n' "normal-product-capacity"
      ;;
    non-large-group-smoke)
      printf '%s\n' "non-large-group-smoke"
      ;;
    non-large-group-baseline)
      printf '%s\n' "non-large-group-baseline"
      ;;
    non-large-group-capacity)
      printf '%s\n' "non-large-group-capacity"
      ;;
    *)
      printf 'product_test_plan result=fail reason=unknown_phase phase=%s\n' "$1" >&2
      return 2
      ;;
  esac
}

list_phases() {
  local phase groups
  printf 'Default phases:\n  %s\n\n' "${DEFAULT_PRODUCT_TEST_PHASES}"
  printf 'Available presets:\n'
  while IFS= read -r preset; do
    printf '  %-30s %s\n' "${preset}" "$(product_test_preset_phases "${preset}")"
  done < <(product_test_preset_names)
  printf '\n'
  printf 'Available phases:\n'
  while IFS= read -r phase; do
    if [[ "${phase}" == "entrypoint" ]]; then
      printf '  %-30s %s\n' "${phase}" "http_entrypoint_probe.sh"
      continue
    fi
    groups="$(phase_groups "${phase}")"
    printf '  %-30s %s\n' "${phase}" "${groups}"
  done < <(phase_names)
}

usage() {
  cat <<EOF
Usage:
  run_product_test_plan.sh [--help|--list-phases|--validate-plan|--print-plan|--print-plan-json]

Common env:
  BASE_URL=https://chat.yourdomain.com
  TCP_HOST=tcp.yourdomain.com  # optional; derived from BASE_URL when empty
  TCP_PORT=9000
  ACCOUNT_FILE=/path/load-5000.csv
  IM_CONVERSATION_ID=<uuid>
  IM_INTERNAL_SECRET=<secret>
  Replace *.yourdomain.com before running; production gates reject literal placeholder domains.
  For local development only, override BASE_URL=http://127.0.0.1:8080 and TCP_HOST=127.0.0.1.
  PRODUCT_TEST_PRESET=normal-breadth
  PRODUCT_TEST_PHASES="${DEFAULT_PRODUCT_TEST_PHASES}"
  PRODUCT_TEST_RUN_FULL_PROFILE=true|false
  PRODUCT_TEST_FULL_PROFILE=normal-product-baseline
  PRODUCT_TEST_PACKAGE_EVIDENCE=true|false
  PRODUCT_TEST_PLAN_PREVIEW_JSON=results/product-test-plan-preview.json
  PRODUCT_TEST_REQUIRE_ENTRYPOINT=true|false
  PRODUCT_TEST_PREREQ_GATE=true|false
  PERF_DRY_RUN=true|false

Examples:
  PRODUCT_TEST_PRESET=normal-breadth ./run_product_test_plan.sh
  PRODUCT_TEST_PRESET=normal-acceptance ./run_product_test_plan.sh
  PRODUCT_TEST_PRESET=realtime-focused ./run_product_test_plan.sh --validate-plan
  PRODUCT_TEST_PRESET=normal-breadth ./run_product_test_plan.sh --print-plan
  PRODUCT_TEST_PRESET=normal-breadth ./run_product_test_plan.sh --print-plan-json
  PRODUCT_TEST_PHASES="entrypoint daily-core sync-read direct-chat" ./run_product_test_plan.sh
  ./run_product_test_plan.sh --list-phases
  PRODUCT_TEST_PHASES="entrypoint media-ai-admin" ./run_product_test_plan.sh --validate-plan
EOF
}

validate_product_phases() {
  local phase
  resolve_product_test_phases
  if bool_enabled "${PRODUCT_TEST_REQUIRE_ENTRYPOINT}" && ! bool_enabled "${PRODUCT_TEST_ENTRYPOINT_PROBE}"; then
    printf 'product_test_plan result=fail reason=entrypoint_required_but_probe_disabled\n' >&2
    return 2
  fi
  if [[ -z "${PRODUCT_TEST_PHASES//[[:space:]]/}" ]]; then
    printf 'product_test_plan result=fail reason=empty_phase_list\n' >&2
    return 2
  fi
  for phase in ${PRODUCT_TEST_PHASES}; do
    if [[ "${phase}" == "entrypoint" ]]; then
      continue
    fi
    if ! phase_groups "${phase}" >/dev/null 2>&1; then
      printf 'product_test_plan result=fail reason=invalid_phase_list phase=%s\n' "${phase}" >&2
      return 2
    fi
  done
}

print_product_plan() {
  local phase groups expanded selected_file unique_count scenario_count first_scenario sample
  normalize_product_phases
  validate_product_phases
  selected_file="$(mktemp)"

  printf 'product_test_plan result=pass mode=print preset=%q phases=%q fullProfile=%q runFullProfile=%q dryRun=%q\n' \
    "${PRODUCT_TEST_PRESET}" \
    "${PRODUCT_TEST_PHASES}" \
    "${PRODUCT_TEST_FULL_PROFILE}" \
    "${PRODUCT_TEST_RUN_FULL_PROFILE}" \
    "${PERF_DRY_RUN}"
  printf 'target baseURL=%q tcpHost=%q tcpPort=%q accountFile=%q conversationID=%q\n' \
    "${BASE_URL}" \
    "${TCP_HOST}" \
    "${TCP_PORT}" \
    "${ACCOUNT_FILE}" \
    "${IM_CONVERSATION_ID}"

  for phase in ${PRODUCT_TEST_PHASES}; do
    if [[ "${phase}" == "entrypoint" ]]; then
      printf 'phase=%q kind=entrypoint groups=%q scenarioCount=0 runner=%q\n' \
        "${phase}" \
        "" \
        "http_entrypoint_probe.sh"
      continue
    fi

    groups="$(phase_groups "${phase}")"
    expanded="$(
      SCENARIO_GROUPS="${groups}" \
        "${SCRIPT_DIR}/run_perf_scenarios.sh" --expand-groups
    )"
    scenario_count="$(wc -w <<<"${expanded}" | tr -d ' ')"
    first_scenario="$(awk '{print $1}' <<<"${expanded}")"
    sample="$(awk '{for (i=1; i<=NF && i<=8; i++) printf "%s%s", (i == 1 ? "" : ","), $i}' <<<"${expanded}")"
    if [[ -n "${expanded}" ]]; then
      printf '%s\n' ${expanded} >>"${selected_file}"
    fi
    printf 'phase=%q kind=scenario-groups groups=%q scenarioCount=%s firstScenario=%q sample=%q\n' \
      "${phase}" \
      "${groups}" \
      "${scenario_count}" \
      "${first_scenario}" \
      "${sample}"
  done

  unique_count="$(
    python3 - "${selected_file}" <<'PY'
import sys
from pathlib import Path

seen = set()
ordered = []
for raw in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    item = raw.strip()
    if item and item not in seen:
        seen.add(item)
        ordered.append(item)
print(len(ordered))
PY
  )"
  printf 'summary uniqueScenarioCount=%s\n' "${unique_count}"
  rm -f "${selected_file}"
}

print_product_plan_json() {
  local preview_file
  preview_file="$(mktemp)"
  write_product_plan_preview_json "${preview_file}"
  cat "${preview_file}"
  rm -f "${preview_file}"
}

write_product_plan_preview_json() {
  local output_json="$1"
  local phase groups expanded rows_file
  normalize_product_phases
  validate_product_phases
  rows_file="$(mktemp)"

  for phase in ${PRODUCT_TEST_PHASES}; do
    if [[ "${phase}" == "entrypoint" ]]; then
      printf '%s\t%s\t%s\t%s\n' "${phase}" "entrypoint" "" "" >>"${rows_file}"
      continue
    fi

    groups="$(phase_groups "${phase}")"
    expanded="$(
      SCENARIO_GROUPS="${groups}" \
        "${SCRIPT_DIR}/run_perf_scenarios.sh" --expand-groups
    )"
    printf '%s\t%s\t%s\t%s\n' "${phase}" "scenario-groups" "${groups}" "${expanded}" >>"${rows_file}"
  done

  python3 - \
    "${rows_file}" \
    "${PRODUCT_TEST_PLAN}" \
    "${PRODUCT_TEST_PRESET}" \
    "${PRODUCT_TEST_PHASES}" \
    "${PRODUCT_TEST_FULL_PROFILE}" \
    "${PRODUCT_TEST_RUN_FULL_PROFILE}" \
    "${PRODUCT_TEST_PACKAGE_EVIDENCE}" \
    "${PRODUCT_TEST_REQUIRE_ENTRYPOINT}" \
    "${PRODUCT_TEST_PREREQ_GATE}" \
    "${PERF_DRY_RUN}" \
    "${PERF_STATUS_FILTER_TARGET}" \
    "${BASE_URL}" \
    "${TCP_HOST}" \
    "${TCP_PORT}" \
    "${ACCOUNT_FILE}" \
    "${IM_CONVERSATION_ID}" \
    "${output_json}" <<'PY'
import json
import sys
import time
from pathlib import Path

(
    rows_file,
    plan,
    preset,
    phases,
    full_profile,
    run_full_profile,
    package_evidence,
    require_entrypoint,
    prereq_gate,
    dry_run,
    status_filter_target,
    base_url,
    tcp_host,
    tcp_port,
    account_file,
    conversation_id,
    output_json,
) = sys.argv[1:18]

def as_bool(value: str) -> bool:
    return value.lower() in {"1", "true", "yes", "on"}

phase_rows = []
selected_scenarios = []
seen = set()
large_group_included = False
required_product_domains = [
    "account-security",
    "sync-read",
    "direct-chat",
    "group-workflow",
    "contacts-social",
    "media-ai-admin",
    "reliability-recovery",
    "realtime-direct",
]

domain_rules = {
    "account-security": (
        "login-",
        "auth-session",
        "auth-token",
        "auth-failure",
        "push-token",
        "account-lifecycle",
    ),
    "sync-read": (
        "client-sync",
        "user-journey",
        "offline-catchup",
        "inbox-fanout",
        "multi-device-sync",
        "client-health",
        "cold-start",
        "timeline-",
        "domain-events",
        "read-state",
    ),
    "direct-chat": (
        "direct-",
        "read-state",
        "conversation-preferences",
        "conversation-visibility",
        "message-forward",
        "hot-write",
        "pair-delivery",
    ),
    "group-workflow": (
        "small-group",
        "conversation-convergence",
        "group-",
        "governance",
        "access-control",
    ),
    "contacts-social": (
        "contact-",
        "profile-",
        "safety-block",
    ),
    "media-ai-admin": (
        "media-",
        "ai-stream",
        "admin-report",
        "search-",
    ),
    "reliability-recovery": (
        "offline-catchup",
        "reconnect-",
        "cold-start",
        "auth-failure",
        "media-failure",
        "client-health",
    ),
    "realtime-direct": (
        "online-idle",
        "reconnect-",
        "multi-device-online",
        "multi-device-delivery",
        "pair-delivery",
        "online-chat-mix",
        "direct-burst",
    ),
}


def product_domains_for_scenario(scenario: str) -> set[str]:
    domains = set()
    for domain, prefixes in domain_rules.items():
        if any(scenario.startswith(prefix) for prefix in prefixes):
            domains.add(domain)
    return domains

for raw in Path(rows_file).read_text(encoding="utf-8").splitlines():
    phase, kind, groups_raw, scenarios_raw = raw.split("\t", 3)
    groups = [item for item in groups_raw.split() if item]
    scenarios = [item for item in scenarios_raw.split() if item]
    for scenario in scenarios:
        if scenario not in seen:
            seen.add(scenario)
            selected_scenarios.append(scenario)
        if scenario.startswith("large-group-") or scenario == "large-group":
            large_group_included = True
    if "large-group" in groups:
        large_group_included = True
    phase_rows.append({
        "phase": phase,
        "kind": kind,
        "groups": groups,
        "runner": "http_entrypoint_probe.sh" if kind == "entrypoint" else "run_perf_scenarios.sh",
        "scenarioCount": len(scenarios),
        "firstScenario": scenarios[0] if scenarios else "",
        "sampleScenarios": scenarios[:8],
        "scenarios": scenarios,
    })

covered_product_domains = sorted({
    domain
    for scenario in selected_scenarios
    for domain in product_domains_for_scenario(scenario)
})
missing_product_domains = [
    domain for domain in required_product_domains
    if domain not in covered_product_domains
]

payload = {
    "schemaVersion": 1,
    "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "plan": plan,
    "preset": preset,
    "requestedPhases": [item for item in phases.split() if item],
    "fullProfile": full_profile,
    "runFullProfile": as_bool(run_full_profile),
    "packageEvidence": as_bool(package_evidence),
    "requireEntrypoint": as_bool(require_entrypoint),
    "prereqGate": as_bool(prereq_gate),
    "dryRun": as_bool(dry_run),
    "statusFilterTarget": as_bool(status_filter_target),
    "target": {
        "baseURL": base_url,
        "tcpHost": tcp_host,
        "tcpPort": tcp_port,
        "accountFile": account_file,
        "conversationID": conversation_id,
    },
    "summary": {
        "phaseCount": len(phase_rows),
        "scenarioPhaseCount": sum(1 for row in phase_rows if row["kind"] == "scenario-groups"),
        "uniqueScenarioCount": len(selected_scenarios),
        "largeGroupIncluded": large_group_included,
        "coveredProductDomains": covered_product_domains,
        "requiredProductDomains": required_product_domains,
        "missingProductDomains": missing_product_domains,
        "requiredProductDomainsCovered": not missing_product_domains,
    },
    "selectedScenarios": selected_scenarios,
    "phases": phase_rows,
}
output_path = Path(output_json)
output_path.parent.mkdir(parents=True, exist_ok=True)
output_path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
  rm -f "${rows_file}"
}

normalize_product_phases() {
  local phase
  local phases=()
  resolve_product_test_phases
  if ! bool_enabled "${PRODUCT_TEST_REQUIRE_ENTRYPOINT}"; then
    return 0
  fi
  for phase in ${PRODUCT_TEST_PHASES}; do
    if [[ "${phase}" == "entrypoint" ]]; then
      continue
    fi
    phases+=("${phase}")
  done
  PRODUCT_TEST_PHASES="entrypoint"
  if ((${#phases[@]} > 0)); then
    PRODUCT_TEST_PHASES="${PRODUCT_TEST_PHASES} ${phases[*]}"
  fi
}

build_product_prereq_plan() {
  local phase groups expanded
  local selected_file
  selected_file="$(mktemp)"
  for phase in ${PRODUCT_TEST_PHASES}; do
    if [[ "${phase}" == "entrypoint" ]]; then
      continue
    fi
    groups="$(phase_groups "${phase}")"
    expanded="$(
      SCENARIO_GROUPS="${groups}" \
        "${SCRIPT_DIR}/run_perf_scenarios.sh" --expand-groups
    )"
    if [[ -n "${expanded}" ]]; then
      printf '%s\n' ${expanded} >>"${selected_file}"
    fi
  done
  python3 - "${selected_file}" "${PRODUCT_TEST_PREREQ_PLAN_JSON}" "${PRODUCT_TEST_PLAN}" "${PRODUCT_TEST_PRESET}" "${PRODUCT_TEST_PHASES}" <<'PY'
import json
import sys
import time
from pathlib import Path

selected_file, output_json, plan, preset, phases = sys.argv[1:6]
seen = set()
selected = []
for raw in Path(selected_file).read_text(encoding="utf-8").splitlines():
    scenario = raw.strip()
    if scenario and scenario not in seen:
        seen.add(scenario)
        selected.append(scenario)
payload = {
    "schemaVersion": 1,
    "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "status": "READY" if selected else "NO_SCENARIOS",
    "plan": plan,
    "preset": preset,
    "requestedPhases": [item for item in phases.split() if item],
    "selectedScenarios": selected,
}
Path(output_json).parent.mkdir(parents=True, exist_ok=True)
Path(output_json).write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
  rm -f "${selected_file}"
}

run_product_prereq_gate() {
  if ! bool_enabled "${PRODUCT_TEST_PREREQ_GATE}"; then
    printf 'product_test_plan prereq=skipped reason=disabled\n'
    return 0
  fi
  build_product_prereq_plan
  python3 "${SCRIPT_DIR}/perf_scenario_catalog.py" \
    --script "${SCRIPT_DIR}/run_perf_scenarios.sh" \
    --json-output "${PRODUCT_TEST_SCENARIO_CATALOG_JSON}" >/dev/null
  python3 "${SCRIPT_DIR}/perf_prereq_audit.py" \
    --scenario-catalog "${PRODUCT_TEST_SCENARIO_CATALOG_JSON}" \
    --domain-run-plan "${PRODUCT_TEST_PREREQ_PLAN_JSON}" \
    --base-url "${BASE_URL}" \
    --tcp-host "${TCP_HOST}" \
    --tcp-port "${TCP_PORT}" \
    --account-file "${ACCOUNT_FILE}" \
    --conversation-id "${IM_CONVERSATION_ID}" \
    --internal-secret "${IM_INTERNAL_SECRET}" \
    --auth-email-webhook-url "${IM_AUTH_EMAIL_WEBHOOK_SINK_URL:-}" \
    --verification-code "${IM_ACCOUNT_VERIFICATION_CODE:-}" \
    --password-reset-code "${IM_ACCOUNT_PASSWORD_RESET_CODE:-}" \
    --output "${PRODUCT_TEST_PREREQ_AUDIT_MD}" \
    --json-output "${PRODUCT_TEST_PREREQ_AUDIT_JSON}" \
    --strict || return 1
  python3 - "${PRODUCT_TEST_PREREQ_AUDIT_JSON}" <<'PY'
import json
import sys
from pathlib import Path

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
summary = payload.get("summary") or {}
if summary.get("overallStatus") == "BLOCKED":
    raise SystemExit(
        "product_test_plan prereq=fail "
        f"reason=blocked missingRequired={summary.get('missingRequiredCount')}"
    )
PY
  printf 'product_test_plan prereq=pass audit=%s\n' "${PRODUCT_TEST_PREREQ_AUDIT_JSON}"
}

append_status() {
  local phase="$1"
  local kind="$2"
  local run_id="$3"
  local status="$4"
  local reason="$5"
  local command="$6"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${phase}" \
    "${kind}" \
    "${run_id}" \
    "${status}" \
    "${reason}" \
    "${command}" >>"${PRODUCT_TEST_STATUS_TSV}"
}

run_operator_network_preflight() {
  local run_id command log_file
  run_id="${PRODUCT_TEST_RUN_ID_PREFIX}-operator-network"
  log_file="${RESULT_ROOT}/${run_id}/operator-network.log"
  command="$(
    quote_command env \
      "${PRODUCT_TEST_OPERATOR_NETWORK_PREFLIGHT_SCRIPT}" \
      "${BASE_URL}" \
      "${TCP_HOST}:${TCP_PORT}"
  )"

  if ! bool_enabled "${PRODUCT_TEST_OPERATOR_NETWORK_PREFLIGHT}"; then
    append_status "operator-network" "operator-network" "${run_id}" "SKIPPED" "disabled" "${command}"
    return 0
  fi
  if bool_enabled "${PERF_DRY_RUN}"; then
    mkdir -p "${RESULT_ROOT}/${run_id}"
    append_status "operator-network" "operator-network" "${run_id}" "DRY_RUN" "" "${command}"
    return 0
  fi
  if [[ ! -f "${PRODUCT_TEST_OPERATOR_NETWORK_PREFLIGHT_SCRIPT}" ]]; then
    append_status "operator-network" "operator-network" "${run_id}" "SKIPPED" "script_missing" "${command}"
    return 0
  fi

  mkdir -p "${RESULT_ROOT}/${run_id}"
  set +e
  bash "${PRODUCT_TEST_OPERATOR_NETWORK_PREFLIGHT_SCRIPT}" \
    "${BASE_URL}" \
    "${TCP_HOST}:${TCP_PORT}" \
    >"${log_file}" 2>&1
  local rc=$?
  set -e
  if [[ "${rc}" -ne 0 ]]; then
    if bool_enabled "${PRODUCT_TEST_FAIL_ON_OPERATOR_NETWORK}"; then
      append_status "operator-network" "operator-network" "${run_id}" "FAIL" "operator_network_failed" "${command}"
      return 1
    fi
    append_status "operator-network" "operator-network" "${run_id}" "WARN" "operator_network_failed" "${command}"
    return 0
  fi
  append_status "operator-network" "operator-network" "${run_id}" "PASS" "" "${command}"
}

write_plan_json() {
  local final_status="$1"
  local reason="${2:-}"
  python3 - \
    "${PRODUCT_TEST_STATUS_TSV}" \
    "${PRODUCT_TEST_PLAN_JSON}" \
    "${PRODUCT_TEST_PLAN}" \
    "${PRODUCT_TEST_PHASES}" \
    "${PRODUCT_TEST_PRESET}" \
    "${PRODUCT_TEST_RUN_FULL_PROFILE}" \
    "${PRODUCT_TEST_FULL_PROFILE}" \
    "${PRODUCT_TEST_RUN_ID_PREFIX}" \
    "${final_status}" \
    "${reason}" \
    "${PERF_DRY_RUN}" \
    "${PERF_STATUS_FILTER_TARGET}" \
    "${RESULT_ROOT}" \
    "${BASE_URL}" \
    "${TCP_HOST}" \
    "${TCP_PORT}" \
    "${ACCOUNT_FILE}" \
    "${IM_CONVERSATION_ID}" \
    "${PRODUCT_TEST_PREREQ_GATE}" \
    "${PRODUCT_TEST_PREREQ_PLAN_JSON}" \
    "${PRODUCT_TEST_PREREQ_AUDIT_JSON}" \
    "${PRODUCT_TEST_PREREQ_AUDIT_MD}" \
    "${PRODUCT_TEST_RUNBOOK_JSON}" \
    "${PRODUCT_TEST_RUNBOOK_MD}" \
    "${PRODUCT_TEST_REQUIRE_ENTRYPOINT}" \
    "${PRODUCT_TEST_PLAN_PREVIEW_JSON}" \
    "${PRODUCT_TEST_ENTRYPOINT_RESCUE_JSON}" <<'PY'
import json
import sys
import time
from pathlib import Path

(
    status_tsv,
    output_json,
    plan,
    phases,
    preset,
    run_full_profile,
    full_profile,
    run_id_prefix,
    final_status,
    reason,
    dry_run,
    status_filter_target,
    result_root,
    base_url,
    tcp_host,
    tcp_port,
    account_file,
    conversation_id,
    prereq_gate,
    prereq_plan_json,
    prereq_audit_json,
    prereq_audit_md,
    runbook_json,
    runbook_md,
    require_entrypoint,
    plan_preview_json,
    entrypoint_rescue_json,
) = sys.argv[1:28]

records = []
path = Path(status_tsv)
if path.exists():
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            phase, kind, run_id, status, item_reason, command = line.rstrip("\n").split("\t", 5)
            records.append({
                "phase": phase,
                "kind": kind,
                "runID": run_id,
                "status": status,
                "reason": item_reason,
                "command": command,
                "runDir": str(Path(result_root) / run_id) if run_id else "",
            })

def read_json(path: str) -> dict:
    file_path = Path(path)
    if not file_path.exists():
        return {}
    try:
        with file_path.open(encoding="utf-8") as handle:
            return json.load(handle)
    except Exception:
        return {}

def derive_blocker_type() -> str:
    if final_status != "FAIL":
        return ""
    if reason == "operator_network_failed":
        return "operator-network"
    if reason == "public_target_invalid":
        return "target"
    if reason == "prereq_gate_failed":
        return "prerequisites"
    if reason == "entrypoint_failed":
        return "entrypoint"
    if reason == "package_failed":
        return "evidence-package"
    if reason == "full_profile_failed":
        return "production-profile"
    failed_records = [row for row in records if row.get("status") == "FAIL"]
    if failed_records:
        first = failed_records[0]
        if first.get("kind") == "operator-network" or first.get("reason") == "operator_network_failed":
            return "operator-network"
        if first.get("kind") == "entrypoint-probe" or first.get("reason") == "entrypoint_probe_failed":
            return "entrypoint"
        if first.get("kind") == "scenario-groups":
            run_dir = Path(str(first.get("runDir") or ""))
            evidence = read_json(str(run_dir / "evidence.json"))
            outcome = str(evidence.get("outcome") or "")
            if outcome == "BLOCKED_PREREQUISITES":
                return "prerequisites"
            if outcome == "BLOCKED_ENTRYPOINT":
                return "entrypoint"
            return "scenario-groups"
    return "unknown"

payload = {
    "schemaVersion": 1,
    "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "plan": plan,
    "requestedPhases": [item for item in phases.split() if item],
    "preset": preset,
    "runFullProfile": run_full_profile.lower() in {"1", "true", "yes", "on"},
    "fullProfile": full_profile,
    "runIDPrefix": run_id_prefix,
    "finalStatus": final_status,
    "reason": reason,
    "blockerType": derive_blocker_type(),
    "dryRun": dry_run.lower() in {"1", "true", "yes", "on"},
    "statusFilterTarget": status_filter_target.lower() in {"1", "true", "yes", "on"},
    "target": {
        "baseURL": base_url,
        "tcpHost": tcp_host,
        "tcpPort": tcp_port,
        "accountFile": account_file,
        "conversationID": conversation_id,
    },
    "prereq": {
        "enabled": prereq_gate.lower() in {"1", "true", "yes", "on"},
        "ran": Path(prereq_plan_json).exists() or Path(prereq_audit_json).exists(),
        "plan": prereq_plan_json,
        "auditJSON": prereq_audit_json,
        "auditMarkdown": prereq_audit_md,
    },
    "planPreview": {
        "json": plan_preview_json,
        "exists": Path(plan_preview_json).exists(),
    },
    "entrypoint": {
        "required": require_entrypoint.lower() in {"1", "true", "yes", "on"},
        "rescueArtifact": read_json(entrypoint_rescue_json),
    },
    "runbook": {
        "json": runbook_json,
        "markdown": runbook_md,
    },
    "phases": records,
}
Path(output_json).parent.mkdir(parents=True, exist_ok=True)
Path(output_json).write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
}

write_product_runbook() {
  python3 "${SCRIPT_DIR}/perf_product_test_plan_runbook.py" \
    --product-run-json "${PRODUCT_TEST_PLAN_JSON}" \
    --prereq-audit-json "${PRODUCT_TEST_PREREQ_AUDIT_JSON}" \
    --result-root "${RESULT_ROOT}" \
    --output "${PRODUCT_TEST_RUNBOOK_MD}" \
    --json-output "${PRODUCT_TEST_RUNBOOK_JSON}" >/dev/null
}

write_entrypoint_rescue_status() {
  local status="$1"
  local reason="${2:-}"
  local log_file="${3:-}"
  python3 - \
    "${PRODUCT_TEST_ENTRYPOINT_RESCUE_JSON}" \
    "${status}" \
    "${reason}" \
    "${PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT_DIR}" \
    "${log_file}" \
    "${PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT}" \
    "${PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT_PACKAGE}" \
    "${PERF_DRY_RUN}" <<'PY'
import json
import sys
import time
from pathlib import Path

(
    output_json,
    status,
    reason,
    artifact_dir,
    log_file,
    enabled,
    package_enabled,
    dry_run,
) = sys.argv[1:9]

artifact_path = Path(artifact_dir)
tarball = Path(f"{artifact_dir}.tar.gz")
payload = {
    "schemaVersion": 1,
    "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "status": status,
    "reason": reason,
    "enabled": enabled.lower() in {"1", "true", "yes", "on"},
    "packageEnabled": package_enabled.lower() in {"1", "true", "yes", "on"},
    "dryRun": dry_run.lower() in {"1", "true", "yes", "on"},
    "artifactDir": artifact_dir,
    "artifactDirExists": artifact_path.is_dir(),
    "tarball": str(tarball),
    "tarballExists": tarball.is_file(),
    "logFile": log_file,
    "logFileExists": Path(log_file).is_file() if log_file else False,
}
Path(output_json).parent.mkdir(parents=True, exist_ok=True)
Path(output_json).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

entrypoint_probe_blocker_action() {
  local probe_json="$1"
  python3 - "${probe_json}" <<'PY'
import json
import sys
from pathlib import Path

try:
    payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
except Exception:
    print("")
else:
    print(str((payload.get("blocker") or {}).get("action") or ""))
PY
}

generate_entrypoint_rescue_artifact() {
  local probe_json="${1:-}"
  local log_file blocker_action
  blocker_action="$(entrypoint_probe_blocker_action "${probe_json}")"
  if [[ "${blocker_action}" != "cloud_console_rescue_required" ]]; then
    write_entrypoint_rescue_status "SKIPPED" "probe_action_not_cloud_console:${blocker_action:-none}"
    printf 'product_test_plan entrypoint_rescue_artifact=skipped reason=probe_action_not_cloud_console action=%s\n' \
      "${blocker_action:-<none>}"
    return 0
  fi
  if ! bool_enabled "${PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT}"; then
    write_entrypoint_rescue_status "SKIPPED" "disabled"
    return 0
  fi
  if bool_enabled "${PERF_DRY_RUN}"; then
    write_entrypoint_rescue_status "SKIPPED" "dry_run"
    printf 'product_test_plan entrypoint_rescue_artifact=skipped reason=dry_run\n'
    return 0
  fi
  if [[ -z "${SSH_PRIVATE_KEY_PATH:-}" && -z "${SSH_AUTHORIZED_KEY:-}" ]]; then
    write_entrypoint_rescue_status "SKIPPED" "missing_ssh_key_source"
    printf 'product_test_plan entrypoint_rescue_artifact=skipped reason=missing_ssh_key_source\n'
    return 0
  fi
  if [[ ! -x "${SCRIPT_DIR}/generate_node_access_rescue_artifact.sh" ]]; then
    write_entrypoint_rescue_status "SKIPPED" "generator_missing"
    printf 'product_test_plan entrypoint_rescue_artifact=skipped reason=generator_missing\n'
    return 0
  fi
  log_file="${RESULT_ROOT}/entrypoint-rescue-artifact.log"
  printf 'product_test_plan entrypoint_rescue_artifact=start dir=%s log=%s\n' \
    "${PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT_DIR}" \
    "${log_file}"
  if PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT=false \
    NODE_ACCESS_RESCUE_ARTIFACT_DIR="${PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT_DIR}" \
    NODE_ACCESS_RESCUE_ARTIFACT_PACKAGE="${PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT_PACKAGE}" \
    PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-${BASE_URL}}" \
    BASE_URL="${BASE_URL}" \
    TCP_HOST="${TCP_HOST}" \
    TCP_PORT="${TCP_PORT}" \
    IM_TCP_PORT="${TCP_PORT}" \
    ACCOUNT_FILE="${ACCOUNT_FILE}" \
    PRODUCT_TEST_PHASES="${PRODUCT_TEST_PHASES}" \
    PRODUCT_TEST_STOP_ON_FAILURE=true \
    PRODUCT_TEST_RUN_FULL_PROFILE=false \
    PERF_DRY_RUN=false \
      bash "${SCRIPT_DIR}/generate_node_access_rescue_artifact.sh" >"${log_file}" 2>&1; then
    write_entrypoint_rescue_status "PASS" "" "${log_file}"
    printf 'product_test_plan entrypoint_rescue_artifact=pass dir=%s\n' \
      "${PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT_DIR}"
    return 0
  fi
  write_entrypoint_rescue_status "FAIL" "generator_failed" "${log_file}"
  printf 'product_test_plan entrypoint_rescue_artifact=fail log=%s\n' "${log_file}" >&2
  return 0
}

run_entrypoint_phase() {
  local command run_id
  run_id="${PRODUCT_TEST_RUN_ID_PREFIX}-entrypoint"
  command="$(
    quote_command env \
      "BASE_URL=${BASE_URL}" \
      "ACCOUNT_FILE=${ACCOUNT_FILE}" \
      "PROBE_FAIL_ON_ENTRYPOINT_ERROR=true" \
      "PROBE_FAIL_ON_LOCAL_NETWORK=${PRODUCT_TEST_FAIL_ON_LOCAL_NETWORK}" \
      "PROBE_JSON_OUTPUT=${RESULT_ROOT}/${run_id}/entrypoint-probe.json" \
      "${SCRIPT_DIR}/http_entrypoint_probe.sh"
  )"
  printf '\n== product phase: entrypoint ==\n'
  printf '%s\n' "${command}"

  if ! bool_enabled "${PRODUCT_TEST_ENTRYPOINT_PROBE}"; then
    append_status "entrypoint" "entrypoint-probe" "${run_id}" "SKIPPED" "disabled" "${command}"
    return 0
  fi
  if bool_enabled "${PERF_DRY_RUN}"; then
    mkdir -p "${RESULT_ROOT}/${run_id}"
    append_status "entrypoint" "entrypoint-probe" "${run_id}" "DRY_RUN" "" "${command}"
    return 0
  fi

  mkdir -p "${RESULT_ROOT}/${run_id}"
  if BASE_URL="${BASE_URL}" \
    ACCOUNT_FILE="${ACCOUNT_FILE}" \
    PROBE_FAIL_ON_ENTRYPOINT_ERROR=true \
    PROBE_FAIL_ON_LOCAL_NETWORK="${PRODUCT_TEST_FAIL_ON_LOCAL_NETWORK}" \
    PROBE_JSON_OUTPUT="${RESULT_ROOT}/${run_id}/entrypoint-probe.json" \
      "${SCRIPT_DIR}/http_entrypoint_probe.sh" >"${RESULT_ROOT}/${run_id}/entrypoint-probe.log" 2>&1; then
    append_status "entrypoint" "entrypoint-probe" "${run_id}" "PASS" "" "${command}"
    return 0
  fi
  append_status "entrypoint" "entrypoint-probe" "${run_id}" "FAIL" "entrypoint_probe_failed" "${command}"
  generate_entrypoint_rescue_artifact "${RESULT_ROOT}/${run_id}/entrypoint-probe.json"
  return 1
}

run_scenario_phase() {
  local phase="$1"
  local groups run_id command
  groups="$(phase_groups "${phase}")"
  run_id="${PRODUCT_TEST_RUN_ID_PREFIX}-${phase}"
  command="$(
    quote_command_redacted env \
      "RUN_ID=${run_id}" \
      "RESULT_ROOT=${RESULT_ROOT}" \
      "BASE_URL=${BASE_URL}" \
      "TCP_HOST=${TCP_HOST}" \
      "TCP_PORT=${TCP_PORT}" \
      "ACCOUNT_FILE=${ACCOUNT_FILE}" \
      "IM_CONVERSATION_ID=${IM_CONVERSATION_ID}" \
      "IM_INTERNAL_SECRET=${IM_INTERNAL_SECRET}" \
      "SCENARIO_GROUPS=${groups}" \
      "STOP_ON_FAILURE=false" \
      "PERF_STATUS_FILTER_TARGET=${PERF_STATUS_FILTER_TARGET}" \
      "PERF_DRY_RUN=${PERF_DRY_RUN}" \
      "${SCRIPT_DIR}/run_perf_scenarios.sh"
  )"
  printf '\n== product phase: %s ==\n' "${phase}"
  printf '%s\n' "${command}"

  if RUN_ID="${run_id}" \
    RESULT_ROOT="${RESULT_ROOT}" \
    BASE_URL="${BASE_URL}" \
    TCP_HOST="${TCP_HOST}" \
    TCP_PORT="${TCP_PORT}" \
    ACCOUNT_FILE="${ACCOUNT_FILE}" \
    IM_CONVERSATION_ID="${IM_CONVERSATION_ID}" \
    IM_INTERNAL_SECRET="${IM_INTERNAL_SECRET}" \
    SCENARIO_GROUPS="${groups}" \
    STOP_ON_FAILURE=false \
    PERF_STATUS_FILTER_TARGET="${PERF_STATUS_FILTER_TARGET}" \
    PERF_DRY_RUN="${PERF_DRY_RUN}" \
      "${SCRIPT_DIR}/run_perf_scenarios.sh"; then
    append_status "${phase}" "scenario-groups" "${run_id}" "PASS" "" "${command}"
    return 0
  fi
  append_status "${phase}" "scenario-groups" "${run_id}" "FAIL" "run_perf_scenarios_failed" "${command}"
  return 1
}

run_full_profile_phase() {
  local run_id command
  run_id="${PRODUCT_TEST_RUN_ID_PREFIX}-profile-${PRODUCT_TEST_FULL_PROFILE}"
  command="$(
    quote_command_redacted env \
      "RESULT_ROOT=${RESULT_ROOT}" \
      "BASE_URL=${BASE_URL}" \
      "TCP_HOST=${TCP_HOST}" \
      "TCP_PORT=${TCP_PORT}" \
      "ACCOUNT_FILE=${ACCOUNT_FILE}" \
      "IM_CONVERSATION_ID=${IM_CONVERSATION_ID}" \
      "IM_INTERNAL_SECRET=${IM_INTERNAL_SECRET}" \
      "PERF_PRODUCTION_GATE_PROFILE=${PRODUCT_TEST_FULL_PROFILE}" \
      "PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET=${PRODUCT_TEST_REQUIRE_PUBLIC_TARGET_EFFECTIVE}" \
      "PRODUCTION_PROFILE_RUN_ID_PREFIX=${run_id}" \
      "PRODUCTION_PROFILE_PACKAGE=false" \
      "PRODUCTION_PROFILE_REQUIRE_PRODUCT_PLAN_ARTIFACTS=false" \
      "PERF_STATUS_FILTER_TARGET=${PERF_STATUS_FILTER_TARGET}" \
      "PERF_DRY_RUN=${PERF_DRY_RUN}" \
      "${SCRIPT_DIR}/run_production_profile.sh"
  )"
  printf '\n== product phase: full-profile (%s) ==\n' "${PRODUCT_TEST_FULL_PROFILE}"
  printf '%s\n' "${command}"

  if ! bool_enabled "${PRODUCT_TEST_RUN_FULL_PROFILE}"; then
    append_status "full-profile" "production-profile" "${run_id}" "SKIPPED" "disabled" "${command}"
    return 0
  fi

  if RESULT_ROOT="${RESULT_ROOT}" \
    BASE_URL="${BASE_URL}" \
    TCP_HOST="${TCP_HOST}" \
    TCP_PORT="${TCP_PORT}" \
    ACCOUNT_FILE="${ACCOUNT_FILE}" \
    IM_CONVERSATION_ID="${IM_CONVERSATION_ID}" \
    IM_INTERNAL_SECRET="${IM_INTERNAL_SECRET}" \
    PERF_PRODUCTION_GATE_PROFILE="${PRODUCT_TEST_FULL_PROFILE}" \
    PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET="${PRODUCT_TEST_REQUIRE_PUBLIC_TARGET_EFFECTIVE}" \
    PRODUCTION_PROFILE_RUN_ID_PREFIX="${run_id}" \
    PRODUCTION_PROFILE_PACKAGE=false \
    PRODUCTION_PROFILE_REQUIRE_PRODUCT_PLAN_ARTIFACTS=false \
    PERF_STATUS_FILTER_TARGET="${PERF_STATUS_FILTER_TARGET}" \
    PERF_DRY_RUN="${PERF_DRY_RUN}" \
      "${SCRIPT_DIR}/run_production_profile.sh"; then
    append_status "full-profile" "production-profile" "${run_id}" "PASS" "" "${command}"
    return 0
  fi
  append_status "full-profile" "production-profile" "${run_id}" "FAIL" "run_production_profile_failed" "${command}"
  return 1
}

package_product_evidence() {
  if ! bool_enabled "${PRODUCT_TEST_RUN_FULL_PROFILE}"; then
    printf 'product_test_plan package=skipped reason=full_profile_disabled\n'
    return 0
  fi
  if ! bool_enabled "${PRODUCT_TEST_PACKAGE_EVIDENCE}"; then
    printf 'product_test_plan package=skipped reason=disabled\n'
    return 0
  fi
  if bool_enabled "${PERF_DRY_RUN}"; then
    printf 'product_test_plan package=skipped reason=dry_run\n'
    return 0
  fi

  PERF_PRODUCTION_GATE_JSON="${RESULT_ROOT}/production-gate.json" \
  PERF_PRODUCTION_GATE_PROFILE="${PRODUCT_TEST_FULL_PROFILE}" \
  PERF_PRODUCTION_GATE_MAX_AGE_SECONDS="${PERF_PRODUCTION_GATE_MAX_AGE_SECONDS:-604800}" \
  PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET="${PRODUCT_TEST_REQUIRE_PUBLIC_TARGET_EFFECTIVE}" \
  PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS="${PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS:-false}" \
  PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS="${PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS:-false}" \
  PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS="${PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS:-false}" \
    "${SCRIPT_DIR}/package_production_evidence.sh"
}

run_plan() {
  local phase first_phase rc=0 reason="" entrypoint_ran=false
  normalize_product_phases
  validate_product_phases
  mkdir -p "${RESULT_ROOT}"
  : >"${PRODUCT_TEST_STATUS_TSV}"
  rm -f \
    "${PRODUCT_TEST_PREREQ_PLAN_JSON}" \
    "${PRODUCT_TEST_PREREQ_AUDIT_JSON}" \
    "${PRODUCT_TEST_PREREQ_AUDIT_MD}" \
    "${PRODUCT_TEST_SCENARIO_CATALOG_JSON}" \
    "${PRODUCT_TEST_PLAN_PREVIEW_JSON}" \
    "${PRODUCT_TEST_ENTRYPOINT_RESCUE_JSON}"
  write_product_plan_preview_json "${PRODUCT_TEST_PLAN_PREVIEW_JSON}"

  if ! validate_public_target; then
    reason="public_target_invalid"
    write_plan_json "FAIL" "${reason}"
    write_product_runbook || true
    printf 'product_test_plan result=fail reason=%s plan=%s\n' "${reason}" "${PRODUCT_TEST_PLAN_JSON}" >&2
    return 1
  fi

  if ! run_operator_network_preflight; then
    reason="operator_network_failed"
    write_plan_json "FAIL" "${reason}"
    write_product_runbook || true
    printf 'product_test_plan result=fail reason=%s plan=%s\n' "${reason}" "${PRODUCT_TEST_PLAN_JSON}" >&2
    return 1
  fi

  first_phase="${PRODUCT_TEST_PHASES%% *}"
  if [[ "${first_phase}" == "entrypoint" ]]; then
    if run_entrypoint_phase; then
      entrypoint_ran=true
    else
      rc=$?
      entrypoint_ran=true
      if bool_enabled "${PRODUCT_TEST_STOP_ON_FAILURE}"; then
        reason="entrypoint_failed"
        write_plan_json "FAIL" "${reason}"
        write_product_runbook || true
        printf 'product_test_plan result=fail reason=%s plan=%s\n' "${reason}" "${PRODUCT_TEST_PLAN_JSON}" >&2
        return "${rc}"
      fi
    fi
  fi

  if ! run_product_prereq_gate; then
    reason="prereq_gate_failed"
    write_plan_json "FAIL" "${reason}"
    write_product_runbook || true
    printf 'product_test_plan result=fail reason=%s plan=%s prereq=%s\n' \
      "${reason}" \
      "${PRODUCT_TEST_PLAN_JSON}" \
      "${PRODUCT_TEST_PREREQ_AUDIT_JSON}" >&2
    return 1
  fi

  for phase in ${PRODUCT_TEST_PHASES}; do
    if [[ "${phase}" == "entrypoint" && "${entrypoint_ran}" == "true" ]]; then
      continue
    fi
    if [[ "${phase}" == "entrypoint" ]]; then
      run_entrypoint_phase || rc=$?
    else
      run_scenario_phase "${phase}" || rc=$?
    fi
    if (( rc != 0 )) && bool_enabled "${PRODUCT_TEST_STOP_ON_FAILURE}"; then
      reason="${phase}_failed"
      write_plan_json "FAIL" "${reason}"
      write_product_runbook || true
      printf 'product_test_plan result=fail reason=%s plan=%s\n' "${reason}" "${PRODUCT_TEST_PLAN_JSON}" >&2
      return "${rc}"
    fi
  done

  run_full_profile_phase || rc=$?
  if (( rc != 0 )); then
    reason="full_profile_failed"
    write_plan_json "FAIL" "${reason}"
    write_product_runbook || true
    printf 'product_test_plan result=fail reason=%s plan=%s\n' "${reason}" "${PRODUCT_TEST_PLAN_JSON}" >&2
    return "${rc}"
  fi

  write_plan_json "PASS" ""
  write_product_runbook
  if ! package_product_evidence; then
    reason="package_failed"
    write_plan_json "FAIL" "${reason}"
    write_product_runbook || true
    printf 'product_test_plan result=fail reason=%s plan=%s\n' "${reason}" "${PRODUCT_TEST_PLAN_JSON}" >&2
    return 1
  fi
  printf '\nproduct_test_plan result=pass plan=%s\n' "${PRODUCT_TEST_PLAN_JSON}"
}

case "${1:-}" in
  --help|-h)
    usage
    exit 0
    ;;
  --list|--list-phases)
    list_phases
    exit 0
    ;;
  --validate-plan)
    normalize_product_phases
    validate_product_phases
    printf 'product_test_plan result=pass mode=validate preset=%q phases=%q fullProfile=%q runFullProfile=%q\n' \
      "${PRODUCT_TEST_PRESET}" \
      "${PRODUCT_TEST_PHASES}" \
      "${PRODUCT_TEST_FULL_PROFILE}" \
      "${PRODUCT_TEST_RUN_FULL_PROFILE}"
    exit 0
    ;;
  --print-plan)
    print_product_plan
    exit 0
    ;;
  --print-plan-json)
    print_product_plan_json
    exit 0
    ;;
  "")
    ;;
  *)
    printf 'product_test_plan result=fail reason=unknown_argument arg=%s\n' "$1" >&2
    usage >&2
    exit 2
    ;;
esac

if bool_enabled "${PRODUCT_TEST_SELF_TEST}"; then
  self_test_dir="$(mktemp -d)"
  trap 'rm -rf "${self_test_dir}"' EXIT
  account_file="${self_test_dir}/accounts.csv"
  for index in $(seq 1 5000); do
    printf 'demo%03d@example.com,password1234\n' "${index}"
  done >"${account_file}"
  fake_operator_fail="${self_test_dir}/fake-operator-network-fail.sh"
  cat >"${fake_operator_fail}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'operator-network target=%s status=fail warning=tun_route routeInterface=utun99 routeGateway=198.18.0.1 proxyEnv=<none>\n' "${1:-<missing>}"
printf 'operator-network result=fail failures=1 action=disconnect_local_tun_or_use_clean_network\n' >&2
exit 1
SH
  chmod +x "${fake_operator_fail}"
  "${BASH_SOURCE[0]}" --list-phases >"${self_test_dir}/phase-list.txt"
  grep -q '^  entrypoint ' "${self_test_dir}/phase-list.txt" || {
    printf 'product_test_plan_self_test result=fail reason=entrypoint_missing_from_phase_list\n' >&2
    exit 1
  }
  grep -q '^  normal-breadth ' "${self_test_dir}/phase-list.txt" || {
    printf 'product_test_plan_self_test result=fail reason=normal_breadth_preset_missing_from_phase_list\n' >&2
    exit 1
  }
  grep -q '^  normal-acceptance ' "${self_test_dir}/phase-list.txt" || {
    printf 'product_test_plan_self_test result=fail reason=normal_acceptance_preset_missing_from_phase_list\n' >&2
    exit 1
  }
  grep -q '^  product-breadth-baseline ' "${self_test_dir}/phase-list.txt" || {
    printf 'product_test_plan_self_test result=fail reason=product_breadth_missing_from_phase_list\n' >&2
    exit 1
  }
  grep -q '^  normal-product-baseline ' "${self_test_dir}/phase-list.txt" || {
    printf 'product_test_plan_self_test result=fail reason=normal_product_missing_from_phase_list\n' >&2
    exit 1
  }
  grep -q '^  real-world-baseline ' "${self_test_dir}/phase-list.txt" || {
    printf 'product_test_plan_self_test result=fail reason=real_world_missing_from_phase_list\n' >&2
    exit 1
  }
  grep -q '^  im-scenario-breadth-baseline ' "${self_test_dir}/phase-list.txt" || {
    printf 'product_test_plan_self_test result=fail reason=im_scenario_breadth_missing_from_phase_list\n' >&2
    exit 1
  }
  PRODUCT_TEST_PHASES="entrypoint daily-core sync-read" \
    "${BASH_SOURCE[0]}" --validate-plan >"${self_test_dir}/validate-plan.txt"
  PRODUCT_TEST_PHASES="daily-core sync-read" \
    "${BASH_SOURCE[0]}" --validate-plan >"${self_test_dir}/validate-normalized-plan.txt"
  grep -q 'phases=entrypoint\\ daily-core\\ sync-read' "${self_test_dir}/validate-normalized-plan.txt" || {
    printf 'product_test_plan_self_test result=fail reason=normalized_entrypoint_missing\n' >&2
    exit 1
  }
  PRODUCT_TEST_PRESET=realtime-focused \
    "${BASH_SOURCE[0]}" --validate-plan >"${self_test_dir}/validate-preset-plan.txt"
  grep -q 'preset=realtime-focused' "${self_test_dir}/validate-preset-plan.txt" || {
    printf 'product_test_plan_self_test result=fail reason=preset_validate_missing\n' >&2
    exit 1
  }
  grep -q 'phases=entrypoint\\ message-spike\\ realtime-direct\\ realtime-direct-baseline\\ group-delivery\\ group-delivery-baseline' "${self_test_dir}/validate-preset-plan.txt" || {
    printf 'product_test_plan_self_test result=fail reason=preset_phases_unexpected\n' >&2
    exit 1
  }
  PRODUCT_TEST_PRESET=normal-breadth \
    "${BASH_SOURCE[0]}" --print-plan >"${self_test_dir}/print-plan.txt"
  grep -q 'mode=print preset=normal-breadth' "${self_test_dir}/print-plan.txt" || {
    printf 'product_test_plan_self_test result=fail reason=print_plan_header_missing\n' >&2
    exit 1
  }
  BASE_URL="http://203.0.113.10:8080" \
  TCP_HOST="" \
  PRODUCT_TEST_PRESET=normal-breadth \
    "${BASH_SOURCE[0]}" --print-plan >"${self_test_dir}/derived-target-print-plan.txt"
  grep -q 'target baseURL=http://203.0.113.10:8080 tcpHost=203.0.113.10 tcpPort=9000' "${self_test_dir}/derived-target-print-plan.txt" || {
    printf 'product_test_plan_self_test result=fail reason=derived_tcp_host_missing\n' >&2
    exit 1
  }
  if RESULT_ROOT="${self_test_dir}/gate-require-target-results" \
    BASE_URL="http://203.0.113.10:8080" \
    TCP_HOST="203.0.113.10" \
    PRODUCT_TEST_PHASES="entrypoint daily-core" \
    PRODUCT_TEST_PACKAGE_EVIDENCE=false \
    PRODUCT_TEST_OPERATOR_NETWORK_PREFLIGHT_SCRIPT="${fake_operator_fail}" \
    PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET=true \
    PRODUCT_TEST_RUN_ID_PREFIX="product-gate-require-target" \
    PRODUCT_TEST_SELF_TEST=false \
      "${BASH_SOURCE[0]}" >"${self_test_dir}/gate-require-target.log" 2>&1; then
    printf 'product_test_plan_self_test result=fail reason=gate_require_target_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=base_url_https_required' "${self_test_dir}/gate-require-target.log" || {
    printf 'product_test_plan_self_test result=fail reason=gate_require_target_reason_missing\n' >&2
    exit 1
  }
  python3 - \
    "${self_test_dir}/gate-require-target-results/product-test-plan-run.json" \
    "${self_test_dir}/gate-require-target-results/product-gate-require-target-operator-network/operator-network.log" <<'PY'
import json
import sys
from pathlib import Path

with open(sys.argv[1], encoding="utf-8") as handle:
    run = json.load(handle)
if run.get("finalStatus") != "FAIL":
    raise SystemExit("product_test_plan_self_test result=fail reason=gate_require_target_status_not_fail")
if run.get("reason") != "public_target_invalid":
    raise SystemExit("product_test_plan_self_test result=fail reason=gate_require_target_run_reason_mismatch")
if run.get("blockerType") != "target":
    raise SystemExit(f"product_test_plan_self_test result=fail reason=gate_require_target_blocker_type_mismatch blockerType={run.get('blockerType')}")
if Path(sys.argv[2]).exists():
    raise SystemExit("product_test_plan_self_test result=fail reason=gate_require_target_started_operator_network")
PY
  grep -Fq 'phase=daily-core kind=scenario-groups groups=daily-core-smoke\ daily-traffic-smoke' "${self_test_dir}/print-plan.txt" || {
    printf 'product_test_plan_self_test result=fail reason=print_plan_daily_core_missing\n' >&2
    exit 1
  }
  python3 - "${self_test_dir}/print-plan.txt" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(r"summary uniqueScenarioCount=(\d+)", text)
if not match:
    raise SystemExit("product_test_plan_self_test result=fail reason=print_plan_summary_missing")
if int(match.group(1)) <= 0:
    raise SystemExit("product_test_plan_self_test result=fail reason=print_plan_empty")
PY
  PRODUCT_TEST_PRESET=normal-acceptance \
    "${BASH_SOURCE[0]}" --print-plan >"${self_test_dir}/acceptance-print-plan.txt"
  grep -q 'mode=print preset=normal-acceptance' "${self_test_dir}/acceptance-print-plan.txt" || {
    printf 'product_test_plan_self_test result=fail reason=acceptance_print_plan_header_missing\n' >&2
    exit 1
  }
  grep -q 'phase=real-world-baseline' "${self_test_dir}/acceptance-print-plan.txt" || {
    printf 'product_test_plan_self_test result=fail reason=acceptance_real_world_missing\n' >&2
    exit 1
  }
  grep -q 'phase=group-delivery-baseline' "${self_test_dir}/acceptance-print-plan.txt" || {
    printf 'product_test_plan_self_test result=fail reason=acceptance_group_delivery_missing\n' >&2
    exit 1
  }
  PRODUCT_TEST_PRESET=normal-breadth \
    "${BASH_SOURCE[0]}" --print-plan-json >"${self_test_dir}/print-plan.json"
  python3 - "${self_test_dir}/print-plan.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if payload.get("schemaVersion") != 1:
    raise SystemExit("product_test_plan_self_test result=fail reason=print_plan_json_schema_missing")
if payload.get("preset") != "normal-breadth":
    raise SystemExit("product_test_plan_self_test result=fail reason=print_plan_json_preset_missing")
summary = payload.get("summary") or {}
if int(summary.get("uniqueScenarioCount") or 0) <= 0:
    raise SystemExit("product_test_plan_self_test result=fail reason=print_plan_json_empty")
if summary.get("largeGroupIncluded") is not False:
    raise SystemExit("product_test_plan_self_test result=fail reason=print_plan_json_large_group_included")
required_domains = summary.get("requiredProductDomains") or []
covered_domains = summary.get("coveredProductDomains") or []
if len(required_domains) != 8:
    raise SystemExit(f"product_test_plan_self_test result=fail reason=print_plan_json_required_domains_count count={len(required_domains)}")
if sorted(required_domains) != sorted(covered_domains):
    raise SystemExit("product_test_plan_self_test result=fail reason=print_plan_json_required_domains_missing")
if summary.get("missingProductDomains") != []:
    raise SystemExit("product_test_plan_self_test result=fail reason=print_plan_json_missing_domains_nonempty")
if summary.get("requiredProductDomainsCovered") is not True:
    raise SystemExit("product_test_plan_self_test result=fail reason=print_plan_json_required_domains_not_covered")
daily_core = next((row for row in payload.get("phases") or [] if row.get("phase") == "daily-core"), None)
if not daily_core:
    raise SystemExit("product_test_plan_self_test result=fail reason=print_plan_json_daily_core_missing")
if daily_core.get("groups") != ["daily-core-smoke", "daily-traffic-smoke"]:
    raise SystemExit(f"product_test_plan_self_test result=fail reason=print_plan_json_daily_core_groups groups={daily_core.get('groups')}")
if int(daily_core.get("scenarioCount") or 0) <= 0:
    raise SystemExit("product_test_plan_self_test result=fail reason=print_plan_json_daily_core_empty")
if not payload.get("selectedScenarios"):
    raise SystemExit("product_test_plan_self_test result=fail reason=print_plan_json_selected_missing")
PY
  if PRODUCT_TEST_PRESET=definitely-not-a-preset \
    "${BASH_SOURCE[0]}" --validate-plan >"${self_test_dir}/invalid-preset.txt" 2>&1; then
    printf 'product_test_plan_self_test result=fail reason=invalid_preset_validate_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=unknown_preset preset=definitely-not-a-preset' "${self_test_dir}/invalid-preset.txt" || {
    printf 'product_test_plan_self_test result=fail reason=invalid_preset_message_missing\n' >&2
    exit 1
  }
  if PRODUCT_TEST_PHASES="entrypoint definitely-not-a-phase" \
    "${BASH_SOURCE[0]}" --validate-plan >"${self_test_dir}/invalid-plan.txt" 2>&1; then
    printf 'product_test_plan_self_test result=fail reason=invalid_phase_validate_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=invalid_phase_list phase=definitely-not-a-phase' "${self_test_dir}/invalid-plan.txt" || {
    printf 'product_test_plan_self_test result=fail reason=invalid_phase_message_missing\n' >&2
    exit 1
  }
  RESULT_ROOT="${self_test_dir}/results" \
  ACCOUNT_FILE="${account_file}" \
  IM_CONVERSATION_ID="00000000-0000-4000-8000-000000000001" \
  IM_INTERNAL_SECRET="self-test-secret" \
  PRODUCT_TEST_PHASES="entrypoint daily-core sync-message social-governance realtime-direct" \
  PRODUCT_TEST_RUN_ID_PREFIX="product-self-test" \
  PRODUCT_TEST_RUN_FULL_PROFILE=false \
  PRODUCT_TEST_SELF_TEST=false \
  PERF_DRY_RUN=true \
    "${BASH_SOURCE[0]}" >/dev/null
  python3 - "${self_test_dir}/results/product-test-plan-run.json" <<'PY'
import json
import sys
from pathlib import Path

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
if payload.get("finalStatus") != "PASS":
    raise SystemExit("product_test_plan_self_test result=fail reason=status_not_pass")
if payload.get("dryRun") is not True:
    raise SystemExit("product_test_plan_self_test result=fail reason=dry_run_not_recorded")
if payload.get("preset") not in {"", None}:
    raise SystemExit("product_test_plan_self_test result=fail reason=explicit_phases_should_not_record_preset")
phases = payload.get("phases") or []
if len(phases) != 7:
    raise SystemExit(f"product_test_plan_self_test result=fail reason=phase_count expected=7 actual={len(phases)}")
names = [item.get("phase") for item in phases]
expected = ["operator-network", "entrypoint", "daily-core", "sync-message", "social-governance", "realtime-direct", "full-profile"]
if names != expected:
    raise SystemExit(f"product_test_plan_self_test result=fail reason=phase_order names={names}")
if not all(item.get("command") for item in phases):
    raise SystemExit("product_test_plan_self_test result=fail reason=missing_command")
if phases[0].get("kind") != "operator-network" or phases[0].get("status") != "DRY_RUN":
    raise SystemExit("product_test_plan_self_test result=fail reason=operator_network_dry_run_phase_missing")
if not any("SCENARIO_GROUPS=daily-core-smoke\\ daily-traffic-smoke" in item.get("command", "") or "SCENARIO_GROUPS=daily-core-smoke daily-traffic-smoke" in item.get("command", "") for item in phases):
    raise SystemExit("product_test_plan_self_test result=fail reason=daily_core_groups_missing")
if phases[-1].get("kind") != "production-profile" or phases[-1].get("status") != "SKIPPED":
    raise SystemExit("product_test_plan_self_test result=fail reason=full_profile_kind_missing")
preview_path = Path((payload.get("planPreview") or {}).get("json") or "")
if not preview_path.exists():
    raise SystemExit("product_test_plan_self_test result=fail reason=plan_preview_missing")
preview = json.loads(preview_path.read_text(encoding="utf-8"))
if preview.get("requestedPhases") != payload.get("requestedPhases"):
    raise SystemExit("product_test_plan_self_test result=fail reason=plan_preview_phase_mismatch")
if int((preview.get("summary") or {}).get("uniqueScenarioCount") or 0) <= 0:
    raise SystemExit("product_test_plan_self_test result=fail reason=plan_preview_empty")
PY
  python3 "${SCRIPT_DIR}/perf_product_plan_artifacts_verify.py" \
    --product-run-json "${self_test_dir}/results/product-test-plan-run.json" \
    --allow-dry-run \
    --require-prereq >/dev/null
  python3 - "${self_test_dir}/results/product-test-runbook.json" "${self_test_dir}/results/bad-evidence-policy-product-test-runbook.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
payload.setdefault("evidencePolicy", {})["requiresCurrentReadiness"] = True
Path(sys.argv[2]).write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
  if python3 "${SCRIPT_DIR}/perf_product_plan_artifacts_verify.py" \
    --product-run-json "${self_test_dir}/results/product-test-plan-run.json" \
    --runbook-json "${self_test_dir}/results/bad-evidence-policy-product-test-runbook.json" \
    --allow-dry-run \
    --require-prereq >"${self_test_dir}/results/bad-evidence-policy-runbook.log" 2>&1; then
    printf 'product_test_plan_self_test result=fail reason=bad_evidence_policy_runbook_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=runbook_evidence_policy_current_readiness_invalid' "${self_test_dir}/results/bad-evidence-policy-runbook.log" || {
    printf 'product_test_plan_self_test result=fail reason=bad_evidence_policy_runbook_reason_missing\n' >&2
    exit 1
  }

  if RESULT_ROOT="${self_test_dir}/operator-network-results" \
    BASE_URL="http://203.0.113.10:8080" \
    TCP_HOST="203.0.113.10" \
    ACCOUNT_FILE="${account_file}" \
    IM_CONVERSATION_ID="00000000-0000-4000-8000-000000000001" \
    IM_INTERNAL_SECRET="self-test-secret" \
    PRODUCT_TEST_PHASES="entrypoint daily-core" \
    PRODUCT_TEST_RUN_ID_PREFIX="product-operator-network-self-test" \
    PRODUCT_TEST_RUN_FULL_PROFILE=false \
    PRODUCT_TEST_PACKAGE_EVIDENCE=false \
    PRODUCT_TEST_OPERATOR_NETWORK_PREFLIGHT_SCRIPT="${fake_operator_fail}" \
    PRODUCT_TEST_SELF_TEST=false \
    PERF_DRY_RUN=false \
      "${BASH_SOURCE[0]}" >"${self_test_dir}/operator-network-plan.log" 2>&1; then
    printf 'product_test_plan_self_test result=fail reason=operator_network_failure_passed\n' >&2
    exit 1
  fi
  python3 - \
    "${self_test_dir}/operator-network-results/product-test-plan-run.json" \
    "${self_test_dir}/operator-network-results/product-operator-network-self-test-operator-network/operator-network.log" \
    "${self_test_dir}/operator-network-results/product-operator-network-self-test-entrypoint/entrypoint-probe.log" \
    "${self_test_dir}/operator-network-results/product-test-runbook.json" <<'PY'
import json
import sys
from pathlib import Path

run = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if run.get("finalStatus") != "FAIL":
    raise SystemExit("product_test_plan_self_test result=fail reason=operator_network_status_not_fail")
if run.get("reason") != "operator_network_failed":
    raise SystemExit("product_test_plan_self_test result=fail reason=operator_network_reason_mismatch")
if run.get("blockerType") != "operator-network":
    raise SystemExit(f"product_test_plan_self_test result=fail reason=operator_network_blocker_type_mismatch blockerType={run.get('blockerType')}")
phases = run.get("phases") or []
if len(phases) != 1 or phases[0].get("phase") != "operator-network" or phases[0].get("status") != "FAIL":
    raise SystemExit(f"product_test_plan_self_test result=fail reason=operator_network_phase_invalid phases={phases}")
operator_log = Path(sys.argv[2])
if "operator-network result=fail" not in operator_log.read_text(encoding="utf-8", errors="replace"):
    raise SystemExit("product_test_plan_self_test result=fail reason=operator_network_log_missing_failure")
if Path(sys.argv[3]).exists():
    raise SystemExit("product_test_plan_self_test result=fail reason=operator_network_started_entrypoint_probe")
runbook = json.loads(Path(sys.argv[4]).read_text(encoding="utf-8"))
product_run = runbook.get("productRun") or {}
if product_run.get("blockerType") != "operator-network":
    raise SystemExit(f"product_test_plan_self_test result=fail reason=operator_network_runbook_blocker_type_mismatch blockerType={product_run.get('blockerType')}")
PY
  python3 "${SCRIPT_DIR}/perf_product_plan_artifacts_verify.py" \
    --product-run-json "${self_test_dir}/operator-network-results/product-test-plan-run.json" \
    --require-prereq >/dev/null

  if RESULT_ROOT="${self_test_dir}/blocked-results" \
    ACCOUNT_FILE="${account_file}" \
    IM_CONVERSATION_ID="" \
    IM_INTERNAL_SECRET="" \
    PRODUCT_TEST_PHASES="direct-chat" \
    PRODUCT_TEST_RUN_ID_PREFIX="product-blocked-self-test" \
    PRODUCT_TEST_RUN_FULL_PROFILE=false \
    PRODUCT_TEST_SELF_TEST=false \
    PERF_DRY_RUN=true \
      "${BASH_SOURCE[0]}" >"${self_test_dir}/blocked.log" 2>&1; then
    printf 'product_test_plan_self_test result=fail reason=missing_prereq_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=prereq_gate_failed' "${self_test_dir}/blocked.log" || {
    printf 'product_test_plan_self_test result=fail reason=missing_prereq_reason_absent\n' >&2
    exit 1
  }
  python3 - "${self_test_dir}/blocked-results/product-test-plan-run.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    run = json.load(handle)
if run.get("blockerType") != "prerequisites":
    raise SystemExit(f"product_test_plan_self_test result=fail reason=blocked_blocker_type_mismatch blockerType={run.get('blockerType')}")
PY
  python3 - "${self_test_dir}/blocked-results/product-test-runbook.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    runbook = json.load(handle)
product_run = runbook.get("productRun") or {}
if product_run.get("blockerType") != "prerequisites":
    raise SystemExit(f"product_test_plan_self_test result=fail reason=blocked_runbook_blocker_type_mismatch blockerType={product_run.get('blockerType')}")
PY
  python3 "${SCRIPT_DIR}/perf_product_plan_artifacts_verify.py" \
    --product-run-json "${self_test_dir}/blocked-results/product-test-plan-run.json" \
    --allow-dry-run \
    --require-prereq >/dev/null

  RESULT_ROOT="${self_test_dir}/results-expanded" \
  ACCOUNT_FILE="${account_file}" \
  IM_CONVERSATION_ID="00000000-0000-4000-8000-000000000001" \
  IM_INTERNAL_SECRET="self-test-secret" \
  PRODUCT_TEST_PHASES="real-world-smoke real-world-baseline im-scenario-breadth-smoke im-scenario-breadth-baseline account-security sync-read direct-chat group-workflow contacts-social media-ai-admin message-spike reliability-recovery normal-product-baseline non-large-group-baseline" \
  PRODUCT_TEST_RUN_ID_PREFIX="product-expanded-self-test" \
  PRODUCT_TEST_RUN_FULL_PROFILE=false \
  PRODUCT_TEST_SELF_TEST=false \
  PERF_DRY_RUN=true \
    "${BASH_SOURCE[0]}" >/dev/null
  python3 - "${self_test_dir}/results-expanded/product-test-plan-run.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
if payload.get("finalStatus") != "PASS":
    raise SystemExit("product_test_plan_self_test result=fail reason=expanded_status_not_pass")
phases = payload.get("phases") or []
names = [item.get("phase") for item in phases]
expected = [
    "operator-network",
    "entrypoint",
    "real-world-smoke",
    "real-world-baseline",
    "im-scenario-breadth-smoke",
    "im-scenario-breadth-baseline",
    "account-security",
    "sync-read",
    "direct-chat",
    "group-workflow",
    "contacts-social",
    "media-ai-admin",
    "message-spike",
    "reliability-recovery",
    "normal-product-baseline",
    "non-large-group-baseline",
    "full-profile",
]
if names != expected:
    raise SystemExit(f"product_test_plan_self_test result=fail reason=expanded_phase_order names={names}")
commands = "\n".join(item.get("command", "") for item in phases)
for expected_group in [
    "SCENARIO_GROUPS=account-security",
    "SCENARIO_GROUPS=sync-read",
    "SCENARIO_GROUPS=direct-chat",
    "SCENARIO_GROUPS=group-workflow",
    "SCENARIO_GROUPS=contacts-social",
    "SCENARIO_GROUPS=media-ai-admin",
    "SCENARIO_GROUPS=message-spike-smoke",
    "SCENARIO_GROUPS=reliability-recovery-smoke",
    "SCENARIO_GROUPS=normal-product-baseline",
    "SCENARIO_GROUPS=non-large-group-baseline",
    "SCENARIO_GROUPS=real-world-smoke",
    "SCENARIO_GROUPS=real-world-baseline",
    "SCENARIO_GROUPS=im-scenario-breadth-smoke",
    "SCENARIO_GROUPS=im-scenario-breadth-baseline",
]:
    if expected_group not in commands:
        raise SystemExit(f"product_test_plan_self_test result=fail reason=expanded_group_missing group={expected_group}")
PY
  python3 "${SCRIPT_DIR}/perf_product_plan_artifacts_verify.py" \
    --product-run-json "${self_test_dir}/results-expanded/product-test-plan-run.json" \
    --allow-dry-run \
    --require-prereq >/dev/null

  RESULT_ROOT="${self_test_dir}/full-profile-results" \
  ACCOUNT_FILE="${account_file}" \
  IM_CONVERSATION_ID="00000000-0000-4000-8000-000000000001" \
  IM_INTERNAL_SECRET="self-test-secret" \
  PRODUCT_TEST_PHASES="entrypoint daily-core" \
  PRODUCT_TEST_RUN_ID_PREFIX="product-full-profile-self-test" \
  PRODUCT_TEST_RUN_FULL_PROFILE=true \
  PRODUCT_TEST_PACKAGE_EVIDENCE=true \
  PRODUCT_TEST_SELF_TEST=false \
  PERF_DRY_RUN=true \
    "${BASH_SOURCE[0]}" >/dev/null
  python3 - "${self_test_dir}/full-profile-results/product-test-plan-run.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
if payload.get("finalStatus") != "PASS":
    raise SystemExit("product_test_plan_self_test result=fail reason=full_profile_status_not_pass")
phases = payload.get("phases") or []
full_profile = phases[-1] if phases else {}
if full_profile.get("phase") != "full-profile" or full_profile.get("status") != "PASS":
    raise SystemExit("product_test_plan_self_test result=fail reason=full_profile_phase_not_pass")
command = full_profile.get("command") or ""
for expected in [
    "PRODUCTION_PROFILE_PACKAGE=false",
    "PRODUCTION_PROFILE_REQUIRE_PRODUCT_PLAN_ARTIFACTS=false",
]:
    if expected not in command:
        raise SystemExit(f"product_test_plan_self_test result=fail reason=full_profile_command_missing expected={expected}")
PY
  recovery_dir="${self_test_dir}/entrypoint-failed-results"
  recovery_run_dir="${recovery_dir}/product-entrypoint-failed-entrypoint"
  mkdir -p "${recovery_run_dir}"
  cat >"${recovery_run_dir}/entrypoint-probe.json" <<'JSON'
{
  "schemaVersion": 1,
  "baseURL": "http://203.0.113.10:8080",
  "diagnosis": "public_listener_not_imserver_nginx",
  "failed": true,
  "detail": "/nginx-health returned empty 403.",
  "blocker": {
    "type": "entrypoint",
    "severity": "P0",
    "preventsPerformanceEvidence": true,
    "action": "repair_entrypoint",
    "reason": "/nginx-health returned empty 403."
  },
  "signals": {
    "nginxHealthStatus": "403",
    "nginxHealthBodyBytes": 0,
    "healthStatus": "403",
    "loginStatus": "403",
    "tcpStatus": "open"
  }
}
JSON
  cat >"${recovery_dir}/product-test-plan-preview.json" <<'JSON'
{
  "schemaVersion": 1,
  "plan": "self-test",
  "preset": "",
  "requestedPhases": ["entrypoint", "daily-core"],
  "fullProfile": "normal-product-baseline",
  "runFullProfile": false,
  "packageEvidence": true,
  "requireEntrypoint": true,
  "prereqGate": true,
  "dryRun": false,
  "statusFilterTarget": true,
  "target": {
    "baseURL": "http://203.0.113.10:8080",
    "tcpHost": "203.0.113.10",
    "tcpPort": "9000",
    "accountFile": "",
    "conversationID": ""
  },
  "summary": {
    "phaseCount": 2,
    "scenarioPhaseCount": 1,
    "uniqueScenarioCount": 1,
    "largeGroupIncluded": false,
    "coveredProductDomains": ["account-security"],
    "requiredProductDomains": [
      "account-security",
      "sync-read",
      "direct-chat",
      "group-workflow",
      "contacts-social",
      "media-ai-admin",
      "reliability-recovery",
      "realtime-direct"
    ],
    "missingProductDomains": [
      "sync-read",
      "direct-chat",
      "group-workflow",
      "contacts-social",
      "media-ai-admin",
      "reliability-recovery",
      "realtime-direct"
    ],
    "requiredProductDomainsCovered": false
  },
  "selectedScenarios": ["login-smoke"],
  "phases": [
    {
      "phase": "entrypoint",
      "kind": "entrypoint",
      "groups": [],
      "runner": "http_entrypoint_probe.sh",
      "scenarioCount": 0,
      "firstScenario": "",
      "sampleScenarios": [],
      "scenarios": []
    },
    {
      "phase": "daily-core",
      "kind": "scenario-groups",
      "groups": ["daily-core-smoke", "daily-traffic-smoke"],
      "runner": "run_perf_scenarios.sh",
      "scenarioCount": 1,
      "firstScenario": "login-smoke",
      "sampleScenarios": ["login-smoke"],
      "scenarios": ["login-smoke"]
    }
  ]
}
JSON
  cat >"${recovery_dir}/product-test-plan-run.json" <<EOF
{
  "schemaVersion": 1,
  "plan": "self-test",
  "requestedPhases": ["entrypoint", "daily-core"],
  "runFullProfile": false,
  "fullProfile": "normal-product-baseline",
  "runIDPrefix": "product-entrypoint-failed",
  "finalStatus": "FAIL",
  "reason": "entrypoint_failed",
  "blockerType": "entrypoint",
  "dryRun": false,
  "statusFilterTarget": true,
  "target": {
    "baseURL": "http://203.0.113.10:8080",
    "tcpHost": "203.0.113.10",
    "tcpPort": "9000",
    "accountFile": "${account_file}",
    "conversationID": ""
  },
  "prereq": {
    "enabled": true,
    "ran": false,
    "plan": "${recovery_dir}/product-test-prereq-plan.json",
    "auditJSON": "${recovery_dir}/product-test-prereq-audit.json",
    "auditMarkdown": "${recovery_dir}/product-test-prereq-audit.md"
  },
  "planPreview": {
    "json": "${recovery_dir}/product-test-plan-preview.json",
    "exists": true
  },
  "entrypoint": {
    "required": true,
    "rescueArtifact": {
      "schemaVersion": 1,
      "status": "SKIPPED",
      "reason": "missing_ssh_key_source",
      "enabled": true,
      "packageEnabled": true,
      "dryRun": false,
      "artifactDir": "${recovery_dir}/current-node-access-rescue",
      "artifactDirExists": false,
      "tarball": "${recovery_dir}/current-node-access-rescue.tar.gz",
      "tarballExists": false,
      "logFile": "",
      "logFileExists": false
    }
  },
  "runbook": {
    "json": "${recovery_dir}/product-test-runbook.json",
    "markdown": "${recovery_dir}/product-test-runbook.md"
  },
  "phases": [
    {
      "phase": "entrypoint",
      "kind": "entrypoint-probe",
      "runID": "product-entrypoint-failed-entrypoint",
      "status": "FAIL",
      "reason": "entrypoint_probe_failed",
      "command": "BASE_URL=http://203.0.113.10:8080 ./http_entrypoint_probe.sh",
      "runDir": "${recovery_run_dir}"
    }
  ]
}
EOF
  python3 "${SCRIPT_DIR}/perf_product_test_plan_runbook.py" \
    --product-run-json "${recovery_dir}/product-test-plan-run.json" \
    --result-root "${recovery_dir}" \
    --output "${recovery_dir}/product-test-runbook.md" \
    --json-output "${recovery_dir}/product-test-runbook.json" >/dev/null
  python3 - "${recovery_dir}/product-test-runbook.json" "${recovery_dir}/product-test-runbook.md" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
markdown = Path(sys.argv[2]).read_text(encoding="utf-8")
if payload.get("status") != "BLOCKED":
    raise SystemExit("product_test_plan_self_test result=fail reason=entrypoint_runbook_not_blocked")
recovery = ((payload.get("entrypoint") or {}).get("recovery") or {})
if recovery.get("diagnosis") != "public_listener_not_imserver_nginx":
    raise SystemExit("product_test_plan_self_test result=fail reason=entrypoint_diagnosis_missing")
blocker = recovery.get("blocker") or {}
if blocker.get("type") != "entrypoint" or blocker.get("severity") != "P0":
    raise SystemExit(f"product_test_plan_self_test result=fail reason=entrypoint_blocker_invalid blocker={blocker}")
if blocker.get("preventsPerformanceEvidence") is not True:
    raise SystemExit("product_test_plan_self_test result=fail reason=entrypoint_blocker_not_preventing_performance")
if "blocker: `entrypoint/P0`" not in markdown or "preventsPerformanceEvidence=`True`" not in markdown:
    raise SystemExit("product_test_plan_self_test result=fail reason=entrypoint_blocker_markdown_missing")
commands = "\n".join(command.get("command", "") for command in recovery.get("commands") or [])
for expected in [
    "75_entrypoint_diagnose.sh",
    "23_repair_node_access.sh",
    "64_repair_http_entrypoint.sh",
]:
    if expected not in commands or expected not in markdown:
        raise SystemExit(f"product_test_plan_self_test result=fail reason=entrypoint_recovery_command_missing command={expected}")
if "21_render_node_access_rescue_command.sh" in commands:
    raise SystemExit("product_test_plan_self_test result=fail reason=entrypoint_recovery_unexpected_cloud_console_command")
PY
  python3 "${SCRIPT_DIR}/perf_product_plan_artifacts_verify.py" \
    --product-run-json "${recovery_dir}/product-test-plan-run.json" \
    --require-prereq >/dev/null
  python3 - "${recovery_dir}/product-test-runbook.json" "${recovery_dir}/bad-product-test-runbook.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
((payload.get("entrypoint") or {}).get("recovery") or {})["commands"] = []
Path(sys.argv[2]).write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
  if python3 "${SCRIPT_DIR}/perf_product_plan_artifacts_verify.py" \
    --product-run-json "${recovery_dir}/product-test-plan-run.json" \
    --runbook-json "${recovery_dir}/bad-product-test-runbook.json" \
    --require-prereq >"${recovery_dir}/bad-runbook.log" 2>&1; then
    printf 'product_test_plan_self_test result=fail reason=bad_entrypoint_recovery_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=entrypoint_failed_recovery_command_missing' "${recovery_dir}/bad-runbook.log" || {
    printf 'product_test_plan_self_test result=fail reason=bad_entrypoint_recovery_reason_missing\n' >&2
    exit 1
  }
  local_recovery_dir="${self_test_dir}/entrypoint-local-proxy-results"
  local_recovery_run_dir="${local_recovery_dir}/product-entrypoint-local-proxy-entrypoint"
  mkdir -p "${local_recovery_run_dir}"
  cp "${recovery_dir}/product-test-plan-preview.json" "${local_recovery_dir}/product-test-plan-preview.json"
  cat >"${local_recovery_run_dir}/entrypoint-probe.json" <<'JSON'
{
  "schemaVersion": 1,
  "baseURL": "http://203.0.113.10:8080",
  "diagnosis": "local_network_proxy_http_403_intercept",
  "failed": true,
  "detail": "The local route or proxy environment can intercept traffic before it reaches the server.",
  "localNetworkWarning": "tun_route",
  "localRouteInterface": "utun99",
  "localRouteGateway": "198.18.0.1",
  "blocker": {
    "type": "entrypoint",
    "severity": "P0",
    "preventsPerformanceEvidence": true,
    "action": "disable_local_proxy_or_test_from_clean_network",
    "reason": "local TUN route"
  },
  "signals": {
    "nginxHealthStatus": "403",
    "healthStatus": "403",
    "loginStatus": "403",
    "tcpStatus": "http_403_intercepted",
    "localNetworkWarning": "tun_route",
    "localRouteInterface": "utun99",
    "localRouteGateway": "198.18.0.1"
  }
}
JSON
  cat >"${local_recovery_dir}/product-test-plan-run.json" <<EOF
{
  "schemaVersion": 1,
  "plan": "self-test",
  "requestedPhases": ["entrypoint", "daily-core"],
  "runFullProfile": false,
  "fullProfile": "normal-product-baseline",
  "runIDPrefix": "product-entrypoint-local-proxy",
  "finalStatus": "FAIL",
  "reason": "entrypoint_failed",
  "blockerType": "entrypoint",
  "dryRun": false,
  "statusFilterTarget": true,
  "target": {
    "baseURL": "http://203.0.113.10:8080",
    "tcpHost": "203.0.113.10",
    "tcpPort": "9000",
    "accountFile": "${account_file}",
    "conversationID": ""
  },
  "prereq": {
    "enabled": true,
    "ran": false,
    "plan": "${local_recovery_dir}/product-test-prereq-plan.json",
    "auditJSON": "${local_recovery_dir}/product-test-prereq-audit.json",
    "auditMarkdown": "${local_recovery_dir}/product-test-prereq-audit.md"
  },
  "planPreview": {
    "json": "${local_recovery_dir}/product-test-plan-preview.json",
    "exists": true
  },
  "entrypoint": {
    "required": true,
    "rescueArtifact": {
      "schemaVersion": 1,
      "status": "SKIPPED",
      "reason": "probe_action_not_cloud_console:disable_local_proxy_or_test_from_clean_network",
      "enabled": true,
      "packageEnabled": true,
      "dryRun": false,
      "artifactDir": "${local_recovery_dir}/current-node-access-rescue",
      "artifactDirExists": false,
      "tarball": "${local_recovery_dir}/current-node-access-rescue.tar.gz",
      "tarballExists": false,
      "logFile": "",
      "logFileExists": false
    }
  },
  "runbook": {
    "json": "${local_recovery_dir}/product-test-runbook.json",
    "markdown": "${local_recovery_dir}/product-test-runbook.md"
  },
  "phases": [
    {
      "phase": "entrypoint",
      "kind": "entrypoint-probe",
      "runID": "product-entrypoint-local-proxy-entrypoint",
      "status": "FAIL",
      "reason": "entrypoint_probe_failed",
      "command": "BASE_URL=http://203.0.113.10:8080 ./http_entrypoint_probe.sh",
      "runDir": "${local_recovery_run_dir}"
    }
  ]
}
EOF
  python3 "${SCRIPT_DIR}/perf_product_test_plan_runbook.py" \
    --product-run-json "${local_recovery_dir}/product-test-plan-run.json" \
    --result-root "${local_recovery_dir}" \
    --output "${local_recovery_dir}/product-test-runbook.md" \
    --json-output "${local_recovery_dir}/product-test-runbook.json" >/dev/null
  python3 - "${local_recovery_dir}/product-test-runbook.json" "${local_recovery_dir}/product-test-runbook.md" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
markdown = Path(sys.argv[2]).read_text(encoding="utf-8")
recovery = ((payload.get("entrypoint") or {}).get("recovery") or {})
if recovery.get("diagnosis") != "local_network_proxy_http_403_intercept":
    raise SystemExit("product_test_plan_self_test result=fail reason=local_proxy_diagnosis_missing")
blocker = recovery.get("blocker") or {}
if blocker.get("action") != "disable_local_proxy_or_test_from_clean_network":
    raise SystemExit("product_test_plan_self_test result=fail reason=local_proxy_action_missing")
commands = "\n".join(command.get("command", "") for command in recovery.get("commands") or [])
if "http_entrypoint_probe.sh" not in commands or "rerun-entrypoint-probe-clean-network" not in markdown:
    raise SystemExit("product_test_plan_self_test result=fail reason=local_proxy_rerun_command_missing")
for forbidden in ["23_repair_node_access.sh", "21_render_node_access_rescue_command.sh"]:
    if forbidden in commands or forbidden in markdown:
        raise SystemExit(f"product_test_plan_self_test result=fail reason=local_proxy_forbidden_server_command command={forbidden}")
PY
  python3 "${SCRIPT_DIR}/perf_product_plan_artifacts_verify.py" \
    --product-run-json "${local_recovery_dir}/product-test-plan-run.json" \
    --require-prereq >/dev/null
  printf 'product_test_plan_self_test result=pass\n'
  exit 0
fi

run_plan
