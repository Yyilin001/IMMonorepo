#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
export COPYFILE_DISABLE="${COPYFILE_DISABLE:-1}"

RESULT_ROOT="${RESULT_ROOT:-${SCRIPT_DIR}/results}"
RESULT_ROOT="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve())' "${RESULT_ROOT}")"
PERF_PRODUCTION_GATE_JSON="${PERF_PRODUCTION_GATE_JSON:-${RESULT_ROOT}/production-gate.json}"
PERF_PRODUCTION_GATE_PROFILE="${PERF_PRODUCTION_GATE_PROFILE:-normal-product-baseline}"
PERF_PRODUCTION_GATE_MAX_AGE_SECONDS="${PERF_PRODUCTION_GATE_MAX_AGE_SECONDS:-604800}"
PERF_PRODUCTION_GATE_REQUIRE_CURRENT_GIT="${PERF_PRODUCTION_GATE_REQUIRE_CURRENT_GIT:-false}"
PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT="${PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT:-false}"
PERF_PRODUCTION_GATE_EXPECT_BASE_URL="${PERF_PRODUCTION_GATE_EXPECT_BASE_URL:-}"
PERF_PRODUCTION_GATE_EXPECT_TCP_HOST="${PERF_PRODUCTION_GATE_EXPECT_TCP_HOST:-}"
PERF_PRODUCTION_GATE_EXPECT_TCP_PORT="${PERF_PRODUCTION_GATE_EXPECT_TCP_PORT:-}"
PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET="${PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET:-}"
PERF_PRODUCTION_PROFILE_CATALOG="${PERF_PRODUCTION_PROFILE_CATALOG:-${SCRIPT_DIR}/perf_production_profiles.json}"
PRODUCTION_EVIDENCE_OUTPUT_DIR="${PRODUCTION_EVIDENCE_OUTPUT_DIR:-${RESULT_ROOT}/production-evidence}"
PRODUCTION_EVIDENCE_PACKAGE="${PRODUCTION_EVIDENCE_PACKAGE:-}"
PRODUCTION_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS="${PRODUCTION_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS:-true}"
PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS="${PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS:-true}"
PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS="${PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS:-true}"
PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS="${PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS:-true}"
PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP="${PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP:-true}"
PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS="${PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS:-true}"
PRODUCTION_EVIDENCE_REQUIRE_VALIDATION_INVENTORY="${PRODUCTION_EVIDENCE_REQUIRE_VALIDATION_INVENTORY:-true}"
PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP="${PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP:-}"
PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_FILE="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_FILE:-${CLOUD_SECURITY_GROUP_RULES_FILE:-}}"
PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON:-${ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_JSON:-}}"
PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS:-${ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS:-86400}}"
PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID:-${ALIYUN_SECURITY_GROUP_ID:-}}"
PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID:-${ALIYUN_REGION_ID:-}}"
PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR:-${ALIYUN_SECURITY_GROUP_ADMIN_CIDR:-}}"
PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS:-80 443 9000}"
PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS:-3389 5432 6379 9092 8081 8082 18080 8080}"
PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ADMIN_PORTS="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ADMIN_PORTS:-22}"
PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS:-}"
PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS:-86400}"
PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER:-true}"
PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080:-false}"
PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP:-true}"
PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX:-8}"
PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX:-16}"
PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX:-32}"
PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX:-128}"
PRODUCTION_EVIDENCE_GENERATE_VALIDATION_INVENTORY="${PRODUCTION_EVIDENCE_GENERATE_VALIDATION_INVENTORY:-true}"
PRODUCTION_EVIDENCE_REQUIRE_DOCS_AUDIT="${PRODUCTION_EVIDENCE_REQUIRE_DOCS_AUDIT:-true}"
PRODUCTION_EVIDENCE_GENERATE_DOCS_AUDIT="${PRODUCTION_EVIDENCE_GENERATE_DOCS_AUDIT:-true}"
PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PROFILE_GATE="${PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PROFILE_GATE:-true}"
PRODUCTION_EVIDENCE_GENERATE_PRODUCT_PROFILE_GATE="${PRODUCTION_EVIDENCE_GENERATE_PRODUCT_PROFILE_GATE:-true}"
PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_AUDIT="${PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_AUDIT:-true}"
PRODUCTION_EVIDENCE_GENERATE_PRODUCT_CAMPAIGN_AUDIT="${PRODUCTION_EVIDENCE_GENERATE_PRODUCT_CAMPAIGN_AUDIT:-true}"
PRODUCTION_EVIDENCE_SELF_TEST="${PRODUCTION_EVIDENCE_SELF_TEST:-false}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_package_require_cloud_security_group() {
  if bool_enabled "${PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET}"; then
    printf 'true\n'
    return 0
  fi
  if [[ -n "${PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP}" ]]; then
    printf '%s\n' "${PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP}"
    return 0
  fi
  printf 'false\n'
}

PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE="$(resolve_package_require_cloud_security_group)"

require_cloud_security_group_repair_receipt_binding() {
  if ! bool_enabled "${PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE}"; then
    return 0
  fi
  if [[ -z "${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID}" ]]; then
    printf 'production_evidence_package result=fail reason=cloud_security_group_repair_receipt_expected_security_group_id_required hint=set_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID\n' >&2
    return 1
  fi
  if [[ -z "${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID}" ]]; then
    printf 'production_evidence_package result=fail reason=cloud_security_group_repair_receipt_expected_region_id_required hint=set_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID\n' >&2
    return 1
  fi
  if [[ -z "${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR}" ]]; then
    printf 'production_evidence_package result=fail reason=cloud_security_group_repair_receipt_expected_admin_cidr_required hint=set_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR\n' >&2
    return 1
  fi
}

package_host_from_url() {
  local url="$1"
  [[ -n "${url}" ]] || return 0
  python3 - "${url}" <<'PY'
import sys
from urllib.parse import urlsplit

print(urlsplit(sys.argv[1]).hostname or "")
PY
}

resolve_package_expect_base_url() {
  if [[ -n "${PERF_PRODUCTION_GATE_EXPECT_BASE_URL}" ]]; then
    printf '%s\n' "${PERF_PRODUCTION_GATE_EXPECT_BASE_URL}"
    return 0
  fi
  if [[ -n "${PUBLIC_BASE_URL:-}" ]]; then
    printf '%s\n' "${PUBLIC_BASE_URL}"
    return 0
  fi
  if [[ -n "${IM_PUBLIC_BASE_URL:-}" ]]; then
    printf '%s\n' "${IM_PUBLIC_BASE_URL}"
    return 0
  fi
  printf '%s\n' "${BASE_URL:-}"
}

resolve_package_expect_tcp_host() {
  if [[ -n "${PERF_PRODUCTION_GATE_EXPECT_TCP_HOST}" ]]; then
    printf '%s\n' "${PERF_PRODUCTION_GATE_EXPECT_TCP_HOST}"
    return 0
  fi
  if [[ -n "${TCP_HOST:-}" ]]; then
    printf '%s\n' "${TCP_HOST}"
    return 0
  fi
  if [[ -n "${IM_PUBLIC_HOST:-}" ]]; then
    printf '%s\n' "${IM_PUBLIC_HOST}"
    return 0
  fi
  package_host_from_url "$(resolve_package_expect_base_url)"
}

resolve_package_expect_tcp_port() {
  if [[ -n "${PERF_PRODUCTION_GATE_EXPECT_TCP_PORT}" ]]; then
    printf '%s\n' "${PERF_PRODUCTION_GATE_EXPECT_TCP_PORT}"
    return 0
  fi
  if [[ -n "${TCP_PORT:-}" ]]; then
    printf '%s\n' "${TCP_PORT}"
    return 0
  fi
  printf '%s\n' "${IM_TCP_PORT:-9000}"
}

copy_if_present() {
  local src="$1"
  local dst_dir="$2"
  if [[ -f "${src}" ]]; then
    cp "${src}" "${dst_dir}/$(basename "${src}")"
  fi
}

materialize_product_campaign_stage_logs() {
  local stage_dir="$1"
  local source_dir="$2"
  if [[ ! -f "${stage_dir}/product-campaign-run.json" ]]; then
    return 0
  fi
  python3 - "${stage_dir}/product-campaign-run.json" "${stage_dir}" "${source_dir}" <<'PY'
import json
import re
import shutil
import sys
from pathlib import Path

run_json, stage_dir, source_dir = [Path(item) for item in sys.argv[1:4]]
payload = json.loads(run_json.read_text(encoding="utf-8"))
if not bool(payload.get("execute")):
    raise SystemExit(0)

def resolve_source_path(value):
    raw = str(value or "")
    if not raw:
        return None
    path = Path(raw)
    if not path.is_absolute():
        path = source_dir / path
    return path

def safe_name(value: str) -> str:
    sanitized = re.sub(r"[^A-Za-z0-9_.-]+", "-", value.strip())
    sanitized = sanitized.strip(".-")
    return sanitized or "stage"

updated = False
for index, row in enumerate(payload.get("stages") or [], start=1):
    if not isinstance(row, dict):
        continue
    status = str(row.get("status") or "")
    if status not in {"PASS", "FAIL"}:
        continue
    source_log = resolve_source_path(row.get("log"))
    if source_log is None:
        continue
    if not source_log.is_file():
        raise SystemExit(
            "production_evidence_package result=fail "
            f"reason=product_campaign_stage_log_missing stage={row.get('id') or index} path={source_log}"
        )
    stage_id = safe_name(str(row.get("id") or f"stage-{index}"))
    target_name = f"product-campaign-stage-{index:02d}-{stage_id}.log"
    target_path = stage_dir / target_name
    shutil.copyfile(source_log, target_path)
    row["runDir"] = "."
    row["log"] = target_name
    updated = True

if updated:
    run_json.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
}

materialize_current_readiness_artifacts() {
  local stage_dir="$1"
  local source_dir="$2"
  if [[ ! -f "${stage_dir}/current-production-readiness.json" ]]; then
    return 0
  fi
  python3 - "${stage_dir}/current-production-readiness.json" "${stage_dir}" "${source_dir}" <<'PY'
import json
import shutil
import sys
from pathlib import Path

receipt_path, stage_dir, source_dir = [Path(item) for item in sys.argv[1:4]]
payload = json.loads(receipt_path.read_text(encoding="utf-8"))

def resolve_source_path(value):
    raw = str(value or "")
    if not raw:
        return None
    path = Path(raw)
    if not path.is_absolute():
        path = source_dir / path
    return path

def copy_reference(container, key, target_name, *, required=False):
    if not isinstance(container, dict):
        return False
    source = resolve_source_path(container.get(key))
    if source is None:
        if required:
            raise SystemExit(
                "production_evidence_package result=fail "
                f"reason=current_readiness_reference_missing field={key}"
            )
        return False
    if not source.is_file():
        if required:
            raise SystemExit(
                "production_evidence_package result=fail "
                f"reason=current_readiness_reference_file_missing field={key} path={source}"
            )
        return False
    shutil.copyfile(source, stage_dir / target_name)
    container[key] = target_name
    return True

entrypoint = payload.setdefault("entrypoint", {})
artifacts = payload.setdefault("artifacts", {})
copy_reference(entrypoint, "probeJSON", "current-readiness-entrypoint-probe.json", required=True)
copy_reference(artifacts, "operatorNetworkLog", "current-readiness-operator-network.log")
copy_reference(artifacts, "operatorNetworkJSON", "current-readiness-operator-network.json")
copy_reference(artifacts, "entrypointProbeLog", "current-readiness-entrypoint-probe.log")
copy_reference(artifacts, "smokeLog", "current-readiness-normal-product-smoke.log")
copy_reference(artifacts, "productScenarioSuiteLog", "current-readiness-product-scenario-suite.log")
copy_reference(artifacts, "productScenarioSuiteRunJSON", "product-scenario-suite-run.json")
copy_reference(artifacts, "productScenarioSuiteRunMarkdown", "product-scenario-suite-run.md")
copy_reference(artifacts, "productScenarioSuiteStagesTSV", "product-scenario-suite-stages.tsv")
copy_reference(artifacts, "baselineLog", "current-readiness-normal-product-baseline.log")
copy_reference(artifacts, "fullAcceptanceLog", "current-readiness-production-full-acceptance.log")
copy_reference(artifacts, "fullAcceptanceRunJSON", "current-readiness-full-acceptance-run.json")
copy_reference(artifacts, "fullAcceptanceRunbook", "current-readiness-full-acceptance-runbook.md")
copy_reference(artifacts, "prereqSummary", "current-production-prereq-summary.txt")
copy_reference(artifacts, "cloudSecurityGroupRepairReceiptVerifyLog", "current-readiness-cloud-security-group-repair-receipt-verify.log")
artifacts["runDir"] = "."
if (stage_dir / "current-production-dashboard.md").is_file():
    artifacts["dashboard"] = "current-production-dashboard.md"
if (stage_dir / "current-production-state-summary.md").is_file():
    artifacts["stateSummary"] = "current-production-state-summary.md"
receipt_path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
}

relink_current_readiness_cloud_security_group_repair_receipt() {
  local stage_dir="$1"
  if [[ ! -f "${stage_dir}/current-production-readiness.json" || ! -f "${stage_dir}/cloud-security-group-repair-receipt.json" ]]; then
    return 0
  fi
  python3 - "${stage_dir}/current-production-readiness.json" <<'PY'
import json
import sys
from pathlib import Path

receipt_path = Path(sys.argv[1])
payload = json.loads(receipt_path.read_text(encoding="utf-8"))
policy = payload.setdefault("evidencePolicy", {})
artifacts = payload.setdefault("artifacts", {})
if isinstance(policy, dict) and policy.get("requireCloudSecurityGroupRepairReceipt") is True:
    policy["cloudSecurityGroupRepairReceiptJSON"] = "cloud-security-group-repair-receipt.json"
    artifacts["cloudSecurityGroupRepairReceiptJSON"] = "cloud-security-group-repair-receipt.json"
receipt_path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
}

refresh_current_readiness_markdown() {
  local stage_dir="$1"
  if [[ ! -f "${stage_dir}/current-production-readiness.json" || ! -f "${stage_dir}/current-production-readiness.md" ]]; then
    return 0
  fi
  python3 - "${stage_dir}/current-production-readiness.json" "${stage_dir}/current-production-readiness.md" "${SCRIPT_DIR}" <<'PY'
import json
import sys
from pathlib import Path

json_path, markdown_path, script_dir = map(Path, sys.argv[1:4])
sys.path.insert(0, str(script_dir))
from perf_current_production_readiness_verify import build_readiness_markdown

payload = json.loads(json_path.read_text(encoding="utf-8"))
markdown_path.write_text(build_readiness_markdown(payload), encoding="utf-8")
PY
}

require_file() {
  local path="$1"
  local reason="$2"
  if [[ ! -f "${path}" ]]; then
    printf 'production_evidence_package result=fail reason=%s path=%s\n' "${reason}" "${path}" >&2
    return 1
  fi
}

stage_cloud_security_group_snapshot() {
  local stage_dir="$1"
  local source_file="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_FILE}"
  if [[ -z "${source_file}" ]]; then
    if bool_enabled "${PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE}"; then
      printf 'production_evidence_package result=fail reason=cloud_security_group_snapshot_required hint=set_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_FILE\n' >&2
      return 1
    fi
    return 0
  fi
  if [[ ! -f "${source_file}" ]]; then
    printf 'production_evidence_package result=fail reason=cloud_security_group_snapshot_missing path=%s\n' "${source_file}" >&2
    return 1
  fi
  CLOUD_SECURITY_GROUP_RULES_FILE="${source_file}" \
    CLOUD_SECURITY_GROUP_PROFILE=production \
    CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS}" \
    CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS}" \
    CLOUD_SECURITY_GROUP_ADMIN_PORTS="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ADMIN_PORTS}" \
    CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS}" \
    CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS}" \
    CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER=false \
    CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080}" \
    CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP}" \
    CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX}" \
    CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX}" \
    CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX}" \
    CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX}" \
    bash "${REPO_ROOT}/deploy/ubuntu/26_audit_cloud_security_group.sh" >/dev/null
  cp "${source_file}" "${stage_dir}/cloud-security-group.json"
}

stage_cloud_security_group_repair_receipt() {
  local stage_dir="$1"
  local receipt="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON}"
  if [[ -z "${receipt}" ]]; then
    if bool_enabled "${PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE}"; then
      printf 'production_evidence_package result=fail reason=cloud_security_group_repair_receipt_required hint=set_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON\n' >&2
      return 1
    fi
    return 0
  fi
  if [[ ! -f "${receipt}" ]]; then
    printf 'production_evidence_package result=fail reason=cloud_security_group_repair_receipt_missing path=%s\n' "${receipt}" >&2
    return 1
  fi
  require_cloud_security_group_repair_receipt_binding || return 1

  ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${receipt}" \
    ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_REQUIRE_APPLIED=true \
    ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_REQUIRE_VERIFIED=true \
    ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS}" \
    ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID}" \
    ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID}" \
    ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR}" \
    bash "${REPO_ROOT}/deploy/ubuntu/31_verify_aliyun_security_group_repair_receipt.sh" >/dev/null

  python3 - "${receipt}" "${stage_dir}" <<'PY'
import hashlib
import json
import shutil
import sys
from pathlib import Path

receipt_path = Path(sys.argv[1]).resolve()
stage_dir = Path(sys.argv[2]).resolve()
target_receipt = stage_dir / "cloud-security-group-repair-receipt.json"
targets = {
    "snapshot": stage_dir / "cloud-security-group-repair-snapshot.json",
    "postApplySnapshot": stage_dir / "cloud-security-group-repair-post-apply-snapshot.json",
    "plan": stage_dir / "cloud-security-group-repair-plan.json",
}
receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
artifacts = receipt.get("artifacts")
if not isinstance(artifacts, dict):
    raise SystemExit("production_evidence_package result=fail reason=cloud_security_group_repair_receipt_artifacts_missing")

def file_record(path: Path) -> dict[str, object]:
    data = path.read_bytes()
    return {
        "path": str(path),
        "present": True,
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
    }

for name, target in targets.items():
    entry = artifacts.get(name)
    required = name != "postApplySnapshot" or bool(receipt.get("verified"))
    if not isinstance(entry, dict):
        if required:
            raise SystemExit(
                "production_evidence_package result=fail "
                f"reason=cloud_security_group_repair_artifact_entry_invalid name={name}"
            )
        continue
    if not bool(entry.get("present")):
        if required:
            raise SystemExit(
                "production_evidence_package result=fail "
                f"reason=cloud_security_group_repair_artifact_not_present name={name}"
            )
        receipt["artifacts"][name] = {"path": "", "present": False, "bytes": 0, "sha256": ""}
        continue
    source = Path(str(entry.get("path") or "")).resolve()
    if not source.is_file():
        raise SystemExit(
            "production_evidence_package result=fail "
            f"reason=cloud_security_group_repair_artifact_missing name={name} path={source}"
        )
    shutil.copyfile(source, target)
    receipt["artifacts"][name] = file_record(target)
    if name == "snapshot":
        receipt["snapshot"] = str(target)
    elif name == "postApplySnapshot":
        receipt["postApplySnapshot"] = str(target)
    elif name == "plan":
        receipt["plan"] = str(target)

plan_path = targets["plan"]
if plan_path.is_file():
    plan = json.loads(plan_path.read_text(encoding="utf-8"))
    if str(plan.get("snapshot") or ""):
        plan["snapshot"] = str(targets["snapshot"])
        plan_path.write_text(json.dumps(plan, indent=2, sort_keys=True), encoding="utf-8")
    receipt["artifacts"]["plan"] = file_record(plan_path)

target_receipt.write_text(json.dumps(receipt, indent=2, sort_keys=True), encoding="utf-8")
PY

  ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${stage_dir}/cloud-security-group-repair-receipt.json" \
    ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_REQUIRE_APPLIED=true \
    ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_REQUIRE_VERIFIED=true \
    ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS=0 \
    ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID}" \
    ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID}" \
    ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR}" \
    bash "${REPO_ROOT}/deploy/ubuntu/31_verify_aliyun_security_group_repair_receipt.sh" >/dev/null
}

require_product_plan_pass() {
  local path="$1"
  python3 - "${path}" <<'PY'
import json
import sys
from pathlib import Path

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)
status = str(payload.get("finalStatus") or "")
if status != "PASS":
    reason = payload.get("reason") or "-"
    raise SystemExit(
        "production_evidence_package result=fail "
        f"reason=product_plan_not_pass path={path} status={status or '-'} runReason={reason}"
    )
PY
}

write_sha256sums() {
  local dir="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "${dir}" && sha256sum ./* >SHA256SUMS)
  else
    (cd "${dir}" && shasum -a 256 ./* >SHA256SUMS)
  fi
}

verify_profile_artifacts() {
  local stage_dir="$1"
  local package_path="$2"
  require_file "${stage_dir}/production-profile-run.json" "profile_run_missing" || return 1
  require_file "${stage_dir}/production-profile-plan.json" "profile_plan_missing" || return 1
  require_file "${stage_dir}/production-profile-prereq-plan.json" "profile_prereq_plan_missing" || return 1
  require_file "${stage_dir}/production-profile-prereq-audit.md" "profile_prereq_audit_md_missing" || return 1
  require_file "${stage_dir}/production-profile-prereq-audit.json" "profile_prereq_audit_missing" || return 1
  require_file "${stage_dir}/production-profile-scenario-catalog.json" "profile_scenario_catalog_missing" || return 1
  require_file "${stage_dir}/production-profile-runbook.json" "profile_runbook_json_missing" || return 1
  require_file "${stage_dir}/production-profile-runbook.md" "profile_runbook_md_missing" || return 1
  python3 "${SCRIPT_DIR}/perf_profile_artifacts_verify.py" \
    --gate-json "${stage_dir}/production-gate.json" \
    --profile-run-json "${stage_dir}/production-profile-run.json" \
    --profile-plan-json "${stage_dir}/production-profile-plan.json" \
    --profile-runbook-json "${stage_dir}/production-profile-runbook.json" \
    --profile-runbook-md "${stage_dir}/production-profile-runbook.md" \
    --prereq-plan-json "${stage_dir}/production-profile-prereq-plan.json" \
    --prereq-audit-json "${stage_dir}/production-profile-prereq-audit.json" \
    --scenario-catalog-json "${stage_dir}/production-profile-scenario-catalog.json" \
    --expected-package-path "${package_path}" >/dev/null
}

verify_product_plan_artifacts() {
  local stage_dir="$1"
  if [[ ! -f "${stage_dir}/product-test-plan-run.json" ]]; then
    if bool_enabled "${PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS}"; then
      printf 'production_evidence_package result=fail reason=product_plan_run_missing path=%s\n' "${stage_dir}/product-test-plan-run.json" >&2
      return 1
    fi
    return 0
  fi
  require_product_plan_pass "${stage_dir}/product-test-plan-run.json" || return 1
  require_file "${stage_dir}/product-test-plan-preview.json" "product_plan_preview_missing" || return 1
  require_file "${stage_dir}/product-test-plan-phases.tsv" "product_plan_phases_missing" || return 1
  require_file "${stage_dir}/product-test-prereq-plan.json" "product_plan_prereq_plan_missing" || return 1
  require_file "${stage_dir}/product-test-prereq-audit.json" "product_plan_prereq_audit_missing" || return 1
  require_file "${stage_dir}/product-test-prereq-audit.md" "product_plan_prereq_audit_md_missing" || return 1
  require_file "${stage_dir}/product-test-scenario-catalog.json" "product_plan_scenario_catalog_missing" || return 1
  require_file "${stage_dir}/product-test-runbook.json" "product_plan_runbook_missing" || return 1
  require_file "${stage_dir}/product-test-runbook.md" "product_plan_runbook_md_missing" || return 1
  python3 "${SCRIPT_DIR}/perf_product_plan_artifacts_verify.py" \
    --product-run-json "${stage_dir}/product-test-plan-run.json" \
    --plan-preview-json "${stage_dir}/product-test-plan-preview.json" \
    --phases-tsv "${stage_dir}/product-test-plan-phases.tsv" \
    --prereq-plan-json "${stage_dir}/product-test-prereq-plan.json" \
    --prereq-audit-json "${stage_dir}/product-test-prereq-audit.json" \
    --prereq-audit-md "${stage_dir}/product-test-prereq-audit.md" \
    --scenario-catalog-json "${stage_dir}/product-test-scenario-catalog.json" \
    --runbook-json "${stage_dir}/product-test-runbook.json" \
    --runbook-md "${stage_dir}/product-test-runbook.md" \
    --require-pass >/dev/null
}

verify_product_campaign_artifacts() {
  local stage_dir="$1"
  local verify_args=(--require-pass)
  if [[ ! -f "${stage_dir}/product-campaign-run.json" ]]; then
    if bool_enabled "${PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS}"; then
      printf 'production_evidence_package result=fail reason=product_campaign_run_missing path=%s\n' "${stage_dir}/product-campaign-run.json" >&2
      return 1
    fi
    return 0
  fi
  require_file "${stage_dir}/product-campaign-runbook.md" "product_campaign_runbook_missing" || return 1
  if bool_enabled "${PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS}"; then
    verify_args+=(--require-production-gate-campaign)
  fi
  python3 "${SCRIPT_DIR}/perf_product_campaign_artifacts_verify.py" \
    --campaign-run-json "${stage_dir}/product-campaign-run.json" \
    --runbook "${stage_dir}/product-campaign-runbook.md" \
    --require-portable-stage-logs \
    "${verify_args[@]}" >/dev/null
}

verify_product_scenario_suite_artifacts() {
  local stage_dir="$1"
  local verify_args=(--require-pass)
  if [[ ! -f "${stage_dir}/product-scenario-suite-run.json" ]]; then
    if bool_enabled "${PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS}"; then
      printf 'production_evidence_package result=fail reason=product_scenario_suite_run_missing path=%s\n' "${stage_dir}/product-scenario-suite-run.json" >&2
      return 1
    fi
    return 0
  fi
  require_file "${stage_dir}/product-scenario-suite-run.md" "product_scenario_suite_markdown_missing" || return 1
  if bool_enabled "${PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP}"; then
    verify_args+=(--require-no-large-group)
  fi
  python3 "${SCRIPT_DIR}/perf_product_scenario_suite_verify.py" \
    --suite-run-json "${stage_dir}/product-scenario-suite-run.json" \
    --markdown "${stage_dir}/product-scenario-suite-run.md" \
    "${verify_args[@]}" >/dev/null
}

scan_stage_for_secrets() {
  local stage_dir="$1"
  if ! python3 "${SCRIPT_DIR}/perf_secret_scan.py" --root "${stage_dir}" >"${stage_dir}/secret-scan.log" 2>&1; then
    cat "${stage_dir}/secret-scan.log" >&2 || true
    return 1
  fi
}

ensure_validation_inventory() {
  local gate_json="$1"
  if bool_enabled "${PRODUCTION_EVIDENCE_GENERATE_VALIDATION_INVENTORY}"; then
    python3 "${SCRIPT_DIR}/perf_validation_inventory.py" \
      --repo-root "${REPO_ROOT}" \
      --json-output "${RESULT_ROOT}/validation-inventory.json" \
      --md-output "${RESULT_ROOT}/validation-inventory.md" \
      --bash-bin "$(command -v bash || true)" \
      --python-bin "$(command -v python3 || true)" \
      --k6-bin "$(command -v k6 || true)" \
      --k6-inspect-requested "false" \
      --k6-inspect-status "skipped_disabled" >/dev/null
  fi
  if bool_enabled "${PRODUCTION_EVIDENCE_REQUIRE_VALIDATION_INVENTORY}"; then
    require_file "${RESULT_ROOT}/validation-inventory.json" "validation_inventory_missing" || return 1
    require_file "${RESULT_ROOT}/validation-inventory.md" "validation_inventory_md_missing" || return 1
    python3 "${SCRIPT_DIR}/perf_validation_inventory.py" \
      --verify-json "${RESULT_ROOT}/validation-inventory.json" \
      --verify-md "${RESULT_ROOT}/validation-inventory.md" \
      --gate-json "${gate_json}" >/dev/null || return 1
  fi
}

ensure_docs_audit() {
  if bool_enabled "${PRODUCTION_EVIDENCE_GENERATE_DOCS_AUDIT}"; then
    python3 "${SCRIPT_DIR}/perf_docs_audit.py" \
      --readme "${SCRIPT_DIR}/README.md" \
      --matrix-script "${SCRIPT_DIR}/run_perf_scenarios.sh" \
      --profile-catalog "${PERF_PRODUCTION_PROFILE_CATALOG}" \
      --output "${RESULT_ROOT}/docs-audit.md" \
      --json-output "${RESULT_ROOT}/docs-audit.json" \
      --csv-output "${RESULT_ROOT}/docs-audit.csv" \
      --strict >/dev/null
  fi
  if bool_enabled "${PRODUCTION_EVIDENCE_REQUIRE_DOCS_AUDIT}"; then
    require_file "${RESULT_ROOT}/docs-audit.json" "docs_audit_missing" || return 1
    require_file "${RESULT_ROOT}/docs-audit.md" "docs_audit_md_missing" || return 1
    python3 "${SCRIPT_DIR}/perf_docs_audit.py" \
      --verify-json "${RESULT_ROOT}/docs-audit.json" \
      --verify-md "${RESULT_ROOT}/docs-audit.md" \
      --readme "${SCRIPT_DIR}/README.md" \
      --matrix-script "${SCRIPT_DIR}/run_perf_scenarios.sh" \
      --profile-catalog "${PERF_PRODUCTION_PROFILE_CATALOG}" \
      --strict >/dev/null || return 1
  fi
}

ensure_product_profile_gate() {
  if bool_enabled "${PRODUCTION_EVIDENCE_GENERATE_PRODUCT_PROFILE_GATE}"; then
    python3 "${SCRIPT_DIR}/perf_product_profile_gate.py" \
      --profile-catalog "${PERF_PRODUCTION_PROFILE_CATALOG}" \
      --matrix-script "${SCRIPT_DIR}/run_perf_scenarios.sh" \
      --profile normal-product-smoke \
      --profile normal-product-baseline \
      --profile normal-product-capacity \
      --require-no-maturity-gaps \
      --output "${RESULT_ROOT}/product-profile-gate.md" \
      --json-output "${RESULT_ROOT}/product-profile-gate.json" \
      --csv-output "${RESULT_ROOT}/product-profile-gate.csv" \
      --strict >/dev/null
  fi
  if bool_enabled "${PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PROFILE_GATE}"; then
    require_file "${RESULT_ROOT}/product-profile-gate.json" "product_profile_gate_missing" || return 1
    require_file "${RESULT_ROOT}/product-profile-gate.md" "product_profile_gate_md_missing" || return 1
    python3 "${SCRIPT_DIR}/perf_product_profile_gate.py" \
      --verify-json "${RESULT_ROOT}/product-profile-gate.json" \
      --verify-md "${RESULT_ROOT}/product-profile-gate.md" \
      --strict >/dev/null || return 1
    python3 "${SCRIPT_DIR}/perf_product_profile_gate.py" \
      --profile-catalog "${PERF_PRODUCTION_PROFILE_CATALOG}" \
      --matrix-script "${SCRIPT_DIR}/run_perf_scenarios.sh" \
      --profile normal-product-smoke \
      --profile normal-product-baseline \
      --profile normal-product-capacity \
      --require-no-maturity-gaps \
      --json-output "${RESULT_ROOT}/product-profile-gate.verify.json" \
      --strict >/dev/null || return 1
    python3 - "${RESULT_ROOT}/product-profile-gate.json" "${RESULT_ROOT}/product-profile-gate.verify.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    current = json.load(handle)
with open(sys.argv[2], encoding="utf-8") as handle:
    verified = json.load(handle)
if current.get("status") != "PASS":
    raise SystemExit("production_evidence_package result=fail reason=product_profile_gate_not_pass")
if current.get("requiredDomains") != verified.get("requiredDomains"):
    raise SystemExit("production_evidence_package result=fail reason=product_profile_gate_required_domains_mismatch")
if current.get("profilesChecked") != verified.get("profilesChecked"):
    raise SystemExit("production_evidence_package result=fail reason=product_profile_gate_profiles_mismatch")
if current.get("errorCount") != 0:
    raise SystemExit("production_evidence_package result=fail reason=product_profile_gate_errors")
for row in current.get("profiles") or []:
    if row.get("status") != "PASS":
        raise SystemExit("production_evidence_package result=fail reason=product_profile_gate_profile_not_pass")
    for key in ("missingDomains",):
        if row.get(key):
            raise SystemExit(f"production_evidence_package result=fail reason=product_profile_gate_{key}")
    for key in ("largeGroupScenarioCount", "forbiddenScenarioCount", "unknownScenarioCount"):
        if int(row.get(key) or 0) != 0:
            raise SystemExit(f"production_evidence_package result=fail reason=product_profile_gate_{key}")
PY
  fi
}

ensure_product_campaign_audit() {
  if bool_enabled "${PRODUCTION_EVIDENCE_GENERATE_PRODUCT_CAMPAIGN_AUDIT}"; then
    python3 "${SCRIPT_DIR}/perf_product_campaign_audit.py" \
      --campaigns "${SCRIPT_DIR}/perf_product_campaigns.json" \
      --product-plan-script "${SCRIPT_DIR}/run_product_test_plan.sh" \
      --profile-catalog "${PERF_PRODUCTION_PROFILE_CATALOG}" \
      --matrix-script "${SCRIPT_DIR}/run_perf_scenarios.sh" \
      --output "${RESULT_ROOT}/product-campaign-audit.md" \
      --json-output "${RESULT_ROOT}/product-campaign-audit.json" \
      --csv-output "${RESULT_ROOT}/product-campaign-audit.csv" \
      --strict >/dev/null
  fi
  if bool_enabled "${PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_AUDIT}"; then
    require_file "${RESULT_ROOT}/product-campaign-audit.json" "product_campaign_audit_missing" || return 1
    require_file "${RESULT_ROOT}/product-campaign-audit.md" "product_campaign_audit_md_missing" || return 1
    python3 "${SCRIPT_DIR}/perf_product_campaign_audit.py" \
      --verify-json "${RESULT_ROOT}/product-campaign-audit.json" \
      --verify-md "${RESULT_ROOT}/product-campaign-audit.md" \
      --strict >/dev/null || return 1
    python3 - "${RESULT_ROOT}/product-campaign-audit.json" "${RESULT_ROOT}/product-campaign-audit.md" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
markdown = Path(sys.argv[2]).read_text(encoding="utf-8")
if payload.get("status") != "PASS":
    raise SystemExit("production_evidence_package result=fail reason=product_campaign_audit_not_pass")
if int(payload.get("errorCount") or 0) != 0:
    raise SystemExit("production_evidence_package result=fail reason=product_campaign_audit_errors")
policies = payload.get("requiredPhasePolicies") or []
if len(policies) < 3:
    raise SystemExit("production_evidence_package result=fail reason=product_campaign_audit_policies_missing")
by_campaign = {str(row.get("campaign") or ""): row for row in policies if isinstance(row, dict)}
for campaign in ("non-large-group-release", "product-scenario-regression", "product-scenario-acceptance"):
    if campaign not in by_campaign:
        raise SystemExit(f"production_evidence_package result=fail reason=product_campaign_audit_policy_missing campaign={campaign}")
non_large = set(by_campaign["non-large-group-release"].get("requiredPhases") or [])
for phase in ("sync-read", "direct-chat", "group-workflow", "realtime-direct"):
    if phase not in non_large:
        raise SystemExit(f"production_evidence_package result=fail reason=product_campaign_audit_non_large_phase_missing phase={phase}")
if "## Required Phase Policies" not in markdown:
    raise SystemExit("production_evidence_package result=fail reason=product_campaign_audit_md_policies_missing")
PY
  fi
}

ensure_profile_runbook() {
  if [[ -f "${RESULT_ROOT}/production-profile-runbook.json" && -f "${RESULT_ROOT}/production-profile-runbook.md" ]]; then
    return 0
  fi
  if [[ ! -f "${RESULT_ROOT}/production-profile-plan.json" ]]; then
    return 0
  fi
  local status_filter_arg="--no-status-filter-target"
  if bool_enabled "${PERF_STATUS_FILTER_TARGET:-true}"; then
    status_filter_arg="--status-filter-target"
  fi
  python3 "${SCRIPT_DIR}/perf_production_profile_runbook.py" \
    --plan "${RESULT_ROOT}/production-profile-plan.json" \
    --prereq-audit "${RESULT_ROOT}/production-profile-prereq-audit.json" \
    --profile-run "${RESULT_ROOT}/production-profile-run.json" \
    --profile "${PERF_PRODUCTION_GATE_PROFILE}" \
    --result-root "${RESULT_ROOT}" \
    --batch-size "${PRODUCTION_PROFILE_BATCH_SIZE:-6}" \
    "${status_filter_arg}" \
    --max-age-seconds "${PERF_PRODUCTION_GATE_MAX_AGE_SECONDS}" \
    --base-url "${BASE_URL:-https://chat.myim-prod.com}" \
    --tcp-host "${TCP_HOST:-tcp.myim-prod.com}" \
    --tcp-port "${TCP_PORT:-9000}" \
    --account-file "${ACCOUNT_FILE:-}" \
    --conversation-id "${IM_CONVERSATION_ID:-}" \
    --internal-secret "${IM_INTERNAL_SECRET:-${IM_INTERNAL_SHARED_SECRET:-}}" \
    --auth-email-webhook-url "${IM_AUTH_EMAIL_WEBHOOK_SINK_URL:-}" \
    --verification-code "${IM_ACCOUNT_VERIFICATION_CODE:-}" \
    --password-reset-code "${IM_ACCOUNT_PASSWORD_RESET_CODE:-}" \
    --output "${RESULT_ROOT}/production-profile-runbook.md" \
    --json-output "${RESULT_ROOT}/production-profile-runbook.json" >/dev/null
}

ensure_product_plan_runbook() {
  if [[ -f "${RESULT_ROOT}/product-test-runbook.json" && -f "${RESULT_ROOT}/product-test-runbook.md" ]]; then
    return 0
  fi
  if [[ ! -f "${RESULT_ROOT}/product-test-plan-run.json" ]]; then
    return 0
  fi
  python3 "${SCRIPT_DIR}/perf_product_test_plan_runbook.py" \
    --product-run-json "${RESULT_ROOT}/product-test-plan-run.json" \
    --prereq-audit-json "${RESULT_ROOT}/product-test-prereq-audit.json" \
    --result-root "${RESULT_ROOT}" \
    --output "${RESULT_ROOT}/product-test-runbook.md" \
    --json-output "${RESULT_ROOT}/product-test-runbook.json" >/dev/null
}

enrich_profile_run_receipt() {
  local stage_dir="$1"
  local package_path="$2"
  if [[ ! -f "${stage_dir}/production-profile-run.json" ]]; then
    return 0
  fi
  python3 - "${stage_dir}/production-profile-run.json" "${package_path}" <<'PY'
import json
import sys
import time
from pathlib import Path

run_path, package_path = sys.argv[1:3]
with open(run_path, encoding="utf-8") as handle:
    payload = json.load(handle)
payload["package"] = {
    "status": "PACKAGED",
    "path": package_path,
    "fileName": Path(package_path).name,
    "packagedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
}
with open(run_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
}

write_summary() {
  local output="$1"
  local gate_json="$2"
  local stage_dir="$3"
  python3 - "${output}" "${gate_json}" "${stage_dir}" <<'PY'
import json
import sys
from pathlib import Path

output_path, gate_path, stage_dir = sys.argv[1:4]
with open(gate_path, encoding="utf-8") as handle:
    gate = json.load(handle)
summary = gate.get("summary") or {}
source = gate.get("source") or {}
catalog = gate.get("profileCatalog") or {}
stage_path = Path(stage_dir)
profile_run = {}
profile_run_path = stage_path / "production-profile-run.json"
if profile_run_path.exists():
    with open(profile_run_path, encoding="utf-8") as handle:
        profile_run = json.load(handle)
profile_run_plan = profile_run.get("plan") or {}
profile_package = profile_run.get("package") or {}
docs_audit = {}
docs_audit_path = stage_path / "docs-audit.json"
if docs_audit_path.exists():
    with open(docs_audit_path, encoding="utf-8") as handle:
        docs_audit = json.load(handle)
product_profile_gate = {}
product_profile_gate_path = stage_path / "product-profile-gate.json"
if product_profile_gate_path.exists():
    with open(product_profile_gate_path, encoding="utf-8") as handle:
        product_profile_gate = json.load(handle)
product_campaign_audit = {}
product_campaign_audit_path = stage_path / "product-campaign-audit.json"
if product_campaign_audit_path.exists():
    with open(product_campaign_audit_path, encoding="utf-8") as handle:
        product_campaign_audit = json.load(handle)
validation_inventory = {}
validation_inventory_path = stage_path / "validation-inventory.json"
if validation_inventory_path.exists():
    with open(validation_inventory_path, encoding="utf-8") as handle:
        validation_inventory = json.load(handle)
validation_inventory_summary = validation_inventory.get("summary") or {}
profile_artifacts = [
    name for name in [
        "production-profile-run.json",
        "production-profile-plan.json",
        "production-profile-operator-network.log",
        "production-profile-operator-network.json",
        "production-profile-entrypoint-probe.log",
        "production-profile-entrypoint-probe.json",
        "production-profile-runbook.md",
        "production-profile-runbook.json",
        "production-profile-prereq-plan.json",
        "production-profile-prereq-audit.md",
        "production-profile-prereq-audit.json",
        "production-profile-scenario-catalog.json",
    ]
    if (stage_path / name).exists()
]
validation_artifacts = [
    name for name in [
        "docs-audit.json",
        "docs-audit.md",
        "product-profile-gate.json",
        "product-profile-gate.md",
        "product-campaign-audit.json",
        "product-campaign-audit.md",
        "perf_production_profiles.json",
        "perf_product_campaigns.json",
        "validation-inventory.json",
        "validation-inventory.md",
    ]
    if (stage_path / name).exists()
]
product_run = {}
product_run_path = stage_path / "product-test-plan-run.json"
if product_run_path.exists():
    with open(product_run_path, encoding="utf-8") as handle:
        product_run = json.load(handle)
product_preview = {}
product_preview_path = stage_path / "product-test-plan-preview.json"
if product_preview_path.exists():
    with open(product_preview_path, encoding="utf-8") as handle:
        product_preview = json.load(handle)
product_preview_summary = product_preview.get("summary") or {}
product_prereq = {}
product_prereq_path = stage_path / "product-test-prereq-audit.json"
if product_prereq_path.exists():
    with open(product_prereq_path, encoding="utf-8") as handle:
        product_prereq = json.load(handle)
product_prereq_summary = product_prereq.get("summary") or {}
profile_entrypoint_probe = {}
profile_entrypoint_probe_path = stage_path / "production-profile-entrypoint-probe.json"
if profile_entrypoint_probe_path.exists():
    with open(profile_entrypoint_probe_path, encoding="utf-8") as handle:
        profile_entrypoint_probe = json.load(handle)
profile_entrypoint_blocker = profile_entrypoint_probe.get("blocker") if isinstance(profile_entrypoint_probe.get("blocker"), dict) else {}
profile_entrypoint_tcp_status = profile_entrypoint_probe.get("tcpStatus") or (profile_entrypoint_probe.get("signals") or {}).get("tcpStatus") or "-"
profile_entrypoint_edge_intercept = profile_entrypoint_probe.get("edgeIntercept") or (profile_entrypoint_probe.get("signals") or {}).get("edgeIntercept") or "-"
profile_entrypoint_protocols = profile_entrypoint_probe.get("portProtocols") or (profile_entrypoint_probe.get("signals") or {}).get("portProtocols") or []
profile_entrypoint_protocol_count = len(profile_entrypoint_protocols) if isinstance(profile_entrypoint_protocols, list) else "-"
product_artifacts = [
    name for name in [
        "product-test-plan-run.json",
        "product-test-plan-preview.json",
        "product-test-plan-phases.tsv",
        "product-test-prereq-plan.json",
        "product-test-prereq-audit.md",
        "product-test-prereq-audit.json",
        "product-test-scenario-catalog.json",
        "product-test-runbook.md",
        "product-test-runbook.json",
    ]
    if (stage_path / name).exists()
]
campaign_run = {}
campaign_run_path = stage_path / "product-campaign-run.json"
if campaign_run_path.exists():
    with open(campaign_run_path, encoding="utf-8") as handle:
        campaign_run = json.load(handle)
campaign_target = campaign_run.get("target") or {}
campaign_target_summary = ",".join([
    str(campaign_target.get("baseURL") or "-"),
    str(campaign_target.get("tcpHost") or "-"),
    str(campaign_target.get("tcpPort") or "-"),
])
campaign_artifacts = [
    name for name in [
        "product-campaign-run.json",
        "product-campaign-runbook.md",
    ]
    if (stage_path / name).exists()
]
campaign_artifacts.extend(sorted(path.name for path in stage_path.glob("product-campaign-stage-*.log") if path.is_file()))
suite_run = {}
suite_run_path = stage_path / "product-scenario-suite-run.json"
if suite_run_path.exists():
    with open(suite_run_path, encoding="utf-8") as handle:
        suite_run = json.load(handle)
suite_coverage = suite_run.get("coverageSummary") or {}
suite_artifacts = [
    name for name in [
        "product-scenario-suite-run.json",
        "product-scenario-suite-run.md",
        "product-scenario-suite-stages.tsv",
    ]
    if (stage_path / name).exists()
]
current_readiness = {}
current_readiness_path = stage_path / "current-production-readiness.json"
if current_readiness_path.exists():
    with open(current_readiness_path, encoding="utf-8") as handle:
        current_readiness = json.load(handle)
current_requested = current_readiness.get("requestedRuns") or {}
current_runs = current_readiness.get("runs") or {}
current_operator_network_log = stage_path / "current-readiness-operator-network.log"
current_operator_network_json = stage_path / "current-readiness-operator-network.json"
current_operator_network = {"present": current_operator_network_log.exists() or current_operator_network_json.exists(), "failed": False, "warnings": []}
if current_operator_network_json.exists():
    with open(current_operator_network_json, encoding="utf-8") as handle:
        current_operator_payload = json.load(handle)
    current_operator_network["failed"] = bool(current_operator_payload.get("failed")) or current_operator_payload.get("status") == "fail"
    current_operator_network["warnings"] = sorted(str(item) for item in current_operator_payload.get("warnings") or [])
elif current_operator_network_log.exists():
    warnings = set()
    for line in current_operator_network_log.read_text(encoding="utf-8", errors="replace").splitlines():
        if "operator-network result=fail" in line:
            current_operator_network["failed"] = True
        for token in line.split():
            if token.startswith("warning="):
                warning = token.split("=", 1)[1]
                if warning not in {"", "clean", "<none>"}:
                    warnings.add(warning)
    current_operator_network["warnings"] = sorted(warnings)
current_full_acceptance_run = {}
current_full_acceptance_run_path = stage_path / "current-readiness-full-acceptance-run.json"
if current_full_acceptance_run_path.exists():
    with open(current_full_acceptance_run_path, encoding="utf-8") as handle:
        current_full_acceptance_run = json.load(handle)
else:
    raw_full_run_path = (current_readiness.get("artifacts") or {}).get("fullAcceptanceRunJSON")
    if raw_full_run_path:
        resolved_full_run_path = Path(raw_full_run_path)
        if not resolved_full_run_path.is_absolute():
            resolved_full_run_path = stage_path / resolved_full_run_path
        if resolved_full_run_path.exists():
            with open(resolved_full_run_path, encoding="utf-8") as handle:
                current_full_acceptance_run = json.load(handle)
current_readiness_artifacts = [
    name for name in [
        "current-production-readiness.json",
        "current-production-readiness.md",
        "current-production-dashboard.json",
        "current-production-dashboard.md",
        "current-production-state-summary.json",
        "current-production-state-summary.md",
        "current-production-state-summary.csv",
        "current-production-prereq-summary.txt",
        "current-readiness-operator-network.log",
        "current-readiness-operator-network.json",
        "current-readiness-product-scenario-suite.log",
        "product-scenario-suite-run.json",
        "product-scenario-suite-run.md",
        "product-scenario-suite-stages.tsv",
        "current-readiness-production-full-acceptance.log",
        "current-readiness-full-acceptance-run.json",
        "current-readiness-full-acceptance-runbook.md",
    ]
    if (stage_path / name).exists()
]
lines = [
    "# Production Performance Evidence",
    "",
    f"- gate: `{Path(gate_path).name}`",
    f"- status: `{gate.get('status') or 'UNKNOWN'}`",
    f"- profile: `{gate.get('profile') or '-'}`",
    f"- required: `{summary.get('requiredScenarioCount') or 0}`",
    f"- passed/failed/missing: `{summary.get('passedScenarioCount') or 0}/{summary.get('failedScenarioCount') or 0}/{summary.get('missingScenarioCount') or 0}`",
    f"- evidenceOldestMtime: `{summary.get('evidenceOldestMtime') or '-'}`",
    f"- evidenceNewestMtime: `{summary.get('evidenceNewestMtime') or '-'}`",
    f"- gitCommit: `{source.get('gitCommit') or '-'}`",
    f"- gitBranch: `{source.get('gitBranch') or '-'}`",
    f"- gitDirty: `{source.get('gitDirty')}`",
    f"- profileCatalogSha256: `{catalog.get('sha256') or '-'}`",
    f"- profileRunStatus: `{profile_run.get('finalStatus') or '-'}`",
    f"- profileRunBlockerType: `{profile_run.get('blockerType') or '-'}`",
    f"- profileEntrypointDiagnosis: `{profile_entrypoint_probe.get('diagnosis') or '-'}`",
    f"- profileEntrypointTcpStatus: `{profile_entrypoint_tcp_status}`",
    f"- profileEntrypointEdgeIntercept: `{profile_entrypoint_edge_intercept}`",
    f"- profileEntrypointPortProtocols: `{profile_entrypoint_protocol_count}`",
    f"- profileEntrypointBlocker: `{profile_entrypoint_blocker.get('type') or '-'}/{profile_entrypoint_blocker.get('severity') or '-'}` preventsPerformanceEvidence=`{profile_entrypoint_blocker.get('preventsPerformanceEvidence') if profile_entrypoint_blocker else '-'}` action=`{profile_entrypoint_blocker.get('action') or '-'}`",
    f"- profileRunSelected/skipped/batches: `{profile_run_plan.get('selectedScenarioCount') or 0}/{profile_run_plan.get('skippedFreshPassCount') or 0}/{len(profile_run.get('batches') or [])}`",
    f"- packageStatus: `{profile_package.get('status') or '-'}`",
    f"- packageFile: `{profile_package.get('fileName') or '-'}`",
    f"- docsAudit: `{docs_audit.get('status') or '-'}`",
    f"- docsGroups/errors: `{docs_audit.get('presetsGroupCount') or 0}/{docs_audit.get('listedGroupCount') or 0}/{docs_audit.get('errorCount') or 0}`",
    f"- productProfileGate: `{product_profile_gate.get('status') or '-'}`",
    f"- productProfileGateChecked/errors: `{product_profile_gate.get('profileCount') or 0}/{product_profile_gate.get('errorCount') or 0}`",
    f"- productProfileGateRequiredDomains: `{len(product_profile_gate.get('requiredDomains') or []) if product_profile_gate else '-'}`",
    f"- productCampaignAudit: `{product_campaign_audit.get('status') or '-'}`",
    f"- productCampaignAuditCampaigns/policies/errors: `{product_campaign_audit.get('campaignCount') if product_campaign_audit else '-'}/{len(product_campaign_audit.get('requiredPhasePolicies') or []) if product_campaign_audit else '-'}/{product_campaign_audit.get('errorCount') if product_campaign_audit else '-'}`",
    f"- inventoryDocs: `{validation_inventory_summary.get('docs') or 0}`",
    f"- profileArtifacts: `{', '.join(profile_artifacts) if profile_artifacts else '-'}`",
    f"- validationArtifacts: `{', '.join(validation_artifacts) if validation_artifacts else '-'}`",
    f"- productPlanStatus: `{product_run.get('finalStatus') or '-'}`",
    f"- productPlanBlockerType: `{product_run.get('blockerType') or '-'}`",
    f"- productPlanPhases: `{len(product_run.get('phases') or [])}`",
    f"- productPlanScenarioCount: `{product_preview_summary.get('uniqueScenarioCount') if product_preview_summary else '-'}`",
    f"- productPlanLargeGroupIncluded: `{product_preview_summary.get('largeGroupIncluded') if product_preview_summary else '-'}`",
    f"- productPlanDomainCount: `{len(product_preview_summary.get('coveredProductDomains') or []) if product_preview_summary else '-'}`",
    f"- productPlanRequiredDomainsCovered: `{product_preview_summary.get('requiredProductDomainsCovered') if product_preview_summary else '-'}`",
    f"- productPlanMissingDomains: `{', '.join(product_preview_summary.get('missingProductDomains') or []) if product_preview_summary else '-'}`",
    f"- productPrereqStatus: `{product_prereq_summary.get('overallStatus') or '-'}`",
    f"- productPrereqMissingRequired: `{product_prereq_summary.get('missingRequiredCount') if product_prereq_summary else '-'}`",
    f"- productArtifacts: `{', '.join(product_artifacts) if product_artifacts else '-'}`",
    f"- productCampaign: `{campaign_run.get('campaign') or '-'}`",
    f"- productCampaignStatus: `{campaign_run.get('finalStatus') or '-'}`",
    f"- productCampaignTarget: `{campaign_target_summary if campaign_run else '-'}`",
    f"- productCampaignFailures/required/attempted/skipped: `{campaign_run.get('failureCount') if campaign_run else '-'}/{campaign_run.get('requiredFailureCount') if campaign_run else '-'}/{campaign_run.get('attemptedStageCount') if campaign_run else '-'}/{campaign_run.get('skippedStageCount') if campaign_run else '-'}`",
    f"- productCampaignRequiredFailures: `{campaign_run.get('requiredFailureCount') if campaign_run else '-'}`",
    f"- productCampaignArtifacts: `{', '.join(campaign_artifacts) if campaign_artifacts else '-'}`",
    f"- productScenarioSuite: `{suite_run.get('suite') or '-'}`",
    f"- productScenarioSuiteStatus: `{suite_run.get('status') or '-'}`",
    f"- productScenarioSuiteScenarios: `{suite_coverage.get('uniqueScenarioCount') if suite_coverage else '-'}`",
    f"- productScenarioSuiteDomains: `{len(suite_coverage.get('coveredProductDomains') or []) if suite_coverage else '-'}`",
    f"- productScenarioSuiteLargeGroupIncluded: `{suite_coverage.get('largeGroupIncluded') if suite_coverage else '-'}`",
    f"- productScenarioSuiteArtifacts: `{', '.join(suite_artifacts) if suite_artifacts else '-'}`",
    f"- currentReadinessStatus: `{current_readiness.get('status') or '-'}`",
    f"- currentReadinessReason: `{current_readiness.get('reason') or '-'}`",
    f"- currentReadinessOperatorNetwork: `present={current_operator_network['present']} failed={current_operator_network['failed']} warnings={','.join(current_operator_network['warnings']) if current_operator_network['warnings'] else '-'}`",
    f"- currentReadinessRequestedSmoke/ProductSuite/Baseline/Full: `{current_requested.get('smoke') if current_readiness else '-'}/{current_requested.get('productScenarioSuite') if current_readiness else '-'}/{current_requested.get('baseline') if current_readiness else '-'}/{current_requested.get('fullAcceptance') if current_readiness else '-'}`",
    f"- currentReadinessExitCodesSmoke/ProductSuite/Baseline/Full: `{current_runs.get('smokeExitCode') if current_readiness else '-'}/{current_runs.get('suiteExitCode') if current_readiness else '-'}/{current_runs.get('baselineExitCode') if current_readiness else '-'}/{current_runs.get('fullAcceptanceExitCode') if current_readiness else '-'}`",
    f"- currentReadinessProductScenarioSuiteExpected: `{current_requested.get('productScenarioSuiteName') if current_readiness else '-'}`",
    f"- currentReadinessProductScenarioSuite: `{suite_run.get('suite') or '-'}`",
    f"- currentReadinessProductScenarioSuiteStatus: `{suite_run.get('status') or '-'}`",
    f"- currentReadinessProductScenarioSuiteScenarios: `{suite_coverage.get('uniqueScenarioCount') if suite_coverage else '-'}`",
    f"- currentReadinessProductScenarioSuiteLargeGroupIncluded: `{suite_coverage.get('largeGroupIncluded') if suite_coverage else '-'}`",
    f"- currentReadinessFullAcceptanceExpectedCampaign: `{current_requested.get('fullAcceptanceCampaign') if current_readiness else '-'}`",
    f"- currentReadinessFullAcceptanceCampaign: `{current_full_acceptance_run.get('campaign') or '-'}`",
    f"- currentReadinessFullAcceptanceStatus: `{current_full_acceptance_run.get('finalStatus') or '-'}`",
    f"- currentReadinessFullAcceptanceFailures/required/attempted/skipped: `{current_full_acceptance_run.get('failureCount') if current_full_acceptance_run else '-'}/{current_full_acceptance_run.get('requiredFailureCount') if current_full_acceptance_run else '-'}/{current_full_acceptance_run.get('attemptedStageCount') if current_full_acceptance_run else '-'}/{current_full_acceptance_run.get('skippedStageCount') if current_full_acceptance_run else '-'}`",
    f"- currentReadinessArtifacts: `{', '.join(current_readiness_artifacts) if current_readiness_artifacts else '-'}`",
    "",
    "Install on the target server:",
    "",
    "```bash",
    "sudo bash deploy/ubuntu/69_install_performance_evidence_package.sh \\",
    "  /tmp/production-evidence.tar.gz",
    "```",
    "",
    "Do not install only `production-gate.json`; use the full evidence package so",
    "the retained profile run, prereq audit, checksums, and scenario catalog are",
    "verified together.",
    "",
]
with open(output_path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines))
PY
}

package_evidence() {
  local gate_json="$1"
  local output_dir="$2"
  local package_path="$3"
  local stage_dir expect_base_url expect_tcp_host expect_tcp_port

  if [[ ! -f "${gate_json}" ]]; then
    printf 'production_evidence_package result=fail reason=missing_gate path=%s\n' "${gate_json}" >&2
    return 1
  fi

  expect_base_url="$(resolve_package_expect_base_url)"
  expect_tcp_host="$(resolve_package_expect_tcp_host)"
  expect_tcp_port="$(resolve_package_expect_tcp_port)"

  PERF_PRODUCTION_GATE_JSON="${gate_json}" \
  PERF_PRODUCTION_GATE_PROFILE="${PERF_PRODUCTION_GATE_PROFILE}" \
  PERF_PRODUCTION_GATE_MAX_AGE_SECONDS="${PERF_PRODUCTION_GATE_MAX_AGE_SECONDS}" \
  PERF_PRODUCTION_GATE_REQUIRE_CURRENT_GIT="${PERF_PRODUCTION_GATE_REQUIRE_CURRENT_GIT}" \
  PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT="${PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT}" \
  PERF_PRODUCTION_GATE_EXPECT_BASE_URL="${expect_base_url}" \
  PERF_PRODUCTION_GATE_EXPECT_TCP_HOST="${expect_tcp_host}" \
  PERF_PRODUCTION_GATE_EXPECT_TCP_PORT="${expect_tcp_port}" \
  PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET="${PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET}" \
  PERF_PRODUCTION_PROFILE_CATALOG="${PERF_PRODUCTION_PROFILE_CATALOG}" \
    bash "${REPO_ROOT}/deploy/ubuntu/67_verify_performance_gate.sh" >/dev/null

  mkdir -p "${output_dir}"
  if [[ -z "${package_path}" ]]; then
    package_path="${output_dir}/production-evidence-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
  fi
  ensure_validation_inventory "${gate_json}" || return 1
  ensure_docs_audit || return 1
  ensure_product_profile_gate || return 1
  ensure_product_campaign_audit || return 1
  ensure_profile_runbook || return 1
  ensure_product_plan_runbook || return 1
  stage_dir="$(mktemp -d "${output_dir}/production-evidence.XXXXXX")"
  trap 'rm -rf "${stage_dir:-}"' RETURN

  cp "${gate_json}" "${stage_dir}/production-gate.json"
  copy_if_present "${RESULT_ROOT}/production-gate.md" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/production-gate.csv" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/dashboard.md" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/dashboard.json" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/state-summary.md" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/state-summary.json" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/slo-status.md" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/slo-status.json" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/slo-domain-scorecard.md" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/slo-domain-scorecard.json" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/scenario-status.md" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/scenario-status.json" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/production-profile-run.json" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/production-profile-plan.json" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/production-profile-operator-network.log" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/production-profile-operator-network.json" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/production-profile-entrypoint-probe.log" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/production-profile-entrypoint-probe.json" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/production-profile-runbook.md" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/production-profile-runbook.json" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/production-profile-prereq-plan.json" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/production-profile-prereq-audit.md" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/production-profile-prereq-audit.json" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/production-profile-scenario-catalog.json" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/product-test-plan-run.json" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/product-test-plan-preview.json" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/product-test-plan-phases.tsv" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/product-test-prereq-plan.json" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/product-test-prereq-audit.md" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/product-test-prereq-audit.json" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/product-test-scenario-catalog.json" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/product-test-runbook.md" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/product-test-runbook.json" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/product-campaign-run.json" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/product-campaign-runbook.md" "${stage_dir}"
  materialize_product_campaign_stage_logs "${stage_dir}" "${RESULT_ROOT}"
  copy_if_present "${RESULT_ROOT}/product-scenario-suite-run.json" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/product-scenario-suite-run.md" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/product-scenario-suite-stages.tsv" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/current-production-readiness.json" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/current-production-readiness.md" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/current-production-dashboard.json" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/current-production-dashboard.md" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/current-production-state-summary.json" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/current-production-state-summary.md" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/current-production-state-summary.csv" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/current-production-prereq-summary.txt" "${stage_dir}"
  materialize_current_readiness_artifacts "${stage_dir}" "${RESULT_ROOT}"
  copy_if_present "${RESULT_ROOT}/docs-audit.json" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/docs-audit.md" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/docs-audit.csv" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/product-profile-gate.json" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/product-profile-gate.md" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/product-profile-gate.csv" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/product-campaign-audit.json" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/product-campaign-audit.md" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/product-campaign-audit.csv" "${stage_dir}"
  cp "${PERF_PRODUCTION_PROFILE_CATALOG}" "${stage_dir}/perf_production_profiles.json"
  cp "${SCRIPT_DIR}/perf_product_campaigns.json" "${stage_dir}/perf_product_campaigns.json"
  copy_if_present "${RESULT_ROOT}/validation-inventory.json" "${stage_dir}"
  copy_if_present "${RESULT_ROOT}/validation-inventory.md" "${stage_dir}"
  stage_cloud_security_group_snapshot "${stage_dir}" || return 1
  stage_cloud_security_group_repair_receipt "${stage_dir}" || return 1
  relink_current_readiness_cloud_security_group_repair_receipt "${stage_dir}"
  refresh_current_readiness_markdown "${stage_dir}"
  enrich_profile_run_receipt "${stage_dir}" "${package_path}"
  write_summary "${stage_dir}/README.md" "${gate_json}" "${stage_dir}"
  scan_stage_for_secrets "${stage_dir}" || return 1
  PRODUCTION_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS="${PRODUCTION_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS}" \
  PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS="${PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS}" \
  PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS="${PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS}" \
  PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS="${PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS}" \
  PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP="${PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP}" \
  PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS="${PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS}" \
  PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP="${PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE}" \
  PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT="${PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE}" \
  PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080}" \
  PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS}" \
  PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER}" \
  PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID}" \
  PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID}" \
  PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR="${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR}" \
    python3 "${SCRIPT_DIR}/perf_evidence_manifest.py" --dir "${stage_dir}" --write >/dev/null
  python3 "${SCRIPT_DIR}/perf_evidence_manifest.py" --dir "${stage_dir}" --verify >/dev/null
  if bool_enabled "${PRODUCTION_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS}"; then
    verify_profile_artifacts "${stage_dir}" "${package_path}" || return 1
  fi
  verify_product_plan_artifacts "${stage_dir}" || return 1
  verify_product_campaign_artifacts "${stage_dir}" || return 1
  verify_product_scenario_suite_artifacts "${stage_dir}" || return 1

  write_sha256sums "${stage_dir}"

  tar -C "${stage_dir}" -czf "${package_path}" .
  chmod 0644 "${package_path}"
  if [[ -f "${stage_dir}/production-profile-run.json" && -f "${RESULT_ROOT}/production-profile-run.json" ]]; then
    cp "${stage_dir}/production-profile-run.json" "${RESULT_ROOT}/production-profile-run.json"
  fi

  printf 'production_evidence_package result=pass gate=%s package=%s profile=%s\n' \
    "${gate_json}" \
    "${package_path}" \
    "${PERF_PRODUCTION_GATE_PROFILE}"
}

if bool_enabled "${PRODUCTION_EVIDENCE_SELF_TEST}"; then
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' EXIT
  PERF_PRODUCTION_PROFILE_CATALOG="${PERF_PRODUCTION_PROFILE_CATALOG}" \
  python3 - "${tmp_dir}/production-gate.json" "${PERF_PRODUCTION_PROFILE_CATALOG}" <<'PY'
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
  printf '{"profile":"minimum-smoke","profileScenarioCount":%s,"selectedScenarioCount":1,"skippedFreshPassCount":%s,"batchSize":1,"batchCount":1,"batches":[{"index":1,"scenarios":["login-smoke"]}]}\n' "${self_test_profile_count}" "${self_test_skipped_count}" >"${tmp_dir}/production-profile-plan.json"
  printf '{"schemaVersion":1,"profile":"minimum-smoke","finalStatus":"PASS","dryRun":false,"packageEnabled":false,"statusFilterTarget":true,"operatorNetworkPreflight":true,"operatorNetworkArtifacts":{"log":"%s/production-profile-operator-network.log","json":"%s/production-profile-operator-network.json"},"entrypointProbe":true,"entrypointProbeArtifacts":{"log":"%s/production-profile-entrypoint-probe.log","json":"%s/production-profile-entrypoint-probe.json"},"plan":{"profile":"minimum-smoke","profileScenarioCount":%s,"selectedScenarioCount":1,"skippedFreshPassCount":%s},"batches":[{"index":1,"runID":"self-test","status":"PASS","scenarios":["login-smoke"]}]}\n' "${tmp_dir}" "${tmp_dir}" "${tmp_dir}" "${tmp_dir}" "${self_test_profile_count}" "${self_test_skipped_count}" >"${tmp_dir}/production-profile-run.json"
  printf 'operator-network result=pass targets=2\n' >"${tmp_dir}/production-profile-operator-network.log"
  printf '{"schemaVersion":1,"status":"pass","failed":false,"failureCount":0,"targetCount":2,"warnings":[],"warningCounts":{},"routeInterfaces":["en0"],"routeGateways":["192.168.1.1"],"failedTargets":[],"targets":[],"action":""}\n' >"${tmp_dir}/production-profile-operator-network.json"
  printf 'diagnosis=ok\n' >"${tmp_dir}/production-profile-entrypoint-probe.log"
  printf '{"schemaVersion":1,"diagnosis":"ok","failed":false,"baseURL":"https://chat.myim-prod.com","tcpStatus":"open","edgeIntercept":"","portProtocols":[{"label":"base-https:chat.myim-prod.com","port":"443","protocol":"tls_or_http"}]}\n' >"${tmp_dir}/production-profile-entrypoint-probe.json"
  printf '{"status":"READY","profile":"minimum-smoke","selectedScenarios":["login-smoke"]}\n' >"${tmp_dir}/production-profile-prereq-plan.json"
  printf '# Self-test prereq audit\n' >"${tmp_dir}/production-profile-prereq-audit.md"
  printf '{"summary":{"overallStatus":"READY"},"scenarios":[{"scenario":"login-smoke","status":"READY"}]}\n' >"${tmp_dir}/production-profile-prereq-audit.json"
  printf '{"summary":{"scenarioCount":1},"scenarios":[{"scenario":"login-smoke"}]}\n' >"${tmp_dir}/production-profile-scenario-catalog.json"
  cat >"${tmp_dir}/product-test-prereq-plan.json" <<'EOF'
{"schemaVersion":1,"status":"NO_SCENARIOS","plan":"self-test","requestedPhases":["entrypoint"],"selectedScenarios":[]}
EOF
  printf '# Product self-test prereq audit\n' >"${tmp_dir}/product-test-prereq-audit.md"
  cat >"${tmp_dir}/product-test-prereq-audit.json" <<'EOF'
{"summary":{"overallStatus":"READY","scenarioCount":0,"accountRows":1,"missingRequiredCount":0,"missingRecommendedCount":0},"scenarios":[]}
EOF
  printf '{"summary":{"scenarioCount":0},"scenarios":[]}\n' >"${tmp_dir}/product-test-scenario-catalog.json"
  cat >"${tmp_dir}/product-test-plan-preview.json" <<EOF
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
    {
      "phase": "entrypoint",
      "kind": "entrypoint",
      "groups": [],
      "runner": "http_entrypoint_probe.sh",
      "scenarioCount": 0,
      "firstScenario": "",
      "sampleScenarios": [],
      "scenarios": []
    }
  ]
}
EOF
  cat >"${tmp_dir}/product-test-plan-run.json" <<EOF
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
    "plan": "${tmp_dir}/product-test-prereq-plan.json",
    "auditJSON": "${tmp_dir}/product-test-prereq-audit.json",
    "auditMarkdown": "${tmp_dir}/product-test-prereq-audit.md"
  },
  "planPreview": {
    "json": "${tmp_dir}/product-test-plan-preview.json",
    "exists": true
  },
  "runbook": {
    "json": "${tmp_dir}/product-test-runbook.json",
    "markdown": "${tmp_dir}/product-test-runbook.md"
  },
  "phases": [
    {
      "phase": "entrypoint",
      "kind": "entrypoint-probe",
      "runID": "product-self-test-entrypoint",
      "status": "PASS",
      "reason": "",
      "command": "BASE_URL=https://chat.myim-prod.com ./http_entrypoint_probe.sh",
      "runDir": "${tmp_dir}/product-self-test-entrypoint"
    },
    {
      "phase": "full-profile",
      "kind": "production-profile",
      "runID": "product-self-test-profile-normal-product-baseline",
      "status": "SKIPPED",
      "reason": "disabled",
      "command": "PERF_PRODUCTION_GATE_PROFILE=normal-product-baseline ./run_production_profile.sh",
      "runDir": "${tmp_dir}/product-self-test-profile-normal-product-baseline"
    }
  ]
}
EOF
  {
    printf 'entrypoint\tentrypoint-probe\tproduct-self-test-entrypoint\tPASS\t\tBASE_URL=https://chat.myim-prod.com ./http_entrypoint_probe.sh\n'
    printf 'full-profile\tproduction-profile\tproduct-self-test-profile-normal-product-baseline\tSKIPPED\tdisabled\tPERF_PRODUCTION_GATE_PROFILE=normal-product-baseline ./run_production_profile.sh\n'
  } >"${tmp_dir}/product-test-plan-phases.tsv"
  python3 - "${tmp_dir}" <<'PY'
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
preview_rows = [{
    "phase": "entrypoint",
    "kind": "entrypoint",
    "groups": [],
    "runner": "http_entrypoint_probe.sh",
    "scenarioCount": 0,
    "firstScenario": "",
    "sampleScenarios": [],
    "scenarios": [],
}]
run_rows = [{
    "phase": "entrypoint",
    "kind": "entrypoint-probe",
    "runID": "product-self-test-entrypoint",
    "status": "PASS",
    "reason": "",
    "command": "BASE_URL=https://chat.myim-prod.com ./http_entrypoint_probe.sh",
    "runDir": str(root / "product-self-test-entrypoint"),
}]
tsv_rows = ["entrypoint\tentrypoint-probe\tproduct-self-test-entrypoint\tPASS\t\tBASE_URL=https://chat.myim-prod.com ./http_entrypoint_probe.sh"]
for phase in domains:
    scenarios = phase_scenarios[phase]
    preview_rows.append({
        "phase": phase,
        "kind": "scenario-groups",
        "groups": [phase],
        "runner": "run_perf_scenarios.sh",
        "scenarioCount": len(scenarios),
        "firstScenario": scenarios[0],
        "sampleScenarios": scenarios,
        "scenarios": scenarios,
    })
    command = f"SCENARIO_GROUPS={phase} ./run_perf_scenarios.sh"
    run_rows.append({
        "phase": phase,
        "kind": "scenario-groups",
        "runID": f"product-self-test-{phase}",
        "status": "PASS",
        "reason": "",
        "command": command,
        "runDir": str(root / f"product-self-test-{phase}"),
    })
    tsv_rows.append(f"{phase}\tscenario-groups\tproduct-self-test-{phase}\tPASS\t\t{command}")
run_rows.append({
    "phase": "full-profile",
    "kind": "production-profile",
    "runID": "product-self-test-profile-normal-product-baseline",
    "status": "SKIPPED",
    "reason": "disabled",
    "command": "PERF_PRODUCTION_GATE_PROFILE=normal-product-baseline ./run_production_profile.sh",
    "runDir": str(root / "product-self-test-profile-normal-product-baseline"),
})
tsv_rows.append("full-profile\tproduction-profile\tproduct-self-test-profile-normal-product-baseline\tSKIPPED\tdisabled\tPERF_PRODUCTION_GATE_PROFILE=normal-product-baseline ./run_production_profile.sh")
(root / "product-test-plan-preview.json").write_text(json.dumps({
    "schemaVersion": 1,
    "plan": "self-test",
    "preset": "",
    "requestedPhases": phases,
    "fullProfile": "normal-product-baseline",
    "runFullProfile": False,
    "packageEvidence": True,
    "requireEntrypoint": True,
    "prereqGate": True,
    "dryRun": False,
    "statusFilterTarget": True,
    "target": target,
    "summary": {
        "phaseCount": len(preview_rows),
        "scenarioPhaseCount": len(domains),
        "uniqueScenarioCount": len(selected),
        "largeGroupIncluded": False,
        "coveredProductDomains": domains,
        "requiredProductDomains": domains,
        "missingProductDomains": [],
        "requiredProductDomainsCovered": True,
    },
    "selectedScenarios": selected,
    "phases": preview_rows,
}, indent=2, sort_keys=True), encoding="utf-8")
run_payload = json.loads((root / "product-test-plan-run.json").read_text(encoding="utf-8"))
run_payload["requestedPhases"] = phases
run_payload["target"] = target
run_payload["phases"] = run_rows
(root / "product-test-plan-run.json").write_text(json.dumps(run_payload, indent=2, sort_keys=True), encoding="utf-8")
(root / "product-test-plan-phases.tsv").write_text("\n".join(tsv_rows) + "\n", encoding="utf-8")
(root / "product-test-prereq-plan.json").write_text(json.dumps({
    "schemaVersion": 1,
    "status": "READY",
    "plan": "self-test",
    "requestedPhases": phases,
    "selectedScenarios": selected,
}, indent=2, sort_keys=True), encoding="utf-8")
(root / "product-test-prereq-audit.json").write_text(json.dumps({
    "summary": {
        "overallStatus": "READY",
        "scenarioCount": len(selected),
        "accountRows": 1000,
        "missingRequiredCount": 0,
        "missingRecommendedCount": 0,
    },
    "scenarios": [{"scenario": item, "status": "READY"} for item in selected],
}, indent=2, sort_keys=True), encoding="utf-8")
(root / "product-test-scenario-catalog.json").write_text(json.dumps({
    "summary": {"scenarioCount": len(selected)},
    "scenarios": [{"scenario": item} for item in selected],
}, indent=2, sort_keys=True), encoding="utf-8")
PY
  python3 "${SCRIPT_DIR}/perf_product_test_plan_runbook.py" \
    --product-run-json "${tmp_dir}/product-test-plan-run.json" \
    --prereq-audit-json "${tmp_dir}/product-test-prereq-audit.json" \
    --result-root "${tmp_dir}" \
    --output "${tmp_dir}/product-test-runbook.md" \
    --json-output "${tmp_dir}/product-test-runbook.json" >/dev/null
  python3 "${SCRIPT_DIR}/perf_product_test_plan_runbook.py" \
    --verify-json "${tmp_dir}/product-test-runbook.json" \
    --verify-md "${tmp_dir}/product-test-runbook.md" >/dev/null
  cp "${tmp_dir}/product-test-runbook.md" "${tmp_dir}/product-test-runbook-bad.md"
  perl -0pi -e 's/- status: `READY`/- runbookStatus: `READY`/' "${tmp_dir}/product-test-runbook-bad.md"
  if python3 "${SCRIPT_DIR}/perf_product_test_plan_runbook.py" \
    --verify-json "${tmp_dir}/product-test-runbook.json" \
    --verify-md "${tmp_dir}/product-test-runbook-bad.md" \
    >"${tmp_dir}/bad-product-runbook-md.log" 2>&1; then
    printf 'production_evidence_package_self_test result=fail reason=bad_product_runbook_md_passed\n' >&2
    exit 1
  fi
  grep -q 'markdown_mismatch' "${tmp_dir}/bad-product-runbook-md.log" || {
    printf 'production_evidence_package_self_test result=fail reason=bad_product_runbook_md_reason_missing\n' >&2
    exit 1
  }
  mkdir -p "${tmp_dir}/campaign-stage-entrypoint" "${tmp_dir}/campaign-stage-profile"
  printf 'stage pass\n' >"${tmp_dir}/campaign-stage-entrypoint/stage.log"
  printf 'stage pass\n' >"${tmp_dir}/campaign-stage-profile/stage.log"
  cat >"${tmp_dir}/product-campaign-run.json" <<EOF
{
  "schemaVersion": 1,
  "campaign": "non-large-group-release",
  "description": "self-test campaign",
  "campaignCatalog": "${SCRIPT_DIR}/perf_product_campaigns.json",
  "execute": true,
  "stopOnFailure": true,
  "resultDir": "${tmp_dir}",
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
      "runDir": "${tmp_dir}/campaign-stage-entrypoint",
      "log": "${tmp_dir}/campaign-stage-entrypoint/stage.log",
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
      "runDir": "${tmp_dir}/campaign-stage-profile",
      "log": "${tmp_dir}/campaign-stage-profile/stage.log",
      "command": "env PERF_PRODUCTION_GATE_PROFILE=normal-product-baseline IM_INTERNAL_SECRET=<redacted> ./run_production_profile.sh",
      "evidence": "profile self-test"
    }
  ],
  "evidenceRoot": {
    "enabled": true,
    "profileSourceDir": "${tmp_dir}/campaign-stage-profile",
    "productPlanSourceDir": "${tmp_dir}/campaign-stage-entrypoint",
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
  python3 - "${tmp_dir}/product-campaign-run.json" "${tmp_dir}" "${tmp_dir}/product-campaign-runbook.md" "${SCRIPT_DIR}" <<'PY'
import json
import sys
from pathlib import Path

path, root, runbook_path, script_dir = sys.argv[1:5]
sys.path.insert(0, str(Path(script_dir)))
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
  cat >"${tmp_dir}/entrypoint-probe.json" <<'EOF'
{"schemaVersion":1,"failed":false,"diagnosis":"ok","detail":"self-test ok","blocker":{"preventsPerformanceEvidence":false}}
EOF
  printf 'operator-network target=https://chat.myim-prod.com host=chat.myim-prod.com status=pass warning=clean routeInterface=en0 routeGateway=192.168.1.1 proxyEnv=<none>\noperator-network result=pass targets=2\n' \
    >"${tmp_dir}/operator-network.log"
  cat >"${tmp_dir}/operator-network.json" <<'EOF'
{
  "schemaVersion": 1,
  "status": "pass",
  "failed": false,
  "failureCount": 0,
  "targetCount": 1,
  "warnings": [],
  "warningCounts": {},
  "routeInterfaces": ["en0"],
  "routeGateways": ["192.168.1.1"],
  "failedTargets": [],
  "targets": [
    {"target": "https://chat.myim-prod.com", "host": "chat.myim-prod.com", "status": "pass", "warning": "clean", "routeInterface": "en0", "routeGateway": "192.168.1.1", "proxyEnv": "<none>"}
  ],
  "action": ""
}
EOF
  printf 'entrypoint pass\n' >"${tmp_dir}/entrypoint-probe.log"
  cat >"${tmp_dir}/current-production-dashboard.json" <<'EOF'
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
  printf '# Current Production Dashboard\n' >"${tmp_dir}/current-production-dashboard.md"
  cat >"${tmp_dir}/current-production-state-summary.json" <<'EOF'
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
  printf '# Current Production State Summary\n' >"${tmp_dir}/current-production-state-summary.md"
  cat >"${tmp_dir}/current-production-state-summary.csv" <<'EOF'
recordType,conclusion,readinessGate,currentReadinessStatus,currentReadinessReason,currentReadinessRequestedSmoke,currentReadinessRequestedProductScenarioSuite,currentReadinessRequestedBaseline,currentReadinessRequestedFullAcceptance,currentReadinessSmokeExitCode,currentReadinessProductScenarioSuiteExitCode,currentReadinessBaselineExitCode,currentReadinessFullAcceptanceExitCode,currentReadinessProductScenarioSuiteExpected,currentReadinessProductScenarioSuite,currentReadinessProductScenarioSuiteStatus,currentReadinessProductScenarioSuiteStageCount,currentReadinessProductScenarioSuiteFailedStages,currentReadinessProductScenarioSuitePlannedStages,currentReadinessProductScenarioSuiteScenarios,currentReadinessProductScenarioSuiteProductPlanStages,currentReadinessProductScenarioSuiteLargeGroupIncluded,currentReadinessFullAcceptanceExpectedCampaign,currentReadinessFullAcceptanceCampaign,currentReadinessFullAcceptanceStatus,currentReadinessFullAcceptanceFailures,currentReadinessFullAcceptanceRequiredFailures,currentReadinessFullAcceptanceAttempted,currentReadinessFullAcceptanceSkipped,currentReadinessOperatorNetworkPreflight,currentReadinessOperatorNetworkLogPresent,currentReadinessOperatorNetworkFailed,currentReadinessOperatorNetworkWarnings,currentReadinessOperatorNetworkRouteInterfaces,currentReadinessOperatorNetworkRouteGateways,currentReadinessOperatorNetworkFailureCount,domain
summary,READY,,PASS,entrypoint_and_requested_runs_passed,True,True,True,True,0,0,0,0,recommended,recommended,PASS,1,0,0,8,1,False,production-full-acceptance,production-full-acceptance,PASS,0,0,6,0,True,True,False,,en0,192.168.1.1,0,
EOF
  printf 'smoke pass\n' >"${tmp_dir}/normal-product-smoke.log"
  printf 'product scenario suite pass\n' >"${tmp_dir}/product-scenario-suite.log"
  printf 'baseline pass\n' >"${tmp_dir}/normal-product-baseline.log"
  printf 'full acceptance pass\n' >"${tmp_dir}/production-full-acceptance.log"
  python3 - "${tmp_dir}" "${tmp_dir}/production-full-acceptance-run.json" "${tmp_dir}/production-full-acceptance-runbook.md" "${SCRIPT_DIR}" <<'PY'
import json
import sys
from pathlib import Path

root, json_path, runbook_path, script_dir = map(Path, sys.argv[1:5])
sys.path.insert(0, str(script_dir))
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
    "description": "production evidence package self-test",
    "campaignCatalog": str(script_dir / "perf_product_campaigns.json"),
    "execute": True,
    "stopOnFailure": True,
    "resultDir": str(root),
    "runIDPrefix": "production-evidence-package-self-test",
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
  cat >"${tmp_dir}/current-production-readiness.json" <<EOF
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
	    "requireCloudSecurityGroup": false,
	    "requirePublicPortPolicy": false,
	    "allowTempHTTP8080": false,
	    "cloudSecurityGroupRulesMaxAgeSeconds": 86400,
	    "cloudSecurityGroupRulesRequireRootOwner": true,
	    "cloudSecurityGroupRulesFile": "",
    "requireCloudSecurityGroupRepairReceipt": false,
    "cloudSecurityGroupRepairReceiptJSON": "",
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
    "probeJSON": "${tmp_dir}/entrypoint-probe.json",
    "failed": false,
    "diagnosis": "ok",
    "detail": "self-test ok",
    "blocker": {"preventsPerformanceEvidence": false}
  },
  "artifacts": {
    "runDir": "${tmp_dir}",
    "rescueSummary": "${tmp_dir}/entrypoint-summary.txt",
    "operatorNetworkLog": "${tmp_dir}/operator-network.log",
    "operatorNetworkJSON": "${tmp_dir}/operator-network.json",
    "entrypointProbeLog": "${tmp_dir}/entrypoint-probe.log",
    "dashboard": "${tmp_dir}/current-production-dashboard.md",
    "stateSummary": "${tmp_dir}/current-production-state-summary.md",
    "smokeLog": "${tmp_dir}/normal-product-smoke.log",
    "productScenarioSuiteLog": "${tmp_dir}/product-scenario-suite.log",
    "productScenarioSuiteRunJSON": "${tmp_dir}/product-scenario-suite-run.json",
    "productScenarioSuiteRunMarkdown": "${tmp_dir}/product-scenario-suite-run.md",
    "productScenarioSuiteStagesTSV": "${tmp_dir}/product-scenario-suite-stages.tsv",
    "baselineLog": "${tmp_dir}/normal-product-baseline.log",
    "fullAcceptanceLog": "${tmp_dir}/production-full-acceptance.log",
    "fullAcceptanceRunJSON": "${tmp_dir}/production-full-acceptance-run.json",
    "fullAcceptanceRunbook": "${tmp_dir}/production-full-acceptance-runbook.md"
  },
  "runs": {
    "smokeExitCode": 0,
    "suiteExitCode": 0,
    "baselineExitCode": 0,
    "fullAcceptanceExitCode": 0
  }
}
EOF
  python3 - "${tmp_dir}/current-production-readiness.json" "${tmp_dir}/current-production-readiness.md" "${SCRIPT_DIR}" <<'PY'
import json
import sys
from pathlib import Path

json_path, md_path, script_dir = map(Path, sys.argv[1:4])
sys.path.insert(0, str(script_dir))
from perf_current_production_readiness_verify import build_readiness_markdown

payload = json.loads(json_path.read_text(encoding="utf-8"))
md_path.write_text(build_readiness_markdown(payload), encoding="utf-8")
PY
  cat >"${tmp_dir}/product-scenario-suite-run.json" <<'EOF'
{
  "schemaVersion": 1,
  "suite": "recommended",
  "runIDPrefix": "self-test-suite",
  "status": "PASS",
  "reason": "all_stages_passed",
  "startedAt": "2026-06-19T00:00:00Z",
  "endedAt": "2026-06-19T00:00:01Z",
  "target": {
    "baseURL": "https://chat.myim-prod.com",
    "tcpHost": "tcp.myim-prod.com",
    "tcpPort": "9000",
    "accountFile": "/tmp/self-test-accounts.csv",
    "conversationIDPresent": true
  },
  "settings": {
    "dryRun": false,
    "execute": true,
    "stopOnFailure": true,
    "includeLargeGroup": false
  },
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
    "requiredProductDomainsCovered": true,
    "sampleScenarios": ["login-smoke", "client-sync-mix-smoke", "direct-message-lifecycle-smoke"]
  },
  "failureSummary": [],
  "stageCoverage": [
    {
      "stage": "normal-smoke",
      "runner": "product-plan",
      "value": "normal-smoke",
      "coverageStatus": "READY",
      "phaseCount": 3,
      "uniqueScenarioCount": 8,
      "largeGroupIncluded": false,
      "coveredProductDomains": ["account-security", "sync-read", "direct-chat", "group-workflow", "contacts-social", "media-ai-admin", "reliability-recovery", "realtime-direct"],
      "requiredProductDomains": ["account-security", "sync-read", "direct-chat", "group-workflow", "contacts-social", "media-ai-admin", "reliability-recovery", "realtime-direct"],
      "missingProductDomains": [],
      "requiredProductDomainsCovered": true,
      "selectedScenarios": ["login-smoke", "client-sync-mix-smoke", "direct-message-lifecycle-smoke"],
      "sampleScenarios": ["login-smoke", "client-sync-mix-smoke", "direct-message-lifecycle-smoke"]
    }
  ],
  "stages": [
    {
      "id": "normal-smoke",
      "runner": "product-plan",
      "value": "normal-smoke",
      "description": "Fast cross-product smoke excluding large-group fanout.",
      "runDir": ".",
      "status": "PASS",
      "exitCode": 0
    }
  ],
  "artifacts": {
    "json": "product-scenario-suite-run.json",
    "markdown": "product-scenario-suite-run.md"
  }
}
EOF
  cat >"${tmp_dir}/product-scenario-suite-run.md" <<'EOF'
# Product Scenario Suite Run

- suite: `recommended`
- status: `PASS`
- reason: `all_stages_passed`

## Coverage

| Stage | Runner | Coverage | Scenarios | Domains | Missing Domains | Large Group |
| --- | --- | --- | --- | --- | --- | --- |
| `normal-smoke` | `product-plan` | `READY` | `8` | `account-security,sync-read,direct-chat,group-workflow,contacts-social,media-ai-admin,reliability-recovery,realtime-direct` | `-` | `False` |

## Stages

| Stage | Runner | Value | Status | Exit | Run Dir |
| --- | --- | --- | --- | --- | --- |
| `normal-smoke` | `product-plan` | `normal-smoke` | `PASS` | `0` | `.` |
EOF
  cat >"${tmp_dir}/product-scenario-suite-stages.tsv" <<'EOF'
normal-smoke	product-plan	normal-smoke	Fast cross-product smoke excluding large-group fanout.	.	PASS	0
EOF
  printf '{"schemaVersion":1,"summary":{"shell":1,"python":1,"k6":1},"source":{"gitCommit":"self-test","gitDirty":false},"tools":{"k6":{"inspectStatus":"pass"}},"groups":{"shell":[],"python":[],"k6":[]}}\n' >"${tmp_dir}/validation-inventory.json"
  printf '# Validation Inventory\n\n- shellScripts: `1`\n- pythonScripts: `1`\n- k6Scripts: `1`\n' >"${tmp_dir}/validation-inventory.md"
  RESULT_ROOT="${tmp_dir}"
  PERF_PRODUCTION_GATE_JSON="${tmp_dir}/production-gate.json"
  PERF_PRODUCTION_GATE_PROFILE="minimum-smoke"
  PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=0
  PUBLIC_BASE_URL=https://chat.myim-prod.com
  TCP_HOST=tcp.myim-prod.com
  TCP_PORT=9000
  PERF_PRODUCTION_GATE_EXPECT_BASE_URL=
  PERF_PRODUCTION_GATE_EXPECT_TCP_HOST=
  PERF_PRODUCTION_GATE_EXPECT_TCP_PORT=
  PRODUCTION_EVIDENCE_OUTPUT_DIR="${tmp_dir}/out"
  PRODUCTION_EVIDENCE_PACKAGE="${tmp_dir}/out/evidence.tar.gz"
  PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS=true
  PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS=true
  PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP=true
  IM_INTERNAL_SECRET="production-evidence-self-test-secret-012345"
	  package_evidence "${tmp_dir}/production-gate.json" "${tmp_dir}/out" "${tmp_dir}/out/evidence.tar.gz" >/dev/null
	  [[ -f "${tmp_dir}/out/evidence.tar.gz" ]] || {
	    printf 'production_evidence_package_self_test result=fail reason=package_missing\n' >&2
	    exit 1
	  }
	  python3 - "${tmp_dir}/production-gate.json" "${tmp_dir}/loopback-production-gate.json" <<'PY'
import json
import sys

source_path, target_path = sys.argv[1:3]
with open(source_path, encoding="utf-8") as handle:
    payload = json.load(handle)
payload["targetFilter"] = {
    "enabled": True,
    "baseURL": "http://127.0.0.1:8080",
    "tcpHost": "127.0.0.1",
    "tcpPort": "9000",
}
with open(target_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
	  PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET=true
	  PERF_PRODUCTION_GATE_EXPECT_BASE_URL=http://127.0.0.1:8080
	  PERF_PRODUCTION_GATE_EXPECT_TCP_HOST=127.0.0.1
	  PERF_PRODUCTION_GATE_EXPECT_TCP_PORT=9000
	  if package_evidence "${tmp_dir}/loopback-production-gate.json" "${tmp_dir}/production-target-loopback-out" "${tmp_dir}/production-target-loopback-out/evidence.tar.gz" \
	    >"${tmp_dir}/production-target-loopback.log" 2>&1; then
	    printf 'production_evidence_package_self_test result=fail reason=production_target_loopback_packaged\n' >&2
	    exit 1
	  fi
	  grep -q 'reason=production_target_base_url_https_required' "${tmp_dir}/production-target-loopback.log" || {
	    printf 'production_evidence_package_self_test result=fail reason=production_target_loopback_reason_missing\n' >&2
	    exit 1
	  }
	  PERF_PRODUCTION_GATE_EXPECT_BASE_URL=
	  PERF_PRODUCTION_GATE_EXPECT_TCP_HOST=
	  PERF_PRODUCTION_GATE_EXPECT_TCP_PORT=
	  PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET=true
	  PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP=
	  PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE="$(resolve_package_require_cloud_security_group)"
	  if package_evidence "${tmp_dir}/production-gate.json" "${tmp_dir}/production-target-missing-cloud-sg-out" "${tmp_dir}/production-target-missing-cloud-sg-out/evidence.tar.gz" \
	    >"${tmp_dir}/production-target-missing-cloud-sg.log" 2>&1; then
	    printf 'production_evidence_package_self_test result=fail reason=production_target_missing_cloud_security_group_packaged\n' >&2
	    exit 1
	  fi
	  grep -q 'reason=cloud_security_group_snapshot_required' "${tmp_dir}/production-target-missing-cloud-sg.log" || {
	    printf 'production_evidence_package_self_test result=fail reason=production_target_missing_cloud_security_group_reason_missing\n' >&2
	    exit 1
	  }
	  cat >"${tmp_dir}/cloud-security-group.json" <<'JSON'
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
	  PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_FILE="${tmp_dir}/cloud-security-group.json"
	  PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON=
	  if package_evidence "${tmp_dir}/production-gate.json" "${tmp_dir}/production-target-missing-cloud-sg-receipt-out" "${tmp_dir}/production-target-missing-cloud-sg-receipt-out/evidence.tar.gz" \
	    >"${tmp_dir}/production-target-missing-cloud-sg-receipt.log" 2>&1; then
	    printf 'production_evidence_package_self_test result=fail reason=production_target_missing_cloud_security_group_receipt_packaged\n' >&2
	    exit 1
	  fi
	  grep -q 'reason=cloud_security_group_repair_receipt_required' "${tmp_dir}/production-target-missing-cloud-sg-receipt.log" || {
	    printf 'production_evidence_package_self_test result=fail reason=production_target_missing_cloud_security_group_receipt_reason_missing\n' >&2
	    exit 1
	  }
	  python3 - "${tmp_dir}/cloud-security-group.json" "${tmp_dir}/cloud-security-group-repair-plan.json" "${tmp_dir}/cloud-security-group-post-apply.json" "${tmp_dir}/cloud-security-group-repair-receipt.json" <<'PY'
import hashlib
import json
import sys
import time
from pathlib import Path

snapshot_path, plan_path, post_apply_path, receipt_path = map(Path, sys.argv[1:5])
post_apply_path.write_text(snapshot_path.read_text(encoding="utf-8"), encoding="utf-8")
plan = {
    "schemaVersion": 1,
    "securityGroupId": "sg-package-selftest",
    "snapshot": str(snapshot_path.resolve()),
    "adminCidr": "203.0.113.10/32",
    "publicClientPorts": [80, 443, 9000],
    "adminPorts": [22],
    "denyPublicPorts": [22, 3389, 5432, 6379, 8080, 8081, 8082, 9092, 18080],
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
    "securityGroupId": "sg-package-selftest",
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
	  PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${tmp_dir}/cloud-security-group-repair-receipt.json"
	  PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=
	  PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=
	  PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=
	  if package_evidence "${tmp_dir}/production-gate.json" "${tmp_dir}/production-target-missing-cloud-sg-binding-out" "${tmp_dir}/production-target-missing-cloud-sg-binding-out/evidence.tar.gz" \
	    >"${tmp_dir}/production-target-missing-cloud-sg-binding.log" 2>&1; then
	    printf 'production_evidence_package_self_test result=fail reason=production_target_missing_cloud_security_group_binding_packaged\n' >&2
	    exit 1
	  fi
	  grep -q 'reason=cloud_security_group_repair_receipt_expected_security_group_id_required' "${tmp_dir}/production-target-missing-cloud-sg-binding.log" || {
	    printf 'production_evidence_package_self_test result=fail reason=production_target_missing_cloud_security_group_binding_reason_missing\n' >&2
	    exit 1
	  }
	  PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=sg-package-selftest
	  PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=cn-shenzhen
	  PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=203.0.113.10/32
	  package_evidence "${tmp_dir}/production-gate.json" "${tmp_dir}/production-target-cloud-sg-out" "${tmp_dir}/production-target-cloud-sg-out/evidence.tar.gz" \
	    >"${tmp_dir}/production-target-cloud-sg.log" 2>&1
	  for cloud_sg_artifact in \
	    './cloud-security-group.json' \
	    './cloud-security-group-repair-receipt.json' \
	    './cloud-security-group-repair-plan.json' \
	    './cloud-security-group-repair-snapshot.json' \
	    './cloud-security-group-repair-post-apply-snapshot.json'; do
	    tar -tzf "${tmp_dir}/production-target-cloud-sg-out/evidence.tar.gz" | grep -q "${cloud_sg_artifact}" || {
	      printf 'production_evidence_package_self_test result=fail reason=cloud_security_group_artifact_missing artifact=%s\n' "${cloud_sg_artifact}" >&2
	      exit 1
	    }
	  done
	  tar -xOzf "${tmp_dir}/production-target-cloud-sg-out/evidence.tar.gz" ./production-evidence-manifest.json >"${tmp_dir}/packaged-cloud-sg-manifest.json"
	  python3 - "${tmp_dir}/packaged-cloud-sg-manifest.json" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
policy = manifest.get("policy") or {}
if policy.get("requireCloudSecurityGroup") is not True:
    raise SystemExit("production_evidence_package_self_test result=fail reason=cloud_security_group_policy_missing")
if policy.get("requireCloudSecurityGroupRepairReceipt") is not True:
    raise SystemExit("production_evidence_package_self_test result=fail reason=cloud_security_group_repair_receipt_policy_missing")
expected = {
    "cloudSecurityGroupRepairReceiptExpectSecurityGroupID": "sg-package-selftest",
    "cloudSecurityGroupRepairReceiptExpectRegionID": "cn-shenzhen",
    "cloudSecurityGroupRepairReceiptExpectAdminCIDR": "203.0.113.10/32",
}
for key, value in expected.items():
    if policy.get(key) != value:
        raise SystemExit(f"production_evidence_package_self_test result=fail reason=cloud_security_group_repair_receipt_policy_binding_missing key={key}")
receipt = (manifest.get("cloudSecurityGroup") or {}).get("repairReceipt") or {}
if receipt.get("present") is not True:
    raise SystemExit("production_evidence_package_self_test result=fail reason=cloud_security_group_repair_receipt_manifest_missing")
PY
	  PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET=
	  PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP=false
	  PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_FILE=
	  PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON=
	  PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=
	  PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=
	  PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=
	  PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE="$(resolve_package_require_cloud_security_group)"
	  tar -tzf "${tmp_dir}/out/evidence.tar.gz" | grep -q './production-profile-plan.json' || {
	    printf 'production_evidence_package_self_test result=fail reason=profile_plan_missing\n' >&2
	    exit 1
  }
  tar -tzf "${tmp_dir}/out/evidence.tar.gz" | grep -q './production-profile-run.json' || {
    printf 'production_evidence_package_self_test result=fail reason=profile_run_missing\n' >&2
    exit 1
  }
  tar -tzf "${tmp_dir}/out/evidence.tar.gz" | grep -q './production-profile-operator-network.log' || {
    printf 'production_evidence_package_self_test result=fail reason=profile_operator_network_log_missing\n' >&2
    exit 1
  }
  tar -tzf "${tmp_dir}/out/evidence.tar.gz" | grep -q './production-profile-operator-network.json' || {
    printf 'production_evidence_package_self_test result=fail reason=profile_operator_network_json_missing\n' >&2
    exit 1
  }
  tar -tzf "${tmp_dir}/out/evidence.tar.gz" | grep -q './production-profile-entrypoint-probe.json' || {
    printf 'production_evidence_package_self_test result=fail reason=profile_entrypoint_probe_json_missing\n' >&2
    exit 1
  }
  tar -tzf "${tmp_dir}/out/evidence.tar.gz" | grep -q './production-profile-entrypoint-probe.log' || {
    printf 'production_evidence_package_self_test result=fail reason=profile_entrypoint_probe_log_missing\n' >&2
    exit 1
  }
  tar -tzf "${tmp_dir}/out/evidence.tar.gz" | grep -q './production-profile-runbook.md' || {
    printf 'production_evidence_package_self_test result=fail reason=profile_runbook_missing\n' >&2
    exit 1
  }
  tar -tzf "${tmp_dir}/out/evidence.tar.gz" | grep -q './production-profile-prereq-audit.json' || {
    printf 'production_evidence_package_self_test result=fail reason=profile_prereq_audit_missing\n' >&2
    exit 1
  }
  tar -tzf "${tmp_dir}/out/evidence.tar.gz" | grep -q './product-test-plan-run.json' || {
    printf 'production_evidence_package_self_test result=fail reason=product_plan_run_missing\n' >&2
    exit 1
  }
  tar -tzf "${tmp_dir}/out/evidence.tar.gz" | grep -q './product-test-plan-preview.json' || {
    printf 'production_evidence_package_self_test result=fail reason=product_plan_preview_missing\n' >&2
    exit 1
  }
  tar -tzf "${tmp_dir}/out/evidence.tar.gz" | grep -q './product-test-runbook.json' || {
    printf 'production_evidence_package_self_test result=fail reason=product_plan_runbook_missing\n' >&2
    exit 1
  }
  tar -tzf "${tmp_dir}/out/evidence.tar.gz" | grep -q './product-test-prereq-audit.json' || {
    printf 'production_evidence_package_self_test result=fail reason=product_plan_prereq_audit_missing\n' >&2
    exit 1
  }
  tar -tzf "${tmp_dir}/out/evidence.tar.gz" | grep -q './product-campaign-run.json' || {
    printf 'production_evidence_package_self_test result=fail reason=product_campaign_run_missing\n' >&2
    exit 1
  }
  tar -tzf "${tmp_dir}/out/evidence.tar.gz" | grep -q './product-campaign-runbook.md' || {
    printf 'production_evidence_package_self_test result=fail reason=product_campaign_runbook_missing\n' >&2
    exit 1
  }
  tar -tzf "${tmp_dir}/out/evidence.tar.gz" | grep -q './product-campaign-stage-01-entrypoint.log' || {
    printf 'production_evidence_package_self_test result=fail reason=product_campaign_stage_log_missing\n' >&2
    exit 1
  }
  tar -tzf "${tmp_dir}/out/evidence.tar.gz" | grep -q './product-campaign-stage-07-normal-product-baseline.log' || {
    printf 'production_evidence_package_self_test result=fail reason=product_campaign_last_stage_log_missing\n' >&2
    exit 1
  }
  tar -tzf "${tmp_dir}/out/evidence.tar.gz" | grep -q './product-scenario-suite-run.json' || {
    printf 'production_evidence_package_self_test result=fail reason=product_scenario_suite_run_missing\n' >&2
    exit 1
  }
  tar -tzf "${tmp_dir}/out/evidence.tar.gz" | grep -q './product-scenario-suite-run.md' || {
    printf 'production_evidence_package_self_test result=fail reason=product_scenario_suite_md_missing\n' >&2
    exit 1
  }
  tar -tzf "${tmp_dir}/out/evidence.tar.gz" | grep -q './product-scenario-suite-stages.tsv' || {
    printf 'production_evidence_package_self_test result=fail reason=product_scenario_suite_stages_missing\n' >&2
    exit 1
  }
  tar -tzf "${tmp_dir}/out/evidence.tar.gz" | grep -q './validation-inventory.json' || {
    printf 'production_evidence_package_self_test result=fail reason=validation_inventory_missing\n' >&2
    exit 1
  }
  tar -tzf "${tmp_dir}/out/evidence.tar.gz" | grep -q './docs-audit.json' || {
    printf 'production_evidence_package_self_test result=fail reason=docs_audit_missing\n' >&2
    exit 1
  }
  tar -tzf "${tmp_dir}/out/evidence.tar.gz" | grep -q './product-profile-gate.json' || {
    printf 'production_evidence_package_self_test result=fail reason=product_profile_gate_missing\n' >&2
    exit 1
  }
  tar -tzf "${tmp_dir}/out/evidence.tar.gz" | grep -q './product-profile-gate.md' || {
    printf 'production_evidence_package_self_test result=fail reason=product_profile_gate_md_missing\n' >&2
    exit 1
  }
  tar -tzf "${tmp_dir}/out/evidence.tar.gz" | grep -q './product-campaign-audit.json' || {
    printf 'production_evidence_package_self_test result=fail reason=product_campaign_audit_missing\n' >&2
    exit 1
  }
  tar -tzf "${tmp_dir}/out/evidence.tar.gz" | grep -q './product-campaign-audit.md' || {
    printf 'production_evidence_package_self_test result=fail reason=product_campaign_audit_md_missing\n' >&2
    exit 1
  }
  tar -tzf "${tmp_dir}/out/evidence.tar.gz" | grep -q './current-production-readiness.json' || {
    printf 'production_evidence_package_self_test result=fail reason=current_readiness_missing\n' >&2
    exit 1
  }
  tar -tzf "${tmp_dir}/out/evidence.tar.gz" | grep -q './current-production-dashboard.json' || {
    printf 'production_evidence_package_self_test result=fail reason=current_readiness_dashboard_missing\n' >&2
    exit 1
  }
  tar -tzf "${tmp_dir}/out/evidence.tar.gz" | grep -q './current-readiness-operator-network.log' || {
    printf 'production_evidence_package_self_test result=fail reason=current_readiness_operator_network_log_missing\n' >&2
    exit 1
  }
  tar -tzf "${tmp_dir}/out/evidence.tar.gz" | grep -q './current-readiness-operator-network.json' || {
    printf 'production_evidence_package_self_test result=fail reason=current_readiness_operator_network_json_missing\n' >&2
    exit 1
  }
  tar -tzf "${tmp_dir}/out/evidence.tar.gz" | grep -q './current-readiness-production-full-acceptance.log' || {
    printf 'production_evidence_package_self_test result=fail reason=current_readiness_full_acceptance_log_missing\n' >&2
    exit 1
  }
  tar -tzf "${tmp_dir}/out/evidence.tar.gz" | grep -q './current-readiness-full-acceptance-run.json' || {
    printf 'production_evidence_package_self_test result=fail reason=current_readiness_full_acceptance_run_missing\n' >&2
    exit 1
  }
  tar -tzf "${tmp_dir}/out/evidence.tar.gz" | grep -q './current-readiness-full-acceptance-runbook.md' || {
    printf 'production_evidence_package_self_test result=fail reason=current_readiness_full_acceptance_runbook_missing\n' >&2
    exit 1
  }
  tar -tzf "${tmp_dir}/out/evidence.tar.gz" | grep -q './perf_production_profiles.json' || {
    printf 'production_evidence_package_self_test result=fail reason=profile_catalog_snapshot_missing\n' >&2
    exit 1
  }
  tar -tzf "${tmp_dir}/out/evidence.tar.gz" | grep -q './perf_product_campaigns.json' || {
    printf 'production_evidence_package_self_test result=fail reason=product_campaign_catalog_snapshot_missing\n' >&2
    exit 1
  }
  tar -tzf "${tmp_dir}/out/evidence.tar.gz" | grep -q './production-evidence-manifest.json' || {
    printf 'production_evidence_package_self_test result=fail reason=evidence_manifest_missing\n' >&2
    exit 1
  }
  tar -xOzf "${tmp_dir}/out/evidence.tar.gz" ./README.md >"${tmp_dir}/packaged-readme.md"
  grep -q '69_install_performance_evidence_package.sh' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_evidence_install_command\n' >&2
    exit 1
  }
  grep -q 'packageStatus: `PACKAGED`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_package_status\n' >&2
    exit 1
  }
  grep -q 'docsAudit: `PASS`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_docs_audit_status\n' >&2
    exit 1
  }
  grep -q 'productProfileGate: `PASS`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_product_profile_gate_status\n' >&2
    exit 1
  }
  grep -q 'productProfileGateChecked/errors: `3/0`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_product_profile_gate_counts\n' >&2
    exit 1
  }
  grep -q 'productProfileGateRequiredDomains: `10`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_product_profile_gate_domains\n' >&2
    exit 1
  }
  grep -q 'productCampaignAudit: `PASS`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_product_campaign_audit_status\n' >&2
    exit 1
  }
  grep -q 'productCampaignAuditCampaigns/policies/errors: `6/3/0`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_product_campaign_audit_counts\n' >&2
    exit 1
  }
  python3 - "${tmp_dir}/packaged-readme.md" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(r"docsGroups/errors: `(\d+)/(\d+)/(\d+)`", text)
if not match:
    raise SystemExit("production_evidence_package_self_test result=fail reason=readme_missing_docs_audit_counts")
presets, listed, errors = map(int, match.groups())
if presets <= 0 or presets != listed or errors != 0:
    raise SystemExit("production_evidence_package_self_test result=fail reason=readme_invalid_docs_audit_counts")
PY
  grep -q 'inventoryDocs: `5`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_inventory_docs\n' >&2
    exit 1
  }
  grep -q 'validationArtifacts: `docs-audit.json, docs-audit.md, product-profile-gate.json, product-profile-gate.md, product-campaign-audit.json, product-campaign-audit.md, perf_production_profiles.json, perf_product_campaigns.json, validation-inventory.json, validation-inventory.md`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_validation_artifacts\n' >&2
    exit 1
  }
  grep -q 'productPlanStatus: `PASS`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_product_plan_status\n' >&2
    exit 1
  }
  grep -q 'profileRunBlockerType: `-`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_profile_blocker_type\n' >&2
    exit 1
  }
  grep -q 'profileEntrypointDiagnosis: `ok`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_profile_entrypoint_diagnosis\n' >&2
    exit 1
  }
  grep -q 'profileEntrypointTcpStatus: `open`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_profile_entrypoint_tcp_status\n' >&2
    exit 1
  }
  grep -q 'profileEntrypointEdgeIntercept: `-`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_profile_entrypoint_edge_intercept\n' >&2
    exit 1
  }
  grep -q 'profileEntrypointPortProtocols: `1`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_profile_entrypoint_port_protocols\n' >&2
    exit 1
  }
  grep -q 'profileEntrypointBlocker: `-/-` preventsPerformanceEvidence=`-` action=`-`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_profile_entrypoint_blocker\n' >&2
    exit 1
  }
  grep -q 'productPlanBlockerType: `-`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_product_blocker_type\n' >&2
    exit 1
  }
  grep -q 'productPlanScenarioCount: `8`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_product_plan_scenario_count\n' >&2
    exit 1
  }
  grep -q 'productPlanLargeGroupIncluded: `False`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_product_plan_large_group_flag\n' >&2
    exit 1
  }
  grep -q 'productPlanDomainCount: `8`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_product_plan_domain_count\n' >&2
    exit 1
  }
  grep -q 'productPlanRequiredDomainsCovered: `True`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_product_plan_domain_coverage\n' >&2
    exit 1
  }
  grep -q 'productArtifacts: `product-test-plan-run.json' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_product_artifacts\n' >&2
    exit 1
  }
  grep -q 'productCampaign: `non-large-group-release`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_product_campaign\n' >&2
    exit 1
  }
  grep -q 'productCampaignStatus: `PASS`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_product_campaign_status\n' >&2
    exit 1
  }
  grep -q 'productCampaignTarget: `https://chat.myim-prod.com,tcp.myim-prod.com,9000`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_product_campaign_target\n' >&2
    exit 1
  }
  grep -q 'productCampaignFailures/required/attempted/skipped: `0/0/7/0`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_product_campaign_counters\n' >&2
    exit 1
  }
  grep -q 'productScenarioSuite: `recommended`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_product_scenario_suite\n' >&2
    exit 1
  }
  grep -q 'productScenarioSuiteStatus: `PASS`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_product_scenario_suite_status\n' >&2
    exit 1
  }
  grep -q 'productScenarioSuiteScenarios: `8`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_product_scenario_suite_scenarios\n' >&2
    exit 1
  }
  grep -q 'productScenarioSuiteLargeGroupIncluded: `False`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_product_scenario_suite_large_group\n' >&2
    exit 1
  }
  grep -q 'currentReadinessStatus: `PASS`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_current_readiness_status\n' >&2
    exit 1
  }
  grep -q 'currentReadinessOperatorNetwork: `present=True failed=False warnings=-`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_current_readiness_operator_network\n' >&2
    exit 1
  }
  grep -q 'currentReadinessRequestedSmoke/ProductSuite/Baseline/Full: `True/True/True/True`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_current_readiness_requested_runs\n' >&2
    exit 1
  }
  grep -q 'currentReadinessExitCodesSmoke/ProductSuite/Baseline/Full: `0/0/0/0`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_current_readiness_exit_codes\n' >&2
    exit 1
  }
  grep -q 'currentReadinessProductScenarioSuiteExpected: `recommended`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_current_readiness_suite_expected\n' >&2
    exit 1
  }
  grep -q 'currentReadinessProductScenarioSuiteStatus: `PASS`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_current_readiness_suite_status\n' >&2
    exit 1
  }
  grep -q 'currentReadinessProductScenarioSuiteScenarios: `8`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_current_readiness_suite_scenarios\n' >&2
    exit 1
  }
  grep -q 'currentReadinessFullAcceptanceExpectedCampaign: `production-full-acceptance`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_current_readiness_full_expected_campaign\n' >&2
    exit 1
  }
  grep -q 'currentReadinessFullAcceptanceCampaign: `production-full-acceptance`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_current_readiness_full_campaign\n' >&2
    exit 1
  }
  grep -q 'currentReadinessFullAcceptanceStatus: `PASS`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_current_readiness_full_status\n' >&2
    exit 1
  }
  grep -q 'currentReadinessFullAcceptanceFailures/required/attempted/skipped: `0/0/6/0`' "${tmp_dir}/packaged-readme.md" || {
    printf 'production_evidence_package_self_test result=fail reason=readme_missing_current_readiness_full_counters\n' >&2
    exit 1
  }
  tar -xOzf "${tmp_dir}/out/evidence.tar.gz" ./production-evidence-manifest.json >"${tmp_dir}/packaged-manifest.json"
  tar -xOzf "${tmp_dir}/out/evidence.tar.gz" ./product-campaign-run.json >"${tmp_dir}/packaged-campaign-run.json"
  python3 - "${tmp_dir}/packaged-campaign-run.json" <<'PY'
import json
import sys
from pathlib import Path

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
stages = payload.get("stages") or []
if len(stages) != 7:
    raise SystemExit("production_evidence_package_self_test result=fail reason=packaged_campaign_stage_count")
for index, stage in enumerate(stages, start=1):
    if stage.get("runDir") != ".":
        raise SystemExit("production_evidence_package_self_test result=fail reason=packaged_campaign_stage_run_dir_not_relative")
    log = str(stage.get("log") or "")
    if not log.startswith(f"product-campaign-stage-{index:02d}-") or not log.endswith(".log"):
        raise SystemExit("production_evidence_package_self_test result=fail reason=packaged_campaign_stage_log_not_materialized")
    if Path(log).is_absolute():
        raise SystemExit("production_evidence_package_self_test result=fail reason=packaged_campaign_stage_log_absolute")
PY
  python3 - "${tmp_dir}/packaged-manifest.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    manifest = json.load(handle)
files = {str(row.get("path") or "") for row in manifest.get("files") or []}
if "product-campaign-stage-01-entrypoint.log" not in files:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_stage_log_missing")
profile = manifest.get("productionProfile") or {}
product = manifest.get("productPlan") or {}
product_profile_gate = manifest.get("productProfileGate") or {}
campaign = manifest.get("productCampaign") or {}
suite = manifest.get("productScenarioSuite") or {}
current = manifest.get("currentReadiness") or {}
validation_inventory = manifest.get("validationInventory") or {}
policy = manifest.get("policy") or {}
if policy.get("requireProfileArtifacts") is not True:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_policy_profile_not_required")
if policy.get("requireProductPlanArtifacts") is not True:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_policy_product_plan_not_required")
if policy.get("requireProductCampaignArtifacts") is not True:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_policy_product_campaign_not_required")
if policy.get("requireProductScenarioSuiteArtifacts") is not True:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_policy_product_scenario_suite_not_required")
if policy.get("requireProductScenarioSuiteNoLargeGroup") is not True:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_policy_product_scenario_suite_no_large_group_not_required")
if policy.get("requireCurrentReadinessArtifacts") is not True:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_policy_current_readiness_not_required")
if validation_inventory.get("present") is not True:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_validation_inventory_missing")
markdown = validation_inventory.get("markdown") or {}
if markdown.get("present") is not True:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_validation_inventory_markdown_missing")
if markdown.get("path") != "validation-inventory.md":
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_validation_inventory_markdown_path")
if not isinstance(markdown.get("bytes"), int) or markdown.get("bytes") <= 0:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_validation_inventory_markdown_bytes")
if not isinstance(markdown.get("sha256"), str) or len(markdown.get("sha256")) != 64:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_validation_inventory_markdown_sha")
summary = validation_inventory.get("summary") or {}
if summary.get("docs") != 5:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_validation_inventory_docs_count")
required_records = validation_inventory.get("requiredRecords") or {}
expected_required_records = validation_inventory.get("expectedRequiredRecords") or {}
if required_records != expected_required_records:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_validation_inventory_required_records_mismatch")
if "IMServer/LoadTests/perf_scenario_status.py" not in set(required_records.get("python") or []):
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_validation_inventory_scenario_status_missing")
if "IMServer/LoadTests/perf_production_gate.py" not in set(required_records.get("python") or []):
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_validation_inventory_production_gate_missing")
if "IMServer/LoadTests/perf_product_scenario_suite_verify.py" not in set(required_records.get("python") or []):
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_validation_inventory_suite_verifier_missing")
if "IMServer/LoadTests/run_production_acceptance.sh" not in set(required_records.get("shell") or []):
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_validation_inventory_production_acceptance_runner_missing")
if "IMServer/LoadTests/run_product_scenario_suite.sh" not in set(required_records.get("shell") or []):
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_validation_inventory_suite_runner_missing")
if "IMServer/LoadTests/perf_product_campaigns.json" not in set(required_records.get("docs") or []):
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_validation_inventory_campaign_catalog_missing")
if "docs/imserver-aliyun-local-binary-deploy.md" not in set(required_records.get("docs") or []):
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_validation_inventory_deploy_runbook_missing")
if validation_inventory.get("missingRequiredRecords") != {}:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_validation_inventory_missing_required_records")
if profile.get("finalStatus") != "PASS":
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_profile_status_missing")
if profile.get("blockerType") not in {"", None}:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_profile_blocker_type_not_empty")
if "production-profile-operator-network.log" not in set(profile.get("presentFiles") or []):
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_profile_operator_network_log_not_present")
if "production-profile-operator-network.json" not in set(profile.get("presentFiles") or []):
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_profile_operator_network_json_not_present")
profile_operator_network = profile.get("operatorNetwork") or {}
if profile_operator_network.get("present") is not True:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_profile_operator_network_missing")
if profile_operator_network.get("failed") is not False:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_profile_operator_network_failed")
if profile_operator_network.get("warnings") != []:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_profile_operator_network_warnings")
entrypoint = profile.get("entrypointProbe") or {}
if entrypoint.get("present") is not True:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_profile_entrypoint_missing")
if entrypoint.get("failed") is not False:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_profile_entrypoint_failed_invalid")
if entrypoint.get("diagnosis") != "ok":
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_profile_entrypoint_diagnosis_missing")
if entrypoint.get("tcpStatus") != "open":
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_profile_entrypoint_tcp_status_missing")
if entrypoint.get("edgeIntercept") != "":
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_profile_entrypoint_edge_intercept_invalid")
if len(entrypoint.get("portProtocols") or []) != 1:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_profile_entrypoint_port_protocols_missing")
blocker = entrypoint.get("blocker") or {}
if blocker.get("type") not in {"", None}:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_profile_entrypoint_blocker_type_not_empty")
if blocker.get("preventsPerformanceEvidence") not in {"", None}:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_profile_entrypoint_blocker_prevents_not_empty")
if product.get("finalStatus") != "PASS":
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_product_status_missing")
if product.get("blockerType") not in {"", None}:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_product_blocker_type_not_empty")
if product.get("scenarioCount") != 8:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_product_scenario_count_missing")
if product.get("largeGroupIncluded") is not False:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_product_large_group_flag_invalid")
if len(product.get("coveredProductDomains") or []) != 8:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_product_domain_count_missing")
if product.get("requiredProductDomainsCovered") is not True:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_product_domain_coverage_missing")
if product.get("missingProductDomains") != []:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_product_missing_domains_not_empty")
if product_profile_gate.get("status") != "PASS":
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_product_profile_gate_status")
if product_profile_gate.get("profileCount") != 3:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_product_profile_gate_profile_count")
if len(product_profile_gate.get("requiredDomains") or []) != 10:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_product_profile_gate_required_domains")
if product_profile_gate.get("errorCount") != 0:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_product_profile_gate_errors")
checked = set(product_profile_gate.get("profilesChecked") or [])
if checked != {"normal-product-smoke", "normal-product-baseline", "normal-product-capacity"}:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_product_profile_gate_profiles_checked")
for row in product_profile_gate.get("profiles") or []:
    if row.get("status") != "PASS":
        raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_product_profile_gate_profile_status")
    if row.get("missingDomains") != []:
        raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_product_profile_gate_missing_domains")
    if row.get("largeGroupScenarioCount") != 0:
        raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_product_profile_gate_large_group")
    if row.get("forbiddenScenarioCount") != 0:
        raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_product_profile_gate_forbidden")
    if row.get("unknownScenarioCount") != 0:
        raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_product_profile_gate_unknown")
campaign_audit = campaign.get("audit") or {}
if campaign_audit.get("present") is not True:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_product_campaign_audit_missing")
if campaign_audit.get("status") != "PASS":
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_product_campaign_audit_status")
if campaign_audit.get("campaignCount") != 6:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_product_campaign_audit_campaign_count")
if campaign_audit.get("requiredPhasePolicyCount") != 3:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_product_campaign_audit_policy_count")
if campaign_audit.get("errorCount") != 0:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_product_campaign_audit_errors")
policies = campaign_audit.get("requiredPhasePolicies") or []
by_campaign = {row.get("campaign"): row for row in policies}
for expected_campaign in ("non-large-group-release", "product-scenario-regression", "product-scenario-acceptance"):
    if expected_campaign not in by_campaign:
        raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_product_campaign_audit_policy_missing")
non_large_phases = set(by_campaign["non-large-group-release"].get("requiredPhases") or [])
for phase in ("sync-read", "direct-chat", "group-workflow", "realtime-direct"):
    if phase not in non_large_phases:
        raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_product_campaign_audit_non_large_phase_missing")
if campaign.get("campaign") != "non-large-group-release":
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_campaign_missing")
if campaign.get("productionGateCampaign") is not True:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_campaign_not_production_gate")
if campaign.get("finalStatus") != "PASS":
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_campaign_status_missing")
if campaign.get("requiredFailureCount") != 0:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_campaign_required_failures")
if campaign.get("failureCount") != 0:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_campaign_failures")
if campaign.get("attemptedStageCount") != 7:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_campaign_attempted_stage_count")
if campaign.get("skippedStageCount") != 0:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_campaign_skipped_stage_count")
target = campaign.get("target") or {}
if target.get("baseURL") != "https://chat.myim-prod.com":
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_campaign_target_base_url")
if target.get("tcpHost") != "tcp.myim-prod.com":
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_campaign_target_tcp_host")
if str(target.get("tcpPort") or "") != "9000":
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_campaign_target_tcp_port")
if suite.get("present") is not True:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_product_scenario_suite_missing")
if suite.get("suite") != "recommended":
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_product_scenario_suite_name")
if suite.get("status") != "PASS":
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_product_scenario_suite_status")
suite_coverage = suite.get("coverage") or {}
if suite_coverage.get("uniqueScenarioCount") != 8:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_product_scenario_suite_scenario_count")
if suite_coverage.get("largeGroupIncluded") is not False:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_product_scenario_suite_large_group")
if len(suite_coverage.get("coveredProductDomains") or []) != 8:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_product_scenario_suite_domain_count")
if suite_coverage.get("coverageErrorCount") != 0:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_product_scenario_suite_coverage_errors")
suite_present_files = set(suite.get("presentFiles") or [])
for expected_file in ("product-scenario-suite-run.json", "product-scenario-suite-run.md", "product-scenario-suite-stages.tsv"):
    if expected_file not in suite_present_files:
        raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_product_scenario_suite_file_missing")
if current.get("present") is not True:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_current_readiness_missing")
if current.get("status") != "PASS":
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_current_readiness_status")
operator_network = current.get("operatorNetwork") or {}
if operator_network.get("present") is not True:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_current_readiness_operator_network_missing")
if operator_network.get("failed") is not False:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_current_readiness_operator_network_failed")
current_required_files = set(current.get("requiredFiles") or [])
current_present_files = set(current.get("presentFiles") or [])
if "current-production-state-summary.csv" not in current_required_files:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_current_readiness_state_csv_not_required")
if "current-production-state-summary.csv" not in current_present_files:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_current_readiness_state_csv_not_present")
if "current-readiness-operator-network.log" not in current_present_files:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_current_readiness_operator_network_log_not_present")
if "current-readiness-operator-network.json" not in current_present_files:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_current_readiness_operator_network_json_not_present")
requested = current.get("requestedRuns") or {}
if (
    requested.get("smoke") is not True
    or requested.get("productScenarioSuite") is not True
    or requested.get("baseline") is not True
    or requested.get("fullAcceptance") is not True
):
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_current_readiness_requested_runs")
runs = current.get("runs") or {}
if (
    runs.get("smokeExitCode") != 0
    or runs.get("suiteExitCode") != 0
    or runs.get("baselineExitCode") != 0
    or runs.get("fullAcceptanceExitCode") != 0
):
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_current_readiness_exit_codes")
full_run = current.get("fullAcceptanceRun") or {}
if full_run.get("present") is not True:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_current_full_run_missing")
if full_run.get("campaign") != "production-full-acceptance":
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_current_full_campaign")
if full_run.get("execute") is not True:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_current_full_execute")
if full_run.get("finalStatus") != "PASS":
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_current_full_status")
if full_run.get("failureCount") != 0 or full_run.get("requiredFailureCount") != 0:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_current_full_failures")
if full_run.get("attemptedStageCount") != 6 or full_run.get("skippedStageCount") != 0:
    raise SystemExit("production_evidence_package_self_test result=fail reason=manifest_current_full_stage_counts")
PY
  bad_validation_inventory_manifest_dir="${tmp_dir}/bad-validation-inventory-manifest"
  mkdir -p "${bad_validation_inventory_manifest_dir}"
  tar -C "${bad_validation_inventory_manifest_dir}" -xzf "${tmp_dir}/out/evidence.tar.gz"
  python3 - "${bad_validation_inventory_manifest_dir}/production-evidence-manifest.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
required = payload.setdefault("validationInventory", {}).setdefault("requiredRecords", {}).setdefault("python", [])
payload["validationInventory"]["requiredRecords"]["python"] = [
    item for item in required
    if item != "IMServer/LoadTests/perf_product_scenario_suite_verify.py"
]
path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
  if python3 "${SCRIPT_DIR}/perf_evidence_manifest.py" --dir "${bad_validation_inventory_manifest_dir}" --verify >"${tmp_dir}/bad-validation-inventory-manifest.log" 2>&1; then
    printf 'production_evidence_package_self_test result=fail reason=manifest_bad_validation_inventory_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=validation_inventory_required_records_mismatch' "${tmp_dir}/bad-validation-inventory-manifest.log" || {
    printf 'production_evidence_package_self_test result=fail reason=manifest_bad_validation_inventory_reason_missing\n' >&2
    exit 1
  }
  bad_validation_inventory_md_manifest_dir="${tmp_dir}/bad-validation-inventory-md-manifest"
  mkdir -p "${bad_validation_inventory_md_manifest_dir}"
  tar -C "${bad_validation_inventory_md_manifest_dir}" -xzf "${tmp_dir}/out/evidence.tar.gz"
  python3 - "${bad_validation_inventory_md_manifest_dir}/production-evidence-manifest.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload.setdefault("validationInventory", {}).setdefault("markdown", {})["sha256"] = "0" * 64
path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
  if python3 "${SCRIPT_DIR}/perf_evidence_manifest.py" --dir "${bad_validation_inventory_md_manifest_dir}" --verify >"${tmp_dir}/bad-validation-inventory-md-manifest.log" 2>&1; then
    printf 'production_evidence_package_self_test result=fail reason=manifest_bad_validation_inventory_md_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=validation_inventory_markdown_sha_mismatch' "${tmp_dir}/bad-validation-inventory-md-manifest.log" || {
    printf 'production_evidence_package_self_test result=fail reason=manifest_bad_validation_inventory_md_reason_missing\n' >&2
    exit 1
  }
  bad_validation_inventory_md_content_dir="${tmp_dir}/bad-validation-inventory-md-content"
  mkdir -p "${bad_validation_inventory_md_content_dir}"
  tar -C "${bad_validation_inventory_md_content_dir}" -xzf "${tmp_dir}/out/evidence.tar.gz"
  python3 - "${bad_validation_inventory_md_content_dir}/validation-inventory.md" \
    "${bad_validation_inventory_md_content_dir}/production-evidence-manifest.json" <<'PY'
import json
import hashlib
import sys
from pathlib import Path

markdown_path = Path(sys.argv[1])
manifest_path = Path(sys.argv[2])
text = markdown_path.read_text(encoding="utf-8")
markdown_path.write_text(text.replace("- shellScripts:", "- shellScriptCount:", 1), encoding="utf-8")
markdown_sha = hashlib.sha256(markdown_path.read_bytes()).hexdigest()
payload = json.loads(manifest_path.read_text(encoding="utf-8"))
for row in payload.get("files") or []:
    if row.get("path") == "validation-inventory.md":
        row["bytes"] = markdown_path.stat().st_size
        row["sha256"] = markdown_sha
markdown_record = payload.setdefault("validationInventory", {}).setdefault("markdown", {})
markdown_record["bytes"] = markdown_path.stat().st_size
markdown_record["sha256"] = markdown_sha
manifest_path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
  if python3 "${SCRIPT_DIR}/perf_evidence_manifest.py" --dir "${bad_validation_inventory_md_content_dir}" --verify >"${tmp_dir}/bad-validation-inventory-md-content.log" 2>&1; then
    printf 'production_evidence_package_self_test result=fail reason=manifest_bad_validation_inventory_md_content_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=validation_inventory_markdown_verify_failed' "${tmp_dir}/bad-validation-inventory-md-content.log" || {
    printf 'production_evidence_package_self_test result=fail reason=manifest_bad_validation_inventory_md_content_reason_missing\n' >&2
    exit 1
  }
  bad_campaign_audit_policy_dir="${tmp_dir}/bad-campaign-audit-policy"
  mkdir -p "${bad_campaign_audit_policy_dir}"
  tar -C "${bad_campaign_audit_policy_dir}" -xzf "${tmp_dir}/out/evidence.tar.gz"
  python3 - "${bad_campaign_audit_policy_dir}/production-evidence-manifest.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
policies = payload.setdefault("productCampaign", {}).setdefault("audit", {}).setdefault("requiredPhasePolicies", [])
for row in policies:
    if row.get("campaign") == "non-large-group-release":
        row["requiredPhases"] = [phase for phase in row.get("requiredPhases", []) if phase != "sync-read"]
path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
  if python3 "${SCRIPT_DIR}/perf_evidence_manifest.py" --dir "${bad_campaign_audit_policy_dir}" --verify >"${tmp_dir}/bad-campaign-audit-policy.log" 2>&1; then
    printf 'production_evidence_package_self_test result=fail reason=manifest_bad_campaign_audit_policy_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=product_campaign_audit_required_phase_policies_mismatch' "${tmp_dir}/bad-campaign-audit-policy.log" || {
    printf 'production_evidence_package_self_test result=fail reason=manifest_bad_campaign_audit_policy_reason_missing\n' >&2
    exit 1
  }
  bad_campaign_catalog_snapshot_dir="${tmp_dir}/bad-campaign-catalog-snapshot"
  mkdir -p "${bad_campaign_catalog_snapshot_dir}"
  tar -C "${bad_campaign_catalog_snapshot_dir}" -xzf "${tmp_dir}/out/evidence.tar.gz"
  python3 - "${bad_campaign_catalog_snapshot_dir}/perf_product_campaigns.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["schemaVersion"] = 999
path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
  if python3 "${SCRIPT_DIR}/perf_evidence_manifest.py" --dir "${bad_campaign_catalog_snapshot_dir}" --verify >"${tmp_dir}/bad-campaign-catalog-snapshot.log" 2>&1; then
    printf 'production_evidence_package_self_test result=fail reason=manifest_bad_campaign_catalog_snapshot_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=product_campaign_audit_campaign_catalog_sha_mismatch' "${tmp_dir}/bad-campaign-catalog-snapshot.log" || {
    printf 'production_evidence_package_self_test result=fail reason=manifest_bad_campaign_catalog_snapshot_reason_missing\n' >&2
    exit 1
  }
  bad_suite_manifest_dir="${tmp_dir}/bad-product-scenario-suite-manifest"
  mkdir -p "${bad_suite_manifest_dir}"
  tar -C "${bad_suite_manifest_dir}" -xzf "${tmp_dir}/out/evidence.tar.gz"
  python3 - "${bad_suite_manifest_dir}/production-evidence-manifest.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload.setdefault("productScenarioSuite", {}).setdefault("coverage", {})["uniqueScenarioCount"] = 999
path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
  if python3 "${SCRIPT_DIR}/perf_evidence_manifest.py" --dir "${bad_suite_manifest_dir}" --verify >"${tmp_dir}/bad-product-scenario-suite-manifest.log" 2>&1; then
    printf 'production_evidence_package_self_test result=fail reason=manifest_bad_product_scenario_suite_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=product_scenario_suite_coverage_uniqueScenarioCount_mismatch' "${tmp_dir}/bad-product-scenario-suite-manifest.log" || {
    printf 'production_evidence_package_self_test result=fail reason=manifest_bad_product_scenario_suite_reason_missing\n' >&2
    exit 1
  }
  bad_readme_manifest_dir="${tmp_dir}/bad-readme-manifest"
  mkdir -p "${bad_readme_manifest_dir}"
  tar -C "${bad_readme_manifest_dir}" -xzf "${tmp_dir}/out/evidence.tar.gz"
  perl -0pi -e 's/- productCampaignStatus: `PASS`/- productCampaignStatus: `FAIL`/' "${bad_readme_manifest_dir}/README.md"
  if python3 "${SCRIPT_DIR}/perf_evidence_manifest.py" --dir "${bad_readme_manifest_dir}" --verify >"${tmp_dir}/bad-readme-manifest.log" 2>&1; then
    printf 'production_evidence_package_self_test result=fail reason=manifest_bad_readme_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=readme_product_campaign_status_mismatch' "${tmp_dir}/bad-readme-manifest.log" || {
    printf 'production_evidence_package_self_test result=fail reason=manifest_bad_readme_reason_missing\n' >&2
    exit 1
  }
  bad_current_readiness_md_manifest_dir="${tmp_dir}/bad-current-readiness-md-manifest"
  mkdir -p "${bad_current_readiness_md_manifest_dir}"
  tar -C "${bad_current_readiness_md_manifest_dir}" -xzf "${tmp_dir}/out/evidence.tar.gz"
  printf '\nmanual drift\n' >>"${bad_current_readiness_md_manifest_dir}/current-production-readiness.md"
  if python3 "${SCRIPT_DIR}/perf_evidence_manifest.py" --dir "${bad_current_readiness_md_manifest_dir}" --verify >"${tmp_dir}/bad-current-readiness-md-manifest.log" 2>&1; then
    printf 'production_evidence_package_self_test result=fail reason=manifest_bad_current_readiness_markdown_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=current_readiness_artifact_verify_failed' "${tmp_dir}/bad-current-readiness-md-manifest.log" || {
    printf 'production_evidence_package_self_test result=fail reason=manifest_bad_current_readiness_markdown_reason_missing\n' >&2
    exit 1
  }
  grep -q 'readiness_markdown_mismatch' "${tmp_dir}/bad-current-readiness-md-manifest.log" || {
    printf 'production_evidence_package_self_test result=fail reason=manifest_bad_current_readiness_markdown_detail_missing\n' >&2
    exit 1
  }
  bad_current_full_manifest_dir="${tmp_dir}/bad-current-full-manifest"
  mkdir -p "${bad_current_full_manifest_dir}"
  tar -C "${bad_current_full_manifest_dir}" -xzf "${tmp_dir}/out/evidence.tar.gz"
  python3 - "${bad_current_full_manifest_dir}/production-evidence-manifest.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload.setdefault("currentReadiness", {}).setdefault("fullAcceptanceRun", {})["campaign"] = "non-large-group-release"
path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
  if python3 "${SCRIPT_DIR}/perf_evidence_manifest.py" --dir "${bad_current_full_manifest_dir}" --verify >"${tmp_dir}/bad-current-full-manifest.log" 2>&1; then
    printf 'production_evidence_package_self_test result=fail reason=manifest_bad_current_full_summary_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=current_readiness_full_acceptance_run_mismatch' "${tmp_dir}/bad-current-full-manifest.log" || {
    printf 'production_evidence_package_self_test result=fail reason=manifest_bad_current_full_summary_reason_missing\n' >&2
    exit 1
  }
  partial_current_readiness_manifest_dir="${tmp_dir}/partial-current-readiness-manifest"
  mkdir -p "${partial_current_readiness_manifest_dir}"
  tar -C "${partial_current_readiness_manifest_dir}" -xzf "${tmp_dir}/out/evidence.tar.gz"
  python3 - \
    "${partial_current_readiness_manifest_dir}/production-evidence-manifest.json" \
    "${partial_current_readiness_manifest_dir}/current-production-readiness.json" <<'PY'
import json
import sys
from pathlib import Path

manifest_path, receipt_path = map(Path, sys.argv[1:3])
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
for payload in (manifest.get("currentReadiness") or {}, receipt):
    payload.setdefault("requestedRuns", {})["fullAcceptance"] = False
    payload.setdefault("runs", {})["fullAcceptanceExitCode"] = None
manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True), encoding="utf-8")
receipt_path.write_text(json.dumps(receipt, indent=2, sort_keys=True), encoding="utf-8")
PY
  if python3 "${SCRIPT_DIR}/perf_evidence_manifest.py" --dir "${partial_current_readiness_manifest_dir}" --verify >"${tmp_dir}/partial-current-readiness-manifest.log" 2>&1; then
    printf 'production_evidence_package_self_test result=fail reason=manifest_partial_current_readiness_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=current_readiness_required_run_missing' "${tmp_dir}/partial-current-readiness-manifest.log" || {
    printf 'production_evidence_package_self_test result=fail reason=manifest_partial_current_readiness_reason_missing\n' >&2
    exit 1
  }
  bad_current_full_campaign_dir="${tmp_dir}/bad-current-full-campaign"
  mkdir -p "${bad_current_full_campaign_dir}"
  tar -C "${bad_current_full_campaign_dir}" -xzf "${tmp_dir}/out/evidence.tar.gz"
  python3 - "${bad_current_full_campaign_dir}/current-readiness-full-acceptance-run.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["campaign"] = "non-large-group-release"
path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
  if python3 "${SCRIPT_DIR}/perf_evidence_manifest.py" --dir "${bad_current_full_campaign_dir}" --verify >"${tmp_dir}/bad-current-full-campaign.log" 2>&1; then
    printf 'production_evidence_package_self_test result=fail reason=manifest_bad_current_full_campaign_passed\n' >&2
    exit 1
  fi
  grep -q 'current_readiness_full_acceptance_run_mismatch' "${tmp_dir}/bad-current-full-campaign.log" || {
    printf 'production_evidence_package_self_test result=fail reason=manifest_bad_current_full_campaign_reason_missing\n' >&2
    exit 1
  }
  bad_profile_operator_network_dir="${tmp_dir}/bad-profile-operator-network"
  mkdir -p "${bad_profile_operator_network_dir}"
  tar -C "${bad_profile_operator_network_dir}" -xzf "${tmp_dir}/out/evidence.tar.gz"
  printf 'operator-network target=http://127.0.0.1:8080 host=127.0.0.1 status=fail warning=tun_route routeInterface=utun99 routeGateway=198.18.0.1 proxyEnv=<none>\noperator-network result=fail failures=1 action=disconnect_local_tun_or_use_clean_network\n' \
    >"${bad_profile_operator_network_dir}/production-profile-operator-network.log"
  printf '{"schemaVersion":1,"status":"fail","failed":true,"failureCount":1,"targetCount":1,"warnings":["tun_route"],"warningCounts":{"tun_route":1},"routeInterfaces":["utun99"],"routeGateways":["198.18.0.1"],"failedTargets":[],"targets":[],"action":"disconnect_local_tun_or_use_clean_network"}\n' \
    >"${bad_profile_operator_network_dir}/production-profile-operator-network.json"
  python3 "${SCRIPT_DIR}/perf_evidence_manifest.py" --dir "${bad_profile_operator_network_dir}" --write >/dev/null
  if python3 "${SCRIPT_DIR}/perf_evidence_manifest.py" --dir "${bad_profile_operator_network_dir}" --verify >"${tmp_dir}/bad-profile-operator-network.log" 2>&1; then
    printf 'production_evidence_package_self_test result=fail reason=manifest_bad_profile_operator_network_passed\n' >&2
    exit 1
  fi
  grep -Eq 'reason=production_profile_operator_network_(failed|warning)' "${tmp_dir}/bad-profile-operator-network.log" || {
    printf 'production_evidence_package_self_test result=fail reason=manifest_bad_profile_operator_network_reason_missing\n' >&2
    exit 1
  }
  bad_campaign_target_manifest_dir="${tmp_dir}/bad-campaign-target-manifest"
  mkdir -p "${bad_campaign_target_manifest_dir}"
  tar -C "${bad_campaign_target_manifest_dir}" -xzf "${tmp_dir}/out/evidence.tar.gz"
  python3 - "${bad_campaign_target_manifest_dir}/production-evidence-manifest.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)
payload.setdefault("productCampaign", {}).setdefault("target", {})["tcpHost"] = "10.0.0.1"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
  if python3 "${SCRIPT_DIR}/perf_evidence_manifest.py" --dir "${bad_campaign_target_manifest_dir}" --verify >"${tmp_dir}/bad-campaign-target-manifest.log" 2>&1; then
    printf 'production_evidence_package_self_test result=fail reason=manifest_bad_campaign_target_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=product_campaign_target_mismatch' "${tmp_dir}/bad-campaign-target-manifest.log" || {
    printf 'production_evidence_package_self_test result=fail reason=manifest_bad_campaign_target_reason_missing\n' >&2
    exit 1
  }
  bad_campaign_gate_target_dir="${tmp_dir}/bad-campaign-gate-target"
  mkdir -p "${bad_campaign_gate_target_dir}"
  tar -C "${bad_campaign_gate_target_dir}" -xzf "${tmp_dir}/out/evidence.tar.gz"
  python3 - \
    "${bad_campaign_gate_target_dir}/production-evidence-manifest.json" \
    "${bad_campaign_gate_target_dir}/product-campaign-run.json" \
    "${bad_campaign_gate_target_dir}/product-campaign-runbook.md" \
    "${SCRIPT_DIR}" <<'PY'
import json
import sys
from pathlib import Path

manifest_path, campaign_path, runbook_path = map(Path, sys.argv[1:4])
script_dir = Path(sys.argv[4])
sys.path.insert(0, str(script_dir))
from run_product_campaign import build_runbook

manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
manifest.setdefault("productCampaign", {}).setdefault("target", {})["tcpHost"] = "10.0.0.1"
manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True), encoding="utf-8")

campaign = json.loads(campaign_path.read_text(encoding="utf-8"))
campaign.setdefault("target", {})["tcpHost"] = "10.0.0.1"
for stage in campaign.get("stages") or []:
    command = str(stage.get("command") or "")
    stage["command"] = command.replace("TCP_HOST=tcp.myim-prod.com", "TCP_HOST=10.0.0.1")
campaign_path.write_text(json.dumps(campaign, indent=2, sort_keys=True), encoding="utf-8")
runbook_path.write_text(build_runbook(campaign), encoding="utf-8")
PY
  if python3 "${SCRIPT_DIR}/perf_evidence_manifest.py" --dir "${bad_campaign_gate_target_dir}" --verify >"${tmp_dir}/bad-campaign-gate-target.log" 2>&1; then
    printf 'production_evidence_package_self_test result=fail reason=manifest_bad_campaign_gate_target_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=product_campaign_gate_target_mismatch' "${tmp_dir}/bad-campaign-gate-target.log" || {
    printf 'production_evidence_package_self_test result=fail reason=manifest_bad_campaign_gate_target_reason_missing\n' >&2
    exit 1
  }
  missing_policy_manifest_dir="${tmp_dir}/missing-policy-manifest"
  mkdir -p "${missing_policy_manifest_dir}"
  tar -C "${missing_policy_manifest_dir}" -xzf "${tmp_dir}/out/evidence.tar.gz"
  python3 - "${missing_policy_manifest_dir}/production-evidence-manifest.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)
del payload["policy"]["requireProfileArtifacts"]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
  if python3 "${SCRIPT_DIR}/perf_evidence_manifest.py" --dir "${missing_policy_manifest_dir}" --verify >"${tmp_dir}/missing-policy-manifest.log" 2>&1; then
    printf 'production_evidence_package_self_test result=fail reason=manifest_missing_policy_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=manifest_policy_field_missing' "${tmp_dir}/missing-policy-manifest.log" || {
    printf 'production_evidence_package_self_test result=fail reason=manifest_missing_policy_reason_missing\n' >&2
    exit 1
  }
  invalid_policy_manifest_dir="${tmp_dir}/invalid-policy-manifest"
  mkdir -p "${invalid_policy_manifest_dir}"
  tar -C "${invalid_policy_manifest_dir}" -xzf "${tmp_dir}/out/evidence.tar.gz"
  python3 - "${invalid_policy_manifest_dir}/production-evidence-manifest.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)
payload["policy"]["requireProfileArtifacts"] = "true"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
  if python3 "${SCRIPT_DIR}/perf_evidence_manifest.py" --dir "${invalid_policy_manifest_dir}" --verify >"${tmp_dir}/invalid-policy-manifest.log" 2>&1; then
    printf 'production_evidence_package_self_test result=fail reason=manifest_invalid_policy_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=manifest_policy_field_invalid' "${tmp_dir}/invalid-policy-manifest.log" || {
    printf 'production_evidence_package_self_test result=fail reason=manifest_invalid_policy_reason_missing\n' >&2
    exit 1
  }
  missing_profile_manifest_dir="${tmp_dir}/missing-profile-manifest"
  mkdir -p "${missing_profile_manifest_dir}"
  tar -C "${missing_profile_manifest_dir}" -xzf "${tmp_dir}/out/evidence.tar.gz"
  rm -f "${missing_profile_manifest_dir}/production-profile-run.json"
  python3 "${SCRIPT_DIR}/perf_evidence_manifest.py" --dir "${missing_profile_manifest_dir}" --write >/dev/null
  if python3 "${SCRIPT_DIR}/perf_evidence_manifest.py" --dir "${missing_profile_manifest_dir}" --verify >"${tmp_dir}/missing-profile-manifest.log" 2>&1; then
    printf 'production_evidence_package_self_test result=fail reason=manifest_missing_profile_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=production_profile_required' "${tmp_dir}/missing-profile-manifest.log" || {
    printf 'production_evidence_package_self_test result=fail reason=manifest_missing_profile_reason_missing\n' >&2
    exit 1
  }
  missing_product_manifest_dir="${tmp_dir}/missing-product-manifest"
  mkdir -p "${missing_product_manifest_dir}"
  tar -C "${missing_product_manifest_dir}" -xzf "${tmp_dir}/out/evidence.tar.gz"
  rm -f \
    "${missing_product_manifest_dir}/product-test-plan-run.json" \
    "${missing_product_manifest_dir}/product-test-plan-preview.json" \
    "${missing_product_manifest_dir}/product-test-plan-phases.tsv" \
    "${missing_product_manifest_dir}/product-test-prereq-plan.json" \
    "${missing_product_manifest_dir}/product-test-prereq-audit.json" \
    "${missing_product_manifest_dir}/product-test-prereq-audit.md" \
    "${missing_product_manifest_dir}/product-test-scenario-catalog.json" \
    "${missing_product_manifest_dir}/product-test-runbook.json" \
    "${missing_product_manifest_dir}/product-test-runbook.md"
  python3 "${SCRIPT_DIR}/perf_evidence_manifest.py" --dir "${missing_product_manifest_dir}" --write >/dev/null
  if python3 "${SCRIPT_DIR}/perf_evidence_manifest.py" --dir "${missing_product_manifest_dir}" --verify >"${tmp_dir}/missing-product-manifest.log" 2>&1; then
    printf 'production_evidence_package_self_test result=fail reason=manifest_missing_product_plan_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=product_plan_required' "${tmp_dir}/missing-product-manifest.log" || {
    printf 'production_evidence_package_self_test result=fail reason=manifest_missing_product_plan_reason_missing\n' >&2
    exit 1
  }
  if grep -q 'PERF_PRODUCTION_GATE_SOURCE_JSON' "${tmp_dir}/packaged-readme.md"; then
    printf 'production_evidence_package_self_test result=fail reason=readme_uses_gate_only_install\n' >&2
    exit 1
  fi
  tar -xOzf "${tmp_dir}/out/evidence.tar.gz" ./production-profile-run.json >"${tmp_dir}/packaged-profile-run.json"
  python3 - "${tmp_dir}/packaged-profile-run.json" "${tmp_dir}/out/evidence.tar.gz" <<'PY'
import json
import sys

run_path, package_path = sys.argv[1:3]
with open(run_path, encoding="utf-8") as handle:
    payload = json.load(handle)
package = payload.get("package") or {}
if package.get("status") != "PACKAGED":
    raise SystemExit("production_evidence_package_self_test result=fail reason=run_package_status_missing")
if package.get("path") != package_path:
    raise SystemExit("production_evidence_package_self_test result=fail reason=run_package_path_mismatch")
if payload.get("packageEnabled") is not False:
    raise SystemExit("production_evidence_package_self_test result=fail reason=run_package_enabled_not_preserved")
PY
  cp "${tmp_dir}/packaged-profile-run.json" "${tmp_dir}/bad-package-path-run.json"
  python3 - "${tmp_dir}/bad-package-path-run.json" <<'PY'
import json
import sys
from pathlib import Path

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)
payload["package"]["path"] = "/tmp/wrong-production-evidence.tar.gz"
payload["package"]["fileName"] = "wrong-production-evidence.tar.gz"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
  if python3 "${SCRIPT_DIR}/perf_profile_artifacts_verify.py" \
    --gate-json "${tmp_dir}/production-gate.json" \
    --profile-run-json "${tmp_dir}/bad-package-path-run.json" \
    --profile-plan-json "${tmp_dir}/production-profile-plan.json" \
    --profile-runbook-json "${tmp_dir}/production-profile-runbook.json" \
    --profile-runbook-md "${tmp_dir}/production-profile-runbook.md" \
    --prereq-plan-json "${tmp_dir}/production-profile-prereq-plan.json" \
    --prereq-audit-json "${tmp_dir}/production-profile-prereq-audit.json" \
    --scenario-catalog-json "${tmp_dir}/production-profile-scenario-catalog.json" \
    --expected-package-path "${tmp_dir}/out/evidence.tar.gz" \
    >"${tmp_dir}/bad-package-path.log" 2>&1; then
    printf 'production_evidence_package_self_test result=fail reason=bad_package_path_passed\n' >&2
    exit 1
  fi
  grep -q 'reason=profile_run_package_path_mismatch' "${tmp_dir}/bad-package-path.log" || {
    printf 'production_evidence_package_self_test result=fail reason=bad_package_path_reason_missing\n' >&2
    exit 1
  }
  mv "${tmp_dir}/product-test-scenario-catalog.json" "${tmp_dir}/product-test-scenario-catalog.json.good"
  if RESULT_ROOT="${tmp_dir}" \
    PERF_PRODUCTION_GATE_JSON="${tmp_dir}/production-gate.json" \
    PERF_PRODUCTION_GATE_PROFILE="minimum-smoke" \
    PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=0 \
    PERF_PRODUCTION_GATE_EXPECT_BASE_URL=https://chat.myim-prod.com \
    PERF_PRODUCTION_GATE_EXPECT_TCP_HOST=tcp.myim-prod.com \
    PERF_PRODUCTION_GATE_EXPECT_TCP_PORT=9000 \
    PRODUCTION_EVIDENCE_OUTPUT_DIR="${tmp_dir}/missing-product-catalog-out" \
    PRODUCTION_EVIDENCE_PACKAGE="${tmp_dir}/missing-product-catalog-out/evidence.tar.gz" \
      package_evidence "${tmp_dir}/production-gate.json" "${tmp_dir}/missing-product-catalog-out" "${tmp_dir}/missing-product-catalog-out/evidence.tar.gz" \
      >"${tmp_dir}/missing-product-catalog.log" 2>&1; then
    printf 'production_evidence_package_self_test result=fail reason=missing_product_catalog_packaged\n' >&2
    exit 1
  fi
  grep -q 'reason=product_plan_scenario_catalog_missing' "${tmp_dir}/missing-product-catalog.log" || {
    printf 'production_evidence_package_self_test result=fail reason=missing_product_catalog_reason_missing\n' >&2
    exit 1
  }
  mv "${tmp_dir}/product-test-scenario-catalog.json.good" "${tmp_dir}/product-test-scenario-catalog.json"
  cp "${tmp_dir}/product-test-plan-run.json" "${tmp_dir}/product-test-plan-run.json.good"
  python3 - "${tmp_dir}/product-test-plan-run.json" <<'PY'
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
  if RESULT_ROOT="${tmp_dir}" \
    PERF_PRODUCTION_GATE_JSON="${tmp_dir}/production-gate.json" \
    PERF_PRODUCTION_GATE_PROFILE="minimum-smoke" \
    PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=0 \
    PERF_PRODUCTION_GATE_EXPECT_BASE_URL=https://chat.myim-prod.com \
    PERF_PRODUCTION_GATE_EXPECT_TCP_HOST=tcp.myim-prod.com \
    PERF_PRODUCTION_GATE_EXPECT_TCP_PORT=9000 \
    PRODUCTION_EVIDENCE_OUTPUT_DIR="${tmp_dir}/failed-product-plan-out" \
    PRODUCTION_EVIDENCE_PACKAGE="${tmp_dir}/failed-product-plan-out/evidence.tar.gz" \
      package_evidence "${tmp_dir}/production-gate.json" "${tmp_dir}/failed-product-plan-out" "${tmp_dir}/failed-product-plan-out/evidence.tar.gz" \
      >"${tmp_dir}/failed-product-plan.log" 2>&1; then
    printf 'production_evidence_package_self_test result=fail reason=failed_product_plan_packaged\n' >&2
    exit 1
  fi
  grep -q 'reason=product_plan_not_pass' "${tmp_dir}/failed-product-plan.log" || {
    printf 'production_evidence_package_self_test result=fail reason=failed_product_plan_reason_missing\n' >&2
    exit 1
  }
  mv "${tmp_dir}/product-test-plan-run.json.good" "${tmp_dir}/product-test-plan-run.json"
  cp "${tmp_dir}/product-test-plan-preview.json" "${tmp_dir}/product-test-plan-preview.json.good"
  python3 - "${tmp_dir}/product-test-plan-preview.json" "${SCRIPT_DIR}" <<'PY'
import json
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[2])
from perf_product_test_plan_runbook import build_markdown

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)
summary = payload.setdefault("summary", {})
summary["coveredProductDomains"] = ["account-security"]
summary["missingProductDomains"] = [
    "sync-read",
    "direct-chat",
    "group-workflow",
    "contacts-social",
    "media-ai-admin",
    "reliability-recovery",
    "realtime-direct",
]
summary["requiredProductDomainsCovered"] = False
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
runbook_path = Path(path).with_name("product-test-runbook.json")
with open(runbook_path, encoding="utf-8") as handle:
    runbook = json.load(handle)
runbook_preview = runbook.setdefault("plan", {}).setdefault("preview", {})
runbook_preview["coveredProductDomains"] = summary["coveredProductDomains"]
runbook_preview["missingProductDomains"] = summary["missingProductDomains"]
runbook_preview["requiredProductDomainsCovered"] = summary["requiredProductDomainsCovered"]
with open(runbook_path, "w", encoding="utf-8") as handle:
    json.dump(runbook, handle, indent=2, sort_keys=True)
runbook_path.with_suffix(".md").write_text(build_markdown(runbook), encoding="utf-8")
PY
  if RESULT_ROOT="${tmp_dir}" \
    PERF_PRODUCTION_GATE_JSON="${tmp_dir}/production-gate.json" \
    PERF_PRODUCTION_GATE_PROFILE="minimum-smoke" \
    PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=0 \
    PERF_PRODUCTION_GATE_EXPECT_BASE_URL=https://chat.myim-prod.com \
    PERF_PRODUCTION_GATE_EXPECT_TCP_HOST=tcp.myim-prod.com \
    PERF_PRODUCTION_GATE_EXPECT_TCP_PORT=9000 \
    PRODUCTION_EVIDENCE_OUTPUT_DIR="${tmp_dir}/incomplete-product-domains-out" \
    PRODUCTION_EVIDENCE_PACKAGE="${tmp_dir}/incomplete-product-domains-out/evidence.tar.gz" \
      package_evidence "${tmp_dir}/production-gate.json" "${tmp_dir}/incomplete-product-domains-out" "${tmp_dir}/incomplete-product-domains-out/evidence.tar.gz" \
      >"${tmp_dir}/incomplete-product-domains.log" 2>&1; then
    printf 'production_evidence_package_self_test result=fail reason=incomplete_product_domains_packaged\n' >&2
    exit 1
  fi
  grep -Eq 'reason=(product_plan_manifest_required_domains_not_covered|product_plan_manifest_missing_domains_nonempty|materialized_product_plan_required_domains_not_covered)' "${tmp_dir}/incomplete-product-domains.log" || {
    printf 'production_evidence_package_self_test result=fail reason=incomplete_product_domains_reason_missing\n' >&2
    exit 1
  }
  mv "${tmp_dir}/product-test-plan-preview.json.good" "${tmp_dir}/product-test-plan-preview.json"
  printf 'production-evidence-self-test-secret-012345\n' >"${tmp_dir}/dashboard.md"
  if RESULT_ROOT="${tmp_dir}" \
    PERF_PRODUCTION_GATE_JSON="${tmp_dir}/production-gate.json" \
    PERF_PRODUCTION_GATE_PROFILE="minimum-smoke" \
    PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=0 \
    PERF_PRODUCTION_GATE_EXPECT_BASE_URL=https://chat.myim-prod.com \
    PERF_PRODUCTION_GATE_EXPECT_TCP_HOST=tcp.myim-prod.com \
    PERF_PRODUCTION_GATE_EXPECT_TCP_PORT=9000 \
    PRODUCTION_EVIDENCE_OUTPUT_DIR="${tmp_dir}/secret-leak-out" \
    PRODUCTION_EVIDENCE_PACKAGE="${tmp_dir}/secret-leak-out/evidence.tar.gz" \
    IM_INTERNAL_SECRET="production-evidence-self-test-secret-012345" \
      package_evidence "${tmp_dir}/production-gate.json" "${tmp_dir}/secret-leak-out" "${tmp_dir}/secret-leak-out/evidence.tar.gz" \
      >"${tmp_dir}/secret-leak.log" 2>&1; then
    printf 'production_evidence_package_self_test result=fail reason=secret_leak_packaged\n' >&2
    exit 1
  fi
  grep -q 'perf_secret_scan result=fail' "${tmp_dir}/secret-leak.log" || {
    printf 'production_evidence_package_self_test result=fail reason=secret_leak_reason_missing\n' >&2
    exit 1
  }
  rm -f "${tmp_dir}/dashboard.md"
  if RESULT_ROOT="${tmp_dir}" \
    PERF_PRODUCTION_GATE_JSON="${tmp_dir}/production-gate.json" \
    PERF_PRODUCTION_GATE_PROFILE="minimum-smoke" \
    PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=0 \
    PERF_PRODUCTION_GATE_EXPECT_BASE_URL=https://chat.myim-prod.com \
    PERF_PRODUCTION_GATE_EXPECT_TCP_HOST=tcp.myim-prod.com \
    PERF_PRODUCTION_GATE_EXPECT_TCP_PORT=9000 \
    PRODUCTION_EVIDENCE_OUTPUT_DIR="${tmp_dir}/login-cache" \
    PRODUCTION_EVIDENCE_PACKAGE="${tmp_dir}/login-cache/evidence.tar.gz" \
      package_evidence "${tmp_dir}/production-gate.json" "${tmp_dir}/login-cache" "${tmp_dir}/login-cache/evidence.tar.gz" \
      >"${tmp_dir}/token-cache-path.log" 2>&1; then
    printf 'production_evidence_package_self_test result=fail reason=token_cache_path_packaged\n' >&2
    exit 1
  fi
  grep -q 'token_cache_artifact' "${tmp_dir}/token-cache-path.log" || {
    printf 'production_evidence_package_self_test result=fail reason=token_cache_path_reason_missing\n' >&2
    exit 1
  }
  if RESULT_ROOT="${tmp_dir}" \
    PERF_PRODUCTION_GATE_JSON="${tmp_dir}/production-gate.json" \
    PERF_PRODUCTION_GATE_PROFILE="minimum-smoke" \
    PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=0 \
    PERF_PRODUCTION_GATE_EXPECT_BASE_URL=https://chat.myim-prod.com \
    PERF_PRODUCTION_GATE_EXPECT_TCP_HOST=tcp.myim-prod.com \
    PERF_PRODUCTION_GATE_EXPECT_TCP_PORT=9000 \
    PRODUCTION_EVIDENCE_OUTPUT_DIR="${tmp_dir}/accounts" \
    PRODUCTION_EVIDENCE_PACKAGE="${tmp_dir}/accounts/evidence.tar.gz" \
      package_evidence "${tmp_dir}/production-gate.json" "${tmp_dir}/accounts" "${tmp_dir}/accounts/evidence.tar.gz" \
      >"${tmp_dir}/account-artifact-path.log" 2>&1; then
    printf 'production_evidence_package_self_test result=fail reason=account_artifact_path_packaged\n' >&2
    exit 1
  fi
  grep -q 'account_artifact' "${tmp_dir}/account-artifact-path.log" || {
    printf 'production_evidence_package_self_test result=fail reason=account_artifact_path_reason_missing\n' >&2
    exit 1
  }
  mv "${tmp_dir}/production-profile-run.json" "${tmp_dir}/production-profile-run.json.bak"
  if RESULT_ROOT="${tmp_dir}" \
    PERF_PRODUCTION_GATE_JSON="${tmp_dir}/production-gate.json" \
    PERF_PRODUCTION_GATE_PROFILE="minimum-smoke" \
    PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=0 \
    PERF_PRODUCTION_GATE_EXPECT_BASE_URL=https://chat.myim-prod.com \
    PERF_PRODUCTION_GATE_EXPECT_TCP_HOST=tcp.myim-prod.com \
    PERF_PRODUCTION_GATE_EXPECT_TCP_PORT=9000 \
    PRODUCTION_EVIDENCE_OUTPUT_DIR="${tmp_dir}/missing-run-out" \
    PRODUCTION_EVIDENCE_PACKAGE="${tmp_dir}/missing-run-out/evidence.tar.gz" \
      package_evidence "${tmp_dir}/production-gate.json" "${tmp_dir}/missing-run-out" "${tmp_dir}/missing-run-out/evidence.tar.gz" \
      >"${tmp_dir}/missing-run.log" 2>&1; then
    printf 'production_evidence_package_self_test result=fail reason=missing_run_unexpectedly_packaged\n' >&2
    exit 1
  fi
  grep -Eq 'reason=(production_profile_required|profile_run_missing)' "${tmp_dir}/missing-run.log" || {
    printf 'production_evidence_package_self_test result=fail reason=missing_run_reason_missing\n' >&2
    exit 1
  }
  mv "${tmp_dir}/production-profile-run.json.bak" "${tmp_dir}/production-profile-run.json"
  printf 'production_evidence_package_self_test result=pass\n'
  exit 0
fi

package_evidence "${PERF_PRODUCTION_GATE_JSON}" "${PRODUCTION_EVIDENCE_OUTPUT_DIR}" "${PRODUCTION_EVIDENCE_PACKAGE}"
