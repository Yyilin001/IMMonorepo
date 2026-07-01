#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export COPYFILE_DISABLE="${COPYFILE_DISABLE:-1}"

PERF_PRODUCTION_EVIDENCE_CURRENT_LINK="${PERF_PRODUCTION_EVIDENCE_CURRENT_LINK:-/var/lib/imserver/performance/current-evidence}"
PERF_PRODUCTION_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS="${PERF_PRODUCTION_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS:-true}"
PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS="${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS:-true}"
PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS="${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS:-true}"
PERF_PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS="${PERF_PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS:-true}"
PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS="${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS:-true}"
PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP="${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP:-true}"
PERF_PRODUCTION_EVIDENCE_REQUIRE_VALIDATION_INVENTORY="${PERF_PRODUCTION_EVIDENCE_REQUIRE_VALIDATION_INVENTORY:-true}"
PERF_PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP="${PERF_PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP:-false}"
PERF_PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT="${PERF_PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT:-}"
PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS="${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS:-86400}"
PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID="${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID:-${ALIYUN_SECURITY_GROUP_ID:-}}"
PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID="${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID:-${ALIYUN_REGION_ID:-}}"
PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR="${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR:-${ALIYUN_SECURITY_GROUP_ADMIN_CIDR:-}}"
PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS="${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS:-80 443 9000}"
PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS="${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS:-3389 5432 6379 9092 8081 8082 18080 8080}"
PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ADMIN_PORTS="${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ADMIN_PORTS:-22}"
PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS="${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS:-}"
PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080="${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080:-false}"
PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS="${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS:-86400}"
PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER="${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER:-true}"
PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP="${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP:-true}"
PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX="${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX:-8}"
PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX="${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX:-16}"
PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX="${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX:-32}"
PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX="${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX:-128}"
PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE="${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE:-false}"
PERF_PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${PERF_PRODUCTION_ACCEPTANCE_RECEIPT_JSON:-}"
PERF_PRODUCTION_ACCEPTANCE_PACKAGE_FILE="${PERF_PRODUCTION_ACCEPTANCE_PACKAGE_FILE:-}"
PERF_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS="${PERF_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS:-86400}"
PERF_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS="${PERF_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS:-300}"
PERF_PRODUCTION_GATE_JSON="${PERF_PRODUCTION_GATE_JSON:-/var/lib/imserver/performance/production-gate.json}"
PERF_PRODUCTION_GATE_PROFILE="${PERF_PRODUCTION_GATE_PROFILE:-normal-product-baseline}"
PERF_PRODUCTION_GATE_MAX_AGE_SECONDS="${PERF_PRODUCTION_GATE_MAX_AGE_SECONDS:-604800}"
PERF_PRODUCTION_GATE_REQUIRE_CURRENT_GIT="${PERF_PRODUCTION_GATE_REQUIRE_CURRENT_GIT:-false}"
PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT="${PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT:-false}"
PERF_PRODUCTION_GATE_EXPECT_BASE_URL="${PERF_PRODUCTION_GATE_EXPECT_BASE_URL:-}"
PERF_PRODUCTION_GATE_EXPECT_TCP_HOST="${PERF_PRODUCTION_GATE_EXPECT_TCP_HOST:-}"
PERF_PRODUCTION_GATE_EXPECT_TCP_PORT="${PERF_PRODUCTION_GATE_EXPECT_TCP_PORT:-}"
PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET="${PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET:-}"
PERF_PRODUCTION_PROFILE_CATALOG="${PERF_PRODUCTION_PROFILE_CATALOG:-${SCRIPT_DIR}/../../IMServer/LoadTests/perf_production_profiles.json}"
PERF_EVIDENCE_VERIFY_SELF_TEST="${PERF_EVIDENCE_VERIFY_SELF_TEST:-false}"
IMSERVER_ETC_DIR="${IMSERVER_ETC_DIR:-/etc/imserver}"
PRODUCTION_ACCEPTANCE_RECEIPT_FILE_NAME="production-acceptance.json"
PRODUCTION_ACCEPTANCE_PACKAGE_FILE_NAME="production-acceptance-package.tar.gz"
PERF_PRODUCTION_ACCEPTANCE_RECEIPT_JSON_EFFECTIVE=""
PERF_PRODUCTION_ACCEPTANCE_PACKAGE_FILE_EFFECTIVE=""

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

read_env_file_value() {
  local file="$1"
  local key="$2"
  [[ -f "${file}" ]] || return 0
  awk -F= -v key="${key}" '
    $1 == key {
      value = substr($0, length(key) + 2)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      gsub(/^["'\'']|["'\'']$/, "", value)
      found = value
    }
    END {
      if (found != "") {
        print found
      }
    }
  ' "${file}"
}

evidence_verify_env_value() {
  local key="$1"
  local env_file="${ENV_FILE:-${IMSERVER_ETC_DIR}/common.env}"
  local value="${!key:-}"
  if [[ -n "${value}" ]]; then
    printf '%s\n' "${value}"
    return 0
  fi
  read_env_file_value "${env_file}" "${key}"
}

evidence_verify_host_from_url() {
  local url="$1"
  [[ -n "${url}" ]] || return 0
  python3 - "${url}" <<'PY'
import sys
from urllib.parse import urlsplit

print(urlsplit(sys.argv[1]).hostname or "")
PY
}

resolve_evidence_verify_expect_base_url() {
  if [[ -n "${PERF_PRODUCTION_GATE_EXPECT_BASE_URL}" ]]; then
    printf '%s\n' "${PERF_PRODUCTION_GATE_EXPECT_BASE_URL}"
    return 0
  fi
  local value
  value="$(evidence_verify_env_value "PUBLIC_BASE_URL")"
  if [[ -z "${value}" ]]; then
    value="$(evidence_verify_env_value "IM_PUBLIC_BASE_URL")"
  fi
  printf '%s\n' "${value}"
}

resolve_evidence_verify_expect_tcp_host() {
  if [[ -n "${PERF_PRODUCTION_GATE_EXPECT_TCP_HOST}" ]]; then
    printf '%s\n' "${PERF_PRODUCTION_GATE_EXPECT_TCP_HOST}"
    return 0
  fi
  local value
  value="$(evidence_verify_env_value "TCP_HOST")"
  if [[ -z "${value}" ]]; then
    value="$(evidence_verify_env_value "IM_PUBLIC_HOST")"
  fi
  if [[ -z "${value}" ]]; then
    value="$(evidence_verify_host_from_url "$(resolve_evidence_verify_expect_base_url)")"
  fi
  printf '%s\n' "${value}"
}

resolve_evidence_verify_expect_tcp_port() {
  if [[ -n "${PERF_PRODUCTION_GATE_EXPECT_TCP_PORT}" ]]; then
    printf '%s\n' "${PERF_PRODUCTION_GATE_EXPECT_TCP_PORT}"
    return 0
  fi
  local value
  value="$(evidence_verify_env_value "TCP_PORT")"
  if [[ -z "${value}" ]]; then
    value="$(evidence_verify_env_value "IM_TCP_PORT")"
  fi
  printf '%s\n' "${value:-9000}"
}

checksum_verify() {
  local dir="$1"
  if [[ ! -f "${dir}/SHA256SUMS" ]]; then
    printf 'performance_evidence result=fail reason=checksums_missing dir=%s\n' "${dir}" >&2
    return 1
  fi
  python3 - "${dir}" <<'PY'
import re
import sys
from pathlib import Path, PurePosixPath

root = Path(sys.argv[1])
checksum_path = root / "SHA256SUMS"
line_re = re.compile(r"^[0-9A-Fa-f]{64} [ *](.+)$")
checked = set()
unsigned_sidecars = {
    "production-acceptance.json",
    "production-acceptance-package.tar.gz",
}

def local_metadata_name(name):
    base = PurePosixPath(name).name
    return base.startswith("._") or base == ".DS_Store"

for lineno, raw in enumerate(checksum_path.read_text(encoding="utf-8", errors="replace").splitlines(), start=1):
    if not raw:
        continue
    if raw.startswith("\\"):
        raise SystemExit(
            "performance_evidence result=fail "
            f"reason=checksum_escaped_path_unsupported line={lineno}"
        )
    match = line_re.match(raw)
    if not match:
        raise SystemExit(
            "performance_evidence result=fail "
            f"reason=checksum_line_invalid line={lineno}"
        )
    name = match.group(1)
    normalized = name[2:] if name.startswith("./") else name
    path = PurePosixPath(normalized)
    if (
        not normalized
        or normalized == "."
        or path.is_absolute()
        or ".." in path.parts
        or "/" in normalized
        or normalized == "SHA256SUMS"
        or local_metadata_name(normalized)
    ):
        raise SystemExit(
            "performance_evidence result=fail "
            f"reason=checksum_path_unsafe line={lineno} path={name}"
        )
    if not (root / normalized).is_file():
        raise SystemExit(
            "performance_evidence result=fail "
            f"reason=checksum_file_missing line={lineno} path={name}"
        )
    if normalized in checked:
        raise SystemExit(
            "performance_evidence result=fail "
            f"reason=checksum_duplicate_path path={normalized}"
        )
    checked.add(normalized)
expected = {
    path.name
    for path in root.iterdir()
    if path.is_file() and path.name != "SHA256SUMS" and path.name not in unsigned_sidecars
}
missing = sorted(expected - checked)
if missing:
    raise SystemExit(
        "performance_evidence result=fail "
        f"reason=checksum_member_missing path={missing[0]}"
    )
PY
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "${dir}" && sha256sum -c SHA256SUMS >/dev/null)
  else
    (cd "${dir}" && shasum -a 256 -c SHA256SUMS >/dev/null)
  fi
}

require_file() {
  local path="$1"
  local reason="$2"
  if [[ ! -f "${path}" ]]; then
    printf 'performance_evidence result=fail reason=%s path=%s\n' "${reason}" "${path}" >&2
    return 1
  fi
}

validate_evidence_tree() {
  local dir="$1"
  local unsafe_path
  unsafe_path="$(find "${dir}" ! -type f ! -type d -print -quit)"
  if [[ -n "${unsafe_path}" ]]; then
    printf 'performance_evidence result=fail reason=unsafe_evidence_file path=%s\n' "${unsafe_path}" >&2
    return 1
  fi
  unsafe_path="$(find "${dir}" \( -name '._*' -o -name '.DS_Store' \) -print -quit)"
  if [[ -n "${unsafe_path}" ]]; then
    printf 'performance_evidence result=fail reason=local_metadata_file path=%s\n' "${unsafe_path}" >&2
    return 1
  fi
}

require_product_plan_pass() {
  local path="$1"
  python3 - "${path}" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)
status = str(payload.get("finalStatus") or "")
if status != "PASS":
    reason = payload.get("reason") or "-"
    raise SystemExit(
        "performance_evidence result=fail "
        f"reason=product_plan_not_pass path={path} status={status or '-'} runReason={reason}"
    )
PY
}

verify_prereq_not_blocked() {
  local prereq_json="$1"
  python3 - "${prereq_json}" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)
summary = payload.get("summary") or {}
status = str(summary.get("overallStatus") or "")
if status == "BLOCKED":
    missing = summary.get("missingRequiredCount")
    raise SystemExit(
        "performance_evidence result=fail "
        f"reason=profile_prereq_blocked path={path} missingRequired={missing}"
    )
PY
}

verify_profile_artifact_consistency() {
  local gate_json="$1"
  local profile_run_json="$2"
  local profile_plan_json="$3"
  local prereq_plan_json="$4"
  local prereq_audit_json="$5"
  local scenario_catalog_json="$6"
  python3 "${SCRIPT_DIR}/../../IMServer/LoadTests/perf_profile_artifacts_verify.py" \
    --gate-json "${gate_json}" \
    --profile-run-json "${profile_run_json}" \
    --profile-plan-json "${profile_plan_json}" \
    --profile-runbook-json "${profile_run_json%production-profile-run.json}production-profile-runbook.json" \
    --profile-runbook-md "${profile_run_json%production-profile-run.json}production-profile-runbook.md" \
    --prereq-plan-json "${prereq_plan_json}" \
    --prereq-audit-json "${prereq_audit_json}" \
    --scenario-catalog-json "${scenario_catalog_json}" >/dev/null
}

verify_product_plan_artifact_consistency() {
  local evidence_dir="$1"
  if [[ ! -f "${evidence_dir}/product-test-plan-run.json" ]]; then
    if bool_enabled "${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS}"; then
      printf 'performance_evidence result=fail reason=product_plan_run_missing path=%s\n' "${evidence_dir}/product-test-plan-run.json" >&2
      return 1
    fi
    return 0
  fi
  require_product_plan_pass "${evidence_dir}/product-test-plan-run.json" || return 1
  require_file "${evidence_dir}/product-test-plan-preview.json" "product_plan_preview_missing" || return 1
  require_file "${evidence_dir}/product-test-plan-phases.tsv" "product_plan_phases_missing" || return 1
  require_file "${evidence_dir}/product-test-prereq-plan.json" "product_plan_prereq_plan_missing" || return 1
  require_file "${evidence_dir}/product-test-prereq-audit.json" "product_plan_prereq_audit_missing" || return 1
  require_file "${evidence_dir}/product-test-prereq-audit.md" "product_plan_prereq_audit_md_missing" || return 1
  require_file "${evidence_dir}/product-test-scenario-catalog.json" "product_plan_scenario_catalog_missing" || return 1
  require_file "${evidence_dir}/product-test-runbook.json" "product_plan_runbook_json_missing" || return 1
  require_file "${evidence_dir}/product-test-runbook.md" "product_plan_runbook_md_missing" || return 1
  python3 "${SCRIPT_DIR}/../../IMServer/LoadTests/perf_product_plan_artifacts_verify.py" \
    --product-run-json "${evidence_dir}/product-test-plan-run.json" \
    --plan-preview-json "${evidence_dir}/product-test-plan-preview.json" \
    --phases-tsv "${evidence_dir}/product-test-plan-phases.tsv" \
    --prereq-plan-json "${evidence_dir}/product-test-prereq-plan.json" \
    --prereq-audit-json "${evidence_dir}/product-test-prereq-audit.json" \
    --prereq-audit-md "${evidence_dir}/product-test-prereq-audit.md" \
    --scenario-catalog-json "${evidence_dir}/product-test-scenario-catalog.json" \
    --runbook-json "${evidence_dir}/product-test-runbook.json" \
    --runbook-md "${evidence_dir}/product-test-runbook.md" \
    --require-pass >/dev/null
}

verify_product_campaign_artifact_consistency() {
  local evidence_dir="$1"
  local verify_args=(--require-pass)
  if [[ ! -f "${evidence_dir}/product-campaign-run.json" ]]; then
    if bool_enabled "${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS}"; then
      printf 'performance_evidence result=fail reason=product_campaign_run_missing path=%s\n' "${evidence_dir}/product-campaign-run.json" >&2
      return 1
    fi
    return 0
  fi
  require_file "${evidence_dir}/product-campaign-runbook.md" "product_campaign_runbook_missing" || return 1
  if bool_enabled "${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS}"; then
    verify_args+=(--require-production-gate-campaign)
  fi
  python3 "${SCRIPT_DIR}/../../IMServer/LoadTests/perf_product_campaign_artifacts_verify.py" \
    --campaign-run-json "${evidence_dir}/product-campaign-run.json" \
    --runbook "${evidence_dir}/product-campaign-runbook.md" \
    --require-portable-stage-logs \
    "${verify_args[@]}" >/dev/null
}

verify_current_readiness_artifact_consistency() {
  local evidence_dir="$1"
  local expect_base_url="${2:-}"
  local expect_tcp_host="${3:-}"
  local expect_tcp_port="${4:-}"
  if [[ -z "${expect_base_url}" ]]; then
    expect_base_url="$(resolve_evidence_verify_expect_base_url)"
  fi
  if [[ -z "${expect_tcp_host}" ]]; then
    expect_tcp_host="$(resolve_evidence_verify_expect_tcp_host)"
  fi
  if [[ -z "${expect_tcp_port}" ]]; then
    expect_tcp_port="$(resolve_evidence_verify_expect_tcp_port)"
  fi
  if [[ ! -f "${evidence_dir}/current-production-readiness.json" ]]; then
    if bool_enabled "${PERF_PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS}"; then
      printf 'performance_evidence result=fail reason=current_readiness_missing path=%s\n' "${evidence_dir}/current-production-readiness.json" >&2
      return 1
    fi
    return 0
  fi
  require_file "${evidence_dir}/current-production-readiness.md" "current_readiness_md_missing" || return 1
  python3 "${SCRIPT_DIR}/../../IMServer/LoadTests/perf_current_production_readiness_verify.py" \
    --readiness-json "${evidence_dir}/current-production-readiness.json" \
    --expect-base-url "${expect_base_url}" \
    --expect-tcp-host "${expect_tcp_host}" \
    --expect-tcp-port "${expect_tcp_port}" >/dev/null || return 1
  if bool_enabled "${PERF_PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS}"; then
    python3 - \
      "${evidence_dir}/current-production-readiness.json" \
      "${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS}" \
      "${PERF_PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP}" <<'PY'
import json
import sys

path, require_product_suite_raw, require_cloud_security_group_raw = sys.argv[1:4]
require_product_suite = require_product_suite_raw.lower() in {"1", "true", "yes", "on"}
require_cloud_security_group = require_cloud_security_group_raw.lower() in {"1", "true", "yes", "on"}
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)
requested = payload.get("requestedRuns") or {}
runs = payload.get("runs") or {}
policy = payload.get("evidencePolicy") or {}
if require_cloud_security_group:
    try:
        rules_max_age_seconds = int(policy.get("cloudSecurityGroupRulesMaxAgeSeconds") or 0)
    except Exception:
        rules_max_age_seconds = 0
    if rules_max_age_seconds <= 0:
        raise SystemExit(
            "performance_evidence result=fail "
            f"reason=current_readiness_cloud_security_group_rules_max_age_invalid value={rules_max_age_seconds} path={path}"
        )
    if policy.get("cloudSecurityGroupRulesRequireRootOwner") is not True:
        raise SystemExit(
            "performance_evidence result=fail "
            f"reason=current_readiness_cloud_security_group_rules_root_owner_missing path={path}"
        )
requirements = [
    ("smoke", "smokeExitCode"),
    ("baseline", "baselineExitCode"),
    ("fullAcceptance", "fullAcceptanceExitCode"),
]
if require_product_suite:
    requirements.insert(1, ("productScenarioSuite", "suiteExitCode"))
for requested_key, exit_key in requirements:
    if requested.get(requested_key) is not True:
        raise SystemExit(
            "performance_evidence result=fail "
            f"reason=current_readiness_required_run_missing run={requested_key} path={path}"
        )
    if runs.get(exit_key) != 0:
        raise SystemExit(
            "performance_evidence result=fail "
            f"reason=current_readiness_required_run_not_pass run={requested_key} exitCode={runs.get(exit_key)} path={path}"
        )
PY
  fi
}

verify_no_secret_material() {
  local evidence_dir="$1"
  python3 "${SCRIPT_DIR}/../../IMServer/LoadTests/perf_secret_scan.py" \
    --root "${evidence_dir}" >/dev/null || {
    printf 'performance_evidence result=fail reason=secret_scan_failed dir=%s\n' "${evidence_dir}" >&2
    return 1
  }
}

verify_production_acceptance_receipt() {
  local evidence_dir="${1:-}"
  local receipt_file="${PERF_PRODUCTION_ACCEPTANCE_RECEIPT_JSON}"
  local package_file="${PERF_PRODUCTION_ACCEPTANCE_PACKAGE_FILE}"
  if bool_enabled "${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE}" && [[ -n "${evidence_dir}" ]]; then
    receipt_file="${evidence_dir}/${PRODUCTION_ACCEPTANCE_RECEIPT_FILE_NAME}"
    package_file="${evidence_dir}/${PRODUCTION_ACCEPTANCE_PACKAGE_FILE_NAME}"
  else
    if [[ -z "${receipt_file}" && -n "${evidence_dir}" && -f "${evidence_dir}/${PRODUCTION_ACCEPTANCE_RECEIPT_FILE_NAME}" ]]; then
      receipt_file="${evidence_dir}/${PRODUCTION_ACCEPTANCE_RECEIPT_FILE_NAME}"
    fi
    if [[ -z "${package_file}" && -n "${evidence_dir}" && -f "${evidence_dir}/${PRODUCTION_ACCEPTANCE_PACKAGE_FILE_NAME}" ]]; then
      package_file="${evidence_dir}/${PRODUCTION_ACCEPTANCE_PACKAGE_FILE_NAME}"
    fi
  fi
  PERF_PRODUCTION_ACCEPTANCE_RECEIPT_JSON_EFFECTIVE="${receipt_file}"
  PERF_PRODUCTION_ACCEPTANCE_PACKAGE_FILE_EFFECTIVE="${package_file}"

  if [[ -z "${receipt_file}" ]]; then
    if bool_enabled "${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE}"; then
      printf 'performance_evidence result=fail reason=production_acceptance_receipt_required\n' >&2
      return 1
    fi
    return 0
  fi
  require_file "${receipt_file}" "production_acceptance_receipt_missing" || return 1
  if [[ -z "${package_file}" ]] && bool_enabled "${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE}"; then
    printf 'performance_evidence result=fail reason=production_acceptance_package_required\n' >&2
    return 1
  fi
  local args=(
    --receipt-json "${receipt_file}"
    --max-age-seconds "${PERF_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS}"
    --max-future-skew-seconds "${PERF_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS}"
    --require-pass
  )
  if [[ -n "${evidence_dir}" ]]; then
    args+=(--evidence-dir "${evidence_dir}")
  fi
  if [[ -n "${package_file}" ]]; then
    require_file "${package_file}" "production_acceptance_package_missing" || return 1
    args+=(--package-file "${package_file}")
  fi
  python3 "${SCRIPT_DIR}/../../IMServer/LoadTests/perf_production_acceptance_verify.py" \
    "${args[@]}" >/dev/null || return 1
}

verify_manifest_policy_requirements() {
  local evidence_dir="$1"
  local require_cloud_security_group_repair_receipt="${PERF_PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT}"
  if [[ -z "${require_cloud_security_group_repair_receipt}" ]]; then
    require_cloud_security_group_repair_receipt="${PERF_PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP}"
  fi
  python3 - \
    "${evidence_dir}/production-evidence-manifest.json" \
    "${PERF_PRODUCTION_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS}" \
    "${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS}" \
    "${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS}" \
    "${PERF_PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS}" \
    "${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS}" \
    "${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP}" \
    "${PERF_PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP}" \
    "${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080}" \
    "${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS}" \
    "${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER}" \
    "${require_cloud_security_group_repair_receipt}" \
    "${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID}" \
    "${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID}" \
    "${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR}" <<'PY'
import json
import sys

manifest_path, require_profile, require_product_plan, require_product_campaign, require_current_readiness, require_product_suite, require_product_suite_no_large_group, require_cloud_security_group, allow_temp_http_8080, rules_max_age_seconds, rules_require_root_owner, require_cloud_security_group_repair_receipt, expect_security_group_id, expect_region_id, expect_admin_cidr = sys.argv[1:16]

def enabled(value: str) -> bool:
    return value.lower() in {"1", "true", "yes", "on"}

with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)
policy = manifest.get("policy") or {}
requirements = [
    ("requireProfileArtifacts", require_profile),
    ("requireProductPlanArtifacts", require_product_plan),
    ("requireProductCampaignArtifacts", require_product_campaign),
    ("requireCurrentReadinessArtifacts", require_current_readiness),
    ("requireProductScenarioSuiteArtifacts", require_product_suite),
    ("requireProductScenarioSuiteNoLargeGroup", require_product_suite_no_large_group),
    ("requireCloudSecurityGroup", require_cloud_security_group),
    ("requireCloudSecurityGroupRepairReceipt", require_cloud_security_group_repair_receipt),
]
for key, expected in requirements:
    if enabled(expected) and policy.get(key) is not True:
        actual = policy.get(key, None)
        raise SystemExit(
            "performance_evidence result=fail "
            f"reason=manifest_policy_requirement_mismatch key={key} expected=true actual={actual}"
        )
if enabled(require_cloud_security_group):
    expected_temp_http = enabled(allow_temp_http_8080)
    if policy.get("allowTempHTTP8080") is not expected_temp_http:
        raise SystemExit(
            "performance_evidence result=fail "
            "reason=manifest_policy_requirement_mismatch "
            f"key=allowTempHTTP8080 expected={str(expected_temp_http).lower()} actual={policy.get('allowTempHTTP8080')}"
        )
    try:
        expected_max_age = int(rules_max_age_seconds)
    except Exception:
        expected_max_age = 0
    if expected_max_age <= 0 or policy.get("cloudSecurityGroupRulesMaxAgeSeconds") != expected_max_age:
        raise SystemExit(
            "performance_evidence result=fail "
            "reason=manifest_policy_requirement_mismatch "
            f"key=cloudSecurityGroupRulesMaxAgeSeconds expected={expected_max_age} actual={policy.get('cloudSecurityGroupRulesMaxAgeSeconds')}"
        )
    expected_root_owner = enabled(rules_require_root_owner)
    if not expected_root_owner or policy.get("cloudSecurityGroupRulesRequireRootOwner") is not True:
        raise SystemExit(
            "performance_evidence result=fail "
            "reason=manifest_policy_requirement_mismatch "
            f"key=cloudSecurityGroupRulesRequireRootOwner expected=true actual={policy.get('cloudSecurityGroupRulesRequireRootOwner')}"
        )
if enabled(require_cloud_security_group_repair_receipt):
    expected_text = [
        ("cloudSecurityGroupRepairReceiptExpectSecurityGroupID", expect_security_group_id),
        ("cloudSecurityGroupRepairReceiptExpectRegionID", expect_region_id),
        ("cloudSecurityGroupRepairReceiptExpectAdminCIDR", expect_admin_cidr),
    ]
    for key, expected in expected_text:
        if not expected:
            raise SystemExit(
                "performance_evidence result=fail "
                f"reason=manifest_policy_requirement_missing key={key}"
            )
        actual = policy.get(key)
        if actual != expected:
            raise SystemExit(
                "performance_evidence result=fail "
                f"reason=manifest_policy_requirement_mismatch key={key} expected={expected} actual={actual}"
            )
PY
}

verify_cloud_security_group_snapshot() {
  local evidence_dir="$1"
  local snapshot="${evidence_dir}/cloud-security-group.json"
  if ! bool_enabled "${PERF_PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP}"; then
    return 0
  fi
  require_file "${snapshot}" "cloud_security_group_missing" || return 1
  CLOUD_SECURITY_GROUP_RULES_FILE="${snapshot}" \
    CLOUD_SECURITY_GROUP_PROFILE=production \
    CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS="${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS}" \
    CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS="${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS}" \
    CLOUD_SECURITY_GROUP_ADMIN_PORTS="${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ADMIN_PORTS}" \
    CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS="${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS}" \
    CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS=0 \
    CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER=false \
    CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080="${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080}" \
    CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP="${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP}" \
    CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX="${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX}" \
    CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX="${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX}" \
    CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX="${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX}" \
    CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX="${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX}" \
    bash "${SCRIPT_DIR}/26_audit_cloud_security_group.sh" >/dev/null
}

verify_cloud_security_group_repair_receipt() {
  local evidence_dir="$1"
  local receipt="${evidence_dir}/cloud-security-group-repair-receipt.json"
  local require_receipt="${PERF_PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT}"
  if [[ -z "${require_receipt}" ]]; then
    require_receipt="${PERF_PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP}"
  fi
  if ! bool_enabled "${require_receipt}"; then
    return 0
  fi
  require_file "${receipt}" "cloud_security_group_repair_receipt_missing" || return 1
  ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${receipt}" \
    ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_REQUIRE_APPLIED=true \
    ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_REQUIRE_VERIFIED=true \
    ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS="${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS}" \
    ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID="${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID}" \
    ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID="${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID}" \
    ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR="${PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR}" \
    bash "${SCRIPT_DIR}/31_verify_aliyun_security_group_repair_receipt.sh" >/dev/null
}

evidence_summary_fields() {
  local evidence_dir="$1"
  python3 - "${evidence_dir}/docs-audit.json" "${evidence_dir}/validation-inventory.json" "${evidence_dir}/production-evidence-manifest.json" <<'PY'
import json
import sys
from pathlib import Path

docs_path, inventory_path, manifest_path = sys.argv[1:4]
evidence_dir = Path(docs_path).parent
with open(docs_path, encoding="utf-8") as handle:
    docs = json.load(handle)
with open(inventory_path, encoding="utf-8") as handle:
    inventory = json.load(handle)
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)
summary = inventory.get("summary") or {}
policy = manifest.get("policy") or {}
policy_profile = str(policy.get("requireProfileArtifacts") is True).lower()
policy_product_plan = str(policy.get("requireProductPlanArtifacts") is True).lower()
policy_product_campaign = str(policy.get("requireProductCampaignArtifacts") is True).lower()
policy_current_readiness = str(policy.get("requireCurrentReadinessArtifacts") is True).lower()
policy_product_suite = str(policy.get("requireProductScenarioSuiteArtifacts") is True).lower()
policy_product_suite_no_large_group = str(policy.get("requireProductScenarioSuiteNoLargeGroup") is True).lower()
policy_cloud_security_group = str(policy.get("requireCloudSecurityGroup") is True).lower()
policy_cloud_security_group_repair_receipt = str(policy.get("requireCloudSecurityGroupRepairReceipt") is True).lower()
product_profile_gate = manifest.get("productProfileGate") or {}
product_profile_gate_status = product_profile_gate.get("status") or "-"
product_profile_gate_checked = product_profile_gate.get("profileCount", "-")
product_profile_gate_required_domains = len(product_profile_gate.get("requiredDomains") or []) if product_profile_gate else "-"
profile_status = "-"
profile_blocker_type = "-"
profile_entrypoint_diagnosis = "-"
profile_entrypoint_blocker = "-,-,-,-"
profile_entrypoint_tcp_status = "-"
profile_entrypoint_edge_intercept = "-"
profile_entrypoint_protocol_count = "-"
profile = manifest.get("productionProfile") or {}
profile_entrypoint = profile.get("entrypointProbe") or {}
if profile_entrypoint:
    profile_entrypoint_diagnosis = profile_entrypoint.get("diagnosis") or "-"
    profile_entrypoint_tcp_status = profile_entrypoint.get("tcpStatus") or (profile_entrypoint.get("signals") or {}).get("tcpStatus") or "-"
    profile_entrypoint_edge_intercept = profile_entrypoint.get("edgeIntercept") or (profile_entrypoint.get("signals") or {}).get("edgeIntercept") or "-"
    profile_entrypoint_protocols = profile_entrypoint.get("portProtocols") or (profile_entrypoint.get("signals") or {}).get("portProtocols") or []
    profile_entrypoint_protocol_count = len(profile_entrypoint_protocols) if isinstance(profile_entrypoint_protocols, list) else "-"
    profile_entrypoint_blocker_payload = profile_entrypoint.get("blocker") or {}
    profile_entrypoint_prevents = profile_entrypoint_blocker_payload.get("preventsPerformanceEvidence", "-")
    if isinstance(profile_entrypoint_prevents, bool):
        profile_entrypoint_prevents = str(profile_entrypoint_prevents).lower()
    elif profile_entrypoint_prevents == "":
        profile_entrypoint_prevents = "-"
    profile_entrypoint_blocker = "{},{},{},{}".format(
        profile_entrypoint_blocker_payload.get("type") or "-",
        profile_entrypoint_blocker_payload.get("severity") or "-",
        profile_entrypoint_prevents,
        profile_entrypoint_blocker_payload.get("action") or "-",
    )
profile_path = evidence_dir / "production-profile-run.json"
if profile_path.exists():
    with profile_path.open(encoding="utf-8") as handle:
        profile_run = json.load(handle)
        profile_status = profile_run.get("finalStatus") or "-"
        profile_blocker_type = profile_run.get("blockerType") or "-"
product_status = "-"
product_blocker_type = "-"
product_scenario_count = "-"
product_large_group_included = "-"
product_domain_count = "-"
product_required_domains_covered = "-"
product_path = evidence_dir / "product-test-plan-run.json"
if product_path.exists():
    with product_path.open(encoding="utf-8") as handle:
        product_run = json.load(handle)
        product_status = product_run.get("finalStatus") or "-"
        product_blocker_type = product_run.get("blockerType") or "-"
product_preview_path = evidence_dir / "product-test-plan-preview.json"
if product_preview_path.exists():
    with product_preview_path.open(encoding="utf-8") as handle:
        product_preview = json.load(handle)
        product_preview_summary = product_preview.get("summary") or {}
        if "uniqueScenarioCount" in product_preview_summary:
            product_scenario_count = product_preview_summary.get("uniqueScenarioCount", "-")
        if "largeGroupIncluded" in product_preview_summary:
            product_large_group_included = str(bool(product_preview_summary.get("largeGroupIncluded"))).lower()
        if isinstance(product_preview_summary.get("coveredProductDomains"), list):
            product_domain_count = len(product_preview_summary.get("coveredProductDomains") or [])
        if "requiredProductDomainsCovered" in product_preview_summary:
            product_required_domains_covered = str(bool(product_preview_summary.get("requiredProductDomainsCovered"))).lower()
campaign_name = "-"
campaign_status = "-"
campaign_required_failures = "-"
campaign_failures = "-"
campaign_attempted = "-"
campaign_skipped = "-"
campaign_target = "-,-,-"
campaign_path = evidence_dir / "product-campaign-run.json"
if campaign_path.exists():
    with campaign_path.open(encoding="utf-8") as handle:
        campaign_run = json.load(handle)
        campaign_target_payload = campaign_run.get("target") or {}
        campaign_name = campaign_run.get("campaign") or "-"
        campaign_status = campaign_run.get("finalStatus") or "-"
        campaign_failures = campaign_run.get("failureCount", "-")
        campaign_required_failures = campaign_run.get("requiredFailureCount", "-")
        campaign_attempted = campaign_run.get("attemptedStageCount", "-")
        campaign_skipped = campaign_run.get("skippedStageCount", "-")
        campaign_target = "{},{},{}".format(
            campaign_target_payload.get("baseURL") or "-",
            campaign_target_payload.get("tcpHost") or "-",
            campaign_target_payload.get("tcpPort") or "-",
        )
current_readiness_status = "-"
current_readiness_reason = "-"
current_readiness_requested_smoke = "-"
current_readiness_requested_suite = "-"
current_readiness_requested_baseline = "-"
current_readiness_requested_full = "-"
current_readiness_suite_expected = "-"
current_readiness_full_expected_campaign = "-"
current_readiness_smoke_exit = "-"
current_readiness_suite_exit = "-"
current_readiness_baseline_exit = "-"
current_readiness_full_exit = "-"
current_readiness_suite_name = "-"
current_readiness_suite_status = "-"
current_readiness_suite_scenarios = "-"
current_readiness_suite_large_group = "-"
current_readiness_full_campaign = "-"
current_readiness_full_status = "-"
current_readiness_full_failures = "-"
current_readiness_full_required_failures = "-"
current_readiness_full_attempted = "-"
current_readiness_full_skipped = "-"
current_readiness_path = evidence_dir / "current-production-readiness.json"
if current_readiness_path.exists():
    with current_readiness_path.open(encoding="utf-8") as handle:
        current_readiness = json.load(handle)
        requested = current_readiness.get("requestedRuns") or {}
        runs = current_readiness.get("runs") or {}
        current_readiness_status = current_readiness.get("status") or "-"
        current_readiness_reason = current_readiness.get("reason") or "-"
        current_readiness_requested_smoke = str(requested.get("smoke")).lower()
        current_readiness_requested_suite = str(requested.get("productScenarioSuite")).lower()
        current_readiness_requested_baseline = str(requested.get("baseline")).lower()
        current_readiness_requested_full = str(requested.get("fullAcceptance")).lower()
        current_readiness_suite_expected = requested.get("productScenarioSuiteName") or "-"
        current_readiness_full_expected_campaign = requested.get("fullAcceptanceCampaign") or "-"
        current_readiness_smoke_exit = runs.get("smokeExitCode", "-")
        current_readiness_suite_exit = runs.get("suiteExitCode", "-")
        current_readiness_baseline_exit = runs.get("baselineExitCode", "-")
        current_readiness_full_exit = runs.get("fullAcceptanceExitCode", "-")
current_suite_path = evidence_dir / "product-scenario-suite-run.json"
if current_suite_path.exists():
    with current_suite_path.open(encoding="utf-8") as handle:
        current_suite = json.load(handle)
        current_suite_coverage = current_suite.get("coverageSummary") or {}
        current_readiness_suite_name = current_suite.get("suite") or "-"
        current_readiness_suite_status = current_suite.get("status") or "-"
        current_readiness_suite_scenarios = current_suite_coverage.get("uniqueScenarioCount", "-")
        current_readiness_suite_large_group = current_suite_coverage.get("largeGroupIncluded", "-")
current_full_path = evidence_dir / "current-readiness-full-acceptance-run.json"
if current_full_path.exists():
    with current_full_path.open(encoding="utf-8") as handle:
        current_full = json.load(handle)
        current_readiness_full_campaign = current_full.get("campaign") or "-"
        current_readiness_full_status = current_full.get("finalStatus") or "-"
        current_readiness_full_failures = current_full.get("failureCount", "-")
        current_readiness_full_required_failures = current_full.get("requiredFailureCount", "-")
        current_readiness_full_attempted = current_full.get("attemptedStageCount", "-")
        current_readiness_full_skipped = current_full.get("skippedStageCount", "-")
print(
    "docsAudit={docs_status} docsGroups={docs_presets}/{docs_listed} "
    "docsErrors={docs_errors} inventoryDocs={inventory_docs} "
    "manifestRequireProfileArtifacts={policy_profile} "
    "manifestRequireProductPlanArtifacts={policy_product_plan} "
    "manifestRequireProductCampaignArtifacts={policy_product_campaign} "
    "manifestRequireCurrentReadinessArtifacts={policy_current_readiness} "
    "manifestRequireProductScenarioSuiteArtifacts={policy_product_suite} "
    "manifestRequireProductScenarioSuiteNoLargeGroup={policy_product_suite_no_large_group} "
    "manifestRequireCloudSecurityGroup={policy_cloud_security_group} "
    "manifestRequireCloudSecurityGroupRepairReceipt={policy_cloud_security_group_repair_receipt} "
    "productProfileGate={product_profile_gate_status} "
    "productProfileGateChecked={product_profile_gate_checked} "
    "productProfileGateRequiredDomains={product_profile_gate_required_domains} "
    "profileRunStatus={profile_status} profileRunBlockerType={profile_blocker_type} "
    "profileEntrypointDiagnosis={profile_entrypoint_diagnosis} "
    "profileEntrypointTcpStatus={profile_entrypoint_tcp_status} "
    "profileEntrypointEdgeIntercept={profile_entrypoint_edge_intercept} "
    "profileEntrypointPortProtocols={profile_entrypoint_protocol_count} "
    "profileEntrypointBlocker={profile_entrypoint_blocker} "
    "productPlanStatus={product_status} productPlanBlockerType={product_blocker_type} "
    "productPlanScenarioCount={product_scenario_count} productPlanLargeGroupIncluded={product_large_group_included} "
    "productPlanDomainCount={product_domain_count} productPlanRequiredDomainsCovered={product_required_domains_covered} "
    "productCampaign={campaign_name} productCampaignStatus={campaign_status} "
    "productCampaignTarget={campaign_target} "
    "productCampaignFailures={campaign_failures} productCampaignRequiredFailures={campaign_required_failures} "
    "productCampaignAttempted={campaign_attempted} productCampaignSkipped={campaign_skipped} "
    "currentReadinessStatus={current_readiness_status} currentReadinessReason={current_readiness_reason} "
    "currentReadinessRequestedSmoke={current_readiness_requested_smoke} "
    "currentReadinessRequestedProductScenarioSuite={current_readiness_requested_suite} "
    "currentReadinessRequestedBaseline={current_readiness_requested_baseline} "
    "currentReadinessRequestedFullAcceptance={current_readiness_requested_full} "
    "currentReadinessSmokeExitCode={current_readiness_smoke_exit} "
    "currentReadinessProductScenarioSuiteExitCode={current_readiness_suite_exit} "
    "currentReadinessBaselineExitCode={current_readiness_baseline_exit} "
    "currentReadinessFullAcceptanceExitCode={current_readiness_full_exit} "
    "currentReadinessProductScenarioSuiteExpected={current_readiness_suite_expected} "
    "currentReadinessProductScenarioSuite={current_readiness_suite_name} "
    "currentReadinessProductScenarioSuiteStatus={current_readiness_suite_status} "
    "currentReadinessProductScenarioSuiteScenarios={current_readiness_suite_scenarios} "
    "currentReadinessProductScenarioSuiteLargeGroupIncluded={current_readiness_suite_large_group} "
    "currentReadinessFullAcceptanceExpectedCampaign={current_readiness_full_expected_campaign} "
    "currentReadinessFullAcceptanceCampaign={current_readiness_full_campaign} "
    "currentReadinessFullAcceptanceStatus={current_readiness_full_status} "
    "currentReadinessFullAcceptanceFailures={current_readiness_full_failures} "
    "currentReadinessFullAcceptanceRequiredFailures={current_readiness_full_required_failures} "
    "currentReadinessFullAcceptanceAttempted={current_readiness_full_attempted} "
    "currentReadinessFullAcceptanceSkipped={current_readiness_full_skipped}".format(
        docs_status=docs.get("status") or "UNKNOWN",
        docs_presets=docs.get("presetsGroupCount") or 0,
        docs_listed=docs.get("listedGroupCount") or 0,
        docs_errors=docs.get("errorCount") or 0,
        inventory_docs=summary.get("docs") or 0,
        policy_profile=policy_profile,
        policy_product_plan=policy_product_plan,
        policy_product_campaign=policy_product_campaign,
        policy_current_readiness=policy_current_readiness,
        policy_product_suite=policy_product_suite,
        policy_product_suite_no_large_group=policy_product_suite_no_large_group,
        policy_cloud_security_group=policy_cloud_security_group,
        policy_cloud_security_group_repair_receipt=policy_cloud_security_group_repair_receipt,
        product_profile_gate_status=product_profile_gate_status,
        product_profile_gate_checked=product_profile_gate_checked,
        product_profile_gate_required_domains=product_profile_gate_required_domains,
        profile_status=profile_status,
        profile_blocker_type=profile_blocker_type,
        profile_entrypoint_diagnosis=profile_entrypoint_diagnosis,
        profile_entrypoint_tcp_status=profile_entrypoint_tcp_status,
        profile_entrypoint_edge_intercept=profile_entrypoint_edge_intercept,
        profile_entrypoint_protocol_count=profile_entrypoint_protocol_count,
        profile_entrypoint_blocker=profile_entrypoint_blocker,
        product_status=product_status,
        product_blocker_type=product_blocker_type,
        product_scenario_count=product_scenario_count,
        product_large_group_included=product_large_group_included,
        product_domain_count=product_domain_count,
        product_required_domains_covered=product_required_domains_covered,
        campaign_name=campaign_name,
        campaign_status=campaign_status,
        campaign_target=campaign_target,
        campaign_failures=campaign_failures,
        campaign_required_failures=campaign_required_failures,
        campaign_attempted=campaign_attempted,
        campaign_skipped=campaign_skipped,
        current_readiness_status=current_readiness_status,
        current_readiness_reason=current_readiness_reason,
        current_readiness_requested_smoke=current_readiness_requested_smoke,
        current_readiness_requested_suite=current_readiness_requested_suite,
        current_readiness_requested_baseline=current_readiness_requested_baseline,
        current_readiness_requested_full=current_readiness_requested_full,
        current_readiness_suite_expected=current_readiness_suite_expected,
        current_readiness_full_expected_campaign=current_readiness_full_expected_campaign,
        current_readiness_smoke_exit=current_readiness_smoke_exit,
        current_readiness_suite_exit=current_readiness_suite_exit,
        current_readiness_baseline_exit=current_readiness_baseline_exit,
        current_readiness_full_exit=current_readiness_full_exit,
        current_readiness_suite_name=current_readiness_suite_name,
        current_readiness_suite_status=current_readiness_suite_status,
        current_readiness_suite_scenarios=current_readiness_suite_scenarios,
        current_readiness_suite_large_group=current_readiness_suite_large_group,
        current_readiness_full_campaign=current_readiness_full_campaign,
        current_readiness_full_status=current_readiness_full_status,
        current_readiness_full_failures=current_readiness_full_failures,
        current_readiness_full_required_failures=current_readiness_full_required_failures,
        current_readiness_full_attempted=current_readiness_full_attempted,
        current_readiness_full_skipped=current_readiness_full_skipped,
    )
)
PY
}

verify_evidence() {
  local current_path="$1"
  local evidence_dir gate_in_evidence
  local expect_base_url expect_tcp_host expect_tcp_port
  local gate_output

  if [[ ! -e "${current_path}" ]]; then
    printf 'performance_evidence result=fail reason=current_evidence_missing path=%s\n' "${current_path}" >&2
    return 1
  fi
  evidence_dir="$(cd "${current_path}" && pwd -P)"
  gate_in_evidence="${evidence_dir}/production-gate.json"

  validate_evidence_tree "${evidence_dir}" || return 1
  require_file "${gate_in_evidence}" "evidence_gate_missing" || return 1
  require_file "${PERF_PRODUCTION_GATE_JSON}" "installed_gate_missing" || return 1
  checksum_verify "${evidence_dir}" || return 1
  python3 "${SCRIPT_DIR}/../../IMServer/LoadTests/perf_evidence_manifest.py" \
    --dir "${evidence_dir}" --verify >/dev/null || return 1
  verify_manifest_policy_requirements "${evidence_dir}" || return 1
  verify_cloud_security_group_snapshot "${evidence_dir}" || return 1
  verify_cloud_security_group_repair_receipt "${evidence_dir}" || return 1
  verify_no_secret_material "${evidence_dir}" || return 1
  python3 "${SCRIPT_DIR}/../../IMServer/LoadTests/perf_docs_audit.py" \
    --verify-json "${evidence_dir}/docs-audit.json" \
    --verify-md "${evidence_dir}/docs-audit.md" \
    --readme "${SCRIPT_DIR}/../../IMServer/LoadTests/README.md" \
    --matrix-script "${SCRIPT_DIR}/../../IMServer/LoadTests/run_perf_scenarios.sh" \
    --profile-catalog "${evidence_dir}/perf_production_profiles.json" >/dev/null || return 1

  if ! cmp -s "${gate_in_evidence}" "${PERF_PRODUCTION_GATE_JSON}"; then
    printf 'performance_evidence result=fail reason=installed_gate_mismatch evidence=%s installed=%s\n' \
      "${gate_in_evidence}" \
      "${PERF_PRODUCTION_GATE_JSON}" >&2
    return 1
  fi
  expect_base_url="$(resolve_evidence_verify_expect_base_url)"
  expect_tcp_host="$(resolve_evidence_verify_expect_tcp_host)"
  expect_tcp_port="$(resolve_evidence_verify_expect_tcp_port)"

  if ! gate_output="$(
    PERF_PRODUCTION_GATE_JSON="${gate_in_evidence}" \
    PERF_PRODUCTION_GATE_PROFILE="${PERF_PRODUCTION_GATE_PROFILE}" \
    PERF_PRODUCTION_GATE_MAX_AGE_SECONDS="${PERF_PRODUCTION_GATE_MAX_AGE_SECONDS}" \
    PERF_PRODUCTION_GATE_REQUIRE_CURRENT_GIT="${PERF_PRODUCTION_GATE_REQUIRE_CURRENT_GIT}" \
    PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT="${PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT}" \
    PERF_PRODUCTION_GATE_EXPECT_BASE_URL="${expect_base_url}" \
    PERF_PRODUCTION_GATE_EXPECT_TCP_HOST="${expect_tcp_host}" \
    PERF_PRODUCTION_GATE_EXPECT_TCP_PORT="${expect_tcp_port}" \
    PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET="${PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET}" \
    PERF_PRODUCTION_PROFILE_CATALOG="${PERF_PRODUCTION_PROFILE_CATALOG}" \
    ENV_FILE="${ENV_FILE:-}" \
      bash "${SCRIPT_DIR}/67_verify_performance_gate.sh" 2>&1
  )"; then
    printf '%s\n' "${gate_output}" >&2
    return 1
  fi

  if bool_enabled "${PERF_PRODUCTION_EVIDENCE_REQUIRE_VALIDATION_INVENTORY}"; then
    require_file "${evidence_dir}/validation-inventory.json" "validation_inventory_missing" || return 1
    require_file "${evidence_dir}/validation-inventory.md" "validation_inventory_md_missing" || return 1
    python3 "${SCRIPT_DIR}/../../IMServer/LoadTests/perf_validation_inventory.py" \
      --verify-json "${evidence_dir}/validation-inventory.json" \
      --verify-md "${evidence_dir}/validation-inventory.md" \
      --gate-json "${gate_in_evidence}" >/dev/null || return 1
  fi

  if bool_enabled "${PERF_PRODUCTION_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS}"; then
    require_file "${evidence_dir}/production-profile-run.json" "profile_run_missing" || return 1
    require_file "${evidence_dir}/production-profile-plan.json" "profile_plan_missing" || return 1
    require_file "${evidence_dir}/production-profile-entrypoint-probe.log" "profile_entrypoint_probe_log_missing" || return 1
    require_file "${evidence_dir}/production-profile-entrypoint-probe.json" "profile_entrypoint_probe_json_missing" || return 1
    require_file "${evidence_dir}/production-profile-runbook.json" "profile_runbook_json_missing" || return 1
    require_file "${evidence_dir}/production-profile-runbook.md" "profile_runbook_md_missing" || return 1
    require_file "${evidence_dir}/production-profile-prereq-plan.json" "profile_prereq_plan_missing" || return 1
    require_file "${evidence_dir}/production-profile-prereq-audit.md" "profile_prereq_audit_md_missing" || return 1
    require_file "${evidence_dir}/production-profile-prereq-audit.json" "profile_prereq_audit_missing" || return 1
    require_file "${evidence_dir}/production-profile-scenario-catalog.json" "profile_scenario_catalog_missing" || return 1
    verify_prereq_not_blocked "${evidence_dir}/production-profile-prereq-audit.json" || return 1
    verify_profile_artifact_consistency \
      "${gate_in_evidence}" \
      "${evidence_dir}/production-profile-run.json" \
      "${evidence_dir}/production-profile-plan.json" \
      "${evidence_dir}/production-profile-prereq-plan.json" \
      "${evidence_dir}/production-profile-prereq-audit.json" \
      "${evidence_dir}/production-profile-scenario-catalog.json" || return 1
  fi
  verify_product_plan_artifact_consistency "${evidence_dir}" || return 1
  verify_product_campaign_artifact_consistency "${evidence_dir}" || return 1
  verify_current_readiness_artifact_consistency "${evidence_dir}" "${expect_base_url}" "${expect_tcp_host}" "${expect_tcp_port}" || return 1
  verify_production_acceptance_receipt "${evidence_dir}" || return 1

  local summary_fields
  summary_fields="$(evidence_summary_fields "${evidence_dir}")"
  printf 'performance_evidence result=pass current=%s evidence=%s gate=%s profile=%s expectBaseURL=%s expectTCPHost=%s expectTCPPort=%s requireProfileArtifacts=%s requireCurrentReadinessArtifacts=%s requireValidationInventory=%s requireProductionAcceptance=%s productionAcceptanceReceipt=%s productionAcceptancePackage=%s %s\n' \
    "${current_path}" \
    "${evidence_dir}" \
    "${PERF_PRODUCTION_GATE_JSON}" \
    "${PERF_PRODUCTION_GATE_PROFILE}" \
    "${expect_base_url:-<unset>}" \
    "${expect_tcp_host:-<unset>}" \
    "${expect_tcp_port}" \
    "${PERF_PRODUCTION_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS}" \
    "${PERF_PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS}" \
    "${PERF_PRODUCTION_EVIDENCE_REQUIRE_VALIDATION_INVENTORY}" \
    "${PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE}" \
    "${PERF_PRODUCTION_ACCEPTANCE_RECEIPT_JSON_EFFECTIVE:-<unset>}" \
    "${PERF_PRODUCTION_ACCEPTANCE_PACKAGE_FILE_EFFECTIVE:-<unset>}" \
    "${summary_fields}"
}

if bool_enabled "${PERF_EVIDENCE_VERIFY_SELF_TEST}"; then
  self_test_dir="$(mktemp -d)"
  trap 'rm -rf "${self_test_dir}"' EXIT
  package_path="${self_test_dir}/production-evidence.tar.gz"
  python3 - "${self_test_dir}/production-gate.json" "${PERF_PRODUCTION_PROFILE_CATALOG}" <<'PY'
import hashlib
import json
import subprocess
import sys
import time
from pathlib import Path

gate_path, catalog_path = sys.argv[1:3]
now = int(time.time())
repo_root = Path(catalog_path).resolve().parents[2]
with open(catalog_path, encoding="utf-8") as handle:
    scenarios = (json.load(handle).get("profiles") or {}).get("minimum-smoke") or []
with open(catalog_path, "rb") as handle:
    catalog_sha256 = hashlib.sha256(handle.read()).hexdigest()
try:
    commit = subprocess.run(["git", "rev-parse", "--verify", "HEAD"], cwd=repo_root, check=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout.strip()
    branch = subprocess.run(["git", "branch", "--show-current"], cwd=repo_root, check=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout.strip()
    dirty = bool(subprocess.run(["git", "status", "--porcelain"], cwd=repo_root, check=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout.strip())
except Exception:
    commit = "self-test"
    branch = "self-test"
    dirty = False
payload = {
    "status": "PASS",
    "profile": "minimum-smoke",
    "source": {"repoRoot": str(repo_root), "gitCommit": commit, "gitBranch": branch, "gitDirty": dirty},
    "targetFilter": {"enabled": True, "baseURL": "https://chat.myim-prod.com", "tcpHost": "tcp.myim-prod.com", "tcpPort": "9000"},
    "profileCatalog": {"path": catalog_path, "schemaVersion": 1, "sha256": catalog_sha256},
    "generatedAtEpoch": now,
    "summary": {
        "requiredScenarioCount": len(scenarios),
        "passedScenarioCount": len(scenarios),
        "failedScenarioCount": 0,
        "missingScenarioCount": 0,
        "evidenceOldestMtime": now,
        "evidenceNewestMtime": now,
        "runArtifactMissingCount": 0,
    },
    "requirements": {"runArtifacts": True},
    "requiredScenarios": [
        {
            "scenario": scenario,
            "category": "self-test",
            "requiredStatus": "PASS",
            "latestSLOStatus": "PASS",
            "latestScenarioStatus": "PASS",
            "runCount": 1,
            "latestRunID": "self-test",
            "latestRunDir": "/tmp/self-test",
            "latestMtime": now,
            "runArtifactsVerified": True,
            "runArtifactsOK": True,
            "passed": True,
            "reason": "",
        }
        for scenario in scenarios
    ],
}
with open(gate_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
  self_test_profile_count="$(
    python3 - "${PERF_PRODUCTION_PROFILE_CATALOG}" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(len((json.load(handle).get("profiles") or {}).get("minimum-smoke") or []))
PY
  )"
  self_test_skipped_count="$((self_test_profile_count - 1))"
  printf '{"profile":"minimum-smoke","profileScenarioCount":%s,"selectedScenarioCount":1,"skippedFreshPassCount":%s,"batchSize":1,"batchCount":1,"batches":[{"index":1,"scenarios":["login-smoke"]}]}\n' "${self_test_profile_count}" "${self_test_skipped_count}" >"${self_test_dir}/production-profile-plan.json"
  printf '{"schemaVersion":1,"profile":"minimum-smoke","finalStatus":"PASS","dryRun":false,"statusFilterTarget":true,"entrypointProbe":true,"entrypointProbeArtifacts":{"log":"%s/production-profile-entrypoint-probe.log","json":"%s/production-profile-entrypoint-probe.json"},"plan":{"profile":"minimum-smoke","profileScenarioCount":%s,"selectedScenarioCount":1,"skippedFreshPassCount":%s},"batches":[{"index":1,"runID":"self-test","status":"PASS","scenarios":["login-smoke"]}]}\n' "${self_test_dir}" "${self_test_dir}" "${self_test_profile_count}" "${self_test_skipped_count}" >"${self_test_dir}/production-profile-run.json"
  printf 'diagnosis=ok\n' >"${self_test_dir}/production-profile-entrypoint-probe.log"
  printf '{"schemaVersion":1,"diagnosis":"ok","failed":false,"baseURL":"https://chat.myim-prod.com","tcpStatus":"open","edgeIntercept":"","portProtocols":[{"label":"base-https:chat.myim-prod.com","port":"443","protocol":"tls_or_http"}]}\n' >"${self_test_dir}/production-profile-entrypoint-probe.json"
  printf '{"status":"READY","profile":"minimum-smoke","selectedScenarios":["login-smoke"]}\n' >"${self_test_dir}/production-profile-prereq-plan.json"
  printf '# Self-test prereq audit\n' >"${self_test_dir}/production-profile-prereq-audit.md"
  printf '{"summary":{"overallStatus":"READY"},"scenarios":[{"scenario":"login-smoke","status":"READY"}]}\n' >"${self_test_dir}/production-profile-prereq-audit.json"
  printf '{"summary":{"scenarioCount":1},"scenarios":[{"scenario":"login-smoke"}]}\n' >"${self_test_dir}/production-profile-scenario-catalog.json"
  cat >"${self_test_dir}/product-test-prereq-plan.json" <<'EOF'
{"schemaVersion":1,"status":"NO_SCENARIOS","plan":"self-test","requestedPhases":["entrypoint"],"selectedScenarios":[]}
EOF
  printf '{"summary":{"overallStatus":"READY","scenarioCount":0,"accountRows":1,"missingRequiredCount":0,"missingRecommendedCount":0},"scenarios":[]}\n' >"${self_test_dir}/product-test-prereq-audit.json"
  printf '# Product self-test prereq audit\n' >"${self_test_dir}/product-test-prereq-audit.md"
  printf '{"summary":{"scenarioCount":0},"scenarios":[]}\n' >"${self_test_dir}/product-test-scenario-catalog.json"
  cat >"${self_test_dir}/product-test-plan-preview.json" <<EOF
{
  "schemaVersion": 1,
  "plan": "self-test",
  "preset": "",
  "requestedPhases": ["entrypoint"],
  "fullProfile": "normal-product-baseline",
  "runFullProfile": false,
  "packageEvidence": true,
  "requireEntrypoint": true,
  "prereqGate": true,
  "dryRun": false,
  "statusFilterTarget": true,
  "target": {
    "baseURL": "https://chat.myim-prod.com",
    "tcpHost": "tcp.myim-prod.com",
    "tcpPort": "9000",
    "accountFile": "/tmp/self-test-accounts.csv",
    "conversationID": ""
  },
  "summary": {
    "phaseCount": 1,
    "scenarioPhaseCount": 0,
    "uniqueScenarioCount": 0,
    "largeGroupIncluded": false,
    "coveredProductDomains": [],
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
      "account-security",
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
  "selectedScenarios": [],
  "phases": [
    {"phase":"entrypoint","kind":"entrypoint","groups":[],"runner":"http_entrypoint_probe.sh","scenarioCount":0,"firstScenario":"","sampleScenarios":[],"scenarios":[]}
  ]
}
EOF
  cat >"${self_test_dir}/product-test-plan-run.json" <<EOF
{
  "schemaVersion": 1,
  "plan": "self-test",
  "requestedPhases": ["entrypoint"],
  "runFullProfile": false,
  "fullProfile": "normal-product-baseline",
  "runIDPrefix": "product-self-test",
  "finalStatus": "PASS",
  "reason": "",
  "dryRun": false,
  "statusFilterTarget": true,
  "target": {
    "baseURL": "https://chat.myim-prod.com",
    "tcpHost": "tcp.myim-prod.com",
    "tcpPort": "9000",
    "accountFile": "/tmp/self-test-accounts.csv",
    "conversationID": ""
  },
  "prereq": {
    "enabled": true,
    "plan": "${self_test_dir}/product-test-prereq-plan.json",
    "auditJSON": "${self_test_dir}/product-test-prereq-audit.json",
    "auditMarkdown": "${self_test_dir}/product-test-prereq-audit.md"
  },
  "planPreview": {
    "json": "${self_test_dir}/product-test-plan-preview.json",
    "exists": true
  },
  "runbook": {
    "json": "${self_test_dir}/product-test-runbook.json",
    "markdown": "${self_test_dir}/product-test-runbook.md"
  },
  "phases": [
    {"phase":"entrypoint","kind":"entrypoint-probe","runID":"product-self-test-entrypoint","status":"PASS","reason":"","command":"BASE_URL=https://chat.myim-prod.com ./http_entrypoint_probe.sh","runDir":"${self_test_dir}/product-self-test-entrypoint"},
    {"phase":"full-profile","kind":"production-profile","runID":"product-self-test-profile-normal-product-baseline","status":"SKIPPED","reason":"disabled","command":"PERF_PRODUCTION_GATE_PROFILE=normal-product-baseline ./run_production_profile.sh","runDir":"${self_test_dir}/product-self-test-profile-normal-product-baseline"}
  ]
}
EOF
  {
    printf 'entrypoint\tentrypoint-probe\tproduct-self-test-entrypoint\tPASS\t\tBASE_URL=https://chat.myim-prod.com ./http_entrypoint_probe.sh\n'
    printf 'full-profile\tproduction-profile\tproduct-self-test-profile-normal-product-baseline\tSKIPPED\tdisabled\tPERF_PRODUCTION_GATE_PROFILE=normal-product-baseline ./run_production_profile.sh\n'
  } >"${self_test_dir}/product-test-plan-phases.tsv"
  python3 - "${self_test_dir}" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
domains = [
    "account-security",
    "sync-read",
    "direct-chat",
    "group-workflow",
    "contacts-social",
    "media-ai-admin",
    "reliability-recovery",
    "realtime-direct",
]
phase_scenarios = {
    "account-security": ["login-smoke"],
    "sync-read": ["client-sync-mix-smoke"],
    "direct-chat": ["direct-convergence-smoke"],
    "group-workflow": ["small-group-smoke"],
    "contacts-social": ["contact-sync-smoke"],
    "media-ai-admin": ["media-file-smoke"],
    "reliability-recovery": ["offline-catchup-smoke"],
    "realtime-direct": ["online-idle-1000"],
}
phases = ["entrypoint", *domains]
selected = [items[0] for items in phase_scenarios.values()]
target = {
    "baseURL": "https://chat.myim-prod.com",
    "tcpHost": "tcp.myim-prod.com",
    "tcpPort": "9000",
    "accountFile": "/tmp/self-test-accounts.csv",
    "conversationID": "00000000-0000-4000-8000-000000000001",
}
preview_rows = [{"phase": "entrypoint", "kind": "entrypoint", "groups": [], "runner": "http_entrypoint_probe.sh", "scenarioCount": 0, "firstScenario": "", "sampleScenarios": [], "scenarios": []}]
run_rows = [{"phase": "entrypoint", "kind": "entrypoint-probe", "runID": "product-self-test-entrypoint", "status": "PASS", "reason": "", "command": "BASE_URL=https://chat.myim-prod.com ./http_entrypoint_probe.sh", "runDir": str(root / "product-self-test-entrypoint")}]
tsv_rows = ["entrypoint\tentrypoint-probe\tproduct-self-test-entrypoint\tPASS\t\tBASE_URL=https://chat.myim-prod.com ./http_entrypoint_probe.sh"]
for phase in domains:
    scenarios = phase_scenarios[phase]
    preview_rows.append({"phase": phase, "kind": "scenario-groups", "groups": [phase], "runner": "run_perf_scenarios.sh", "scenarioCount": len(scenarios), "firstScenario": scenarios[0], "sampleScenarios": scenarios, "scenarios": scenarios})
    command = f"SCENARIO_GROUPS={phase} ./run_perf_scenarios.sh"
    run_rows.append({"phase": phase, "kind": "scenario-groups", "runID": f"product-self-test-{phase}", "status": "PASS", "reason": "", "command": command, "runDir": str(root / f"product-self-test-{phase}")})
    tsv_rows.append(f"{phase}\tscenario-groups\tproduct-self-test-{phase}\tPASS\t\t{command}")
run_rows.append({"phase": "full-profile", "kind": "production-profile", "runID": "product-self-test-profile-normal-product-baseline", "status": "SKIPPED", "reason": "disabled", "command": "PERF_PRODUCTION_GATE_PROFILE=normal-product-baseline ./run_production_profile.sh", "runDir": str(root / "product-self-test-profile-normal-product-baseline")})
tsv_rows.append("full-profile\tproduction-profile\tproduct-self-test-profile-normal-product-baseline\tSKIPPED\tdisabled\tPERF_PRODUCTION_GATE_PROFILE=normal-product-baseline ./run_production_profile.sh")
(root / "product-test-plan-preview.json").write_text(json.dumps({"schemaVersion": 1, "plan": "self-test", "preset": "", "requestedPhases": phases, "fullProfile": "normal-product-baseline", "runFullProfile": False, "packageEvidence": True, "requireEntrypoint": True, "prereqGate": True, "dryRun": False, "statusFilterTarget": True, "target": target, "summary": {"phaseCount": len(preview_rows), "scenarioPhaseCount": len(domains), "uniqueScenarioCount": len(selected), "largeGroupIncluded": False, "coveredProductDomains": domains, "requiredProductDomains": domains, "missingProductDomains": [], "requiredProductDomainsCovered": True}, "selectedScenarios": selected, "phases": preview_rows}, indent=2, sort_keys=True), encoding="utf-8")
run_payload = json.loads((root / "product-test-plan-run.json").read_text(encoding="utf-8"))
run_payload["requestedPhases"] = phases
run_payload["target"] = target
run_payload["phases"] = run_rows
(root / "product-test-plan-run.json").write_text(json.dumps(run_payload, indent=2, sort_keys=True), encoding="utf-8")
(root / "product-test-plan-phases.tsv").write_text("\n".join(tsv_rows) + "\n", encoding="utf-8")
(root / "product-test-prereq-plan.json").write_text(json.dumps({"schemaVersion": 1, "status": "READY", "plan": "self-test", "requestedPhases": phases, "selectedScenarios": selected}, indent=2, sort_keys=True), encoding="utf-8")
(root / "product-test-prereq-audit.json").write_text(json.dumps({"summary": {"overallStatus": "READY", "scenarioCount": len(selected), "accountRows": 1000, "missingRequiredCount": 0, "missingRecommendedCount": 0}, "scenarios": [{"scenario": item, "status": "READY"} for item in selected]}, indent=2, sort_keys=True), encoding="utf-8")
(root / "product-test-scenario-catalog.json").write_text(json.dumps({"summary": {"scenarioCount": len(selected)}, "scenarios": [{"scenario": item} for item in selected]}, indent=2, sort_keys=True), encoding="utf-8")
PY
  python3 "${SCRIPT_DIR}/../../IMServer/LoadTests/perf_product_test_plan_runbook.py" \
    --product-run-json "${self_test_dir}/product-test-plan-run.json" \
    --prereq-audit-json "${self_test_dir}/product-test-prereq-audit.json" \
    --result-root "${self_test_dir}" \
    --output "${self_test_dir}/product-test-runbook.md" \
    --json-output "${self_test_dir}/product-test-runbook.json" >/dev/null
  mkdir -p "${self_test_dir}/campaign-stage-entrypoint" "${self_test_dir}/campaign-stage-profile"
  printf 'stage pass\n' >"${self_test_dir}/campaign-stage-entrypoint/stage.log"
  printf 'stage pass\n' >"${self_test_dir}/campaign-stage-profile/stage.log"
  cat >"${self_test_dir}/product-campaign-run.json" <<EOF
{
  "schemaVersion": 1,
  "campaign": "non-large-group-release",
  "description": "verify self-test campaign",
  "campaignCatalog": "${SCRIPT_DIR}/../../IMServer/LoadTests/perf_product_campaigns.json",
  "execute": true,
  "stopOnFailure": true,
  "resultDir": "${self_test_dir}",
  "runIDPrefix": "campaign-self-test",
  "finalStatus": "PASS",
  "failureCount": 0,
  "requiredFailureCount": 0,
  "attemptedStageCount": 2,
  "skippedStageCount": 0,
  "stageCount": 2,
  "stages": [
    {
      "index": 1,
      "id": "entrypoint",
      "runner": "product-plan",
      "required": true,
      "isolated": false,
      "status": "PASS",
      "returnCode": 0,
      "runDir": "${self_test_dir}/campaign-stage-entrypoint",
      "log": "${self_test_dir}/campaign-stage-entrypoint/stage.log",
      "command": "env BASE_URL=https://chat.myim-prod.com IM_INTERNAL_SECRET=<redacted> PRODUCT_TEST_PHASES=entrypoint ./run_product_test_plan.sh",
      "evidence": "entrypoint self-test"
    },
    {
      "index": 2,
      "id": "normal-product-baseline",
      "runner": "production-profile",
      "required": true,
      "isolated": false,
      "status": "PASS",
      "returnCode": 0,
      "runDir": "${self_test_dir}/campaign-stage-profile",
      "log": "${self_test_dir}/campaign-stage-profile/stage.log",
      "command": "env PERF_PRODUCTION_GATE_PROFILE=normal-product-baseline IM_INTERNAL_SECRET=<redacted> ./run_production_profile.sh",
      "evidence": "profile self-test"
    }
  ],
  "evidenceRoot": {
    "enabled": true,
    "profileSourceDir": "${self_test_dir}/campaign-stage-profile",
    "productPlanSourceDir": "${self_test_dir}/campaign-stage-entrypoint",
    "profileFilesCopied": [
      "production-gate.json",
      "production-profile-run.json",
      "production-profile-plan.json",
      "production-profile-entrypoint-probe.log",
      "production-profile-entrypoint-probe.json",
      "production-profile-runbook.json",
      "production-profile-runbook.md",
      "production-profile-prereq-plan.json",
      "production-profile-prereq-audit.json",
      "production-profile-prereq-audit.md",
      "production-profile-scenario-catalog.json"
    ],
    "productPlanFilesCopied": [
      "product-test-plan-run.json",
      "product-test-plan-preview.json",
      "product-test-plan-phases.tsv",
      "product-test-prereq-plan.json",
      "product-test-prereq-audit.json",
      "product-test-prereq-audit.md",
      "product-test-scenario-catalog.json",
      "product-test-runbook.json",
      "product-test-runbook.md"
    ]
  }
}
EOF
  python3 - \
    "${self_test_dir}/product-campaign-run.json" \
    "${self_test_dir}" \
    "${self_test_dir}/product-campaign-runbook.md" \
    "${SCRIPT_DIR}/../../IMServer/LoadTests" <<'PY'
import json
import sys
from pathlib import Path

path, root, runbook_path, load_tests_dir = sys.argv[1:5]
sys.path.insert(0, str(Path(load_tests_dir)))
from run_product_campaign import build_runbook

with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)
payload["target"] = {
    "baseURL": "https://chat.myim-prod.com",
    "tcpHost": "tcp.myim-prod.com",
    "tcpPort": "9000",
    "accountFile": "",
    "hasConversationID": "false",
    "hasInternalSecret": "true",
}
stage_defs = [
    ("entrypoint", "product-plan"),
    ("real-world-smoke", "product-plan"),
    ("daily-core", "product-plan"),
    ("workflow-domains", "product-plan"),
    ("recovery-governance", "product-plan"),
    ("realtime-direct", "product-plan"),
    ("normal-product-baseline", "production-profile"),
]
stages = []
for index, (stage_id, runner) in enumerate(stage_defs, start=1):
    run_dir = f"{root}/campaign-stage-{stage_id}"
    Path(run_dir).mkdir(parents=True, exist_ok=True)
    Path(run_dir, "stage.log").write_text("stage pass\n", encoding="utf-8")
    command = (
        f"env BASE_URL=https://chat.myim-prod.com TCP_HOST=tcp.myim-prod.com TCP_PORT=9000 PRODUCT_TEST_PHASES={stage_id} IM_INTERNAL_SECRET=<redacted> ./run_product_test_plan.sh"
        if runner == "product-plan"
        else "env BASE_URL=https://chat.myim-prod.com TCP_HOST=tcp.myim-prod.com TCP_PORT=9000 PERF_PRODUCTION_GATE_PROFILE=normal-product-baseline IM_INTERNAL_SECRET=<redacted> ./run_production_profile.sh"
    )
    stages.append({
        "index": index,
        "id": stage_id,
        "runner": runner,
        "required": True,
        "isolated": False,
        "status": "PASS",
        "returnCode": 0,
        "runDir": run_dir,
        "log": f"{run_dir}/stage.log",
        "command": command,
        "evidence": "self-test",
    })
payload["stageCount"] = len(stages)
payload["attemptedStageCount"] = len(stages)
payload["skippedStageCount"] = 0
payload["failureCount"] = 0
payload["requiredFailureCount"] = 0
payload["stages"] = stages
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
Path(runbook_path).write_text(build_runbook(payload), encoding="utf-8")
PY
  printf '{"schemaVersion":1,"failed":false,"diagnosis":"ok","publicPortPolicyStatus":"pass","publicDeniedPortsOpen":[],"publicExpectedPortsMissing":[]}\n' >"${self_test_dir}/current-readiness-entrypoint-probe.json"
  printf 'diagnosis=ok\n' >"${self_test_dir}/current-readiness-entrypoint-probe.log"
  printf 'entrypoint ok\n' >"${self_test_dir}/current-readiness-entrypoint-summary.txt"
  cat >"${self_test_dir}/current-production-dashboard.json" <<'EOF'
{
  "summary": {
    "entrypointRescueBlocked": false,
    "entrypointRescueDiagnosis": "",
    "currentReadinessStatus": "PASS",
    "currentReadinessReason": "entrypoint_and_requested_runs_passed",
    "currentReadinessRequestedSmoke": true,
    "currentReadinessRequestedProductScenarioSuite": true,
    "currentReadinessRequestedBaseline": true,
    "currentReadinessRequestedFullAcceptance": true,
    "currentReadinessSmokeExitCode": 0,
    "currentReadinessProductScenarioSuiteExitCode": 0,
    "currentReadinessBaselineExitCode": 0,
    "currentReadinessFullAcceptanceExitCode": 0,
    "currentReadinessProductScenarioSuiteExpected": "recommended",
    "currentReadinessProductScenarioSuite": "recommended",
    "currentReadinessProductScenarioSuiteStatus": "PASS",
    "currentReadinessProductScenarioSuiteStageCount": 1,
    "currentReadinessProductScenarioSuiteFailedStages": 0,
    "currentReadinessProductScenarioSuitePlannedStages": 0,
    "currentReadinessProductScenarioSuiteScenarios": 8,
    "currentReadinessProductScenarioSuiteProductPlanStages": 1,
    "currentReadinessProductScenarioSuiteLargeGroupIncluded": false,
    "currentReadinessFullAcceptanceExpectedCampaign": "production-full-acceptance",
    "currentReadinessFullAcceptanceCampaign": "production-full-acceptance",
    "currentReadinessFullAcceptanceStatus": "PASS",
    "currentReadinessFullAcceptanceFailures": 0,
    "currentReadinessFullAcceptanceRequiredFailures": 0,
    "currentReadinessFullAcceptanceAttempted": 6,
    "currentReadinessFullAcceptanceSkipped": 0
  },
  "nextCommand": ""
}
EOF
  printf '# Current Production Dashboard\n' >"${self_test_dir}/current-production-dashboard.md"
  cat >"${self_test_dir}/current-production-state-summary.json" <<'EOF'
{
  "summary": {
    "conclusion": "READY",
    "entrypointRescueDiagnosis": "",
    "currentReadinessStatus": "PASS",
    "currentReadinessReason": "entrypoint_and_requested_runs_passed",
    "currentReadinessRequestedSmoke": true,
    "currentReadinessRequestedProductScenarioSuite": true,
    "currentReadinessRequestedBaseline": true,
    "currentReadinessRequestedFullAcceptance": true,
    "currentReadinessSmokeExitCode": 0,
    "currentReadinessProductScenarioSuiteExitCode": 0,
    "currentReadinessBaselineExitCode": 0,
    "currentReadinessFullAcceptanceExitCode": 0,
    "currentReadinessProductScenarioSuiteExpected": "recommended",
    "currentReadinessProductScenarioSuite": "recommended",
    "currentReadinessProductScenarioSuiteStatus": "PASS",
    "currentReadinessProductScenarioSuiteStageCount": 1,
    "currentReadinessProductScenarioSuiteFailedStages": 0,
    "currentReadinessProductScenarioSuitePlannedStages": 0,
    "currentReadinessProductScenarioSuiteScenarios": 8,
    "currentReadinessProductScenarioSuiteProductPlanStages": 1,
    "currentReadinessProductScenarioSuiteLargeGroupIncluded": false,
    "currentReadinessFullAcceptanceExpectedCampaign": "production-full-acceptance",
    "currentReadinessFullAcceptanceCampaign": "production-full-acceptance",
    "currentReadinessFullAcceptanceStatus": "PASS",
    "currentReadinessFullAcceptanceFailures": 0,
    "currentReadinessFullAcceptanceRequiredFailures": 0,
    "currentReadinessFullAcceptanceAttempted": 6,
    "currentReadinessFullAcceptanceSkipped": 0,
    "currentReadinessOperatorNetworkPreflight": true,
    "currentReadinessOperatorNetworkLogPresent": true,
    "currentReadinessOperatorNetworkFailed": false,
    "currentReadinessOperatorNetworkWarnings": [],
    "currentReadinessOperatorNetworkRouteInterfaces": ["en0"],
    "currentReadinessOperatorNetworkRouteGateways": ["192.168.1.1"],
    "currentReadinessOperatorNetworkFailureCount": 0
  },
  "nextCommand": ""
}
EOF
  printf '# Current Production State Summary\n' >"${self_test_dir}/current-production-state-summary.md"
  cat >"${self_test_dir}/current-production-state-summary.csv" <<'EOF'
recordType,conclusion,readinessGate,currentReadinessStatus,currentReadinessReason,currentReadinessRequestedSmoke,currentReadinessRequestedProductScenarioSuite,currentReadinessRequestedBaseline,currentReadinessRequestedFullAcceptance,currentReadinessSmokeExitCode,currentReadinessProductScenarioSuiteExitCode,currentReadinessBaselineExitCode,currentReadinessFullAcceptanceExitCode,currentReadinessProductScenarioSuiteExpected,currentReadinessProductScenarioSuite,currentReadinessProductScenarioSuiteStatus,currentReadinessProductScenarioSuiteStageCount,currentReadinessProductScenarioSuiteFailedStages,currentReadinessProductScenarioSuitePlannedStages,currentReadinessProductScenarioSuiteScenarios,currentReadinessProductScenarioSuiteProductPlanStages,currentReadinessProductScenarioSuiteLargeGroupIncluded,currentReadinessFullAcceptanceExpectedCampaign,currentReadinessFullAcceptanceCampaign,currentReadinessFullAcceptanceStatus,currentReadinessFullAcceptanceFailures,currentReadinessFullAcceptanceRequiredFailures,currentReadinessFullAcceptanceAttempted,currentReadinessFullAcceptanceSkipped,currentReadinessOperatorNetworkPreflight,currentReadinessOperatorNetworkLogPresent,currentReadinessOperatorNetworkFailed,currentReadinessOperatorNetworkWarnings,currentReadinessOperatorNetworkRouteInterfaces,currentReadinessOperatorNetworkRouteGateways,currentReadinessOperatorNetworkFailureCount,domain
summary,READY,,PASS,entrypoint_and_requested_runs_passed,True,True,True,True,0,0,0,0,recommended,recommended,PASS,1,0,0,8,1,False,production-full-acceptance,production-full-acceptance,PASS,0,0,6,0,True,True,False,,en0,192.168.1.1,0,
EOF
  printf 'smoke pass\n' >"${self_test_dir}/current-readiness-normal-product-smoke.log"
  printf 'product scenario suite pass\n' >"${self_test_dir}/current-readiness-product-scenario-suite.log"
  printf 'baseline pass\n' >"${self_test_dir}/current-readiness-normal-product-baseline.log"
  printf 'full acceptance pass\n' >"${self_test_dir}/current-readiness-production-full-acceptance.log"
  python3 - \
    "${self_test_dir}" \
    "${self_test_dir}/current-readiness-full-acceptance-run.json" \
    "${self_test_dir}/current-readiness-full-acceptance-runbook.md" \
    "${SCRIPT_DIR}/../../IMServer/LoadTests" <<'PY'
import json
import sys
from pathlib import Path

root, json_path, runbook_path, load_tests_dir = map(Path, sys.argv[1:5])
sys.path.insert(0, str(load_tests_dir))
from run_product_campaign import build_runbook

stage_ids = [
    "normal-product-smoke",
    "normal-product-plan",
    "normal-product-baseline",
    "normal-product-capacity",
    "message-realtime-capacity",
    "large-group-isolated",
]
stages = []
for index, stage_id in enumerate(stage_ids, start=1):
    is_large = stage_id == "large-group-isolated"
    command = (
        "env BASE_URL=https://chat.myim-prod.com TCP_HOST=tcp.myim-prod.com TCP_PORT=9000 "
        "IM_INTERNAL_SECRET=<redacted> SCENARIO_GROUPS=large-group ./run_perf_scenarios.sh"
        if is_large else
        "env BASE_URL=https://chat.myim-prod.com TCP_HOST=tcp.myim-prod.com TCP_PORT=9000 "
        f"IM_INTERNAL_SECRET=<redacted> PRODUCT_TEST_PHASES={stage_id} ./run_product_test_plan.sh"
    )
    stages.append({
        "index": index,
        "id": stage_id,
        "runner": "scenario-group" if is_large else "product-plan",
        "required": True,
        "isolated": is_large,
        "status": "PASS",
        "returnCode": 0,
        "runDir": str(root / f"{index:02d}-{stage_id}"),
        "log": str(root / f"{index:02d}-{stage_id}" / "stage.log"),
        "command": command,
        "evidence": "self-test",
        "packageEvidenceProfile": False,
        "packageEvidenceProductPlan": False,
        "skipReason": "",
    })
payload = {
    "schemaVersion": 1,
    "generatedAt": "2026-01-01T00:00:00Z",
    "campaign": "production-full-acceptance",
    "description": "performance evidence verify self-test",
    "campaignCatalog": str(load_tests_dir / "perf_product_campaigns.json"),
    "execute": True,
    "stopOnFailure": True,
    "resultDir": str(root),
    "runIDPrefix": "performance-evidence-verify-self-test",
    "target": {
        "baseURL": "https://chat.myim-prod.com",
        "tcpHost": "tcp.myim-prod.com",
        "tcpPort": "9000",
        "accountFile": "/tmp/self-test-accounts.csv",
        "hasConversationID": "true",
        "hasInternalSecret": "true",
    },
    "evidenceRoot": {"enabled": False},
    "finalStatus": "PASS",
    "failureCount": 0,
    "requiredFailureCount": 0,
    "attemptedStageCount": len(stages),
    "skippedStageCount": 0,
    "stageCount": len(stages),
    "stages": stages,
}
json_path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
runbook_path.write_text(build_runbook(payload), encoding="utf-8")
PY
  cat >"${self_test_dir}/product-scenario-suite-run.json" <<'EOF'
{
  "schemaVersion": 1,
  "suite": "recommended",
  "status": "PASS",
  "reason": "all_stages_passed",
  "target": {"baseURL": "https://chat.myim-prod.com", "tcpHost": "tcp.myim-prod.com", "tcpPort": "9000", "accountFile": "/tmp/self-test-accounts.csv", "conversationIDPresent": true},
  "settings": {"dryRun": false, "execute": true, "stopOnFailure": true, "includeLargeGroup": false},
  "stageCount": 1,
  "failedStageCount": 0,
  "plannedStageCount": 0,
  "coverageSummary": {
    "stageCount": 1,
    "productPlanStageCount": 1,
    "campaignStageCount": 0,
    "coverageErrorCount": 0,
    "uniqueScenarioCount": 8,
    "largeGroupIncluded": false,
    "coveredProductDomains": ["account-security", "sync-read", "direct-chat", "group-workflow", "contacts-social", "media-ai-admin", "reliability-recovery", "realtime-direct"],
    "requiredProductDomains": ["account-security", "sync-read", "direct-chat", "group-workflow", "contacts-social", "media-ai-admin", "reliability-recovery", "realtime-direct"],
    "missingProductDomains": [],
    "requiredProductDomainsCovered": true
  },
  "failureSummary": [],
  "stageCoverage": [
    {"stage": "normal-smoke", "runner": "product-plan", "value": "normal-smoke", "coverageStatus": "READY", "uniqueScenarioCount": 8, "largeGroupIncluded": false, "coveredProductDomains": ["account-security", "sync-read", "direct-chat", "group-workflow", "contacts-social", "media-ai-admin", "reliability-recovery", "realtime-direct"], "requiredProductDomains": ["account-security", "sync-read", "direct-chat", "group-workflow", "contacts-social", "media-ai-admin", "reliability-recovery", "realtime-direct"], "missingProductDomains": [], "requiredProductDomainsCovered": true, "selectedScenarios": ["login-smoke"], "sampleScenarios": ["login-smoke"]}
  ],
  "stages": [
    {"id": "normal-smoke", "runner": "product-plan", "value": "normal-smoke", "description": "Fast smoke", "runDir": ".", "status": "PASS", "exitCode": 0}
  ]
}
EOF
  cat >"${self_test_dir}/product-scenario-suite-run.md" <<'EOF'
# Product Scenario Suite Run

- suite: `recommended`
- status: `PASS`

## Coverage

| Stage | Runner | Coverage | Scenarios | Domains | Missing Domains | Large Group |
| --- | --- | --- | --- | --- | --- | --- |
| `normal-smoke` | `product-plan` | `READY` | `8` | `account-security,sync-read,direct-chat,group-workflow,contacts-social,media-ai-admin,reliability-recovery,realtime-direct` | `-` | `False` |

## Stages

| Stage | Runner | Value | Status | Exit | Run Dir |
| --- | --- | --- | --- | --- | --- |
| `normal-smoke` | `product-plan` | `normal-smoke` | `PASS` | `0` | `.` |
EOF
  printf 'normal-smoke\tproduct-plan\tnormal-smoke\tFast smoke\t.\tPASS\t0\n' >"${self_test_dir}/product-scenario-suite-stages.tsv"
  cat >"${self_test_dir}/current-production-readiness.json" <<EOF
{
  "schemaVersion": 1,
  "status": "PASS",
  "reason": "entrypoint_and_requested_runs_passed",
  "generatedAtEpoch": $(date +%s),
  "target": {
    "baseURL": "https://chat.myim-prod.com",
    "tcpHost": "tcp.myim-prod.com",
    "tcpPort": "9000",
    "accountFile": "/tmp/self-test-accounts.csv",
    "conversationIDPresent": true
  },
  "profile": "minimum-smoke",
  "evidencePolicy": {
	    "requirePackageableEvidence": true,
	    "requireCloudSecurityGroup": true,
	    "requirePublicPortPolicy": true,
	    "allowTempHTTP8080": false,
	    "cloudSecurityGroupRulesMaxAgeSeconds": 86400,
	    "cloudSecurityGroupRulesRequireRootOwner": true,
	    "cloudSecurityGroupRulesFile": "${self_test_dir}/cloud-security-group.json",
    "requireCloudSecurityGroupRepairReceipt": true,
    "cloudSecurityGroupRepairReceiptJSON": "${self_test_dir}/cloud-security-group-repair-receipt.json",
    "cloudSecurityGroupRepairReceiptMaxAgeSeconds": 86400,
    "cloudSecurityGroupRepairReceiptExpectSecurityGroupID": "sg-evidence-verify-selftest",
    "cloudSecurityGroupRepairReceiptExpectRegionID": "cn-shenzhen",
    "cloudSecurityGroupRepairReceiptExpectAdminCIDR": "203.0.113.10/32",
    "operatorNetworkPreflight": true,
    "autoProductScenarioSuiteForPackageableAcceptance": true
  },
  "requestedRuns": {
    "smoke": true,
    "smokeMode": "smoke",
    "productScenarioSuite": true,
    "productScenarioSuiteName": "recommended",
    "baseline": true,
    "fullAcceptance": true,
    "fullAcceptanceCampaign": "production-full-acceptance"
  },
  "entrypoint": {
    "probeJSON": "${self_test_dir}/current-readiness-entrypoint-probe.json",
    "failed": false,
    "diagnosis": "ok",
    "detail": "self-test ok",
    "blocker": {"preventsPerformanceEvidence": false}
  },
  "artifacts": {
    "runDir": "${self_test_dir}",
    "rescueSummary": "${self_test_dir}/current-readiness-entrypoint-summary.txt",
    "entrypointProbeLog": "${self_test_dir}/current-readiness-entrypoint-probe.log",
    "operatorNetworkLog": "${self_test_dir}/current-readiness-operator-network.log",
    "operatorNetworkJSON": "${self_test_dir}/current-readiness-operator-network.json",
    "dashboard": "${self_test_dir}/current-production-dashboard.md",
    "stateSummary": "${self_test_dir}/current-production-state-summary.md",
    "smokeLog": "${self_test_dir}/current-readiness-normal-product-smoke.log",
    "productScenarioSuiteLog": "${self_test_dir}/current-readiness-product-scenario-suite.log",
    "productScenarioSuiteRunJSON": "${self_test_dir}/product-scenario-suite-run.json",
    "productScenarioSuiteRunMarkdown": "${self_test_dir}/product-scenario-suite-run.md",
    "productScenarioSuiteStagesTSV": "${self_test_dir}/product-scenario-suite-stages.tsv",
    "baselineLog": "${self_test_dir}/current-readiness-normal-product-baseline.log",
    "fullAcceptanceLog": "${self_test_dir}/current-readiness-production-full-acceptance.log",
    "fullAcceptanceRunJSON": "${self_test_dir}/current-readiness-full-acceptance-run.json",
    "fullAcceptanceRunbook": "${self_test_dir}/current-readiness-full-acceptance-runbook.md",
    "cloudSecurityGroupRulesFile": "${self_test_dir}/cloud-security-group.json",
    "cloudSecurityGroupAuditLog": "${self_test_dir}/cloud-security-group-audit.log",
    "cloudSecurityGroupRepairReceiptJSON": "${self_test_dir}/cloud-security-group-repair-receipt.json",
    "cloudSecurityGroupRepairReceiptVerifyLog": "${self_test_dir}/cloud-security-group-repair-receipt-verify.log"
  },
  "runs": {
    "smokeExitCode": 0,
    "suiteExitCode": 0,
    "baselineExitCode": 0,
    "fullAcceptanceExitCode": 0
  }
}
EOF
  python3 - \
    "${self_test_dir}/current-production-readiness.json" \
    "${self_test_dir}/current-production-readiness.md" \
    "${SCRIPT_DIR}/../../IMServer/LoadTests" <<'PY'
import json
import sys
from pathlib import Path

json_path, md_path, load_tests_dir = map(Path, sys.argv[1:4])
sys.path.insert(0, str(load_tests_dir))
from perf_current_production_readiness_verify import build_readiness_markdown

payload = json.loads(json_path.read_text(encoding="utf-8"))
md_path.write_text(build_readiness_markdown(payload), encoding="utf-8")
PY
  printf 'operator-network target=https://chat.myim-prod.com host=chat.myim-prod.com status=pass warning=clean routeInterface=en0 routeGateway=192.168.1.1 proxyEnv=<none>\noperator-network target=tcp.myim-prod.com host=tcp.myim-prod.com status=pass warning=clean routeInterface=en0 routeGateway=192.168.1.1 proxyEnv=<none>\noperator-network result=pass targets=2\n' \
    >"${self_test_dir}/current-readiness-operator-network.log"
  cat >"${self_test_dir}/current-readiness-operator-network.json" <<'EOF'
{
  "schemaVersion": 1,
  "status": "pass",
  "failed": false,
  "failureCount": 0,
  "targetCount": 2,
  "warnings": [],
  "warningCounts": {},
  "routeInterfaces": ["en0"],
  "routeGateways": ["192.168.1.1"],
  "failedTargets": [],
  "targets": [
    {"target": "https://chat.myim-prod.com", "host": "chat.myim-prod.com", "status": "pass", "warning": "clean", "routeInterface": "en0", "routeGateway": "192.168.1.1", "proxyEnv": "<none>"},
    {"target": "tcp.myim-prod.com", "host": "tcp.myim-prod.com", "status": "pass", "warning": "clean", "routeInterface": "en0", "routeGateway": "192.168.1.1", "proxyEnv": "<none>"}
  ],
  "action": ""
}
EOF
  cat >"${self_test_dir}/cloud-security-group.json" <<'JSON'
{
  "SecurityGroupRules": {
    "SecurityGroupRule": [
      {"IpProtocol": "tcp", "PortRange": "80/80", "SourceCidrIp": "0.0.0.0/0", "Policy": "Accept"},
      {"IpProtocol": "tcp", "PortRange": "443/443", "SourceCidrIp": "0.0.0.0/0", "Policy": "Accept"},
      {"IpProtocol": "tcp", "PortRange": "9000/9000", "SourceCidrIp": "0.0.0.0/0", "Policy": "Accept"},
      {"IpProtocol": "tcp", "PortRange": "22/22", "SourceCidrIp": "203.0.113.10/32", "Policy": "Accept"}
    ]
  }
}
JSON
  printf 'cloud-security-group result=pass\n' >"${self_test_dir}/cloud-security-group-audit.log"
  cp "${self_test_dir}/cloud-security-group.json" "${self_test_dir}/cloud-security-group-post-apply.json"
  python3 - "${self_test_dir}/cloud-security-group.json" "${self_test_dir}/cloud-security-group-repair-plan.json" "${self_test_dir}/cloud-security-group-post-apply.json" "${self_test_dir}/cloud-security-group-repair-receipt.json" <<'PY'
import hashlib
import json
import sys
import time
from pathlib import Path

snapshot_path, plan_path, post_apply_path, receipt_path = map(Path, sys.argv[1:5])
plan = {
    "schemaVersion": 1,
    "securityGroupId": "sg-evidence-verify-selftest",
    "regionId": "cn-shenzhen",
    "snapshot": str(snapshot_path),
    "adminCidr": "203.0.113.10/32",
    "publicClientPorts": [80, 443, 9000],
    "adminPorts": [22],
    "denyPublicPorts": [22, 3389, 5432, 6379, 8080, 8081, 8082, 9092, 18080],
    "status": "NOOP",
    "actions": [],
    "summary": {"actionCount": 0, "authorizeCount": 0, "revokeCount": 0},
}
plan_path.write_text(json.dumps(plan, indent=2, sort_keys=True), encoding="utf-8")

def artifact_record(path: Path) -> dict[str, object]:
    data = path.read_bytes()
    return {
        "path": str(path),
        "present": True,
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
    }

receipt = {
    "schemaVersion": 1,
    "status": "APPLIED_VERIFIED",
    "generatedAtEpoch": int(time.time()),
    "securityGroupId": "sg-evidence-verify-selftest",
    "regionId": "cn-shenzhen",
    "adminCidr": "203.0.113.10/32",
    "applied": True,
    "verified": True,
    "snapshot": str(snapshot_path),
    "postApplySnapshot": str(post_apply_path),
    "plan": str(plan_path),
    "planStatus": "NOOP",
    "summary": plan["summary"],
    "artifacts": {
        "snapshot": artifact_record(snapshot_path),
        "postApplySnapshot": artifact_record(post_apply_path),
        "plan": artifact_record(plan_path),
    },
}
receipt_path.write_text(json.dumps(receipt, indent=2, sort_keys=True), encoding="utf-8")
PY
  printf 'aliyun-security-group-repair-receipt-verify result=pass status=APPLIED_VERIFIED\n' >"${self_test_dir}/cloud-security-group-repair-receipt-verify.log"
  RESULT_ROOT="${self_test_dir}" \
  BASE_URL=https://chat.myim-prod.com \
  PUBLIC_BASE_URL=https://chat.myim-prod.com \
  TCP_HOST=tcp.myim-prod.com \
  TCP_PORT=9000 \
  PERF_PRODUCTION_GATE_EXPECT_BASE_URL=https://chat.myim-prod.com \
  PERF_PRODUCTION_GATE_EXPECT_TCP_HOST=tcp.myim-prod.com \
  PERF_PRODUCTION_GATE_EXPECT_TCP_PORT=9000 \
  PERF_PRODUCTION_GATE_JSON="${self_test_dir}/production-gate.json" \
  PERF_PRODUCTION_GATE_PROFILE="minimum-smoke" \
  PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=0 \
  PRODUCTION_EVIDENCE_PACKAGE="${package_path}" \
  PRODUCTION_EVIDENCE_OUTPUT_DIR="${self_test_dir}/out" \
  PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS=true \
  PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS=true \
  PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP=true \
    "${SCRIPT_DIR}/../../IMServer/LoadTests/package_production_evidence.sh" >/dev/null
  python3 - "${self_test_dir}/production-acceptance.json" "${package_path}" "${self_test_dir}" <<'PY'
import hashlib
import json
import sys
import time
from pathlib import Path

receipt_path, package_path, root = map(Path, sys.argv[1:4])
digest = hashlib.sha256()
with package_path.open("rb") as handle:
    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
        digest.update(chunk)
payload = {
    "schemaVersion": 1,
    "status": "PASS",
    "reason": "accepted",
    "generatedAtEpoch": int(time.time()),
    "level": "full",
    "target": {
        "baseURL": "https://chat.myim-prod.com",
        "tcpHost": "tcp.myim-prod.com",
        "tcpPort": "9000",
        "accountFile": "/tmp/accounts.csv",
        "conversationIDPresent": True,
        "requiredAccountRows": 10000,
    },
	    "policy": {
	        "requirePackageableEvidence": True,
	        "requireCloudSecurityGroup": True,
	        "requireCloudSecurityGroupRepairReceipt": True,
	        "requirePublicPortPolicy": True,
	        "allowTempHTTP8080": False,
	        "cloudSecurityGroupRulesMaxAgeSeconds": 86400,
	        "cloudSecurityGroupRulesRequireRootOwner": True,
	        "operatorNetworkPreflight": True,
        "runSmoke": True,
        "runProductScenarioSuite": True,
        "runBaseline": True,
        "runFullAcceptance": True,
        "fullAcceptanceCampaign": "production-full-acceptance",
        "cloudSecurityGroupRulesFile": str(root / "cloud-security-group.json"),
        "cloudSecurityGroupRepairReceiptJSON": str(root / "cloud-security-group-repair-receipt.json"),
        "cloudSecurityGroupRepairReceiptMaxAgeSeconds": 86400,
        "cloudSecurityGroupRepairReceiptExpectSecurityGroupID": "sg-evidence-verify-selftest",
        "cloudSecurityGroupRepairReceiptExpectRegionID": "cn-shenzhen",
        "cloudSecurityGroupRepairReceiptExpectAdminCIDR": "203.0.113.10/32",
    },
    "artifacts": {
        "readinessJSON": str(root / "current-production-readiness.json"),
        "readinessLog": str(root / "current-readiness-normal-product-baseline.log"),
        "packageLog": str(root / "package.log"),
        "package": str(package_path),
        "packagePresent": True,
        "packageBytes": package_path.stat().st_size,
        "packageSha256": digest.hexdigest(),
    },
    "commands": {"readinessExitCode": 0, "packageExitCode": 0},
}
(root / "package.log").write_text("package pass\n", encoding="utf-8")
receipt_path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
  bad_env_file="${self_test_dir}/bad-common.env"
  good_env_file="${self_test_dir}/good-common.env"
  {
    printf 'PUBLIC_BASE_URL=http://example.test:8080\n'
    printf 'TCP_PORT=9000\n'
  } >"${bad_env_file}"
  {
    printf 'PUBLIC_BASE_URL=https://chat.myim-prod.com\n'
    printf 'IM_PUBLIC_HOST=tcp.myim-prod.com\n'
    printf 'TCP_PORT=9000\n'
  } >"${good_env_file}"
  PERF_PRODUCTION_EVIDENCE_PACKAGE_SOURCE="${package_path}" \
  PERF_PRODUCTION_EVIDENCE_DIR="${self_test_dir}/installed/evidence" \
  PERF_PRODUCTION_EVIDENCE_CURRENT_LINK="${self_test_dir}/installed/current-evidence" \
  PERF_PRODUCTION_EVIDENCE_OWNER="$(id -un)" \
  PERF_PRODUCTION_EVIDENCE_GROUP="$(id -gn)" \
  PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE=true \
  PERF_PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${self_test_dir}/production-acceptance.json" \
  PERF_PRODUCTION_EVIDENCE_REQUIRE_ROOT=false \
  PERF_PRODUCTION_GATE_JSON="${self_test_dir}/installed/production-gate.json" \
  PERF_PRODUCTION_GATE_PROFILE="minimum-smoke" \
  PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=0 \
  PERF_PRODUCTION_GATE_REQUIRE_ROOT=false \
  PERF_EVIDENCE_VERIFY_SELF_TEST=false \
  ENV_FILE="${good_env_file}" \
    bash "${SCRIPT_DIR}/69_install_performance_evidence_package.sh" >/dev/null
  PERF_PRODUCTION_EVIDENCE_CURRENT_LINK="${self_test_dir}/installed/current-evidence"
  PERF_PRODUCTION_GATE_JSON="${self_test_dir}/installed/production-gate.json"
  PERF_PRODUCTION_GATE_PROFILE="minimum-smoke"
  PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=0
  PERF_PRODUCTION_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS=true
  PERF_PRODUCTION_GATE_EXPECT_BASE_URL=""
  PERF_PRODUCTION_GATE_EXPECT_TCP_HOST=""
  PERF_PRODUCTION_GATE_EXPECT_TCP_PORT=""
  ENV_FILE="${bad_env_file}"
  if verify_evidence "${self_test_dir}/installed/current-evidence" >"${self_test_dir}/bad-target-evidence.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=bad_env_target_passed\n' >&2
    exit 1
  fi
  grep -q 'target_filter_mismatch' "${self_test_dir}/bad-target-evidence.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=bad_env_target_reason_missing\n' >&2
    exit 1
  }
  ENV_FILE="${good_env_file}"
  verify_evidence "${self_test_dir}/installed/current-evidence" >"${self_test_dir}/good-evidence.log"
  PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE=true \
  PERF_PRODUCTION_ACCEPTANCE_RECEIPT_JSON= \
  PERF_PRODUCTION_ACCEPTANCE_PACKAGE_FILE= \
    verify_evidence "${self_test_dir}/installed/current-evidence" >"${self_test_dir}/good-acceptance-evidence.log"
  grep -q 'requireProductionAcceptance=true' "${self_test_dir}/good-acceptance-evidence.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=good_acceptance_summary_missing\n' >&2
    exit 1
  }
  grep -q 'productionAcceptanceReceipt=.*/production-acceptance.json' "${self_test_dir}/good-acceptance-evidence.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=good_acceptance_sidecar_summary_missing\n' >&2
    exit 1
  }
  grep -q 'productionAcceptancePackage=.*/production-acceptance-package.tar.gz' "${self_test_dir}/good-acceptance-evidence.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=good_acceptance_package_summary_missing\n' >&2
    exit 1
  }
  missing_acceptance_dir="${self_test_dir}/missing-acceptance-current-evidence"
  mkdir -p "${missing_acceptance_dir}"
  tar -C "$(readlink -f "${self_test_dir}/installed/current-evidence")" -cf - . | tar -C "${missing_acceptance_dir}" -xf -
  rm -f "${missing_acceptance_dir}/${PRODUCTION_ACCEPTANCE_RECEIPT_FILE_NAME}" "${missing_acceptance_dir}/${PRODUCTION_ACCEPTANCE_PACKAGE_FILE_NAME}"
  if PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE=true \
    PERF_PRODUCTION_ACCEPTANCE_RECEIPT_JSON= \
    PERF_PRODUCTION_ACCEPTANCE_PACKAGE_FILE= \
      verify_evidence "${missing_acceptance_dir}" >"${self_test_dir}/missing-acceptance-evidence.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=missing_acceptance_receipt_passed\n' >&2
    exit 1
  fi
  grep -q 'production_acceptance_receipt_missing' "${self_test_dir}/missing-acceptance-evidence.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=missing_acceptance_receipt_reason_missing\n' >&2
    exit 1
  }
  missing_acceptance_package_dir="${self_test_dir}/missing-acceptance-package-current-evidence"
  mkdir -p "${missing_acceptance_package_dir}"
  tar -C "$(readlink -f "${self_test_dir}/installed/current-evidence")" -cf - . | tar -C "${missing_acceptance_package_dir}" -xf -
  rm -f "${missing_acceptance_package_dir}/${PRODUCTION_ACCEPTANCE_PACKAGE_FILE_NAME}"
  if PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE=true \
    PERF_PRODUCTION_ACCEPTANCE_RECEIPT_JSON= \
    PERF_PRODUCTION_ACCEPTANCE_PACKAGE_FILE= \
      verify_evidence "${missing_acceptance_package_dir}" >"${self_test_dir}/missing-acceptance-package-evidence.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=missing_acceptance_package_passed\n' >&2
    exit 1
  fi
  grep -q 'production_acceptance_package_missing' "${self_test_dir}/missing-acceptance-package-evidence.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=missing_acceptance_package_reason_missing\n' >&2
    exit 1
  }
  if PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE=true \
    PERF_PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${self_test_dir}/production-acceptance.json" \
    PERF_PRODUCTION_ACCEPTANCE_PACKAGE_FILE="${package_path}" \
      verify_evidence "${missing_acceptance_package_dir}" >"${self_test_dir}/missing-acceptance-package-external-evidence.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=external_acceptance_package_bypassed_sidecar_requirement\n' >&2
    exit 1
  fi
  grep -q 'production_acceptance_package_missing' "${self_test_dir}/missing-acceptance-package-external-evidence.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=external_acceptance_package_bypass_reason_missing\n' >&2
    exit 1
  }
  metadata_evidence_dir="${self_test_dir}/metadata-current-evidence"
  mkdir -p "${metadata_evidence_dir}"
  tar -C "$(readlink -f "${self_test_dir}/installed/current-evidence")" -cf - . | tar -C "${metadata_evidence_dir}" -xf -
  printf 'local metadata\n' >"${metadata_evidence_dir}/._production-gate.json"
  if verify_evidence "${metadata_evidence_dir}" >"${self_test_dir}/metadata-evidence.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=metadata_evidence_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=local_metadata_file' "${self_test_dir}/metadata-evidence.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=metadata_evidence_reason_missing\n' >&2
    exit 1
  }
  unsigned_evidence_dir="${self_test_dir}/unsigned-current-evidence"
  mkdir -p "${unsigned_evidence_dir}"
  tar -C "$(readlink -f "${self_test_dir}/installed/current-evidence")" -cf - . | tar -C "${unsigned_evidence_dir}" -xf -
  printf 'unsigned extra evidence\n' >"${unsigned_evidence_dir}/unsigned-extra.txt"
  if verify_evidence "${unsigned_evidence_dir}" >"${self_test_dir}/unsigned-evidence.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=unsigned_evidence_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=checksum_member_missing path=unsigned-extra.txt' "${self_test_dir}/unsigned-evidence.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=unsigned_evidence_reason_missing\n' >&2
    exit 1
  }
  bad_current_markdown_dir="${self_test_dir}/bad-current-readiness-markdown"
  mkdir -p "${bad_current_markdown_dir}"
  tar -C "$(readlink -f "${self_test_dir}/installed/current-evidence")" -cf - . | tar -C "${bad_current_markdown_dir}" -xf -
  printf '\nmanual drift\n' >>"${bad_current_markdown_dir}/current-production-readiness.md"
  if verify_current_readiness_artifact_consistency "${bad_current_markdown_dir}" >"${self_test_dir}/bad-current-readiness-markdown.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=bad_current_readiness_markdown_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=readiness_markdown_mismatch' "${self_test_dir}/bad-current-readiness-markdown.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=bad_current_readiness_markdown_reason_missing\n' >&2
    exit 1
  }
  grep -q 'expectBaseURL=https://chat.myim-prod.com expectTCPHost=tcp.myim-prod.com expectTCPPort=9000' "${self_test_dir}/good-evidence.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=good_evidence_missing_target_summary\n' >&2
    exit 1
  }
  grep -q 'docsAudit=PASS docsGroups=' "${self_test_dir}/good-evidence.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=good_evidence_missing_docs_summary\n' >&2
    exit 1
  }
  grep -q 'inventoryDocs=5' "${self_test_dir}/good-evidence.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=good_evidence_missing_inventory_docs\n' >&2
    exit 1
  }
  grep -q 'manifestRequireProfileArtifacts=true manifestRequireProductPlanArtifacts=true manifestRequireProductCampaignArtifacts=true' "${self_test_dir}/good-evidence.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=good_evidence_missing_manifest_policy_summary\n' >&2
    exit 1
  }
  grep -q 'manifestRequireCurrentReadinessArtifacts=true' "${self_test_dir}/good-evidence.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=good_evidence_missing_current_readiness_policy_summary\n' >&2
    exit 1
  }
  grep -q 'manifestRequireProductScenarioSuiteArtifacts=true manifestRequireProductScenarioSuiteNoLargeGroup=true' "${self_test_dir}/good-evidence.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=good_evidence_missing_product_scenario_suite_policy_summary\n' >&2
    exit 1
  }
  grep -q 'productProfileGate=PASS productProfileGateChecked=3 productProfileGateRequiredDomains=10' "${self_test_dir}/good-evidence.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=good_evidence_missing_product_profile_gate_summary\n' >&2
    exit 1
  }
  grep -q 'profileRunStatus=PASS' "${self_test_dir}/good-evidence.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=good_evidence_missing_profile_run_status\n' >&2
    exit 1
  }
  grep -q 'profileRunBlockerType=-' "${self_test_dir}/good-evidence.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=good_evidence_missing_profile_blocker_type\n' >&2
    exit 1
  }
  grep -q 'profileEntrypointDiagnosis=ok profileEntrypointTcpStatus=open profileEntrypointEdgeIntercept=- profileEntrypointPortProtocols=1 profileEntrypointBlocker=-,-,-,-' "${self_test_dir}/good-evidence.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=good_evidence_missing_profile_entrypoint_summary\n' >&2
    exit 1
  }
  grep -q 'productPlanStatus=PASS' "${self_test_dir}/good-evidence.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=good_evidence_missing_product_plan_status\n' >&2
    exit 1
  }
  grep -q 'productPlanBlockerType=-' "${self_test_dir}/good-evidence.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=good_evidence_missing_product_blocker_type\n' >&2
    exit 1
  }
  grep -q 'productPlanScenarioCount=8 productPlanLargeGroupIncluded=false productPlanDomainCount=8 productPlanRequiredDomainsCovered=true' "${self_test_dir}/good-evidence.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=good_evidence_missing_product_plan_preview_summary\n' >&2
    exit 1
  }
  grep -q 'productCampaign=non-large-group-release' "${self_test_dir}/good-evidence.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=good_evidence_missing_product_campaign\n' >&2
    exit 1
  }
  grep -q 'productCampaignStatus=PASS' "${self_test_dir}/good-evidence.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=good_evidence_missing_product_campaign_status\n' >&2
    exit 1
  }
  grep -q 'productCampaignTarget=https://chat.myim-prod.com,tcp.myim-prod.com,9000' "${self_test_dir}/good-evidence.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=good_evidence_missing_product_campaign_target\n' >&2
    exit 1
  }
  grep -q 'productCampaignFailures=0 productCampaignRequiredFailures=0 productCampaignAttempted=7 productCampaignSkipped=0' "${self_test_dir}/good-evidence.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=good_evidence_missing_product_campaign_counters\n' >&2
    exit 1
  }
  grep -q 'currentReadinessFullAcceptanceExpectedCampaign=production-full-acceptance currentReadinessFullAcceptanceCampaign=production-full-acceptance currentReadinessFullAcceptanceStatus=PASS' "${self_test_dir}/good-evidence.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=good_evidence_missing_current_full_acceptance_campaign_summary\n' >&2
    exit 1
  }
  grep -q 'currentReadinessFullAcceptanceFailures=0 currentReadinessFullAcceptanceRequiredFailures=0 currentReadinessFullAcceptanceAttempted=6 currentReadinessFullAcceptanceSkipped=0' "${self_test_dir}/good-evidence.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=good_evidence_missing_current_full_acceptance_counter_summary\n' >&2
    exit 1
  }
  bad_current_suite_dir="${self_test_dir}/installed/bad-current-suite-readiness"
  mkdir -p "${bad_current_suite_dir}"
  tar -C "$(readlink -f "${self_test_dir}/installed/current-evidence")" -cf - . | tar -C "${bad_current_suite_dir}" -xf -
  python3 - \
    "${bad_current_suite_dir}/current-production-readiness.json" \
    "${bad_current_suite_dir}/current-production-readiness.md" \
    "${SCRIPT_DIR}/../../IMServer/LoadTests" <<'PY'
import json
import sys
from pathlib import Path

path, markdown_path, load_tests_dir = map(Path, sys.argv[1:4])
sys.path.insert(0, str(load_tests_dir))
from perf_current_production_readiness_verify import build_readiness_markdown

payload = json.loads(path.read_text(encoding="utf-8"))
payload.setdefault("requestedRuns", {})["productScenarioSuite"] = False
payload.setdefault("runs", {})["suiteExitCode"] = None
artifacts = payload.setdefault("artifacts", {})
for key in (
    "productScenarioSuiteLog",
    "productScenarioSuiteRunJSON",
    "productScenarioSuiteRunMarkdown",
    "productScenarioSuiteStagesTSV",
):
    artifacts.pop(key, None)
path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
markdown_path.write_text(build_readiness_markdown(payload), encoding="utf-8")
PY
  if PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS=true \
    verify_current_readiness_artifact_consistency "${bad_current_suite_dir}" >"${self_test_dir}/bad-current-suite-readiness.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=bad_current_suite_readiness_passed\n' >&2
    exit 1
  fi
  grep -q 'current_readiness_required_run_missing run=productScenarioSuite' "${self_test_dir}/bad-current-suite-readiness.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=bad_current_suite_readiness_reason_missing\n' >&2
    exit 1
  }
  bad_current_target_dir="${self_test_dir}/installed/bad-current-target-readiness"
  mkdir -p "${bad_current_target_dir}"
  tar -C "$(readlink -f "${self_test_dir}/installed/current-evidence")" -cf - . | tar -C "${bad_current_target_dir}" -xf -
  python3 - \
    "${bad_current_target_dir}/current-production-readiness.json" \
    "${bad_current_target_dir}/current-production-readiness.md" \
    "${SCRIPT_DIR}/../../IMServer/LoadTests" <<'PY'
import json
import sys
from pathlib import Path

path, markdown_path, load_tests_dir = map(Path, sys.argv[1:4])
sys.path.insert(0, str(load_tests_dir))
from perf_current_production_readiness_verify import build_readiness_markdown

payload = json.loads(path.read_text(encoding="utf-8"))
payload.setdefault("target", {})["tcpHost"] = "203.0.113.250"
path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
markdown_path.write_text(build_readiness_markdown(payload), encoding="utf-8")
PY
  if verify_current_readiness_artifact_consistency "${bad_current_target_dir}" >"${self_test_dir}/bad-current-target-readiness.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=bad_current_target_readiness_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=target_mismatch field=tcpHost expected=tcp.myim-prod.com actual=203.0.113.250' "${self_test_dir}/bad-current-target-readiness.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=bad_current_target_readiness_reason_missing\n' >&2
    exit 1
  }
  bad_current_sg_policy_dir="${self_test_dir}/installed/bad-current-cloud-sg-policy"
  mkdir -p "${bad_current_sg_policy_dir}"
  tar -C "$(readlink -f "${self_test_dir}/installed/current-evidence")" -cf - . | tar -C "${bad_current_sg_policy_dir}" -xf -
  python3 - \
    "${bad_current_sg_policy_dir}/current-production-readiness.json" \
    "${bad_current_sg_policy_dir}/current-production-readiness.md" \
    "${SCRIPT_DIR}/../../IMServer/LoadTests" <<'PY'
import json
import sys
from pathlib import Path

path, markdown_path, load_tests_dir = map(Path, sys.argv[1:4])
sys.path.insert(0, str(load_tests_dir))
from perf_current_production_readiness_verify import build_readiness_markdown

payload = json.loads(path.read_text(encoding="utf-8"))
payload.setdefault("evidencePolicy", {})["cloudSecurityGroupRulesRequireRootOwner"] = False
path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
markdown_path.write_text(build_readiness_markdown(payload), encoding="utf-8")
PY
  if PERF_PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP=true \
    verify_current_readiness_artifact_consistency "${bad_current_sg_policy_dir}" >"${self_test_dir}/bad-current-cloud-sg-policy.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=bad_current_cloud_sg_policy_passed\n' >&2
    exit 1
  fi
  grep -Eq '(current_readiness_cloud_security_group_rules_root_owner_missing|cloud_security_group_rules_root_owner_required_for_production)' "${self_test_dir}/bad-current-cloud-sg-policy.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=bad_current_cloud_sg_policy_reason_missing\n' >&2
    exit 1
  }
  unsafe_tree_dir="${self_test_dir}/installed/unsafe-tree-evidence"
  mkdir -p "${unsafe_tree_dir}"
  tar -C "$(readlink -f "${self_test_dir}/installed/current-evidence")" -cf - . | tar -C "${unsafe_tree_dir}" -xf -
  ln -s /etc/passwd "${unsafe_tree_dir}/unsafe-link"
  if verify_evidence "${unsafe_tree_dir}" >"${self_test_dir}/unsafe-tree.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=unsafe_tree_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=unsafe_evidence_file' "${self_test_dir}/unsafe-tree.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=unsafe_tree_reason_missing\n' >&2
    exit 1
  }
  unsafe_checksum_dir="${self_test_dir}/installed/unsafe-checksum-evidence"
  mkdir -p "${unsafe_checksum_dir}"
  tar -C "$(readlink -f "${self_test_dir}/installed/current-evidence")" -cf - . | tar -C "${unsafe_checksum_dir}" -xf -
  printf '%064d  /etc/passwd\n' 0 >"${unsafe_checksum_dir}/SHA256SUMS"
  if verify_evidence "${unsafe_checksum_dir}" >"${self_test_dir}/unsafe-checksum.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=unsafe_checksum_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=checksum_path_unsafe' "${self_test_dir}/unsafe-checksum.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=unsafe_checksum_reason_missing\n' >&2
    exit 1
  }
  missing_current_readiness_evidence_dir="${self_test_dir}/installed/missing-current-readiness-evidence"
  mkdir -p "${missing_current_readiness_evidence_dir}"
  tar -C "$(readlink -f "${self_test_dir}/installed/current-evidence")" -cf - . | tar -C "${missing_current_readiness_evidence_dir}" -xf -
  rm -f "${missing_current_readiness_evidence_dir}/current-production-readiness.json"
  rm -f "${missing_current_readiness_evidence_dir}/current-production-readiness.md"
  rm -f "${missing_current_readiness_evidence_dir}"/current-readiness-*
  rm -f "${missing_current_readiness_evidence_dir}/SHA256SUMS"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "${missing_current_readiness_evidence_dir}" && sha256sum ./* >SHA256SUMS)
  else
    (cd "${missing_current_readiness_evidence_dir}" && shasum -a 256 ./* >SHA256SUMS)
  fi
  if verify_evidence "${missing_current_readiness_evidence_dir}" >"${self_test_dir}/missing-current-readiness.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=missing_current_readiness_passed\n' >&2
    exit 1
  fi
  grep -q 'current_readiness' "${self_test_dir}/missing-current-readiness.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=missing_current_readiness_reason_missing\n' >&2
    exit 1
  }
  bad_current_full_campaign_evidence_dir="${self_test_dir}/installed/bad-current-full-campaign-evidence"
  mkdir -p "${bad_current_full_campaign_evidence_dir}"
  tar -C "$(readlink -f "${self_test_dir}/installed/current-evidence")" -cf - . | tar -C "${bad_current_full_campaign_evidence_dir}" -xf -
  python3 - "${bad_current_full_campaign_evidence_dir}/current-readiness-full-acceptance-run.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["campaign"] = "non-large-group-release"
path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
  rm -f "${bad_current_full_campaign_evidence_dir}/SHA256SUMS"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "${bad_current_full_campaign_evidence_dir}" && sha256sum ./* >SHA256SUMS)
  else
    (cd "${bad_current_full_campaign_evidence_dir}" && shasum -a 256 ./* >SHA256SUMS)
  fi
  if verify_evidence "${bad_current_full_campaign_evidence_dir}" >"${self_test_dir}/bad-current-full-campaign-evidence.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=bad_current_full_campaign_passed\n' >&2
    exit 1
  fi
  grep -q 'current_readiness_full_acceptance_run_mismatch' "${self_test_dir}/bad-current-full-campaign-evidence.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=bad_current_full_campaign_reason_missing\n' >&2
    exit 1
  }
  leaked_secret_evidence_dir="${self_test_dir}/installed/leaked-secret-evidence"
  mkdir -p "${leaked_secret_evidence_dir}"
  tar -C "$(readlink -f "${self_test_dir}/installed/current-evidence")" -cf - . | tar -C "${leaked_secret_evidence_dir}" -xf -
  printf 'verify-side-secret-0123456789\n' >>"${leaked_secret_evidence_dir}/dashboard.md"
  printf 'perf_secret_scan result=pass scanned=999\n' >"${leaked_secret_evidence_dir}/secret-scan.log"
  PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS=true \
  PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS=true \
  PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP=true \
  python3 "${SCRIPT_DIR}/../../IMServer/LoadTests/perf_evidence_manifest.py" \
    --dir "${leaked_secret_evidence_dir}" \
    --write >/dev/null
  rm -f "${leaked_secret_evidence_dir}/SHA256SUMS"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "${leaked_secret_evidence_dir}" && sha256sum ./* >SHA256SUMS)
  else
    (cd "${leaked_secret_evidence_dir}" && shasum -a 256 ./* >SHA256SUMS)
  fi
  if IM_INTERNAL_SECRET="verify-side-secret-0123456789" \
    verify_evidence "${leaked_secret_evidence_dir}" >"${self_test_dir}/leaked-secret-evidence.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=leaked_secret_evidence_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=secret_scan_failed' "${self_test_dir}/leaked-secret-evidence.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=leaked_secret_evidence_reason_missing\n' >&2
    exit 1
  }
  account_artifact_evidence_dir="${self_test_dir}/installed/account-artifact-evidence"
  mkdir -p "${account_artifact_evidence_dir}"
  tar -C "$(readlink -f "${self_test_dir}/installed/current-evidence")" -cf - . | tar -C "${account_artifact_evidence_dir}" -xf -
  printf 'email,password\nload000001@example.com,do-not-verify\n' >"${account_artifact_evidence_dir}/load-10000.csv"
  printf 'perf_secret_scan result=pass scanned=999\n' >"${account_artifact_evidence_dir}/secret-scan.log"
  PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS=true \
  PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS=true \
  PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP=true \
  python3 "${SCRIPT_DIR}/../../IMServer/LoadTests/perf_evidence_manifest.py" \
    --dir "${account_artifact_evidence_dir}" \
    --write >/dev/null
  rm -f "${account_artifact_evidence_dir}/SHA256SUMS"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "${account_artifact_evidence_dir}" && sha256sum ./* >SHA256SUMS)
  else
    (cd "${account_artifact_evidence_dir}" && shasum -a 256 ./* >SHA256SUMS)
  fi
  if verify_evidence "${account_artifact_evidence_dir}" >"${self_test_dir}/account-artifact-evidence.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=account_artifact_evidence_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=secret_scan_failed' "${self_test_dir}/account-artifact-evidence.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=account_artifact_evidence_reason_missing\n' >&2
    exit 1
  }
  bad_product_dir="${self_test_dir}/installed/bad-product-evidence"
  mkdir -p "${bad_product_dir}"
  tar -C "$(readlink -f "${self_test_dir}/installed/current-evidence")" -cf - . | tar -C "${bad_product_dir}" -xf -
  rm -f "${bad_product_dir}/product-test-runbook.json"
  rm -f "${bad_product_dir}/SHA256SUMS"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "${bad_product_dir}" && sha256sum ./* >SHA256SUMS)
  else
    (cd "${bad_product_dir}" && shasum -a 256 ./* >SHA256SUMS)
  fi
  if verify_product_plan_artifact_consistency "${bad_product_dir}" >"${self_test_dir}/bad-product.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=bad_product_plan_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=product_plan_runbook_json_missing' "${self_test_dir}/bad-product.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=bad_product_plan_reason_missing\n' >&2
    exit 1
  }
  failed_product_dir="${self_test_dir}/installed/failed-product-evidence"
  mkdir -p "${failed_product_dir}"
  tar -C "$(readlink -f "${self_test_dir}/installed/current-evidence")" -cf - . | tar -C "${failed_product_dir}" -xf -
  python3 - "${failed_product_dir}/product-test-plan-run.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)
payload["finalStatus"] = "FAIL"
payload["reason"] = "entrypoint_failed"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
  if verify_product_plan_artifact_consistency "${failed_product_dir}" >"${self_test_dir}/failed-product.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=failed_product_plan_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=product_plan_not_pass' "${self_test_dir}/failed-product.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=failed_product_plan_reason_missing\n' >&2
    exit 1
  }
  bad_evidence_dir="${self_test_dir}/installed/bad-evidence"
  mkdir -p "${bad_evidence_dir}"
  tar -C "$(readlink -f "${self_test_dir}/installed/current-evidence")" -cf - . | tar -C "${bad_evidence_dir}" -xf -
  printf '{"profile":"wrong-profile","profileScenarioCount":10,"batchCount":1}\n' >"${bad_evidence_dir}/production-profile-plan.json"
  grep -q 'wrong-profile' "${bad_evidence_dir}/production-profile-plan.json" || {
    printf 'performance_evidence_verify_self_test result=fail reason=bad_profile_not_written\n' >&2
    exit 1
  }
  rm -f "${bad_evidence_dir}/SHA256SUMS"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "${bad_evidence_dir}" && sha256sum ./* >SHA256SUMS)
  else
    (cd "${bad_evidence_dir}" && shasum -a 256 ./* >SHA256SUMS)
  fi
  if verify_profile_artifact_consistency \
    "${bad_evidence_dir}/production-gate.json" \
    "${bad_evidence_dir}/production-profile-run.json" \
    "${bad_evidence_dir}/production-profile-plan.json" \
    "${bad_evidence_dir}/production-profile-prereq-plan.json" \
    "${bad_evidence_dir}/production-profile-prereq-audit.json" \
    "${bad_evidence_dir}/production-profile-scenario-catalog.json" \
    >"${self_test_dir}/bad-consistency.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=profile_consistency_direct_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=profile_plan_mismatch' "${self_test_dir}/bad-consistency.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=profile_consistency_reason_missing\n' >&2
    exit 1
  }
  PERF_PRODUCTION_GATE_JSON="${self_test_dir}/installed/production-gate.json"
  PERF_PRODUCTION_GATE_PROFILE="minimum-smoke"
  PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=0
  PERF_PRODUCTION_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS=true
  if ! bool_enabled "${PERF_PRODUCTION_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS}"; then
    printf 'performance_evidence_verify_self_test result=fail reason=profile_artifacts_flag_false\n' >&2
    exit 1
  fi
  if verify_evidence "${bad_evidence_dir}" >"${self_test_dir}/bad-evidence.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=profile_mismatch_passed\n' >&2
    exit 1
  fi
  grep -q 'result=fail reason=' "${self_test_dir}/bad-evidence.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=profile_mismatch_reason_missing\n' >&2
    exit 1
  }
  missing_inventory_evidence_dir="${self_test_dir}/installed/missing-inventory-evidence"
  mkdir -p "${missing_inventory_evidence_dir}"
  tar -C "$(readlink -f "${self_test_dir}/installed/current-evidence")" -cf - . | tar -C "${missing_inventory_evidence_dir}" -xf -
  rm -f "${missing_inventory_evidence_dir}/validation-inventory.json"
  rm -f "${missing_inventory_evidence_dir}/SHA256SUMS"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "${missing_inventory_evidence_dir}" && sha256sum ./* >SHA256SUMS)
  else
    (cd "${missing_inventory_evidence_dir}" && shasum -a 256 ./* >SHA256SUMS)
  fi
  PERF_PRODUCTION_GATE_JSON="${self_test_dir}/installed/production-gate.json"
  PERF_PRODUCTION_GATE_PROFILE="minimum-smoke"
  PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=0
  PERF_PRODUCTION_EVIDENCE_REQUIRE_VALIDATION_INVENTORY=true
  if verify_evidence "${missing_inventory_evidence_dir}" >"${self_test_dir}/missing-inventory.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=missing_inventory_passed\n' >&2
    exit 1
  fi
  grep -q 'validation-inventory.json' "${self_test_dir}/missing-inventory.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=missing_inventory_reason_missing\n' >&2
    exit 1
  }
  missing_manifest_evidence_dir="${self_test_dir}/installed/missing-manifest-evidence"
  mkdir -p "${missing_manifest_evidence_dir}"
  tar -C "$(readlink -f "${self_test_dir}/installed/current-evidence")" -cf - . | tar -C "${missing_manifest_evidence_dir}" -xf -
  rm -f "${missing_manifest_evidence_dir}/production-evidence-manifest.json"
  rm -f "${missing_manifest_evidence_dir}/SHA256SUMS"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "${missing_manifest_evidence_dir}" && sha256sum ./* >SHA256SUMS)
  else
    (cd "${missing_manifest_evidence_dir}" && shasum -a 256 ./* >SHA256SUMS)
  fi
  PERF_PRODUCTION_GATE_JSON="${self_test_dir}/installed/production-gate.json"
  PERF_PRODUCTION_GATE_PROFILE="minimum-smoke"
  PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=0
  if verify_evidence "${missing_manifest_evidence_dir}" >"${self_test_dir}/missing-manifest.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=missing_manifest_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=manifest_missing' "${self_test_dir}/missing-manifest.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=missing_manifest_reason_missing\n' >&2
    exit 1
  }
  weakened_policy_evidence_dir="${self_test_dir}/installed/weakened-policy-evidence"
  mkdir -p "${weakened_policy_evidence_dir}"
  tar -C "$(readlink -f "${self_test_dir}/installed/current-evidence")" -cf - . | tar -C "${weakened_policy_evidence_dir}" -xf -
  python3 - "${weakened_policy_evidence_dir}/production-evidence-manifest.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)
policy = payload.setdefault("policy", {})
policy["requireProfileArtifacts"] = False
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
  rm -f "${weakened_policy_evidence_dir}/SHA256SUMS"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "${weakened_policy_evidence_dir}" && sha256sum ./* >SHA256SUMS)
  else
    (cd "${weakened_policy_evidence_dir}" && shasum -a 256 ./* >SHA256SUMS)
  fi
  if verify_evidence "${weakened_policy_evidence_dir}" >"${self_test_dir}/weakened-policy.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=weakened_policy_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=manifest_policy_requirement_mismatch' "${self_test_dir}/weakened-policy.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=weakened_policy_reason_missing\n' >&2
    exit 1
  }
  bad_readme_evidence_dir="${self_test_dir}/installed/bad-readme-evidence"
  mkdir -p "${bad_readme_evidence_dir}"
  tar -C "$(readlink -f "${self_test_dir}/installed/current-evidence")" -cf - . | tar -C "${bad_readme_evidence_dir}" -xf -
  perl -0pi -e 's/- productCampaignStatus: `PASS`/- productCampaignStatus: `FAIL`/' "${bad_readme_evidence_dir}/README.md"
  rm -f "${bad_readme_evidence_dir}/SHA256SUMS"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "${bad_readme_evidence_dir}" && sha256sum ./* >SHA256SUMS)
  else
    (cd "${bad_readme_evidence_dir}" && shasum -a 256 ./* >SHA256SUMS)
  fi
  if verify_evidence "${bad_readme_evidence_dir}" >"${self_test_dir}/bad-readme.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=bad_readme_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=readme_product_campaign_status_mismatch' "${self_test_dir}/bad-readme.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=bad_readme_reason_missing\n' >&2
    exit 1
  }
  mismatched_manifest_evidence_dir="${self_test_dir}/installed/mismatched-manifest-evidence"
  mkdir -p "${mismatched_manifest_evidence_dir}"
  tar -C "$(readlink -f "${self_test_dir}/installed/current-evidence")" -cf - . | tar -C "${mismatched_manifest_evidence_dir}" -xf -
  python3 - "${mismatched_manifest_evidence_dir}/production-evidence-manifest.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)
payload["files"][0]["sha256"] = "0" * 64
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
  rm -f "${mismatched_manifest_evidence_dir}/SHA256SUMS"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "${mismatched_manifest_evidence_dir}" && sha256sum ./* >SHA256SUMS)
  else
    (cd "${mismatched_manifest_evidence_dir}" && shasum -a 256 ./* >SHA256SUMS)
  fi
  if verify_evidence "${mismatched_manifest_evidence_dir}" >"${self_test_dir}/mismatched-manifest.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=mismatched_manifest_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=file_sha_mismatch' "${self_test_dir}/mismatched-manifest.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=mismatched_manifest_reason_missing\n' >&2
    exit 1
  }
  mismatched_campaign_gate_evidence_dir="${self_test_dir}/installed/mismatched-campaign-gate-evidence"
  mkdir -p "${mismatched_campaign_gate_evidence_dir}"
  tar -C "$(readlink -f "${self_test_dir}/installed/current-evidence")" -cf - . | tar -C "${mismatched_campaign_gate_evidence_dir}" -xf -
  python3 - "${mismatched_campaign_gate_evidence_dir}/production-evidence-manifest.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)
payload.setdefault("productCampaign", {})["productionGateCampaign"] = False
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
  rm -f "${mismatched_campaign_gate_evidence_dir}/SHA256SUMS"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "${mismatched_campaign_gate_evidence_dir}" && sha256sum ./* >SHA256SUMS)
  else
    (cd "${mismatched_campaign_gate_evidence_dir}" && shasum -a 256 ./* >SHA256SUMS)
  fi
  if verify_evidence "${mismatched_campaign_gate_evidence_dir}" >"${self_test_dir}/mismatched-campaign-gate.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=mismatched_campaign_gate_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=product_campaign_production_gate_mismatch' "${self_test_dir}/mismatched-campaign-gate.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=mismatched_campaign_gate_reason_missing\n' >&2
    exit 1
  }
  diagnostic_campaign_evidence_dir="${self_test_dir}/installed/diagnostic-campaign-evidence"
  mkdir -p "${diagnostic_campaign_evidence_dir}"
  tar -C "$(readlink -f "${self_test_dir}/installed/current-evidence")" -cf - . | tar -C "${diagnostic_campaign_evidence_dir}" -xf -
  python3 - "${diagnostic_campaign_evidence_dir}/product-campaign-run.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)
payload["campaign"] = "product-scenario-regression"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
  PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS=true \
  PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS=true \
  PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP=true \
  python3 "${SCRIPT_DIR}/../../IMServer/LoadTests/perf_evidence_manifest.py" \
    --dir "${diagnostic_campaign_evidence_dir}" --write >/dev/null
  rm -f "${diagnostic_campaign_evidence_dir}/SHA256SUMS"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "${diagnostic_campaign_evidence_dir}" && sha256sum ./* >SHA256SUMS)
  else
    (cd "${diagnostic_campaign_evidence_dir}" && shasum -a 256 ./* >SHA256SUMS)
  fi
  if verify_evidence "${diagnostic_campaign_evidence_dir}" >"${self_test_dir}/diagnostic-campaign.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=diagnostic_campaign_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=product_campaign_not_production_gate' "${self_test_dir}/diagnostic-campaign.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=diagnostic_campaign_reason_missing\n' >&2
    exit 1
  }
  product_manifest_evidence_dir="${self_test_dir}/installed/product-manifest-evidence"
  mkdir -p "${product_manifest_evidence_dir}"
  tar -C "$(readlink -f "${self_test_dir}/installed/current-evidence")" -cf - . | tar -C "${product_manifest_evidence_dir}" -xf -
  rm -f "${product_manifest_evidence_dir}/product-test-runbook.json"
  rm -f "${product_manifest_evidence_dir}/SHA256SUMS"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "${product_manifest_evidence_dir}" && sha256sum ./* >SHA256SUMS)
  else
    (cd "${product_manifest_evidence_dir}" && shasum -a 256 ./* >SHA256SUMS)
  fi
  if verify_evidence "${product_manifest_evidence_dir}" >"${self_test_dir}/product-manifest.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=product_manifest_passed\n' >&2
    exit 1
  fi
  grep -Eq 'reason=(product_plan_present_files_mismatch|product_plan_file_missing|file_not_listed)' "${self_test_dir}/product-manifest.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=product_manifest_reason_missing\n' >&2
    exit 1
  }
  failed_docs_audit_evidence_dir="${self_test_dir}/installed/failed-docs-audit-evidence"
  mkdir -p "${failed_docs_audit_evidence_dir}"
  tar -C "$(readlink -f "${self_test_dir}/installed/current-evidence")" -cf - . | tar -C "${failed_docs_audit_evidence_dir}" -xf -
  python3 - "${failed_docs_audit_evidence_dir}/docs-audit.json" "${failed_docs_audit_evidence_dir}/docs-audit.md" <<'PY'
import json
import sys

path = sys.argv[1]
markdown_path = sys.argv[2]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)
payload["status"] = "FAIL"
payload["errorCount"] = 1
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
with open(markdown_path, encoding="utf-8") as handle:
    markdown = handle.read()
markdown = markdown.replace("- status: `PASS`", "- status: `FAIL`", 1)
markdown = markdown.replace("- errors/warnings: `0/0`", "- errors/warnings: `1/0`", 1)
with open(markdown_path, "w", encoding="utf-8") as handle:
    handle.write(markdown)
PY
  PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS=true \
  python3 "${SCRIPT_DIR}/../../IMServer/LoadTests/perf_evidence_manifest.py" \
    --dir "${failed_docs_audit_evidence_dir}" --write >/dev/null
  rm -f "${failed_docs_audit_evidence_dir}/SHA256SUMS"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "${failed_docs_audit_evidence_dir}" && sha256sum ./* >SHA256SUMS)
  else
    (cd "${failed_docs_audit_evidence_dir}" && shasum -a 256 ./* >SHA256SUMS)
  fi
  if verify_evidence "${failed_docs_audit_evidence_dir}" >"${self_test_dir}/failed-docs-audit.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=failed_docs_audit_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=docs_audit_failed' "${self_test_dir}/failed-docs-audit.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=failed_docs_audit_reason_missing\n' >&2
    exit 1
  }
  mismatched_docs_inventory_evidence_dir="${self_test_dir}/installed/mismatched-docs-inventory-evidence"
  mkdir -p "${mismatched_docs_inventory_evidence_dir}"
  tar -C "$(readlink -f "${self_test_dir}/installed/current-evidence")" -cf - . | tar -C "${mismatched_docs_inventory_evidence_dir}" -xf -
  python3 - "${mismatched_docs_inventory_evidence_dir}/validation-inventory.json" \
    "${mismatched_docs_inventory_evidence_dir}/validation-inventory.md" <<'PY'
import json
import sys

path = sys.argv[1]
markdown_path = sys.argv[2]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)
target_path = "IMServer/LoadTests/run_perf_scenarios.sh"
new_sha = "0" * 64
for record in payload.get("groups", {}).get("shell", []):
    if record.get("path") == target_path:
        old_sha = record.get("sha256")
        record["sha256"] = new_sha
        break
else:
    raise SystemExit("run_perf_scenarios.sh not found in validation inventory")
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
with open(markdown_path, encoding="utf-8") as handle:
    markdown = handle.read()
expected = f"- `{target_path}` `{old_sha}`"
replacement = f"- `{target_path}` `{new_sha}`"
if expected not in markdown:
    raise SystemExit("run_perf_scenarios.sh not found in validation inventory markdown")
with open(markdown_path, "w", encoding="utf-8") as handle:
    handle.write(markdown.replace(expected, replacement, 1))
PY
  PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS=true \
  PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS=true \
  PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP=true \
  python3 "${SCRIPT_DIR}/../../IMServer/LoadTests/perf_evidence_manifest.py" \
    --dir "${mismatched_docs_inventory_evidence_dir}" --write >/dev/null
  rm -f "${mismatched_docs_inventory_evidence_dir}/SHA256SUMS"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "${mismatched_docs_inventory_evidence_dir}" && sha256sum ./* >SHA256SUMS)
  else
    (cd "${mismatched_docs_inventory_evidence_dir}" && shasum -a 256 ./* >SHA256SUMS)
  fi
  if verify_evidence "${mismatched_docs_inventory_evidence_dir}" >"${self_test_dir}/mismatched-docs-inventory.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=mismatched_docs_inventory_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=docs_audit_inventory_sha_mismatch' "${self_test_dir}/mismatched-docs-inventory.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=mismatched_docs_inventory_reason_missing\n' >&2
    exit 1
  }
  missing_catalog_evidence_dir="${self_test_dir}/installed/missing-catalog-evidence"
  mkdir -p "${missing_catalog_evidence_dir}"
  tar -C "$(readlink -f "${self_test_dir}/installed/current-evidence")" -cf - . | tar -C "${missing_catalog_evidence_dir}" -xf -
  rm -f "${missing_catalog_evidence_dir}/perf_production_profiles.json"
  rm -f "${missing_catalog_evidence_dir}/SHA256SUMS"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "${missing_catalog_evidence_dir}" && sha256sum ./* >SHA256SUMS)
  else
    (cd "${missing_catalog_evidence_dir}" && shasum -a 256 ./* >SHA256SUMS)
  fi
  PERF_PRODUCTION_GATE_JSON="${self_test_dir}/installed/production-gate.json"
  PERF_PRODUCTION_GATE_PROFILE="minimum-smoke"
  PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=0
  if verify_evidence "${missing_catalog_evidence_dir}" >"${self_test_dir}/missing-catalog.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=missing_catalog_passed\n' >&2
    exit 1
  fi
  grep -q 'perf_production_profiles.json' "${self_test_dir}/missing-catalog.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=missing_catalog_reason_missing\n' >&2
    exit 1
  }
  mismatched_catalog_evidence_dir="${self_test_dir}/installed/mismatched-catalog-evidence"
  mkdir -p "${mismatched_catalog_evidence_dir}"
  tar -C "$(readlink -f "${self_test_dir}/installed/current-evidence")" -cf - . | tar -C "${mismatched_catalog_evidence_dir}" -xf -
  printf '{"schemaVersion":1,"profiles":{"wrong":["login-smoke"]}}\n' >"${mismatched_catalog_evidence_dir}/perf_production_profiles.json"
  rm -f "${mismatched_catalog_evidence_dir}/SHA256SUMS"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "${mismatched_catalog_evidence_dir}" && sha256sum ./* >SHA256SUMS)
  else
    (cd "${mismatched_catalog_evidence_dir}" && shasum -a 256 ./* >SHA256SUMS)
  fi
  if verify_evidence "${mismatched_catalog_evidence_dir}" >"${self_test_dir}/mismatched-catalog.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=mismatched_catalog_passed\n' >&2
    exit 1
  fi
  grep -q 'perf_production_profiles.json' "${self_test_dir}/mismatched-catalog.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=mismatched_catalog_reason_missing\n' >&2
    exit 1
  }
  mismatched_inventory_evidence_dir="${self_test_dir}/installed/mismatched-inventory-evidence"
  mkdir -p "${mismatched_inventory_evidence_dir}"
  tar -C "$(readlink -f "${self_test_dir}/installed/current-evidence")" -cf - . | tar -C "${mismatched_inventory_evidence_dir}" -xf -
  python3 - "${mismatched_inventory_evidence_dir}/validation-inventory.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)
payload.setdefault("source", {})["gitCommit"] = "0" * 40
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
  rm -f "${mismatched_inventory_evidence_dir}/SHA256SUMS"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "${mismatched_inventory_evidence_dir}" && sha256sum ./* >SHA256SUMS)
  else
    (cd "${mismatched_inventory_evidence_dir}" && shasum -a 256 ./* >SHA256SUMS)
  fi
  PERF_PRODUCTION_GATE_JSON="${self_test_dir}/installed/production-gate.json"
  PERF_PRODUCTION_GATE_PROFILE="minimum-smoke"
  PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=0
  PERF_PRODUCTION_EVIDENCE_REQUIRE_VALIDATION_INVENTORY=true
  if verify_evidence "${mismatched_inventory_evidence_dir}" >"${self_test_dir}/mismatched-inventory.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=mismatched_inventory_passed\n' >&2
    exit 1
  fi
  grep -q 'validation-inventory.json' "${self_test_dir}/mismatched-inventory.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=mismatched_inventory_reason_missing\n' >&2
    exit 1
  }
  failed_entrypoint_evidence_dir="${self_test_dir}/installed/failed-entrypoint-evidence"
  mkdir -p "${failed_entrypoint_evidence_dir}"
  tar -C "$(readlink -f "${self_test_dir}/installed/current-evidence")" -cf - . | tar -C "${failed_entrypoint_evidence_dir}" -xf -
  python3 - "${failed_entrypoint_evidence_dir}/production-profile-entrypoint-probe.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)
payload["diagnosis"] = "uniform_empty_403"
payload["failed"] = True
payload["blocker"] = {
    "type": "entrypoint",
    "severity": "P0",
    "preventsPerformanceEvidence": True,
    "action": "repair_entrypoint",
    "reason": "Every probe returned empty 403.",
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
  if verify_profile_artifact_consistency \
    "${failed_entrypoint_evidence_dir}/production-gate.json" \
    "${failed_entrypoint_evidence_dir}/production-profile-run.json" \
    "${failed_entrypoint_evidence_dir}/production-profile-plan.json" \
    "${failed_entrypoint_evidence_dir}/production-profile-prereq-plan.json" \
    "${failed_entrypoint_evidence_dir}/production-profile-prereq-audit.json" \
    "${failed_entrypoint_evidence_dir}/production-profile-scenario-catalog.json" \
    >"${self_test_dir}/failed-entrypoint-consistency.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=failed_entrypoint_probe_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=profile_entrypoint_probe_failed' "${self_test_dir}/failed-entrypoint-consistency.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=failed_entrypoint_probe_reason_missing\n' >&2
    exit 1
  }
  dry_run_evidence_dir="${self_test_dir}/installed/dry-run-evidence"
  mkdir -p "${dry_run_evidence_dir}"
  tar -C "$(readlink -f "${self_test_dir}/installed/current-evidence")" -cf - . | tar -C "${dry_run_evidence_dir}" -xf -
  python3 - "${dry_run_evidence_dir}/production-profile-run.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)
payload["dryRun"] = True
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
  if verify_profile_artifact_consistency \
    "${dry_run_evidence_dir}/production-gate.json" \
    "${dry_run_evidence_dir}/production-profile-run.json" \
    "${dry_run_evidence_dir}/production-profile-plan.json" \
    "${dry_run_evidence_dir}/production-profile-prereq-plan.json" \
    "${dry_run_evidence_dir}/production-profile-prereq-audit.json" \
    "${dry_run_evidence_dir}/production-profile-scenario-catalog.json" \
    >"${self_test_dir}/dry-run-consistency.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=dry_run_receipt_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=profile_run_is_dry_run' "${self_test_dir}/dry-run-consistency.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=dry_run_reason_missing\n' >&2
    exit 1
  }
  partial_run_evidence_dir="${self_test_dir}/installed/partial-run-evidence"
  mkdir -p "${partial_run_evidence_dir}"
  tar -C "$(readlink -f "${self_test_dir}/installed/current-evidence")" -cf - . | tar -C "${partial_run_evidence_dir}" -xf -
  python3 - "${partial_run_evidence_dir}/production-profile-run.json" "${partial_run_evidence_dir}/production-profile-prereq-plan.json" <<'PY'
import json
import sys

run_path, prereq_path = sys.argv[1:3]
with open(run_path, encoding="utf-8") as handle:
    run = json.load(handle)
with open(prereq_path, encoding="utf-8") as handle:
    prereq = json.load(handle)
selected_count = 2
run["plan"]["selectedScenarioCount"] = selected_count
run["plan"]["skippedFreshPassCount"] = max(0, int(run["plan"].get("profileScenarioCount") or 0) - selected_count)
prereq["selectedScenarios"] = ["login-smoke", "auth-session-smoke"]
with open(run_path, "w", encoding="utf-8") as handle:
    json.dump(run, handle, indent=2, sort_keys=True)
with open(prereq_path, "w", encoding="utf-8") as handle:
    json.dump(prereq, handle, indent=2, sort_keys=True)
PY
  if verify_profile_artifact_consistency \
    "${partial_run_evidence_dir}/production-gate.json" \
    "${partial_run_evidence_dir}/production-profile-run.json" \
    "${partial_run_evidence_dir}/production-profile-plan.json" \
    "${partial_run_evidence_dir}/production-profile-prereq-plan.json" \
    "${partial_run_evidence_dir}/production-profile-prereq-audit.json" \
    "${partial_run_evidence_dir}/production-profile-scenario-catalog.json" \
    >"${self_test_dir}/partial-run-consistency.log" 2>&1; then
    printf 'performance_evidence_verify_self_test result=fail reason=partial_run_passed\n' >&2
    exit 1
  fi
  grep -Eq 'reason=(profile_run_scenario_count_mismatch|profile_run_batch_selection_mismatch|profile_runbook_selected_count_mismatch)' "${self_test_dir}/partial-run-consistency.log" || {
    printf 'performance_evidence_verify_self_test result=fail reason=partial_run_reason_missing\n' >&2
    exit 1
  }
  printf 'performance_evidence_verify_self_test result=pass\n'
  exit 0
fi

verify_evidence "${PERF_PRODUCTION_EVIDENCE_CURRENT_LINK}"
