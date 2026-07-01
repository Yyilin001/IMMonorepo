#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export COPYFILE_DISABLE="${COPYFILE_DISABLE:-1}"
PRODUCTION_TARGET_POLICY="${PRODUCTION_TARGET_POLICY:-${SCRIPT_DIR}/production_target_policy.py}"

PRODUCTION_ACCEPTANCE_SELF_TEST="${PRODUCTION_ACCEPTANCE_SELF_TEST:-false}"
PRODUCTION_ACCEPTANCE_LEVEL="${PRODUCTION_ACCEPTANCE_LEVEL:-full}"
PRODUCTION_ACCEPTANCE_RESULT_ROOT="${PRODUCTION_ACCEPTANCE_RESULT_ROOT:-${RESULT_ROOT:-${SCRIPT_DIR}/results/production-acceptance}}"
PRODUCTION_ACCEPTANCE_RESULT_ROOT="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve())' "${PRODUCTION_ACCEPTANCE_RESULT_ROOT}")"
PRODUCTION_ACCEPTANCE_RUN_ID="${PRODUCTION_ACCEPTANCE_RUN_ID:-production-acceptance-$(date -u +%Y%m%dT%H%M%SZ)}"
PRODUCTION_ACCEPTANCE_RUN_DIR="${PRODUCTION_ACCEPTANCE_RUN_DIR:-${PRODUCTION_ACCEPTANCE_RESULT_ROOT}/${PRODUCTION_ACCEPTANCE_RUN_ID}}"
PRODUCTION_ACCEPTANCE_RUN_DIR="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve())' "${PRODUCTION_ACCEPTANCE_RUN_DIR}")"
PRODUCTION_ACCEPTANCE_READINESS_RUNNER="${PRODUCTION_ACCEPTANCE_READINESS_RUNNER:-${SCRIPT_DIR}/run_current_production_readiness.sh}"
PRODUCTION_ACCEPTANCE_PACKAGE_RUNNER="${PRODUCTION_ACCEPTANCE_PACKAGE_RUNNER:-${SCRIPT_DIR}/package_production_evidence.sh}"
PRODUCTION_ACCEPTANCE_PACKAGE_EVIDENCE="${PRODUCTION_ACCEPTANCE_PACKAGE_EVIDENCE:-true}"
PRODUCTION_ACCEPTANCE_PACKAGE_DIR="${PRODUCTION_ACCEPTANCE_PACKAGE_DIR:-${PRODUCTION_ACCEPTANCE_RESULT_ROOT}/production-evidence}"
PRODUCTION_ACCEPTANCE_PACKAGE="${PRODUCTION_ACCEPTANCE_PACKAGE:-}"
PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_RULES_FILE="${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_RULES_FILE:-${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_FILE:-${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_FILE:-${CLOUD_SECURITY_GROUP_RULES_FILE:-}}}}"
PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS="${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS:-${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS:-${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS:-86400}}}"
PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER="${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER:-true}"
PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON:-${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON:-/var/lib/imserver/cloud-security-group/repairs/latest-repair-receipt.json}}"
PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS="${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS:-${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS:-${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS:-86400}}}"
PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID="${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID:-${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID:-${ALIYUN_SECURITY_GROUP_ID:-}}}"
PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID="${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID:-${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID:-${ALIYUN_REGION_ID:-}}}"
PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR="${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR:-${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR:-${ALIYUN_SECURITY_GROUP_ADMIN_CIDR:-}}}"
PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${PRODUCTION_ACCEPTANCE_RECEIPT_JSON:-${PRODUCTION_ACCEPTANCE_RUN_DIR}/production-acceptance.json}"
PRODUCTION_ACCEPTANCE_RECEIPT_MD="${PRODUCTION_ACCEPTANCE_RECEIPT_MD:-${PRODUCTION_ACCEPTANCE_RUN_DIR}/production-acceptance.md}"
PRODUCTION_ACCEPTANCE_VERIFY_RECEIPT="${PRODUCTION_ACCEPTANCE_VERIFY_RECEIPT:-true}"
PRODUCTION_ACCEPTANCE_RECEIPT_VERIFIER="${PRODUCTION_ACCEPTANCE_RECEIPT_VERIFIER:-${SCRIPT_DIR}/perf_production_acceptance_verify.py}"
PRODUCTION_ACCEPTANCE_RECEIPT_MAX_AGE_SECONDS="${PRODUCTION_ACCEPTANCE_RECEIPT_MAX_AGE_SECONDS:-${PERF_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS:-86400}}"
PRODUCTION_ACCEPTANCE_RECEIPT_MAX_FUTURE_SKEW_SECONDS="${PRODUCTION_ACCEPTANCE_RECEIPT_MAX_FUTURE_SKEW_SECONDS:-${PERF_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS:-300}}"

BASE_URL="${BASE_URL:-${PUBLIC_BASE_URL:-${IM_PUBLIC_BASE_URL:-}}}"
TCP_PORT="${TCP_PORT:-${IM_TCP_PORT:-9000}}"
ACCOUNT_FILE="${ACCOUNT_FILE:-}"
IM_CONVERSATION_ID="${IM_CONVERSATION_ID:-}"
IM_INTERNAL_SECRET="${IM_INTERNAL_SECRET:-${IM_INTERNAL_SHARED_SECRET:-}}"
TCP_HOST="${TCP_HOST:-${IM_PUBLIC_HOST:-}}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

run_self_test_child() {
  local log="$1"
  shift
  if ! "$@" >"${log}" 2>&1; then
    cat "${log}" >&2 || true
    return 1
  fi
}

usage() {
  cat <<'EOF'
Usage:
  BASE_URL=https://chat.prod.company.com \
  TCP_HOST=tcp.prod.company.com \
  ACCOUNT_FILE=accounts/load-10000.csv \
  IM_CONVERSATION_ID=<conversation-id> \
  IM_INTERNAL_SECRET=<internal-secret> \
  CLOUD_SECURITY_GROUP_RULES_FILE=/etc/imserver/cloud-security-group.json \
    ./run_production_acceptance.sh
  Replace prod.company.com examples before running; production gates reject literal placeholder domains.

Common env:
  PRODUCTION_ACCEPTANCE_LEVEL=full|baseline
  PRODUCTION_ACCEPTANCE_RESULT_ROOT=results/production-acceptance
  PRODUCTION_ACCEPTANCE_RUN_ID=production-acceptance-<timestamp>
  PRODUCTION_ACCEPTANCE_PACKAGE_EVIDENCE=true|false
  PRODUCTION_ACCEPTANCE_PACKAGE=/path/production-evidence.tar.gz
  PRODUCTION_ACCEPTANCE_RECEIPT_JSON=results/.../production-acceptance.json
  PRODUCTION_ACCEPTANCE_RECEIPT_MD=results/.../production-acceptance.md
  PRODUCTION_ACCEPTANCE_VERIFY_RECEIPT=true|false
  PRODUCTION_ACCEPTANCE_RECEIPT_MAX_AGE_SECONDS=86400
  PRODUCTION_ACCEPTANCE_RECEIPT_MAX_FUTURE_SKEW_SECONDS=300
  PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_RULES_FILE=/path/cloud-security-group.json
  PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON=/path/cloud-security-group-repair-receipt.json
  PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS=86400
  PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=sg-...
  PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=cn-shenzhen
  PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=<your-admin-public-ip>/32
  BASE_URL=https://public-domain
  TCP_HOST=tcp-public-domain
  TCP_PORT=9000
  ACCOUNT_FILE=/path/load-10000.csv
  IM_CONVERSATION_ID=<valid-non-nil-conversation-uuid>
  IM_INTERNAL_SECRET=<secret>

Purpose:
  Run the final production acceptance path with packageable evidence enabled.
  This wrapper intentionally requires a real HTTPS DNS name, a DNS TCP host,
  a cloud security group snapshot, operator-network preflight, current
  production readiness, a non-placeholder conversation UUID, and a portable
  evidence package.
EOF
}

safe_file_token() {
  python3 - "$1" <<'PY'
import re
import sys

value = re.sub(r"[^A-Za-z0-9_.-]+", "-", sys.argv[1].strip())
value = value.strip(".-")
print(value or "production-acceptance")
PY
}

host_from_url() {
  python3 - "$1" <<'PY'
from urllib.parse import urlparse
import sys

print(urlparse(sys.argv[1]).hostname or "")
PY
}

usable_account_rows() {
  local account_file="$1"
  if [[ -z "${account_file}" || ! -f "${account_file}" ]]; then
    printf '0\n'
    return 0
  fi
  python3 - "${account_file}" <<'PY'
import csv
import sys
from pathlib import Path

path = Path(sys.argv[1])
count = 0
try:
    with path.open(newline="", encoding="utf-8") as handle:
        for row in csv.reader(handle):
            if len(row) >= 2 and row[0].strip() and row[1].strip():
                count += 1
except Exception:
    count = 0
print(count)
PY
}

conversation_id_reason() {
  local conversation_id="$1"
  if [[ -z "${conversation_id}" ]]; then
    printf 'missing\n'
    return 0
  fi
  python3 - "${conversation_id}" <<'PY'
import sys
import uuid

value = sys.argv[1].strip()
try:
    parsed = uuid.UUID(value)
except ValueError:
    print("invalid_uuid")
    raise SystemExit(0)
if parsed.int == 0:
    print("nil_uuid")
else:
    print("")
PY
}

validate_public_target() {
  python3 "${PRODUCTION_TARGET_POLICY}" \
    --base-url "${BASE_URL}" \
    --tcp-host "${TCP_HOST}" \
    --tcp-port "${TCP_PORT}" \
    --result-prefix "production_acceptance"
}

validate_required_input() {
  local required_rows="$1"
  case "${PRODUCTION_ACCEPTANCE_LEVEL}" in
    full|baseline) ;;
    *)
      printf 'production_acceptance result=fail reason=invalid_level level=%s expected=full_or_baseline\n' \
        "${PRODUCTION_ACCEPTANCE_LEVEL}" >&2
      return 2
      ;;
  esac

  if [[ -z "${BASE_URL}" ]]; then
    printf 'production_acceptance result=fail reason=base_url_required\n' >&2
    return 2
  fi
  if [[ -z "${TCP_HOST}" ]]; then
    TCP_HOST="$(host_from_url "${BASE_URL}")"
  fi
  validate_public_target
  if [[ -z "${ACCOUNT_FILE}" || ! -f "${ACCOUNT_FILE}" ]]; then
    printf 'production_acceptance result=fail reason=account_file_missing path=%s\n' "${ACCOUNT_FILE:-<empty>}" >&2
    return 2
  fi
  local account_rows
  account_rows="$(usable_account_rows "${ACCOUNT_FILE}")"
  if (( account_rows < required_rows )); then
    printf 'production_acceptance result=fail reason=account_file_too_small rows=%s required=%s level=%s path=%s\n' \
      "${account_rows}" \
      "${required_rows}" \
      "${PRODUCTION_ACCEPTANCE_LEVEL}" \
      "${ACCOUNT_FILE}" >&2
    return 2
  fi
  if [[ -z "${IM_CONVERSATION_ID}" ]]; then
    printf 'production_acceptance result=fail reason=conversation_id_required\n' >&2
    return 2
  fi
  local conversation_reason
  conversation_reason="$(conversation_id_reason "${IM_CONVERSATION_ID}")"
  if [[ -n "${conversation_reason}" ]]; then
    printf 'production_acceptance result=fail reason=conversation_id_invalid detail=%s value=%s\n' \
      "${conversation_reason}" \
      "${IM_CONVERSATION_ID}" >&2
    return 2
  fi
  if [[ -z "${IM_INTERNAL_SECRET}" ]]; then
    printf 'production_acceptance result=fail reason=internal_secret_required\n' >&2
    return 2
  fi
  if [[ -z "${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_RULES_FILE}" ]]; then
    printf 'production_acceptance result=fail reason=cloud_security_group_snapshot_required\n' >&2
    return 2
  fi
  if [[ ! -f "${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_RULES_FILE}" ]]; then
    printf 'production_acceptance result=fail reason=cloud_security_group_snapshot_missing path=%s\n' \
      "${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_RULES_FILE}" >&2
    return 2
  fi
  if [[ -z "${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON}" ]]; then
    printf 'production_acceptance result=fail reason=cloud_security_group_repair_receipt_required\n' >&2
    return 2
  fi
  if [[ ! -f "${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON}" ]]; then
    printf 'production_acceptance result=fail reason=cloud_security_group_repair_receipt_missing path=%s\n' \
      "${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON}" >&2
    return 2
  fi
  if [[ -z "${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID}" ]]; then
    printf 'production_acceptance result=fail reason=cloud_security_group_repair_receipt_expected_security_group_id_required\n' >&2
    return 2
  fi
  if [[ -z "${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID}" ]]; then
    printf 'production_acceptance result=fail reason=cloud_security_group_repair_receipt_expected_region_id_required\n' >&2
    return 2
  fi
  if [[ -z "${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR}" ]]; then
    printf 'production_acceptance result=fail reason=cloud_security_group_repair_receipt_expected_admin_cidr_required\n' >&2
    return 2
  fi
  if [[ ! -f "${PRODUCTION_ACCEPTANCE_READINESS_RUNNER}" ]]; then
    printf 'production_acceptance result=fail reason=readiness_runner_missing path=%s\n' \
      "${PRODUCTION_ACCEPTANCE_READINESS_RUNNER}" >&2
    return 2
  fi
  if bool_enabled "${PRODUCTION_ACCEPTANCE_PACKAGE_EVIDENCE}" && [[ ! -f "${PRODUCTION_ACCEPTANCE_PACKAGE_RUNNER}" ]]; then
    printf 'production_acceptance result=fail reason=package_runner_missing path=%s\n' \
      "${PRODUCTION_ACCEPTANCE_PACKAGE_RUNNER}" >&2
    return 2
  fi
  if bool_enabled "${PRODUCTION_ACCEPTANCE_VERIFY_RECEIPT}" && [[ ! -f "${PRODUCTION_ACCEPTANCE_RECEIPT_VERIFIER}" ]]; then
    printf 'production_acceptance result=fail reason=receipt_verifier_missing path=%s\n' \
      "${PRODUCTION_ACCEPTANCE_RECEIPT_VERIFIER}" >&2
    return 2
  fi
}

write_acceptance_receipt() {
  local status="$1"
  local reason="$2"
  local required_rows="$3"
  local run_full_acceptance="$4"
  local readiness_rc="$5"
  local package_rc="$6"
  local package_path="$7"
  local readiness_log="$8"
  local package_log="$9"
  mkdir -p "$(dirname "${PRODUCTION_ACCEPTANCE_RECEIPT_JSON}")"
  python3 - \
    "${PRODUCTION_ACCEPTANCE_RECEIPT_JSON}" \
    "${PRODUCTION_ACCEPTANCE_RECEIPT_MD}" \
    "${status}" \
    "${reason}" \
    "${PRODUCTION_ACCEPTANCE_LEVEL}" \
    "${BASE_URL}" \
    "${TCP_HOST}" \
    "${TCP_PORT}" \
    "${ACCOUNT_FILE}" \
    "${IM_CONVERSATION_ID}" \
    "${PRODUCTION_ACCEPTANCE_RESULT_ROOT}" \
    "${PRODUCTION_ACCEPTANCE_RUN_ID}" \
    "${PRODUCTION_ACCEPTANCE_RUN_DIR}" \
    "${required_rows}" \
    "${run_full_acceptance}" \
    "${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_RULES_FILE}" \
    "${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS}" \
    "${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER}" \
    "${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON}" \
    "${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS}" \
    "${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID}" \
    "${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID}" \
    "${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR}" \
    "${PRODUCTION_ACCEPTANCE_RECEIPT_MAX_AGE_SECONDS}" \
    "${PRODUCTION_ACCEPTANCE_RECEIPT_MAX_FUTURE_SKEW_SECONDS}" \
    "${readiness_rc}" \
    "${package_rc}" \
    "${package_path}" \
    "${readiness_log}" \
    "${package_log}" <<'PY'
import json
import sys
import time
from pathlib import Path

(
    receipt_json,
    receipt_md,
    status,
    reason,
    level,
    base_url,
    tcp_host,
    tcp_port,
    account_file,
    conversation_id,
    result_root,
    run_id,
    run_dir,
    required_rows,
    run_full_acceptance,
    cloud_security_group_rules_file,
    cloud_security_group_rules_max_age_seconds,
    cloud_security_group_rules_require_root_owner,
    cloud_security_group_repair_receipt_json,
    cloud_security_group_repair_receipt_max_age_seconds,
    cloud_security_group_repair_receipt_expect_security_group_id,
    cloud_security_group_repair_receipt_expect_region_id,
    cloud_security_group_repair_receipt_expect_admin_cidr,
    receipt_max_age_seconds,
    receipt_max_future_skew_seconds,
    readiness_rc,
    package_rc,
    package_path,
    readiness_log,
    package_log,
) = sys.argv[1:31]

run_dir_path = Path(run_dir)
package_file = Path(package_path) if package_path else None
package_bytes = 0
package_sha256 = ""
if package_file and package_file.is_file():
    import hashlib

    package_bytes = package_file.stat().st_size
    digest = hashlib.sha256()
    with package_file.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    package_sha256 = digest.hexdigest()
readiness_json = run_dir_path / "current-production-readiness.json"
readiness_md = run_dir_path / "current-production-readiness.md"
payload = {
    "schemaVersion": 1,
    "status": status,
    "reason": reason,
    "generatedAtEpoch": int(time.time()),
    "level": level,
    "target": {
        "baseURL": base_url,
        "tcpHost": tcp_host,
        "tcpPort": tcp_port,
        "accountFile": account_file,
        "conversationIDPresent": bool(conversation_id),
        "requiredAccountRows": int(required_rows or 0),
    },
    "policy": {
        "requirePackageableEvidence": True,
        "requireCloudSecurityGroup": True,
        "requireCloudSecurityGroupRepairReceipt": True,
        "requirePublicPortPolicy": True,
        "allowTempHTTP8080": False,
        "operatorNetworkPreflight": True,
        "receiptMaxAgeSeconds": int(receipt_max_age_seconds or 0),
        "receiptMaxFutureSkewSeconds": int(receipt_max_future_skew_seconds or 0),
        "runSmoke": True,
        "runProductScenarioSuite": True,
        "runBaseline": True,
        "runFullAcceptance": run_full_acceptance.lower() in {"1", "true", "yes", "on"},
        "fullAcceptanceCampaign": "production-full-acceptance",
        "cloudSecurityGroupRulesFile": cloud_security_group_rules_file,
        "cloudSecurityGroupRulesMaxAgeSeconds": int(cloud_security_group_rules_max_age_seconds or 0),
        "cloudSecurityGroupRulesRequireRootOwner": cloud_security_group_rules_require_root_owner.lower() in {"1", "true", "yes", "on"},
        "cloudSecurityGroupRepairReceiptJSON": cloud_security_group_repair_receipt_json,
        "cloudSecurityGroupRepairReceiptMaxAgeSeconds": int(cloud_security_group_repair_receipt_max_age_seconds or 0),
        "cloudSecurityGroupRepairReceiptExpectSecurityGroupID": cloud_security_group_repair_receipt_expect_security_group_id,
        "cloudSecurityGroupRepairReceiptExpectRegionID": cloud_security_group_repair_receipt_expect_region_id,
        "cloudSecurityGroupRepairReceiptExpectAdminCIDR": cloud_security_group_repair_receipt_expect_admin_cidr,
    },
    "artifacts": {
        "runDir": run_dir,
        "readinessLog": readiness_log,
        "readinessJSON": str(readiness_json) if readiness_json.is_file() else "",
        "readinessMarkdown": str(readiness_md) if readiness_md.is_file() else "",
        "packageLog": package_log,
        "package": str(package_file) if package_file else "",
        "packageFileName": package_file.name if package_file else "",
        "packagePresent": bool(package_file and package_file.is_file()),
        "packageBytes": package_bytes,
        "packageSha256": package_sha256,
        "receiptJSON": receipt_json,
        "receiptMarkdown": receipt_md,
    },
    "commands": {
        "readinessExitCode": None if readiness_rc == "-" else int(readiness_rc),
        "packageExitCode": None if package_rc == "-" else int(package_rc),
    },
}
Path(receipt_json).write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
lines = [
    "# Production Acceptance",
    "",
    f"- status: `{status}`",
    f"- reason: `{reason}`",
    f"- level: `{level}`",
    f"- baseURL: `{base_url}`",
    f"- tcpHost: `{tcp_host}`",
    f"- tcpPort: `{tcp_port}`",
    f"- requiredAccountRows: `{required_rows}`",
    f"- runFullAcceptance: `{payload['policy']['runFullAcceptance']}`",
    f"- cloudSecurityGroupRulesFile: `{cloud_security_group_rules_file}`",
    f"- cloudSecurityGroupRepairReceiptJSON: `{cloud_security_group_repair_receipt_json}`",
    f"- readinessExitCode: `{payload['commands']['readinessExitCode'] if payload['commands']['readinessExitCode'] is not None else '-'}`",
    f"- packageExitCode: `{payload['commands']['packageExitCode'] if payload['commands']['packageExitCode'] is not None else '-'}`",
    f"- readinessJSON: `{payload['artifacts']['readinessJSON'] or '-'}`",
    f"- readinessLog: `{readiness_log or '-'}`",
    f"- package: `{payload['artifacts']['package'] or '-'}`",
    f"- packagePresent: `{payload['artifacts']['packagePresent']}`",
    f"- packageBytes: `{payload['artifacts']['packageBytes']}`",
    f"- packageSha256: `{payload['artifacts']['packageSha256'] or '-'}`",
    f"- packageLog: `{package_log or '-'}`",
    "",
]
Path(receipt_md).write_text("\n".join(lines), encoding="utf-8")
PY
}

run_acceptance() {
  local run_full_acceptance="false"
  local required_rows="5000"
  local safe_run_id package_path readiness_log package_log readiness_rc package_rc
  if [[ "${PRODUCTION_ACCEPTANCE_LEVEL}" == "full" ]]; then
    run_full_acceptance="true"
    required_rows="10000"
  fi
  validate_required_input "${required_rows}"

  safe_run_id="$(safe_file_token "${PRODUCTION_ACCEPTANCE_RUN_ID}")"
  package_path="${PRODUCTION_ACCEPTANCE_PACKAGE}"
  if bool_enabled "${PRODUCTION_ACCEPTANCE_PACKAGE_EVIDENCE}" && [[ -z "${package_path}" ]]; then
    package_path="${PRODUCTION_ACCEPTANCE_PACKAGE_DIR}/production-evidence-${safe_run_id}.tar.gz"
  fi
  readiness_log="${PRODUCTION_ACCEPTANCE_RUN_DIR}/production-acceptance-readiness.log"
  package_log="${PRODUCTION_ACCEPTANCE_RUN_DIR}/production-acceptance-package.log"

  mkdir -p "${PRODUCTION_ACCEPTANCE_RESULT_ROOT}" "${PRODUCTION_ACCEPTANCE_RUN_DIR}"
  printf 'production_acceptance start level=%s baseURL=%s tcpHost=%s tcpPort=%s resultRoot=%s requiredRows=%s packageEvidence=%s\n' \
    "${PRODUCTION_ACCEPTANCE_LEVEL}" \
    "${BASE_URL}" \
    "${TCP_HOST}" \
    "${TCP_PORT}" \
    "${PRODUCTION_ACCEPTANCE_RESULT_ROOT}" \
    "${required_rows}" \
    "${PRODUCTION_ACCEPTANCE_PACKAGE_EVIDENCE}"

  set +e
  RESULT_ROOT="${PRODUCTION_ACCEPTANCE_RESULT_ROOT}" \
  RUN_ID="${PRODUCTION_ACCEPTANCE_RUN_ID}" \
  RUN_DIR="${PRODUCTION_ACCEPTANCE_RUN_DIR}" \
  BASE_URL="${BASE_URL}" \
  TCP_HOST="${TCP_HOST}" \
  TCP_PORT="${TCP_PORT}" \
  ACCOUNT_FILE="${ACCOUNT_FILE}" \
  IM_CONVERSATION_ID="${IM_CONVERSATION_ID}" \
  IM_INTERNAL_SECRET="${IM_INTERNAL_SECRET}" \
  CURRENT_PRODUCTION_REQUIRE_PACKAGEABLE_EVIDENCE=true \
  CURRENT_PRODUCTION_REQUIRE_CLOUD_SECURITY_GROUP=true \
  CURRENT_PRODUCTION_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT=true \
  CURRENT_PRODUCTION_REQUIRE_PUBLIC_PORT_POLICY=true \
  CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_FILE="${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_RULES_FILE}" \
  CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS="${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS}" \
  CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER="${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER}" \
  CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON}" \
  CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS="${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS}" \
  CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID="${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID}" \
  CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID="${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID}" \
  CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR="${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR}" \
  CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080=false \
  CURRENT_PRODUCTION_OPERATOR_NETWORK_PREFLIGHT=true \
  CURRENT_PRODUCTION_FAIL_ON_OPERATOR_NETWORK=true \
  CURRENT_PRODUCTION_RUN_SMOKE=true \
  CURRENT_PRODUCTION_RUN_SCENARIO_SUITE=true \
  CURRENT_PRODUCTION_SCENARIO_SUITE=recommended \
  CURRENT_PRODUCTION_RUN_BASELINE=true \
  CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE="${run_full_acceptance}" \
  CURRENT_PRODUCTION_FULL_ACCEPTANCE_CAMPAIGN=production-full-acceptance \
  CURRENT_PRODUCTION_VERIFY_ARTIFACTS=true \
    bash "${PRODUCTION_ACCEPTANCE_READINESS_RUNNER}" 2>&1 | tee "${readiness_log}"
  readiness_rc="${PIPESTATUS[0]}"
  set -e
  if [[ "${readiness_rc}" -ne 0 ]]; then
    write_acceptance_receipt "FAIL" "current_readiness_failed" "${required_rows}" "${run_full_acceptance}" "${readiness_rc}" "-" "${package_path}" "${readiness_log}" ""
    return "${readiness_rc}"
  fi

  if bool_enabled "${PRODUCTION_ACCEPTANCE_PACKAGE_EVIDENCE}"; then
    set +e
    RESULT_ROOT="${PRODUCTION_ACCEPTANCE_RESULT_ROOT}" \
    BASE_URL="${BASE_URL}" \
    TCP_HOST="${TCP_HOST}" \
    TCP_PORT="${TCP_PORT}" \
    PUBLIC_BASE_URL="${BASE_URL}" \
    IM_PUBLIC_HOST="${TCP_HOST}" \
    PERF_PRODUCTION_GATE_EXPECT_BASE_URL="${BASE_URL}" \
    PERF_PRODUCTION_GATE_EXPECT_TCP_HOST="${TCP_HOST}" \
    PERF_PRODUCTION_GATE_EXPECT_TCP_PORT="${TCP_PORT}" \
    PRODUCTION_EVIDENCE_OUTPUT_DIR="${PRODUCTION_ACCEPTANCE_PACKAGE_DIR}" \
    PRODUCTION_EVIDENCE_PACKAGE="${package_path}" \
    PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS=true \
    PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS=true \
    PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP=true \
    PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS=true \
    PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS=true \
    PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP=true \
    PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_FILE="${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_RULES_FILE}" \
    PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS="${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS}" \
    PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER="${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER}" \
    PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON}" \
    PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS="${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS}" \
    PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID="${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID}" \
    PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID="${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID}" \
    PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR="${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR}" \
    PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080=false \
      bash "${PRODUCTION_ACCEPTANCE_PACKAGE_RUNNER}" 2>&1 | tee "${package_log}"
    package_rc="${PIPESTATUS[0]}"
    set -e
    if [[ "${package_rc}" -ne 0 ]]; then
      write_acceptance_receipt "FAIL" "evidence_package_failed" "${required_rows}" "${run_full_acceptance}" "${readiness_rc}" "${package_rc}" "${package_path}" "${readiness_log}" "${package_log}"
      return "${package_rc}"
    fi
  else
    package_rc="-"
  fi

  write_acceptance_receipt "PASS" "accepted" "${required_rows}" "${run_full_acceptance}" "${readiness_rc}" "${package_rc}" "${package_path}" "${readiness_log}" "${package_log}"
  if bool_enabled "${PRODUCTION_ACCEPTANCE_VERIFY_RECEIPT}"; then
    python3 "${PRODUCTION_ACCEPTANCE_RECEIPT_VERIFIER}" \
      --receipt-json "${PRODUCTION_ACCEPTANCE_RECEIPT_JSON}" \
      --package-file "${package_path}" \
      --max-age-seconds "${PRODUCTION_ACCEPTANCE_RECEIPT_MAX_AGE_SECONDS}" \
      --max-future-skew-seconds "${PRODUCTION_ACCEPTANCE_RECEIPT_MAX_FUTURE_SKEW_SECONDS}" \
      --require-pass
  fi
  printf 'production_acceptance result=pass level=%s resultRoot=%s packageDir=%s\n' \
    "${PRODUCTION_ACCEPTANCE_LEVEL}" \
    "${PRODUCTION_ACCEPTANCE_RESULT_ROOT}" \
    "${PRODUCTION_ACCEPTANCE_PACKAGE_DIR}"
}

run_self_test() {
  local tmpdir account_file sg_file repair_receipt_file repair_plan_file repair_post_apply_file fake_readiness fake_package fake_verifier log
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' RETURN
  account_file="${tmpdir}/accounts.csv"
  sg_file="${tmpdir}/cloud-security-group.json"
  repair_receipt_file="${tmpdir}/cloud-security-group-repair-receipt.json"
  repair_plan_file="${tmpdir}/cloud-security-group-repair-plan.json"
  repair_post_apply_file="${tmpdir}/cloud-security-group-post-apply.json"
  fake_readiness="${tmpdir}/fake-readiness.sh"
  fake_package="${tmpdir}/fake-package.sh"
  fake_verifier="${tmpdir}/fake-verifier.sh"
  log="${tmpdir}/run.log"

  python3 - "${account_file}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
with path.open("w", encoding="utf-8") as handle:
    for index in range(1, 10001):
        handle.write(f"user{index:05d}@example.com,password\n")
PY
  cat >"${sg_file}" <<'JSON'
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
  cp "${sg_file}" "${repair_post_apply_file}"
  python3 - "${sg_file}" "${repair_plan_file}" "${repair_post_apply_file}" "${repair_receipt_file}" <<'PY'
import hashlib
import json
import sys
import time
from pathlib import Path

snapshot_path, plan_path, post_apply_path, receipt_path = map(Path, sys.argv[1:5])
plan = {
    "schemaVersion": 1,
    "securityGroupId": "sg-production-acceptance-selftest",
    "snapshot": str(snapshot_path),
    "adminCidr": "203.0.113.10/32",
    "publicClientPorts": [80, 443, 9000],
    "adminPorts": [22],
    "denyPublicPorts": [22, 3389, 5432, 6379, 8080, 8081, 8082, 9092, 18080],
    "status": "NOOP",
    "regionId": "cn-shenzhen",
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
    "securityGroupId": "sg-production-acceptance-selftest",
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
  cat >"${fake_readiness}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
env | sort >"${PRODUCTION_ACCEPTANCE_SELF_TEST_CAPTURE_DIR}/readiness.env"
mkdir -p "${RESULT_ROOT}/${RUN_ID}"
python3 - "${RESULT_ROOT}/${RUN_ID}/current-production-readiness.json" "${RESULT_ROOT}/${RUN_ID}/current-readiness-entrypoint-probe.json" "${RESULT_ROOT}/${RUN_ID}/current-readiness-cloud-security-group-repair-receipt-verify.log" "${CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE}" "${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON}" "${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS}" <<'PY'
import json
import os
import sys
import time
from pathlib import Path

path, probe_path, repair_verify_log, run_full, repair_receipt, repair_receipt_max_age_seconds = sys.argv[1:7]
is_full = run_full.lower() in {"1", "true", "yes", "on"}
run_dir = Path(path).parent
operator_log = run_dir / "current-readiness-operator-network.log"
operator_json = run_dir / "current-readiness-operator-network.json"
cloud_security_group_audit_log = run_dir / "current-readiness-cloud-security-group-audit.log"
smoke_log = run_dir / "current-readiness-normal-product-smoke.log"
suite_log = run_dir / "current-readiness-product-scenario-suite.log"
baseline_log = run_dir / "current-readiness-normal-product-baseline.log"
full_acceptance_log = run_dir / "current-readiness-production-full-acceptance.log"
suite_run_json = run_dir / "product-scenario-suite-run.json"
suite_run_md = run_dir / "product-scenario-suite-run.md"
full_acceptance_run_json = run_dir / "current-readiness-full-acceptance-run.json"
full_acceptance_runbook = run_dir / "current-readiness-full-acceptance-runbook.md"
dashboard_json = run_dir / "current-production-dashboard.json"
dashboard_md = run_dir / "current-production-dashboard.md"
state_summary_json = run_dir / "current-production-state-summary.json"
state_summary_md = run_dir / "current-production-state-summary.md"
state_summary_csv = run_dir / "current-production-state-summary.csv"
base_url = os.environ.get("BASE_URL", "https://chat.myim-prod.com")
tcp_host = os.environ.get("TCP_HOST", "tcp.myim-prod.com")
tcp_port = os.environ.get("TCP_PORT", "9000")
load_tests_dir = Path(os.environ.get("PRODUCTION_ACCEPTANCE_LOAD_TESTS_DIR", "IMServer/LoadTests")).resolve()
sys.path.insert(0, str(load_tests_dir))
from run_product_campaign import build_runbook
cloud_security_group_rules_file = os.environ.get("CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_FILE", "")
cloud_security_group_rules_max_age_seconds = int(os.environ.get("CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS", "0") or 0)
cloud_security_group_rules_require_root_owner = os.environ.get("CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER", "false").lower() in {"1", "true", "yes", "on"}
expected_security_group_id = os.environ.get("CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID", "")
expected_region_id = os.environ.get("CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID", "")
expected_admin_cidr = os.environ.get("CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR", "")
allow_temp_http_8080 = os.environ.get("CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080", "false").lower() in {"1", "true", "yes", "on"}
Path(probe_path).write_text(json.dumps({
    "schemaVersion": 1,
    "failed": False,
    "diagnosis": "ok",
    "publicPortPolicyStatus": "pass",
    "publicDeniedPortsOpen": [],
    "publicExpectedPortsMissing": [],
}), encoding="utf-8")
Path(repair_verify_log).write_text("cloud_security_group_repair_receipt result=pass\n", encoding="utf-8")
cloud_security_group_audit_log.write_text("cloud_security_group_audit result=pass\n", encoding="utf-8")
operator_log.write_text(
    "operator-network target=https://chat.myim-prod.com host=chat.myim-prod.com status=pass warning=clean routeInterface=en0 routeGateway=192.168.1.1 proxyEnv=<none>\n"
    "operator-network result=pass targets=2\n",
    encoding="utf-8",
)
operator_json.write_text(json.dumps({
    "schemaVersion": 1,
    "status": "pass",
    "failed": False,
    "failureCount": 0,
    "targetCount": 2,
    "warnings": [],
    "warningCounts": {},
    "routeInterfaces": ["en0"],
    "routeGateways": ["192.168.1.1"],
    "failedTargets": [],
    "targets": [
        {
            "target": "https://chat.myim-prod.com",
            "host": "chat.myim-prod.com",
            "status": "pass",
            "warning": "clean",
            "routeInterface": "en0",
            "routeGateway": "192.168.1.1",
            "proxyEnv": "<none>",
        }
    ],
    "action": "",
}), encoding="utf-8")
smoke_log.write_text("smoke pass\n", encoding="utf-8")
suite_log.write_text("suite pass\n", encoding="utf-8")
baseline_log.write_text("baseline pass\n", encoding="utf-8")
full_acceptance_log.write_text("full acceptance pass\n", encoding="utf-8")
required_domains = [
    "account-security",
    "sync-read",
    "direct-chat",
    "group-workflow",
    "contacts-social",
    "media-ai-admin",
    "reliability-recovery",
    "realtime-direct",
]
suite_run_json.write_text(json.dumps({
    "schemaVersion": 1,
    "suite": "recommended",
    "status": "PASS",
    "reason": "all_stages_passed",
    "settings": {"dryRun": False, "execute": True, "stopOnFailure": True, "includeLargeGroup": False},
    "target": {"baseURL": base_url, "tcpHost": tcp_host, "tcpPort": tcp_port},
    "stageCount": 1,
    "failedStageCount": 0,
    "plannedStageCount": 0,
    "coverageSummary": {
        "stageCount": 1,
        "productPlanStageCount": 1,
        "coverageErrorCount": 0,
        "uniqueScenarioCount": 8,
        "largeGroupIncluded": False,
        "coveredProductDomains": required_domains,
        "requiredProductDomains": required_domains,
        "missingProductDomains": [],
        "requiredProductDomainsCovered": True,
    },
    "failureSummary": [],
    "stageCoverage": [{
        "stage": "normal-smoke",
        "runner": "product-plan",
        "value": "normal-smoke",
        "coverageStatus": "READY",
        "uniqueScenarioCount": 8,
        "largeGroupIncluded": False,
        "coveredProductDomains": required_domains,
        "requiredProductDomains": required_domains,
        "missingProductDomains": [],
        "requiredProductDomainsCovered": True,
        "selectedScenarios": ["login-smoke"],
        "sampleScenarios": ["login-smoke"],
    }],
    "stages": [{
        "id": "normal-smoke",
        "runner": "product-plan",
        "value": "normal-smoke",
        "description": "Fast smoke",
        "runDir": ".",
        "status": "PASS",
        "exitCode": 0,
    }],
}, indent=2, sort_keys=True), encoding="utf-8")
suite_run_md.write_text(
    "# Product Scenario Suite Run\n\n"
    "- suite: `recommended`\n"
    "- status: `PASS`\n\n"
    "## Coverage\n\n"
    "- `normal-smoke`\n",
    encoding="utf-8",
)
full_stage_ids = [
    "normal-product-smoke",
    "normal-product-plan",
    "normal-product-baseline",
    "normal-product-capacity",
    "message-realtime-capacity",
    "large-group-isolated",
]
full_stages = []
for index, stage_id in enumerate(full_stage_ids, start=1):
    is_large = stage_id == "large-group-isolated"
    command = (
        f"env BASE_URL={base_url} TCP_HOST={tcp_host} TCP_PORT={tcp_port} "
        "IM_INTERNAL_SECRET=<redacted> SCENARIO_GROUPS=large-group ./run_perf_scenarios.sh"
        if is_large else
        f"env BASE_URL={base_url} TCP_HOST={tcp_host} TCP_PORT={tcp_port} "
        f"IM_INTERNAL_SECRET=<redacted> PRODUCT_TEST_PHASES={stage_id} ./run_product_test_plan.sh"
    )
    full_stages.append({
        "index": index,
        "id": stage_id,
        "runner": "scenario-group" if is_large else "product-plan",
        "required": True,
        "isolated": is_large,
        "status": "PASS",
        "returnCode": 0,
        "runDir": str(run_dir / f"{index:02d}-{stage_id}"),
        "log": str(run_dir / f"{index:02d}-{stage_id}" / "stage.log"),
        "command": command,
        "evidence": "self-test",
        "packageEvidenceProfile": False,
        "packageEvidenceProductPlan": False,
        "skipReason": "",
    })
full_acceptance_payload = {
    "schemaVersion": 1,
    "generatedAt": "2026-01-01T00:00:00Z",
    "campaign": "production-full-acceptance",
    "description": "production acceptance wrapper self-test",
    "campaignCatalog": str(load_tests_dir / "perf_product_campaigns.json"),
    "execute": True,
    "stopOnFailure": True,
    "resultDir": str(run_dir),
    "runIDPrefix": "production-acceptance-wrapper-self-test",
    "target": {
        "baseURL": base_url,
        "tcpHost": tcp_host,
        "tcpPort": tcp_port,
        "accountFile": "/tmp/self-test-accounts.csv",
        "hasConversationID": "true",
        "hasInternalSecret": "true",
    },
    "evidenceRoot": {"enabled": False},
    "finalStatus": "PASS",
    "failureCount": 0,
    "requiredFailureCount": 0,
    "attemptedStageCount": len(full_stages),
    "skippedStageCount": 0,
    "stageCount": len(full_stages),
    "stages": full_stages,
}
full_acceptance_run_json.write_text(json.dumps(full_acceptance_payload, indent=2, sort_keys=True), encoding="utf-8")
full_acceptance_runbook.write_text(build_runbook(full_acceptance_payload), encoding="utf-8")
readiness_summary = {
    "conclusion": "READY",
    "entrypointRescueBlocked": False,
    "entrypointRescueDiagnosis": "",
    "currentReadinessStatus": "PASS",
    "currentReadinessReason": "entrypoint_and_requested_runs_passed",
    "currentReadinessRequestedSmoke": True,
    "currentReadinessRequestedProductScenarioSuite": True,
    "currentReadinessRequestedBaseline": True,
    "currentReadinessRequestedFullAcceptance": is_full,
    "currentReadinessSmokeExitCode": 0,
    "currentReadinessProductScenarioSuiteExitCode": 0,
    "currentReadinessBaselineExitCode": 0,
    "currentReadinessFullAcceptanceExitCode": 0 if is_full else None,
    "currentReadinessProductScenarioSuiteExpected": "recommended",
    "currentReadinessProductScenarioSuite": "recommended",
    "currentReadinessProductScenarioSuiteStatus": "PASS",
    "currentReadinessProductScenarioSuiteStageCount": 1,
    "currentReadinessProductScenarioSuiteFailedStages": 0,
    "currentReadinessProductScenarioSuitePlannedStages": 0,
    "currentReadinessProductScenarioSuiteScenarios": 8,
    "currentReadinessProductScenarioSuiteProductPlanStages": 1,
    "currentReadinessProductScenarioSuiteLargeGroupIncluded": False,
    "currentReadinessFullAcceptanceExpectedCampaign": "production-full-acceptance" if is_full else "",
    "currentReadinessFullAcceptanceCampaign": "production-full-acceptance" if is_full else "",
    "currentReadinessFullAcceptanceStatus": "PASS" if is_full else "",
    "currentReadinessFullAcceptanceFailures": 0 if is_full else "",
    "currentReadinessFullAcceptanceRequiredFailures": 0 if is_full else "",
    "currentReadinessFullAcceptanceAttempted": 6 if is_full else "",
    "currentReadinessFullAcceptanceSkipped": 0 if is_full else "",
    "currentReadinessOperatorNetworkPreflight": True,
    "currentReadinessOperatorNetworkLogPresent": True,
    "currentReadinessOperatorNetworkFailed": False,
    "currentReadinessOperatorNetworkWarnings": [],
    "currentReadinessOperatorNetworkRouteInterfaces": ["en0"],
    "currentReadinessOperatorNetworkRouteGateways": ["192.168.1.1"],
    "currentReadinessOperatorNetworkFailureCount": 0,
    "productionEvidenceBlockerCount": 0,
    "productionEvidenceBlockers": [],
}
dashboard_json.write_text(json.dumps({"summary": readiness_summary, "nextCommand": ""}, indent=2, sort_keys=True), encoding="utf-8")
dashboard_md.write_text("# Current Production Dashboard\n", encoding="utf-8")
state_summary_json.write_text(json.dumps({
    "summary": readiness_summary,
    "productionEvidenceBlockers": [],
    "nextCommand": "",
}, indent=2, sort_keys=True), encoding="utf-8")
state_summary_md.write_text("# Current Production State Summary\n", encoding="utf-8")
state_csv_fields = [
    "recordType",
    "conclusion",
    "currentReadinessStatus",
    "currentReadinessReason",
    "currentReadinessRequestedSmoke",
    "currentReadinessRequestedProductScenarioSuite",
    "currentReadinessRequestedBaseline",
    "currentReadinessRequestedFullAcceptance",
    "currentReadinessSmokeExitCode",
    "currentReadinessProductScenarioSuiteExitCode",
    "currentReadinessBaselineExitCode",
    "currentReadinessFullAcceptanceExitCode",
    "currentReadinessProductScenarioSuiteExpected",
    "currentReadinessProductScenarioSuite",
    "currentReadinessProductScenarioSuiteStatus",
    "currentReadinessProductScenarioSuiteStageCount",
    "currentReadinessProductScenarioSuiteFailedStages",
    "currentReadinessProductScenarioSuitePlannedStages",
    "currentReadinessProductScenarioSuiteScenarios",
    "currentReadinessProductScenarioSuiteProductPlanStages",
    "currentReadinessProductScenarioSuiteLargeGroupIncluded",
    "currentReadinessFullAcceptanceExpectedCampaign",
    "currentReadinessFullAcceptanceCampaign",
    "currentReadinessFullAcceptanceStatus",
    "currentReadinessFullAcceptanceFailures",
    "currentReadinessFullAcceptanceRequiredFailures",
    "currentReadinessFullAcceptanceAttempted",
    "currentReadinessFullAcceptanceSkipped",
    "currentReadinessOperatorNetworkPreflight",
    "currentReadinessOperatorNetworkLogPresent",
    "currentReadinessOperatorNetworkFailed",
    "currentReadinessOperatorNetworkWarnings",
    "currentReadinessOperatorNetworkRouteInterfaces",
    "currentReadinessOperatorNetworkRouteGateways",
    "currentReadinessOperatorNetworkFailureCount",
    "productionEvidenceBlockerCount",
    "productionEvidenceBlockers",
]
state_csv_row = []
for field in state_csv_fields:
    if field == "recordType":
        state_csv_row.append("summary")
        continue
    value = readiness_summary.get(field, "")
    if isinstance(value, list):
        value = ",".join(str(item) for item in value)
    if value is None:
        value = ""
    state_csv_row.append(str(value))
state_summary_csv.write_text(
    ",".join(state_csv_fields) + "\n" + ",".join(state_csv_row) + "\n",
    encoding="utf-8",
)
payload = {
    "schemaVersion": 1,
    "status": "PASS",
    "reason": "entrypoint_and_requested_runs_passed",
    "generatedAtEpoch": int(time.time()),
    "target": {
        "baseURL": base_url,
        "tcpHost": tcp_host,
        "tcpPort": tcp_port,
        "accountFile": os.environ.get("ACCOUNT_FILE", ""),
        "conversationIDPresent": bool(os.environ.get("IM_CONVERSATION_ID", "")),
    },
    "requestedRuns": {
        "smoke": True,
        "smokeMode": "smoke",
        "productScenarioSuite": True,
        "productScenarioSuiteName": "recommended",
        "baseline": True,
        "fullAcceptance": is_full,
        "fullAcceptanceCampaign": "production-full-acceptance" if is_full else "",
    },
    "evidencePolicy": {
        "requirePackageableEvidence": True,
        "autoProductScenarioSuiteForPackageableAcceptance": True,
        "requireCloudSecurityGroup": True,
        "requireCloudSecurityGroupRepairReceipt": True,
        "requirePublicPortPolicy": True,
        "allowTempHTTP8080": allow_temp_http_8080,
        "cloudSecurityGroupRulesFile": cloud_security_group_rules_file,
        "cloudSecurityGroupRulesMaxAgeSeconds": cloud_security_group_rules_max_age_seconds,
        "cloudSecurityGroupRulesRequireRootOwner": cloud_security_group_rules_require_root_owner,
        "cloudSecurityGroupRepairReceiptJSON": repair_receipt,
        "cloudSecurityGroupRepairReceiptMaxAgeSeconds": int(repair_receipt_max_age_seconds or 0),
        "cloudSecurityGroupRepairReceiptExpectSecurityGroupID": expected_security_group_id,
        "cloudSecurityGroupRepairReceiptExpectRegionID": expected_region_id,
        "cloudSecurityGroupRepairReceiptExpectAdminCIDR": expected_admin_cidr,
        "operatorNetworkPreflight": True,
    },
    "entrypoint": {
        "probeJSON": probe_path,
        "failed": False,
        "diagnosis": "ok",
        "detail": "ok",
        "blocker": {"preventsPerformanceEvidence": False},
    },
    "artifacts": {
        "runDir": str(run_dir),
        "dashboard": str(dashboard_md),
        "stateSummary": str(state_summary_md),
        "cloudSecurityGroupRulesFile": cloud_security_group_rules_file,
        "cloudSecurityGroupAuditLog": str(cloud_security_group_audit_log),
        "cloudSecurityGroupRepairReceiptJSON": repair_receipt,
        "cloudSecurityGroupRepairReceiptVerifyLog": repair_verify_log,
        "operatorNetworkLog": str(operator_log),
        "operatorNetworkJSON": str(operator_json),
        "smokeLog": str(smoke_log),
        "productScenarioSuiteLog": str(suite_log),
        "productScenarioSuiteRunJSON": str(suite_run_json),
        "productScenarioSuiteRunMarkdown": str(suite_run_md),
        "baselineLog": str(baseline_log),
        "fullAcceptanceLog": str(full_acceptance_log) if is_full else "",
        "fullAcceptanceRunJSON": str(full_acceptance_run_json) if is_full else "",
        "fullAcceptanceRunbook": str(full_acceptance_runbook) if is_full else "",
    },
    "runs": {
        "smokeExitCode": 0,
        "suiteExitCode": 0,
        "baselineExitCode": 0,
        "fullAcceptanceExitCode": 0 if is_full else None,
    },
}
Path(path).write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
printf 'fake readiness\n'
SH
  chmod 0755 "${fake_readiness}"
  cat >"${fake_package}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
env | sort >"${PRODUCTION_ACCEPTANCE_SELF_TEST_CAPTURE_DIR}/package.env"
mkdir -p "${PRODUCTION_EVIDENCE_OUTPUT_DIR}"
package="${PRODUCTION_EVIDENCE_PACKAGE:-${PRODUCTION_EVIDENCE_OUTPUT_DIR}/production-evidence.tar.gz}"
stage_dir="${PRODUCTION_ACCEPTANCE_SELF_TEST_CAPTURE_DIR}/package-stage"
rm -rf "${stage_dir}"
mkdir -p "${stage_dir}"
python3 - "${stage_dir}" "${PRODUCTION_ACCEPTANCE_SELF_TEST_REAL_VERIFIER}" <<'PY'
import hashlib
import json
import sys
import time
from pathlib import Path

stage = Path(sys.argv[1])
script_dir = Path(sys.argv[2]).resolve().parent
sys.path.insert(0, str(script_dir))
from perf_current_production_readiness_verify import build_readiness_markdown

target = {
    "baseURL": "https://chat.myim-prod.com",
    "tcpHost": "tcp.myim-prod.com",
    "tcpPort": "9000",
}
readiness = {
    "schemaVersion": 1,
    "status": "PASS",
    "reason": "entrypoint_and_requested_runs_passed",
    "generatedAtEpoch": int(time.time()),
    "target": target,
    "requestedRuns": {
        "smoke": True,
        "productScenarioSuite": True,
        "baseline": True,
        "fullAcceptance": True,
    },
    "runs": {
        "smokeExitCode": 0,
        "suiteExitCode": 0,
        "baselineExitCode": 0,
        "fullAcceptanceExitCode": 0,
    },
}
(stage / "production-gate.json").write_text(json.dumps({
    "schemaVersion": 1,
    "status": "PASS",
    "profile": "normal-product-baseline",
}), encoding="utf-8")
(stage / "README.md").write_text("\n".join([
    "# Production Evidence Package",
    "",
    "Install with `69_install_performance_evidence_package.sh`.",
    "Do not install only `production-gate.json`.",
    "",
    "- status: `PASS`",
    "- profile: `normal-product-baseline`",
    "- docsAudit: `PASS`",
    "- productProfileGate: `PASS`",
    "- currentReadinessStatus: `PASS`",
    "- currentReadinessRequestedSmoke/ProductSuite/Baseline/Full: `True/True/True/True`",
    "- currentReadinessExitCodesSmoke/ProductSuite/Baseline/Full: `0/0/0/0`",
    "",
]), encoding="utf-8")
(stage / "current-production-readiness.json").write_text(json.dumps(readiness), encoding="utf-8")
(stage / "current-production-readiness.md").write_text(build_readiness_markdown(readiness), encoding="utf-8")
files = []
for member in sorted(stage.iterdir(), key=lambda item: item.name):
    if not member.is_file() or member.name in {"production-evidence-manifest.json", "SHA256SUMS"}:
        continue
    files.append({
        "path": member.name,
        "bytes": member.stat().st_size,
        "sha256": hashlib.sha256(member.read_bytes()).hexdigest(),
    })
(stage / "production-evidence-manifest.json").write_text(json.dumps({
    "schemaVersion": 1,
    "profile": "normal-product-baseline",
    "docsAudit": {"status": "PASS"},
    "productProfileGate": {"status": "PASS"},
    "currentReadiness": {
        "present": True,
        "status": readiness["status"],
        "reason": readiness["reason"],
        "target": target,
        "requestedRuns": readiness["requestedRuns"],
        "runs": readiness["runs"],
    },
    "files": files,
}), encoding="utf-8")
PY
: >"${stage_dir}/SHA256SUMS"
if command -v sha256sum >/dev/null 2>&1; then
  (
    cd "${stage_dir}"
    sha256sum ./README.md ./current-production-readiness.json ./current-production-readiness.md ./production-evidence-manifest.json ./production-gate.json >SHA256SUMS
  )
else
  (
    cd "${stage_dir}"
    shasum -a 256 ./README.md ./current-production-readiness.json ./current-production-readiness.md ./production-evidence-manifest.json ./production-gate.json >SHA256SUMS
  )
fi
tar -C "${stage_dir}" -czf "${package}" \
  README.md \
  current-production-readiness.json \
  current-production-readiness.md \
  production-evidence-manifest.json \
  production-gate.json \
  SHA256SUMS
printf 'production_evidence_package result=pass package=%s\n' "${package}"
SH
  chmod 0755 "${fake_package}"
  cat >"${fake_verifier}" <<'PY'
#!/usr/bin/env python3
import os
import subprocess
import sys
from pathlib import Path

capture_dir = Path(os.environ["PRODUCTION_ACCEPTANCE_SELF_TEST_CAPTURE_DIR"])
(capture_dir / "verifier.args").write_text(
    "\n".join(sys.argv[1:]) + "\n",
    encoding="utf-8",
)
subprocess.run(
    [sys.executable, os.environ["PRODUCTION_ACCEPTANCE_SELF_TEST_REAL_VERIFIER"], *sys.argv[1:]],
    check=True,
)
PY
  chmod 0755 "${fake_verifier}"

  run_self_test_child "${log}" \
    env \
    PRODUCTION_ACCEPTANCE_SELF_TEST=false \
    PRODUCTION_ACCEPTANCE_SELF_TEST_CAPTURE_DIR="${tmpdir}" \
    PRODUCTION_ACCEPTANCE_READINESS_RUNNER="${fake_readiness}" \
    PRODUCTION_ACCEPTANCE_PACKAGE_RUNNER="${fake_package}" \
    PRODUCTION_ACCEPTANCE_RECEIPT_VERIFIER="${fake_verifier}" \
    PRODUCTION_ACCEPTANCE_SELF_TEST_REAL_VERIFIER="${SCRIPT_DIR}/perf_production_acceptance_verify.py" \
    PRODUCTION_ACCEPTANCE_RESULT_ROOT="${tmpdir}/results" \
    PRODUCTION_ACCEPTANCE_RUN_ID=self-test-full \
    PRODUCTION_ACCEPTANCE_RECEIPT_MAX_AGE_SECONDS=43210 \
    PRODUCTION_ACCEPTANCE_RECEIPT_MAX_FUTURE_SKEW_SECONDS=123 \
    CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080=true \
    PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080=true \
    BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    ACCOUNT_FILE="${account_file}" \
    IM_CONVERSATION_ID=00000000-0000-0000-0000-000000000001 \
    IM_INTERNAL_SECRET=secret \
    CLOUD_SECURITY_GROUP_RULES_FILE="${sg_file}" \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${repair_receipt_file}" \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=sg-production-acceptance-selftest \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=cn-shenzhen \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=203.0.113.10/32 \
    bash "${BASH_SOURCE[0]}"
  grep -q 'production_acceptance result=pass' "${log}"
  grep -q '^--max-age-seconds$' "${tmpdir}/verifier.args"
  grep -q '^43210$' "${tmpdir}/verifier.args"
  grep -q '^--max-future-skew-seconds$' "${tmpdir}/verifier.args"
  grep -q '^123$' "${tmpdir}/verifier.args"
  grep -q '^CURRENT_PRODUCTION_REQUIRE_PACKAGEABLE_EVIDENCE=true$' "${tmpdir}/readiness.env"
  grep -q '^CURRENT_PRODUCTION_REQUIRE_CLOUD_SECURITY_GROUP=true$' "${tmpdir}/readiness.env"
  grep -q '^CURRENT_PRODUCTION_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT=true$' "${tmpdir}/readiness.env"
  grep -q '^CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS=86400$' "${tmpdir}/readiness.env"
  grep -q '^CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER=true$' "${tmpdir}/readiness.env"
  grep -q "^CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON=${repair_receipt_file}$" "${tmpdir}/readiness.env"
  grep -q '^CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS=86400$' "${tmpdir}/readiness.env"
  grep -q '^CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=sg-production-acceptance-selftest$' "${tmpdir}/readiness.env"
  grep -q '^CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=cn-shenzhen$' "${tmpdir}/readiness.env"
  grep -q '^CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=203.0.113.10/32$' "${tmpdir}/readiness.env"
  grep -q '^CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080=false$' "${tmpdir}/readiness.env"
  grep -q '^CURRENT_PRODUCTION_REQUIRE_PUBLIC_PORT_POLICY=true$' "${tmpdir}/readiness.env"
  grep -q '^CURRENT_PRODUCTION_RUN_SCENARIO_SUITE=true$' "${tmpdir}/readiness.env"
  grep -q '^CURRENT_PRODUCTION_RUN_BASELINE=true$' "${tmpdir}/readiness.env"
  grep -q '^CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE=true$' "${tmpdir}/readiness.env"
  grep -q '^PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS=true$' "${tmpdir}/package.env"
  grep -q '^PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP=true$' "${tmpdir}/package.env"
  grep -q '^PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS=86400$' "${tmpdir}/package.env"
  grep -q '^PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER=true$' "${tmpdir}/package.env"
  grep -q "^PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON=${repair_receipt_file}$" "${tmpdir}/package.env"
  grep -q '^PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS=86400$' "${tmpdir}/package.env"
  grep -q '^PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=sg-production-acceptance-selftest$' "${tmpdir}/package.env"
  grep -q '^PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=cn-shenzhen$' "${tmpdir}/package.env"
  grep -q '^PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=203.0.113.10/32$' "${tmpdir}/package.env"
  grep -q '^PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080=false$' "${tmpdir}/package.env"
  grep -q '^CURRENT_PRODUCTION_OPERATOR_NETWORK_PREFLIGHT=true$' "${tmpdir}/readiness.env"
  grep -q '^CURRENT_PRODUCTION_FAIL_ON_OPERATOR_NETWORK=true$' "${tmpdir}/readiness.env"
  python3 - "${tmpdir}/results/self-test-full/production-acceptance.json" "${repair_receipt_file}" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
repair_receipt_file = sys.argv[2]
if payload.get("status") != "PASS":
    raise SystemExit("production_acceptance_self_test result=fail reason=receipt_status")
if payload.get("reason") != "accepted":
    raise SystemExit("production_acceptance_self_test result=fail reason=receipt_reason")
policy = payload.get("policy") or {}
if policy.get("runFullAcceptance") is not True:
    raise SystemExit("production_acceptance_self_test result=fail reason=receipt_full_acceptance")
if policy.get("requireCloudSecurityGroupRepairReceipt") is not True:
    raise SystemExit("production_acceptance_self_test result=fail reason=receipt_cloud_security_group_repair_receipt_policy")
if policy.get("allowTempHTTP8080") is not False:
    raise SystemExit("production_acceptance_self_test result=fail reason=receipt_temp_http_8080_policy")
if policy.get("cloudSecurityGroupRulesMaxAgeSeconds") != 86400:
    raise SystemExit("production_acceptance_self_test result=fail reason=receipt_cloud_security_group_rules_max_age")
if policy.get("cloudSecurityGroupRulesRequireRootOwner") is not True:
    raise SystemExit("production_acceptance_self_test result=fail reason=receipt_cloud_security_group_rules_root_owner")
if policy.get("cloudSecurityGroupRepairReceiptJSON") != repair_receipt_file:
    raise SystemExit("production_acceptance_self_test result=fail reason=receipt_cloud_security_group_repair_receipt_path")
if policy.get("cloudSecurityGroupRepairReceiptMaxAgeSeconds") != 86400:
    raise SystemExit("production_acceptance_self_test result=fail reason=receipt_cloud_security_group_repair_receipt_max_age")
if policy.get("cloudSecurityGroupRepairReceiptExpectSecurityGroupID") != "sg-production-acceptance-selftest":
    raise SystemExit("production_acceptance_self_test result=fail reason=receipt_cloud_security_group_repair_receipt_security_group")
if policy.get("cloudSecurityGroupRepairReceiptExpectRegionID") != "cn-shenzhen":
    raise SystemExit("production_acceptance_self_test result=fail reason=receipt_cloud_security_group_repair_receipt_region")
if policy.get("cloudSecurityGroupRepairReceiptExpectAdminCIDR") != "203.0.113.10/32":
    raise SystemExit("production_acceptance_self_test result=fail reason=receipt_cloud_security_group_repair_receipt_admin_cidr")
if policy.get("operatorNetworkPreflight") is not True:
    raise SystemExit("production_acceptance_self_test result=fail reason=receipt_operator_network_policy")
if policy.get("receiptMaxAgeSeconds") != 43210:
    raise SystemExit("production_acceptance_self_test result=fail reason=receipt_max_age")
if policy.get("receiptMaxFutureSkewSeconds") != 123:
    raise SystemExit("production_acceptance_self_test result=fail reason=receipt_max_future_skew")
artifacts = payload.get("artifacts") or {}
if artifacts.get("packagePresent") is not True:
    raise SystemExit("production_acceptance_self_test result=fail reason=receipt_package_missing")
if not str(artifacts.get("package") or "").endswith("production-evidence-self-test-full.tar.gz"):
    raise SystemExit("production_acceptance_self_test result=fail reason=receipt_package_path")
if int(artifacts.get("packageBytes") or 0) <= 0:
    raise SystemExit("production_acceptance_self_test result=fail reason=receipt_package_bytes")
if len(str(artifacts.get("packageSha256") or "")) != 64:
    raise SystemExit("production_acceptance_self_test result=fail reason=receipt_package_sha")
commands = payload.get("commands") or {}
if commands.get("readinessExitCode") != 0 or commands.get("packageExitCode") != 0:
    raise SystemExit("production_acceptance_self_test result=fail reason=receipt_exit_codes")
if not Path(artifacts.get("readinessLog") or "").is_file():
    raise SystemExit("production_acceptance_self_test result=fail reason=receipt_readiness_log")
if not Path(artifacts.get("packageLog") or "").is_file():
    raise SystemExit("production_acceptance_self_test result=fail reason=receipt_package_log")
PY
  grep -q 'packagePresent: `True`' "${tmpdir}/results/self-test-full/production-acceptance.md"

  run_self_test_child "${log}" \
    env \
    PRODUCTION_ACCEPTANCE_SELF_TEST=false \
    PRODUCTION_ACCEPTANCE_SELF_TEST_CAPTURE_DIR="${tmpdir}" \
    PRODUCTION_ACCEPTANCE_LEVEL=baseline \
    PRODUCTION_ACCEPTANCE_READINESS_RUNNER="${fake_readiness}" \
    PRODUCTION_ACCEPTANCE_PACKAGE_RUNNER="${fake_package}" \
    PRODUCTION_ACCEPTANCE_SELF_TEST_REAL_VERIFIER="${SCRIPT_DIR}/perf_production_acceptance_verify.py" \
    PRODUCTION_ACCEPTANCE_RESULT_ROOT="${tmpdir}/baseline-results" \
    PRODUCTION_ACCEPTANCE_RUN_ID=self-test-baseline \
    BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    ACCOUNT_FILE="${account_file}" \
    IM_CONVERSATION_ID=00000000-0000-0000-0000-000000000001 \
    IM_INTERNAL_SECRET=secret \
    CLOUD_SECURITY_GROUP_RULES_FILE="${sg_file}" \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${repair_receipt_file}" \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=sg-production-acceptance-selftest \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=cn-shenzhen \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=203.0.113.10/32 \
    bash "${BASH_SOURCE[0]}"
  grep -q '^CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE=false$' "${tmpdir}/readiness.env"
  python3 - "${tmpdir}/baseline-results/self-test-baseline/production-acceptance.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
policy = payload.get("policy") or {}
target = payload.get("target") or {}
if payload.get("status") != "PASS":
    raise SystemExit("production_acceptance_self_test result=fail reason=baseline_receipt_status")
if policy.get("runFullAcceptance") is not False:
    raise SystemExit("production_acceptance_self_test result=fail reason=baseline_receipt_full_acceptance")
if target.get("requiredAccountRows") != 5000:
    raise SystemExit("production_acceptance_self_test result=fail reason=baseline_receipt_required_rows")
PY

  printf 'small001@example.com,password\nsmall002@example.com,password\n' >"${tmpdir}/small-accounts.csv"
  if PRODUCTION_ACCEPTANCE_SELF_TEST=false \
    PRODUCTION_ACCEPTANCE_SELF_TEST_CAPTURE_DIR="${tmpdir}" \
    PRODUCTION_ACCEPTANCE_READINESS_RUNNER="${fake_readiness}" \
    PRODUCTION_ACCEPTANCE_PACKAGE_RUNNER="${fake_package}" \
    PRODUCTION_ACCEPTANCE_RESULT_ROOT="${tmpdir}/small-results" \
    PRODUCTION_ACCEPTANCE_RUN_ID=self-test-small-accounts \
    BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    ACCOUNT_FILE="${tmpdir}/small-accounts.csv" \
    IM_CONVERSATION_ID=00000000-0000-0000-0000-000000000001 \
    IM_INTERNAL_SECRET=secret \
    CLOUD_SECURITY_GROUP_RULES_FILE="${sg_file}" \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${repair_receipt_file}" \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=sg-production-acceptance-selftest \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=cn-shenzhen \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=203.0.113.10/32 \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    printf 'production_acceptance_self_test result=fail reason=small_account_file_passed\n' >&2
    return 1
  fi
  grep -q 'reason=account_file_too_small rows=2 required=10000 level=full' "${log}"

  if PRODUCTION_ACCEPTANCE_SELF_TEST=false \
    PRODUCTION_ACCEPTANCE_SELF_TEST_CAPTURE_DIR="${tmpdir}" \
    PRODUCTION_ACCEPTANCE_READINESS_RUNNER="${fake_readiness}" \
    PRODUCTION_ACCEPTANCE_PACKAGE_RUNNER="${fake_package}" \
    PRODUCTION_ACCEPTANCE_RESULT_ROOT="${tmpdir}/nil-conversation-results" \
    PRODUCTION_ACCEPTANCE_RUN_ID=self-test-nil-conversation \
    BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    ACCOUNT_FILE="${account_file}" \
    IM_CONVERSATION_ID=00000000-0000-0000-0000-000000000000 \
    IM_INTERNAL_SECRET=secret \
    CLOUD_SECURITY_GROUP_RULES_FILE="${sg_file}" \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${repair_receipt_file}" \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=sg-production-acceptance-selftest \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=cn-shenzhen \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=203.0.113.10/32 \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    printf 'production_acceptance_self_test result=fail reason=nil_conversation_passed\n' >&2
    return 1
  fi
  grep -q 'reason=conversation_id_invalid detail=nil_uuid' "${log}"

  if PRODUCTION_ACCEPTANCE_SELF_TEST=false \
    PRODUCTION_ACCEPTANCE_SELF_TEST_CAPTURE_DIR="${tmpdir}" \
    PRODUCTION_ACCEPTANCE_READINESS_RUNNER="${fake_readiness}" \
    PRODUCTION_ACCEPTANCE_PACKAGE_RUNNER="${fake_package}" \
    PRODUCTION_ACCEPTANCE_RESULT_ROOT="${tmpdir}/bad-conversation-results" \
    PRODUCTION_ACCEPTANCE_RUN_ID=self-test-bad-conversation \
    BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    ACCOUNT_FILE="${account_file}" \
    IM_CONVERSATION_ID=not-a-uuid \
    IM_INTERNAL_SECRET=secret \
    CLOUD_SECURITY_GROUP_RULES_FILE="${sg_file}" \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${repair_receipt_file}" \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=sg-production-acceptance-selftest \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=cn-shenzhen \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=203.0.113.10/32 \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    printf 'production_acceptance_self_test result=fail reason=bad_conversation_passed\n' >&2
    return 1
  fi
  grep -q 'reason=conversation_id_invalid detail=invalid_uuid' "${log}"

  if PRODUCTION_ACCEPTANCE_SELF_TEST=false \
    PRODUCTION_ACCEPTANCE_SELF_TEST_CAPTURE_DIR="${tmpdir}" \
    PRODUCTION_ACCEPTANCE_READINESS_RUNNER="${fake_readiness}" \
    PRODUCTION_ACCEPTANCE_PACKAGE_RUNNER="${fake_package}" \
    BASE_URL=http://203.0.113.10 \
    TCP_HOST=203.0.113.10 \
    ACCOUNT_FILE="${account_file}" \
    IM_CONVERSATION_ID=00000000-0000-0000-0000-000000000001 \
    IM_INTERNAL_SECRET=secret \
    CLOUD_SECURITY_GROUP_RULES_FILE="${sg_file}" \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${repair_receipt_file}" \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=sg-production-acceptance-selftest \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=cn-shenzhen \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=203.0.113.10/32 \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    printf 'production_acceptance_self_test result=fail reason=invalid_target_passed\n' >&2
    return 1
  fi
  grep -q 'reason=base_url_https_required' "${log}"

  if PRODUCTION_ACCEPTANCE_SELF_TEST=false \
    PRODUCTION_ACCEPTANCE_SELF_TEST_CAPTURE_DIR="${tmpdir}" \
    PRODUCTION_ACCEPTANCE_READINESS_RUNNER="${fake_readiness}" \
    PRODUCTION_ACCEPTANCE_PACKAGE_RUNNER="${fake_package}" \
    BASE_URL=https://chat.myim-prod.com:8080 \
    TCP_HOST=tcp.myim-prod.com \
    ACCOUNT_FILE="${account_file}" \
    IM_CONVERSATION_ID=00000000-0000-0000-0000-000000000001 \
    IM_INTERNAL_SECRET=secret \
    CLOUD_SECURITY_GROUP_RULES_FILE="${sg_file}" \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${repair_receipt_file}" \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=sg-production-acceptance-selftest \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=cn-shenzhen \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=203.0.113.10/32 \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    printf 'production_acceptance_self_test result=fail reason=non_default_https_port_target_passed\n' >&2
    return 1
  fi
  grep -q 'reason=base_url_default_https_port_required' "${log}"

  if PRODUCTION_ACCEPTANCE_SELF_TEST=false \
    PRODUCTION_ACCEPTANCE_SELF_TEST_CAPTURE_DIR="${tmpdir}" \
    PRODUCTION_ACCEPTANCE_READINESS_RUNNER="${fake_readiness}" \
    PRODUCTION_ACCEPTANCE_PACKAGE_RUNNER="${fake_package}" \
    BASE_URL=https://chat.myim-prod.com/api \
    TCP_HOST=tcp.myim-prod.com \
    ACCOUNT_FILE="${account_file}" \
    IM_CONVERSATION_ID=00000000-0000-0000-0000-000000000001 \
    IM_INTERNAL_SECRET=secret \
    CLOUD_SECURITY_GROUP_RULES_FILE="${sg_file}" \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${repair_receipt_file}" \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=sg-production-acceptance-selftest \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=cn-shenzhen \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=203.0.113.10/32 \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    printf 'production_acceptance_self_test result=fail reason=path_target_passed\n' >&2
    return 1
  fi
  grep -q 'reason=base_url_origin_required' "${log}"

  if PRODUCTION_ACCEPTANCE_SELF_TEST=false \
    PRODUCTION_ACCEPTANCE_SELF_TEST_CAPTURE_DIR="${tmpdir}" \
    PRODUCTION_ACCEPTANCE_READINESS_RUNNER="${fake_readiness}" \
    PRODUCTION_ACCEPTANCE_PACKAGE_RUNNER="${fake_package}" \
    BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9443 \
    ACCOUNT_FILE="${account_file}" \
    IM_CONVERSATION_ID=00000000-0000-0000-0000-000000000001 \
    IM_INTERNAL_SECRET=secret \
    CLOUD_SECURITY_GROUP_RULES_FILE="${sg_file}" \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${repair_receipt_file}" \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=sg-production-acceptance-selftest \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=cn-shenzhen \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=203.0.113.10/32 \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    printf 'production_acceptance_self_test result=fail reason=bad_tcp_port_target_passed\n' >&2
    return 1
  fi
  grep -q 'reason=tcp_port_required' "${log}"

  if PRODUCTION_ACCEPTANCE_SELF_TEST=false \
    PRODUCTION_ACCEPTANCE_SELF_TEST_CAPTURE_DIR="${tmpdir}" \
    PRODUCTION_ACCEPTANCE_READINESS_RUNNER="${fake_readiness}" \
    PRODUCTION_ACCEPTANCE_PACKAGE_RUNNER="${fake_package}" \
    BASE_URL=https://203.0.113.10 \
    TCP_HOST=tcp.myim-prod.com \
    ACCOUNT_FILE="${account_file}" \
    IM_CONVERSATION_ID=00000000-0000-0000-0000-000000000001 \
    IM_INTERNAL_SECRET=secret \
    CLOUD_SECURITY_GROUP_RULES_FILE="${sg_file}" \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${repair_receipt_file}" \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=sg-production-acceptance-selftest \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=cn-shenzhen \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=203.0.113.10/32 \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    printf 'production_acceptance_self_test result=fail reason=ip_base_target_passed\n' >&2
    return 1
  fi
  grep -q 'reason=base_url_dns_required' "${log}"
  grep -q 'hostReason=ip' "${log}"

  if PRODUCTION_ACCEPTANCE_SELF_TEST=false \
    PRODUCTION_ACCEPTANCE_SELF_TEST_CAPTURE_DIR="${tmpdir}" \
    PRODUCTION_ACCEPTANCE_READINESS_RUNNER="${fake_readiness}" \
    PRODUCTION_ACCEPTANCE_PACKAGE_RUNNER="${fake_package}" \
    BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=203.0.113.10 \
    ACCOUNT_FILE="${account_file}" \
    IM_CONVERSATION_ID=00000000-0000-0000-0000-000000000001 \
    IM_INTERNAL_SECRET=secret \
    CLOUD_SECURITY_GROUP_RULES_FILE="${sg_file}" \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${repair_receipt_file}" \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=sg-production-acceptance-selftest \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=cn-shenzhen \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=203.0.113.10/32 \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    printf 'production_acceptance_self_test result=fail reason=ip_tcp_target_passed\n' >&2
    return 1
  fi
  grep -q 'reason=tcp_host_dns_required' "${log}"
  grep -q 'hostReason=ip' "${log}"

  if PRODUCTION_ACCEPTANCE_SELF_TEST=false \
    PRODUCTION_ACCEPTANCE_SELF_TEST_CAPTURE_DIR="${tmpdir}" \
    PRODUCTION_ACCEPTANCE_READINESS_RUNNER="${fake_readiness}" \
    PRODUCTION_ACCEPTANCE_PACKAGE_RUNNER="${fake_package}" \
    BASE_URL=https://chat.yourdomain.com \
    TCP_HOST=tcp.yourdomain.com \
    ACCOUNT_FILE="${account_file}" \
    IM_CONVERSATION_ID=00000000-0000-0000-0000-000000000001 \
    IM_INTERNAL_SECRET=secret \
    CLOUD_SECURITY_GROUP_RULES_FILE="${sg_file}" \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${repair_receipt_file}" \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=sg-production-acceptance-selftest \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=cn-shenzhen \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=203.0.113.10/32 \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    printf 'production_acceptance_self_test result=fail reason=placeholder_target_passed\n' >&2
    return 1
  fi
  grep -q 'reason=base_url_dns_required' "${log}"
  grep -q 'hostReason=placeholder' "${log}"

  if PRODUCTION_ACCEPTANCE_SELF_TEST=false \
    PRODUCTION_ACCEPTANCE_SELF_TEST_CAPTURE_DIR="${tmpdir}" \
    PRODUCTION_ACCEPTANCE_READINESS_RUNNER="${fake_readiness}" \
    PRODUCTION_ACCEPTANCE_PACKAGE_RUNNER="${fake_package}" \
    BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.example.net \
    ACCOUNT_FILE="${account_file}" \
    IM_CONVERSATION_ID=00000000-0000-0000-0000-000000000001 \
    IM_INTERNAL_SECRET=secret \
    CLOUD_SECURITY_GROUP_RULES_FILE="${sg_file}" \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${repair_receipt_file}" \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=sg-production-acceptance-selftest \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=cn-shenzhen \
    PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=203.0.113.10/32 \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    printf 'production_acceptance_self_test result=fail reason=placeholder_tcp_target_passed\n' >&2
    return 1
  fi
  grep -q 'reason=tcp_host_dns_required' "${log}"
  grep -q 'hostReason=placeholder' "${log}"
  printf 'production_acceptance_self_test result=pass\n'
}

case "${1:-}" in
  --help|-h)
    usage
    exit 0
    ;;
  "")
    ;;
  *)
    printf 'production_acceptance result=fail reason=unknown_argument arg=%s\n' "$1" >&2
    usage >&2
    exit 2
    ;;
esac

if bool_enabled "${PRODUCTION_ACCEPTANCE_SELF_TEST}"; then
  run_self_test
  exit 0
fi

run_acceptance
