#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRODUCTION_TARGET_POLICY="${PRODUCTION_TARGET_POLICY:-${SCRIPT_DIR}/production_target_policy.py}"
RESULT_ROOT="${RESULT_ROOT:-${SCRIPT_DIR}/results}"
RESULT_ROOT="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve())' "${RESULT_ROOT}")"
RUN_ID="${RUN_ID:-current-production-readiness-$(date +%Y%m%d-%H%M%S)}"
RUN_DIR="${RUN_DIR:-${RESULT_ROOT}/${RUN_ID}}"
RUN_DIR="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve())' "${RUN_DIR}")"
CURRENT_PRODUCTION_LINK="${CURRENT_PRODUCTION_LINK:-${RESULT_ROOT}/current-production-readiness}"

BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
TCP_HOST="${TCP_HOST:-}"
TCP_PORT="${TCP_PORT:-9000}"
ACCOUNT_FILE="${ACCOUNT_FILE:-}"
IM_CONVERSATION_ID="${IM_CONVERSATION_ID:-}"
IM_INTERNAL_SECRET="${IM_INTERNAL_SECRET:-${IM_INTERNAL_SHARED_SECRET:-}}"

CURRENT_PRODUCTION_PROFILE="${CURRENT_PRODUCTION_PROFILE:-normal-product-baseline}"
CURRENT_PRODUCTION_SMOKE_MODE="${CURRENT_PRODUCTION_SMOKE_MODE:-smoke}"
CURRENT_PRODUCTION_RUN_SMOKE_WAS_SET=false
if [[ "${CURRENT_PRODUCTION_RUN_SMOKE+x}" == "x" ]]; then
  CURRENT_PRODUCTION_RUN_SMOKE_WAS_SET=true
fi
CURRENT_PRODUCTION_RUN_SMOKE="${CURRENT_PRODUCTION_RUN_SMOKE:-true}"
CURRENT_PRODUCTION_RUN_SCENARIO_SUITE_WAS_SET=false
if [[ "${CURRENT_PRODUCTION_RUN_SCENARIO_SUITE+x}" == "x" ]]; then
  CURRENT_PRODUCTION_RUN_SCENARIO_SUITE_WAS_SET=true
fi
CURRENT_PRODUCTION_RUN_SCENARIO_SUITE="${CURRENT_PRODUCTION_RUN_SCENARIO_SUITE:-}"
CURRENT_PRODUCTION_SCENARIO_SUITE="${CURRENT_PRODUCTION_SCENARIO_SUITE:-recommended}"
CURRENT_PRODUCTION_RUN_BASELINE_WAS_SET=false
if [[ "${CURRENT_PRODUCTION_RUN_BASELINE+x}" == "x" ]]; then
  CURRENT_PRODUCTION_RUN_BASELINE_WAS_SET=true
fi
CURRENT_PRODUCTION_RUN_BASELINE="${CURRENT_PRODUCTION_RUN_BASELINE:-}"
CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE="${CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE:-false}"
CURRENT_PRODUCTION_FULL_ACCEPTANCE_CAMPAIGN="${CURRENT_PRODUCTION_FULL_ACCEPTANCE_CAMPAIGN:-production-full-acceptance}"
CURRENT_PRODUCTION_REQUIRE_PACKAGEABLE_EVIDENCE="${CURRENT_PRODUCTION_REQUIRE_PACKAGEABLE_EVIDENCE:-true}"
CURRENT_PRODUCTION_ENTRYPOINT_PROBE="${CURRENT_PRODUCTION_ENTRYPOINT_PROBE:-true}"
CURRENT_PRODUCTION_FAIL_ON_ENTRYPOINT_ERROR="${CURRENT_PRODUCTION_FAIL_ON_ENTRYPOINT_ERROR:-true}"
CURRENT_PRODUCTION_OPERATOR_NETWORK_PREFLIGHT="${CURRENT_PRODUCTION_OPERATOR_NETWORK_PREFLIGHT:-true}"
CURRENT_PRODUCTION_FAIL_ON_OPERATOR_NETWORK="${CURRENT_PRODUCTION_FAIL_ON_OPERATOR_NETWORK:-true}"
CURRENT_PRODUCTION_FAIL_ON_LOCAL_NETWORK="${CURRENT_PRODUCTION_FAIL_ON_LOCAL_NETWORK:-${CURRENT_PRODUCTION_FAIL_ON_OPERATOR_NETWORK}}"
CURRENT_PRODUCTION_OPERATOR_NETWORK_PREFLIGHT_SCRIPT="${CURRENT_PRODUCTION_OPERATOR_NETWORK_PREFLIGHT_SCRIPT:-${SCRIPT_DIR}/../../deploy/ubuntu/20_verify_operator_network.sh}"
CURRENT_PRODUCTION_REQUIRE_CLOUD_SECURITY_GROUP="${CURRENT_PRODUCTION_REQUIRE_CLOUD_SECURITY_GROUP:-}"
CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_FILE="${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_FILE:-${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_FILE:-${CLOUD_SECURITY_GROUP_RULES_FILE:-}}}"
CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_AUDIT_SCRIPT="${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_AUDIT_SCRIPT:-${SCRIPT_DIR}/../../deploy/ubuntu/26_audit_cloud_security_group.sh}"
CURRENT_PRODUCTION_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT="${CURRENT_PRODUCTION_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT:-}"
CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON:-${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON:-/var/lib/imserver/cloud-security-group/repairs/latest-repair-receipt.json}}"
CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS="${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS:-86400}"
CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID="${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID:-${ALIYUN_SECURITY_GROUP_ID:-}}"
CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID="${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID:-${ALIYUN_REGION_ID:-}}"
CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR="${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR:-${ALIYUN_SECURITY_GROUP_ADMIN_CIDR:-}}"
CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_VERIFY_SCRIPT="${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_VERIFY_SCRIPT:-${SCRIPT_DIR}/../../deploy/ubuntu/31_verify_aliyun_security_group_repair_receipt.sh}"
CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS="${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS:-80 443 9000}"
CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS="${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS:-3389 5432 6379 9092 8081 8082 18080 8080}"
CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_ADMIN_PORTS="${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_ADMIN_PORTS:-22}"
CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS="${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS:-true}"
CURRENT_PRODUCTION_REQUIRE_PUBLIC_PORT_POLICY="${CURRENT_PRODUCTION_REQUIRE_PUBLIC_PORT_POLICY:-}"
CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS="${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS:-86400}"
CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER="${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER:-false}"
CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080="${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080:-false}"
CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP="${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP:-true}"
CURRENT_PRODUCTION_RESCUE_ARTIFACT="${CURRENT_PRODUCTION_RESCUE_ARTIFACT:-true}"
CURRENT_PRODUCTION_RESCUE_ARTIFACT_PACKAGE="${CURRENT_PRODUCTION_RESCUE_ARTIFACT_PACKAGE:-true}"
CURRENT_PRODUCTION_RESCUE_ARTIFACT_DIR="${CURRENT_PRODUCTION_RESCUE_ARTIFACT_DIR:-${RESULT_ROOT}/current-node-access-rescue}"
CURRENT_PRODUCTION_PROBE_PROTOCOL_PORTS="${CURRENT_PRODUCTION_PROBE_PROTOCOL_PORTS:-22 ${TCP_PORT}}"
CURRENT_PRODUCTION_PROBE_ADDITIONAL_HOSTS="${CURRENT_PRODUCTION_PROBE_ADDITIONAL_HOSTS:-${TCP_HOST}}"
CURRENT_PRODUCTION_HTTP_ENTRYPOINT_PROBE="${CURRENT_PRODUCTION_HTTP_ENTRYPOINT_PROBE:-${SCRIPT_DIR}/http_entrypoint_probe.sh}"
CURRENT_PRODUCTION_NON_LARGE_GROUP_RUNNER="${CURRENT_PRODUCTION_NON_LARGE_GROUP_RUNNER:-${SCRIPT_DIR}/run_non_large_group_regression.sh}"
CURRENT_PRODUCTION_SCENARIO_SUITE_RUNNER="${CURRENT_PRODUCTION_SCENARIO_SUITE_RUNNER:-${SCRIPT_DIR}/run_product_scenario_suite.sh}"
CURRENT_PRODUCTION_PRODUCTION_PROFILE_RUNNER="${CURRENT_PRODUCTION_PRODUCTION_PROFILE_RUNNER:-${SCRIPT_DIR}/run_production_profile.sh}"
CURRENT_PRODUCTION_PRODUCT_CAMPAIGN_RUNNER="${CURRENT_PRODUCTION_PRODUCT_CAMPAIGN_RUNNER:-${SCRIPT_DIR}/run_product_campaign.py}"
CURRENT_PRODUCTION_RESCUE_GENERATOR="${CURRENT_PRODUCTION_RESCUE_GENERATOR:-${SCRIPT_DIR}/generate_node_access_rescue_artifact.sh}"
CURRENT_PRODUCTION_VERIFY_ARTIFACTS="${CURRENT_PRODUCTION_VERIFY_ARTIFACTS:-true}"
CURRENT_PRODUCTION_ARTIFACT_VERIFIER="${CURRENT_PRODUCTION_ARTIFACT_VERIFIER:-${SCRIPT_DIR}/perf_current_production_readiness_verify.py}"
CURRENT_PRODUCTION_SCENARIO_STATUS_JSON="${CURRENT_PRODUCTION_SCENARIO_STATUS_JSON:-${RESULT_ROOT}/scenario-status-current.json}"
CURRENT_PRODUCTION_SLO_STATUS_JSON="${CURRENT_PRODUCTION_SLO_STATUS_JSON:-${RESULT_ROOT}/slo-status-current.json}"
CURRENT_PRODUCTION_SLO_DOMAIN_SCORECARD_JSON="${CURRENT_PRODUCTION_SLO_DOMAIN_SCORECARD_JSON:-${RESULT_ROOT}/slo-domain-scorecard-current.json}"
CURRENT_PRODUCTION_NEXT_ACTIONS_JSON="${CURRENT_PRODUCTION_NEXT_ACTIONS_JSON:-${RESULT_ROOT}/next-actions-current.json}"
CURRENT_PRODUCTION_SCENARIO_CATALOG_JSON="${CURRENT_PRODUCTION_SCENARIO_CATALOG_JSON:-${RESULT_ROOT}/scenario-catalog-current.json}"
CURRENT_PRODUCTION_DOMAIN_BACKLOG_JSON="${CURRENT_PRODUCTION_DOMAIN_BACKLOG_JSON:-${RESULT_ROOT}/domain-backlog-current.json}"
CURRENT_PRODUCTION_RUN_PLAN_JSON="${CURRENT_PRODUCTION_RUN_PLAN_JSON:-${RESULT_ROOT}/run-plan-current.json}"
CURRENT_PRODUCTION_DOMAIN_RUN_PLAN_JSON="${CURRENT_PRODUCTION_DOMAIN_RUN_PLAN_JSON:-${RESULT_ROOT}/domain-run-plan-current.json}"
CURRENT_PRODUCTION_SLO_DOMAIN_RUN_PLAN_JSON="${CURRENT_PRODUCTION_SLO_DOMAIN_RUN_PLAN_JSON:-${RESULT_ROOT}/slo-domain-run-plan-current.json}"
CURRENT_PRODUCTION_DOMAIN_SCORECARD_JSON="${CURRENT_PRODUCTION_DOMAIN_SCORECARD_JSON:-${RESULT_ROOT}/domain-scorecard-current.json}"
CURRENT_PRODUCTION_PREREQ_AUDIT_JSON="${CURRENT_PRODUCTION_PREREQ_AUDIT_JSON:-${RESULT_ROOT}/prereq-audit-current.json}"
CURRENT_PRODUCTION_READINESS_GATE_JSON="${CURRENT_PRODUCTION_READINESS_GATE_JSON:-${RESULT_ROOT}/readiness-gate-current.json}"
CURRENT_PRODUCTION_PRODUCTION_GATE_JSON="${CURRENT_PRODUCTION_PRODUCTION_GATE_JSON:-${RESULT_ROOT}/production-gate.json}"
CURRENT_PRODUCTION_SELF_TEST="${CURRENT_PRODUCTION_SELF_TEST:-false}"

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
if [[ -z "${CURRENT_PRODUCTION_PROBE_ADDITIONAL_HOSTS}" ]]; then
  CURRENT_PRODUCTION_PROBE_ADDITIONAL_HOSTS="${TCP_HOST}"
fi

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

packageable_acceptance_requested() {
  bool_enabled "${CURRENT_PRODUCTION_RUN_BASELINE}" || bool_enabled "${CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE}"
}

resolve_current_production_require_cloud_security_group() {
  if [[ -n "${CURRENT_PRODUCTION_REQUIRE_CLOUD_SECURITY_GROUP}" ]]; then
    printf '%s\n' "${CURRENT_PRODUCTION_REQUIRE_CLOUD_SECURITY_GROUP}"
    return 0
  fi
  if bool_enabled "${CURRENT_PRODUCTION_REQUIRE_PACKAGEABLE_EVIDENCE}" && packageable_acceptance_requested; then
    printf 'true\n'
    return 0
  fi
  printf 'false\n'
}

resolve_current_production_require_public_port_policy() {
  if [[ -n "${CURRENT_PRODUCTION_REQUIRE_PUBLIC_PORT_POLICY}" ]]; then
    printf '%s\n' "${CURRENT_PRODUCTION_REQUIRE_PUBLIC_PORT_POLICY}"
    return 0
  fi
  if bool_enabled "${CURRENT_PRODUCTION_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE:-false}"; then
    printf 'true\n'
    return 0
  fi
  printf 'false\n'
}

resolve_current_production_require_cloud_security_group_repair_receipt() {
  if [[ -n "${CURRENT_PRODUCTION_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT}" ]]; then
    printf '%s\n' "${CURRENT_PRODUCTION_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT}"
    return 0
  fi
  if bool_enabled "${CURRENT_PRODUCTION_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE:-false}"; then
    printf 'true\n'
    return 0
  fi
  printf 'false\n'
}

resolve_current_production_run_baseline() {
  if [[ "${CURRENT_PRODUCTION_RUN_BASELINE_WAS_SET}" == "true" ]]; then
    if bool_enabled "${CURRENT_PRODUCTION_RUN_BASELINE}"; then
      printf 'true\n'
    else
      printf 'false\n'
    fi
    return 0
  fi
  if bool_enabled "${CURRENT_PRODUCTION_REQUIRE_PACKAGEABLE_EVIDENCE}" && bool_enabled "${CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE}"; then
    printf 'true\n'
    return 0
  fi
  printf 'false\n'
}

resolve_current_production_run_scenario_suite() {
  if [[ "${CURRENT_PRODUCTION_RUN_SCENARIO_SUITE_WAS_SET}" == "true" ]]; then
    if bool_enabled "${CURRENT_PRODUCTION_RUN_SCENARIO_SUITE}"; then
      printf 'true\n'
    else
      printf 'false\n'
    fi
    return 0
  fi
  if bool_enabled "${CURRENT_PRODUCTION_REQUIRE_PACKAGEABLE_EVIDENCE}" && packageable_acceptance_requested; then
    printf 'true\n'
    return 0
  fi
  printf 'false\n'
}

CURRENT_PRODUCTION_RUN_BASELINE="$(resolve_current_production_run_baseline)"
CURRENT_PRODUCTION_RUN_SCENARIO_SUITE="$(resolve_current_production_run_scenario_suite)"
CURRENT_PRODUCTION_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE="$(resolve_current_production_require_cloud_security_group)"
CURRENT_PRODUCTION_REQUIRE_PUBLIC_PORT_POLICY_EFFECTIVE="$(resolve_current_production_require_public_port_policy)"
CURRENT_PRODUCTION_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EFFECTIVE="$(resolve_current_production_require_cloud_security_group_repair_receipt)"

append_dashboard_arg() {
  local flag="$1"
  local path="$2"
  if [[ -n "${path}" && -f "${path}" ]]; then
    dashboard_args+=("${flag}" "${path}")
  fi
}

append_state_arg() {
  local flag="$1"
  local path="$2"
  if [[ -n "${path}" && -f "${path}" ]]; then
    state_args+=("${flag}" "${path}")
  fi
}

usage() {
  cat <<'EOF'
Usage:
  run_current_production_readiness.sh [--help]

Purpose:
  One stable entrypoint for current production validation. It first probes the
  public HTTP/TCP entrypoints. If the entrypoint is blocked, it generates the
  node-access rescue artifact and current production state/dashboard outputs.
  If the entrypoint is healthy, it can run normal-product smoke and, when
  enabled, the resumable normal-product production baseline.

Common env:
  BASE_URL=https://chat.prod.company.com
  TCP_HOST=tcp.prod.company.com
  TCP_PORT=9000
  ACCOUNT_FILE=/path/load-5000.csv
  IM_CONVERSATION_ID=<uuid>
  IM_INTERNAL_SECRET=<secret>
  RESULT_ROOT=IMServer/LoadTests/results
  CURRENT_PRODUCTION_RUN_SMOKE=true|false
  CURRENT_PRODUCTION_RUN_SCENARIO_SUITE=true|false
  CURRENT_PRODUCTION_SCENARIO_SUITE=recommended
  CURRENT_PRODUCTION_RUN_BASELINE=true|false
  Replace prod.company.com examples before running; production gates reject literal placeholder domains.
  For local development only, override BASE_URL=http://127.0.0.1:8080 and TCP_HOST=127.0.0.1.
  CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE=true|false
  CURRENT_PRODUCTION_PROFILE=normal-product-baseline
  CURRENT_PRODUCTION_FULL_ACCEPTANCE_CAMPAIGN=production-full-acceptance
  CURRENT_PRODUCTION_REQUIRE_PACKAGEABLE_EVIDENCE=true|false
  CURRENT_PRODUCTION_REQUIRE_CLOUD_SECURITY_GROUP=true|false
  CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_FILE=/path/cloud-security-group.json
  CURRENT_PRODUCTION_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT=true|false
  CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON=/path/cloud-security-group-repair-receipt.json
  CURRENT_PRODUCTION_REQUIRE_PUBLIC_PORT_POLICY=true|false
  CURRENT_PRODUCTION_PROBE_PROTOCOL_PORTS="22 9000"
  CURRENT_PRODUCTION_PROBE_ADDITIONAL_HOSTS="tcp-host"
  CURRENT_PRODUCTION_OPERATOR_NETWORK_PREFLIGHT=true|false
  CURRENT_PRODUCTION_FAIL_ON_OPERATOR_NETWORK=true|false
  CURRENT_PRODUCTION_FAIL_ON_LOCAL_NETWORK=true|false
  CURRENT_PRODUCTION_RESCUE_ARTIFACT=true|false
  CURRENT_PRODUCTION_RESCUE_ARTIFACT_DIR=results/current-node-access-rescue
  CURRENT_PRODUCTION_VERIFY_ARTIFACTS=true|false
  SSH_PRIVATE_KEY_PATH=/path/key.pem or SSH_AUTHORIZED_KEY='ssh-ed25519 ...'
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

json_value() {
  local path="$1"
  local expression="$2"
  python3 - "${path}" "${expression}" <<'PY'
import json
import os
import sys
from pathlib import Path

path, expression = sys.argv[1:3]
try:
    payload = json.loads(Path(path).read_text(encoding="utf-8"))
except Exception:
    print("")
    raise SystemExit(0)
value = payload
for part in expression.split("."):
    if not part:
        continue
    if isinstance(value, dict):
        value = value.get(part, "")
    else:
        value = ""
        break
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
else:
    print(str(value))
PY
}

write_entrypoint_summary_from_probe() {
  local probe_json="$1"
  local summary_file="$2"
  mkdir -p "$(dirname "${summary_file}")"
  python3 - "${probe_json}" "${summary_file}" <<'PY'
import json
import sys
import time
from pathlib import Path

probe_path, output_path = sys.argv[1:3]
try:
    probe = json.loads(Path(probe_path).read_text(encoding="utf-8"))
except Exception:
    probe = {}
blocker = probe.get("blocker") or {}
signals = probe.get("signals") or {}
lines = {
    "status": "BLOCKED" if probe.get("failed") else "OK",
    "entrypointFailed": "true" if probe.get("failed") else "false",
    "entrypointDiagnosis": str(probe.get("diagnosis") or "unknown"),
    "entrypointDetail": str(probe.get("detail") or ""),
    "rescuePlanAction": str(blocker.get("action") or "repair_entrypoint"),
    "entrypointTcpStatus": str(probe.get("tcpStatus") or signals.get("tcpStatus") or ""),
    "edgeIntercept": str(probe.get("edgeIntercept") or signals.get("edgeIntercept") or ""),
    "portProtocolCount": str(len(probe.get("portProtocols") or signals.get("portProtocols") or [])),
}
Path(output_path).write_text("".join(f"{key}={value}\n" for key, value in lines.items()), encoding="utf-8")
PY
}

write_probe_fallback_json() {
  local probe_json="$1"
  local diagnosis="$2"
  local detail="$3"
  local action="${4:-repair_entrypoint_probe}"
  mkdir -p "$(dirname "${probe_json}")"
  python3 - "${probe_json}" "${BASE_URL}" "${TCP_HOST}" "${TCP_PORT}" "${diagnosis}" "${detail}" "${action}" <<'PY'
import json
import sys
import time
from pathlib import Path

output_path, base_url, tcp_host, tcp_port, diagnosis, detail, action = sys.argv[1:8]
payload = {
    "schemaVersion": 1,
    "generatedAtEpoch": int(time.time()),
    "baseURL": base_url,
    "tcpHost": tcp_host,
    "tcpPort": tcp_port,
    "failed": True,
    "diagnosis": diagnosis,
    "detail": detail,
    "signals": {
        "tcpStatus": "",
        "edgeIntercept": "",
        "portProtocols": [],
    },
    "blocker": {
        "type": "entrypoint",
        "severity": "P0",
        "preventsPerformanceEvidence": True,
        "action": action,
        "reason": detail,
    },
}
Path(output_path).write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
}

is_local_readiness_host() {
  local host="$1"
  python3 - "${host}" <<'PY'
import ipaddress
import sys

host = sys.argv[1].strip().lower()
if host in {"", "localhost"}:
    raise SystemExit(0)
try:
    address = ipaddress.ip_address(host.strip("[]"))
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if address.is_loopback else 1)
PY
}

operator_network_targets() {
  local targets=("${BASE_URL}")
  if ! is_local_readiness_host "${TCP_HOST}"; then
    targets+=("${TCP_HOST}:${TCP_PORT}")
  fi
  if [[ -n "${SSH_HOST:-}" ]] && ! is_local_readiness_host "${SSH_HOST}"; then
    targets+=("${SSH_HOST}")
  fi
  printf '%s\n' "${targets[@]}"
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

check_cloud_security_group_prereq() {
  local log_file="${RUN_DIR}/cloud-security-group-audit.log"
  if ! bool_enabled "${CURRENT_PRODUCTION_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE}"; then
    return 0
  fi
  if [[ -z "${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_FILE}" ]]; then
    printf 'cloud_security_group_snapshot_required requireCloudSecurityGroup=%s hint=set_CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_FILE\n' \
      "${CURRENT_PRODUCTION_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE}"
    return 1
  fi
  if [[ ! -f "${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_FILE}" ]]; then
    printf 'cloud_security_group_snapshot_missing path=%s\n' \
      "${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_FILE}"
    return 1
  fi
  if [[ ! -f "${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_AUDIT_SCRIPT}" ]]; then
    printf 'cloud_security_group_audit_script_missing path=%s\n' \
      "${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_AUDIT_SCRIPT}"
    return 1
  fi

  mkdir -p "${RUN_DIR}"
  set +e
  CLOUD_SECURITY_GROUP_RULES_FILE="${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_FILE}" \
  CLOUD_SECURITY_GROUP_PROFILE=production \
  CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS="${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS}" \
  CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS="${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS}" \
  CLOUD_SECURITY_GROUP_ADMIN_PORTS="${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_ADMIN_PORTS}" \
  CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS="${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS}" \
  CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS="${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS}" \
  CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER="${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER}" \
  CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080="${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080}" \
  CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP="${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_ALLOW_PUBLIC_ICMP}" \
    bash "${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_AUDIT_SCRIPT}" >"${log_file}" 2>&1
  local rc=$?
  set -e
  if [[ "${rc}" -ne 0 ]]; then
    printf 'cloud_security_group_audit_failed log=%s\n' "${log_file}"
    return 1
  fi
  return 0
}

check_cloud_security_group_repair_receipt_prereq() {
  local log_file="${RUN_DIR}/cloud-security-group-repair-receipt-verify.log"
  if ! bool_enabled "${CURRENT_PRODUCTION_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EFFECTIVE}"; then
    return 0
  fi
  if [[ -z "${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON}" ]]; then
    printf 'cloud_security_group_repair_receipt_required requireCloudSecurityGroupRepairReceipt=%s hint=set_CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON\n' \
      "${CURRENT_PRODUCTION_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EFFECTIVE}"
    return 1
  fi
  if [[ ! -f "${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON}" ]]; then
    printf 'cloud_security_group_repair_receipt_missing path=%s\n' \
      "${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON}"
    return 1
  fi
  if [[ ! -f "${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_VERIFY_SCRIPT}" ]]; then
    printf 'cloud_security_group_repair_receipt_verify_script_missing path=%s\n' \
      "${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_VERIFY_SCRIPT}"
    return 1
  fi

  mkdir -p "${RUN_DIR}"
  set +e
  ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON}" \
  ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_REQUIRE_APPLIED=true \
  ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_REQUIRE_VERIFIED=true \
  ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS="${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS}" \
  ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID="${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID}" \
  ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID="${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID}" \
  ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR="${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR}" \
    bash "${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_VERIFY_SCRIPT}" >"${log_file}" 2>&1
  local rc=$?
  set -e
  if [[ "${rc}" -ne 0 ]]; then
    printf 'cloud_security_group_repair_receipt_verify_failed log=%s\n' "${log_file}"
    return 1
  fi
  return 0
}

check_public_target_prereq() {
  if ! bool_enabled "${CURRENT_PRODUCTION_REQUIRE_PACKAGEABLE_EVIDENCE}"; then
    return 0
  fi
  local policy_output policy_rc
  policy_output="$(python3 "${PRODUCTION_TARGET_POLICY}" \
    --base-url "${BASE_URL}" \
    --tcp-host "${TCP_HOST}" \
    --tcp-port "${TCP_PORT}" \
    --reason-only 2>&1)" && return 0
  policy_rc=$?
  case "${policy_output}" in
    base_url_https_required*)
      printf 'public_base_url_https_required baseURL=%s hint=use_real_https_domain_or_set_CURRENT_PRODUCTION_REQUIRE_PACKAGEABLE_EVIDENCE=false_for_diagnostics\n' \
        "${BASE_URL}"
      ;;
    base_url_port_invalid*)
      printf 'public_base_url_port_invalid baseURL=%s\n' "${BASE_URL}"
      ;;
    base_url_default_https_port_required*)
      printf 'public_base_url_default_https_port_required baseURL=%s %s hint=terminate_public_https_on_443_and_proxy_to_internal_http\n' \
        "${BASE_URL}" "${policy_output#base_url_default_https_port_required }"
      ;;
    base_url_origin_required*)
      printf 'public_base_url_origin_required baseURL=%s %s hint=set_BASE_URL_to_the_public_https_origin_without_path_query_fragment_or_userinfo\n' \
        "${BASE_URL}" "${policy_output#base_url_origin_required }"
      ;;
    base_url_dns_required*)
      printf 'public_base_url_domain_required baseURL=%s %s hint=use_real_production_domain_not_raw_ip_or_placeholder\n' \
        "${BASE_URL}" "${policy_output#base_url_dns_required }"
      ;;
    tcp_host_dns_required*)
      printf 'tcp_host_domain_required %s hint=use_real_production_tcp_domain_not_raw_ip_or_placeholder\n' \
        "${policy_output#tcp_host_dns_required }"
      ;;
    tcp_port_required*)
      printf 'tcp_port_required %s hint=use_public_tcp_port_9000\n' \
        "${policy_output#tcp_port_required }"
      ;;
    tcp_port_invalid*)
      printf 'tcp_port_required %s hint=use_public_tcp_port_9000\n' \
        "${policy_output#tcp_port_invalid }"
      ;;
    missing_env*)
      printf 'public_target_required %s\n' "${policy_output#missing_env }"
      ;;
    *)
      printf '%s\n' "${policy_output}"
      ;;
  esac
  return "${policy_rc}"
}

requested_run_prereq_error() {
  local required_rows=0
  local required_by="-"
  if bool_enabled "${CURRENT_PRODUCTION_REQUIRE_PACKAGEABLE_EVIDENCE}" &&
    packageable_acceptance_requested &&
    [[ "${CURRENT_PRODUCTION_RUN_SMOKE_WAS_SET}" == "true" ]] &&
    ! bool_enabled "${CURRENT_PRODUCTION_RUN_SMOKE}"; then
    printf 'smoke_required_for_packageable_evidence run=baseline_or_full_acceptance requirePackageableEvidence=%s explicitSmoke=%s\n' \
      "${CURRENT_PRODUCTION_REQUIRE_PACKAGEABLE_EVIDENCE}" \
      "${CURRENT_PRODUCTION_RUN_SMOKE}"
    return 1
  fi
  if bool_enabled "${CURRENT_PRODUCTION_REQUIRE_PACKAGEABLE_EVIDENCE}" &&
    bool_enabled "${CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE}" &&
    [[ "${CURRENT_PRODUCTION_RUN_BASELINE_WAS_SET}" == "true" ]] &&
    ! bool_enabled "${CURRENT_PRODUCTION_RUN_BASELINE}"; then
    printf 'baseline_required_for_packageable_full_acceptance run=full_acceptance requirePackageableEvidence=%s explicitBaseline=%s\n' \
      "${CURRENT_PRODUCTION_REQUIRE_PACKAGEABLE_EVIDENCE}" \
      "${CURRENT_PRODUCTION_RUN_BASELINE}"
    return 1
  fi
  if bool_enabled "${CURRENT_PRODUCTION_REQUIRE_PACKAGEABLE_EVIDENCE}" &&
    packageable_acceptance_requested &&
    [[ "${CURRENT_PRODUCTION_RUN_SCENARIO_SUITE_WAS_SET}" == "true" ]] &&
    ! bool_enabled "${CURRENT_PRODUCTION_RUN_SCENARIO_SUITE}"; then
    printf 'product_scenario_suite_required_for_packageable_evidence run=baseline_or_full_acceptance requirePackageableEvidence=%s explicitProductScenarioSuite=%s\n' \
      "${CURRENT_PRODUCTION_REQUIRE_PACKAGEABLE_EVIDENCE}" \
      "${CURRENT_PRODUCTION_RUN_SCENARIO_SUITE}"
    return 1
  fi
  if ! check_public_target_prereq; then
    return 1
  fi
  if bool_enabled "${CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE}"; then
    required_rows=10000
    required_by="full-acceptance"
  elif bool_enabled "${CURRENT_PRODUCTION_RUN_SCENARIO_SUITE}"; then
    required_rows=5000
    required_by="product-scenario-suite"
  elif bool_enabled "${CURRENT_PRODUCTION_RUN_BASELINE}"; then
    required_rows=5000
    required_by="baseline"
  elif bool_enabled "${CURRENT_PRODUCTION_RUN_SMOKE}"; then
    required_rows=1000
    required_by="smoke"
  fi

  if (( required_rows <= 0 )); then
    return 0
  fi

  local rows
  rows="$(usable_account_rows "${ACCOUNT_FILE}")"
  if [[ "${rows}" -lt "${required_rows}" ]]; then
    printf 'account_file_too_small run=%s rows=%s required=%s path=%s\n' \
      "${required_by}" \
      "${rows}" \
      "${required_rows}" \
      "${ACCOUNT_FILE:-<empty>}"
    return 1
  fi
  if [[ -z "${IM_CONVERSATION_ID}" ]]; then
    printf 'conversation_id_missing run=%s requiredFor=tcp-delivery path=%s\n' \
      "${required_by}" \
      "${ACCOUNT_FILE:-<empty>}"
    return 1
  fi
  if [[ -z "${IM_INTERNAL_SECRET}" ]]; then
    printf 'internal_secret_missing run=%s requiredFor=internal-write-scenarios\n' \
      "${required_by}"
    return 1
  fi
  if ! check_cloud_security_group_prereq; then
    return 1
  fi
  if ! check_cloud_security_group_repair_receipt_prereq; then
    return 1
  fi
  return 0
}

write_prereq_summary() {
  local detail="$1"
  local summary_file="${RUN_DIR}/current-production-prereq-summary.txt"
  mkdir -p "${RUN_DIR}"
  {
    printf 'status=FAIL\n'
    printf 'reason=requested_run_prereq_failed\n'
    printf 'detail=%s\n' "${detail}"
    printf 'accountFile=%s\n' "${ACCOUNT_FILE:-}"
    printf 'accountRows=%s\n' "$(usable_account_rows "${ACCOUNT_FILE}")"
    printf 'conversationIDPresent=%s\n' "$([[ -n "${IM_CONVERSATION_ID}" ]] && printf true || printf false)"
    printf 'internalSecretPresent=%s\n' "$([[ -n "${IM_INTERNAL_SECRET}" ]] && printf true || printf false)"
    printf 'runSmoke=%s\n' "${CURRENT_PRODUCTION_RUN_SMOKE}"
    printf 'runProductScenarioSuite=%s\n' "${CURRENT_PRODUCTION_RUN_SCENARIO_SUITE}"
    printf 'productScenarioSuite=%s\n' "${CURRENT_PRODUCTION_SCENARIO_SUITE}"
    printf 'runBaseline=%s\n' "${CURRENT_PRODUCTION_RUN_BASELINE}"
    printf 'runFullAcceptance=%s\n' "${CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE}"
    printf 'requirePackageableEvidence=%s\n' "${CURRENT_PRODUCTION_REQUIRE_PACKAGEABLE_EVIDENCE}"
    printf 'baseURL=%s\n' "${BASE_URL}"
	    printf 'tcpHost=%s\n' "${TCP_HOST}"
	    printf 'requireCloudSecurityGroup=%s\n' "${CURRENT_PRODUCTION_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE}"
	    printf 'requirePublicPortPolicy=%s\n' "${CURRENT_PRODUCTION_REQUIRE_PUBLIC_PORT_POLICY_EFFECTIVE}"
	    printf 'cloudSecurityGroupRulesFile=%s\n' "${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_FILE:-}"
    printf 'requireCloudSecurityGroupRepairReceipt=%s\n' "${CURRENT_PRODUCTION_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EFFECTIVE}"
    printf 'cloudSecurityGroupRepairReceiptJSON=%s\n' "${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON:-}"
    printf 'cloudSecurityGroupRepairReceiptVerifyLog=%s\n' "${RUN_DIR}/cloud-security-group-repair-receipt-verify.log"
    printf 'cloudSecurityGroupAuditLog=%s\n' "${RUN_DIR}/cloud-security-group-audit.log"
  } >"${summary_file}"
  printf '%s\n' "${summary_file}"
}

write_receipt() {
  local status="$1"
  local reason="$2"
  local probe_json="$3"
  local rescue_summary="$4"
  local smoke_rc="$5"
  local suite_rc="$6"
  local baseline_rc="$7"
  local full_acceptance_rc="$8"
  local output_json="${RUN_DIR}/current-production-readiness.json"
  local output_md="${RUN_DIR}/current-production-readiness.md"
  mkdir -p "${RUN_DIR}"
  python3 - \
    "${output_json}" \
    "${output_md}" \
    "${status}" \
    "${reason}" \
    "${BASE_URL}" \
    "${TCP_HOST}" \
    "${TCP_PORT}" \
    "${ACCOUNT_FILE}" \
    "${IM_CONVERSATION_ID}" \
    "${CURRENT_PRODUCTION_PROFILE}" \
    "${probe_json}" \
    "${rescue_summary}" \
    "${smoke_rc}" \
    "${suite_rc}" \
    "${baseline_rc}" \
    "${full_acceptance_rc}" \
    "${RUN_DIR}" \
    "${CURRENT_PRODUCTION_RUN_SMOKE}" \
    "${CURRENT_PRODUCTION_SMOKE_MODE}" \
    "${CURRENT_PRODUCTION_RUN_SCENARIO_SUITE}" \
    "${CURRENT_PRODUCTION_SCENARIO_SUITE}" \
    "${CURRENT_PRODUCTION_RUN_BASELINE}" \
    "${CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE}" \
    "${CURRENT_PRODUCTION_FULL_ACCEPTANCE_CAMPAIGN}" \
    "${CURRENT_PRODUCTION_REQUIRE_PACKAGEABLE_EVIDENCE}" \
    "${CURRENT_PRODUCTION_REQUIRE_CLOUD_SECURITY_GROUP_EFFECTIVE}" \
    "${CURRENT_PRODUCTION_REQUIRE_PUBLIC_PORT_POLICY_EFFECTIVE}" \
    "${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_FILE}" \
    "${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS}" \
    "${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER}" \
    "${CURRENT_PRODUCTION_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EFFECTIVE}" \
    "${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON}" \
    "${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS}" \
    "${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID}" \
    "${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID}" \
    "${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR}" \
    "${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080}" \
    "${CURRENT_PRODUCTION_OPERATOR_NETWORK_PREFLIGHT}" \
    "${SCRIPT_DIR}" <<'PY'
import json
import sys
import time
from pathlib import Path

(
    output_json,
    output_md,
    status,
    reason,
    base_url,
    tcp_host,
    tcp_port,
    account_file,
    conversation_id,
    profile,
    probe_json,
    rescue_summary,
    smoke_rc,
    suite_rc,
    baseline_rc,
    full_acceptance_rc,
    run_dir,
    run_smoke,
    smoke_mode,
    run_suite,
    suite_name,
    run_baseline,
    run_full_acceptance,
    full_acceptance_campaign,
    require_packageable_evidence,
    require_cloud_security_group,
    require_public_port_policy,
    cloud_security_group_rules_file,
    cloud_security_group_rules_max_age_seconds,
    cloud_security_group_rules_require_root_owner,
    require_cloud_security_group_repair_receipt,
    cloud_security_group_repair_receipt_json,
    cloud_security_group_repair_receipt_max_age_seconds,
    cloud_security_group_repair_receipt_expect_security_group_id,
    cloud_security_group_repair_receipt_expect_region_id,
    cloud_security_group_repair_receipt_expect_admin_cidr,
    cloud_security_group_allow_temp_http_8080,
    operator_network_preflight,
    script_dir,
) = sys.argv[1:40]

def bool_text(value: str) -> bool:
    return value.lower() in {"1", "true", "yes", "on"}

def read_json(path: str) -> dict:
    if not path:
        return {}
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except Exception:
        return {}

probe = read_json(probe_json)
operator_network_json_path = Path(run_dir) / "operator-network.json"
operator_network = read_json(str(operator_network_json_path))
runs = {
    "smokeExitCode": None if smoke_rc == "-" else int(smoke_rc),
    "suiteExitCode": None if suite_rc == "-" else int(suite_rc),
    "baselineExitCode": None if baseline_rc == "-" else int(baseline_rc),
    "fullAcceptanceExitCode": None if full_acceptance_rc == "-" else int(full_acceptance_rc),
}
run_dir_path = Path(run_dir)
artifacts = {
    "runDir": run_dir,
    "rescueSummary": rescue_summary,
    "operatorNetworkLog": str(run_dir_path / "operator-network.log"),
    "operatorNetworkJSON": str(run_dir_path / "operator-network.json"),
    "entrypointProbeLog": str(run_dir_path / "entrypoint-probe.log"),
    "stateSummary": str(run_dir_path / "current-production-state-summary.md"),
    "dashboard": str(run_dir_path / "current-production-dashboard.md"),
}
if runs["smokeExitCode"] is not None:
    artifacts["smokeLog"] = str(run_dir_path / "normal-product-smoke.log")
if runs["suiteExitCode"] is not None:
    suite_dir = run_dir_path / "product-scenario-suite"
    artifacts["productScenarioSuiteLog"] = str(run_dir_path / "product-scenario-suite.log")
    suite_run_json = suite_dir / "product-scenario-suite-run.json"
    suite_run_md = suite_dir / "product-scenario-suite-run.md"
    suite_stages = suite_dir / "product-scenario-suite-stages.tsv"
    if suite_run_json.is_file():
        artifacts["productScenarioSuiteRunJSON"] = str(suite_run_json)
    if suite_run_md.is_file():
        artifacts["productScenarioSuiteRunMarkdown"] = str(suite_run_md)
    if suite_stages.is_file():
        artifacts["productScenarioSuiteStagesTSV"] = str(suite_stages)
if runs["baselineExitCode"] is not None:
    artifacts["baselineLog"] = str(run_dir_path / "normal-product-baseline.log")
if runs["fullAcceptanceExitCode"] is not None:
    full_dir = run_dir_path / "production-full-acceptance"
    artifacts["fullAcceptanceLog"] = str(run_dir_path / "production-full-acceptance.log")
    full_run_json = full_dir / "product-campaign-run.json"
    full_runbook = full_dir / "product-campaign-runbook.md"
    if full_run_json.is_file():
        artifacts["fullAcceptanceRunJSON"] = str(full_run_json)
    if full_runbook.is_file():
        artifacts["fullAcceptanceRunbook"] = str(full_runbook)
prereq_summary = run_dir_path / "current-production-prereq-summary.txt"
if prereq_summary.is_file():
    artifacts["prereqSummary"] = str(prereq_summary)
cloud_security_group_log = run_dir_path / "cloud-security-group-audit.log"
if cloud_security_group_log.is_file():
    artifacts["cloudSecurityGroupAuditLog"] = str(cloud_security_group_log)
if cloud_security_group_rules_file and Path(cloud_security_group_rules_file).is_file():
    artifacts["cloudSecurityGroupRulesFile"] = cloud_security_group_rules_file
cloud_security_group_repair_receipt_log = run_dir_path / "cloud-security-group-repair-receipt-verify.log"
if cloud_security_group_repair_receipt_log.is_file():
    artifacts["cloudSecurityGroupRepairReceiptVerifyLog"] = str(cloud_security_group_repair_receipt_log)
if cloud_security_group_repair_receipt_json and Path(cloud_security_group_repair_receipt_json).is_file():
    artifacts["cloudSecurityGroupRepairReceiptJSON"] = cloud_security_group_repair_receipt_json
if rescue_summary:
    rescue_summary_path = Path(rescue_summary)
    rescue_dir = rescue_summary_path.parent
    rescue_manifest = rescue_dir / "artifact-manifest.json"
    rescue_tarball = Path(f"{rescue_dir}.tar.gz")
    if rescue_manifest.is_file():
        artifacts["rescueArtifactDir"] = str(rescue_dir)
        artifacts["rescueManifest"] = str(rescue_manifest)
    if rescue_tarball.is_file():
        artifacts["rescueTarball"] = str(rescue_tarball)
        artifacts["rescueTarballVerifyScript"] = f"{rescue_tarball}.verify.sh"
        artifacts["rescueTarballSha256"] = f"{rescue_tarball}.sha256"
        artifacts["rescueTarballReceipt"] = f"{rescue_tarball}.receipt.json"
payload = {
    "schemaVersion": 1,
    "status": status,
    "reason": reason,
    "generatedAtEpoch": int(time.time()),
    "target": {
        "baseURL": base_url,
        "tcpHost": tcp_host,
        "tcpPort": tcp_port,
        "accountFile": account_file,
        "conversationIDPresent": bool(conversation_id),
    },
    "profile": profile,
    "evidencePolicy": {
        "requirePackageableEvidence": bool_text(require_packageable_evidence),
        "requireCloudSecurityGroup": bool_text(require_cloud_security_group),
        "requirePublicPortPolicy": bool_text(require_public_port_policy),
        "allowTempHTTP8080": bool_text(cloud_security_group_allow_temp_http_8080),
        "cloudSecurityGroupRulesFile": cloud_security_group_rules_file,
        "cloudSecurityGroupRulesMaxAgeSeconds": int(cloud_security_group_rules_max_age_seconds or 0),
        "cloudSecurityGroupRulesRequireRootOwner": bool_text(cloud_security_group_rules_require_root_owner),
        "requireCloudSecurityGroupRepairReceipt": bool_text(require_cloud_security_group_repair_receipt),
        "cloudSecurityGroupRepairReceiptJSON": cloud_security_group_repair_receipt_json,
        "cloudSecurityGroupRepairReceiptMaxAgeSeconds": int(cloud_security_group_repair_receipt_max_age_seconds or 0),
        "cloudSecurityGroupRepairReceiptExpectSecurityGroupID": cloud_security_group_repair_receipt_expect_security_group_id,
        "cloudSecurityGroupRepairReceiptExpectRegionID": cloud_security_group_repair_receipt_expect_region_id,
        "cloudSecurityGroupRepairReceiptExpectAdminCIDR": cloud_security_group_repair_receipt_expect_admin_cidr,
        "operatorNetworkPreflight": bool_text(operator_network_preflight),
        "autoProductScenarioSuiteForPackageableAcceptance": bool_text(require_packageable_evidence)
        and (bool_text(run_baseline) or bool_text(run_full_acceptance)),
    },
    "requestedRuns": {
        "smoke": bool_text(run_smoke),
        "smokeMode": smoke_mode,
        "productScenarioSuite": bool_text(run_suite),
        "productScenarioSuiteName": suite_name,
        "baseline": bool_text(run_baseline),
        "fullAcceptance": bool_text(run_full_acceptance),
        "fullAcceptanceCampaign": full_acceptance_campaign,
    },
    "entrypoint": {
        "probeJSON": probe_json,
        "failed": bool(probe.get("failed")),
        "diagnosis": probe.get("diagnosis") or "",
        "detail": probe.get("detail") or "",
        "blocker": probe.get("blocker") or {},
    },
    "operatorNetwork": {
        "status": operator_network.get("status") or "",
        "failed": operator_network.get("failed"),
        "failureCount": operator_network.get("failureCount"),
        "warnings": operator_network.get("warnings") or [],
        "routeInterfaces": operator_network.get("routeInterfaces") or [],
        "routeGateways": operator_network.get("routeGateways") or [],
        "targetCount": operator_network.get("targetCount"),
        "action": operator_network.get("action") or "",
    },
    "artifacts": artifacts,
    "runs": runs,
}
Path(output_json).write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
sys.path.insert(0, script_dir)
from perf_current_production_readiness_verify import build_readiness_markdown

Path(output_md).write_text(build_readiness_markdown(payload), encoding="utf-8")
PY
}

verify_current_artifacts() {
  if ! bool_enabled "${CURRENT_PRODUCTION_VERIFY_ARTIFACTS}"; then
    printf 'current_production_readiness artifact_verifier=skipped reason=disabled\n'
    return 0
  fi
  if [[ ! -f "${CURRENT_PRODUCTION_ARTIFACT_VERIFIER}" ]]; then
    printf 'current_production_readiness artifact_verifier=fail reason=verifier_missing path=%s\n' \
      "${CURRENT_PRODUCTION_ARTIFACT_VERIFIER}" >&2
    return 1
  fi
  if ! python3 "${CURRENT_PRODUCTION_ARTIFACT_VERIFIER}" \
    --readiness-json "${RUN_DIR}/current-production-readiness.json" \
    >"${RUN_DIR}/current-production-readiness-verify.log"; then
    printf 'current_production_readiness artifact_verifier=fail log=%s\n' \
      "${RUN_DIR}/current-production-readiness-verify.log" >&2
    if [[ -f "${RUN_DIR}/current-production-readiness-verify.log" ]]; then
      sed -n '1,40p' "${RUN_DIR}/current-production-readiness-verify.log" >&2
    fi
    return 1
  fi
  printf 'current_production_readiness artifact_verifier=pass log=%s\n' \
    "${RUN_DIR}/current-production-readiness-verify.log"
}

refresh_current_link() {
  mkdir -p "${RESULT_ROOT}"
  rm -f "${CURRENT_PRODUCTION_LINK}"
  ln -s "${RUN_DIR}" "${CURRENT_PRODUCTION_LINK}"
}

generate_state_outputs() {
  local rescue_summary="$1"
  local dashboard_json="${RUN_DIR}/current-production-dashboard.json"
  local dashboard_md="${RUN_DIR}/current-production-dashboard.md"
  local state_json="${RUN_DIR}/current-production-state-summary.json"
  local state_md="${RUN_DIR}/current-production-state-summary.md"
  local state_csv="${RUN_DIR}/current-production-state-summary.csv"
  local dashboard_args=()
  local state_args=()

  append_dashboard_arg --scenario-status-json "${CURRENT_PRODUCTION_SCENARIO_STATUS_JSON}"
  append_dashboard_arg --slo-status-json "${CURRENT_PRODUCTION_SLO_STATUS_JSON}"
  append_dashboard_arg --slo-domain-scorecard-json "${CURRENT_PRODUCTION_SLO_DOMAIN_SCORECARD_JSON}"
  append_dashboard_arg --next-actions-json "${CURRENT_PRODUCTION_NEXT_ACTIONS_JSON}"
  append_dashboard_arg --scenario-catalog-json "${CURRENT_PRODUCTION_SCENARIO_CATALOG_JSON}"
  append_dashboard_arg --domain-backlog-json "${CURRENT_PRODUCTION_DOMAIN_BACKLOG_JSON}"
  append_dashboard_arg --run-plan-json "${CURRENT_PRODUCTION_RUN_PLAN_JSON}"
  append_dashboard_arg --domain-run-plan-json "${CURRENT_PRODUCTION_DOMAIN_RUN_PLAN_JSON}"
  append_dashboard_arg --slo-domain-run-plan-json "${CURRENT_PRODUCTION_SLO_DOMAIN_RUN_PLAN_JSON}"
  append_dashboard_arg --domain-scorecard-json "${CURRENT_PRODUCTION_DOMAIN_SCORECARD_JSON}"
  append_dashboard_arg --prereq-audit-json "${CURRENT_PRODUCTION_PREREQ_AUDIT_JSON}"
  append_dashboard_arg --readiness-gate-json "${CURRENT_PRODUCTION_READINESS_GATE_JSON}"
  append_dashboard_arg --production-gate-json "${CURRENT_PRODUCTION_PRODUCTION_GATE_JSON}"
  append_dashboard_arg --current-readiness-json "${RUN_DIR}/current-production-readiness.json"

  append_state_arg --scenario-status-json "${CURRENT_PRODUCTION_SCENARIO_STATUS_JSON}"
  append_state_arg --slo-status-json "${CURRENT_PRODUCTION_SLO_STATUS_JSON}"
  append_state_arg --slo-domain-scorecard-json "${CURRENT_PRODUCTION_SLO_DOMAIN_SCORECARD_JSON}"
  append_state_arg --readiness-gate-json "${CURRENT_PRODUCTION_READINESS_GATE_JSON}"
  append_state_arg --next-actions-json "${CURRENT_PRODUCTION_NEXT_ACTIONS_JSON}"
  append_state_arg --scenario-catalog-json "${CURRENT_PRODUCTION_SCENARIO_CATALOG_JSON}"
  append_state_arg --run-plan-json "${CURRENT_PRODUCTION_RUN_PLAN_JSON}"
  append_state_arg --production-gate-json "${CURRENT_PRODUCTION_PRODUCTION_GATE_JSON}"
  append_state_arg --current-readiness-json "${RUN_DIR}/current-production-readiness.json"

  if ((${#dashboard_args[@]} > 0)); then
    python3 "${SCRIPT_DIR}/perf_dashboard.py" \
      "${dashboard_args[@]}" \
      --entrypoint-rescue-summary "${rescue_summary}" \
      --output "${dashboard_md}" \
      --json-output "${dashboard_json}" >/dev/null
  else
    python3 "${SCRIPT_DIR}/perf_dashboard.py" \
      --entrypoint-rescue-summary "${rescue_summary}" \
      --output "${dashboard_md}" \
      --json-output "${dashboard_json}" >/dev/null
  fi
  if ((${#state_args[@]} > 0)); then
    python3 "${SCRIPT_DIR}/perf_state_summary.py" \
      "${state_args[@]}" \
      --dashboard-json "${dashboard_json}" \
      --entrypoint-rescue-summary "${rescue_summary}" \
      --output "${state_md}" \
      --json-output "${state_json}" \
      --csv-output "${state_csv}" >/dev/null
  else
    python3 "${SCRIPT_DIR}/perf_state_summary.py" \
      --dashboard-json "${dashboard_json}" \
      --entrypoint-rescue-summary "${rescue_summary}" \
      --output "${state_md}" \
      --json-output "${state_json}" \
      --csv-output "${state_csv}" >/dev/null
  fi

  cp "${dashboard_json}" "${RESULT_ROOT}/current-production-dashboard.json"
  cp "${dashboard_md}" "${RESULT_ROOT}/current-production-dashboard.md"
  cp "${state_json}" "${RESULT_ROOT}/current-production-state-summary.json"
  cp "${state_md}" "${RESULT_ROOT}/current-production-state-summary.md"
  cp "${state_csv}" "${RESULT_ROOT}/current-production-state-summary.csv"
}

run_entrypoint_probe() {
  local probe_log="${RUN_DIR}/entrypoint-probe.log"
  local probe_json="${RUN_DIR}/entrypoint-probe.json"
  if ! bool_enabled "${CURRENT_PRODUCTION_ENTRYPOINT_PROBE}"; then
    printf 'current_production_readiness entrypoint_probe=skipped reason=disabled\n'
    return 0
  fi
  mkdir -p "${RUN_DIR}"
  local fail_on_error="false"
  bool_enabled "${CURRENT_PRODUCTION_FAIL_ON_ENTRYPOINT_ERROR}" && fail_on_error="true"
  printf 'current_production_readiness entrypoint_probe=start baseURL=%s log=%s json=%s\n' \
    "${BASE_URL}" \
    "${probe_log}" \
    "${probe_json}"
  set +e
  BASE_URL="${BASE_URL}" \
  ACCOUNT_FILE="${ACCOUNT_FILE}" \
	  PROBE_FAIL_ON_ENTRYPOINT_ERROR="${fail_on_error}" \
	  PROBE_PROTOCOL_PORTS="${CURRENT_PRODUCTION_PROBE_PROTOCOL_PORTS}" \
	  PROBE_ADDITIONAL_PROTOCOL_HOSTS="${CURRENT_PRODUCTION_PROBE_ADDITIONAL_HOSTS}" \
	  PROBE_REQUIRE_PUBLIC_PORT_POLICY="${CURRENT_PRODUCTION_REQUIRE_PUBLIC_PORT_POLICY_EFFECTIVE}" \
	  PROBE_PUBLIC_EXPECT_OPEN_PORTS="${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS}" \
	  PROBE_PUBLIC_DENY_PORTS="${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS}" \
	  PROBE_FAIL_ON_LOCAL_NETWORK="${CURRENT_PRODUCTION_FAIL_ON_LOCAL_NETWORK}" \
	  PROBE_JSON_OUTPUT="${probe_json}" \
    "${CURRENT_PRODUCTION_HTTP_ENTRYPOINT_PROBE}" >"${probe_log}" 2>&1
  local rc=$?
  set -e
  if [[ ! -f "${probe_json}" ]]; then
    write_probe_fallback_json \
      "${probe_json}" \
      "probe_json_missing" \
      "Entrypoint probe command exited without writing PROBE_JSON_OUTPUT; inspect entrypoint-probe.log before running load."
    return 1
  fi
  if [[ "${rc}" -ne 0 || "$(json_value "${probe_json}" failed)" == "true" ]]; then
    return 1
  fi
  printf 'current_production_readiness entrypoint_probe=pass json=%s\n' "${probe_json}"
  return 0
}

run_operator_network_preflight() {
  local network_log="${RUN_DIR}/operator-network.log"
  local network_json="${RUN_DIR}/operator-network.json"
  local probe_json="${RUN_DIR}/entrypoint-probe.json"
  local fail_on_operator_network="false"
  local targets=()

  if ! bool_enabled "${CURRENT_PRODUCTION_OPERATOR_NETWORK_PREFLIGHT}"; then
    printf 'current_production_readiness operator_network=skipped reason=disabled\n'
    return 0
  fi
  if [[ ! -f "${CURRENT_PRODUCTION_OPERATOR_NETWORK_PREFLIGHT_SCRIPT}" ]]; then
    printf 'current_production_readiness operator_network=skipped reason=script_missing path=%s\n' \
      "${CURRENT_PRODUCTION_OPERATOR_NETWORK_PREFLIGHT_SCRIPT}"
    return 0
  fi

  mkdir -p "${RUN_DIR}"
  bool_enabled "${CURRENT_PRODUCTION_FAIL_ON_OPERATOR_NETWORK}" && fail_on_operator_network="true"
  while IFS= read -r target; do
    [[ -n "${target}" ]] && targets+=("${target}")
  done < <(operator_network_targets)

  printf 'current_production_readiness operator_network=start targets=%s log=%s\n' \
    "${#targets[@]}" \
    "${network_log}"

  set +e
  OPERATOR_NETWORK_JSON_OUTPUT="${network_json}" \
    bash "${CURRENT_PRODUCTION_OPERATOR_NETWORK_PREFLIGHT_SCRIPT}" "${targets[@]}" >"${network_log}" 2>&1
  local rc=$?
  set -e
  if [[ "${rc}" -ne 0 ]]; then
    if [[ "${fail_on_operator_network}" == "true" ]]; then
      write_probe_fallback_json \
        "${probe_json}" \
        "local_operator_network_blocked" \
        "Operator workstation route/proxy preflight failed; inspect operator-network.log and disconnect local TUN/proxy before collecting production evidence." \
        "disconnect_local_tun_or_use_clean_network"
      printf 'current_production_readiness operator_network=fail log=%s\n' "${network_log}" >&2
      return 1
    fi
    printf 'current_production_readiness operator_network=warn log=%s\n' "${network_log}" >&2
    return 0
  fi

  printf 'current_production_readiness operator_network=pass log=%s\n' "${network_log}"
  return 0
}

generate_rescue_artifact() {
  local rescue_log="${RUN_DIR}/entrypoint-rescue-artifact.log"
  local rescue_dir blocker_action
  rescue_dir="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve())' "${CURRENT_PRODUCTION_RESCUE_ARTIFACT_DIR}")"
  blocker_action="$(json_value "${RUN_DIR}/entrypoint-probe.json" blocker.action)"
  if [[ "${blocker_action}" != "cloud_console_rescue_required" ]]; then
    printf 'current_production_readiness rescue_artifact=skipped reason=probe_action_not_cloud_console action=%s\n' \
      "${blocker_action:-<none>}"
    write_entrypoint_summary_from_probe "${RUN_DIR}/entrypoint-probe.json" "${RUN_DIR}/entrypoint-rescue-summary.txt"
    printf '%s\n' "${RUN_DIR}/entrypoint-rescue-summary.txt"
    return 0
  fi
  if ! bool_enabled "${CURRENT_PRODUCTION_RESCUE_ARTIFACT}"; then
    printf 'current_production_readiness rescue_artifact=skipped reason=disabled\n'
    write_entrypoint_summary_from_probe "${RUN_DIR}/entrypoint-probe.json" "${RUN_DIR}/entrypoint-rescue-summary.txt"
    printf '%s\n' "${RUN_DIR}/entrypoint-rescue-summary.txt"
    return 0
  fi
  if [[ -z "${SSH_PRIVATE_KEY_PATH:-}" && -z "${SSH_AUTHORIZED_KEY:-}" && "${CURRENT_PRODUCTION_RESCUE_GENERATOR}" == "${SCRIPT_DIR}/generate_node_access_rescue_artifact.sh" ]]; then
    printf 'current_production_readiness rescue_artifact=skipped reason=missing_ssh_key_source\n'
    write_entrypoint_summary_from_probe "${RUN_DIR}/entrypoint-probe.json" "${RUN_DIR}/entrypoint-rescue-summary.txt"
    printf '%s\n' "${RUN_DIR}/entrypoint-rescue-summary.txt"
    return 0
  fi
  printf 'current_production_readiness rescue_artifact=start dir=%s log=%s\n' "${rescue_dir}" "${rescue_log}"
  if NODE_ACCESS_RESCUE_ARTIFACT_DIR="${rescue_dir}" \
    NODE_ACCESS_RESCUE_ARTIFACT_PACKAGE="${CURRENT_PRODUCTION_RESCUE_ARTIFACT_PACKAGE}" \
    PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-${BASE_URL}}" \
    BASE_URL="${BASE_URL}" \
    TCP_HOST="${TCP_HOST}" \
    TCP_PORT="${TCP_PORT}" \
    IM_TCP_PORT="${TCP_PORT}" \
    ACCOUNT_FILE="${ACCOUNT_FILE}" \
    PRODUCT_TEST_PHASES="entrypoint real-world-smoke" \
    PRODUCT_TEST_RUN_FULL_PROFILE=false \
    PRODUCT_TEST_STOP_ON_FAILURE=true \
    PERF_DRY_RUN=false \
      "${CURRENT_PRODUCTION_RESCUE_GENERATOR}" >"${rescue_log}" 2>&1; then
    if [[ -f "${rescue_dir}/summary.txt" ]]; then
      printf 'current_production_readiness rescue_artifact=pass dir=%s\n' "${rescue_dir}"
      printf '%s\n' "${rescue_dir}/summary.txt"
      return 0
    fi
  fi
  printf 'current_production_readiness rescue_artifact=fail log=%s\n' "${rescue_log}" >&2
  write_entrypoint_summary_from_probe "${RUN_DIR}/entrypoint-probe.json" "${RUN_DIR}/entrypoint-rescue-summary.txt"
  printf '%s\n' "${RUN_DIR}/entrypoint-rescue-summary.txt"
}

run_smoke() {
  local smoke_log="${RUN_DIR}/normal-product-smoke.log"
  if ! bool_enabled "${CURRENT_PRODUCTION_RUN_SMOKE}"; then
    printf 'current_production_readiness smoke=skipped reason=disabled\n'
    return 0
  fi
  printf 'current_production_readiness smoke=start mode=%s log=%s\n' "${CURRENT_PRODUCTION_SMOKE_MODE}" "${smoke_log}"
  NON_LARGE_GROUP_MODE="${CURRENT_PRODUCTION_SMOKE_MODE}" \
  NON_LARGE_GROUP_RUN_ID_PREFIX="${RUN_ID}" \
  RESULT_ROOT="${RESULT_ROOT}" \
  BASE_URL="${BASE_URL}" \
  TCP_HOST="${TCP_HOST}" \
  TCP_PORT="${TCP_PORT}" \
  ACCOUNT_FILE="${ACCOUNT_FILE}" \
  IM_CONVERSATION_ID="${IM_CONVERSATION_ID}" \
  IM_INTERNAL_SECRET="${IM_INTERNAL_SECRET}" \
  NON_LARGE_GROUP_ENTRYPOINT_PROBE=false \
    "${CURRENT_PRODUCTION_NON_LARGE_GROUP_RUNNER}" >"${smoke_log}" 2>&1
}

run_product_scenario_suite() {
  local suite_log="${RUN_DIR}/product-scenario-suite.log"
  local suite_dir="${RUN_DIR}/product-scenario-suite"
  if ! bool_enabled "${CURRENT_PRODUCTION_RUN_SCENARIO_SUITE}"; then
    printf 'current_production_readiness product_scenario_suite=skipped reason=disabled\n'
    return 0
  fi
  printf 'current_production_readiness product_scenario_suite=start suite=%s log=%s\n' \
    "${CURRENT_PRODUCTION_SCENARIO_SUITE}" \
    "${suite_log}"
  PRODUCT_SCENARIO_SUITE="${CURRENT_PRODUCTION_SCENARIO_SUITE}" \
  PRODUCT_SCENARIO_RUN_ID_PREFIX="product-scenario-suite" \
  PRODUCT_SCENARIO_RECEIPT_DIR="${suite_dir}" \
  PRODUCT_SCENARIO_EXECUTE=true \
  PRODUCT_SCENARIO_INCLUDE_LARGE_GROUP=false \
  RESULT_ROOT="${RUN_DIR}" \
  BASE_URL="${BASE_URL}" \
  TCP_HOST="${TCP_HOST}" \
  TCP_PORT="${TCP_PORT}" \
  ACCOUNT_FILE="${ACCOUNT_FILE}" \
  IM_CONVERSATION_ID="${IM_CONVERSATION_ID}" \
  IM_INTERNAL_SECRET="${IM_INTERNAL_SECRET}" \
    "${CURRENT_PRODUCTION_SCENARIO_SUITE_RUNNER}" >"${suite_log}" 2>&1
}

run_baseline() {
  local baseline_log="${RUN_DIR}/normal-product-baseline.log"
  if ! bool_enabled "${CURRENT_PRODUCTION_RUN_BASELINE}"; then
    printf 'current_production_readiness baseline=skipped reason=disabled\n'
    return 0
  fi
  printf 'current_production_readiness baseline=start profile=%s log=%s\n' "${CURRENT_PRODUCTION_PROFILE}" "${baseline_log}"
  PERF_PRODUCTION_GATE_PROFILE="${CURRENT_PRODUCTION_PROFILE}" \
  RESULT_ROOT="${RESULT_ROOT}" \
  BASE_URL="${BASE_URL}" \
  TCP_HOST="${TCP_HOST}" \
  TCP_PORT="${TCP_PORT}" \
  ACCOUNT_FILE="${ACCOUNT_FILE}" \
  IM_CONVERSATION_ID="${IM_CONVERSATION_ID}" \
  IM_INTERNAL_SECRET="${IM_INTERNAL_SECRET}" \
  PRODUCTION_PROFILE_ENTRYPOINT_PROBE=false \
    "${CURRENT_PRODUCTION_PRODUCTION_PROFILE_RUNNER}" >"${baseline_log}" 2>&1
}

run_full_acceptance() {
  local full_log="${RUN_DIR}/production-full-acceptance.log"
  local full_dir="${RUN_DIR}/production-full-acceptance"
  if ! bool_enabled "${CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE}"; then
    printf 'current_production_readiness full_acceptance=skipped reason=disabled\n'
    return 0
  fi
  printf 'current_production_readiness full_acceptance=start campaign=%s log=%s\n' \
    "${CURRENT_PRODUCTION_FULL_ACCEPTANCE_CAMPAIGN}" \
    "${full_log}"
  if [[ "${CURRENT_PRODUCTION_PRODUCT_CAMPAIGN_RUNNER}" == *.py ]]; then
    BASE_URL="${BASE_URL}" \
    TCP_HOST="${TCP_HOST}" \
    TCP_PORT="${TCP_PORT}" \
    ACCOUNT_FILE="${ACCOUNT_FILE}" \
    IM_CONVERSATION_ID="${IM_CONVERSATION_ID}" \
    IM_INTERNAL_SECRET="${IM_INTERNAL_SECRET}" \
    python3 "${CURRENT_PRODUCTION_PRODUCT_CAMPAIGN_RUNNER}" \
      --campaign "${CURRENT_PRODUCTION_FULL_ACCEPTANCE_CAMPAIGN}" \
      --result-dir "${full_dir}" \
      --execute >"${full_log}" 2>&1
  else
    BASE_URL="${BASE_URL}" \
    TCP_HOST="${TCP_HOST}" \
    TCP_PORT="${TCP_PORT}" \
    ACCOUNT_FILE="${ACCOUNT_FILE}" \
    IM_CONVERSATION_ID="${IM_CONVERSATION_ID}" \
    IM_INTERNAL_SECRET="${IM_INTERNAL_SECRET}" \
      "${CURRENT_PRODUCTION_PRODUCT_CAMPAIGN_RUNNER}" \
      --campaign "${CURRENT_PRODUCTION_FULL_ACCEPTANCE_CAMPAIGN}" \
      --result-dir "${full_dir}" \
      --execute >"${full_log}" 2>&1
  fi
}

run_self_test() {
  local tmpdir fake_probe fake_rescue fake_non_large fake_suite fake_profile fake_campaign fake_operator_fail fake_operator_pass fake_cloud_security_group_audit_pass
  tmpdir="$(mktemp -d)"
  trap "rm -rf '${tmpdir}'" EXIT
  export CURRENT_PRODUCTION_OPERATOR_NETWORK_PREFLIGHT=false

  fake_probe="${tmpdir}/fake-probe.sh"
  cat >"${fake_probe}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$(dirname "${PROBE_JSON_OUTPUT}")"
if [[ "${FAKE_PROBE_RESULT:-fail}" == "pass" ]]; then
  cat >"${PROBE_JSON_OUTPUT}" <<'JSON'
{"schemaVersion":1,"failed":false,"diagnosis":"ok","detail":"self-test ok","publicPortPolicyStatus":"pass","publicDeniedPortsOpen":[],"publicExpectedPortsMissing":[],"blocker":{"preventsPerformanceEvidence":false}}
JSON
  printf 'fake probe pass\n'
  exit 0
fi
cat >"${PROBE_JSON_OUTPUT}" <<'JSON'
{"schemaVersion":1,"failed":true,"diagnosis":"cloud_edge_http_403_intercept","detail":"self-test blocked","tcpStatus":"http_403_intercepted","edgeIntercept":"http_403_all_sampled_ports","portProtocols":[{"label":"base","port":"8080","protocol":"http_403_intercepted"}],"blocker":{"type":"entrypoint","severity":"P0","preventsPerformanceEvidence":true,"action":"cloud_console_rescue_required"}}
JSON
printf 'fake probe fail\n'
exit 1
SH
  chmod +x "${fake_probe}"
  fake_probe_missing_json="${tmpdir}/fake-probe-missing-json.sh"
  cat >"${fake_probe_missing_json}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'fake probe failed before json\n'
exit 1
SH
  chmod +x "${fake_probe_missing_json}"

  fake_operator_fail="${tmpdir}/fake-operator-network-fail.sh"
cat >"${fake_operator_fail}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'operator-network result=fail failures=1 warningCount=1 allowTun=false failOnProxyEnv=false\n'
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
  fake_operator_pass="${tmpdir}/fake-operator-network-pass.sh"
cat >"${fake_operator_pass}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
for target in "$@"; do
  printf 'operator-network target=%s status=pass warning=clean routeInterface=en0 routeGateway=192.168.1.1 proxyEnv=<none>\n' "${target}"
done
if [[ -n "${OPERATOR_NETWORK_JSON_OUTPUT:-}" ]]; then
  python3 - "${OPERATOR_NETWORK_JSON_OUTPUT}" "$@" <<'PY'
import json
import sys
from pathlib import Path

output = sys.argv[1]
targets = sys.argv[2:]
Path(output).write_text(json.dumps({
    "schemaVersion": 1,
    "status": "pass",
    "failed": False,
    "failureCount": 0,
    "targetCount": len(targets),
    "warnings": [],
    "warningCounts": {},
    "routeInterfaces": ["en0"],
    "routeGateways": ["192.168.1.1"],
    "failedTargets": [],
    "targets": [{
        "target": target,
        "host": target,
        "status": "pass",
        "warning": "clean",
        "routeInterface": "en0",
        "routeGateway": "192.168.1.1",
        "proxyEnv": "<none>",
    } for target in targets],
    "action": "",
}, indent=2, sort_keys=True), encoding="utf-8")
PY
fi
  printf 'operator-network result=pass targets=%s\n' "$#"
SH
  chmod +x "${fake_operator_pass}"
  fake_cloud_security_group_audit_pass="${tmpdir}/fake-cloud-security-group-audit-pass.sh"
  cat >"${fake_cloud_security_group_audit_pass}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'cloud-security-group result=pass profile=production errors=0 warnings=0 rulesRequireRootOwner=true\n'
SH
  chmod +x "${fake_cloud_security_group_audit_pass}"

  fake_rescue="${tmpdir}/fake-rescue.sh"
  cat >"${fake_rescue}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "${NODE_ACCESS_RESCUE_ARTIFACT_DIR}"
cat >"${NODE_ACCESS_RESCUE_ARTIFACT_DIR}/summary.txt" <<'TXT'
status=BLOCKED
entrypointFailed=true
entrypointDiagnosis=cloud_edge_http_403_intercept
entrypointDetail=self-test blocked
rescuePlanAction=cloud_console_rescue_required
TXT
cat >"${NODE_ACCESS_RESCUE_ARTIFACT_DIR}/verify-artifact.sh" <<'SH2'
#!/usr/bin/env bash
set -euo pipefail
printf 'verify pass\n'
SH2
chmod +x "${NODE_ACCESS_RESCUE_ARTIFACT_DIR}/verify-artifact.sh"
printf '# Rescue Plan\n' >"${NODE_ACCESS_RESCUE_ARTIFACT_DIR}/entrypoint-rescue-plan.md"
printf '{"schemaVersion":1,"diagnosis":"cloud_edge_http_403_intercept"}\n' >"${NODE_ACCESS_RESCUE_ARTIFACT_DIR}/artifact-manifest.json"
printf 'synthetic rescue tarball\n' >"${NODE_ACCESS_RESCUE_ARTIFACT_DIR}.tar.gz"
printf 'synthetic verify\n' >"${NODE_ACCESS_RESCUE_ARTIFACT_DIR}.tar.gz.verify.sh"
printf 'synthetic sha\n' >"${NODE_ACCESS_RESCUE_ARTIFACT_DIR}.tar.gz.sha256"
printf '{"schemaVersion":1}\n' >"${NODE_ACCESS_RESCUE_ARTIFACT_DIR}.tar.gz.receipt.json"
printf 'fake rescue generated\n'
SH
  chmod +x "${fake_rescue}"
  fake_missing_json_rescue="${tmpdir}/fake-missing-json-rescue.sh"
  cat >"${fake_missing_json_rescue}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "${NODE_ACCESS_RESCUE_ARTIFACT_DIR}"
cat >"${NODE_ACCESS_RESCUE_ARTIFACT_DIR}/summary.txt" <<'TXT'
status=BLOCKED
entrypointFailed=true
entrypointDiagnosis=probe_json_missing
entrypointDetail=fallback probe json was generated
rescuePlanAction=repair_entrypoint_probe
TXT
cat >"${NODE_ACCESS_RESCUE_ARTIFACT_DIR}/verify-artifact.sh" <<'SH2'
#!/usr/bin/env bash
set -euo pipefail
printf 'verify pass\n'
SH2
chmod +x "${NODE_ACCESS_RESCUE_ARTIFACT_DIR}/verify-artifact.sh"
printf '# Rescue Plan\n' >"${NODE_ACCESS_RESCUE_ARTIFACT_DIR}/entrypoint-rescue-plan.md"
printf 'fake missing-json rescue generated\n'
SH
  chmod +x "${fake_missing_json_rescue}"

  fake_non_large="${tmpdir}/fake-non-large.sh"
  cat >"${fake_non_large}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'mode=%s base=%s tcp=%s\n' "${NON_LARGE_GROUP_MODE}" "${BASE_URL}" "${TCP_HOST}" >>"${FAKE_RUN_LOG:?}"
SH
  chmod +x "${fake_non_large}"

  fake_suite="${tmpdir}/fake-suite.sh"
  cat >"${fake_suite}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "${PRODUCT_SCENARIO_RECEIPT_DIR}"
printf 'suite=%s base=%s tcp=%s\n' "${PRODUCT_SCENARIO_SUITE}" "${BASE_URL}" "${TCP_HOST}" >>"${FAKE_RUN_LOG:?}"
cat >"${PRODUCT_SCENARIO_RECEIPT_DIR}/product-scenario-suite-run.json" <<JSON
{
  "schemaVersion": 1,
  "suite": "${PRODUCT_SCENARIO_SUITE}",
  "status": "PASS",
  "reason": "all_stages_passed",
  "target": {"baseURL": "${BASE_URL}", "tcpHost": "${TCP_HOST}", "tcpPort": "${TCP_PORT}", "accountFile": "${ACCOUNT_FILE}", "conversationIDPresent": true},
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
JSON
cat >"${PRODUCT_SCENARIO_RECEIPT_DIR}/product-scenario-suite-run.md" <<'MD'
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
MD
printf 'normal-smoke\tproduct-plan\tnormal-smoke\tFast smoke\t.\tPASS\t0\n' >"${PRODUCT_SCENARIO_RECEIPT_DIR}/product-scenario-suite-stages.tsv"
SH
  chmod +x "${fake_suite}"

  fake_profile="${tmpdir}/fake-profile.sh"
  cat >"${fake_profile}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'profile=%s base=%s tcp=%s\n' "${PERF_PRODUCTION_GATE_PROFILE}" "${BASE_URL}" "${TCP_HOST}" >>"${FAKE_RUN_LOG:?}"
SH
  chmod +x "${fake_profile}"

  fake_campaign="${tmpdir}/fake-campaign.sh"
  cat >"${fake_campaign}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
campaign=""
result_dir=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --campaign)
      campaign="$2"
      shift 2
      ;;
    --result-dir)
      result_dir="$2"
      shift 2
      ;;
    --execute)
      shift
      ;;
    *)
      shift
      ;;
  esac
done
mkdir -p "${result_dir}"
printf 'campaign=%s base=%s tcp=%s\n' "${campaign}" "${BASE_URL}" "${TCP_HOST}" >>"${FAKE_RUN_LOG:?}"
python3 - "${campaign}" "${result_dir}" "${CURRENT_PRODUCTION_LOAD_TESTS_DIR:-IMServer/LoadTests}" <<'PY'
import json
import os
import sys
from pathlib import Path

campaign, result_dir_raw, load_tests_dir_raw = sys.argv[1:4]
result_dir = Path(result_dir_raw)
load_tests_dir = Path(load_tests_dir_raw).resolve()
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
        f"env BASE_URL={os.environ.get('BASE_URL', 'https://chat.myim-prod.com')} "
        f"TCP_HOST={os.environ.get('TCP_HOST', 'tcp.myim-prod.com')} "
        f"TCP_PORT={os.environ.get('TCP_PORT', '9000')} "
        "IM_INTERNAL_SECRET=<redacted> SCENARIO_GROUPS=large-group ./run_perf_scenarios.sh"
        if is_large else
        f"env BASE_URL={os.environ.get('BASE_URL', 'https://chat.myim-prod.com')} "
        f"TCP_HOST={os.environ.get('TCP_HOST', 'tcp.myim-prod.com')} "
        f"TCP_PORT={os.environ.get('TCP_PORT', '9000')} "
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
        "runDir": str(result_dir / f"{index:02d}-{stage_id}"),
        "log": str(result_dir / f"{index:02d}-{stage_id}" / "stage.log"),
        "command": command,
        "evidence": "self-test",
        "packageEvidenceProfile": False,
        "packageEvidenceProductPlan": False,
        "skipReason": "",
    })
payload = {
    "schemaVersion": 1,
    "generatedAt": "2026-01-01T00:00:00Z",
    "campaign": campaign,
    "description": "current production readiness self-test",
    "campaignCatalog": str(load_tests_dir / "perf_product_campaigns.json"),
    "execute": True,
    "stopOnFailure": True,
    "resultDir": str(result_dir),
    "runIDPrefix": "current-production-readiness-self-test",
    "target": {
        "baseURL": os.environ.get("BASE_URL", "https://chat.myim-prod.com"),
        "tcpHost": os.environ.get("TCP_HOST", "tcp.myim-prod.com"),
        "tcpPort": os.environ.get("TCP_PORT", "9000"),
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
(result_dir / "product-campaign-run.json").write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
(result_dir / "product-campaign-runbook.md").write_text(build_runbook(payload), encoding="utf-8")
PY
SH
  chmod +x "${fake_campaign}"

  mkdir -p "${tmpdir}/blocked-results"
  cat >"${tmpdir}/blocked-results/scenario-catalog-current.json" <<'JSON'
{
  "summary": {"scenarioCount": 2, "domainCount": 1, "maturityGapCount": 0},
  "domains": [{"domain": "auth-session", "scenarioCount": 2, "familyCount": 2, "profiles": ["smoke"], "pass": 1, "fail": 0, "unknown": 0, "neverRun": 1}]
}
JSON
  cat >"${tmpdir}/blocked-results/scenario-status-current.json" <<'JSON'
{
  "scenarios": [
    {"scenario": "login-smoke", "category": "http-auth", "latestStatus": "PASS", "runCount": 1},
    {"scenario": "auth-session-smoke", "category": "http-auth", "latestStatus": "NEVER_RUN", "runCount": 0}
  ],
  "latestStatusCounts": {"PASS": 1, "NEVER_RUN": 1}
}
JSON
  cat >"${tmpdir}/blocked-results/slo-status-current.json" <<'JSON'
{
  "matrixScenarioCount": 2,
  "latestSLOStatusCounts": {"PASS": 1, "NEVER_RUN": 1},
  "extraSLOStatusCounts": {}
}
JSON

  FAKE_PROBE_RESULT=pass \
  CURRENT_PRODUCTION_SELF_TEST=false \
  CURRENT_PRODUCTION_OPERATOR_NETWORK_PREFLIGHT=true \
  CURRENT_PRODUCTION_OPERATOR_NETWORK_PREFLIGHT_SCRIPT="${fake_operator_fail}" \
  CURRENT_PRODUCTION_HTTP_ENTRYPOINT_PROBE="${fake_probe}" \
  CURRENT_PRODUCTION_RESCUE_GENERATOR="${fake_rescue}" \
  CURRENT_PRODUCTION_NON_LARGE_GROUP_RUNNER="${fake_non_large}" \
  CURRENT_PRODUCTION_SCENARIO_SUITE_RUNNER="${fake_suite}" \
  CURRENT_PRODUCTION_PRODUCTION_PROFILE_RUNNER="${fake_profile}" \
  CURRENT_PRODUCTION_PRODUCT_CAMPAIGN_RUNNER="${fake_campaign}" \
  RESULT_ROOT="${tmpdir}/blocked-results" \
  RUN_ID="operator-network-blocked" \
  BASE_URL="http://203.0.113.10:8080" \
  TCP_HOST="203.0.113.10" \
  FAKE_RUN_LOG="${tmpdir}/operator-network-run.log" \
    "${BASH_SOURCE[0]}" >"${tmpdir}/operator-network.out" 2>"${tmpdir}/operator-network.err" && {
      printf 'current_production_readiness_self_test result=fail reason=operator_network_path_passed\n' >&2
      return 1
    }
  grep -q 'warning=tun_route' "${tmpdir}/blocked-results/operator-network-blocked/operator-network.log" || {
    printf 'current_production_readiness_self_test result=fail reason=operator_network_log_missing\n' >&2
    return 1
  }
  [[ ! -f "${tmpdir}/blocked-results/operator-network-blocked/entrypoint-probe.log" ]] || {
    printf 'current_production_readiness_self_test result=fail reason=operator_network_started_entrypoint_probe\n' >&2
    return 1
  }
  [[ ! -f "${tmpdir}/operator-network-run.log" ]] || {
    printf 'current_production_readiness_self_test result=fail reason=operator_network_started_load\n' >&2
    return 1
  }
  python3 - "${tmpdir}/blocked-results/operator-network-blocked/current-production-readiness.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if payload.get("status") != "BLOCKED_ENTRYPOINT" or payload.get("reason") != "local_operator_network_blocked":
    raise SystemExit("current_production_readiness_self_test result=fail reason=operator_network_receipt_invalid")
if payload.get("evidencePolicy", {}).get("operatorNetworkPreflight") is not True:
    raise SystemExit("current_production_readiness_self_test result=fail reason=operator_network_policy_missing")
artifacts = payload.get("artifacts") or {}
operator_log = artifacts.get("operatorNetworkLog")
if not operator_log or not Path(str(operator_log)).is_file():
    raise SystemExit("current_production_readiness_self_test result=fail reason=operator_network_artifact_missing")
operator_json = artifacts.get("operatorNetworkJSON")
if not operator_json or not Path(str(operator_json)).is_file():
    raise SystemExit("current_production_readiness_self_test result=fail reason=operator_network_json_artifact_missing")
operator_payload = json.loads(Path(str(operator_json)).read_text(encoding="utf-8"))
if operator_payload.get("failed") is not True or "tun_route" not in (operator_payload.get("warnings") or []):
    raise SystemExit("current_production_readiness_self_test result=fail reason=operator_network_json_content_invalid")
operator_summary = payload.get("operatorNetwork") or {}
if operator_summary.get("failed") is not True or "tun_route" not in (operator_summary.get("warnings") or []):
    raise SystemExit("current_production_readiness_self_test result=fail reason=operator_network_summary_invalid")
if "utun99" not in (operator_summary.get("routeInterfaces") or []):
    raise SystemExit("current_production_readiness_self_test result=fail reason=operator_network_summary_route_missing")
PY

  FAKE_PROBE_RESULT=fail \
  CURRENT_PRODUCTION_SELF_TEST=false \
  CURRENT_PRODUCTION_HTTP_ENTRYPOINT_PROBE="${fake_probe}" \
  CURRENT_PRODUCTION_RESCUE_GENERATOR="${fake_rescue}" \
  CURRENT_PRODUCTION_NON_LARGE_GROUP_RUNNER="${fake_non_large}" \
  CURRENT_PRODUCTION_SCENARIO_SUITE_RUNNER="${fake_suite}" \
  CURRENT_PRODUCTION_PRODUCTION_PROFILE_RUNNER="${fake_profile}" \
  CURRENT_PRODUCTION_PRODUCT_CAMPAIGN_RUNNER="${fake_campaign}" \
  CURRENT_PRODUCTION_RESCUE_ARTIFACT_DIR="${tmpdir}/blocked-rescue" \
  RESULT_ROOT="${tmpdir}/blocked-results" \
  RUN_ID="blocked" \
  FAKE_RUN_LOG="${tmpdir}/blocked-run.log" \
    "${BASH_SOURCE[0]}" >"${tmpdir}/blocked.out" 2>"${tmpdir}/blocked.err" && {
      printf 'current_production_readiness_self_test result=fail reason=blocked_path_passed\n' >&2
      return 1
    }
  grep -q 'result=blocked' "${tmpdir}/blocked.err" || {
    printf 'current_production_readiness_self_test result=fail reason=blocked_reason_missing\n' >&2
    sed -n '1,80p' "${tmpdir}/blocked.err" >&2
    return 1
  }
  [[ -f "${tmpdir}/blocked-results/blocked/current-production-readiness.json" ]] || {
    printf 'current_production_readiness_self_test result=fail reason=blocked_receipt_missing\n' >&2
    return 1
  }
  python3 - "${tmpdir}/blocked-results/blocked/current-production-state-summary.json" "${tmpdir}/blocked-results/current-production-state-summary.json" <<'PY'
import json
import sys
from pathlib import Path

run_payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
current_payload = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
for payload in (run_payload, current_payload):
    summary = payload.get("summary") or {}
    if summary.get("conclusion") != "BLOCKED_ENTRYPOINT":
        raise SystemExit("current_production_readiness_self_test result=fail reason=blocked_conclusion_missing")
    if summary.get("matrixScenarioCount") != 2:
        raise SystemExit(f"current_production_readiness_self_test result=fail reason=current_evidence_not_attached count={summary.get('matrixScenarioCount')}")
    if summary.get("ranScenarioCount") != 1:
        raise SystemExit("current_production_readiness_self_test result=fail reason=current_run_count_not_attached")
PY
  [[ ! -f "${tmpdir}/blocked-run.log" ]] || {
    printf 'current_production_readiness_self_test result=fail reason=blocked_started_load\n' >&2
    return 1
  }
  python3 - "${tmpdir}/blocked-results/blocked/current-production-readiness.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
artifacts = payload.get("artifacts") or {}
required = [
    "rescueArtifactDir",
    "rescueManifest",
    "rescueTarball",
    "rescueTarballVerifyScript",
    "rescueTarballSha256",
    "rescueTarballReceipt",
]
missing = [key for key in required if not artifacts.get(key)]
if missing:
    raise SystemExit(f"current_production_readiness_self_test result=fail reason=blocked_rescue_artifacts_missing fields={missing}")
for key in required:
    if not Path(str(artifacts[key])).exists():
        raise SystemExit(f"current_production_readiness_self_test result=fail reason=blocked_rescue_artifact_file_missing field={key} path={artifacts[key]}")
PY
  CURRENT_PRODUCTION_SELF_TEST=false \
  CURRENT_PRODUCTION_HTTP_ENTRYPOINT_PROBE="${fake_probe_missing_json}" \
  CURRENT_PRODUCTION_RESCUE_GENERATOR="${fake_missing_json_rescue}" \
  CURRENT_PRODUCTION_NON_LARGE_GROUP_RUNNER="${fake_non_large}" \
  CURRENT_PRODUCTION_SCENARIO_SUITE_RUNNER="${fake_suite}" \
  CURRENT_PRODUCTION_PRODUCTION_PROFILE_RUNNER="${fake_profile}" \
  CURRENT_PRODUCTION_PRODUCT_CAMPAIGN_RUNNER="${fake_campaign}" \
  CURRENT_PRODUCTION_RESCUE_ARTIFACT_DIR="${tmpdir}/missing-json-rescue" \
  RESULT_ROOT="${tmpdir}/missing-json-results" \
  RUN_ID="missing-json" \
  FAKE_RUN_LOG="${tmpdir}/missing-json-run.log" \
    "${BASH_SOURCE[0]}" >"${tmpdir}/missing-json.out" 2>"${tmpdir}/missing-json.err" && {
      printf 'current_production_readiness_self_test result=fail reason=missing_json_path_passed\n' >&2
      return 1
    }
  python3 - "${tmpdir}/missing-json-results/missing-json/entrypoint-probe.json" "${tmpdir}/missing-json-results/missing-json/current-production-readiness-verify.log" <<'PY'
import json
import sys
from pathlib import Path

probe = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if probe.get("diagnosis") != "probe_json_missing":
    raise SystemExit("current_production_readiness_self_test result=fail reason=fallback_probe_diagnosis_missing")
if (probe.get("blocker") or {}).get("action") != "repair_entrypoint_probe":
    raise SystemExit("current_production_readiness_self_test result=fail reason=fallback_probe_action_missing")
if "result=pass" not in Path(sys.argv[2]).read_text(encoding="utf-8"):
    raise SystemExit("current_production_readiness_self_test result=fail reason=fallback_probe_artifact_verify_missing")
PY
  [[ ! -f "${tmpdir}/missing-json-run.log" ]] || {
    printf 'current_production_readiness_self_test result=fail reason=missing_json_started_load\n' >&2
    return 1
  }

  python3 - "${tmpdir}/load-5000.csv" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
path.write_text(
    "".join(f"user{i}@example.com,password{i}\n" for i in range(5000)),
    encoding="utf-8",
)
PY

  FAKE_PROBE_RESULT=pass \
  CURRENT_PRODUCTION_SELF_TEST=false \
  CURRENT_PRODUCTION_HTTP_ENTRYPOINT_PROBE="${fake_probe}" \
  CURRENT_PRODUCTION_RESCUE_GENERATOR="${fake_rescue}" \
  CURRENT_PRODUCTION_NON_LARGE_GROUP_RUNNER="${fake_non_large}" \
  CURRENT_PRODUCTION_SCENARIO_SUITE_RUNNER="${fake_suite}" \
  CURRENT_PRODUCTION_PRODUCTION_PROFILE_RUNNER="${fake_profile}" \
  CURRENT_PRODUCTION_PRODUCT_CAMPAIGN_RUNNER="${fake_campaign}" \
  CURRENT_PRODUCTION_RUN_BASELINE=true \
  CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE=true \
  RESULT_ROOT="${tmpdir}/small-account-results" \
  RUN_ID="small-account" \
  BASE_URL="https://chat.myim-prod.com" \
  TCP_HOST="" \
  ACCOUNT_FILE="${tmpdir}/load-5000.csv" \
  IM_CONVERSATION_ID="00000000-0000-0000-0000-000000000001" \
  IM_INTERNAL_SECRET="self-test-internal-secret" \
  FAKE_RUN_LOG="${tmpdir}/small-account-run.log" \
    "${BASH_SOURCE[0]}" >"${tmpdir}/small-account.out" 2>"${tmpdir}/small-account.err" && {
      printf 'current_production_readiness_self_test result=fail reason=small_account_path_passed\n' >&2
      return 1
    }
  grep -q 'reason=requested_run_prereq_failed' "${tmpdir}/small-account.err" || {
    printf 'current_production_readiness_self_test result=fail reason=small_account_reason_missing\n' >&2
    return 1
  }
  [[ ! -f "${tmpdir}/small-account-run.log" ]] || {
    printf 'current_production_readiness_self_test result=fail reason=small_account_started_load\n' >&2
    return 1
  }
  python3 - "${tmpdir}/small-account-results/small-account/current-production-readiness.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if payload.get("status") != "FAIL" or payload.get("reason") != "requested_run_prereq_failed":
    raise SystemExit("current_production_readiness_self_test result=fail reason=small_account_receipt_invalid")
if payload.get("runs", {}).get("smokeExitCode") is not None:
    raise SystemExit("current_production_readiness_self_test result=fail reason=small_account_smoke_started")
if not (payload.get("artifacts") or {}).get("prereqSummary"):
    raise SystemExit("current_production_readiness_self_test result=fail reason=small_account_prereq_summary_missing")
PY

  python3 - "${tmpdir}/load-10000.csv" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
path.write_text(
    "".join(f"user{i}@example.com,password{i}\n" for i in range(10000)),
    encoding="utf-8",
)
PY
  cloud_security_group_good="${tmpdir}/cloud-security-group-good.json"
  cat >"${cloud_security_group_good}" <<'JSON'
{
  "SecurityGroupRules": {
    "SecurityGroupRule": [
      {"IpProtocol": "tcp", "PortRange": "80/80", "SourceCidrIp": "0.0.0.0/0", "Policy": "Accept"},
      {"IpProtocol": "tcp", "PortRange": "443/443", "SourceCidrIp": "0.0.0.0/0", "Policy": "Accept"},
      {"IpProtocol": "tcp", "PortRange": "9000/9000", "SourceCidrIp": "0.0.0.0/0", "Policy": "Accept"},
      {"IpProtocol": "tcp", "PortRange": "22/22", "SourceCidrIp": "203.0.113.10/32", "Policy": "Accept"},
      {"IpProtocol": "icmp", "PortRange": "-1/-1", "SourceCidrIp": "0.0.0.0/0", "Policy": "Accept"}
    ]
  }
}
JSON
  chmod 0600 "${cloud_security_group_good}"
  cloud_security_group_repair_receipt="${tmpdir}/cloud-security-group-repair-receipt.json"
  cloud_security_group_repair_plan="${tmpdir}/cloud-security-group-repair-plan.json"
  cloud_security_group_post_apply="${tmpdir}/cloud-security-group-post-apply.json"
  cp "${cloud_security_group_good}" "${cloud_security_group_post_apply}"
  python3 - "${cloud_security_group_good}" "${cloud_security_group_repair_plan}" "${cloud_security_group_post_apply}" "${cloud_security_group_repair_receipt}" <<'PY'
import hashlib
import json
import sys
import time
from pathlib import Path

snapshot_path, plan_path, post_apply_path, receipt_path = map(Path, sys.argv[1:5])
plan = {
    "schemaVersion": 1,
    "securityGroupId": "sg-current-readiness-selftest",
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
    "securityGroupId": "sg-current-readiness-selftest",
    "regionId": "cn-shenzhen",
    "adminCidr": "203.0.113.10/32",
    "applyRequested": True,
    "applied": True,
    "verifyRequested": True,
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

  FAKE_PROBE_RESULT=pass \
  CURRENT_PRODUCTION_SELF_TEST=false \
  CURRENT_PRODUCTION_HTTP_ENTRYPOINT_PROBE="${fake_probe}" \
  CURRENT_PRODUCTION_RESCUE_GENERATOR="${fake_rescue}" \
  CURRENT_PRODUCTION_NON_LARGE_GROUP_RUNNER="${fake_non_large}" \
  CURRENT_PRODUCTION_SCENARIO_SUITE_RUNNER="${fake_suite}" \
  CURRENT_PRODUCTION_PRODUCTION_PROFILE_RUNNER="${fake_profile}" \
  CURRENT_PRODUCTION_PRODUCT_CAMPAIGN_RUNNER="${fake_campaign}" \
  RESULT_ROOT="${tmpdir}/bad-smoke-public-target-results" \
  RUN_ID="bad-smoke-public-target" \
  BASE_URL="http://203.0.113.10:8080" \
  TCP_HOST="" \
  ACCOUNT_FILE="${tmpdir}/load-10000.csv" \
  IM_CONVERSATION_ID="00000000-0000-0000-0000-000000000001" \
  IM_INTERNAL_SECRET="self-test-internal-secret" \
  FAKE_RUN_LOG="${tmpdir}/bad-smoke-public-target-run.log" \
    "${BASH_SOURCE[0]}" >"${tmpdir}/bad-smoke-public-target.out" 2>"${tmpdir}/bad-smoke-public-target.err" && {
      printf 'current_production_readiness_self_test result=fail reason=bad_smoke_public_target_path_passed\n' >&2
      return 1
    }
  grep -q 'public_base_url_https_required' "${tmpdir}/bad-smoke-public-target.err" || {
    printf 'current_production_readiness_self_test result=fail reason=bad_smoke_public_target_reason_missing\n' >&2
    return 1
  }
  [[ ! -f "${tmpdir}/bad-smoke-public-target-run.log" ]] || {
    printf 'current_production_readiness_self_test result=fail reason=bad_smoke_public_target_started_load\n' >&2
    return 1
  }
  python3 - "${tmpdir}/bad-smoke-public-target-results/bad-smoke-public-target/current-production-readiness.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if payload.get("status") != "FAIL" or payload.get("reason") != "requested_run_prereq_failed":
    raise SystemExit("current_production_readiness_self_test result=fail reason=bad_smoke_public_target_receipt_invalid")
summary_path = Path((payload.get("artifacts") or {}).get("prereqSummary") or "")
if "public_base_url_https_required" not in summary_path.read_text(encoding="utf-8"):
    raise SystemExit("current_production_readiness_self_test result=fail reason=bad_smoke_public_target_summary_missing")
if payload.get("runs", {}).get("smokeExitCode") is not None:
    raise SystemExit("current_production_readiness_self_test result=fail reason=bad_smoke_public_target_smoke_started")
PY

  FAKE_PROBE_RESULT=pass \
  CURRENT_PRODUCTION_SELF_TEST=false \
  CURRENT_PRODUCTION_HTTP_ENTRYPOINT_PROBE="${fake_probe}" \
  CURRENT_PRODUCTION_RESCUE_GENERATOR="${fake_rescue}" \
  CURRENT_PRODUCTION_NON_LARGE_GROUP_RUNNER="${fake_non_large}" \
  CURRENT_PRODUCTION_SCENARIO_SUITE_RUNNER="${fake_suite}" \
  CURRENT_PRODUCTION_PRODUCTION_PROFILE_RUNNER="${fake_profile}" \
  CURRENT_PRODUCTION_PRODUCT_CAMPAIGN_RUNNER="${fake_campaign}" \
  CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE=true \
  CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_FILE="${cloud_security_group_good}" \
  RESULT_ROOT="${tmpdir}/bad-public-target-results" \
  RUN_ID="bad-public-target" \
  BASE_URL="http://203.0.113.10:8080" \
  TCP_HOST="" \
  ACCOUNT_FILE="${tmpdir}/load-10000.csv" \
  IM_CONVERSATION_ID="00000000-0000-0000-0000-000000000001" \
  IM_INTERNAL_SECRET="self-test-internal-secret" \
  FAKE_RUN_LOG="${tmpdir}/bad-public-target-run.log" \
    "${BASH_SOURCE[0]}" >"${tmpdir}/bad-public-target.out" 2>"${tmpdir}/bad-public-target.err" && {
      printf 'current_production_readiness_self_test result=fail reason=bad_public_target_path_passed\n' >&2
      return 1
    }
  grep -q 'public_base_url_https_required' "${tmpdir}/bad-public-target.err" || {
    printf 'current_production_readiness_self_test result=fail reason=bad_public_target_reason_missing\n' >&2
    return 1
  }
  [[ ! -f "${tmpdir}/bad-public-target-run.log" ]] || {
    printf 'current_production_readiness_self_test result=fail reason=bad_public_target_started_load\n' >&2
    return 1
  }
  python3 - "${tmpdir}/bad-public-target-results/bad-public-target/current-production-readiness.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if payload.get("status") != "FAIL" or payload.get("reason") != "requested_run_prereq_failed":
    raise SystemExit("current_production_readiness_self_test result=fail reason=bad_public_target_receipt_invalid")
summary_path = Path((payload.get("artifacts") or {}).get("prereqSummary") or "")
if "public_base_url_https_required" not in summary_path.read_text(encoding="utf-8"):
    raise SystemExit("current_production_readiness_self_test result=fail reason=bad_public_target_summary_missing")
PY

  FAKE_PROBE_RESULT=pass \
  CURRENT_PRODUCTION_SELF_TEST=false \
  CURRENT_PRODUCTION_HTTP_ENTRYPOINT_PROBE="${fake_probe}" \
  CURRENT_PRODUCTION_RESCUE_GENERATOR="${fake_rescue}" \
  CURRENT_PRODUCTION_NON_LARGE_GROUP_RUNNER="${fake_non_large}" \
  CURRENT_PRODUCTION_SCENARIO_SUITE_RUNNER="${fake_suite}" \
  CURRENT_PRODUCTION_PRODUCTION_PROFILE_RUNNER="${fake_profile}" \
  CURRENT_PRODUCTION_PRODUCT_CAMPAIGN_RUNNER="${fake_campaign}" \
  CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE=true \
  CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_FILE="${cloud_security_group_good}" \
  RESULT_ROOT="${tmpdir}/non-default-public-port-results" \
  RUN_ID="non-default-public-port" \
  BASE_URL="https://chat.myim-prod.com:8080" \
  TCP_HOST="tcp.myim-prod.com" \
  ACCOUNT_FILE="${tmpdir}/load-10000.csv" \
  IM_CONVERSATION_ID="00000000-0000-0000-0000-000000000001" \
  IM_INTERNAL_SECRET="self-test-internal-secret" \
  FAKE_RUN_LOG="${tmpdir}/non-default-public-port-run.log" \
    "${BASH_SOURCE[0]}" >"${tmpdir}/non-default-public-port.out" 2>"${tmpdir}/non-default-public-port.err" && {
      printf 'current_production_readiness_self_test result=fail reason=non_default_public_port_path_passed\n' >&2
      return 1
    }
  grep -q 'public_base_url_default_https_port_required' "${tmpdir}/non-default-public-port.err" || {
    printf 'current_production_readiness_self_test result=fail reason=non_default_public_port_reason_missing\n' >&2
    return 1
  }
  [[ ! -f "${tmpdir}/non-default-public-port-run.log" ]] || {
    printf 'current_production_readiness_self_test result=fail reason=non_default_public_port_started_load\n' >&2
    return 1
  }
  python3 - "${tmpdir}/non-default-public-port-results/non-default-public-port/current-production-readiness.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if payload.get("status") != "FAIL" or payload.get("reason") != "requested_run_prereq_failed":
    raise SystemExit("current_production_readiness_self_test result=fail reason=non_default_public_port_receipt_invalid")
summary_path = Path((payload.get("artifacts") or {}).get("prereqSummary") or "")
if "public_base_url_default_https_port_required" not in summary_path.read_text(encoding="utf-8"):
    raise SystemExit("current_production_readiness_self_test result=fail reason=non_default_public_port_summary_missing")
PY

  FAKE_PROBE_RESULT=pass \
  CURRENT_PRODUCTION_SELF_TEST=false \
  CURRENT_PRODUCTION_HTTP_ENTRYPOINT_PROBE="${fake_probe}" \
  CURRENT_PRODUCTION_RESCUE_GENERATOR="${fake_rescue}" \
  CURRENT_PRODUCTION_NON_LARGE_GROUP_RUNNER="${fake_non_large}" \
  CURRENT_PRODUCTION_SCENARIO_SUITE_RUNNER="${fake_suite}" \
  CURRENT_PRODUCTION_PRODUCTION_PROFILE_RUNNER="${fake_profile}" \
  CURRENT_PRODUCTION_PRODUCT_CAMPAIGN_RUNNER="${fake_campaign}" \
  CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE=true \
  CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_FILE="${cloud_security_group_good}" \
  RESULT_ROOT="${tmpdir}/path-public-target-results" \
  RUN_ID="path-public-target" \
  BASE_URL="https://chat.myim-prod.com/api" \
  TCP_HOST="tcp.myim-prod.com" \
  ACCOUNT_FILE="${tmpdir}/load-10000.csv" \
  IM_CONVERSATION_ID="00000000-0000-0000-0000-000000000001" \
  IM_INTERNAL_SECRET="self-test-internal-secret" \
  FAKE_RUN_LOG="${tmpdir}/path-public-target-run.log" \
    "${BASH_SOURCE[0]}" >"${tmpdir}/path-public-target.out" 2>"${tmpdir}/path-public-target.err" && {
      printf 'current_production_readiness_self_test result=fail reason=path_public_target_path_passed\n' >&2
      return 1
    }
  grep -q 'public_base_url_origin_required' "${tmpdir}/path-public-target.err" || {
    printf 'current_production_readiness_self_test result=fail reason=path_public_target_reason_missing\n' >&2
    return 1
  }
  [[ ! -f "${tmpdir}/path-public-target-run.log" ]] || {
    printf 'current_production_readiness_self_test result=fail reason=path_public_target_started_load\n' >&2
    return 1
  }
  python3 - "${tmpdir}/path-public-target-results/path-public-target/current-production-readiness.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if payload.get("status") != "FAIL" or payload.get("reason") != "requested_run_prereq_failed":
    raise SystemExit("current_production_readiness_self_test result=fail reason=path_public_target_receipt_invalid")
summary_path = Path((payload.get("artifacts") or {}).get("prereqSummary") or "")
if "public_base_url_origin_required" not in summary_path.read_text(encoding="utf-8"):
    raise SystemExit("current_production_readiness_self_test result=fail reason=path_public_target_summary_missing")
if payload.get("runs", {}).get("smokeExitCode") is not None:
    raise SystemExit("current_production_readiness_self_test result=fail reason=path_public_target_smoke_started")
PY

  FAKE_PROBE_RESULT=pass \
  CURRENT_PRODUCTION_SELF_TEST=false \
  CURRENT_PRODUCTION_HTTP_ENTRYPOINT_PROBE="${fake_probe}" \
  CURRENT_PRODUCTION_RESCUE_GENERATOR="${fake_rescue}" \
  CURRENT_PRODUCTION_NON_LARGE_GROUP_RUNNER="${fake_non_large}" \
  CURRENT_PRODUCTION_SCENARIO_SUITE_RUNNER="${fake_suite}" \
  CURRENT_PRODUCTION_PRODUCTION_PROFILE_RUNNER="${fake_profile}" \
  CURRENT_PRODUCTION_PRODUCT_CAMPAIGN_RUNNER="${fake_campaign}" \
  CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE=true \
  CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_FILE="${cloud_security_group_good}" \
  RESULT_ROOT="${tmpdir}/bad-tcp-port-results" \
  RUN_ID="bad-tcp-port" \
  BASE_URL="https://chat.myim-prod.com" \
  TCP_HOST="tcp.myim-prod.com" \
  TCP_PORT=9443 \
  ACCOUNT_FILE="${tmpdir}/load-10000.csv" \
  IM_CONVERSATION_ID="00000000-0000-0000-0000-000000000001" \
  IM_INTERNAL_SECRET="self-test-internal-secret" \
  FAKE_RUN_LOG="${tmpdir}/bad-tcp-port-run.log" \
    "${BASH_SOURCE[0]}" >"${tmpdir}/bad-tcp-port.out" 2>"${tmpdir}/bad-tcp-port.err" && {
      printf 'current_production_readiness_self_test result=fail reason=bad_tcp_port_path_passed\n' >&2
      return 1
    }
  grep -q 'tcp_port_required' "${tmpdir}/bad-tcp-port.err" || {
    printf 'current_production_readiness_self_test result=fail reason=bad_tcp_port_reason_missing\n' >&2
    return 1
  }
  [[ ! -f "${tmpdir}/bad-tcp-port-run.log" ]] || {
    printf 'current_production_readiness_self_test result=fail reason=bad_tcp_port_started_load\n' >&2
    return 1
  }
  python3 - "${tmpdir}/bad-tcp-port-results/bad-tcp-port/current-production-readiness.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if payload.get("status") != "FAIL" or payload.get("reason") != "requested_run_prereq_failed":
    raise SystemExit("current_production_readiness_self_test result=fail reason=bad_tcp_port_receipt_invalid")
summary_path = Path((payload.get("artifacts") or {}).get("prereqSummary") or "")
if "tcp_port_required" not in summary_path.read_text(encoding="utf-8"):
    raise SystemExit("current_production_readiness_self_test result=fail reason=bad_tcp_port_summary_missing")
if payload.get("runs", {}).get("smokeExitCode") is not None:
    raise SystemExit("current_production_readiness_self_test result=fail reason=bad_tcp_port_smoke_started")
PY

  FAKE_PROBE_RESULT=pass \
  CURRENT_PRODUCTION_SELF_TEST=false \
  CURRENT_PRODUCTION_HTTP_ENTRYPOINT_PROBE="${fake_probe}" \
  CURRENT_PRODUCTION_RESCUE_GENERATOR="${fake_rescue}" \
  CURRENT_PRODUCTION_NON_LARGE_GROUP_RUNNER="${fake_non_large}" \
  CURRENT_PRODUCTION_SCENARIO_SUITE_RUNNER="${fake_suite}" \
  CURRENT_PRODUCTION_PRODUCTION_PROFILE_RUNNER="${fake_profile}" \
  CURRENT_PRODUCTION_PRODUCT_CAMPAIGN_RUNNER="${fake_campaign}" \
  CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE=true \
  CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_FILE="${cloud_security_group_good}" \
  RESULT_ROOT="${tmpdir}/placeholder-public-target-results" \
  RUN_ID="placeholder-public-target" \
  BASE_URL="https://chat.yourdomain.com" \
  TCP_HOST="" \
  ACCOUNT_FILE="${tmpdir}/load-10000.csv" \
  IM_CONVERSATION_ID="00000000-0000-0000-0000-000000000001" \
  IM_INTERNAL_SECRET="self-test-internal-secret" \
  FAKE_RUN_LOG="${tmpdir}/placeholder-public-target-run.log" \
    "${BASH_SOURCE[0]}" >"${tmpdir}/placeholder-public-target.out" 2>"${tmpdir}/placeholder-public-target.err" && {
      printf 'current_production_readiness_self_test result=fail reason=placeholder_public_target_path_passed\n' >&2
      return 1
    }
  grep -q 'public_base_url_domain_required' "${tmpdir}/placeholder-public-target.err" || {
    printf 'current_production_readiness_self_test result=fail reason=placeholder_public_target_reason_missing\n' >&2
    return 1
  }
  grep -q 'hostReason=placeholder' "${tmpdir}/placeholder-public-target.err" || {
    printf 'current_production_readiness_self_test result=fail reason=placeholder_public_target_host_reason_missing\n' >&2
    return 1
  }
  [[ ! -f "${tmpdir}/placeholder-public-target-run.log" ]] || {
    printf 'current_production_readiness_self_test result=fail reason=placeholder_public_target_started_load\n' >&2
    return 1
  }
  python3 - "${tmpdir}/placeholder-public-target-results/placeholder-public-target/current-production-readiness.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if payload.get("status") != "FAIL" or payload.get("reason") != "requested_run_prereq_failed":
    raise SystemExit("current_production_readiness_self_test result=fail reason=placeholder_public_target_receipt_invalid")
summary_path = Path((payload.get("artifacts") or {}).get("prereqSummary") or "")
summary = summary_path.read_text(encoding="utf-8")
if "public_base_url_domain_required" not in summary or "hostReason=placeholder" not in summary:
    raise SystemExit("current_production_readiness_self_test result=fail reason=placeholder_public_target_summary_missing")
if payload.get("runs", {}).get("smokeExitCode") is not None:
    raise SystemExit("current_production_readiness_self_test result=fail reason=placeholder_public_target_smoke_started")
PY

  FAKE_PROBE_RESULT=pass \
  CURRENT_PRODUCTION_SELF_TEST=false \
  CURRENT_PRODUCTION_HTTP_ENTRYPOINT_PROBE="${fake_probe}" \
  CURRENT_PRODUCTION_RESCUE_GENERATOR="${fake_rescue}" \
  CURRENT_PRODUCTION_NON_LARGE_GROUP_RUNNER="${fake_non_large}" \
  CURRENT_PRODUCTION_SCENARIO_SUITE_RUNNER="${fake_suite}" \
  CURRENT_PRODUCTION_PRODUCTION_PROFILE_RUNNER="${fake_profile}" \
  CURRENT_PRODUCTION_PRODUCT_CAMPAIGN_RUNNER="${fake_campaign}" \
  CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE=true \
  CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_FILE="${cloud_security_group_good}" \
  RESULT_ROOT="${tmpdir}/placeholder-tcp-target-results" \
  RUN_ID="placeholder-tcp-target" \
  BASE_URL="https://chat.myim-prod.com" \
  TCP_HOST="tcp.yourdomain.com" \
  ACCOUNT_FILE="${tmpdir}/load-10000.csv" \
  IM_CONVERSATION_ID="00000000-0000-0000-0000-000000000001" \
  IM_INTERNAL_SECRET="self-test-internal-secret" \
  FAKE_RUN_LOG="${tmpdir}/placeholder-tcp-target-run.log" \
    "${BASH_SOURCE[0]}" >"${tmpdir}/placeholder-tcp-target.out" 2>"${tmpdir}/placeholder-tcp-target.err" && {
      printf 'current_production_readiness_self_test result=fail reason=placeholder_tcp_target_path_passed\n' >&2
      return 1
    }
  grep -q 'tcp_host_domain_required' "${tmpdir}/placeholder-tcp-target.err" || {
    printf 'current_production_readiness_self_test result=fail reason=placeholder_tcp_target_reason_missing\n' >&2
    return 1
  }
  grep -q 'hostReason=placeholder' "${tmpdir}/placeholder-tcp-target.err" || {
    printf 'current_production_readiness_self_test result=fail reason=placeholder_tcp_target_host_reason_missing\n' >&2
    return 1
  }
  [[ ! -f "${tmpdir}/placeholder-tcp-target-run.log" ]] || {
    printf 'current_production_readiness_self_test result=fail reason=placeholder_tcp_target_started_load\n' >&2
    return 1
  }
  python3 - "${tmpdir}/placeholder-tcp-target-results/placeholder-tcp-target/current-production-readiness.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if payload.get("status") != "FAIL" or payload.get("reason") != "requested_run_prereq_failed":
    raise SystemExit("current_production_readiness_self_test result=fail reason=placeholder_tcp_target_receipt_invalid")
summary_path = Path((payload.get("artifacts") or {}).get("prereqSummary") or "")
summary = summary_path.read_text(encoding="utf-8")
if "tcp_host_domain_required" not in summary or "hostReason=placeholder" not in summary:
    raise SystemExit("current_production_readiness_self_test result=fail reason=placeholder_tcp_target_summary_missing")
if payload.get("runs", {}).get("smokeExitCode") is not None:
    raise SystemExit("current_production_readiness_self_test result=fail reason=placeholder_tcp_target_smoke_started")
PY

  FAKE_PROBE_RESULT=pass \
  CURRENT_PRODUCTION_SELF_TEST=false \
  CURRENT_PRODUCTION_HTTP_ENTRYPOINT_PROBE="${fake_probe}" \
  CURRENT_PRODUCTION_RESCUE_GENERATOR="${fake_rescue}" \
  CURRENT_PRODUCTION_NON_LARGE_GROUP_RUNNER="${fake_non_large}" \
  CURRENT_PRODUCTION_SCENARIO_SUITE_RUNNER="${fake_suite}" \
  CURRENT_PRODUCTION_PRODUCTION_PROFILE_RUNNER="${fake_profile}" \
  CURRENT_PRODUCTION_PRODUCT_CAMPAIGN_RUNNER="${fake_campaign}" \
  CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE=true \
  CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_FILE="" \
  RESULT_ROOT="${tmpdir}/missing-cloud-security-group-results" \
  RUN_ID="missing-cloud-security-group" \
  BASE_URL="https://chat.myim-prod.com" \
  TCP_HOST="" \
  ACCOUNT_FILE="${tmpdir}/load-10000.csv" \
  IM_CONVERSATION_ID="00000000-0000-0000-0000-000000000001" \
  IM_INTERNAL_SECRET="self-test-internal-secret" \
  FAKE_RUN_LOG="${tmpdir}/missing-cloud-security-group-run.log" \
    "${BASH_SOURCE[0]}" >"${tmpdir}/missing-cloud-security-group.out" 2>"${tmpdir}/missing-cloud-security-group.err" && {
      printf 'current_production_readiness_self_test result=fail reason=missing_cloud_security_group_path_passed\n' >&2
      return 1
    }
  grep -q 'cloud_security_group_snapshot_required' "${tmpdir}/missing-cloud-security-group.err" || {
    printf 'current_production_readiness_self_test result=fail reason=missing_cloud_security_group_reason_missing\n' >&2
    return 1
  }
  [[ ! -f "${tmpdir}/missing-cloud-security-group-run.log" ]] || {
    printf 'current_production_readiness_self_test result=fail reason=missing_cloud_security_group_started_load\n' >&2
    return 1
  }
  python3 - "${tmpdir}/missing-cloud-security-group-results/missing-cloud-security-group/current-production-readiness.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if payload.get("status") != "FAIL" or payload.get("reason") != "requested_run_prereq_failed":
    raise SystemExit("current_production_readiness_self_test result=fail reason=missing_cloud_security_group_receipt_invalid")
if payload.get("evidencePolicy", {}).get("requireCloudSecurityGroup") is not True:
    raise SystemExit("current_production_readiness_self_test result=fail reason=missing_cloud_security_group_policy_invalid")
summary_path = Path((payload.get("artifacts") or {}).get("prereqSummary") or "")
if "cloud_security_group_snapshot_required" not in summary_path.read_text(encoding="utf-8"):
    raise SystemExit("current_production_readiness_self_test result=fail reason=missing_cloud_security_group_summary_missing")
PY

  FAKE_PROBE_RESULT=pass \
  CURRENT_PRODUCTION_SELF_TEST=false \
  CURRENT_PRODUCTION_HTTP_ENTRYPOINT_PROBE="${fake_probe}" \
  CURRENT_PRODUCTION_RESCUE_GENERATOR="${fake_rescue}" \
  CURRENT_PRODUCTION_NON_LARGE_GROUP_RUNNER="${fake_non_large}" \
  CURRENT_PRODUCTION_SCENARIO_SUITE_RUNNER="${fake_suite}" \
  CURRENT_PRODUCTION_PRODUCTION_PROFILE_RUNNER="${fake_profile}" \
  CURRENT_PRODUCTION_PRODUCT_CAMPAIGN_RUNNER="${fake_campaign}" \
  CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE=true \
  CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_FILE="${cloud_security_group_good}" \
  CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${tmpdir}/missing-cloud-security-group-repair-receipt.json" \
  RESULT_ROOT="${tmpdir}/missing-cloud-security-group-repair-receipt-results" \
  RUN_ID="missing-cloud-security-group-repair-receipt" \
  BASE_URL="https://chat.myim-prod.com" \
  TCP_HOST="" \
  ACCOUNT_FILE="${tmpdir}/load-10000.csv" \
  IM_CONVERSATION_ID="00000000-0000-0000-0000-000000000001" \
  IM_INTERNAL_SECRET="self-test-internal-secret" \
  FAKE_RUN_LOG="${tmpdir}/missing-cloud-security-group-repair-receipt-run.log" \
    "${BASH_SOURCE[0]}" >"${tmpdir}/missing-cloud-security-group-repair-receipt.out" 2>"${tmpdir}/missing-cloud-security-group-repair-receipt.err" && {
      printf 'current_production_readiness_self_test result=fail reason=missing_cloud_security_group_repair_receipt_path_passed\n' >&2
      return 1
    }
  grep -q 'cloud_security_group_repair_receipt_missing' "${tmpdir}/missing-cloud-security-group-repair-receipt.err" || {
    printf 'current_production_readiness_self_test result=fail reason=missing_cloud_security_group_repair_receipt_reason_missing\n' >&2
    return 1
  }
  [[ ! -f "${tmpdir}/missing-cloud-security-group-repair-receipt-run.log" ]] || {
    printf 'current_production_readiness_self_test result=fail reason=missing_cloud_security_group_repair_receipt_started_load\n' >&2
    return 1
  }

  production_gate_pass="${tmpdir}/production-gate-pass.json"
  python3 - "${production_gate_pass}" "${SCRIPT_DIR}/perf_production_profiles.json" <<'PY'
import hashlib
import json
import sys
import time
from pathlib import Path

path, catalog_path = map(Path, sys.argv[1:3])
with catalog_path.open(encoding="utf-8") as handle:
    scenarios = (json.load(handle).get("profiles") or {}).get("normal-product-baseline") or []
with catalog_path.open("rb") as handle:
    catalog_sha256 = hashlib.sha256(handle.read()).hexdigest()
now = int(time.time())
payload = {
    "status": "PASS",
    "profile": "normal-product-baseline",
    "source": {
        "repoRoot": str(catalog_path.resolve().parents[2]),
        "gitCommit": "self-test",
        "gitBranch": "self-test",
        "gitDirty": False,
    },
    "targetFilter": {
        "enabled": True,
        "baseURL": "https://chat.myim-prod.com",
        "tcpHost": "chat.myim-prod.com",
        "tcpPort": "9000",
    },
    "profileCatalog": {"path": str(catalog_path), "schemaVersion": 1, "sha256": catalog_sha256},
    "generatedAtEpoch": now,
    "summary": {
        "requiredScenarioCount": len(scenarios),
        "passedScenarioCount": len(scenarios),
        "failedScenarioCount": 0,
        "missingScenarioCount": 0,
        "failureKindCounts": {},
        "evidenceOldestMtime": now,
        "evidenceNewestMtime": now,
        "runArtifactMissingCount": 0,
    },
    "requirements": {"runArtifacts": True, "maxEvidenceAgeSeconds": 86400},
    "requiredScenarios": [
        {
            "scenario": str(scenario),
            "status": "PASS",
            "latestStatus": "PASS",
            "runCount": 1,
            "failureKinds": [],
            "runArtifactsOK": True,
        }
        for scenario in scenarios
    ],
}
path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY

  FAKE_PROBE_RESULT=pass \
  CURRENT_PRODUCTION_SELF_TEST=false \
  CURRENT_PRODUCTION_HTTP_ENTRYPOINT_PROBE="${fake_probe}" \
  CURRENT_PRODUCTION_RESCUE_GENERATOR="${fake_rescue}" \
  CURRENT_PRODUCTION_NON_LARGE_GROUP_RUNNER="${fake_non_large}" \
  CURRENT_PRODUCTION_SCENARIO_SUITE_RUNNER="${fake_suite}" \
  CURRENT_PRODUCTION_PRODUCTION_PROFILE_RUNNER="${fake_profile}" \
  CURRENT_PRODUCTION_PRODUCT_CAMPAIGN_RUNNER="${fake_campaign}" \
  CURRENT_PRODUCTION_OPERATOR_NETWORK_PREFLIGHT=true \
  CURRENT_PRODUCTION_OPERATOR_NETWORK_PREFLIGHT_SCRIPT="${fake_operator_pass}" \
  CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE=true \
  CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_AUDIT_SCRIPT="${fake_cloud_security_group_audit_pass}" \
  CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_FILE="${cloud_security_group_good}" \
  CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER=true \
  CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON="${cloud_security_group_repair_receipt}" \
  CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID="sg-current-readiness-selftest" \
  CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID="cn-shenzhen" \
  CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR="203.0.113.10/32" \
  CURRENT_PRODUCTION_PRODUCTION_GATE_JSON="${production_gate_pass}" \
  RESULT_ROOT="${tmpdir}/pass-results" \
  RUN_ID="pass" \
  BASE_URL="https://chat.myim-prod.com" \
  TCP_HOST="" \
  ACCOUNT_FILE="${tmpdir}/load-10000.csv" \
  IM_CONVERSATION_ID="00000000-0000-0000-0000-000000000001" \
  IM_INTERNAL_SECRET="self-test-internal-secret" \
  FAKE_RUN_LOG="${tmpdir}/pass-run.log" \
    "${BASH_SOURCE[0]}" >"${tmpdir}/pass.out" 2>"${tmpdir}/pass.err" || {
      cat "${tmpdir}/pass.err" >&2
      if [[ -f "${tmpdir}/pass-results/pass/current-production-state-summary.json" ]]; then
        python3 - "${tmpdir}/pass-results/pass/current-production-state-summary.json" >&2 <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
summary = payload.get("summary") or {}
print(
    "current_production_readiness_self_test debug "
    f"currentReadinessStatus={summary.get('currentReadinessStatus')} "
    f"currentReadinessReason={summary.get('currentReadinessReason')} "
    f"productionEvidenceBlockerCount={summary.get('productionEvidenceBlockerCount')} "
    f"productionEvidenceBlockers={summary.get('productionEvidenceBlockers')}"
)
PY
      fi
      if [[ -f "${tmpdir}/pass-results/pass/production-full-acceptance.log" ]]; then
        sed -n '1,80p' "${tmpdir}/pass-results/pass/production-full-acceptance.log" >&2
      fi
      return 1
    }
  grep -q 'mode=smoke base=https://chat.myim-prod.com tcp=chat.myim-prod.com' "${tmpdir}/pass-run.log" || {
    printf 'current_production_readiness_self_test result=fail reason=smoke_not_run_with_derived_target\n' >&2
    return 1
  }
  grep -q 'suite=recommended base=https://chat.myim-prod.com tcp=chat.myim-prod.com' "${tmpdir}/pass-run.log" || {
    printf 'current_production_readiness_self_test result=fail reason=product_scenario_suite_not_run_with_target\n' >&2
    return 1
  }
  grep -q 'profile=normal-product-baseline base=https://chat.myim-prod.com tcp=chat.myim-prod.com' "${tmpdir}/pass-run.log" || {
    printf 'current_production_readiness_self_test result=fail reason=baseline_not_run_with_profile\n' >&2
    return 1
  }
  grep -q 'campaign=production-full-acceptance base=https://chat.myim-prod.com tcp=chat.myim-prod.com' "${tmpdir}/pass-run.log" || {
    printf 'current_production_readiness_self_test result=fail reason=full_acceptance_not_run_with_target\n' >&2
    return 1
  }
  python3 - "${tmpdir}/pass-results/pass/current-production-readiness.json" "${cloud_security_group_good}" "${cloud_security_group_repair_receipt}" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if payload.get("status") != "PASS":
    raise SystemExit("current_production_readiness_self_test result=fail reason=pass_status_missing")
if payload.get("target", {}).get("tcpHost") != "chat.myim-prod.com":
    raise SystemExit("current_production_readiness_self_test result=fail reason=derived_tcp_host_missing")
if payload.get("runs", {}).get("smokeExitCode") != 0:
    raise SystemExit("current_production_readiness_self_test result=fail reason=smoke_exit_missing")
if payload.get("runs", {}).get("suiteExitCode") != 0:
    raise SystemExit("current_production_readiness_self_test result=fail reason=product_scenario_suite_exit_missing")
if payload.get("evidencePolicy", {}).get("requirePackageableEvidence") is not True:
    raise SystemExit("current_production_readiness_self_test result=fail reason=packageable_evidence_policy_missing")
if payload.get("evidencePolicy", {}).get("requireCloudSecurityGroup") is not True:
    raise SystemExit("current_production_readiness_self_test result=fail reason=cloud_security_group_policy_missing")
if payload.get("evidencePolicy", {}).get("requirePublicPortPolicy") is not True:
    raise SystemExit("current_production_readiness_self_test result=fail reason=public_port_policy_missing")
if payload.get("evidencePolicy", {}).get("allowTempHTTP8080") is not False:
    raise SystemExit("current_production_readiness_self_test result=fail reason=temp_http_8080_policy_invalid")
if payload.get("evidencePolicy", {}).get("cloudSecurityGroupRulesMaxAgeSeconds") != 86400:
    raise SystemExit("current_production_readiness_self_test result=fail reason=cloud_security_group_rules_max_age_missing")
if payload.get("evidencePolicy", {}).get("cloudSecurityGroupRulesRequireRootOwner") is not True:
    raise SystemExit("current_production_readiness_self_test result=fail reason=cloud_security_group_rules_root_owner_policy_missing")
if payload.get("evidencePolicy", {}).get("cloudSecurityGroupRulesFile") != sys.argv[2]:
    raise SystemExit("current_production_readiness_self_test result=fail reason=cloud_security_group_rules_file_missing")
if payload.get("evidencePolicy", {}).get("requireCloudSecurityGroupRepairReceipt") is not True:
    raise SystemExit("current_production_readiness_self_test result=fail reason=cloud_security_group_repair_receipt_policy_missing")
if payload.get("evidencePolicy", {}).get("cloudSecurityGroupRepairReceiptJSON") != sys.argv[3]:
    raise SystemExit("current_production_readiness_self_test result=fail reason=cloud_security_group_repair_receipt_path_missing")
if payload.get("evidencePolicy", {}).get("cloudSecurityGroupRepairReceiptExpectSecurityGroupID") != "sg-current-readiness-selftest":
    raise SystemExit("current_production_readiness_self_test result=fail reason=cloud_security_group_repair_receipt_expected_security_group_missing")
if payload.get("evidencePolicy", {}).get("cloudSecurityGroupRepairReceiptExpectRegionID") != "cn-shenzhen":
    raise SystemExit("current_production_readiness_self_test result=fail reason=cloud_security_group_repair_receipt_expected_region_missing")
if payload.get("evidencePolicy", {}).get("cloudSecurityGroupRepairReceiptExpectAdminCIDR") != "203.0.113.10/32":
    raise SystemExit("current_production_readiness_self_test result=fail reason=cloud_security_group_repair_receipt_expected_admin_cidr_missing")
if not isinstance(payload.get("evidencePolicy", {}).get("operatorNetworkPreflight"), bool):
    raise SystemExit("current_production_readiness_self_test result=fail reason=operator_network_preflight_policy_missing")
if payload.get("evidencePolicy", {}).get("operatorNetworkPreflight") is not True:
    raise SystemExit("current_production_readiness_self_test result=fail reason=operator_network_preflight_policy_not_required")
if payload.get("evidencePolicy", {}).get("autoProductScenarioSuiteForPackageableAcceptance") is not True:
    raise SystemExit("current_production_readiness_self_test result=fail reason=auto_product_scenario_suite_policy_missing")
if payload.get("requestedRuns", {}).get("productScenarioSuite") is not True:
    raise SystemExit("current_production_readiness_self_test result=fail reason=auto_product_scenario_suite_not_requested")
if payload.get("requestedRuns", {}).get("baseline") is not True:
    raise SystemExit("current_production_readiness_self_test result=fail reason=auto_baseline_not_requested")
if payload.get("runs", {}).get("baselineExitCode") != 0:
    raise SystemExit("current_production_readiness_self_test result=fail reason=baseline_exit_missing")
artifacts = payload.get("artifacts") or {}
if not artifacts.get("cloudSecurityGroupAuditLog"):
    raise SystemExit("current_production_readiness_self_test result=fail reason=cloud_security_group_audit_log_missing")
if not artifacts.get("cloudSecurityGroupRepairReceiptJSON") or not artifacts.get("cloudSecurityGroupRepairReceiptVerifyLog"):
    raise SystemExit("current_production_readiness_self_test result=fail reason=cloud_security_group_repair_receipt_artifacts_missing")
operator_log = artifacts.get("operatorNetworkLog")
if not operator_log or not Path(str(operator_log)).is_file():
    raise SystemExit("current_production_readiness_self_test result=fail reason=operator_network_log_missing")
operator_json = artifacts.get("operatorNetworkJSON")
if not operator_json or not Path(str(operator_json)).is_file():
    raise SystemExit("current_production_readiness_self_test result=fail reason=operator_network_json_missing")
operator_payload = json.loads(Path(str(operator_json)).read_text(encoding="utf-8"))
if operator_payload.get("failed") is not False or operator_payload.get("failureCount") != 0:
    raise SystemExit("current_production_readiness_self_test result=fail reason=operator_network_json_pass_invalid")
operator_summary = payload.get("operatorNetwork") or {}
if operator_summary.get("failed") is not False or operator_summary.get("failureCount") != 0:
    raise SystemExit("current_production_readiness_self_test result=fail reason=operator_network_summary_pass_invalid")
if operator_summary.get("warnings"):
    raise SystemExit("current_production_readiness_self_test result=fail reason=operator_network_summary_warning_unexpected")
if not artifacts.get("productScenarioSuiteRunJSON") or not artifacts.get("productScenarioSuiteRunMarkdown"):
    raise SystemExit("current_production_readiness_self_test result=fail reason=product_scenario_suite_artifacts_missing")
if payload.get("runs", {}).get("fullAcceptanceExitCode") != 0:
    raise SystemExit("current_production_readiness_self_test result=fail reason=full_acceptance_exit_missing")
PY
  python3 - "${tmpdir}/pass-results/pass/current-production-state-summary.json" "${tmpdir}/pass-results/current-production-dashboard.json" "${tmpdir}/pass-results/pass/current-production-state-summary.csv" <<'PY'
import csv
import json
import sys
from pathlib import Path

state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
dashboard = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
csv_rows = list(csv.DictReader(Path(sys.argv[3]).open(newline="", encoding="utf-8")))
if (state.get("summary") or {}).get("conclusion") != "READY":
    raise SystemExit("current_production_readiness_self_test result=fail reason=pass_state_not_ready")
if (dashboard.get("summary") or {}).get("entrypointRescueBlocked") is not False:
    raise SystemExit("current_production_readiness_self_test result=fail reason=pass_dashboard_entrypoint_blocked")
state_summary = state.get("summary") or {}
if state_summary.get("currentReadinessOperatorNetworkPreflight") is not True:
    raise SystemExit("current_production_readiness_self_test result=fail reason=pass_state_operator_network_policy_missing")
if state_summary.get("currentReadinessOperatorNetworkLogPresent") is not True:
    raise SystemExit("current_production_readiness_self_test result=fail reason=pass_state_operator_network_log_missing")
if state_summary.get("currentReadinessOperatorNetworkFailed") is not False:
    raise SystemExit("current_production_readiness_self_test result=fail reason=pass_state_operator_network_failed")
if state_summary.get("currentReadinessOperatorNetworkWarnings") != []:
    raise SystemExit("current_production_readiness_self_test result=fail reason=pass_state_operator_network_warning")
csv_summary = next((row for row in csv_rows if row.get("recordType") == "summary"), None)
if csv_summary is None:
    raise SystemExit("current_production_readiness_self_test result=fail reason=pass_state_csv_summary_missing")
if csv_summary.get("currentReadinessOperatorNetworkPreflight") != "True":
    raise SystemExit("current_production_readiness_self_test result=fail reason=csv_operator_network_policy_missing")
if csv_summary.get("currentReadinessOperatorNetworkLogPresent") != "True":
    raise SystemExit("current_production_readiness_self_test result=fail reason=csv_operator_network_log_missing")
if csv_summary.get("currentReadinessOperatorNetworkFailed") != "False":
    raise SystemExit("current_production_readiness_self_test result=fail reason=csv_operator_network_failed")
for source, payload in (("state", state), ("dashboard", dashboard)):
    summary = payload.get("summary") or {}
    if summary.get("currentReadinessRequestedProductScenarioSuite") is not True:
        raise SystemExit(f"current_production_readiness_self_test result=fail reason={source}_product_scenario_suite_requested_missing")
    if summary.get("currentReadinessProductScenarioSuiteExitCode") != 0:
        raise SystemExit(f"current_production_readiness_self_test result=fail reason={source}_product_scenario_suite_exit_missing")
    if summary.get("currentReadinessProductScenarioSuiteExpected") != "recommended":
        raise SystemExit(f"current_production_readiness_self_test result=fail reason={source}_product_scenario_suite_expected_missing")
    if summary.get("currentReadinessProductScenarioSuite") != "recommended":
        raise SystemExit(f"current_production_readiness_self_test result=fail reason={source}_product_scenario_suite_actual_missing")
    if summary.get("currentReadinessProductScenarioSuiteStatus") != "PASS":
        raise SystemExit(f"current_production_readiness_self_test result=fail reason={source}_product_scenario_suite_status_missing")
    if summary.get("currentReadinessProductScenarioSuiteStageCount") != 1:
        raise SystemExit(f"current_production_readiness_self_test result=fail reason={source}_product_scenario_suite_stage_count_invalid")
    if summary.get("currentReadinessProductScenarioSuiteFailedStages") != 0 or summary.get("currentReadinessProductScenarioSuitePlannedStages") != 0:
        raise SystemExit(f"current_production_readiness_self_test result=fail reason={source}_product_scenario_suite_non_pass_stage_counts_invalid")
    if summary.get("currentReadinessProductScenarioSuiteScenarios") != 8:
        raise SystemExit(f"current_production_readiness_self_test result=fail reason={source}_product_scenario_suite_scenario_count_invalid")
    if summary.get("currentReadinessProductScenarioSuiteProductPlanStages") != 1:
        raise SystemExit(f"current_production_readiness_self_test result=fail reason={source}_product_scenario_suite_product_plan_count_invalid")
    if summary.get("currentReadinessProductScenarioSuiteLargeGroupIncluded") is not False:
        raise SystemExit(f"current_production_readiness_self_test result=fail reason={source}_product_scenario_suite_large_group_invalid")
    if summary.get("currentReadinessFullAcceptanceExpectedCampaign") != "production-full-acceptance":
        raise SystemExit(f"current_production_readiness_self_test result=fail reason={source}_full_acceptance_expected_campaign_missing")
    if summary.get("currentReadinessFullAcceptanceCampaign") != "production-full-acceptance":
        raise SystemExit(f"current_production_readiness_self_test result=fail reason={source}_full_acceptance_campaign_missing")
    if summary.get("currentReadinessFullAcceptanceStatus") != "PASS":
        raise SystemExit(f"current_production_readiness_self_test result=fail reason={source}_full_acceptance_status_missing")
    if summary.get("currentReadinessFullAcceptanceFailures") != 0 or summary.get("currentReadinessFullAcceptanceRequiredFailures") != 0:
        raise SystemExit(f"current_production_readiness_self_test result=fail reason={source}_full_acceptance_failure_counts_invalid")
    if summary.get("currentReadinessFullAcceptanceAttempted") != 6 or summary.get("currentReadinessFullAcceptanceSkipped") != 0:
        raise SystemExit(f"current_production_readiness_self_test result=fail reason={source}_full_acceptance_stage_counts_invalid")
if csv_summary.get("currentReadinessFullAcceptanceExpectedCampaign") != "production-full-acceptance":
    raise SystemExit("current_production_readiness_self_test result=fail reason=csv_full_acceptance_expected_campaign_missing")
if csv_summary.get("currentReadinessRequestedProductScenarioSuite") != "True":
    raise SystemExit("current_production_readiness_self_test result=fail reason=csv_product_scenario_suite_requested_missing")
if csv_summary.get("currentReadinessProductScenarioSuiteExitCode") != "0":
    raise SystemExit("current_production_readiness_self_test result=fail reason=csv_product_scenario_suite_exit_missing")
if csv_summary.get("currentReadinessProductScenarioSuiteExpected") != "recommended":
    raise SystemExit("current_production_readiness_self_test result=fail reason=csv_product_scenario_suite_expected_missing")
if csv_summary.get("currentReadinessProductScenarioSuite") != "recommended":
    raise SystemExit("current_production_readiness_self_test result=fail reason=csv_product_scenario_suite_actual_missing")
if csv_summary.get("currentReadinessProductScenarioSuiteStatus") != "PASS":
    raise SystemExit("current_production_readiness_self_test result=fail reason=csv_product_scenario_suite_status_missing")
if csv_summary.get("currentReadinessProductScenarioSuiteStageCount") != "1":
    raise SystemExit("current_production_readiness_self_test result=fail reason=csv_product_scenario_suite_stage_count_invalid")
if csv_summary.get("currentReadinessProductScenarioSuiteFailedStages") != "0" or csv_summary.get("currentReadinessProductScenarioSuitePlannedStages") != "0":
    raise SystemExit("current_production_readiness_self_test result=fail reason=csv_product_scenario_suite_non_pass_stage_counts_invalid")
if csv_summary.get("currentReadinessProductScenarioSuiteScenarios") != "8":
    raise SystemExit("current_production_readiness_self_test result=fail reason=csv_product_scenario_suite_scenario_count_invalid")
if csv_summary.get("currentReadinessProductScenarioSuiteProductPlanStages") != "1":
    raise SystemExit("current_production_readiness_self_test result=fail reason=csv_product_scenario_suite_product_plan_count_invalid")
if csv_summary.get("currentReadinessProductScenarioSuiteLargeGroupIncluded") != "False":
    raise SystemExit("current_production_readiness_self_test result=fail reason=csv_product_scenario_suite_large_group_invalid")
if csv_summary.get("currentReadinessFullAcceptanceCampaign") != "production-full-acceptance":
    raise SystemExit("current_production_readiness_self_test result=fail reason=csv_full_acceptance_campaign_missing")
if csv_summary.get("currentReadinessFullAcceptanceStatus") != "PASS":
    raise SystemExit("current_production_readiness_self_test result=fail reason=csv_full_acceptance_status_missing")
if csv_summary.get("currentReadinessFullAcceptanceFailures") != "0" or csv_summary.get("currentReadinessFullAcceptanceRequiredFailures") != "0":
    raise SystemExit("current_production_readiness_self_test result=fail reason=csv_full_acceptance_failure_counts_invalid")
if csv_summary.get("currentReadinessFullAcceptanceAttempted") != "6" or csv_summary.get("currentReadinessFullAcceptanceSkipped") != "0":
    raise SystemExit("current_production_readiness_self_test result=fail reason=csv_full_acceptance_stage_counts_invalid")
PY

  FAKE_PROBE_RESULT=pass \
  CURRENT_PRODUCTION_SELF_TEST=false \
  CURRENT_PRODUCTION_HTTP_ENTRYPOINT_PROBE="${fake_probe}" \
  CURRENT_PRODUCTION_RESCUE_GENERATOR="${fake_rescue}" \
  CURRENT_PRODUCTION_NON_LARGE_GROUP_RUNNER="${fake_non_large}" \
  CURRENT_PRODUCTION_SCENARIO_SUITE_RUNNER="${fake_suite}" \
  CURRENT_PRODUCTION_PRODUCTION_PROFILE_RUNNER="${fake_profile}" \
  CURRENT_PRODUCTION_PRODUCT_CAMPAIGN_RUNNER="${fake_campaign}" \
  CURRENT_PRODUCTION_RUN_SCENARIO_SUITE=false \
  CURRENT_PRODUCTION_RUN_BASELINE=true \
  CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE=true \
  RESULT_ROOT="${tmpdir}/explicit-suite-disabled-results" \
  RUN_ID="explicit-suite-disabled" \
  BASE_URL="http://203.0.113.10:8080" \
  TCP_HOST="" \
  ACCOUNT_FILE="${tmpdir}/load-10000.csv" \
  IM_CONVERSATION_ID="00000000-0000-0000-0000-000000000001" \
  IM_INTERNAL_SECRET="self-test-internal-secret" \
  FAKE_RUN_LOG="${tmpdir}/explicit-suite-disabled-run.log" \
    "${BASH_SOURCE[0]}" >"${tmpdir}/explicit-suite-disabled.out" 2>"${tmpdir}/explicit-suite-disabled.err" && {
      printf 'current_production_readiness_self_test result=fail reason=explicit_suite_disabled_path_passed\n' >&2
      return 1
    }
  grep -q 'product_scenario_suite_required_for_packageable_evidence' "${tmpdir}/explicit-suite-disabled.err" || {
    printf 'current_production_readiness_self_test result=fail reason=explicit_suite_disabled_reason_missing\n' >&2
    return 1
  }
  [[ ! -f "${tmpdir}/explicit-suite-disabled-run.log" ]] || {
    printf 'current_production_readiness_self_test result=fail reason=explicit_suite_disabled_started_load\n' >&2
    return 1
  }
  python3 - "${tmpdir}/explicit-suite-disabled-results/explicit-suite-disabled/current-production-readiness.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if payload.get("status") != "FAIL" or payload.get("reason") != "requested_run_prereq_failed":
    raise SystemExit("current_production_readiness_self_test result=fail reason=explicit_suite_disabled_receipt_invalid")
if payload.get("runs", {}).get("smokeExitCode") is not None:
    raise SystemExit("current_production_readiness_self_test result=fail reason=explicit_suite_disabled_smoke_started")
if payload.get("requestedRuns", {}).get("productScenarioSuite") is not False:
    raise SystemExit("current_production_readiness_self_test result=fail reason=explicit_suite_disabled_requested_invalid")
PY

  FAKE_PROBE_RESULT=pass \
  CURRENT_PRODUCTION_SELF_TEST=false \
  CURRENT_PRODUCTION_HTTP_ENTRYPOINT_PROBE="${fake_probe}" \
  CURRENT_PRODUCTION_RESCUE_GENERATOR="${fake_rescue}" \
  CURRENT_PRODUCTION_NON_LARGE_GROUP_RUNNER="${fake_non_large}" \
  CURRENT_PRODUCTION_SCENARIO_SUITE_RUNNER="${fake_suite}" \
  CURRENT_PRODUCTION_PRODUCTION_PROFILE_RUNNER="${fake_profile}" \
  CURRENT_PRODUCTION_PRODUCT_CAMPAIGN_RUNNER="${fake_campaign}" \
  CURRENT_PRODUCTION_RUN_BASELINE=false \
  CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE=true \
  RESULT_ROOT="${tmpdir}/explicit-baseline-disabled-results" \
  RUN_ID="explicit-baseline-disabled" \
  BASE_URL="http://203.0.113.10:8080" \
  TCP_HOST="" \
  ACCOUNT_FILE="${tmpdir}/load-10000.csv" \
  IM_CONVERSATION_ID="00000000-0000-0000-0000-000000000001" \
  IM_INTERNAL_SECRET="self-test-internal-secret" \
  FAKE_RUN_LOG="${tmpdir}/explicit-baseline-disabled-run.log" \
    "${BASH_SOURCE[0]}" >"${tmpdir}/explicit-baseline-disabled.out" 2>"${tmpdir}/explicit-baseline-disabled.err" && {
      printf 'current_production_readiness_self_test result=fail reason=explicit_baseline_disabled_path_passed\n' >&2
      return 1
    }
  grep -q 'baseline_required_for_packageable_full_acceptance' "${tmpdir}/explicit-baseline-disabled.err" || {
    printf 'current_production_readiness_self_test result=fail reason=explicit_baseline_disabled_reason_missing\n' >&2
    return 1
  }
  [[ ! -f "${tmpdir}/explicit-baseline-disabled-run.log" ]] || {
    printf 'current_production_readiness_self_test result=fail reason=explicit_baseline_disabled_started_load\n' >&2
    return 1
  }

  FAKE_PROBE_RESULT=pass \
  CURRENT_PRODUCTION_SELF_TEST=false \
  CURRENT_PRODUCTION_HTTP_ENTRYPOINT_PROBE="${fake_probe}" \
  CURRENT_PRODUCTION_RESCUE_GENERATOR="${fake_rescue}" \
  CURRENT_PRODUCTION_NON_LARGE_GROUP_RUNNER="${fake_non_large}" \
  CURRENT_PRODUCTION_SCENARIO_SUITE_RUNNER="${fake_suite}" \
  CURRENT_PRODUCTION_PRODUCTION_PROFILE_RUNNER="${fake_profile}" \
  CURRENT_PRODUCTION_PRODUCT_CAMPAIGN_RUNNER="${fake_campaign}" \
  CURRENT_PRODUCTION_RUN_SMOKE=false \
  CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE=true \
  RESULT_ROOT="${tmpdir}/explicit-smoke-disabled-results" \
  RUN_ID="explicit-smoke-disabled" \
  BASE_URL="http://203.0.113.10:8080" \
  TCP_HOST="" \
  ACCOUNT_FILE="${tmpdir}/load-10000.csv" \
  IM_CONVERSATION_ID="00000000-0000-0000-0000-000000000001" \
  IM_INTERNAL_SECRET="self-test-internal-secret" \
  FAKE_RUN_LOG="${tmpdir}/explicit-smoke-disabled-run.log" \
    "${BASH_SOURCE[0]}" >"${tmpdir}/explicit-smoke-disabled.out" 2>"${tmpdir}/explicit-smoke-disabled.err" && {
      printf 'current_production_readiness_self_test result=fail reason=explicit_smoke_disabled_path_passed\n' >&2
      return 1
    }
  grep -q 'smoke_required_for_packageable_evidence' "${tmpdir}/explicit-smoke-disabled.err" || {
    printf 'current_production_readiness_self_test result=fail reason=explicit_smoke_disabled_reason_missing\n' >&2
    return 1
  }
  [[ ! -f "${tmpdir}/explicit-smoke-disabled-run.log" ]] || {
    printf 'current_production_readiness_self_test result=fail reason=explicit_smoke_disabled_started_load\n' >&2
    return 1
  }
  printf 'current_production_readiness_self_test result=pass\n'
}

main() {
  if bool_enabled "${CURRENT_PRODUCTION_SELF_TEST}"; then
    run_self_test
    return 0
  fi

  mkdir -p "${RUN_DIR}"
  refresh_current_link

  if ! run_operator_network_preflight; then
    local operator_summary
    write_probe_fallback_json \
      "${RUN_DIR}/entrypoint-probe.json" \
      "local_operator_network_blocked" \
      "operator network preflight failed before public entrypoint probe" \
      "disconnect_local_tun_or_use_clean_network"
    operator_summary="$(generate_rescue_artifact | tail -n 1)"
    write_receipt "BLOCKED_ENTRYPOINT" "$(json_value "${RUN_DIR}/entrypoint-probe.json" diagnosis)" "${RUN_DIR}/entrypoint-probe.json" "${operator_summary}" "-" "-" "-" "-"
    generate_state_outputs "${operator_summary}"
    verify_current_artifacts
    printf 'current_production_readiness result=blocked reason=%s runDir=%s operatorSummary=%s\n' \
      "$(json_value "${RUN_DIR}/entrypoint-probe.json" diagnosis)" \
      "${RUN_DIR}" \
      "${operator_summary}" >&2
    return 1
  fi

  if ! run_entrypoint_probe; then
    local rescue_summary
    rescue_summary="$(generate_rescue_artifact | tail -n 1)"
    write_receipt "BLOCKED_ENTRYPOINT" "$(json_value "${RUN_DIR}/entrypoint-probe.json" diagnosis)" "${RUN_DIR}/entrypoint-probe.json" "${rescue_summary}" "-" "-" "-" "-"
    generate_state_outputs "${rescue_summary}"
    verify_current_artifacts
    printf 'current_production_readiness result=blocked reason=%s runDir=%s rescueSummary=%s\n' \
      "$(json_value "${RUN_DIR}/entrypoint-probe.json" diagnosis)" \
      "${RUN_DIR}" \
      "${rescue_summary}" >&2
    return 1
  fi

  local smoke_rc=0
  local suite_rc=0
  local baseline_rc=0
  local full_acceptance_rc=0
  local entrypoint_summary="${RUN_DIR}/entrypoint-summary.txt"
  write_entrypoint_summary_from_probe "${RUN_DIR}/entrypoint-probe.json" "${entrypoint_summary}"

  local requested_prereq_output
  if ! requested_prereq_output="$(requested_run_prereq_error)"; then
    local prereq_summary
    prereq_summary="$(write_prereq_summary "${requested_prereq_output}")"
    printf 'current_production_readiness result=fail reason=requested_run_prereq_failed detail=%s runDir=%s prereqSummary=%s\n' \
      "${requested_prereq_output}" \
      "${RUN_DIR}" \
      "${prereq_summary}" >&2
    write_receipt "FAIL" "requested_run_prereq_failed" "${RUN_DIR}/entrypoint-probe.json" "${entrypoint_summary}" "-" "-" "-" "-"
    generate_state_outputs "${entrypoint_summary}"
    verify_current_artifacts
    return 2
  fi

  set +e
  run_smoke
  smoke_rc=$?
  set -e
  if [[ "${smoke_rc}" -ne 0 ]]; then
    write_receipt "FAIL" "smoke_failed" "${RUN_DIR}/entrypoint-probe.json" "${entrypoint_summary}" "${smoke_rc}" "-" "-" "-"
    generate_state_outputs "${entrypoint_summary}"
    verify_current_artifacts
    printf 'current_production_readiness result=fail reason=smoke_failed runDir=%s\n' "${RUN_DIR}" >&2
    return "${smoke_rc}"
  fi

  set +e
  run_product_scenario_suite
  suite_rc=$?
  set -e
  if [[ "${suite_rc}" -ne 0 ]]; then
    write_receipt "FAIL" "product_scenario_suite_failed" "${RUN_DIR}/entrypoint-probe.json" "${entrypoint_summary}" "${smoke_rc}" "${suite_rc}" "-" "-"
    generate_state_outputs "${entrypoint_summary}"
    verify_current_artifacts
    printf 'current_production_readiness result=fail reason=product_scenario_suite_failed runDir=%s\n' "${RUN_DIR}" >&2
    return "${suite_rc}"
  fi

  set +e
  run_baseline
  baseline_rc=$?
  set -e
  if [[ "${baseline_rc}" -ne 0 ]]; then
    write_receipt "FAIL" "baseline_failed" "${RUN_DIR}/entrypoint-probe.json" "${entrypoint_summary}" "${smoke_rc}" "${suite_rc}" "${baseline_rc}" "-"
    generate_state_outputs "${entrypoint_summary}"
    verify_current_artifacts
    printf 'current_production_readiness result=fail reason=baseline_failed runDir=%s\n' "${RUN_DIR}" >&2
    return "${baseline_rc}"
  fi

  set +e
  run_full_acceptance
  full_acceptance_rc=$?
  set -e
  if [[ "${full_acceptance_rc}" -ne 0 ]]; then
    write_receipt "FAIL" "full_acceptance_failed" "${RUN_DIR}/entrypoint-probe.json" "${entrypoint_summary}" "${smoke_rc}" "${suite_rc}" "${baseline_rc}" "${full_acceptance_rc}"
    generate_state_outputs "${entrypoint_summary}"
    verify_current_artifacts
    printf 'current_production_readiness result=fail reason=full_acceptance_failed runDir=%s\n' "${RUN_DIR}" >&2
    return "${full_acceptance_rc}"
  fi

  write_receipt "PASS" "entrypoint_and_requested_runs_passed" "${RUN_DIR}/entrypoint-probe.json" "${entrypoint_summary}" "${smoke_rc}" "${suite_rc}" "${baseline_rc}" "${full_acceptance_rc}"
  generate_state_outputs "${entrypoint_summary}"
  verify_current_artifacts
  printf 'current_production_readiness result=pass runDir=%s receipt=%s\n' \
    "${RUN_DIR}" \
    "${RUN_DIR}/current-production-readiness.json"
}

main
