#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT_ROOT="${RESULT_ROOT:-${SCRIPT_DIR}/results}"
RESULT_ROOT="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve())' "${RESULT_ROOT}")"
PERF_PRODUCTION_GATE_PROFILE="${PERF_PRODUCTION_GATE_PROFILE:-normal-product-baseline}"
PERF_PRODUCTION_PROFILE_CATALOG="${PERF_PRODUCTION_PROFILE_CATALOG:-${SCRIPT_DIR}/perf_production_profiles.json}"
PERF_PRODUCTION_GATE_MAX_AGE_SECONDS="${PERF_PRODUCTION_GATE_MAX_AGE_SECONDS:-604800}"
PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET="${PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET:-}"
PRODUCTION_PROFILE_BATCH_SIZE="${PRODUCTION_PROFILE_BATCH_SIZE:-6}"
PRODUCTION_PROFILE_RESUME_PASS="${PRODUCTION_PROFILE_RESUME_PASS:-true}"
PRODUCTION_PROFILE_PACKAGE="${PRODUCTION_PROFILE_PACKAGE:-true}"
PRODUCTION_PROFILE_STOP_ON_FAILURE="${PRODUCTION_PROFILE_STOP_ON_FAILURE:-true}"
PRODUCTION_PROFILE_PREFLIGHT="${PRODUCTION_PROFILE_PREFLIGHT:-true}"
PRODUCTION_PROFILE_PREREQ_GATE="${PRODUCTION_PROFILE_PREREQ_GATE:-true}"
PRODUCTION_PROFILE_OPERATOR_NETWORK_PREFLIGHT="${PRODUCTION_PROFILE_OPERATOR_NETWORK_PREFLIGHT:-true}"
PRODUCTION_PROFILE_FAIL_ON_OPERATOR_NETWORK="${PRODUCTION_PROFILE_FAIL_ON_OPERATOR_NETWORK:-true}"
PRODUCTION_PROFILE_FAIL_ON_LOCAL_NETWORK="${PRODUCTION_PROFILE_FAIL_ON_LOCAL_NETWORK:-${PRODUCTION_PROFILE_FAIL_ON_OPERATOR_NETWORK}}"
PRODUCTION_PROFILE_OPERATOR_NETWORK_PREFLIGHT_SCRIPT="${PRODUCTION_PROFILE_OPERATOR_NETWORK_PREFLIGHT_SCRIPT:-${SCRIPT_DIR}/../../deploy/ubuntu/20_verify_operator_network.sh}"
PRODUCTION_PROFILE_OPERATOR_NETWORK_LOG="${PRODUCTION_PROFILE_OPERATOR_NETWORK_LOG:-${RESULT_ROOT}/production-profile-operator-network.log}"
PRODUCTION_PROFILE_OPERATOR_NETWORK_JSON="${PRODUCTION_PROFILE_OPERATOR_NETWORK_JSON:-${RESULT_ROOT}/production-profile-operator-network.json}"
PRODUCTION_PROFILE_ENTRYPOINT_PROBE="${PRODUCTION_PROFILE_ENTRYPOINT_PROBE:-true}"
PRODUCTION_PROFILE_REQUIRE_PRODUCT_PLAN_ARTIFACTS="${PRODUCTION_PROFILE_REQUIRE_PRODUCT_PLAN_ARTIFACTS:-${PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS:-true}}"
PRODUCTION_PROFILE_REQUIRE_PUBLIC_TARGET="${PRODUCTION_PROFILE_REQUIRE_PUBLIC_TARGET:-}"
PERF_STATUS_FILTER_TARGET="${PERF_STATUS_FILTER_TARGET:-true}"
PRODUCTION_PROFILE_RUN_ID_PREFIX="${PRODUCTION_PROFILE_RUN_ID_PREFIX:-production-${PERF_PRODUCTION_GATE_PROFILE}-$(date +%Y%m%d-%H%M%S)}"
PRODUCTION_PROFILE_PLAN_JSON="${PRODUCTION_PROFILE_PLAN_JSON:-${RESULT_ROOT}/production-profile-plan.json}"
PRODUCTION_PROFILE_PREREQ_PLAN_JSON="${PRODUCTION_PROFILE_PREREQ_PLAN_JSON:-${RESULT_ROOT}/production-profile-prereq-plan.json}"
PRODUCTION_PROFILE_SCENARIO_CATALOG_JSON="${PRODUCTION_PROFILE_SCENARIO_CATALOG_JSON:-${RESULT_ROOT}/production-profile-scenario-catalog.json}"
PRODUCTION_PROFILE_PREREQ_AUDIT_JSON="${PRODUCTION_PROFILE_PREREQ_AUDIT_JSON:-${RESULT_ROOT}/production-profile-prereq-audit.json}"
PRODUCTION_PROFILE_PREREQ_AUDIT_MD="${PRODUCTION_PROFILE_PREREQ_AUDIT_MD:-${RESULT_ROOT}/production-profile-prereq-audit.md}"
PRODUCTION_PROFILE_ENTRYPOINT_PROBE_LOG="${PRODUCTION_PROFILE_ENTRYPOINT_PROBE_LOG:-${RESULT_ROOT}/production-profile-entrypoint-probe.log}"
PRODUCTION_PROFILE_ENTRYPOINT_PROBE_JSON="${PRODUCTION_PROFILE_ENTRYPOINT_PROBE_JSON:-${RESULT_ROOT}/production-profile-entrypoint-probe.json}"
PRODUCTION_PROFILE_ENTRYPOINT_RESCUE_ARTIFACT="${PRODUCTION_PROFILE_ENTRYPOINT_RESCUE_ARTIFACT:-true}"
PRODUCTION_PROFILE_ENTRYPOINT_RESCUE_ARTIFACT_DIR="${PRODUCTION_PROFILE_ENTRYPOINT_RESCUE_ARTIFACT_DIR:-${RESULT_ROOT}/current-node-access-rescue}"
PRODUCTION_PROFILE_ENTRYPOINT_RESCUE_ARTIFACT_PACKAGE="${PRODUCTION_PROFILE_ENTRYPOINT_RESCUE_ARTIFACT_PACKAGE:-true}"
PRODUCTION_PROFILE_REQUIRE_CLOUD_SECURITY_GROUP="${PRODUCTION_PROFILE_REQUIRE_CLOUD_SECURITY_GROUP:-${PRODUCTION_PROFILE_PACKAGE}}"
PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_AUDIT_SCRIPT="${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_AUDIT_SCRIPT:-${SCRIPT_DIR}/../../deploy/ubuntu/26_audit_cloud_security_group.sh}"
PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_VERIFY_SCRIPT="${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_VERIFY_SCRIPT:-${SCRIPT_DIR}/../../deploy/ubuntu/31_verify_aliyun_security_group_repair_receipt.sh}"
PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_AUDIT_LOG="${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_AUDIT_LOG:-${RESULT_ROOT}/production-profile-cloud-security-group-audit.log}"
PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_VERIFY_LOG="${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_VERIFY_LOG:-${RESULT_ROOT}/production-profile-cloud-security-group-repair-receipt-verify.log}"
PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS="${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS:-${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS:-80 443 9000}}"
PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS="${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS:-${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS:-3389 5432 6379 9092 8081 8082 18080 8080}}"
PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_ADMIN_PORTS="${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_ADMIN_PORTS:-${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ADMIN_PORTS:-22}}"
PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS="${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS:-${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS:-}}"
PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS="${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS:-${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS:-86400}}"
PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080="${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080:-${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080:-false}}"
PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP="${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP:-${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP:-true}}"
PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX="${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX:-${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX:-8}}"
PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX="${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX:-${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX:-16}}"
PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX="${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX:-${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX:-32}}"
PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX="${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX:-${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX:-128}}"
PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS="${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS:-${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS:-${ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS:-86400}}}"
PRODUCTION_PROFILE_RUNBOOK_JSON="${PRODUCTION_PROFILE_RUNBOOK_JSON:-${RESULT_ROOT}/production-profile-runbook.json}"
PRODUCTION_PROFILE_RUNBOOK_MD="${PRODUCTION_PROFILE_RUNBOOK_MD:-${RESULT_ROOT}/production-profile-runbook.md}"
PRODUCTION_PROFILE_RUN_JSON="${PRODUCTION_PROFILE_RUN_JSON:-${RESULT_ROOT}/production-profile-run.json}"
PRODUCTION_PROFILE_BATCH_STATUS_TSV="${PRODUCTION_PROFILE_BATCH_STATUS_TSV:-${RESULT_ROOT}/production-profile-batches.tsv}"
PRODUCT_TEST_PLAN_JSON="${PRODUCT_TEST_PLAN_JSON:-${RESULT_ROOT}/product-test-plan-run.json}"
PRODUCT_TEST_PLAN_PREVIEW_JSON="${PRODUCT_TEST_PLAN_PREVIEW_JSON:-${RESULT_ROOT}/product-test-plan-preview.json}"
PRODUCT_TEST_PREREQ_PLAN_JSON="${PRODUCT_TEST_PREREQ_PLAN_JSON:-${RESULT_ROOT}/product-test-prereq-plan.json}"
PRODUCT_TEST_PREREQ_AUDIT_JSON="${PRODUCT_TEST_PREREQ_AUDIT_JSON:-${RESULT_ROOT}/product-test-prereq-audit.json}"
PRODUCT_TEST_RUNBOOK_JSON="${PRODUCT_TEST_RUNBOOK_JSON:-${RESULT_ROOT}/product-test-runbook.json}"
PRODUCTION_PROFILE_SELF_TEST="${PRODUCTION_PROFILE_SELF_TEST:-false}"
PERF_DRY_RUN="${PERF_DRY_RUN:-false}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_production_profile_require_public_target() {
  if [[ -n "${PRODUCTION_PROFILE_REQUIRE_PUBLIC_TARGET}" ]]; then
    printf '%s\n' "${PRODUCTION_PROFILE_REQUIRE_PUBLIC_TARGET}"
  elif bool_enabled "${PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET}"; then
    printf 'true\n'
  else
    printf '%s\n' "${PRODUCTION_PROFILE_PACKAGE}"
  fi
}

PRODUCTION_PROFILE_REQUIRE_PUBLIC_TARGET_EFFECTIVE="$(resolve_production_profile_require_public_target)"

host_from_url() {
  python3 - "$1" <<'PY'
from urllib.parse import urlparse
import sys

parsed = urlparse(sys.argv[1])
print(parsed.hostname or "")
PY
}

validate_public_target() {
  if ! bool_enabled "${PRODUCTION_PROFILE_REQUIRE_PUBLIC_TARGET_EFFECTIVE}"; then
    return 0
  fi
  if bool_enabled "${PERF_DRY_RUN}"; then
    return 0
  fi
  python3 - "${BASE_URL_EFFECTIVE}" "${TCP_HOST_EFFECTIVE}" <<'PY'
import ipaddress
import sys
from urllib.parse import urlparse

base_url, tcp_host = sys.argv[1:3]

def host_reason(host: str) -> str:
    value = host.strip().lower().strip("[]")
    if not value:
        return "missing"
    if value in {"localhost", "127.0.0.1", "::1", "0.0.0.0"}:
        return "local"
    try:
        ipaddress.ip_address(value)
        return "ip"
    except ValueError:
        pass
    if "." not in value:
        return "single_label"
    placeholder_hosts = {"example.com", "example.net", "example.org", "yourdomain.com"}
    placeholder_suffixes = (
        ".example",
        ".example.com",
        ".example.net",
        ".example.org",
        ".yourdomain.com",
        ".test",
        ".invalid",
    )
    if value in placeholder_hosts or any(value.endswith(suffix) for suffix in placeholder_suffixes):
        return "placeholder"
    return ""

parsed = urlparse(base_url)
if parsed.scheme != "https":
    raise SystemExit(
        f"production_profile result=fail reason=public_base_url_https_required "
        f"baseURL={base_url or '<empty>'} "
        "hint=use_real_https_domain_or_set_PRODUCTION_PROFILE_REQUIRE_PUBLIC_TARGET=false_for_diagnostics"
    )
try:
    base_port = parsed.port or 443
except ValueError:
    raise SystemExit(
        f"production_profile result=fail reason=public_base_url_port_invalid "
        f"baseURL={base_url or '<empty>'}"
    )
if base_port != 443:
    raise SystemExit(
        f"production_profile result=fail reason=public_base_url_default_https_port_required "
        f"baseURL={base_url or '<empty>'} port={base_port}"
    )
base_host = parsed.hostname or ""
base_reason = host_reason(base_host)
if base_reason:
    raise SystemExit(
        f"production_profile result=fail reason=public_base_url_domain_required "
        f"baseURL={base_url or '<empty>'} host={base_host or '<none>'} hostReason={base_reason}"
    )
tcp_reason = host_reason(tcp_host)
if tcp_reason:
    raise SystemExit(
        f"production_profile result=fail reason=tcp_host_domain_required "
        f"tcpHost={tcp_host or '<none>'} hostReason={tcp_reason}"
    )
PY
}

profile_cloud_security_group_rules_file() {
  printf '%s\n' "${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_FILE:-${CLOUD_SECURITY_GROUP_RULES_FILE:-}}"
}

profile_cloud_security_group_repair_receipt_json() {
  printf '%s\n' "${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON:-${ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_JSON:-}}"
}

profile_cloud_security_group_expected_security_group_id() {
  printf '%s\n' "${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID:-${ALIYUN_SECURITY_GROUP_ID:-}}"
}

profile_cloud_security_group_expected_region_id() {
  printf '%s\n' "${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID:-${ALIYUN_REGION_ID:-}}"
}

profile_cloud_security_group_expected_admin_cidr() {
  printf '%s\n' "${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR:-${ALIYUN_SECURITY_GROUP_ADMIN_CIDR:-}}"
}

verify_required_cloud_security_group_evidence() {
  if ! bool_enabled "${PRODUCTION_PROFILE_REQUIRE_CLOUD_SECURITY_GROUP}"; then
    return 0
  fi
  if bool_enabled "${PERF_DRY_RUN}"; then
    return 0
  fi

  local rules_file receipt security_group_id region_id admin_cidr
  rules_file="$(profile_cloud_security_group_rules_file)"
  receipt="$(profile_cloud_security_group_repair_receipt_json)"
  security_group_id="$(profile_cloud_security_group_expected_security_group_id)"
  region_id="$(profile_cloud_security_group_expected_region_id)"
  admin_cidr="$(profile_cloud_security_group_expected_admin_cidr)"

  if [[ -z "${rules_file}" ]]; then
    printf 'production_profile result=fail reason=cloud_security_group_snapshot_required hint=set_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_FILE_or_CLOUD_SECURITY_GROUP_RULES_FILE\n' >&2
    return 1
  fi
  if [[ ! -f "${rules_file}" ]]; then
    printf 'production_profile result=fail reason=cloud_security_group_snapshot_missing path=%s\n' "${rules_file}" >&2
    return 1
  fi
  if [[ -z "${receipt}" ]]; then
    printf 'production_profile result=fail reason=cloud_security_group_repair_receipt_required hint=set_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON_or_ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_JSON\n' >&2
    return 1
  fi
  if [[ ! -f "${receipt}" ]]; then
    printf 'production_profile result=fail reason=cloud_security_group_repair_receipt_missing path=%s\n' "${receipt}" >&2
    return 1
  fi
  if [[ -z "${security_group_id}" ]]; then
    printf 'production_profile result=fail reason=cloud_security_group_repair_receipt_expected_security_group_id_required hint=set_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID_or_ALIYUN_SECURITY_GROUP_ID\n' >&2
    return 1
  fi
  if [[ -z "${region_id}" ]]; then
    printf 'production_profile result=fail reason=cloud_security_group_repair_receipt_expected_region_id_required hint=set_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID_or_ALIYUN_REGION_ID\n' >&2
    return 1
  fi
  if [[ -z "${admin_cidr}" ]]; then
    printf 'production_profile result=fail reason=cloud_security_group_repair_receipt_expected_admin_cidr_required hint=set_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR_or_ALIYUN_SECURITY_GROUP_ADMIN_CIDR\n' >&2
    return 1
  fi
  if [[ ! -f "${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_AUDIT_SCRIPT}" ]]; then
    printf 'production_profile result=fail reason=cloud_security_group_audit_script_missing path=%s\n' \
      "${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_AUDIT_SCRIPT}" >&2
    return 1
  fi
  if [[ ! -f "${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_VERIFY_SCRIPT}" ]]; then
    printf 'production_profile result=fail reason=cloud_security_group_repair_receipt_verify_script_missing path=%s\n' \
      "${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_VERIFY_SCRIPT}" >&2
    return 1
  fi

  mkdir -p "${RESULT_ROOT}"
  if ! CLOUD_SECURITY_GROUP_RULES_FILE="${rules_file}" \
    CLOUD_SECURITY_GROUP_PROFILE=production \
    CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS="${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS}" \
    CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS="${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS}" \
    CLOUD_SECURITY_GROUP_ADMIN_PORTS="${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_ADMIN_PORTS}" \
    CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS="${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS}" \
    CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS="${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS}" \
    CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER=false \
    CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080="${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080}" \
    CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP="${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP}" \
    CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX="${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX}" \
    CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX="${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX}" \
    CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX="${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX}" \
    CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX="${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX}" \
      bash "${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_AUDIT_SCRIPT}" >"${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_AUDIT_LOG}" 2>&1; then
    printf 'production_profile result=fail reason=cloud_security_group_snapshot_invalid log=%s\n' \
      "${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_AUDIT_LOG}" >&2
    sed -n '1,40p' "${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_AUDIT_LOG}" >&2 || true
    return 1
  fi

  if ! ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${receipt}" \
    ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_REQUIRE_APPLIED=true \
    ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_REQUIRE_VERIFIED=true \
    ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS="${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS}" \
    ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID="${security_group_id}" \
    ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID="${region_id}" \
    ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR="${admin_cidr}" \
    ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_PUBLIC_CLIENT_PORTS="${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS}" \
    ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_PORTS="${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_ADMIN_PORTS}" \
    ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_DENY_PUBLIC_PORTS="${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS}" \
      bash "${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_VERIFY_SCRIPT}" >"${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_VERIFY_LOG}" 2>&1; then
    printf 'production_profile result=fail reason=cloud_security_group_repair_receipt_invalid log=%s\n' \
      "${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_VERIFY_LOG}" >&2
    sed -n '1,40p' "${PRODUCTION_PROFILE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_VERIFY_LOG}" >&2 || true
    return 1
  fi
}

BASE_URL_EFFECTIVE="${BASE_URL:-http://127.0.0.1:8080}"
TCP_HOST_EFFECTIVE="${TCP_HOST:-}"
if [[ -z "${TCP_HOST_EFFECTIVE}" ]]; then
  TCP_HOST_EFFECTIVE="$(host_from_url "${BASE_URL_EFFECTIVE}")"
fi
TCP_HOST_EFFECTIVE="${TCP_HOST_EFFECTIVE:-127.0.0.1}"
TCP_PORT_EFFECTIVE="${TCP_PORT:-9000}"
PUBLIC_BASE_URL_EFFECTIVE="${PUBLIC_BASE_URL:-${BASE_URL_EFFECTIVE}}"

write_plan() {
  local output_json="$1"
  local slo_status_json="${RESULT_ROOT}/slo-status.json"
  python3 - \
    "${PERF_PRODUCTION_PROFILE_CATALOG}" \
    "${PERF_PRODUCTION_GATE_PROFILE}" \
    "${slo_status_json}" \
    "${PRODUCTION_PROFILE_BATCH_SIZE}" \
    "${PRODUCTION_PROFILE_RESUME_PASS}" \
    "${PERF_PRODUCTION_GATE_MAX_AGE_SECONDS}" \
    "${output_json}" <<'PY'
import json
import sys
import time
from pathlib import Path

catalog_path, profile, slo_status_path, batch_size_raw, resume_raw, max_age_raw, output_path = sys.argv[1:8]
try:
    batch_size = int(batch_size_raw)
except ValueError:
    raise SystemExit(f"production_profile result=fail reason=invalid_batch_size value={batch_size_raw}")
if batch_size <= 0:
    raise SystemExit(f"production_profile result=fail reason=invalid_batch_size value={batch_size}")
resume = resume_raw.lower() in {"1", "true", "yes", "on"}
try:
    max_age = int(max_age_raw)
except ValueError:
    raise SystemExit(f"production_profile result=fail reason=invalid_max_age value={max_age_raw}")
if max_age < 0:
    raise SystemExit(f"production_profile result=fail reason=invalid_max_age value={max_age}")

with open(catalog_path, encoding="utf-8") as handle:
    catalog = json.load(handle)
profiles = catalog.get("profiles") or {}
scenarios = list(profiles.get(profile) or [])
if not scenarios:
    raise SystemExit(f"production_profile result=fail reason=unknown_or_empty_profile profile={profile}")

slo_rows = {}
slo_path = Path(slo_status_path)
if slo_path.exists():
    with open(slo_path, encoding="utf-8") as handle:
        for row in (json.load(handle).get("scenarios") or []):
            scenario = str(row.get("scenario") or "")
            if scenario:
                slo_rows[scenario] = row

now = time.time()
selected = []
skipped = []
for scenario in scenarios:
    row = slo_rows.get(scenario) or {}
    status = str(row.get("latestSLOStatus") or "")
    run_count = int(row.get("runCount") or 0)
    try:
        latest_mtime = float(row.get("latestMtime") or 0)
    except (TypeError, ValueError):
        latest_mtime = 0
    fresh = max_age <= 0 or (latest_mtime > 0 and now - latest_mtime <= max_age)
    if resume and status == "PASS" and run_count > 0 and fresh:
        skipped.append({"scenario": scenario, "latestMtime": latest_mtime, "runCount": run_count})
    else:
        selected.append(scenario)

batches = [
    {"index": batch_index, "scenarios": selected[index:index + batch_size]}
    for batch_index, index in enumerate(range(0, len(selected), batch_size), start=1)
]
payload = {
    "profile": profile,
    "profileScenarioCount": len(scenarios),
    "selectedScenarioCount": len(selected),
    "skippedFreshPassCount": len(skipped),
    "batchSize": batch_size,
    "batchCount": len(batches),
    "resumeFreshPass": resume,
    "maxAgeSeconds": max_age,
    "batches": batches,
    "skippedFreshPassScenarios": skipped,
}
Path(output_path).parent.mkdir(parents=True, exist_ok=True)
Path(output_path).write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
for batch in batches:
    print(f"{batch['index']}\t{' '.join(batch['scenarios'])}")
PY
}

run_prereq_gate() {
  local scenario_status_json="${RESULT_ROOT}/scenario-status.json"
  local catalog_args=()

  if ! bool_enabled "${PRODUCTION_PROFILE_PREREQ_GATE}"; then
    printf 'production_profile prereq=skipped reason=disabled\n'
    return 0
  fi

  python3 - "${PRODUCTION_PROFILE_PLAN_JSON}" "${PRODUCTION_PROFILE_PREREQ_PLAN_JSON}" <<'PY'
import json
import sys
from pathlib import Path

plan_path, output_path = sys.argv[1:3]
with open(plan_path, encoding="utf-8") as handle:
    plan = json.load(handle)
scenarios = []
for batch in plan.get("batches") or []:
    scenarios.extend(str(item) for item in (batch.get("scenarios") or []) if item)
payload = {
    "status": "READY" if scenarios else "NO_SCENARIOS",
    "profile": plan.get("profile"),
    "selectedScenarios": scenarios,
}

Path(output_path).write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY

  if python3 - "${PRODUCTION_PROFILE_PREREQ_PLAN_JSON}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
raise SystemExit(0 if payload.get("selectedScenarios") else 1)
PY
  then
    if [[ -f "${scenario_status_json}" ]]; then
      catalog_args+=(--scenario-status "${scenario_status_json}")
      python3 "${SCRIPT_DIR}/perf_scenario_catalog.py" \
      --script "${SCRIPT_DIR}/run_perf_scenarios.sh" \
      "${catalog_args[@]}" \
      --json-output "${PRODUCTION_PROFILE_SCENARIO_CATALOG_JSON}" >/dev/null
    else
      python3 "${SCRIPT_DIR}/perf_scenario_catalog.py" \
      --script "${SCRIPT_DIR}/run_perf_scenarios.sh" \
      --json-output "${PRODUCTION_PROFILE_SCENARIO_CATALOG_JSON}" >/dev/null
    fi

    python3 "${SCRIPT_DIR}/perf_prereq_audit.py" \
      --scenario-catalog "${PRODUCTION_PROFILE_SCENARIO_CATALOG_JSON}" \
      --domain-run-plan "${PRODUCTION_PROFILE_PREREQ_PLAN_JSON}" \
      --base-url "${BASE_URL_EFFECTIVE}" \
      --tcp-host "${TCP_HOST_EFFECTIVE}" \
      --tcp-port "${TCP_PORT_EFFECTIVE}" \
      --account-file "${ACCOUNT_FILE:-}" \
      --conversation-id "${IM_CONVERSATION_ID:-}" \
      --internal-secret "${IM_INTERNAL_SECRET:-${IM_INTERNAL_SHARED_SECRET:-}}" \
      --auth-email-webhook-url "${IM_AUTH_EMAIL_WEBHOOK_SINK_URL:-}" \
      --verification-code "${IM_ACCOUNT_VERIFICATION_CODE:-}" \
      --password-reset-code "${IM_ACCOUNT_PASSWORD_RESET_CODE:-}" \
      --output "${PRODUCTION_PROFILE_PREREQ_AUDIT_MD}" \
      --json-output "${PRODUCTION_PROFILE_PREREQ_AUDIT_JSON}" \
      --strict || return 1
    python3 - "${PRODUCTION_PROFILE_PREREQ_AUDIT_JSON}" <<'PY' || return 1
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
summary = payload.get("summary") or {}
if summary.get("overallStatus") == "BLOCKED":
    raise SystemExit(
        "production_profile prereq=fail "
        f"reason=blocked missingRequired={summary.get('missingRequiredCount')}"
    )
PY
    printf 'production_profile prereq=pass audit=%s\n' "${PRODUCTION_PROFILE_PREREQ_AUDIT_JSON}"
  else
    printf 'production_profile prereq=skipped reason=no_selected_scenarios\n'
  fi
}

run_operator_network_preflight() {
  if ! bool_enabled "${PRODUCTION_PROFILE_OPERATOR_NETWORK_PREFLIGHT}"; then
    printf 'production_profile operator_network=skipped reason=disabled\n'
    return 0
  fi
  if bool_enabled "${PERF_DRY_RUN}"; then
    printf 'production_profile operator_network=skipped reason=dry_run\n'
    return 0
  fi
  if [[ ! -f "${PRODUCTION_PROFILE_OPERATOR_NETWORK_PREFLIGHT_SCRIPT}" ]]; then
    printf 'production_profile operator_network=skipped reason=script_missing path=%s\n' \
      "${PRODUCTION_PROFILE_OPERATOR_NETWORK_PREFLIGHT_SCRIPT}"
    return 0
  fi

  mkdir -p "${RESULT_ROOT}"
  printf 'production_profile operator_network=start log=%s json=%s\n' "${PRODUCTION_PROFILE_OPERATOR_NETWORK_LOG}" "${PRODUCTION_PROFILE_OPERATOR_NETWORK_JSON}"
  set +e
  OPERATOR_NETWORK_JSON_OUTPUT="${PRODUCTION_PROFILE_OPERATOR_NETWORK_JSON}" \
    bash "${PRODUCTION_PROFILE_OPERATOR_NETWORK_PREFLIGHT_SCRIPT}" \
    "${BASE_URL_EFFECTIVE}" \
    "${TCP_HOST_EFFECTIVE}:${TCP_PORT_EFFECTIVE}" \
    >"${PRODUCTION_PROFILE_OPERATOR_NETWORK_LOG}" 2>&1
  local rc=$?
  set -e
  if [[ "${rc}" -ne 0 ]]; then
    if bool_enabled "${PRODUCTION_PROFILE_FAIL_ON_OPERATOR_NETWORK}"; then
      printf 'production_profile operator_network=fail log=%s\n' "${PRODUCTION_PROFILE_OPERATOR_NETWORK_LOG}" >&2
      return 1
    fi
    printf 'production_profile operator_network=warn log=%s\n' "${PRODUCTION_PROFILE_OPERATOR_NETWORK_LOG}" >&2
  else
    printf 'production_profile operator_network=pass log=%s\n' "${PRODUCTION_PROFILE_OPERATOR_NETWORK_LOG}"
  fi
  return 0
}

run_entrypoint_probe() {
  if ! bool_enabled "${PRODUCTION_PROFILE_ENTRYPOINT_PROBE}"; then
    printf 'production_profile entrypoint_probe=skipped reason=disabled\n'
    return 0
  fi
  if bool_enabled "${PERF_DRY_RUN}"; then
    printf 'production_profile entrypoint_probe=skipped reason=dry_run\n'
    return 0
  fi
  if [[ ! -x "${SCRIPT_DIR}/http_entrypoint_probe.sh" ]]; then
    printf 'production_profile entrypoint_probe=skipped reason=probe_script_missing\n'
    return 0
  fi

  mkdir -p "${RESULT_ROOT}"
  printf 'production_profile entrypoint_probe=start baseURL=%s log=%s json=%s\n' \
    "${BASE_URL_EFFECTIVE}" \
    "${PRODUCTION_PROFILE_ENTRYPOINT_PROBE_LOG}" \
    "${PRODUCTION_PROFILE_ENTRYPOINT_PROBE_JSON}"
  if ! BASE_URL="${BASE_URL_EFFECTIVE}" \
    ACCOUNT_FILE="${ACCOUNT_FILE:-}" \
    IM_EMAIL="${IM_EMAIL:-demo@example.com}" \
    IM_PASSWORD="${IM_PASSWORD:-password1234}" \
    PROBE_FAIL_ON_ENTRYPOINT_ERROR=true \
    PROBE_FAIL_ON_LOCAL_NETWORK="${PRODUCTION_PROFILE_FAIL_ON_LOCAL_NETWORK}" \
    PROBE_JSON_OUTPUT="${PRODUCTION_PROFILE_ENTRYPOINT_PROBE_JSON}" \
      "${SCRIPT_DIR}/http_entrypoint_probe.sh" 2>&1 | tee "${PRODUCTION_PROFILE_ENTRYPOINT_PROBE_LOG}"; then
      printf 'production_profile entrypoint_probe=fail\n' >&2
      return 1
  fi
  printf 'production_profile entrypoint_probe=pass\n'
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
  local log_file blocker_action
  blocker_action="$(entrypoint_probe_blocker_action "${PRODUCTION_PROFILE_ENTRYPOINT_PROBE_JSON}")"
  if [[ "${blocker_action}" != "cloud_console_rescue_required" ]]; then
    printf 'production_profile entrypoint_rescue_artifact=skipped reason=probe_action_not_cloud_console action=%s\n' \
      "${blocker_action:-<none>}"
    return 0
  fi
  if ! bool_enabled "${PRODUCTION_PROFILE_ENTRYPOINT_RESCUE_ARTIFACT}"; then
    return 0
  fi
  if bool_enabled "${PERF_DRY_RUN}"; then
    printf 'production_profile entrypoint_rescue_artifact=skipped reason=dry_run\n'
    return 0
  fi
  if [[ -z "${SSH_PRIVATE_KEY_PATH:-}" && -z "${SSH_AUTHORIZED_KEY:-}" ]]; then
    printf 'production_profile entrypoint_rescue_artifact=skipped reason=missing_ssh_key_source\n'
    return 0
  fi
  if [[ ! -x "${SCRIPT_DIR}/generate_node_access_rescue_artifact.sh" ]]; then
    printf 'production_profile entrypoint_rescue_artifact=skipped reason=generator_missing\n'
    return 0
  fi
  log_file="${RESULT_ROOT}/entrypoint-rescue-artifact.log"
  printf 'production_profile entrypoint_rescue_artifact=start dir=%s log=%s\n' \
    "${PRODUCTION_PROFILE_ENTRYPOINT_RESCUE_ARTIFACT_DIR}" \
    "${log_file}"
  if PRODUCTION_PROFILE_ENTRYPOINT_RESCUE_ARTIFACT=false \
    PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT=false \
    NODE_ACCESS_RESCUE_ARTIFACT_DIR="${PRODUCTION_PROFILE_ENTRYPOINT_RESCUE_ARTIFACT_DIR}" \
    NODE_ACCESS_RESCUE_ARTIFACT_PACKAGE="${PRODUCTION_PROFILE_ENTRYPOINT_RESCUE_ARTIFACT_PACKAGE}" \
    PUBLIC_BASE_URL="${PUBLIC_BASE_URL_EFFECTIVE}" \
    BASE_URL="${BASE_URL_EFFECTIVE}" \
    TCP_HOST="${TCP_HOST_EFFECTIVE}" \
    TCP_PORT="${TCP_PORT_EFFECTIVE}" \
    IM_TCP_PORT="${TCP_PORT_EFFECTIVE}" \
    ACCOUNT_FILE="${ACCOUNT_FILE:-}" \
    PRODUCT_TEST_PHASES="entrypoint" \
    PRODUCT_TEST_STOP_ON_FAILURE=true \
    PRODUCT_TEST_RUN_FULL_PROFILE=false \
    PERF_DRY_RUN=false \
      bash "${SCRIPT_DIR}/generate_node_access_rescue_artifact.sh" >"${log_file}" 2>&1; then
    printf 'production_profile entrypoint_rescue_artifact=pass dir=%s\n' \
      "${PRODUCTION_PROFILE_ENTRYPOINT_RESCUE_ARTIFACT_DIR}"
    return 0
  fi
  printf 'production_profile entrypoint_rescue_artifact=fail log=%s\n' "${log_file}" >&2
  return 0
}

verify_required_product_plan_artifacts() {
  if ! bool_enabled "${PRODUCTION_PROFILE_PACKAGE}"; then
    return 0
  fi
  if bool_enabled "${PERF_DRY_RUN}"; then
    return 0
  fi
  if ! bool_enabled "${PRODUCTION_PROFILE_REQUIRE_PRODUCT_PLAN_ARTIFACTS}"; then
    return 0
  fi
  if [[ ! -f "${PRODUCT_TEST_PLAN_JSON}" ]]; then
    printf 'production_profile result=fail reason=product_plan_run_missing path=%s\n' \
      "${PRODUCT_TEST_PLAN_JSON}" >&2
    return 1
  fi
  python3 "${SCRIPT_DIR}/perf_product_plan_artifacts_verify.py" \
    --product-run-json "${PRODUCT_TEST_PLAN_JSON}" \
    --plan-preview-json "${PRODUCT_TEST_PLAN_PREVIEW_JSON}" \
    --prereq-plan-json "${PRODUCT_TEST_PREREQ_PLAN_JSON}" \
    --prereq-audit-json "${PRODUCT_TEST_PREREQ_AUDIT_JSON}" \
    --runbook-json "${PRODUCT_TEST_RUNBOOK_JSON}" \
    --require-prereq \
    --require-pass >/dev/null || {
      printf 'production_profile result=fail reason=product_plan_artifacts_invalid path=%s\n' \
        "${PRODUCT_TEST_PLAN_JSON}" >&2
      return 1
    }
}

append_batch_status() {
  local batch_index="$1"
  local run_id="$2"
  local status="$3"
  local reason="$4"
  local scenarios="$5"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "${batch_index}" \
    "${run_id}" \
    "${status}" \
    "${reason}" \
    "${scenarios}" >>"${PRODUCTION_PROFILE_BATCH_STATUS_TSV}"
}

write_run_receipt() {
  local status="$1"
  local reason="$2"
  python3 - \
    "${PRODUCTION_PROFILE_PLAN_JSON}" \
    "${PRODUCTION_PROFILE_PREREQ_PLAN_JSON}" \
    "${PRODUCTION_PROFILE_PREREQ_AUDIT_JSON}" \
    "${PRODUCTION_PROFILE_BATCH_STATUS_TSV}" \
    "${PRODUCTION_PROFILE_RUN_JSON}" \
    "${PERF_PRODUCTION_GATE_PROFILE}" \
    "${status}" \
    "${reason}" \
    "${PERF_DRY_RUN}" \
    "${PRODUCTION_PROFILE_PACKAGE}" \
    "${PRODUCTION_PROFILE_STOP_ON_FAILURE}" \
    "${PRODUCTION_PROFILE_PREFLIGHT}" \
    "${PRODUCTION_PROFILE_PREREQ_GATE}" \
    "${PRODUCTION_PROFILE_OPERATOR_NETWORK_PREFLIGHT}" \
    "${PRODUCTION_PROFILE_OPERATOR_NETWORK_LOG}" \
    "${PRODUCTION_PROFILE_OPERATOR_NETWORK_JSON}" \
    "${PRODUCTION_PROFILE_ENTRYPOINT_PROBE}" \
    "${PRODUCTION_PROFILE_REQUIRE_PRODUCT_PLAN_ARTIFACTS}" \
    "${PRODUCTION_PROFILE_BATCH_SIZE}" \
    "${PRODUCTION_PROFILE_RESUME_PASS}" \
    "${PERF_PRODUCTION_GATE_MAX_AGE_SECONDS}" \
    "${RESULT_ROOT}" \
    "${PERF_STATUS_FILTER_TARGET}" \
    "${PRODUCTION_PROFILE_ENTRYPOINT_PROBE_LOG}" \
    "${PRODUCTION_PROFILE_ENTRYPOINT_PROBE_JSON}" <<'PY'
import json
import sys
import time
from pathlib import Path

(
    plan_path,
    prereq_plan_path,
    prereq_audit_path,
    batch_status_path,
    output_path,
    profile,
    status,
    reason,
    dry_run,
    package_enabled,
    stop_on_failure,
    preflight,
    prereq_gate,
    operator_network_preflight,
    operator_network_log,
    operator_network_json,
    entrypoint_probe,
    require_product_plan_artifacts,
    batch_size,
    resume_pass,
    max_age_seconds,
    result_root,
    status_filter_target,
    entrypoint_probe_log,
    entrypoint_probe_json,
) = sys.argv[1:26]

def read_json(path: str) -> dict:
    file_path = Path(path)
    if not file_path.exists():
        return {}
    with open(file_path, encoding="utf-8") as handle:
        return json.load(handle)

def enabled(value: str) -> bool:
    return value.lower() in {"1", "true", "yes", "on"}

plan = read_json(plan_path)
prereq_plan = read_json(prereq_plan_path)
prereq_audit = read_json(prereq_audit_path)
prereq_summary = prereq_audit.get("summary") or {}
batches = []
batch_file = Path(batch_status_path)
if batch_file.exists():
    with open(batch_file, encoding="utf-8") as handle:
        for line in handle:
            fields = line.rstrip("\n").split("\t", 4)
            if len(fields) != 5:
                continue
            index, run_id, batch_status, batch_reason, scenarios = fields
            batches.append({
                "index": int(index) if index.isdigit() else index,
                "runID": run_id,
                "status": batch_status,
                "reason": batch_reason,
                "scenarios": [item for item in scenarios.split() if item],
            })

def derive_blocker_type() -> str:
    if status != "FAIL":
        return ""
    if reason == "prereq_gate_failed":
        return "prerequisites"
    if reason == "entrypoint_probe_failed":
        return "entrypoint"
    if reason == "operator_network_failed":
        return "operator-network"
    if reason == "public_target_invalid":
        return "target"
    if reason == "cloud_security_group_evidence_required_failed":
        return "cloud-security-group"
    if reason == "product_plan_evidence_required_failed":
        return "product-plan-evidence"
    if reason == "package_failed":
        return "evidence-package"
    if reason.startswith("batch_") and reason.endswith("_failed"):
        return "scenario-batch"
    return "unknown"

payload = {
    "schemaVersion": 1,
    "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "profile": profile,
    "finalStatus": status,
    "reason": reason,
    "blockerType": derive_blocker_type(),
    "resultRoot": result_root,
    "dryRun": enabled(dry_run),
    "packageEnabled": enabled(package_enabled),
    "stopOnFailure": enabled(stop_on_failure),
    "preflight": enabled(preflight),
    "prereqGate": enabled(prereq_gate),
    "operatorNetworkPreflight": enabled(operator_network_preflight),
    "operatorNetworkArtifacts": {
        "log": operator_network_log if Path(operator_network_log).exists() else "",
        "json": operator_network_json if Path(operator_network_json).exists() else "",
    },
    "entrypointProbe": enabled(entrypoint_probe),
    "requireProductPlanArtifacts": enabled(require_product_plan_artifacts),
    "batchSize": int(batch_size),
    "resumeFreshPass": enabled(resume_pass),
    "maxAgeSeconds": int(max_age_seconds),
    "statusFilterTarget": enabled(status_filter_target),
    "entrypointProbeArtifacts": {
        "log": entrypoint_probe_log if Path(entrypoint_probe_log).exists() else "",
        "json": entrypoint_probe_json if Path(entrypoint_probe_json).exists() else "",
    },
    "plan": {
        "profile": plan.get("profile"),
        "profileScenarioCount": plan.get("profileScenarioCount"),
        "selectedScenarioCount": plan.get("selectedScenarioCount"),
        "skippedFreshPassCount": plan.get("skippedFreshPassCount"),
        "batchCount": plan.get("batchCount"),
    },
    "prereq": {
        "planStatus": prereq_plan.get("status"),
        "selectedScenarioCount": len(prereq_plan.get("selectedScenarios") or []),
        "auditStatus": prereq_summary.get("overallStatus"),
        "missingRequiredCount": prereq_summary.get("missingRequiredCount"),
    },
    "batches": batches,
}
Path(output_path).parent.mkdir(parents=True, exist_ok=True)
Path(output_path).write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
}

write_runbook() {
  python3 "${SCRIPT_DIR}/perf_production_profile_runbook.py" \
    --plan "${PRODUCTION_PROFILE_PLAN_JSON}" \
    --prereq-audit "${PRODUCTION_PROFILE_PREREQ_AUDIT_JSON}" \
    --profile-run "${PRODUCTION_PROFILE_RUN_JSON}" \
    --profile "${PERF_PRODUCTION_GATE_PROFILE}" \
    --result-root "${RESULT_ROOT}" \
    --run-id-prefix "${PRODUCTION_PROFILE_RUN_ID_PREFIX}" \
    --batch-size "${PRODUCTION_PROFILE_BATCH_SIZE}" \
    "$(bool_enabled "${PRODUCTION_PROFILE_RESUME_PASS}" && printf '%s' --resume-fresh-pass || printf '%s' --no-resume-fresh-pass)" \
    "$(bool_enabled "${PRODUCTION_PROFILE_PACKAGE}" && printf '%s' --package || printf '%s' --no-package)" \
    "$(bool_enabled "${PRODUCTION_PROFILE_STOP_ON_FAILURE}" && printf '%s' --stop-on-failure || printf '%s' --no-stop-on-failure)" \
    "$(bool_enabled "${PRODUCTION_PROFILE_PREFLIGHT}" && printf '%s' --preflight || printf '%s' --no-preflight)" \
    "$(bool_enabled "${PRODUCTION_PROFILE_PREREQ_GATE}" && printf '%s' --prereq-gate || printf '%s' --no-prereq-gate)" \
    "$(bool_enabled "${PRODUCTION_PROFILE_ENTRYPOINT_PROBE}" && printf '%s' --entrypoint-probe || printf '%s' --no-entrypoint-probe)" \
    "$(bool_enabled "${PRODUCTION_PROFILE_REQUIRE_PRODUCT_PLAN_ARTIFACTS}" && printf '%s' --require-product-plan-artifacts || printf '%s' --no-require-product-plan-artifacts)" \
    "$(bool_enabled "${PERF_STATUS_FILTER_TARGET}" && printf '%s' --status-filter-target || printf '%s' --no-status-filter-target)" \
    --max-age-seconds "${PERF_PRODUCTION_GATE_MAX_AGE_SECONDS}" \
    --base-url "${BASE_URL_EFFECTIVE}" \
    --tcp-host "${TCP_HOST_EFFECTIVE}" \
    --tcp-port "${TCP_PORT_EFFECTIVE}" \
    --account-file "${ACCOUNT_FILE:-}" \
    --conversation-id "${IM_CONVERSATION_ID:-}" \
    --internal-secret "${IM_INTERNAL_SECRET:-${IM_INTERNAL_SHARED_SECRET:-}}" \
    --auth-email-webhook-url "${IM_AUTH_EMAIL_WEBHOOK_SINK_URL:-}" \
    --verification-code "${IM_ACCOUNT_VERIFICATION_CODE:-}" \
    --password-reset-code "${IM_ACCOUNT_PASSWORD_RESET_CODE:-}" \
    --output "${PRODUCTION_PROFILE_RUNBOOK_MD}" \
    --json-output "${PRODUCTION_PROFILE_RUNBOOK_JSON}" >/dev/null
}

run_profile() {
  local plan_lines batch_index scenarios run_id
  mkdir -p "${RESULT_ROOT}"
  : >"${PRODUCTION_PROFILE_BATCH_STATUS_TSV}"
  plan_lines="$(write_plan "${PRODUCTION_PROFILE_PLAN_JSON}")"
  printf 'production_profile plan=%s profile=%s batchSize=%s dryRun=%s resumePass=%s\n' \
    "${PRODUCTION_PROFILE_PLAN_JSON}" \
    "${PERF_PRODUCTION_GATE_PROFILE}" \
    "${PRODUCTION_PROFILE_BATCH_SIZE}" \
    "${PERF_DRY_RUN}" \
    "${PRODUCTION_PROFILE_RESUME_PASS}"

  write_run_receipt "STARTED" ""

  if ! verify_required_product_plan_artifacts; then
    write_run_receipt "FAIL" "product_plan_evidence_required_failed"
    write_runbook || true
    return 1
  fi

  if ! validate_public_target; then
    write_run_receipt "FAIL" "public_target_invalid"
    write_runbook || true
    return 1
  fi

  if ! verify_required_cloud_security_group_evidence; then
    write_run_receipt "FAIL" "cloud_security_group_evidence_required_failed"
    write_runbook || true
    return 1
  fi

  if ! run_operator_network_preflight; then
    write_run_receipt "FAIL" "operator_network_failed"
    write_runbook || true
    return 1
  fi

  if ! run_entrypoint_probe; then
    write_run_receipt "FAIL" "entrypoint_probe_failed"
    generate_entrypoint_rescue_artifact
    write_runbook || true
    return 1
  fi

  if ! run_prereq_gate; then
    write_run_receipt "FAIL" "prereq_gate_failed"
    write_runbook || true
    return 1
  fi
  write_runbook

  if [[ -z "${plan_lines}" ]]; then
    printf 'production_profile result=noop reason=all_required_scenarios_have_fresh_pass profile=%s\n' \
      "${PERF_PRODUCTION_GATE_PROFILE}"
    write_run_receipt "NOOP" "all_required_scenarios_have_fresh_pass"
    write_runbook
  else
    while IFS=$'\t' read -r batch_index scenarios; do
      [[ -n "${batch_index}" ]] || continue
      run_id="${PRODUCTION_PROFILE_RUN_ID_PREFIX}-batch$(printf '%02d' "${batch_index}")"
      printf 'production_profile batch=start index=%s runID=%s scenarios=%s\n' \
        "${batch_index}" \
        "${run_id}" \
        "${scenarios}"
      if RUN_ID="${run_id}" \
      RESULT_ROOT="${RESULT_ROOT}" \
      SCENARIOS="${scenarios}" \
      PERF_PREFLIGHT="${PRODUCTION_PROFILE_PREFLIGHT}" \
      PERF_PRODUCTION_GATE=true \
      PERF_PRODUCTION_GATE_PROFILE="${PERF_PRODUCTION_GATE_PROFILE}" \
      PERF_PRODUCTION_GATE_MAX_AGE_SECONDS="${PERF_PRODUCTION_GATE_MAX_AGE_SECONDS}" \
      PERF_GLOBAL_STATUS=true \
      PERF_SLO=true \
      PERF_STATUS_FILTER_TARGET="${PERF_STATUS_FILTER_TARGET}" \
      PERF_RUN_PLAN=true \
      STOP_ON_FAILURE="${PRODUCTION_PROFILE_STOP_ON_FAILURE}" \
      PERF_DRY_RUN="${PERF_DRY_RUN}" \
        "${SCRIPT_DIR}/run_perf_scenarios.sh"; then
        append_batch_status "${batch_index}" "${run_id}" "PASS" "" "${scenarios}"
      else
        append_batch_status "${batch_index}" "${run_id}" "FAIL" "run_perf_scenarios_failed" "${scenarios}"
        write_run_receipt "FAIL" "batch_${batch_index}_failed"
        write_runbook || true
        return 1
      fi
      printf 'production_profile batch=pass index=%s runID=%s\n' "${batch_index}" "${run_id}"
    done <<<"${plan_lines}"
    write_run_receipt "PASS" ""
    write_runbook
  fi

  if bool_enabled "${PRODUCTION_PROFILE_PACKAGE}" && ! bool_enabled "${PERF_DRY_RUN}"; then
    PERF_PRODUCTION_GATE_JSON="${RESULT_ROOT}/production-gate.json" \
    PERF_PRODUCTION_GATE_PROFILE="${PERF_PRODUCTION_GATE_PROFILE}" \
    PERF_PRODUCTION_GATE_MAX_AGE_SECONDS="${PERF_PRODUCTION_GATE_MAX_AGE_SECONDS}" \
    PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET="${PRODUCTION_PROFILE_REQUIRE_PUBLIC_TARGET_EFFECTIVE}" \
    PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS="${PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS:-false}" \
    PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS="${PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS:-false}" \
    PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS="${PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS:-false}" \
    PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP="${PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP:-${PRODUCTION_PROFILE_REQUIRE_CLOUD_SECURITY_GROUP}}" \
      "${SCRIPT_DIR}/package_production_evidence.sh" || {
        write_run_receipt "FAIL" "package_failed"
        write_runbook || true
        return 1
      }
    write_runbook
  else
    printf 'production_profile package=skipped dryRun=%s package=%s\n' \
      "${PERF_DRY_RUN}" \
      "${PRODUCTION_PROFILE_PACKAGE}"
  fi
}

if bool_enabled "${PRODUCTION_PROFILE_SELF_TEST}"; then
  self_test_dir="$(mktemp -d)"
  trap 'rm -rf "${self_test_dir}"' EXIT
  account_file="${self_test_dir}/accounts.csv"
  for index in $(seq 1 1000); do
    printf 'demo%03d@example.com,password1234\n' "${index}"
  done >"${account_file}"
  negative_catalog="${self_test_dir}/negative-profile-catalog.json"
  fake_operator_fail="${self_test_dir}/fake-operator-network-fail.sh"
cat >"${fake_operator_fail}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'operator-network target=%s status=fail warning=tun_route routeInterface=utun99 routeGateway=198.18.0.1 proxyEnv=<none>\n' "${1:-<missing>}"
if [[ -n "${OPERATOR_NETWORK_JSON_OUTPUT:-}" ]]; then
  python3 - "${OPERATOR_NETWORK_JSON_OUTPUT}" "${1:-<missing>}" <<'PY'
import json
import sys
from pathlib import Path

output, target = sys.argv[1:3]
Path(output).write_text(json.dumps({
    "schemaVersion": 1,
    "status": "fail",
    "failed": True,
    "failureCount": 1,
    "targetCount": 1,
    "warnings": ["tun_route"],
    "warningCounts": {"tun_route": 1},
    "routeInterfaces": ["utun99"],
    "routeGateways": ["198.18.0.1"],
    "failedTargets": [target],
    "targets": [{
        "target": target,
        "host": target,
        "status": "fail",
        "warning": "tun_route",
        "routeInterface": "utun99",
        "routeGateway": "198.18.0.1",
        "proxyEnv": "<none>",
    }],
    "action": "disconnect_local_tun_or_use_clean_network",
}, indent=2, sort_keys=True), encoding="utf-8")
PY
fi
printf 'operator-network result=fail failures=1 action=disconnect_local_tun_or_use_clean_network\n' >&2
exit 1
SH
  chmod +x "${fake_operator_fail}"
  cat >"${negative_catalog}" <<'JSON'
{
  "schemaVersion": 1,
  "profiles": {
    "requires-conversation": [
      "pair-delivery-1000-50"
    ]
  }
}
JSON
  good_cloud_security_group="${self_test_dir}/cloud-security-group-good.json"
  bad_cloud_security_group="${self_test_dir}/cloud-security-group-public-ssh.json"
  cloud_security_group_repair_plan="${self_test_dir}/cloud-security-group-repair-plan.json"
  cloud_security_group_post_apply="${self_test_dir}/cloud-security-group-post-apply.json"
  cloud_security_group_repair_receipt="${self_test_dir}/cloud-security-group-repair-receipt.json"
  cat >"${good_cloud_security_group}" <<'JSON'
{
  "Permissions": {
    "Permission": [
      {"IpProtocol": "tcp", "PortRange": "80/80", "SourceCidrIp": "0.0.0.0/0", "Policy": "Accept"},
      {"IpProtocol": "tcp", "PortRange": "443/443", "SourceCidrIp": "0.0.0.0/0", "Policy": "Accept"},
      {"IpProtocol": "tcp", "PortRange": "9000/9000", "SourceCidrIp": "0.0.0.0/0", "Policy": "Accept"},
      {"IpProtocol": "tcp", "PortRange": "22/22", "SourceCidrIp": "203.0.113.10/32", "Policy": "Accept"}
    ]
  }
}
JSON
  chmod 0600 "${good_cloud_security_group}"
  cat >"${bad_cloud_security_group}" <<'JSON'
[
  {"protocol": "tcp", "port": "80/80", "source": "0.0.0.0/0", "action": "allow"},
  {"protocol": "tcp", "port": "443/443", "source": "0.0.0.0/0", "action": "allow"},
  {"protocol": "tcp", "port": "9000/9000", "source": "0.0.0.0/0", "action": "allow"},
  {"protocol": "tcp", "port": "22/22", "source": "0.0.0.0/0", "action": "allow"}
]
JSON
  chmod 0600 "${bad_cloud_security_group}"
  cp "${good_cloud_security_group}" "${cloud_security_group_post_apply}"
  python3 - "${good_cloud_security_group}" "${cloud_security_group_repair_plan}" "${cloud_security_group_post_apply}" "${cloud_security_group_repair_receipt}" <<'PY'
import hashlib
import json
import sys
import time
from pathlib import Path

snapshot_path, plan_path, post_apply_path, receipt_path = map(Path, sys.argv[1:5])
plan = {
    "schemaVersion": 1,
    "securityGroupId": "sg-production-profile-selftest",
    "snapshot": str(snapshot_path.resolve()),
    "adminCidr": "203.0.113.10/32",
    "publicClientPorts": [80, 443, 9000],
    "adminPorts": [22],
    "denyPublicPorts": [3389, 5432, 6379, 8080, 8081, 8082, 9092, 18080],
    "status": "NOOP",
    "actions": [],
    "summary": {"actionCount": 0, "authorizeCount": 0, "revokeCount": 0},
}
plan_path.write_text(json.dumps(plan, indent=2, sort_keys=True), encoding="utf-8")

def file_record(path: Path) -> dict[str, object]:
    data = path.read_bytes()
    return {
        "path": str(path.resolve()),
        "present": True,
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
    }

receipt = {
    "schemaVersion": 1,
    "status": "APPLIED_VERIFIED",
    "generatedAtEpoch": int(time.time()),
    "securityGroupId": "sg-production-profile-selftest",
    "regionId": "cn-shenzhen",
    "adminCidr": "203.0.113.10/32",
    "applyRequested": True,
    "applied": True,
    "verifyRequested": True,
    "verified": True,
    "snapshot": str(snapshot_path.resolve()),
    "postApplySnapshot": str(post_apply_path.resolve()),
    "plan": str(plan_path.resolve()),
    "planStatus": "NOOP",
    "summary": plan["summary"],
    "artifacts": {
        "snapshot": file_record(snapshot_path),
        "postApplySnapshot": file_record(post_apply_path),
        "plan": file_record(plan_path),
    },
}
receipt_path.write_text(json.dumps(receipt, indent=2, sort_keys=True), encoding="utf-8")
PY

  RESULT_ROOT="${self_test_dir}/cloud-security-group-preflight-pass" \
  PRODUCTION_PROFILE_REQUIRE_CLOUD_SECURITY_GROUP=true \
  PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_FILE="${good_cloud_security_group}" \
  PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${cloud_security_group_repair_receipt}" \
  PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=sg-production-profile-selftest \
  PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=cn-shenzhen \
  PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=203.0.113.10/32 \
    verify_required_cloud_security_group_evidence

  if RESULT_ROOT="${self_test_dir}/cloud-security-group-preflight-fail" \
    PRODUCTION_PROFILE_REQUIRE_CLOUD_SECURITY_GROUP=true \
    PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_FILE="${bad_cloud_security_group}" \
    PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${cloud_security_group_repair_receipt}" \
    PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=sg-production-profile-selftest \
    PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=cn-shenzhen \
    PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=203.0.113.10/32 \
      verify_required_cloud_security_group_evidence >"${self_test_dir}/cloud-security-group-preflight-fail.log" 2>&1; then
    printf 'production_profile_self_test result=fail reason=bad_cloud_security_group_snapshot_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=cloud_security_group_snapshot_invalid' "${self_test_dir}/cloud-security-group-preflight-fail.log" || {
    printf 'production_profile_self_test result=fail reason=bad_cloud_security_group_snapshot_reason_missing\n' >&2
    exit 1
  }

  RESULT_ROOT="${self_test_dir}/results" \
  ACCOUNT_FILE="${account_file}" \
  IM_CONVERSATION_ID="00000000-0000-4000-8000-000000000001" \
  IM_INTERNAL_SECRET="self-test-internal-secret-0123456789" \
  PERF_PRODUCTION_GATE_PROFILE="minimum-smoke" \
  PRODUCTION_PROFILE_BATCH_SIZE=4 \
  PRODUCTION_PROFILE_PACKAGE=false \
  PRODUCTION_PROFILE_RUN_ID_PREFIX="self-test-production-profile" \
  PRODUCTION_PROFILE_SELF_TEST=false \
  PERF_DRY_RUN=true \
    "${BASH_SOURCE[0]}" >/dev/null
  python3 - "${self_test_dir}/results/production-profile-plan.json" "${self_test_dir}/results/production-profile-prereq-audit.json" "${self_test_dir}/results/production-profile-run.json" "${self_test_dir}/results/production-profile-runbook.json" "${PERF_PRODUCTION_PROFILE_CATALOG}" <<'PY'
import json
import math
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
with open(sys.argv[5], encoding="utf-8") as handle:
    expected_count = len((json.load(handle).get("profiles") or {}).get("minimum-smoke") or [])
expected_batches = math.ceil(expected_count / 4)
if payload.get("profile") != "minimum-smoke":
    raise SystemExit("production_profile_self_test result=fail reason=profile_mismatch")
if payload.get("profileScenarioCount") != expected_count:
    raise SystemExit("production_profile_self_test result=fail reason=scenario_count_mismatch")
if payload.get("batchCount") != expected_batches:
    raise SystemExit("production_profile_self_test result=fail reason=batch_count_mismatch")
with open(sys.argv[2], encoding="utf-8") as handle:
    prereq = json.load(handle)
if (prereq.get("summary") or {}).get("overallStatus") == "BLOCKED":
    raise SystemExit("production_profile_self_test result=fail reason=prereq_blocked")
with open(sys.argv[3], encoding="utf-8") as handle:
    run = json.load(handle)
if run.get("profile") != "minimum-smoke":
    raise SystemExit("production_profile_self_test result=fail reason=run_profile_mismatch")
if run.get("finalStatus") != "PASS":
    raise SystemExit("production_profile_self_test result=fail reason=run_status_not_pass")
if len(run.get("batches") or []) != expected_batches:
    raise SystemExit("production_profile_self_test result=fail reason=run_batch_count_mismatch")
if run.get("statusFilterTarget") is not True:
    raise SystemExit("production_profile_self_test result=fail reason=status_filter_target_not_recorded")
if run.get("packageEnabled") is not False:
    raise SystemExit("production_profile_self_test result=fail reason=package_flag_not_recorded")
with open(sys.argv[4], encoding="utf-8") as handle:
    runbook = json.load(handle)
if runbook.get("profile") != "minimum-smoke":
    raise SystemExit("production_profile_self_test result=fail reason=runbook_profile_mismatch")
if runbook.get("status") != "READY":
    raise SystemExit("production_profile_self_test result=fail reason=runbook_status_mismatch")
if len(((runbook.get("commands") or {}).get("batches") or [])) != expected_batches:
    raise SystemExit("production_profile_self_test result=fail reason=runbook_batch_count_mismatch")
if ((runbook.get("plan") or {}).get("statusFilterTarget")) is not True:
    raise SystemExit("production_profile_self_test result=fail reason=runbook_status_filter_missing")
profile_command = ((runbook.get("commands") or {}).get("profile") or "")
batch_command = (((runbook.get("commands") or {}).get("batches") or [{}])[0].get("command") or "")
if "PERF_STATUS_FILTER_TARGET=true" not in profile_command or "PERF_STATUS_FILTER_TARGET=true" not in batch_command:
    raise SystemExit("production_profile_self_test result=fail reason=runbook_status_filter_command_missing")
PY
  if RESULT_ROOT="${self_test_dir}/operator-network-results" \
    ACCOUNT_FILE="${account_file}" \
    IM_CONVERSATION_ID="00000000-0000-4000-8000-000000000001" \
    IM_INTERNAL_SECRET="self-test-internal-secret-0123456789" \
    PERF_PRODUCTION_GATE_PROFILE="minimum-smoke" \
    PRODUCTION_PROFILE_PACKAGE=false \
    PRODUCTION_PROFILE_RUN_ID_PREFIX="self-test-production-profile-operator-network" \
    PRODUCTION_PROFILE_OPERATOR_NETWORK_PREFLIGHT_SCRIPT="${fake_operator_fail}" \
    PRODUCTION_PROFILE_SELF_TEST=false \
    PERF_DRY_RUN=false \
      "${BASH_SOURCE[0]}" >"${self_test_dir}/operator-network.log" 2>&1; then
    printf 'production_profile_self_test result=fail reason=operator_network_failure_passed\n' >&2
    exit 1
  fi
  python3 - "${self_test_dir}/operator-network-results/production-profile-run.json" "${self_test_dir}/operator-network-results/production-profile-operator-network.log" "${self_test_dir}/operator-network-results/production-profile-operator-network.json" "${self_test_dir}/operator-network-results/production-profile-entrypoint-probe.log" <<'PY'
import json
import sys
from pathlib import Path

with open(sys.argv[1], encoding="utf-8") as handle:
    run = json.load(handle)
if run.get("finalStatus") != "FAIL":
    raise SystemExit("production_profile_self_test result=fail reason=operator_network_status_not_fail")
if run.get("reason") != "operator_network_failed":
    raise SystemExit("production_profile_self_test result=fail reason=operator_network_reason_mismatch")
if run.get("blockerType") != "operator-network":
    raise SystemExit(f"production_profile_self_test result=fail reason=operator_network_blocker_type_mismatch blockerType={run.get('blockerType')}")
artifacts = run.get("operatorNetworkArtifacts") or {}
if not artifacts.get("log") or not Path(str(artifacts.get("log"))).is_file():
    raise SystemExit("production_profile_self_test result=fail reason=operator_network_artifact_missing")
if not artifacts.get("json") or not Path(str(artifacts.get("json"))).is_file():
    raise SystemExit("production_profile_self_test result=fail reason=operator_network_json_artifact_missing")
if "operator-network result=fail" not in Path(sys.argv[2]).read_text(encoding="utf-8", errors="replace"):
    raise SystemExit("production_profile_self_test result=fail reason=operator_network_log_missing_failure")
operator_payload = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
if operator_payload.get("failed") is not True or "tun_route" not in (operator_payload.get("warnings") or []):
    raise SystemExit("production_profile_self_test result=fail reason=operator_network_json_invalid")
if Path(sys.argv[4]).exists():
    raise SystemExit("production_profile_self_test result=fail reason=operator_network_started_entrypoint_probe")
PY
  if RESULT_ROOT="${self_test_dir}/bad-public-target-results" \
    ACCOUNT_FILE="${account_file}" \
    IM_CONVERSATION_ID="00000000-0000-4000-8000-000000000001" \
    IM_INTERNAL_SECRET="self-test-internal-secret-0123456789" \
    PERF_PRODUCTION_GATE_PROFILE="minimum-smoke" \
    PRODUCTION_PROFILE_PACKAGE=true \
    PRODUCTION_PROFILE_REQUIRE_PRODUCT_PLAN_ARTIFACTS=false \
    PRODUCTION_PROFILE_RUN_ID_PREFIX="self-test-production-profile-bad-public-target" \
    PRODUCTION_PROFILE_SELF_TEST=false \
    PERF_DRY_RUN=false \
      "${BASH_SOURCE[0]}" >"${self_test_dir}/bad-public-target.log" 2>&1; then
    printf 'production_profile_self_test result=fail reason=bad_public_target_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=public_base_url_https_required' "${self_test_dir}/bad-public-target.log" || {
    printf 'production_profile_self_test result=fail reason=bad_public_target_reason_missing\n' >&2
    exit 1
  }
  python3 - "${self_test_dir}/bad-public-target-results/production-profile-run.json" "${self_test_dir}/bad-public-target-results/production-profile-operator-network.log" "${self_test_dir}/bad-public-target-results/production-profile-entrypoint-probe.log" <<'PY'
import json
import sys
from pathlib import Path

with open(sys.argv[1], encoding="utf-8") as handle:
    run = json.load(handle)
if run.get("finalStatus") != "FAIL":
    raise SystemExit("production_profile_self_test result=fail reason=bad_public_target_status_not_fail")
if run.get("reason") != "public_target_invalid":
    raise SystemExit("production_profile_self_test result=fail reason=bad_public_target_run_reason_mismatch")
if run.get("blockerType") != "target":
    raise SystemExit(f"production_profile_self_test result=fail reason=bad_public_target_blocker_type_mismatch blockerType={run.get('blockerType')}")
if Path(sys.argv[2]).exists():
    raise SystemExit("production_profile_self_test result=fail reason=bad_public_target_started_operator_network")
if Path(sys.argv[3]).exists():
    raise SystemExit("production_profile_self_test result=fail reason=bad_public_target_started_entrypoint_probe")
PY
  if RESULT_ROOT="${self_test_dir}/gate-require-target-results" \
    ACCOUNT_FILE="${account_file}" \
    IM_CONVERSATION_ID="00000000-0000-4000-8000-000000000001" \
    IM_INTERNAL_SECRET="self-test-internal-secret-0123456789" \
    PERF_PRODUCTION_GATE_PROFILE="minimum-smoke" \
    PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET=true \
    PRODUCTION_PROFILE_PACKAGE=false \
    PRODUCTION_PROFILE_REQUIRE_PRODUCT_PLAN_ARTIFACTS=false \
    PRODUCTION_PROFILE_RUN_ID_PREFIX="self-test-production-profile-gate-require-target" \
    PRODUCTION_PROFILE_SELF_TEST=false \
    PERF_DRY_RUN=false \
      "${BASH_SOURCE[0]}" >"${self_test_dir}/gate-require-target.log" 2>&1; then
    printf 'production_profile_self_test result=fail reason=gate_require_target_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=public_base_url_https_required' "${self_test_dir}/gate-require-target.log" || {
    printf 'production_profile_self_test result=fail reason=gate_require_target_reason_missing\n' >&2
    exit 1
  }
  python3 - "${self_test_dir}/gate-require-target-results/production-profile-run.json" "${self_test_dir}/gate-require-target-results/production-profile-operator-network.log" "${self_test_dir}/gate-require-target-results/production-profile-entrypoint-probe.log" <<'PY'
import json
import sys
from pathlib import Path

with open(sys.argv[1], encoding="utf-8") as handle:
    run = json.load(handle)
if run.get("finalStatus") != "FAIL":
    raise SystemExit("production_profile_self_test result=fail reason=gate_require_target_status_not_fail")
if run.get("reason") != "public_target_invalid":
    raise SystemExit("production_profile_self_test result=fail reason=gate_require_target_run_reason_mismatch")
if run.get("blockerType") != "target":
    raise SystemExit(f"production_profile_self_test result=fail reason=gate_require_target_blocker_type_mismatch blockerType={run.get('blockerType')}")
if Path(sys.argv[2]).exists():
    raise SystemExit("production_profile_self_test result=fail reason=gate_require_target_started_operator_network")
if Path(sys.argv[3]).exists():
    raise SystemExit("production_profile_self_test result=fail reason=gate_require_target_started_entrypoint_probe")
PY
  expect_public_target_failure() {
    local label="$1"
    local base_url="$2"
    local tcp_host="$3"
    local expected_reason="$4"
    local expected_host_reason="${5:-}"
    local result_dir="${self_test_dir}/${label}-results"
    local log_file="${self_test_dir}/${label}.log"
    if RESULT_ROOT="${result_dir}" \
      BASE_URL="${base_url}" \
      TCP_HOST="${tcp_host}" \
      ACCOUNT_FILE="${account_file}" \
      IM_CONVERSATION_ID="00000000-0000-4000-8000-000000000001" \
      IM_INTERNAL_SECRET="self-test-internal-secret-0123456789" \
      PERF_PRODUCTION_GATE_PROFILE="minimum-smoke" \
      PRODUCTION_PROFILE_PACKAGE=true \
      PRODUCTION_PROFILE_REQUIRE_PRODUCT_PLAN_ARTIFACTS=false \
      PRODUCTION_PROFILE_RUN_ID_PREFIX="self-test-production-profile-${label}" \
      PRODUCTION_PROFILE_SELF_TEST=false \
      PERF_DRY_RUN=false \
        "${BASH_SOURCE[0]}" >"${log_file}" 2>&1; then
      printf 'production_profile_self_test result=fail reason=%s_passed\n' "${label}" >&2
      exit 1
    fi
    grep -q "reason=${expected_reason}" "${log_file}" || {
      printf 'production_profile_self_test result=fail reason=%s_reason_missing expected=%s\n' "${label}" "${expected_reason}" >&2
      exit 1
    }
    if [[ -n "${expected_host_reason}" ]]; then
      grep -q "hostReason=${expected_host_reason}" "${log_file}" || {
        printf 'production_profile_self_test result=fail reason=%s_host_reason_missing expected=%s\n' "${label}" "${expected_host_reason}" >&2
        exit 1
      }
    fi
    python3 - "${result_dir}/production-profile-run.json" "${result_dir}/production-profile-operator-network.log" "${result_dir}/production-profile-entrypoint-probe.log" "${label}" <<'PY'
import json
import sys
from pathlib import Path

run_path, operator_log, entrypoint_log, label = sys.argv[1:5]
with open(run_path, encoding="utf-8") as handle:
    run = json.load(handle)
if run.get("finalStatus") != "FAIL":
    raise SystemExit(f"production_profile_self_test result=fail reason={label}_status_not_fail")
if run.get("reason") != "public_target_invalid":
    raise SystemExit(f"production_profile_self_test result=fail reason={label}_run_reason_mismatch")
if run.get("blockerType") != "target":
    raise SystemExit(f"production_profile_self_test result=fail reason={label}_blocker_type_mismatch blockerType={run.get('blockerType')}")
if Path(operator_log).exists():
    raise SystemExit(f"production_profile_self_test result=fail reason={label}_started_operator_network")
if Path(entrypoint_log).exists():
    raise SystemExit(f"production_profile_self_test result=fail reason={label}_started_entrypoint_probe")
PY
  }

  expect_public_target_failure \
    "https-non-default-port-target" \
    "https://chat.myim-prod.com:8080" \
    "tcp.myim-prod.com" \
    "public_base_url_default_https_port_required"
  expect_public_target_failure \
    "raw-ip-base-target" \
    "https://203.0.113.10" \
    "tcp.myim-prod.com" \
    "public_base_url_domain_required" \
    "ip"
  expect_public_target_failure \
    "raw-ip-tcp-target" \
    "https://chat.myim-prod.com" \
    "203.0.113.10" \
    "tcp_host_domain_required" \
    "ip"
  expect_public_target_failure \
    "placeholder-base-target" \
    "https://chat.yourdomain.com" \
    "tcp.myim-prod.com" \
    "public_base_url_domain_required" \
    "placeholder"
  expect_public_target_failure \
    "placeholder-tcp-target" \
    "https://chat.myim-prod.com" \
    "tcp.example.net" \
    "tcp_host_domain_required" \
    "placeholder"
  expect_public_target_failure \
    "test-tld-tcp-target" \
    "https://chat.myim-prod.com" \
    "tcp.myim.test" \
    "tcp_host_domain_required" \
    "placeholder"
  if RESULT_ROOT="${self_test_dir}/missing-cloud-security-group-results" \
    BASE_URL="https://chat.myim-prod.com" \
    TCP_HOST="tcp.myim-prod.com" \
    ACCOUNT_FILE="${account_file}" \
    IM_CONVERSATION_ID="00000000-0000-4000-8000-000000000001" \
    IM_INTERNAL_SECRET="self-test-internal-secret-0123456789" \
    PERF_PRODUCTION_GATE_PROFILE="minimum-smoke" \
    PRODUCTION_PROFILE_PACKAGE=true \
    PRODUCTION_PROFILE_REQUIRE_PRODUCT_PLAN_ARTIFACTS=false \
    PRODUCTION_PROFILE_RUN_ID_PREFIX="self-test-production-profile-missing-cloud-security-group" \
    PRODUCTION_PROFILE_SELF_TEST=false \
    PERF_DRY_RUN=false \
      "${BASH_SOURCE[0]}" >"${self_test_dir}/missing-cloud-security-group.log" 2>&1; then
    printf 'production_profile_self_test result=fail reason=missing_cloud_security_group_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=cloud_security_group_snapshot_required' "${self_test_dir}/missing-cloud-security-group.log" || {
    printf 'production_profile_self_test result=fail reason=missing_cloud_security_group_reason_missing\n' >&2
    exit 1
  }
  python3 - "${self_test_dir}/missing-cloud-security-group-results/production-profile-run.json" "${self_test_dir}/missing-cloud-security-group-results/production-profile-operator-network.log" "${self_test_dir}/missing-cloud-security-group-results/production-profile-entrypoint-probe.log" <<'PY'
import json
import sys
from pathlib import Path

with open(sys.argv[1], encoding="utf-8") as handle:
    run = json.load(handle)
if run.get("finalStatus") != "FAIL":
    raise SystemExit("production_profile_self_test result=fail reason=missing_cloud_security_group_status_not_fail")
if run.get("reason") != "cloud_security_group_evidence_required_failed":
    raise SystemExit("production_profile_self_test result=fail reason=missing_cloud_security_group_run_reason_mismatch")
if run.get("blockerType") != "cloud-security-group":
    raise SystemExit(f"production_profile_self_test result=fail reason=missing_cloud_security_group_blocker_type_mismatch blockerType={run.get('blockerType')}")
if Path(sys.argv[2]).exists():
    raise SystemExit("production_profile_self_test result=fail reason=missing_cloud_security_group_started_operator_network")
if Path(sys.argv[3]).exists():
    raise SystemExit("production_profile_self_test result=fail reason=missing_cloud_security_group_started_entrypoint_probe")
PY
  if ( RESULT_ROOT="${self_test_dir}/missing-product-plan" \
    PRODUCT_TEST_PLAN_JSON="${self_test_dir}/missing-product-plan/product-test-plan-run.json" \
    PRODUCTION_PROFILE_PACKAGE=true \
    PRODUCTION_PROFILE_REQUIRE_PRODUCT_PLAN_ARTIFACTS=true \
    PERF_DRY_RUN=false \
      verify_required_product_plan_artifacts >"${self_test_dir}/missing-product-plan.log" 2>&1 ); then
    printf 'production_profile_self_test result=fail reason=missing_product_plan_preflight_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=product_plan_run_missing' "${self_test_dir}/missing-product-plan.log" || {
    printf 'production_profile_self_test result=fail reason=missing_product_plan_preflight_reason_absent\n' >&2
    exit 1
  }
  if RESULT_ROOT="${self_test_dir}/negative-results" \
    ACCOUNT_FILE="${account_file}" \
    IM_CONVERSATION_ID="" \
    IM_INTERNAL_SECRET="self-test-internal-secret-0123456789" \
    PERF_PRODUCTION_PROFILE_CATALOG="${negative_catalog}" \
    PERF_PRODUCTION_GATE_PROFILE="requires-conversation" \
    PRODUCTION_PROFILE_BATCH_SIZE=1 \
    PRODUCTION_PROFILE_PACKAGE=false \
    PRODUCTION_PROFILE_RUN_ID_PREFIX="self-test-production-profile-negative" \
    PRODUCTION_PROFILE_SELF_TEST=false \
    PERF_DRY_RUN=true \
      "${BASH_SOURCE[0]}" >"${self_test_dir}/negative.log" 2>&1; then
    printf 'production_profile_self_test result=fail reason=missing_conversation_prereq_passed\n' >&2
    exit 1
  fi
  python3 - "${self_test_dir}/negative-results/production-profile-prereq-audit.json" "${self_test_dir}/negative-results/production-profile-run.json" "${self_test_dir}/negative-results/production-profile-runbook.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    prereq = json.load(handle)
summary = prereq.get("summary") or {}
if summary.get("overallStatus") != "BLOCKED":
    raise SystemExit("production_profile_self_test result=fail reason=negative_prereq_not_blocked")
if int(summary.get("missingRequiredCount") or 0) <= 0:
    raise SystemExit("production_profile_self_test result=fail reason=negative_missing_required_not_recorded")
with open(sys.argv[2], encoding="utf-8") as handle:
    run = json.load(handle)
if run.get("finalStatus") != "FAIL":
    raise SystemExit("production_profile_self_test result=fail reason=negative_run_status_not_fail")
if run.get("reason") != "prereq_gate_failed":
    raise SystemExit("production_profile_self_test result=fail reason=negative_run_reason_mismatch")
if run.get("blockerType") != "prerequisites":
    raise SystemExit(f"production_profile_self_test result=fail reason=negative_blocker_type_mismatch blockerType={run.get('blockerType')}")
with open(sys.argv[3], encoding="utf-8") as handle:
    runbook = json.load(handle)
if runbook.get("status") != "BLOCKED":
    raise SystemExit("production_profile_self_test result=fail reason=negative_runbook_not_blocked")
profile_run = runbook.get("profileRun") or {}
if profile_run.get("blockerType") != "prerequisites":
    raise SystemExit(f"production_profile_self_test result=fail reason=negative_runbook_blocker_type_mismatch blockerType={profile_run.get('blockerType')}")
PY
  printf 'production_profile_self_test result=pass\n'
  exit 0
fi

run_profile
