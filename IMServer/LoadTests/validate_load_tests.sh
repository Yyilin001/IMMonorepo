#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT_DIR="${RESULT_DIR:-${SCRIPT_DIR}/results/validate-load-tests}"
VALIDATE_K6_INSPECT="${VALIDATE_K6_INSPECT:-true}"
VALIDATE_TCP_LADDER_TEST="${VALIDATE_TCP_LADDER_TEST:-false}"
VALIDATE_SWIFT_BUILD="${VALIDATE_SWIFT_BUILD:-false}"
VALIDATE_DRY_RUN="${VALIDATE_DRY_RUN:-true}"
VALIDATE_CLEAN_RESULT_DIR="${VALIDATE_CLEAN_RESULT_DIR:-true}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

log() {
  printf '==> %s\n' "$1"
}

if bool_enabled "${VALIDATE_CLEAN_RESULT_DIR}"; then
  resolved_result_dir="$(python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).resolve())' "${RESULT_DIR}")"
  resolved_script_dir="$(python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).resolve())' "${SCRIPT_DIR}")"
  if [[ "${resolved_result_dir}" == "/" || "${resolved_result_dir}" == "${resolved_script_dir}" ]]; then
    echo "Refusing to clean unsafe validate result directory: ${resolved_result_dir}" >&2
    exit 1
  fi
  rm -rf "${RESULT_DIR}"
fi
mkdir -p "${RESULT_DIR}"

log "shell syntax"
shell_syntax_files=()
while IFS= read -r shell_file; do
  shell_syntax_files+=("${shell_file}")
done < <(find "${SCRIPT_DIR}/../../deploy/ubuntu" -maxdepth 1 -type f -name '*.sh' | sort)
while IFS= read -r shell_file; do
  shell_syntax_files+=("${shell_file}")
done < <(find "${SCRIPT_DIR}" -maxdepth 1 -type f -name '*.sh' | sort)
if ((${#shell_syntax_files[@]} == 0)); then
  echo "No shell scripts found for syntax validation." >&2
  exit 1
fi
printf 'shellScripts=%s\n' "${#shell_syntax_files[@]}"
bash -n "${shell_syntax_files[@]}"

log "shell strict mode"
python3 - "${shell_syntax_files[@]}" <<'PY'
import re
import sys
from pathlib import Path

missing_shebang: list[str] = []
missing_strict: list[str] = []

for raw_path in sys.argv[1:]:
    path = Path(raw_path)
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    first = lines[0].strip() if lines else ""
    if first != "#!/usr/bin/env bash":
        missing_shebang.append(str(path))

    strict = False
    for line in lines[:12]:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = re.match(r"set\s+-([A-Za-z]+)\s+pipefail\b", stripped)
        if match:
            flags = set(match.group(1))
            strict = "e" in flags and "u" in flags
        break
    if not strict:
        missing_strict.append(str(path))

if missing_shebang or missing_strict:
    for path in missing_shebang:
        print(f"shell strict audit failed: missing bash shebang path={path}", file=sys.stderr)
    for path in missing_strict:
        print(f"shell strict audit failed: missing set -euo pipefail path={path}", file=sys.stderr)
    raise SystemExit(1)

print(f"shellStrictScripts={len(sys.argv) - 1}")
PY

log "shell executable mode"
python3 - "${shell_syntax_files[@]}" <<'PY'
import stat
import sys
from pathlib import Path

missing_executable: list[str] = []
for raw_path in sys.argv[1:]:
    path = Path(raw_path)
    mode = path.stat().st_mode
    if not (mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)):
        missing_executable.append(str(path))

if missing_executable:
    for path in missing_executable:
        print(f"shell executable audit failed: missing executable mode path={path}", file=sys.stderr)
    raise SystemExit(1)

print(f"shellExecutableScripts={len(sys.argv) - 1}")
PY

log "diagnostics redaction self-test"
DIAGNOSTIC_REDACTION_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/76_collect_diagnostics_bundle.sh" \
  >"${RESULT_DIR}/diagnostics-redaction-self-test.log"

log "diagnostics entrypoint self-test"
DIAGNOSTIC_ENTRYPOINT_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/76_collect_diagnostics_bundle.sh" \
  >"${RESULT_DIR}/diagnostics-entrypoint-self-test.log"

log "systemd units render self-test"
SYSTEMD_UNITS_RENDER_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/50_install_systemd_units.sh" \
  >"${RESULT_DIR}/systemd-units-render-self-test.log"

log "systemd unit verifier self-test"
SYSTEMD_UNIT_VERIFY_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/52_verify_systemd_units.sh" \
  >"${RESULT_DIR}/systemd-unit-verify-self-test.log"

log "JWT rotation migration self-test"
JWT_ROTATION_MIGRATION_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/54_migrate_jwt_rotation.sh" \
  >"${RESULT_DIR}/jwt-rotation-migration-self-test.log"

log "entrypoint probe redaction self-test"
PROBE_REDACTION_SELF_TEST=true \
  bash "${SCRIPT_DIR}/http_entrypoint_probe.sh" \
  >"${RESULT_DIR}/entrypoint-probe-redaction-self-test.log"

log "entrypoint probe protocol-hosts self-test"
PROBE_PROTOCOL_HOSTS_SELF_TEST=true \
  bash "${SCRIPT_DIR}/http_entrypoint_probe.sh" \
  >"${RESULT_DIR}/entrypoint-probe-protocol-hosts-self-test.log"

log "operator network preflight self-test"
OPERATOR_NETWORK_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/20_verify_operator_network.sh" \
  >"${RESULT_DIR}/operator-network-self-test.log"

log "performance artifact secret scan self-test"
python3 "${SCRIPT_DIR}/perf_secret_scan.py" --self-test \
  >"${RESULT_DIR}/perf-secret-scan-self-test.log"

log "production smoke config self-test"
bash "${SCRIPT_DIR}/../scripts/production_smoke.sh" self-test \
  >"${RESULT_DIR}/production-smoke-config-self-test.log"

log "local acceptance wrapper self-test"
LOCAL_ACCEPTANCE_SELF_TEST=true \
  bash "${SCRIPT_DIR}/run_local_acceptance.sh" self-test \
  >"${RESULT_DIR}/local-acceptance-wrapper-self-test.log"

log "local HTTP smoke self-test"
bash "${SCRIPT_DIR}/run_local_http_smoke.sh" self-test \
  >"${RESULT_DIR}/local-http-smoke-self-test.log"

log "local acceptance artifact verifier self-test"
python3 "${SCRIPT_DIR}/verify_local_acceptance.py" --self-test \
  >"${RESULT_DIR}/local-acceptance-verify-self-test.log"

log "kafka lag self-test"
KAFKA_LAG_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/74_check_kafka_lag.sh" \
  >"${RESULT_DIR}/kafka-lag-self-test.log"

log "entrypoint verify self-test"
VERIFY_ENTRYPOINT_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/65_verify_entrypoint.sh" \
  >"${RESULT_DIR}/entrypoint-verify-self-test.log"

log "entrypoint smoke self-test"
SMOKE_ENTRYPOINT_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/66_smoke_entrypoint.sh" \
  >"${RESULT_DIR}/entrypoint-smoke-self-test.log"

log "entrypoint diagnose self-test"
ENTRYPOINT_DIAGNOSE_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/75_entrypoint_diagnose.sh" \
  >"${RESULT_DIR}/entrypoint-diagnose-self-test.log"

log "entrypoint repair self-test"
ENTRYPOINT_REPAIR_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/64_repair_http_entrypoint.sh" \
  >"${RESULT_DIR}/entrypoint-repair-self-test.log"

log "https install self-test"
HTTPS_INSTALL_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/61_install_https.sh" \
  >"${RESULT_DIR}/https-install-self-test.log"

log "nginx install self-test"
NGINX_INSTALL_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/60_install_nginx.sh" \
  >"${RESULT_DIR}/nginx-install-self-test.log"

log "nginx config verifier self-test"
NGINX_VERIFY_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/62_verify_nginx_config.sh" \
  >"${RESULT_DIR}/nginx-config-verify-self-test.log"

log "ssh access repair self-test"
SSH_ACCESS_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/24_repair_ssh_access.sh" \
  >"${RESULT_DIR}/ssh-access-repair-self-test.log"

log "node access repair self-test"
NODE_ACCESS_REPAIR_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/23_repair_node_access.sh" \
  >"${RESULT_DIR}/node-access-repair-self-test.log"

log "host security self-test"
IM_HOST_SECURITY_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/25_setup_host_security.sh" \
  >"${RESULT_DIR}/host-security-self-test.log"

log "cloud security group audit self-test"
CLOUD_SECURITY_GROUP_AUDIT_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/26_audit_cloud_security_group.sh" \
  >"${RESULT_DIR}/cloud-security-group-audit-self-test.log"

log "cloud security group install self-test"
CLOUD_SECURITY_GROUP_INSTALL_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/27_install_cloud_security_group_snapshot.sh" \
  >"${RESULT_DIR}/cloud-security-group-install-self-test.log"

log "cloud security group template self-test"
CLOUD_SECURITY_GROUP_TEMPLATE_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/28_render_cloud_security_group_snapshot_template.sh" \
  >"${RESULT_DIR}/cloud-security-group-template-self-test.log"

log "aliyun cloud security group fetch self-test"
ALIYUN_SECURITY_GROUP_FETCH_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/29_fetch_aliyun_security_group_snapshot.sh" \
  >"${RESULT_DIR}/aliyun-cloud-security-group-fetch-self-test.log"

log "aliyun cloud security group repair self-test"
ALIYUN_SECURITY_GROUP_REPAIR_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/30_repair_aliyun_security_group.sh" \
  >"${RESULT_DIR}/aliyun-cloud-security-group-repair-self-test.log"

log "aliyun cloud security group repair receipt verifier self-test"
ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_VERIFY_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/31_verify_aliyun_security_group_repair_receipt.sh" \
  >"${RESULT_DIR}/aliyun-cloud-security-group-repair-receipt-verify-self-test.log"

log "node access rescue self-test"
NODE_ACCESS_RESCUE_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/22_node_access_rescue.sh" \
  >"${RESULT_DIR}/node-access-rescue-self-test.log"

log "node access rescue command render self-test"
RENDER_NODE_ACCESS_RESCUE_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/21_render_node_access_rescue_command.sh" \
  >"${RESULT_DIR}/node-access-rescue-command-render-self-test.log"

log "node access rescue artifact self-test"
NODE_ACCESS_RESCUE_ARTIFACT_SELF_TEST=true \
  bash "${SCRIPT_DIR}/generate_node_access_rescue_artifact.sh" \
  >"${RESULT_DIR}/node-access-rescue-artifact-self-test.log"

log "all-in-one deploy self-test"
IM_DEPLOY_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/90_deploy_single_node.sh" \
  >"${RESULT_DIR}/deploy-single-node-self-test.log"

log "rollback release self-test"
ROLLBACK_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/45_rollback_release.sh" \
  >"${RESULT_DIR}/rollback-release-self-test.log"

log "deploy failure artifact verifier self-test"
DEPLOY_FAILURE_ARTIFACTS_VERIFY_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/91_verify_deploy_failure_artifacts.sh" \
  >"${RESULT_DIR}/deploy-failure-artifacts-verify-self-test.log"

log "deploy failure artifact package self-test"
DEPLOY_FAILURE_ARTIFACT_PACKAGE_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/92_package_deploy_failure_artifacts.sh" \
  >"${RESULT_DIR}/deploy-failure-artifacts-package-self-test.log"

log "diagnostics performance evidence self-test"
DIAGNOSTIC_PERFORMANCE_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/76_collect_diagnostics_bundle.sh" \
  >"${RESULT_DIR}/diagnostics-performance-self-test.log"

log "readiness defaults self-test"
READINESS_DEFAULTS_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/95_production_readiness_gate.sh" \
  >"${RESULT_DIR}/readiness-defaults-self-test.log"
READINESS_PUBLIC_TARGET_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/95_production_readiness_gate.sh" \
  >"${RESULT_DIR}/readiness-public-target-self-test.log"
READINESS_PERFORMANCE_EVIDENCE_SUMMARY_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/95_production_readiness_gate.sh" \
  >"${RESULT_DIR}/readiness-performance-evidence-summary-self-test.log"
READINESS_AUDIT_ENV_SELF_TEST=true \
READINESS_REQUIRE_PERFORMANCE_GATE=true \
READINESS_REQUIRE_ALERT_WEBHOOK=true \
BACKUP_ROOT=/tmp/readiness-backups \
PERF_PRODUCTION_GATE_JSON=/tmp/readiness-gate.json \
PERF_PRODUCTION_GATE_PROFILE=normal-product-baseline \
PERF_PRODUCTION_GATE_REQUIRE_CURRENT_GIT=true \
PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT=true \
PUBLIC_BASE_URL=https://chat.myim-prod.com \
TCP_HOST=tcp.myim-prod.com \
TCP_PORT=9000 \
PERF_PRODUCTION_EVIDENCE_CURRENT_LINK=/tmp/current-evidence \
PERF_PRODUCTION_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS=false \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/95_production_readiness_gate.sh" \
  >"${RESULT_DIR}/readiness-audit-env-self-test.log"

log "operational audit defaults self-test"
AUDIT_DEFAULTS_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/77_operational_audit.sh" \
  >"${RESULT_DIR}/operational-audit-defaults-self-test.log"
AUDIT_UNIT_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/77_operational_audit.sh" \
  >"${RESULT_DIR}/operational-audit-unit-self-test.log"
AUDIT_PERFORMANCE_SUMMARY_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/77_operational_audit.sh" \
  >"${RESULT_DIR}/operational-audit-performance-summary-self-test.log"
AUDIT_TIMER_RENDER_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/78_install_operational_audit_timer.sh" \
  >"${RESULT_DIR}/operational-audit-timer-render-self-test.log"

log "operational alert self-test"
AUDIT_ALERT_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/79_send_operational_alert.sh" \
  >"${RESULT_DIR}/operational-alert-self-test.log"

log "backup timer render self-test"
BACKUP_TIMER_RENDER_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/85_install_backup_timer.sh" \
  >"${RESULT_DIR}/backup-timer-render-self-test.log"

log "backup create self-test"
BACKUP_CREATE_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/80_backup_single_node.sh" \
  >"${RESULT_DIR}/backup-create-self-test.log"

log "backup verifier self-test"
BACKUP_VERIFY_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/81_verify_backup.sh" \
  >"${RESULT_DIR}/backup-verify-self-test.log"

log "offsite backup sync self-test"
OFFSITE_BACKUP_SYNC_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/86_sync_backup_offsite.sh" \
  >"${RESULT_DIR}/offsite-backup-sync-self-test.log"

log "restore drill safety self-test"
RESTORE_DRILL_SAFETY_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/82_restore_drill_single_node.sh" \
  >"${RESULT_DIR}/restore-drill-safety-self-test.log"

log "restore drill timer render self-test"
RESTORE_DRILL_TIMER_RENDER_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/83_install_restore_drill_timer.sh" \
  >"${RESULT_DIR}/restore-drill-timer-render-self-test.log"

log "production evidence package self-test"
PRODUCTION_EVIDENCE_SELF_TEST=true \
  "${SCRIPT_DIR}/package_production_evidence.sh" \
  >"${RESULT_DIR}/production-evidence-package-self-test.log"

log "production acceptance wrapper self-test"
PRODUCTION_ACCEPTANCE_SELF_TEST=true \
  bash "${SCRIPT_DIR}/run_production_acceptance.sh" \
  >"${RESULT_DIR}/production-acceptance-self-test.log"

log "production acceptance env validator self-test"
PRODUCTION_ACCEPTANCE_ENV_SELF_TEST=true \
  bash "${SCRIPT_DIR}/validate_production_acceptance_env.sh" \
  >"${RESULT_DIR}/production-acceptance-env-validator-self-test.log"

log "production public target policy self-test"
python3 "${SCRIPT_DIR}/production_target_policy.py" --self-test \
  >"${RESULT_DIR}/production-target-policy-self-test.log"

log "production acceptance final verifier wrapper self-test"
VERIFY_PRODUCTION_ACCEPTANCE_SELF_TEST=true \
  bash "${SCRIPT_DIR}/verify_production_acceptance.sh" \
  >"${RESULT_DIR}/production-acceptance-final-verifier-self-test.log"

log "final production-ready assertion self-test"
ASSERT_PRODUCTION_READY_SELF_TEST=true \
  bash "${SCRIPT_DIR}/assert_production_ready.sh" \
  >"${RESULT_DIR}/production-ready-assertion-self-test.log"

log "final production-ready assertion verifier self-test"
python3 "${SCRIPT_DIR}/verify_production_ready_assertion.py" --self-test \
  >"${RESULT_DIR}/production-ready-assertion-verifier-self-test.log"

log "final production-ready assertion package self-test"
python3 "${SCRIPT_DIR}/package_production_ready_assertion.py" --self-test \
  >"${RESULT_DIR}/production-ready-assertion-package-self-test.log"

log "production readiness status self-test"
PRODUCTION_READINESS_STATUS_SELF_TEST=true \
  bash "${SCRIPT_DIR}/production_readiness_status.sh" \
  >"${RESULT_DIR}/production-readiness-status-self-test.log"

log "production acceptance receipt verifier self-test"
python3 "${SCRIPT_DIR}/perf_production_acceptance_verify.py" --self-test \
  >"${RESULT_DIR}/production-acceptance-verifier-self-test.log"

log "profile artifact verifier self-test"
profile_artifact_test_dir="${RESULT_DIR}/profile-artifact-verifier"
rm -rf "${profile_artifact_test_dir}"
mkdir -p "${profile_artifact_test_dir}"
python3 - "${profile_artifact_test_dir}" "${SCRIPT_DIR}/perf_production_profiles.json" <<'PY'
import hashlib
import json
import subprocess
import sys
import time
from pathlib import Path

output_dir, catalog_path = sys.argv[1:3]
output_path = Path(output_dir)
now = int(time.time())
with open(catalog_path, encoding="utf-8") as handle:
    scenarios = (json.load(handle).get("profiles") or {}).get("minimum-smoke") or []
with open(catalog_path, "rb") as handle:
    catalog_sha256 = hashlib.sha256(handle.read()).hexdigest()
gate = {
    "status": "PASS",
    "profile": "minimum-smoke",
    "source": {"repoRoot": str(Path(catalog_path).resolve().parents[2]), "gitCommit": "self-test", "gitBranch": "self-test", "gitDirty": False},
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
            "passed": True,
            "reason": "",
        }
        for scenario in scenarios
    ],
}
package_path = str(output_path / "evidence.tar.gz")
run = {
    "schemaVersion": 1,
    "profile": "minimum-smoke",
    "finalStatus": "PASS",
    "dryRun": False,
    "statusFilterTarget": True,
    "entrypointProbe": True,
    "entrypointProbeArtifacts": {
        "log": str(output_path / "production-profile-entrypoint-probe.log"),
        "json": str(output_path / "production-profile-entrypoint-probe.json"),
    },
    "package": {"status": "PACKAGED", "path": package_path, "fileName": "evidence.tar.gz"},
    "plan": {
        "profile": "minimum-smoke",
        "profileScenarioCount": len(scenarios),
        "selectedScenarioCount": 1,
        "skippedFreshPassCount": max(0, len(scenarios) - 1),
    },
    "batches": [{"index": 1, "runID": "self-test-batch01", "status": "PASS", "scenarios": ["login-smoke"]}],
}
bad_run = dict(run)
bad_run["package"] = {"status": "PACKAGED", "path": str(output_path / "wrong.tar.gz"), "fileName": "wrong.tar.gz"}
bad_entrypoint_disabled_run = json.loads(json.dumps(run))
bad_entrypoint_disabled_run["entrypointProbe"] = False
failed_entrypoint_run = json.loads(json.dumps(run))
failed_entrypoint_run["finalStatus"] = "FAIL"
failed_entrypoint_run["reason"] = "entrypoint_probe_failed"
failed_entrypoint_run["blockerType"] = "entrypoint"
failed_entrypoint_run["package"] = {}
failed_entrypoint_run["batches"] = []
failed_entrypoint_run["entrypointProbeArtifacts"]["json"] = str(output_path / "bad-production-profile-entrypoint-probe.json")
bad_gate = json.loads(json.dumps(gate))
bad_gate["targetFilter"]["enabled"] = False
bad_target_gate = json.loads(json.dumps(gate))
bad_target_gate["targetFilter"]["tcpHost"] = "tcp-alt.myim-prod.com"
bad_public_target_gate = json.loads(json.dumps(gate))
bad_public_target_gate["targetFilter"]["baseURL"] = "http://127.0.0.1:8080"
bad_public_target_gate["targetFilter"]["tcpHost"] = "127.0.0.1"
runbook = {
    "schemaVersion": 1,
    "status": "READY",
    "profile": "minimum-smoke",
    "plan": {
        "profileScenarioCount": len(scenarios),
        "selectedScenarioCount": 1,
        "skippedFreshPassCount": max(0, len(scenarios) - 1),
        "batchCount": 1,
    },
    "target": {"baseURL": "https://chat.myim-prod.com", "tcpHost": "tcp.myim-prod.com", "tcpPort": "9000"},
    "prereq": {"missingRequiredCount": 0},
    "evidencePolicy": {
        "classification": "diagnostic-production-profile",
        "requiresCurrentReadiness": False,
        "finalAcceptanceCommand": "CURRENT_PRODUCTION_REQUIRE_PACKAGEABLE_EVIDENCE=true CURRENT_PRODUCTION_RUN_BASELINE=true CURRENT_PRODUCTION_RUN_SCENARIO_SUITE=true CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE=true ./run_current_production_readiness.sh",
    },
    "commands": {
        "profile": "RESULT_ROOT=/tmp/self-test PERF_PRODUCTION_GATE_PROFILE=minimum-smoke PERF_STATUS_FILTER_TARGET=true PRODUCTION_PROFILE_REQUIRE_CLOUD_SECURITY_GROUP=true PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS=86400 PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080=false PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_FILE=${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_FILE:?set-PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_FILE} PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON=${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON:?set-PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON} PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID:?set-PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID} PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID:?set-PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID} PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR:?set-PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR} ./run_production_profile.sh",
        "package": "RESULT_ROOT=/tmp/self-test PERF_PRODUCTION_GATE_JSON=/tmp/self-test/production-gate.json PERF_PRODUCTION_GATE_PROFILE=minimum-smoke PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS=false PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS=false PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP=true PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS=86400 PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080=false PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_FILE=${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_FILE:?set-PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_FILE} PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON=${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON:?set-PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON} PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID:?set-PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID} PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID:?set-PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID} PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR:?set-PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR} ./package_production_evidence.sh",
        "batches": [{"index": 1, "scenarios": ["login-smoke"], "command": "SCENARIOS=login-smoke PERF_PRODUCTION_GATE_PROFILE=minimum-smoke PERF_PRODUCTION_GATE=true PERF_STATUS_FILTER_TARGET=true ./run_perf_scenarios.sh"}],
    },
}
bad_runbook = json.loads(json.dumps(runbook))
bad_runbook["commands"]["batches"][0]["scenarios"] = ["auth-session-smoke"]
bad_runbook["commands"]["batches"][0]["command"] = "SCENARIOS=auth-session-smoke PERF_PRODUCTION_GATE_PROFILE=minimum-smoke PERF_PRODUCTION_GATE=true PERF_STATUS_FILTER_TARGET=true ./run_perf_scenarios.sh"
bad_command_runbook = json.loads(json.dumps(runbook))
bad_command_runbook["commands"]["batches"][0]["command"] = "SCENARIOS=login-smoke-shadow PERF_PRODUCTION_GATE_PROFILE=minimum-smoke PERF_PRODUCTION_GATE=true PERF_STATUS_FILTER_TARGET=true ./run_perf_scenarios.sh"
bad_profile_command_runbook = json.loads(json.dumps(runbook))
bad_profile_command_runbook["commands"]["batches"][0]["command"] = "SCENARIOS=login-smoke PERF_PRODUCTION_GATE_PROFILE=other-profile PERF_PRODUCTION_GATE=true PERF_STATUS_FILTER_TARGET=true ./run_perf_scenarios.sh"
bad_status_filter_runbook = json.loads(json.dumps(runbook))
bad_status_filter_runbook["commands"]["batches"][0]["command"] = "SCENARIOS=login-smoke PERF_PRODUCTION_GATE_PROFILE=minimum-smoke PERF_PRODUCTION_GATE=true PERF_STATUS_FILTER_TARGET=false ./run_perf_scenarios.sh"
bad_evidence_policy_runbook = json.loads(json.dumps(runbook))
bad_evidence_policy_runbook["evidencePolicy"]["requiresCurrentReadiness"] = True
bad_public_target_runbook = json.loads(json.dumps(runbook))
bad_public_target_runbook["target"] = {"baseURL": "http://127.0.0.1:8080", "tcpHost": "127.0.0.1", "tcpPort": "9000"}
(output_path / "production-gate.json").write_text(json.dumps(gate, indent=2, sort_keys=True), encoding="utf-8")
(output_path / "bad-target-filter-production-gate.json").write_text(json.dumps(bad_gate, indent=2, sort_keys=True), encoding="utf-8")
(output_path / "bad-target-production-gate.json").write_text(json.dumps(bad_target_gate, indent=2, sort_keys=True), encoding="utf-8")
(output_path / "bad-public-target-production-gate.json").write_text(json.dumps(bad_public_target_gate, indent=2, sort_keys=True), encoding="utf-8")
(output_path / "production-profile-run.json").write_text(json.dumps(run, indent=2, sort_keys=True), encoding="utf-8")
(output_path / "bad-production-profile-run.json").write_text(json.dumps(bad_run, indent=2, sort_keys=True), encoding="utf-8")
(output_path / "bad-entrypoint-disabled-production-profile-run.json").write_text(json.dumps(bad_entrypoint_disabled_run, indent=2, sort_keys=True), encoding="utf-8")
(output_path / "failed-entrypoint-production-profile-run.json").write_text(json.dumps(failed_entrypoint_run, indent=2, sort_keys=True), encoding="utf-8")
(output_path / "production-profile-entrypoint-probe.log").write_text("diagnosis=ok\n", encoding="utf-8")
(output_path / "production-profile-entrypoint-probe.json").write_text(json.dumps({"schemaVersion": 1, "diagnosis": "ok", "failed": False, "baseURL": "https://chat.myim-prod.com"}, indent=2, sort_keys=True), encoding="utf-8")
(output_path / "bad-production-profile-entrypoint-probe.json").write_text(json.dumps({
    "schemaVersion": 1,
    "diagnosis": "uniform_empty_403",
    "failed": True,
    "detail": "Every probe returned empty 403.",
    "blocker": {
        "type": "entrypoint",
        "severity": "P0",
        "preventsPerformanceEvidence": True,
        "action": "repair_entrypoint",
        "reason": "Every probe returned empty 403.",
    },
}, indent=2, sort_keys=True), encoding="utf-8")
(output_path / "production-profile-plan.json").write_text(json.dumps({"profile": "minimum-smoke", "profileScenarioCount": len(scenarios), "batchCount": 1}, indent=2, sort_keys=True), encoding="utf-8")
(output_path / "production-profile-runbook.json").write_text(json.dumps(runbook, indent=2, sort_keys=True), encoding="utf-8")
(output_path / "bad-production-profile-runbook.json").write_text(json.dumps(bad_runbook, indent=2, sort_keys=True), encoding="utf-8")
(output_path / "bad-command-production-profile-runbook.json").write_text(json.dumps(bad_command_runbook, indent=2, sort_keys=True), encoding="utf-8")
(output_path / "bad-profile-command-production-profile-runbook.json").write_text(json.dumps(bad_profile_command_runbook, indent=2, sort_keys=True), encoding="utf-8")
(output_path / "bad-status-filter-production-profile-runbook.json").write_text(json.dumps(bad_status_filter_runbook, indent=2, sort_keys=True), encoding="utf-8")
(output_path / "bad-evidence-policy-production-profile-runbook.json").write_text(json.dumps(bad_evidence_policy_runbook, indent=2, sort_keys=True), encoding="utf-8")
(output_path / "bad-public-target-production-profile-runbook.json").write_text(json.dumps(bad_public_target_runbook, indent=2, sort_keys=True), encoding="utf-8")
(output_path / "production-profile-prereq-plan.json").write_text(json.dumps({"status": "READY", "profile": "minimum-smoke", "selectedScenarios": ["login-smoke"]}, indent=2, sort_keys=True), encoding="utf-8")
(output_path / "production-profile-prereq-audit.json").write_text(json.dumps({"summary": {"overallStatus": "READY"}, "scenarios": [{"scenario": "login-smoke", "status": "READY"}]}, indent=2, sort_keys=True), encoding="utf-8")
(output_path / "production-profile-scenario-catalog.json").write_text(json.dumps({"summary": {"scenarioCount": 1}, "scenarios": [{"scenario": "login-smoke"}]}, indent=2, sort_keys=True), encoding="utf-8")
PY
python3 "${SCRIPT_DIR}/perf_profile_artifacts_verify.py" \
  --gate-json "${profile_artifact_test_dir}/production-gate.json" \
  --profile-run-json "${profile_artifact_test_dir}/production-profile-run.json" \
  --profile-plan-json "${profile_artifact_test_dir}/production-profile-plan.json" \
  --profile-runbook-json "${profile_artifact_test_dir}/production-profile-runbook.json" \
  --prereq-plan-json "${profile_artifact_test_dir}/production-profile-prereq-plan.json" \
  --prereq-audit-json "${profile_artifact_test_dir}/production-profile-prereq-audit.json" \
  --scenario-catalog-json "${profile_artifact_test_dir}/production-profile-scenario-catalog.json" \
  --expected-package-path "${profile_artifact_test_dir}/evidence.tar.gz" \
  >"${profile_artifact_test_dir}/pass.log"
if python3 "${SCRIPT_DIR}/perf_profile_artifacts_verify.py" \
  --gate-json "${profile_artifact_test_dir}/production-gate.json" \
  --profile-run-json "${profile_artifact_test_dir}/bad-production-profile-run.json" \
  --profile-plan-json "${profile_artifact_test_dir}/production-profile-plan.json" \
  --profile-runbook-json "${profile_artifact_test_dir}/production-profile-runbook.json" \
  --prereq-plan-json "${profile_artifact_test_dir}/production-profile-prereq-plan.json" \
  --prereq-audit-json "${profile_artifact_test_dir}/production-profile-prereq-audit.json" \
  --scenario-catalog-json "${profile_artifact_test_dir}/production-profile-scenario-catalog.json" \
  --expected-package-path "${profile_artifact_test_dir}/evidence.tar.gz" \
  >"${profile_artifact_test_dir}/bad.log" 2>&1; then
  echo "profile artifact verifier failed: bad package path unexpectedly passed" >&2
  exit 1
fi
grep -q 'reason=profile_run_package_path_mismatch' "${profile_artifact_test_dir}/bad.log" || {
  echo "profile artifact verifier failed: bad package path reason missing" >&2
  exit 1
}
if python3 "${SCRIPT_DIR}/perf_profile_artifacts_verify.py" \
  --gate-json "${profile_artifact_test_dir}/production-gate.json" \
  --profile-run-json "${profile_artifact_test_dir}/bad-entrypoint-disabled-production-profile-run.json" \
  --profile-plan-json "${profile_artifact_test_dir}/production-profile-plan.json" \
  --profile-runbook-json "${profile_artifact_test_dir}/production-profile-runbook.json" \
  --prereq-plan-json "${profile_artifact_test_dir}/production-profile-prereq-plan.json" \
  --prereq-audit-json "${profile_artifact_test_dir}/production-profile-prereq-audit.json" \
  --scenario-catalog-json "${profile_artifact_test_dir}/production-profile-scenario-catalog.json" \
  --expected-package-path "${profile_artifact_test_dir}/evidence.tar.gz" \
  >"${profile_artifact_test_dir}/bad-entrypoint-disabled.log" 2>&1; then
  echo "profile artifact verifier failed: disabled entrypoint probe unexpectedly passed" >&2
  exit 1
fi
grep -q 'reason=profile_entrypoint_probe_disabled' "${profile_artifact_test_dir}/bad-entrypoint-disabled.log" || {
  echo "profile artifact verifier failed: disabled entrypoint probe reason missing" >&2
  exit 1
}
mv "${profile_artifact_test_dir}/production-profile-entrypoint-probe.json" "${profile_artifact_test_dir}/good-production-profile-entrypoint-probe.json"
cp "${profile_artifact_test_dir}/bad-production-profile-entrypoint-probe.json" "${profile_artifact_test_dir}/production-profile-entrypoint-probe.json"
if python3 "${SCRIPT_DIR}/perf_profile_artifacts_verify.py" \
  --gate-json "${profile_artifact_test_dir}/production-gate.json" \
  --profile-run-json "${profile_artifact_test_dir}/production-profile-run.json" \
  --profile-plan-json "${profile_artifact_test_dir}/production-profile-plan.json" \
  --profile-runbook-json "${profile_artifact_test_dir}/production-profile-runbook.json" \
  --prereq-plan-json "${profile_artifact_test_dir}/production-profile-prereq-plan.json" \
  --prereq-audit-json "${profile_artifact_test_dir}/production-profile-prereq-audit.json" \
  --scenario-catalog-json "${profile_artifact_test_dir}/production-profile-scenario-catalog.json" \
  --expected-package-path "${profile_artifact_test_dir}/evidence.tar.gz" \
  >"${profile_artifact_test_dir}/bad-entrypoint-probe.log" 2>&1; then
  echo "profile artifact verifier failed: failed entrypoint probe unexpectedly passed" >&2
  exit 1
fi
grep -q 'reason=profile_entrypoint_probe_failed' "${profile_artifact_test_dir}/bad-entrypoint-probe.log" || {
  echo "profile artifact verifier failed: failed entrypoint probe reason missing" >&2
  exit 1
}
python3 "${SCRIPT_DIR}/perf_production_profile_runbook.py" \
  --plan "${profile_artifact_test_dir}/production-profile-plan.json" \
  --prereq-audit "${profile_artifact_test_dir}/production-profile-prereq-audit.json" \
  --profile-run "${profile_artifact_test_dir}/failed-entrypoint-production-profile-run.json" \
  --profile minimum-smoke \
  --result-root "${profile_artifact_test_dir}" \
  --base-url http://127.0.0.1:8080 \
  --tcp-host 127.0.0.1 \
  --tcp-port 9000 \
  --output "${profile_artifact_test_dir}/failed-entrypoint-production-profile-runbook.md" \
  --json-output "${profile_artifact_test_dir}/failed-entrypoint-production-profile-runbook.json" >/dev/null
python3 "${SCRIPT_DIR}/perf_production_profile_runbook.py" \
  --verify-json "${profile_artifact_test_dir}/failed-entrypoint-production-profile-runbook.json" \
  --verify-md "${profile_artifact_test_dir}/failed-entrypoint-production-profile-runbook.md" >/dev/null
cp "${profile_artifact_test_dir}/failed-entrypoint-production-profile-runbook.md" "${profile_artifact_test_dir}/failed-entrypoint-production-profile-runbook-bad.md"
perl -0pi -e 's/- status: `BLOCKED`/- runbookStatus: `BLOCKED`/' "${profile_artifact_test_dir}/failed-entrypoint-production-profile-runbook-bad.md"
if python3 "${SCRIPT_DIR}/perf_production_profile_runbook.py" \
  --verify-json "${profile_artifact_test_dir}/failed-entrypoint-production-profile-runbook.json" \
  --verify-md "${profile_artifact_test_dir}/failed-entrypoint-production-profile-runbook-bad.md" \
  >"${profile_artifact_test_dir}/bad-runbook-md.log" 2>&1; then
  echo "profile artifact verifier failed: mismatched runbook markdown unexpectedly passed" >&2
  exit 1
fi
grep -q 'markdown_mismatch' "${profile_artifact_test_dir}/bad-runbook-md.log" || {
  echo "profile artifact verifier failed: mismatched runbook markdown reason missing" >&2
  exit 1
}
python3 - "${profile_artifact_test_dir}/failed-entrypoint-production-profile-runbook.json" "${profile_artifact_test_dir}/failed-entrypoint-production-profile-runbook.md" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
markdown = Path(sys.argv[2]).read_text(encoding="utf-8")
if payload.get("status") != "BLOCKED":
    raise SystemExit("profile artifact verifier failed: entrypoint failed runbook not blocked")
entrypoint = payload.get("entrypoint") or {}
blocker = entrypoint.get("blocker") or {}
if entrypoint.get("diagnosis") != "uniform_empty_403":
    raise SystemExit("profile artifact verifier failed: entrypoint failed runbook diagnosis missing")
if blocker.get("type") != "entrypoint" or blocker.get("severity") != "P0":
    raise SystemExit(f"profile artifact verifier failed: entrypoint failed runbook blocker invalid blocker={blocker}")
if blocker.get("preventsPerformanceEvidence") is not True:
    raise SystemExit("profile artifact verifier failed: entrypoint failed runbook blocker not preventing performance")
if "entrypoint/P0" not in markdown or "preventsPerformanceEvidence=`True`" not in markdown:
    raise SystemExit("profile artifact verifier failed: entrypoint failed runbook markdown blocker missing")
PY
mv "${profile_artifact_test_dir}/good-production-profile-entrypoint-probe.json" "${profile_artifact_test_dir}/production-profile-entrypoint-probe.json"
if python3 "${SCRIPT_DIR}/perf_profile_artifacts_verify.py" \
  --gate-json "${profile_artifact_test_dir}/bad-target-filter-production-gate.json" \
  --profile-run-json "${profile_artifact_test_dir}/production-profile-run.json" \
  --profile-plan-json "${profile_artifact_test_dir}/production-profile-plan.json" \
  --profile-runbook-json "${profile_artifact_test_dir}/production-profile-runbook.json" \
  --prereq-plan-json "${profile_artifact_test_dir}/production-profile-prereq-plan.json" \
  --prereq-audit-json "${profile_artifact_test_dir}/production-profile-prereq-audit.json" \
  --scenario-catalog-json "${profile_artifact_test_dir}/production-profile-scenario-catalog.json" \
  --expected-package-path "${profile_artifact_test_dir}/evidence.tar.gz" \
  >"${profile_artifact_test_dir}/bad-target-filter-gate.log" 2>&1; then
  echo "profile artifact verifier failed: target-filter-disabled gate unexpectedly passed" >&2
  exit 1
fi
grep -q 'reason=production_gate_target_filter_disabled' "${profile_artifact_test_dir}/bad-target-filter-gate.log" || {
  echo "profile artifact verifier failed: target-filter-disabled gate reason missing" >&2
  exit 1
}
if python3 "${SCRIPT_DIR}/perf_profile_artifacts_verify.py" \
  --gate-json "${profile_artifact_test_dir}/bad-target-production-gate.json" \
  --profile-run-json "${profile_artifact_test_dir}/production-profile-run.json" \
  --profile-plan-json "${profile_artifact_test_dir}/production-profile-plan.json" \
  --profile-runbook-json "${profile_artifact_test_dir}/production-profile-runbook.json" \
  --prereq-plan-json "${profile_artifact_test_dir}/production-profile-prereq-plan.json" \
  --prereq-audit-json "${profile_artifact_test_dir}/production-profile-prereq-audit.json" \
  --scenario-catalog-json "${profile_artifact_test_dir}/production-profile-scenario-catalog.json" \
  --expected-package-path "${profile_artifact_test_dir}/evidence.tar.gz" \
  >"${profile_artifact_test_dir}/bad-target-gate.log" 2>&1; then
  echo "profile artifact verifier failed: mismatched target gate unexpectedly passed" >&2
  exit 1
fi
grep -q 'reason=production_gate_target_mismatch' "${profile_artifact_test_dir}/bad-target-gate.log" || {
  echo "profile artifact verifier failed: mismatched target gate reason missing" >&2
  exit 1
}
if python3 "${SCRIPT_DIR}/perf_profile_artifacts_verify.py" \
  --gate-json "${profile_artifact_test_dir}/bad-public-target-production-gate.json" \
  --profile-run-json "${profile_artifact_test_dir}/production-profile-run.json" \
  --profile-plan-json "${profile_artifact_test_dir}/production-profile-plan.json" \
  --profile-runbook-json "${profile_artifact_test_dir}/bad-public-target-production-profile-runbook.json" \
  --prereq-plan-json "${profile_artifact_test_dir}/production-profile-prereq-plan.json" \
  --prereq-audit-json "${profile_artifact_test_dir}/production-profile-prereq-audit.json" \
  --scenario-catalog-json "${profile_artifact_test_dir}/production-profile-scenario-catalog.json" \
  --expected-package-path "${profile_artifact_test_dir}/evidence.tar.gz" \
  >"${profile_artifact_test_dir}/bad-public-target-gate.log" 2>&1; then
  echo "profile artifact verifier failed: bad public target gate unexpectedly passed" >&2
  exit 1
fi
grep -q 'reason=production_gate_target_base_url_https_required' "${profile_artifact_test_dir}/bad-public-target-gate.log" || {
  echo "profile artifact verifier failed: bad public target reason missing" >&2
  exit 1
}
if python3 "${SCRIPT_DIR}/perf_profile_artifacts_verify.py" \
  --gate-json "${profile_artifact_test_dir}/production-gate.json" \
  --profile-run-json "${profile_artifact_test_dir}/production-profile-run.json" \
  --profile-plan-json "${profile_artifact_test_dir}/production-profile-plan.json" \
  --profile-runbook-json "${profile_artifact_test_dir}/bad-production-profile-runbook.json" \
  --prereq-plan-json "${profile_artifact_test_dir}/production-profile-prereq-plan.json" \
  --prereq-audit-json "${profile_artifact_test_dir}/production-profile-prereq-audit.json" \
  --scenario-catalog-json "${profile_artifact_test_dir}/production-profile-scenario-catalog.json" \
  --expected-package-path "${profile_artifact_test_dir}/evidence.tar.gz" \
  >"${profile_artifact_test_dir}/bad-runbook.log" 2>&1; then
  echo "profile artifact verifier failed: bad runbook unexpectedly passed" >&2
  exit 1
fi
grep -Eq 'reason=(profile_runbook_selection_mismatch|profile_runbook_batch_selection_mismatch|profile_runbook_batch_scenarios_mismatch)' "${profile_artifact_test_dir}/bad-runbook.log" || {
  echo "profile artifact verifier failed: bad runbook reason missing" >&2
  exit 1
}
if python3 "${SCRIPT_DIR}/perf_profile_artifacts_verify.py" \
  --gate-json "${profile_artifact_test_dir}/production-gate.json" \
  --profile-run-json "${profile_artifact_test_dir}/production-profile-run.json" \
  --profile-plan-json "${profile_artifact_test_dir}/production-profile-plan.json" \
  --profile-runbook-json "${profile_artifact_test_dir}/bad-command-production-profile-runbook.json" \
  --prereq-plan-json "${profile_artifact_test_dir}/production-profile-prereq-plan.json" \
  --prereq-audit-json "${profile_artifact_test_dir}/production-profile-prereq-audit.json" \
  --scenario-catalog-json "${profile_artifact_test_dir}/production-profile-scenario-catalog.json" \
  --expected-package-path "${profile_artifact_test_dir}/evidence.tar.gz" \
  >"${profile_artifact_test_dir}/bad-command-runbook.log" 2>&1; then
  echo "profile artifact verifier failed: bad runbook command unexpectedly passed" >&2
  exit 1
fi
grep -q 'reason=profile_runbook_batch_command_scenarios_mismatch' "${profile_artifact_test_dir}/bad-command-runbook.log" || {
  echo "profile artifact verifier failed: bad runbook command reason missing" >&2
  exit 1
}
if python3 "${SCRIPT_DIR}/perf_profile_artifacts_verify.py" \
  --gate-json "${profile_artifact_test_dir}/production-gate.json" \
  --profile-run-json "${profile_artifact_test_dir}/production-profile-run.json" \
  --profile-plan-json "${profile_artifact_test_dir}/production-profile-plan.json" \
  --profile-runbook-json "${profile_artifact_test_dir}/bad-profile-command-production-profile-runbook.json" \
  --prereq-plan-json "${profile_artifact_test_dir}/production-profile-prereq-plan.json" \
  --prereq-audit-json "${profile_artifact_test_dir}/production-profile-prereq-audit.json" \
  --scenario-catalog-json "${profile_artifact_test_dir}/production-profile-scenario-catalog.json" \
  --expected-package-path "${profile_artifact_test_dir}/evidence.tar.gz" \
  >"${profile_artifact_test_dir}/bad-profile-command-runbook.log" 2>&1; then
  echo "profile artifact verifier failed: bad runbook profile command unexpectedly passed" >&2
  exit 1
fi
grep -q 'reason=profile_runbook_batch_command_profile_mismatch' "${profile_artifact_test_dir}/bad-profile-command-runbook.log" || {
  echo "profile artifact verifier failed: bad runbook profile command reason missing" >&2
  exit 1
}
if python3 "${SCRIPT_DIR}/perf_profile_artifacts_verify.py" \
  --gate-json "${profile_artifact_test_dir}/production-gate.json" \
  --profile-run-json "${profile_artifact_test_dir}/production-profile-run.json" \
  --profile-plan-json "${profile_artifact_test_dir}/production-profile-plan.json" \
  --profile-runbook-json "${profile_artifact_test_dir}/bad-status-filter-production-profile-runbook.json" \
  --prereq-plan-json "${profile_artifact_test_dir}/production-profile-prereq-plan.json" \
  --prereq-audit-json "${profile_artifact_test_dir}/production-profile-prereq-audit.json" \
  --scenario-catalog-json "${profile_artifact_test_dir}/production-profile-scenario-catalog.json" \
  --expected-package-path "${profile_artifact_test_dir}/evidence.tar.gz" \
  >"${profile_artifact_test_dir}/bad-status-filter-runbook.log" 2>&1; then
  echo "profile artifact verifier failed: bad runbook status filter unexpectedly passed" >&2
  exit 1
fi
grep -q 'reason=profile_runbook_batch_command_status_filter_disabled' "${profile_artifact_test_dir}/bad-status-filter-runbook.log" || {
  echo "profile artifact verifier failed: bad runbook status filter reason missing" >&2
  exit 1
}
if python3 "${SCRIPT_DIR}/perf_profile_artifacts_verify.py" \
  --gate-json "${profile_artifact_test_dir}/production-gate.json" \
  --profile-run-json "${profile_artifact_test_dir}/production-profile-run.json" \
  --profile-plan-json "${profile_artifact_test_dir}/production-profile-plan.json" \
  --profile-runbook-json "${profile_artifact_test_dir}/bad-evidence-policy-production-profile-runbook.json" \
  --prereq-plan-json "${profile_artifact_test_dir}/production-profile-prereq-plan.json" \
  --prereq-audit-json "${profile_artifact_test_dir}/production-profile-prereq-audit.json" \
  --scenario-catalog-json "${profile_artifact_test_dir}/production-profile-scenario-catalog.json" \
  --expected-package-path "${profile_artifact_test_dir}/evidence.tar.gz" \
  >"${profile_artifact_test_dir}/bad-evidence-policy-runbook.log" 2>&1; then
  echo "profile artifact verifier failed: bad runbook evidence policy unexpectedly passed" >&2
  exit 1
fi
grep -q 'reason=profile_runbook_evidence_policy_current_readiness_invalid' "${profile_artifact_test_dir}/bad-evidence-policy-runbook.log" || {
  echo "profile artifact verifier failed: bad runbook evidence policy reason missing" >&2
  exit 1
}

log "production profile runner self-test"
PRODUCTION_PROFILE_SELF_TEST=true \
  "${SCRIPT_DIR}/run_production_profile.sh" \
  >"${RESULT_DIR}/production-profile-runner-self-test.log"
if RESULT_ROOT="${RESULT_DIR}/production-profile-invalid-max-age" \
  PERF_DRY_RUN=true \
  PRODUCTION_PROFILE_ENTRYPOINT_PROBE=false \
  PRODUCTION_PROFILE_PREREQ_GATE=false \
  PRODUCTION_PROFILE_PACKAGE=false \
  PERF_PRODUCTION_GATE_PROFILE=minimum-smoke \
  PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=-1 \
    "${SCRIPT_DIR}/run_production_profile.sh" \
    >"${RESULT_DIR}/production-profile-invalid-max-age.log" 2>&1; then
  echo "production profile runner failed: negative max age unexpectedly passed" >&2
  exit 1
fi
grep -q 'reason=invalid_max_age' "${RESULT_DIR}/production-profile-invalid-max-age.log" || {
  echo "production profile runner failed: negative max age reason missing" >&2
  exit 1
}

log "product test plan runner self-test"
PRODUCT_TEST_SELF_TEST=true \
  bash "${SCRIPT_DIR}/run_product_test_plan.sh" \
  >"${RESULT_DIR}/product-test-plan-runner-self-test.log"

log "production env seed guard self-test"
prod_env_test_dir="${RESULT_DIR}/production-env-seed-guard"
rm -rf "${prod_env_test_dir}"
mkdir -p "${prod_env_test_dir}/roles"
cat >"${prod_env_test_dir}/common.env" <<'EOF'
APP_ENV=production
PUBLIC_BASE_URL=https://chat.myim-prod.com
JWT_SECRETS=active:0123456789abcdef0123456789abcdef
JWT_ACTIVE_KID=active
IM_INTERNAL_SHARED_SECRET=fedcba9876543210fedcba9876543210
DATABASE_PRIMARY_HOST=127.0.0.1
DATABASE_PRIMARY_NAME=imserver
DATABASE_PRIMARY_USERNAME=imserver
DATABASE_PRIMARY_PASSWORD=db-0123456789abcdef
IM_CONVERSATION_SHARD_IDS=shard-0
DATABASE_CONVERSATION_SHARD_0_HOST=127.0.0.1
DATABASE_CONVERSATION_SHARD_0_PORT=5432
DATABASE_CONVERSATION_SHARD_0_NAME=imserver
DATABASE_CONVERSATION_SHARD_0_USERNAME=imserver
DATABASE_CONVERSATION_SHARD_0_PASSWORD=db-0123456789abcdef
IM_SUMMARY_SHARD_IDS=summary-a
DATABASE_SUMMARY_SUMMARY_A_HOST=127.0.0.1
DATABASE_SUMMARY_SUMMARY_A_PORT=5432
DATABASE_SUMMARY_SUMMARY_A_NAME=imserver
DATABASE_SUMMARY_SUMMARY_A_USERNAME=imserver
DATABASE_SUMMARY_SUMMARY_A_PASSWORD=db-0123456789abcdef
IM_EVENT_STREAM_DRIVER=kafka
IM_KAFKA_BROKERS=127.0.0.1:9092
IM_KAFKA_TOPIC=conversation-domain-events
IM_KAFKA_DEAD_LETTER_TOPIC=conversation-domain-events-dead-letter
IM_KAFKA_CLIENT_ID=im-load-test-production-env-guard
IM_KAFKA_REQUIRED_ACKS=all
IM_KAFKA_AUTO_CREATE_TOPICS=false
IM_KAFKA_SECURITY_PROTOCOL=sasl_tls
IM_KAFKA_SASL_MECHANISM=scram-sha-512
IM_KAFKA_SASL_USERNAME=imserver
IM_KAFKA_SASL_PASSWORD=kafka-0123456789abcdef
IM_KAFKA_TLS_CA_FILE=/run/secrets/kafka-ca.pem
MEDIA_STORAGE_PROVIDER=s3compatible
MEDIA_STORAGE_S3_ENDPOINT=https://oss.myim-prod.com
MEDIA_STORAGE_S3_BUCKET=im-media
MEDIA_STORAGE_S3_ACCESS_KEY_ID=AKIA0123456789ABCDEF
MEDIA_STORAGE_S3_SECRET_ACCESS_KEY=s3-0123456789abcdef0123456789abcdef
MEDIA_STORAGE_S3_REGION=cn-shenzhen
MEDIA_STORAGE_S3_FORCE_PATH_STYLE=true
IM_COMMAND_API_INTERNAL_BASE_URL=http://127.0.0.1:8081
IM_GATEWAY_INTERNAL_BASE_URL=http://127.0.0.1:18080
IM_TCP_DROP_REALTIME_WHEN_NOT_WRITABLE=true
IM_TCP_REQUIRES_TLS_TERMINATION=true
EOF
ENV_FILE="${prod_env_test_dir}/common.env" \
ROLES_DIR="${prod_env_test_dir}/roles" \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/55_verify_production_env.sh" \
  >"${prod_env_test_dir}/pass.log"
cp "${prod_env_test_dir}/common.env" "${prod_env_test_dir}/missing-public-url.env"
sed -i.bak -e '/^PUBLIC_BASE_URL=/d' -e '/^IM_PUBLIC_BASE_URL=/d' "${prod_env_test_dir}/missing-public-url.env"
if ENV_FILE="${prod_env_test_dir}/missing-public-url.env" \
  ROLES_DIR="${prod_env_test_dir}/roles" \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/55_verify_production_env.sh" \
  >"${prod_env_test_dir}/missing-public-url.log" 2>&1; then
  echo "production env public URL guard failed: missing public URL unexpectedly passed" >&2
  exit 1
fi
grep -q 'key=PUBLIC_BASE_URL reason=missing_or_empty' "${prod_env_test_dir}/missing-public-url.log" || {
  echo "production env public URL guard failed: missing public URL reason absent" >&2
  exit 1
}
cp "${prod_env_test_dir}/common.env" "${prod_env_test_dir}/http-public-url.env"
sed -i.bak -e 's#^PUBLIC_BASE_URL=.*#PUBLIC_BASE_URL=http://chat.myim-prod.com#' "${prod_env_test_dir}/http-public-url.env"
if ENV_FILE="${prod_env_test_dir}/http-public-url.env" \
  ROLES_DIR="${prod_env_test_dir}/roles" \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/55_verify_production_env.sh" \
  >"${prod_env_test_dir}/http-public-url.log" 2>&1; then
  echo "production env public URL guard failed: insecure public URL unexpectedly passed" >&2
  exit 1
fi
grep -q 'key=PUBLIC_BASE_URL reason=https_required' "${prod_env_test_dir}/http-public-url.log" || {
  echo "production env public URL guard failed: insecure public URL reason absent" >&2
  exit 1
}
cp "${prod_env_test_dir}/common.env" "${prod_env_test_dir}/placeholder-public-url.env"
sed -i.bak -e 's#^PUBLIC_BASE_URL=.*#PUBLIC_BASE_URL=https://chat.yourdomain.com#' "${prod_env_test_dir}/placeholder-public-url.env"
if ENV_FILE="${prod_env_test_dir}/placeholder-public-url.env" \
  ROLES_DIR="${prod_env_test_dir}/roles" \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/55_verify_production_env.sh" \
  >"${prod_env_test_dir}/placeholder-public-url.log" 2>&1; then
  echo "production env public URL guard failed: placeholder public URL unexpectedly passed" >&2
  exit 1
fi
grep -q 'key=PUBLIC_BASE_URL reason=placeholder_domain' "${prod_env_test_dir}/placeholder-public-url.log" || {
  echo "production env public URL guard failed: placeholder public URL reason absent" >&2
  exit 1
}
ENV_FILE="${prod_env_test_dir}/http-public-url.env" \
ROLES_DIR="${prod_env_test_dir}/roles" \
IM_PRODUCTION_ALLOW_INSECURE_PUBLIC_BASE_URL=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/55_verify_production_env.sh" \
  >"${prod_env_test_dir}/http-public-url-override.log" 2>&1 && {
  echo "production env public URL guard failed: insecure public URL override unexpectedly passed" >&2
  exit 1
}
grep -q 'key=IM_PRODUCTION_ALLOW_INSECURE_PUBLIC_BASE_URL reason=forbidden_for_long_term_production' "${prod_env_test_dir}/http-public-url-override.log" || {
  echo "production env public URL guard failed: insecure public URL override reason absent" >&2
  exit 1
}
cp "${prod_env_test_dir}/common.env" "${prod_env_test_dir}/local-public-url.env"
sed -i.bak -e 's#^PUBLIC_BASE_URL=.*#PUBLIC_BASE_URL=https://127.0.0.1#' "${prod_env_test_dir}/local-public-url.env"
if ENV_FILE="${prod_env_test_dir}/local-public-url.env" \
  ROLES_DIR="${prod_env_test_dir}/roles" \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/55_verify_production_env.sh" \
  >"${prod_env_test_dir}/local-public-url.log" 2>&1; then
  echo "production env public URL guard failed: local public URL unexpectedly passed" >&2
  exit 1
fi
grep -q 'key=PUBLIC_BASE_URL reason=host_must_be_dns' "${prod_env_test_dir}/local-public-url.log" || {
  echo "production env public URL guard failed: local public URL reason absent" >&2
  exit 1
}
cp "${prod_env_test_dir}/common.env" "${prod_env_test_dir}/jwt-rotation.env"
sed -i.bak -e '/^JWT_SECRETS=/d' -e '/^JWT_ACTIVE_KID=/d' "${prod_env_test_dir}/jwt-rotation.env"
cat >>"${prod_env_test_dir}/jwt-rotation.env" <<'EOF'
JWT_SECRETS=old:old-0123456789abcdef0123456789abcdef,active:active-0123456789abcdef0123456789abcd
JWT_ACTIVE_KID=active
EOF
ENV_FILE="${prod_env_test_dir}/jwt-rotation.env" \
ROLES_DIR="${prod_env_test_dir}/roles" \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/55_verify_production_env.sh" \
  >"${prod_env_test_dir}/jwt-rotation.log"
cp "${prod_env_test_dir}/common.env" "${prod_env_test_dir}/jwt-legacy-secret.env"
printf 'JWT_SECRET=0123456789abcdef0123456789abcdef\n' >>"${prod_env_test_dir}/jwt-legacy-secret.env"
if ENV_FILE="${prod_env_test_dir}/jwt-legacy-secret.env" \
  ROLES_DIR="${prod_env_test_dir}/roles" \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/55_verify_production_env.sh" \
  >"${prod_env_test_dir}/jwt-legacy-secret.log" 2>&1; then
  echo "production env JWT rotation guard failed: legacy JWT_SECRET unexpectedly passed" >&2
  exit 1
fi
grep -q 'key=JWT_SECRET reason=legacy_single_secret_forbidden_for_long_term_production' "${prod_env_test_dir}/jwt-legacy-secret.log" || {
  echo "production env JWT rotation guard failed: legacy JWT_SECRET reason absent" >&2
  exit 1
}
cp "${prod_env_test_dir}/common.env" "${prod_env_test_dir}/jwt-rotation-weak.env"
sed -i.bak -e '/^JWT_SECRETS=/d' -e '/^JWT_ACTIVE_KID=/d' "${prod_env_test_dir}/jwt-rotation-weak.env"
cat >>"${prod_env_test_dir}/jwt-rotation-weak.env" <<'EOF'
JWT_SECRETS=old:short,active:active-0123456789abcdef0123456789abcd
JWT_ACTIVE_KID=active
EOF
if ENV_FILE="${prod_env_test_dir}/jwt-rotation-weak.env" \
  ROLES_DIR="${prod_env_test_dir}/roles" \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/55_verify_production_env.sh" \
  >"${prod_env_test_dir}/jwt-rotation-weak.log" 2>&1; then
  echo "production env JWT rotation guard failed: weak JWT_SECRETS unexpectedly passed" >&2
  exit 1
fi
cp "${prod_env_test_dir}/common.env" "${prod_env_test_dir}/jwt-active-missing.env"
sed -i.bak -e '/^JWT_SECRETS=/d' -e '/^JWT_ACTIVE_KID=/d' "${prod_env_test_dir}/jwt-active-missing.env"
cat >>"${prod_env_test_dir}/jwt-active-missing.env" <<'EOF'
JWT_SECRETS=old:old-0123456789abcdef0123456789abcdef,active:active-0123456789abcdef0123456789abcd
JWT_ACTIVE_KID=missing
EOF
if ENV_FILE="${prod_env_test_dir}/jwt-active-missing.env" \
  ROLES_DIR="${prod_env_test_dir}/roles" \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/55_verify_production_env.sh" \
  >"${prod_env_test_dir}/jwt-active-missing.log" 2>&1; then
  echo "production env JWT rotation guard failed: missing active kid unexpectedly passed" >&2
  exit 1
fi
cp "${prod_env_test_dir}/common.env" "${prod_env_test_dir}/seeded.env"
printf 'SEED_USER_PASSWORD=password1234\n' >>"${prod_env_test_dir}/seeded.env"
if ENV_FILE="${prod_env_test_dir}/seeded.env" \
  ROLES_DIR="${prod_env_test_dir}/roles" \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/55_verify_production_env.sh" \
  >"${prod_env_test_dir}/seeded.log" 2>&1; then
  echo "production env seed guard failed: seeded production env unexpectedly passed" >&2
  exit 1
fi
cp "${prod_env_test_dir}/common.env" "${prod_env_test_dir}/weak-secrets.env"
sed -i.bak \
  -e 's/^JWT_SECRETS=.*/JWT_SECRETS=active:password1234/' \
  -e 's/^IM_INTERNAL_SHARED_SECRET=.*/IM_INTERNAL_SHARED_SECRET=change_me/' \
  -e 's/^DATABASE_PRIMARY_PASSWORD=.*/DATABASE_PRIMARY_PASSWORD=prod-db-password/' \
  -e 's/^IM_KAFKA_SASL_PASSWORD=.*/IM_KAFKA_SASL_PASSWORD=prod-kafka-password/' \
  -e 's/^MEDIA_STORAGE_S3_SECRET_ACCESS_KEY=.*/MEDIA_STORAGE_S3_SECRET_ACCESS_KEY=replace-me/' \
  "${prod_env_test_dir}/weak-secrets.env"
if ENV_FILE="${prod_env_test_dir}/weak-secrets.env" \
  ROLES_DIR="${prod_env_test_dir}/roles" \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/55_verify_production_env.sh" \
  >"${prod_env_test_dir}/weak-secrets.log" 2>&1; then
  echo "production env secret guard failed: weak production secrets unexpectedly passed" >&2
  exit 1
fi
cp "${prod_env_test_dir}/common.env" "${prod_env_test_dir}/weak-shard-secrets.env"
sed -i.bak \
  -e 's/^DATABASE_CONVERSATION_SHARD_0_PASSWORD=.*/DATABASE_CONVERSATION_SHARD_0_PASSWORD=prod-db-password/' \
  -e 's/^DATABASE_SUMMARY_SUMMARY_A_PASSWORD=.*/DATABASE_SUMMARY_SUMMARY_A_PASSWORD=replace-me/' \
  "${prod_env_test_dir}/weak-shard-secrets.env"
if ENV_FILE="${prod_env_test_dir}/weak-shard-secrets.env" \
  ROLES_DIR="${prod_env_test_dir}/roles" \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/55_verify_production_env.sh" \
  >"${prod_env_test_dir}/weak-shard-secrets.log" 2>&1; then
  echo "production env shard secret guard failed: weak shard secrets unexpectedly passed" >&2
  exit 1
fi
cp "${prod_env_test_dir}/common.env" "${prod_env_test_dir}/public-internal-url.env"
sed -i.bak \
  -e 's#^IM_COMMAND_API_INTERNAL_BASE_URL=.*#IM_COMMAND_API_INTERNAL_BASE_URL=https://api.example.com#' \
  -e 's#^IM_GATEWAY_INTERNAL_BASE_URL=.*#IM_GATEWAY_INTERNAL_BASE_URL=http://8.8.8.8:18080#' \
  "${prod_env_test_dir}/public-internal-url.env"
if ENV_FILE="${prod_env_test_dir}/public-internal-url.env" \
  ROLES_DIR="${prod_env_test_dir}/roles" \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/55_verify_production_env.sh" \
  >"${prod_env_test_dir}/public-internal-url.log" 2>&1; then
  echo "production env internal URL guard failed: public internal URLs unexpectedly passed" >&2
  exit 1
fi

log "performance gate deploy self-test"
perf_gate_test_dir="${RESULT_DIR}/deploy-performance-gate"
rm -rf "${perf_gate_test_dir}"
mkdir -p "${perf_gate_test_dir}"
if PERF_PRODUCTION_GATE_JSON="${perf_gate_test_dir}/missing.json" \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/67_verify_performance_gate.sh" \
  >"${perf_gate_test_dir}/missing.log" 2>&1; then
  echo "deploy performance gate failed: missing file unexpectedly passed" >&2
  exit 1
fi
cat >"${perf_gate_test_dir}/fail.json" <<'EOF'
{
  "status": "FAIL",
  "profile": "minimum-smoke",
  "summary": {
    "requiredScenarioCount": 1,
    "passedScenarioCount": 0,
    "failedScenarioCount": 1,
    "missingScenarioCount": 0
  }
}
EOF
if PERF_PRODUCTION_GATE_JSON="${perf_gate_test_dir}/fail.json" \
  PERF_PRODUCTION_GATE_PROFILE="minimum-smoke" \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/67_verify_performance_gate.sh" \
  >"${perf_gate_test_dir}/fail.log" 2>&1; then
  echo "deploy performance gate failed: FAIL status unexpectedly passed" >&2
  exit 1
fi
python3 - "${perf_gate_test_dir}/pass.json" "${SCRIPT_DIR}/perf_production_profiles.json" <<'PY'
import json
import hashlib
import subprocess
import sys
import time
from pathlib import Path

output_path, catalog_path = sys.argv[1:3]
now = int(time.time())
repo_root = Path(catalog_path).resolve().parents[2]
try:
    commit = subprocess.run(
        ["git", "rev-parse", "--verify", "HEAD"],
        cwd=repo_root,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    ).stdout.strip()
    branch = subprocess.run(
        ["git", "branch", "--show-current"],
        cwd=repo_root,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    ).stdout.strip()
    dirty = bool(subprocess.run(
        ["git", "status", "--porcelain"],
        cwd=repo_root,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    ).stdout.strip())
except Exception:
    commit = "validate-load-tests"
    branch = "validate-load-tests"
    dirty = False
with open(catalog_path, encoding="utf-8") as handle:
    scenarios = (json.load(handle).get("profiles") or {}).get("minimum-smoke") or []
with open(catalog_path, "rb") as handle:
    catalog_sha256 = hashlib.sha256(handle.read()).hexdigest()
payload = {
    "status": "PASS",
    "profile": "minimum-smoke",
    "profileCatalog": {
        "path": catalog_path,
        "schemaVersion": 1,
        "sha256": catalog_sha256,
    },
    "source": {
        "repoRoot": str(repo_root),
        "gitCommit": commit,
        "gitBranch": branch,
        "gitDirty": dirty,
    },
    "targetFilter": {
        "enabled": True,
        "baseURL": "https://chat.myim-prod.com",
        "tcpHost": "tcp.myim-prod.com",
        "tcpPort": "9000",
    },
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
            "latestRunID": "validate-load-tests",
            "latestRunDir": "/tmp/validate-load-tests",
            "latestMtime": now,
            "runArtifactsVerified": True,
            "runArtifactsOK": True,
            "passed": True,
            "reason": "",
        }
        for scenario in scenarios
    ],
}
with open(output_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
PERF_PRODUCTION_GATE_JSON="${perf_gate_test_dir}/pass.json" \
PERF_PRODUCTION_GATE_PROFILE="minimum-smoke" \
PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=0 \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/67_verify_performance_gate.sh" \
  >"${perf_gate_test_dir}/pass.log"
if PERF_PRODUCTION_GATE_JSON="${perf_gate_test_dir}/pass.json" \
  PERF_PRODUCTION_GATE_PROFILE="minimum-smoke" \
  PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=-1 \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/67_verify_performance_gate.sh" \
  >"${perf_gate_test_dir}/negative-max-age.log" 2>&1; then
  echo "deploy performance gate failed: negative max age unexpectedly passed" >&2
  exit 1
fi
grep -q 'reason=invalid_max_age' "${perf_gate_test_dir}/negative-max-age.log" || {
  echo "deploy performance gate failed: negative max age reason missing" >&2
  exit 1
}
PERF_PRODUCTION_GATE_JSON="${perf_gate_test_dir}/pass.json" \
PERF_PRODUCTION_GATE_PROFILE="minimum-smoke" \
PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=0 \
PERF_PRODUCTION_GATE_EXPECT_BASE_URL=https://chat.myim-prod.com \
PERF_PRODUCTION_GATE_EXPECT_TCP_HOST=tcp.myim-prod.com \
PERF_PRODUCTION_GATE_EXPECT_TCP_PORT=9000 \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/67_verify_performance_gate.sh" \
  >"${perf_gate_test_dir}/expected-target-pass.log"
if PERF_PRODUCTION_GATE_JSON="${perf_gate_test_dir}/pass.json" \
  PERF_PRODUCTION_GATE_PROFILE="minimum-smoke" \
  PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=0 \
  PERF_PRODUCTION_GATE_EXPECT_BASE_URL=http://example.test:8080 \
  PERF_PRODUCTION_GATE_EXPECT_TCP_PORT=9000 \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/67_verify_performance_gate.sh" \
  >"${perf_gate_test_dir}/expected-target-mismatch-pass.log" 2>&1; then
  echo "deploy performance gate failed: expected target mismatch unexpectedly passed" >&2
  exit 1
fi
grep -q 'reason=target_filter_mismatch' "${perf_gate_test_dir}/expected-target-mismatch-pass.log" || {
  echo "deploy performance gate failed: expected target mismatch reason missing" >&2
  exit 1
}
python3 - "${perf_gate_test_dir}/target-filter-missing-pass.json" "${perf_gate_test_dir}/pass.json" <<'PY'
import json
import sys

with open(sys.argv[2], encoding="utf-8") as handle:
    payload = json.load(handle)
payload.pop("targetFilter", None)
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
if PERF_PRODUCTION_GATE_JSON="${perf_gate_test_dir}/target-filter-missing-pass.json" \
  PERF_PRODUCTION_GATE_PROFILE="minimum-smoke" \
  PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=0 \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/67_verify_performance_gate.sh" \
  >"${perf_gate_test_dir}/target-filter-missing-pass.log" 2>&1; then
  echo "deploy performance gate failed: target-filter-missing PASS unexpectedly passed" >&2
  exit 1
fi
grep -q 'reason=target_filter_disabled' "${perf_gate_test_dir}/target-filter-missing-pass.log" || {
  echo "deploy performance gate failed: target-filter-missing PASS did not fail with target filter reason" >&2
  exit 1
}
python3 - "${perf_gate_test_dir}/dirty-source-pass.json" "${perf_gate_test_dir}/pass.json" <<'PY'
import json
import sys

with open(sys.argv[2], encoding="utf-8") as handle:
    payload = json.load(handle)
payload.setdefault("source", {})["gitDirty"] = True
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
if PERF_PRODUCTION_GATE_JSON="${perf_gate_test_dir}/dirty-source-pass.json" \
  PERF_PRODUCTION_GATE_PROFILE="minimum-smoke" \
  PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=0 \
  PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/67_verify_performance_gate.sh" \
  >"${perf_gate_test_dir}/dirty-source-pass.log" 2>&1; then
  echo "deploy performance gate failed: dirty-source PASS unexpectedly passed with clean git required" >&2
  exit 1
fi
grep -q 'reason=source_git_dirty' "${perf_gate_test_dir}/dirty-source-pass.log" || {
  echo "deploy performance gate failed: dirty-source PASS did not fail with clean git reason" >&2
  exit 1
}
python3 - "${perf_gate_test_dir}/old-format-pass.json" "${perf_gate_test_dir}/pass.json" <<'PY'
import json
import sys

with open(sys.argv[2], encoding="utf-8") as handle:
    payload = json.load(handle)
payload.pop("requirements", None)
payload["summary"].pop("runArtifactMissingCount", None)
for row in payload.get("requiredScenarios") or []:
    row.pop("runArtifactsVerified", None)
    row.pop("runArtifactsOK", None)
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
if PERF_PRODUCTION_GATE_JSON="${perf_gate_test_dir}/old-format-pass.json" \
  PERF_PRODUCTION_GATE_PROFILE="minimum-smoke" \
  PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=0 \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/67_verify_performance_gate.sh" \
  >"${perf_gate_test_dir}/old-format-pass.log" 2>&1; then
  echo "deploy performance gate failed: old-format PASS unexpectedly passed" >&2
  exit 1
fi
grep -q 'reason=run_artifacts_requirement_missing' "${perf_gate_test_dir}/old-format-pass.log" || {
  echo "deploy performance gate failed: old-format PASS did not fail with run artifact reason" >&2
  exit 1
}
python3 - "${perf_gate_test_dir}/artifact-count-pass.json" "${perf_gate_test_dir}/pass.json" <<'PY'
import json
import sys

with open(sys.argv[2], encoding="utf-8") as handle:
    payload = json.load(handle)
payload["summary"]["runArtifactMissingCount"] = 1
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
if PERF_PRODUCTION_GATE_JSON="${perf_gate_test_dir}/artifact-count-pass.json" \
  PERF_PRODUCTION_GATE_PROFILE="minimum-smoke" \
  PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=0 \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/67_verify_performance_gate.sh" \
  >"${perf_gate_test_dir}/artifact-count-pass.log" 2>&1; then
  echo "deploy performance gate failed: artifact-count PASS unexpectedly passed" >&2
  exit 1
fi
grep -q 'reason=run_artifacts_missing_count' "${perf_gate_test_dir}/artifact-count-pass.log" || {
  echo "deploy performance gate failed: artifact-count PASS did not fail with run artifact count reason" >&2
  exit 1
}
python3 - "${perf_gate_test_dir}/artifact-row-pass.json" "${perf_gate_test_dir}/pass.json" <<'PY'
import json
import sys

with open(sys.argv[2], encoding="utf-8") as handle:
    payload = json.load(handle)
payload["requiredScenarios"][0]["runArtifactsOK"] = False
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
if PERF_PRODUCTION_GATE_JSON="${perf_gate_test_dir}/artifact-row-pass.json" \
  PERF_PRODUCTION_GATE_PROFILE="minimum-smoke" \
  PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=0 \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/67_verify_performance_gate.sh" \
  >"${perf_gate_test_dir}/artifact-row-pass.log" 2>&1; then
  echo "deploy performance gate failed: artifact-row PASS unexpectedly passed" >&2
  exit 1
fi
grep -q 'reason=required_scenario_run_artifacts_not_ok' "${perf_gate_test_dir}/artifact-row-pass.log" || {
  echo "deploy performance gate failed: artifact-row PASS did not fail with per-scenario artifact reason" >&2
  exit 1
}
cat >"${perf_gate_test_dir}/summary-only-pass.json" <<'EOF'
{
  "status": "PASS",
  "profile": "minimum-smoke",
  "summary": {
    "requiredScenarioCount": 1,
    "passedScenarioCount": 1,
    "failedScenarioCount": 0,
    "missingScenarioCount": 0
  }
}
EOF
if PERF_PRODUCTION_GATE_JSON="${perf_gate_test_dir}/summary-only-pass.json" \
  PERF_PRODUCTION_GATE_PROFILE="minimum-smoke" \
  PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=0 \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/67_verify_performance_gate.sh" \
  >"${perf_gate_test_dir}/summary-only-pass.log" 2>&1; then
  echo "deploy performance gate failed: summary-only PASS unexpectedly passed" >&2
  exit 1
fi
python3 - "${perf_gate_test_dir}/partial-profile-pass.json" "${SCRIPT_DIR}/perf_production_profiles.json" <<'PY'
import json
import hashlib
import subprocess
import sys
import time
from pathlib import Path

output_path, catalog_path = sys.argv[1:3]
now = int(time.time())
repo_root = Path(catalog_path).resolve().parents[2]
try:
    commit = subprocess.run(
        ["git", "rev-parse", "--verify", "HEAD"],
        cwd=repo_root,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    ).stdout.strip()
    branch = subprocess.run(
        ["git", "branch", "--show-current"],
        cwd=repo_root,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    ).stdout.strip()
    dirty = bool(subprocess.run(
        ["git", "status", "--porcelain"],
        cwd=repo_root,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    ).stdout.strip())
except Exception:
    commit = "validate-load-tests"
    branch = "validate-load-tests"
    dirty = False
with open(catalog_path, "rb") as handle:
    catalog_sha256 = hashlib.sha256(handle.read()).hexdigest()
payload = {
    "status": "PASS",
    "profile": "minimum-smoke",
    "profileCatalog": {
        "path": str(catalog_path),
        "schemaVersion": 1,
        "sha256": catalog_sha256,
    },
    "source": {
        "repoRoot": str(repo_root),
        "gitCommit": commit,
        "gitBranch": branch,
        "gitDirty": dirty,
    },
    "summary": {
        "requiredScenarioCount": 1,
        "passedScenarioCount": 1,
        "failedScenarioCount": 0,
        "missingScenarioCount": 0,
        "evidenceOldestMtime": now,
        "evidenceNewestMtime": now,
    },
    "requiredScenarios": [
        {
            "scenario": "login-smoke",
            "category": "self-test",
            "requiredStatus": "PASS",
            "latestSLOStatus": "PASS",
            "latestScenarioStatus": "PASS",
            "runCount": 1,
            "latestRunID": "partial-profile",
            "latestRunDir": "/tmp/partial-profile",
            "latestMtime": now,
            "passed": True,
            "reason": "",
        }
    ],
}
with open(output_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
if PERF_PRODUCTION_GATE_JSON="${perf_gate_test_dir}/partial-profile-pass.json" \
  PERF_PRODUCTION_GATE_PROFILE="minimum-smoke" \
  PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=0 \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/67_verify_performance_gate.sh" \
  >"${perf_gate_test_dir}/partial-profile-pass.log" 2>&1; then
  echo "deploy performance gate failed: partial profile PASS unexpectedly passed" >&2
  exit 1
fi
python3 - "${perf_gate_test_dir}/catalog-sha-mismatch-pass.json" "${SCRIPT_DIR}/perf_production_profiles.json" <<'PY'
import json
import subprocess
import sys
import time
from pathlib import Path

output_path, catalog_path = sys.argv[1:3]
now = int(time.time())
repo_root = Path(catalog_path).resolve().parents[2]
try:
    commit = subprocess.run(
        ["git", "rev-parse", "--verify", "HEAD"],
        cwd=repo_root,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    ).stdout.strip()
    branch = subprocess.run(
        ["git", "branch", "--show-current"],
        cwd=repo_root,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    ).stdout.strip()
    dirty = bool(subprocess.run(
        ["git", "status", "--porcelain"],
        cwd=repo_root,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    ).stdout.strip())
except Exception:
    commit = "validate-load-tests"
    branch = "validate-load-tests"
    dirty = False
with open(catalog_path, encoding="utf-8") as handle:
    scenarios = (json.load(handle).get("profiles") or {}).get("minimum-smoke") or []
payload = {
    "status": "PASS",
    "profile": "minimum-smoke",
    "profileCatalog": {
        "path": catalog_path,
        "schemaVersion": 1,
        "sha256": "0" * 64,
    },
    "source": {
        "repoRoot": str(repo_root),
        "gitCommit": commit,
        "gitBranch": branch,
        "gitDirty": dirty,
    },
    "summary": {
        "requiredScenarioCount": len(scenarios),
        "passedScenarioCount": len(scenarios),
        "failedScenarioCount": 0,
        "missingScenarioCount": 0,
        "evidenceOldestMtime": now,
        "evidenceNewestMtime": now,
    },
    "requiredScenarios": [
        {
            "scenario": scenario,
            "category": "self-test",
            "requiredStatus": "PASS",
            "latestSLOStatus": "PASS",
            "latestScenarioStatus": "PASS",
            "runCount": 1,
            "latestRunID": "catalog-sha-mismatch",
            "latestRunDir": "/tmp/catalog-sha-mismatch",
            "latestMtime": now,
            "passed": True,
            "reason": "",
        }
        for scenario in scenarios
    ],
}
with open(output_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
if PERF_PRODUCTION_GATE_JSON="${perf_gate_test_dir}/catalog-sha-mismatch-pass.json" \
  PERF_PRODUCTION_GATE_PROFILE="minimum-smoke" \
  PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=0 \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/67_verify_performance_gate.sh" \
  >"${perf_gate_test_dir}/catalog-sha-mismatch-pass.log" 2>&1; then
  echo "deploy performance gate failed: catalog sha mismatch PASS unexpectedly passed" >&2
  exit 1
fi
python3 - "${perf_gate_test_dir}/stale-content-pass.json" "${SCRIPT_DIR}/perf_production_profiles.json" <<'PY'
import json
import hashlib
import subprocess
import sys
import time
from pathlib import Path

output_path, catalog_path = sys.argv[1:3]
old = int(time.time()) - 3600
repo_root = Path(catalog_path).resolve().parents[2]
try:
    commit = subprocess.run(
        ["git", "rev-parse", "--verify", "HEAD"],
        cwd=repo_root,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    ).stdout.strip()
    branch = subprocess.run(
        ["git", "branch", "--show-current"],
        cwd=repo_root,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    ).stdout.strip()
    dirty = bool(subprocess.run(
        ["git", "status", "--porcelain"],
        cwd=repo_root,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    ).stdout.strip())
except Exception:
    commit = "validate-load-tests"
    branch = "validate-load-tests"
    dirty = False
with open(catalog_path, encoding="utf-8") as handle:
    scenarios = (json.load(handle).get("profiles") or {}).get("minimum-smoke") or []
with open(catalog_path, "rb") as handle:
    catalog_sha256 = hashlib.sha256(handle.read()).hexdigest()
payload = {
    "status": "PASS",
    "profile": "minimum-smoke",
    "profileCatalog": {
        "path": catalog_path,
        "schemaVersion": 1,
        "sha256": catalog_sha256,
    },
    "source": {
        "repoRoot": str(repo_root),
        "gitCommit": commit,
        "gitBranch": branch,
        "gitDirty": dirty,
    },
    "summary": {
        "requiredScenarioCount": len(scenarios),
        "passedScenarioCount": len(scenarios),
        "failedScenarioCount": 0,
        "missingScenarioCount": 0,
        "evidenceOldestMtime": old,
        "evidenceNewestMtime": old,
    },
    "requiredScenarios": [
        {
            "scenario": scenario,
            "category": "self-test",
            "requiredStatus": "PASS",
            "latestSLOStatus": "PASS",
            "latestScenarioStatus": "PASS",
            "runCount": 1,
            "latestRunID": "stale-content",
            "latestRunDir": "/tmp/stale-content",
            "latestMtime": old,
            "passed": True,
            "reason": "",
        }
        for scenario in scenarios
    ],
}
with open(output_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
if PERF_PRODUCTION_GATE_JSON="${perf_gate_test_dir}/stale-content-pass.json" \
  PERF_PRODUCTION_GATE_PROFILE="minimum-smoke" \
  PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=60 \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/67_verify_performance_gate.sh" \
  >"${perf_gate_test_dir}/stale-content-pass.log" 2>&1; then
  echo "deploy performance gate failed: stale content PASS unexpectedly passed" >&2
  exit 1
fi
PERF_GATE_VERIFY_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/67_verify_performance_gate.sh" \
  >"${perf_gate_test_dir}/verify-self-test.log"
PERF_GATE_INSTALL_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/68_install_performance_gate.sh" \
  >"${perf_gate_test_dir}/install-self-test.log"
PERF_EVIDENCE_PACKAGE_INSTALL_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/69_install_performance_evidence_package.sh" \
  >"${perf_gate_test_dir}/evidence-package-install-self-test.log"
PERF_EVIDENCE_VERIFY_SELF_TEST=true \
  bash "${SCRIPT_DIR}/../../deploy/ubuntu/70_verify_performance_evidence_package.sh" \
  >"${perf_gate_test_dir}/evidence-package-verify-self-test.log"

log "python compile"
python_compile_files=()
while IFS= read -r python_file; do
  python_compile_files+=("${python_file}")
done < <(find "${SCRIPT_DIR}" -maxdepth 1 -type f -name '*.py' | sort)
if ((${#python_compile_files[@]} == 0)); then
  echo "No Python scripts found for compile validation." >&2
  exit 1
fi
printf 'pythonScripts=%s\n' "${#python_compile_files[@]}"
python3 -m py_compile "${python_compile_files[@]}"

k6_scripts=()
while IFS= read -r k6_script; do
  k6_scripts+=("${k6_script}")
done < <(find "${SCRIPT_DIR}/k6" -maxdepth 1 -type f -name '*.js' | sort)
if ((${#k6_scripts[@]} == 0)); then
  echo "No k6 scripts found for inspect validation." >&2
  exit 1
fi
printf 'k6Scripts=%s\n' "${#k6_scripts[@]}"

bash_bin="$(command -v bash || true)"
python_bin="$(command -v python3 || true)"
k6_bin="$(command -v k6 || true)"
k6_inspect_status="skipped_disabled"
if bool_enabled "${VALIDATE_K6_INSPECT}"; then
  if [[ -n "${k6_bin}" ]]; then
    log "k6 inspect"
    for script in "${k6_scripts[@]}"; do
      "${k6_bin}" inspect "${script}" >/dev/null
    done
    k6_inspect_status="pass"
  else
    log "k6 inspect skipped: k6 not found"
    k6_inspect_status="skipped_missing"
  fi
fi

log "validation inventory"
printf '%s\n' "${shell_syntax_files[@]}" >"${RESULT_DIR}/validation-shell-scripts.txt"
printf '%s\n' "${python_compile_files[@]}" >"${RESULT_DIR}/validation-python-scripts.txt"
printf '%s\n' "${k6_scripts[@]}" >"${RESULT_DIR}/validation-k6-scripts.txt"
printf '%s\n' \
  "${SCRIPT_DIR}/README.md" \
  "${SCRIPT_DIR}/perf_product_campaigns.json" \
  "${SCRIPT_DIR}/perf_production_profiles.json" \
  "${SCRIPT_DIR}/../../deploy/ubuntu/README.md" \
  "${SCRIPT_DIR}/../../docs/imserver-aliyun-local-binary-deploy.md" \
  >"${RESULT_DIR}/validation-docs.txt"
python3 "${SCRIPT_DIR}/perf_validation_inventory.py" \
  --repo-root "${SCRIPT_DIR}/../.." \
  --json-output "${RESULT_DIR}/validation-inventory.json" \
  --md-output "${RESULT_DIR}/validation-inventory.md" \
  --shell-list "${RESULT_DIR}/validation-shell-scripts.txt" \
  --python-list "${RESULT_DIR}/validation-python-scripts.txt" \
  --k6-list "${RESULT_DIR}/validation-k6-scripts.txt" \
  --docs-list "${RESULT_DIR}/validation-docs.txt" \
  --bash-bin "${bash_bin}" \
  --python-bin "${python_bin}" \
  --k6-bin "${k6_bin}" \
  --k6-inspect-requested "${VALIDATE_K6_INSPECT}" \
  --k6-inspect-status "${k6_inspect_status}"
python3 "${SCRIPT_DIR}/perf_validation_inventory.py" \
  --verify-json "${RESULT_DIR}/validation-inventory.json" \
  --verify-md "${RESULT_DIR}/validation-inventory.md" >/dev/null
cp "${RESULT_DIR}/validation-inventory.md" "${RESULT_DIR}/validation-inventory-bad.md"
python3 - "${RESULT_DIR}/validation-inventory-bad.md" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text(text.replace("- shellScripts:", "- shellScriptCount:", 1), encoding="utf-8")
PY
if python3 "${SCRIPT_DIR}/perf_validation_inventory.py" \
  --verify-json "${RESULT_DIR}/validation-inventory.json" \
  --verify-md "${RESULT_DIR}/validation-inventory-bad.md" \
  >"${RESULT_DIR}/validation-inventory-bad-md.out" \
  2>"${RESULT_DIR}/validation-inventory-bad-md.err"; then
  echo "Expected validation inventory verifier to reject mismatched markdown." >&2
  exit 1
fi
grep -q 'reason=markdown_summary_mismatch group=shell' \
  "${RESULT_DIR}/validation-inventory-bad-md.err" || {
    echo "Expected validation inventory markdown_summary_mismatch reason." >&2
    exit 1
  }
python3 - "${RESULT_DIR}/validation-inventory.json" "${RESULT_DIR}/validation-inventory-bad-required-records.json" <<'PY'
import json
import sys

source, target = sys.argv[1:3]
with open(source, encoding="utf-8") as handle:
    payload = json.load(handle)
payload.setdefault("requiredRecords", {}).setdefault("python", [])
payload["requiredRecords"]["python"] = [
    row for row in payload["requiredRecords"]["python"]
    if row != "IMServer/LoadTests/perf_product_scenario_suite_verify.py"
]
with open(target, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
if python3 "${SCRIPT_DIR}/perf_validation_inventory.py" \
  --verify-json "${RESULT_DIR}/validation-inventory-bad-required-records.json" \
  >"${RESULT_DIR}/validation-inventory-bad-required-records.out" \
  2>"${RESULT_DIR}/validation-inventory-bad-required-records.err"; then
  echo "Expected validation inventory verifier to reject tampered requiredRecords." >&2
  exit 1
fi
grep -q 'reason=required_records_mismatch' \
  "${RESULT_DIR}/validation-inventory-bad-required-records.err" || {
    echo "Expected validation inventory required_records_mismatch reason." >&2
    exit 1
  }
python3 - "${RESULT_DIR}/validation-inventory.json" "${RESULT_DIR}/validation-inventory-missing-suite-verifier.json" <<'PY'
import json
import sys

source, target = sys.argv[1:3]
with open(source, encoding="utf-8") as handle:
    payload = json.load(handle)
python_records = payload.get("groups", {}).get("python") or []
payload["groups"]["python"] = [
    row for row in python_records
    if row.get("path") != "IMServer/LoadTests/perf_product_scenario_suite_verify.py"
]
payload["summary"]["python"] = len(payload["groups"]["python"])
with open(target, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
if python3 "${SCRIPT_DIR}/perf_validation_inventory.py" \
  --verify-json "${RESULT_DIR}/validation-inventory-missing-suite-verifier.json" \
  >"${RESULT_DIR}/validation-inventory-missing-suite-verifier.out" \
  2>"${RESULT_DIR}/validation-inventory-missing-suite-verifier.err"; then
  echo "Expected validation inventory verifier to reject missing suite verifier record." >&2
  exit 1
fi
grep -q 'reason=required_record_missing group=python record=IMServer/LoadTests/perf_product_scenario_suite_verify.py' \
  "${RESULT_DIR}/validation-inventory-missing-suite-verifier.err" || {
    echo "Expected validation inventory missing suite verifier reason." >&2
    exit 1
  }
python3 - "${RESULT_DIR}/validation-inventory.json" "${RESULT_DIR}/validation-inventory-bad-sha.json" <<'PY'
import json
import sys

source, target = sys.argv[1:3]
with open(source, encoding="utf-8") as handle:
    payload = json.load(handle)
first_shell = payload.get("groups", {}).get("shell", [])[0]
first_shell["sha256"] = "not-a-valid-sha"
with open(target, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
if python3 "${SCRIPT_DIR}/perf_validation_inventory.py" \
  --verify-json "${RESULT_DIR}/validation-inventory-bad-sha.json" \
  >"${RESULT_DIR}/validation-inventory-bad-sha.out" \
  2>"${RESULT_DIR}/validation-inventory-bad-sha.err"; then
  echo "Expected validation inventory verifier to reject invalid sha256." >&2
  exit 1
fi
grep -q 'reason=invalid_record_sha256 group=shell' \
  "${RESULT_DIR}/validation-inventory-bad-sha.err" || {
    echo "Expected validation inventory invalid_record_sha256 reason." >&2
    exit 1
  }
python3 - "${RESULT_DIR}/validation-inventory.json" "${RESULT_DIR}/validation-inventory-unsafe-path.json" <<'PY'
import json
import sys

source, target = sys.argv[1:3]
with open(source, encoding="utf-8") as handle:
    payload = json.load(handle)
first_shell = payload.get("groups", {}).get("shell", [])[0]
first_shell["path"] = "/tmp/forged-script.sh"
with open(target, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
if python3 "${SCRIPT_DIR}/perf_validation_inventory.py" \
  --verify-json "${RESULT_DIR}/validation-inventory-unsafe-path.json" \
  >"${RESULT_DIR}/validation-inventory-unsafe-path.out" \
  2>"${RESULT_DIR}/validation-inventory-unsafe-path.err"; then
  echo "Expected validation inventory verifier to reject unsafe path." >&2
  exit 1
fi
grep -q 'reason=unsafe_record_path group=shell record=/tmp/forged-script.sh' \
  "${RESULT_DIR}/validation-inventory-unsafe-path.err" || {
    echo "Expected validation inventory unsafe_record_path reason." >&2
    exit 1
  }
python3 - "${RESULT_DIR}/validation-inventory.json" "${RESULT_DIR}/validation-inventory-duplicate-path.json" <<'PY'
import copy
import json
import sys

source, target = sys.argv[1:3]
with open(source, encoding="utf-8") as handle:
    payload = json.load(handle)
shell_records = payload.get("groups", {}).get("shell", [])
shell_records.append(copy.deepcopy(shell_records[0]))
payload["summary"]["shell"] = len(shell_records)
with open(target, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
if python3 "${SCRIPT_DIR}/perf_validation_inventory.py" \
  --verify-json "${RESULT_DIR}/validation-inventory-duplicate-path.json" \
  >"${RESULT_DIR}/validation-inventory-duplicate-path.out" \
  2>"${RESULT_DIR}/validation-inventory-duplicate-path.err"; then
  echo "Expected validation inventory verifier to reject duplicate path." >&2
  exit 1
fi
grep -q 'reason=duplicate_record_path group=shell' \
  "${RESULT_DIR}/validation-inventory-duplicate-path.err" || {
    echo "Expected validation inventory duplicate_record_path reason." >&2
    exit 1
  }

log "coverage audit"
python3 "${SCRIPT_DIR}/perf_coverage.py" \
  --output "${RESULT_DIR}/coverage.md" \
  --json-output "${RESULT_DIR}/coverage.json" \
  --csv-output "${RESULT_DIR}/coverage.csv" \
  --strict >/dev/null

log "route audit"
python3 "${SCRIPT_DIR}/perf_route_audit.py" \
  --output "${RESULT_DIR}/route-audit.md" \
  --json-output "${RESULT_DIR}/route-audit.json" \
  --csv-output "${RESULT_DIR}/route-audit.csv" \
  --strict \
  --fail-on-orphan >/dev/null

log "matrix audit"
python3 "${SCRIPT_DIR}/perf_matrix_audit.py" \
  --script "${SCRIPT_DIR}/run_perf_scenarios.sh" \
  --k6-dir "${SCRIPT_DIR}/k6" \
  --output "${RESULT_DIR}/matrix-audit.md" \
  --json-output "${RESULT_DIR}/matrix-audit.json" \
  --csv-output "${RESULT_DIR}/matrix-audit.csv" \
  --strict >/dev/null

log "matrix audit relative path"
(
  cd "${SCRIPT_DIR}"
  python3 perf_matrix_audit.py \
    --script run_perf_scenarios.sh \
    --k6-dir k6 \
    --output "${RESULT_DIR}/matrix-audit-relative.md" \
    --json-output "${RESULT_DIR}/matrix-audit-relative.json" \
    --csv-output "${RESULT_DIR}/matrix-audit-relative.csv" \
    --strict >/dev/null
)

log "production profile audit"
python3 "${SCRIPT_DIR}/perf_production_profiles_audit.py" \
  --catalog "${SCRIPT_DIR}/perf_production_profiles.json" \
  --matrix-script "${SCRIPT_DIR}/run_perf_scenarios.sh" \
  --output "${RESULT_DIR}/production-profile-audit.md" \
  --json-output "${RESULT_DIR}/production-profile-audit.json" \
  --csv-output "${RESULT_DIR}/production-profile-audit.csv" \
  --strict >/dev/null
python3 "${SCRIPT_DIR}/perf_production_profiles_audit.py" \
  --verify-json "${RESULT_DIR}/production-profile-audit.json" \
  --verify-md "${RESULT_DIR}/production-profile-audit.md" \
  --strict >/dev/null
cp "${RESULT_DIR}/production-profile-audit.md" "${RESULT_DIR}/production-profile-audit-bad-md.md"
perl -0pi -e 's/- status: `PASS`/- auditStatus: `PASS`/' "${RESULT_DIR}/production-profile-audit-bad-md.md"
if python3 "${SCRIPT_DIR}/perf_production_profiles_audit.py" \
  --verify-json "${RESULT_DIR}/production-profile-audit.json" \
  --verify-md "${RESULT_DIR}/production-profile-audit-bad-md.md" \
  --strict >"${RESULT_DIR}/production-profile-audit-bad-md.log" 2>&1; then
  echo "Expected production profile audit verifier to reject mismatched markdown." >&2
  exit 1
fi
grep -q 'markdown_mismatch' "${RESULT_DIR}/production-profile-audit-bad-md.log" || {
  echo "Expected production profile audit bad markdown fixture to report markdown_mismatch." >&2
  exit 1
}

log "product profile gate"
python3 "${SCRIPT_DIR}/perf_product_profile_gate.py" \
  --profile-catalog "${SCRIPT_DIR}/perf_production_profiles.json" \
  --matrix-script "${SCRIPT_DIR}/run_perf_scenarios.sh" \
  --profile normal-product-smoke \
  --profile normal-product-baseline \
  --profile normal-product-capacity \
  --require-no-maturity-gaps \
  --output "${RESULT_DIR}/product-profile-gate.md" \
  --json-output "${RESULT_DIR}/product-profile-gate.json" \
  --csv-output "${RESULT_DIR}/product-profile-gate.csv" \
  --strict >/dev/null
python3 "${SCRIPT_DIR}/perf_product_profile_gate.py" \
  --verify-json "${RESULT_DIR}/product-profile-gate.json" \
  --verify-md "${RESULT_DIR}/product-profile-gate.md" \
  --strict >/dev/null
cp "${RESULT_DIR}/product-profile-gate.md" "${RESULT_DIR}/product-profile-gate-bad-md.md"
perl -0pi -e 's/- status: `PASS`/- gateStatus: `PASS`/' "${RESULT_DIR}/product-profile-gate-bad-md.md"
if python3 "${SCRIPT_DIR}/perf_product_profile_gate.py" \
  --verify-json "${RESULT_DIR}/product-profile-gate.json" \
  --verify-md "${RESULT_DIR}/product-profile-gate-bad-md.md" \
  --strict >"${RESULT_DIR}/product-profile-gate-bad-md.log" 2>&1; then
  echo "Expected product profile gate verifier to reject mismatched markdown." >&2
  exit 1
fi
grep -q 'markdown_mismatch' "${RESULT_DIR}/product-profile-gate-bad-md.log" || {
  echo "Expected product profile gate bad markdown fixture to report markdown_mismatch." >&2
  exit 1
}
python3 - "${SCRIPT_DIR}/perf_production_profiles.json" "${RESULT_DIR}/product-profile-gate-bad-catalog.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
payload.setdefault("profiles", {})["bad-large-group-only"] = ["large-group-1000-10"]
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
if python3 "${SCRIPT_DIR}/perf_product_profile_gate.py" \
  --profile-catalog "${RESULT_DIR}/product-profile-gate-bad-catalog.json" \
  --matrix-script "${SCRIPT_DIR}/run_perf_scenarios.sh" \
  --profile bad-large-group-only \
  --output "${RESULT_DIR}/product-profile-gate-bad.md" \
  --json-output "${RESULT_DIR}/product-profile-gate-bad.json" \
  --csv-output "${RESULT_DIR}/product-profile-gate-bad.csv" \
  --strict >/dev/null 2>&1; then
  echo "Expected product profile gate to reject large-group-only product profile." >&2
  exit 1
fi
python3 - "${RESULT_DIR}/product-profile-gate-bad.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
kinds = {row.get("kind") for row in data.get("issues") or []}
if data.get("status") != "FAIL":
    raise SystemExit("Expected bad product profile gate fixture to fail.")
if "large-group-in-product-profile" not in kinds:
    raise SystemExit(f"Expected large-group-in-product-profile issue, got {kinds}.")
if "missing-domain" not in kinds:
    raise SystemExit(f"Expected missing-domain issues, got {kinds}.")
PY

log "product campaign audit"
python3 "${SCRIPT_DIR}/perf_product_campaign_audit.py" \
  --campaigns "${SCRIPT_DIR}/perf_product_campaigns.json" \
  --product-plan-script "${SCRIPT_DIR}/run_product_test_plan.sh" \
  --profile-catalog "${SCRIPT_DIR}/perf_production_profiles.json" \
  --matrix-script "${SCRIPT_DIR}/run_perf_scenarios.sh" \
  --output "${RESULT_DIR}/product-campaign-audit.md" \
  --json-output "${RESULT_DIR}/product-campaign-audit.json" \
  --csv-output "${RESULT_DIR}/product-campaign-audit.csv" \
  --strict >/dev/null
python3 "${SCRIPT_DIR}/perf_product_campaign_audit.py" \
  --verify-json "${RESULT_DIR}/product-campaign-audit.json" \
  --verify-md "${RESULT_DIR}/product-campaign-audit.md" \
  --strict >/dev/null
cp "${RESULT_DIR}/product-campaign-audit.md" "${RESULT_DIR}/product-campaign-audit-bad-md.md"
perl -0pi -e 's/- status: `PASS`/- auditStatus: `PASS`/' "${RESULT_DIR}/product-campaign-audit-bad-md.md"
if python3 "${SCRIPT_DIR}/perf_product_campaign_audit.py" \
  --verify-json "${RESULT_DIR}/product-campaign-audit.json" \
  --verify-md "${RESULT_DIR}/product-campaign-audit-bad-md.md" \
  --strict >"${RESULT_DIR}/product-campaign-audit-bad-md.log" 2>&1; then
  echo "Expected product campaign audit verifier to reject mismatched markdown." >&2
  exit 1
fi
grep -q 'markdown_mismatch' "${RESULT_DIR}/product-campaign-audit-bad-md.log" || {
  echo "Expected product campaign audit bad markdown fixture to report markdown_mismatch." >&2
  exit 1
}
python3 - "${RESULT_DIR}/product-campaign-audit.json" "${RESULT_DIR}/product-campaign-audit.md" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
markdown = Path(sys.argv[2]).read_text(encoding="utf-8")
policies = payload.get("requiredPhasePolicies") or []
if len(policies) < 3:
    raise SystemExit("Expected product campaign audit to expose required phase policies.")
non_large = next((row for row in policies if row.get("campaign") == "non-large-group-release"), None)
if non_large is None:
    raise SystemExit("Expected non-large-group-release required phase policy.")
required = set(non_large.get("requiredPhases") or [])
for phase in ["sync-read", "direct-chat", "group-workflow", "realtime-direct"]:
    if phase not in required:
        raise SystemExit(f"Expected non-large-group-release policy to require {phase}.")
if "## Required Phase Policies" not in markdown:
    raise SystemExit("Expected product campaign audit markdown to include required phase policies.")
PY
python3 - "${SCRIPT_DIR}/perf_product_campaigns.json" "${RESULT_DIR}/product-campaign-audit-bad-large-group.json" <<'PY'
import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
payload = json.loads(source.read_text(encoding="utf-8"))
payload["campaigns"]["non-large-group-release"]["stages"].append({
    "id": "bad-large-group",
    "runner": "scenario-group",
    "scenarioGroups": ["large-group"],
    "required": True,
    "isolated": True,
    "evidence": "bad fixture"
})
target.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
if python3 "${SCRIPT_DIR}/perf_product_campaign_audit.py" \
  --campaigns "${RESULT_DIR}/product-campaign-audit-bad-large-group.json" \
  --product-plan-script "${SCRIPT_DIR}/run_product_test_plan.sh" \
  --profile-catalog "${SCRIPT_DIR}/perf_production_profiles.json" \
  --matrix-script "${SCRIPT_DIR}/run_perf_scenarios.sh" \
  --output "${RESULT_DIR}/product-campaign-audit-bad-large-group.md" \
  --json-output "${RESULT_DIR}/product-campaign-audit-bad-large-group-result.json" \
  --csv-output "${RESULT_DIR}/product-campaign-audit-bad-large-group.csv" \
  --strict >"${RESULT_DIR}/product-campaign-audit-bad-large-group.log" 2>&1; then
  echo "Expected product campaign audit to reject large-group stage in non-large-group-release." >&2
  exit 1
fi
grep -q 'non-large-includes-large-group' "${RESULT_DIR}/product-campaign-audit-bad-large-group-result.json" || {
  echo "Expected product campaign audit bad fixture to report non-large-includes-large-group." >&2
  exit 1
}
python3 - "${SCRIPT_DIR}/perf_product_campaigns.json" "${RESULT_DIR}/product-campaign-audit-missing-domain.json" <<'PY'
import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
payload = json.loads(source.read_text(encoding="utf-8"))
for stage in payload["campaigns"]["non-large-group-release"]["stages"]:
    if stage.get("id") == "workflow-domains":
        stage["phases"] = [phase for phase in stage.get("phases", []) if phase != "sync-read"]
target.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
if python3 "${SCRIPT_DIR}/perf_product_campaign_audit.py" \
  --campaigns "${RESULT_DIR}/product-campaign-audit-missing-domain.json" \
  --product-plan-script "${SCRIPT_DIR}/run_product_test_plan.sh" \
  --profile-catalog "${SCRIPT_DIR}/perf_production_profiles.json" \
  --matrix-script "${SCRIPT_DIR}/run_perf_scenarios.sh" \
  --output "${RESULT_DIR}/product-campaign-audit-missing-domain.md" \
  --json-output "${RESULT_DIR}/product-campaign-audit-missing-domain-result.json" \
  --csv-output "${RESULT_DIR}/product-campaign-audit-missing-domain.csv" \
  --strict >"${RESULT_DIR}/product-campaign-audit-missing-domain.log" 2>&1; then
  echo "Expected product campaign audit to reject non-large-group-release missing sync-read." >&2
  exit 1
fi
grep -q 'non-large-missing-phases' "${RESULT_DIR}/product-campaign-audit-missing-domain-result.json" || {
  echo "Expected product campaign audit missing-domain fixture to report non-large-missing-phases." >&2
  exit 1
}

log "non-large-group regression runner self-test"
NON_LARGE_GROUP_REGRESSION_SELF_TEST=true \
  "${SCRIPT_DIR}/run_non_large_group_regression.sh" >/dev/null

log "product scenario suite runner self-test"
PRODUCT_SCENARIO_SELF_TEST=true \
  "${SCRIPT_DIR}/run_product_scenario_suite.sh" >/dev/null

log "product scenario suite receipt verifier self-test"
suite_verify_dir="${RESULT_DIR}/product-scenario-suite-verifier"
rm -rf "${suite_verify_dir}"
mkdir -p "${suite_verify_dir}"
python3 - "${suite_verify_dir}" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])

def write(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")

def base_payload(status: str, reason: str, stages: list[dict], *, execute: bool = True, suite: str = "smoke", include_large_group: bool = False) -> dict:
    failure_summary = [
        {
            "stage": row["id"],
            "runner": row["runner"],
            "value": row["value"],
            "exitCode": row["exitCode"],
            "reason": "entrypoint_failed",
            "blockerType": "entrypoint",
            "failedPhase": "entrypoint",
            "failedPhaseReason": "entrypoint_probe_failed",
            "entrypointDiagnosis": "cloud_edge_http_403_intercept",
            "entrypointAction": "cloud_console_rescue_required",
            "preventsPerformanceEvidence": True,
            "artifact": f"{row['runDir']}/product-test-plan-run.json",
        }
        for row in stages
        if row["status"] == "FAIL"
    ]
    stage_coverage = []
    selected_scenarios = []
    covered_domains = set()
    for row in stages:
        is_large = "large-group" in row["id"] or "large-group" in row["value"]
        scenarios = []
        domains = []
        if row["runner"] == "product-plan":
            scenarios = ["login-smoke", "client-sync-mix-smoke", "direct-message-lifecycle-smoke"]
            domains = ["auth-session", "client-sync", "message-workflow"]
            selected_scenarios.extend(scenarios)
            covered_domains.update(domains)
        stage_coverage.append({
            "stage": row["id"],
            "runner": row["runner"],
            "value": row["value"],
            "coverageStatus": "READY",
            "phaseCount": 2 if row["runner"] == "product-plan" else 0,
            "uniqueScenarioCount": len(scenarios),
            "largeGroupIncluded": is_large,
            "coveredProductDomains": domains,
            "requiredProductDomains": ["auth-session", "client-sync", "message-workflow"] if row["runner"] == "product-plan" else [],
            "missingProductDomains": [],
            "requiredProductDomainsCovered": row["runner"] == "product-plan",
            "selectedScenarios": scenarios,
            "sampleScenarios": scenarios,
        })
    return {
        "schemaVersion": 1,
        "suite": suite,
        "runIDPrefix": "suite-verify",
        "status": status,
        "reason": reason,
        "startedAt": "2026-06-19T00:00:00Z",
        "endedAt": "2026-06-19T00:00:01Z",
        "target": {
            "baseURL": "http://127.0.0.1:8080",
            "tcpHost": "127.0.0.1",
            "tcpPort": "9000",
            "accountFile": "accounts/load-5000.csv",
            "conversationIDPresent": True,
        },
        "settings": {
            "dryRun": False,
            "execute": execute,
            "stopOnFailure": True,
            "includeLargeGroup": include_large_group,
        },
        "stageCount": len(stages),
        "failedStageCount": sum(1 for row in stages if row["status"] == "FAIL"),
        "plannedStageCount": sum(1 for row in stages if row["status"] == "PLANNED"),
        "coverageSummary": {
            "stageCount": len(stages),
            "productPlanStageCount": sum(1 for row in stages if row["runner"] == "product-plan"),
            "campaignStageCount": sum(1 for row in stages if row["runner"] != "product-plan"),
            "coverageErrorCount": 0,
            "uniqueScenarioCount": len(dict.fromkeys(selected_scenarios)),
            "largeGroupIncluded": include_large_group or any("large-group" in row["id"] or "large-group" in row["value"] for row in stages),
            "coveredProductDomains": sorted(covered_domains),
            "requiredProductDomains": ["auth-session", "client-sync", "message-workflow"] if selected_scenarios else [],
            "missingProductDomains": [],
            "requiredProductDomainsCovered": bool(selected_scenarios),
            "sampleScenarios": list(dict.fromkeys(selected_scenarios))[:16],
        },
        "failureSummary": failure_summary,
        "stageCoverage": stage_coverage,
        "stages": stages,
        "artifacts": {
            "json": "product-scenario-suite-run.json",
            "markdown": "product-scenario-suite-run.md",
        },
    }

pass_stage = {
    "id": "normal-smoke",
    "runner": "product-plan",
    "value": "normal-smoke",
    "description": "Fast cross-product smoke excluding large-group fanout.",
    "runDir": "results/suite-verify-normal-smoke",
    "status": "PASS",
    "exitCode": 0,
}
planned_stage = {**pass_stage, "status": "PLANNED", "exitCode": None}
failed_stage = {**pass_stage, "status": "FAIL", "exitCode": 7}
large_stage = {
    "id": "large-group-isolated",
    "runner": "scenario-group",
    "value": "large-group",
    "description": "Large-group fanout stress.",
    "runDir": "results/suite-verify-large-group",
    "status": "PASS",
    "exitCode": 0,
}

fixtures = {
    "pass": base_payload("PASS", "all_stages_passed", [pass_stage]),
    "planned": base_payload("PLANNED", "execute_disabled", [planned_stage], execute=False),
    "fail": base_payload("FAIL", "stage_failed:normal-smoke", [failed_stage]),
    "large": base_payload("PASS", "all_stages_passed", [large_stage]),
}

rescue_tarball = root / "current-node-access-rescue.tar.gz"
rescue_tarball.write_text("synthetic rescue tarball\n", encoding="utf-8")
for suffix in (".verify.sh", ".sha256", ".receipt.json"):
    (root / f"current-node-access-rescue.tar.gz{suffix}").write_text(f"synthetic {suffix}\n", encoding="utf-8")
fixtures["fail-rescue-pass"] = base_payload("FAIL", "stage_failed:normal-smoke", [failed_stage])
fixtures["fail-rescue-pass"]["failureSummary"][0]["entrypointRescueStatus"] = "PASS"
fixtures["fail-rescue-pass"]["failureSummary"][0]["entrypointRescueTarball"] = "current-node-access-rescue.tar.gz"

missing_sidecar = root / "missing-sidecar-rescue.tar.gz"
missing_sidecar.write_text("synthetic rescue tarball without sidecars\n", encoding="utf-8")
fixtures["fail-rescue-missing-sidecar"] = base_payload("FAIL", "stage_failed:normal-smoke", [failed_stage])
fixtures["fail-rescue-missing-sidecar"]["failureSummary"][0]["entrypointRescueStatus"] = "PASS"
fixtures["fail-rescue-missing-sidecar"]["failureSummary"][0]["entrypointRescueTarball"] = "missing-sidecar-rescue.tar.gz"

for name, payload in fixtures.items():
    write(root / f"{name}.json", payload)
    lines = [
        "# Product Scenario Suite Run",
        "",
        f"- suite: `{payload['suite']}`",
        f"- status: `{payload['status']}`",
        "",
        "## Coverage",
        "",
        "| Stage | Runner | Coverage | Scenarios | Domains | Missing Domains | Large Group |",
        "| --- | --- | --- | --- | --- | --- | --- |",
    ]
    for coverage in payload["stageCoverage"]:
        lines.append(
            f"| `{coverage['stage']}` | `{coverage['runner']}` | `{coverage['coverageStatus']}` | "
            f"`{coverage['uniqueScenarioCount']}` | "
            f"`{','.join(coverage['coveredProductDomains']) or '-'}` | "
            f"`{','.join(coverage['missingProductDomains']) or '-'}` | "
            f"`{coverage['largeGroupIncluded']}` |"
        )
    lines.extend([
        "",
        "## Stages",
        "",
        "| Stage | Runner | Value | Status | Exit | Run Dir |",
        "| --- | --- | --- | --- | --- | --- |",
    ])
    for stage in payload["stages"]:
        exit_code = "-" if stage["exitCode"] is None else str(stage["exitCode"])
        lines.append(f"| `{stage['id']}` | `{stage['runner']}` | `{stage['value']}` | `{stage['status']}` | `{exit_code}` | `{stage['runDir']}` |")
    (root / f"{name}.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
python3 "${SCRIPT_DIR}/perf_product_scenario_suite_verify.py" \
  --suite-run-json "${suite_verify_dir}/pass.json" \
  --markdown "${suite_verify_dir}/pass.md" \
  --require-pass \
  --require-no-large-group >/dev/null
python3 "${SCRIPT_DIR}/perf_product_scenario_suite_verify.py" \
  --suite-run-json "${suite_verify_dir}/planned.json" \
  --markdown "${suite_verify_dir}/planned.md" \
  --allow-planned \
  --require-no-large-group >/dev/null
python3 "${SCRIPT_DIR}/perf_product_scenario_suite_verify.py" \
  --suite-run-json "${suite_verify_dir}/fail.json" \
  --markdown "${suite_verify_dir}/fail.md" \
  --require-no-large-group >/dev/null
python3 "${SCRIPT_DIR}/perf_product_scenario_suite_verify.py" \
  --suite-run-json "${suite_verify_dir}/fail-rescue-pass.json" \
  --markdown "${suite_verify_dir}/fail-rescue-pass.md" \
  --require-no-large-group >/dev/null
if python3 "${SCRIPT_DIR}/perf_product_scenario_suite_verify.py" \
  --suite-run-json "${suite_verify_dir}/fail-rescue-missing-sidecar.json" \
  --markdown "${suite_verify_dir}/fail-rescue-missing-sidecar.md" \
  --require-no-large-group >"${suite_verify_dir}/fail-rescue-missing-sidecar.out" 2>"${suite_verify_dir}/fail-rescue-missing-sidecar.err"; then
  echo "Expected suite verifier to reject rescue PASS without sidecars." >&2
  exit 1
fi
grep -q 'reason=rescue_tarball_sidecar_missing' "${suite_verify_dir}/fail-rescue-missing-sidecar.err" || {
  echo "Expected suite verifier rescue_tarball_sidecar_missing reason." >&2
  exit 1
}
if python3 "${SCRIPT_DIR}/perf_product_scenario_suite_verify.py" \
  --suite-run-json "${suite_verify_dir}/fail.json" \
  --markdown "${suite_verify_dir}/fail.md" \
  --require-pass >"${suite_verify_dir}/fail-require-pass.out" 2>"${suite_verify_dir}/fail-require-pass.err"; then
  echo "Expected suite verifier to reject failed receipt with --require-pass." >&2
  exit 1
fi
grep -q 'reason=status_not_pass' "${suite_verify_dir}/fail-require-pass.err" || {
  echo "Expected suite verifier status_not_pass reason." >&2
  exit 1
}
if python3 "${SCRIPT_DIR}/perf_product_scenario_suite_verify.py" \
  --suite-run-json "${suite_verify_dir}/large.json" \
  --markdown "${suite_verify_dir}/large.md" \
  --require-pass \
  --require-no-large-group >"${suite_verify_dir}/large.out" 2>"${suite_verify_dir}/large.err"; then
  echo "Expected suite verifier to reject large-group stage in non-large suite." >&2
  exit 1
fi
grep -Eq 'reason=(coverage_large_group_not_allowed|large_group_stage_not_allowed|stage_coverage_large_group_not_allowed)' "${suite_verify_dir}/large.err" || {
  echo "Expected suite verifier large-group rejection reason." >&2
  exit 1
}

log "current production readiness runner self-test"
CURRENT_PRODUCTION_SELF_TEST=true \
  "${SCRIPT_DIR}/run_current_production_readiness.sh" >/dev/null

log "current production readiness artifact verifier self-test"
current_readiness_verify_dir="${RESULT_DIR}/current-readiness-artifact-verifier"
rm -rf "${current_readiness_verify_dir}"
mkdir -p "${current_readiness_verify_dir}/blocked" "${current_readiness_verify_dir}/pass" "${current_readiness_verify_dir}/bad-next"
python3 - "${current_readiness_verify_dir}" "${SCRIPT_DIR}" <<'PY'
import json
import sys
import time
from pathlib import Path

root = Path(sys.argv[1])
script_dir = Path(sys.argv[2])
sys.path.insert(0, str(script_dir))
from run_product_campaign import build_runbook
from perf_current_production_readiness_verify import build_readiness_markdown
now = int(time.time())

def write(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")

def common_target() -> dict:
    return {
        "baseURL": "https://chat.myim-prod.com",
        "tcpHost": "tcp.myim-prod.com",
        "tcpPort": "9000",
        "accountFile": "accounts/load-5000.csv",
        "conversationIDPresent": True,
    }

def common_evidence_policy() -> dict:
    return {
        "requirePackageableEvidence": True,
        "requireCloudSecurityGroup": False,
        "requirePublicPortPolicy": False,
        "allowTempHTTP8080": False,
        "cloudSecurityGroupRulesMaxAgeSeconds": 86400,
        "cloudSecurityGroupRulesRequireRootOwner": False,
        "cloudSecurityGroupRulesFile": "",
        "requireCloudSecurityGroupRepairReceipt": False,
        "cloudSecurityGroupRepairReceiptJSON": "",
        "operatorNetworkPreflight": False,
        "autoProductScenarioSuiteForPackageableAcceptance": False,
    }

def full_acceptance_campaign_payload(result_dir: Path) -> dict:
    stages = []
    for index, stage_id in enumerate(
        [
            "normal-product-smoke",
            "normal-product-plan",
            "normal-product-baseline",
            "normal-product-capacity",
            "message-realtime-capacity",
            "large-group-isolated",
        ],
        start=1,
    ):
        command = (
            "env BASE_URL=https://chat.myim-prod.com TCP_HOST=tcp.myim-prod.com "
            "TCP_PORT=9000 IM_INTERNAL_SECRET=<redacted> "
            f"PRODUCT_TEST_PHASES={stage_id} ./run_product_test_plan.sh"
        )
        if stage_id == "large-group-isolated":
            command = (
                "env BASE_URL=https://chat.myim-prod.com TCP_HOST=tcp.myim-prod.com "
                "TCP_PORT=9000 IM_INTERNAL_SECRET=<redacted> "
                "SCENARIO_GROUPS=large-group ./run_perf_scenarios.sh"
            )
        stages.append({
            "index": index,
            "id": stage_id,
            "runner": "scenario-group" if stage_id == "large-group-isolated" else "product-plan",
            "required": True,
            "isolated": stage_id == "large-group-isolated",
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
    return {
        "schemaVersion": 1,
        "generatedAt": "2026-01-01T00:00:00Z",
        "campaign": "production-full-acceptance",
        "description": "full acceptance self-test",
        "campaignCatalog": str(script_dir / "perf_product_campaigns.json"),
        "execute": True,
        "stopOnFailure": True,
        "resultDir": str(result_dir),
        "runIDPrefix": "current-readiness-full-acceptance-self-test",
        "target": {
            "baseURL": "https://chat.myim-prod.com",
            "tcpHost": "tcp.myim-prod.com",
            "tcpPort": "9000",
            "accountFile": "accounts/load-5000.csv",
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

STATE_CSV_FIELDS = [
    "recordType",
    "conclusion",
    "readinessGate",
    "currentReadinessStatus",
    "currentReadinessReason",
    "currentReadinessRequestedSmoke",
    "currentReadinessRequestedBaseline",
    "currentReadinessRequestedFullAcceptance",
    "currentReadinessSmokeExitCode",
    "currentReadinessBaselineExitCode",
    "currentReadinessFullAcceptanceExitCode",
    "currentReadinessFullAcceptanceExpectedCampaign",
    "currentReadinessFullAcceptanceCampaign",
    "currentReadinessFullAcceptanceStatus",
    "currentReadinessFullAcceptanceFailures",
    "currentReadinessFullAcceptanceRequiredFailures",
    "currentReadinessFullAcceptanceAttempted",
    "currentReadinessFullAcceptanceSkipped",
    "currentReadinessOperatorNetworkPreflight",
    "productionEvidenceBlockerCount",
    "productionEvidenceBlockers",
    "domain",
]

def write_state_csv(path: Path, summary: dict) -> None:
    values = {field: "" for field in STATE_CSV_FIELDS}
    values["recordType"] = "summary"
    for field in STATE_CSV_FIELDS:
        if field in summary:
            value = summary.get(field)
            if isinstance(value, list):
                value = ",".join(str(item) for item in value)
            values[field] = "" if value is None else str(value)
    path.write_text(
        ",".join(STATE_CSV_FIELDS) + "\n"
        + ",".join(values[field] for field in STATE_CSV_FIELDS) + "\n",
        encoding="utf-8",
    )

blocked_command = "cd /tmp/rescue && ./verify-artifact.sh && cat ./entrypoint-rescue-plan.md"
blocked_dir = root / "blocked"
blocked_rescue_dir = blocked_dir / "current-node-access-rescue"
blocked_rescue_dir.mkdir(parents=True, exist_ok=True)
(blocked_rescue_dir / "summary.txt").write_text("status=BLOCKED\nentrypointDiagnosis=cloud_edge_http_403_intercept\n", encoding="utf-8")
(blocked_rescue_dir / "artifact-manifest.json").write_text('{"schemaVersion":1,"diagnosis":"cloud_edge_http_403_intercept"}\n', encoding="utf-8")
(blocked_dir / "current-node-access-rescue.tar.gz").write_text("synthetic rescue package\n", encoding="utf-8")
(blocked_dir / "current-node-access-rescue.tar.gz.verify.sh").write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
(blocked_dir / "current-node-access-rescue.tar.gz.sha256").write_text("synthetic sha\n", encoding="utf-8")
(blocked_dir / "current-node-access-rescue.tar.gz.receipt.json").write_text('{"schemaVersion":1}\n', encoding="utf-8")
write(blocked_dir / "entrypoint-probe.json", {
    "schemaVersion": 1,
    "failed": True,
    "diagnosis": "cloud_edge_http_403_intercept",
    "detail": "blocked",
    "blocker": {
        "type": "entrypoint",
        "severity": "P0",
        "preventsPerformanceEvidence": True,
        "action": "cloud_console_rescue_required",
    },
})
write(blocked_dir / "current-production-dashboard.json", {
    "summary": {
        "entrypointRescueBlocked": True,
        "entrypointRescueDiagnosis": "cloud_edge_http_403_intercept",
        "entrypointRescueAction": "cloud_console_rescue_required",
    },
    "nextCommand": blocked_command,
})
write(blocked_dir / "current-production-state-summary.json", {
    "summary": {
        "conclusion": "BLOCKED_ENTRYPOINT",
        "entrypointRescueDiagnosis": "cloud_edge_http_403_intercept",
        "currentReadinessOperatorNetworkPreflight": False,
    },
    "nextCommand": blocked_command,
})
write_state_csv(blocked_dir / "current-production-state-summary.csv", {
    "conclusion": "BLOCKED_ENTRYPOINT",
    "currentReadinessOperatorNetworkPreflight": False,
})
write(blocked_dir / "current-production-readiness.json", {
    "schemaVersion": 1,
    "status": "BLOCKED_ENTRYPOINT",
    "reason": "cloud_edge_http_403_intercept",
    "generatedAtEpoch": now,
    "target": common_target(),
    "profile": "normal-product-baseline",
    "evidencePolicy": common_evidence_policy(),
    "entrypoint": {
        "probeJSON": str(blocked_dir / "entrypoint-probe.json"),
        "failed": True,
        "diagnosis": "cloud_edge_http_403_intercept",
        "detail": "blocked",
        "blocker": {
            "type": "entrypoint",
            "severity": "P0",
            "preventsPerformanceEvidence": True,
            "action": "cloud_console_rescue_required",
        },
    },
    "requestedRuns": {
        "smoke": True,
        "smokeMode": "smoke",
        "productScenarioSuite": False,
        "productScenarioSuiteName": "recommended",
        "baseline": False,
        "fullAcceptance": False,
        "fullAcceptanceCampaign": "production-full-acceptance",
    },
    "artifacts": {
        "runDir": str(blocked_dir),
        "rescueSummary": str(blocked_rescue_dir / "summary.txt"),
        "rescueArtifactDir": str(blocked_rescue_dir),
        "rescueManifest": str(blocked_rescue_dir / "artifact-manifest.json"),
        "rescueTarball": str(blocked_dir / "current-node-access-rescue.tar.gz"),
        "rescueTarballVerifyScript": str(blocked_dir / "current-node-access-rescue.tar.gz.verify.sh"),
        "rescueTarballSha256": str(blocked_dir / "current-node-access-rescue.tar.gz.sha256"),
        "rescueTarballReceipt": str(blocked_dir / "current-node-access-rescue.tar.gz.receipt.json"),
        "dashboard": str(blocked_dir / "current-production-dashboard.md"),
        "stateSummary": str(blocked_dir / "current-production-state-summary.md"),
    },
    "runs": {"smokeExitCode": None, "suiteExitCode": None, "baselineExitCode": None},
})

pass_dir = root / "pass"
write(pass_dir / "entrypoint-probe.json", {
    "schemaVersion": 1,
    "failed": False,
    "diagnosis": "ok",
    "detail": "ok",
    "blocker": {"preventsPerformanceEvidence": False},
})
write(pass_dir / "current-production-dashboard.json", {
    "summary": {"entrypointRescueBlocked": False, "entrypointRescueDiagnosis": ""},
    "nextCommand": "",
})
write(pass_dir / "current-production-state-summary.json", {
    "summary": {"conclusion": "READY", "entrypointRescueDiagnosis": "", "currentReadinessOperatorNetworkPreflight": False},
    "nextCommand": "",
})
write_state_csv(pass_dir / "current-production-state-summary.csv", {
    "conclusion": "READY",
    "currentReadinessOperatorNetworkPreflight": False,
    "productionEvidenceBlockerCount": 0,
    "productionEvidenceBlockers": [],
})
(pass_dir / "normal-product-smoke.log").write_text("smoke pass\n", encoding="utf-8")
(pass_dir / "normal-product-baseline.log").write_text("baseline pass\n", encoding="utf-8")
write(pass_dir / "current-production-readiness.json", {
    "schemaVersion": 1,
    "status": "PASS",
    "reason": "entrypoint_and_requested_runs_passed",
    "generatedAtEpoch": now,
    "target": common_target(),
    "profile": "normal-product-baseline",
    "evidencePolicy": common_evidence_policy(),
    "entrypoint": {
        "probeJSON": str(pass_dir / "entrypoint-probe.json"),
        "failed": False,
        "diagnosis": "ok",
        "detail": "ok",
        "blocker": {"preventsPerformanceEvidence": False},
    },
    "requestedRuns": {
        "smoke": True,
        "smokeMode": "smoke",
        "productScenarioSuite": False,
        "productScenarioSuiteName": "recommended",
        "baseline": True,
        "fullAcceptance": False,
        "fullAcceptanceCampaign": "production-full-acceptance",
    },
    "artifacts": {
        "runDir": str(pass_dir),
        "dashboard": str(pass_dir / "current-production-dashboard.md"),
        "stateSummary": str(pass_dir / "current-production-state-summary.md"),
        "smokeLog": str(pass_dir / "normal-product-smoke.log"),
        "baselineLog": str(pass_dir / "normal-product-baseline.log"),
    },
    "runs": {"smokeExitCode": 0, "suiteExitCode": None, "baselineExitCode": 0},
})

full_pass_dir = root / "full-pass"
write(full_pass_dir / "entrypoint-probe.json", json.loads((pass_dir / "entrypoint-probe.json").read_text(encoding="utf-8")))
full_summary = {
    "entrypointRescueBlocked": False,
    "entrypointRescueDiagnosis": "",
    "currentReadinessStatus": "PASS",
    "currentReadinessReason": "entrypoint_and_requested_runs_passed",
    "currentReadinessRequestedSmoke": True,
    "currentReadinessRequestedBaseline": True,
    "currentReadinessRequestedFullAcceptance": True,
    "currentReadinessSmokeExitCode": 0,
    "currentReadinessBaselineExitCode": 0,
    "currentReadinessFullAcceptanceExitCode": 0,
    "currentReadinessFullAcceptanceExpectedCampaign": "production-full-acceptance",
    "currentReadinessFullAcceptanceCampaign": "production-full-acceptance",
    "currentReadinessFullAcceptanceStatus": "PASS",
    "currentReadinessFullAcceptanceFailures": 0,
    "currentReadinessFullAcceptanceRequiredFailures": 0,
    "currentReadinessFullAcceptanceAttempted": 6,
    "currentReadinessFullAcceptanceSkipped": 0,
    "currentReadinessOperatorNetworkPreflight": False,
}
write(full_pass_dir / "current-production-dashboard.json", {
    "summary": full_summary,
    "nextCommand": "",
})
state_full_summary = dict(full_summary)
state_full_summary["conclusion"] = "READY"
state_full_summary["productionEvidenceBlockerCount"] = 0
state_full_summary["productionEvidenceBlockers"] = []
write(full_pass_dir / "current-production-state-summary.json", {
    "summary": state_full_summary,
    "nextCommand": "",
})
write_state_csv(full_pass_dir / "current-production-state-summary.csv", state_full_summary)
(full_pass_dir / "normal-product-smoke.log").write_text("smoke pass\n", encoding="utf-8")
(full_pass_dir / "normal-product-baseline.log").write_text("baseline pass\n", encoding="utf-8")
(full_pass_dir / "production-full-acceptance.log").write_text("full acceptance pass\n", encoding="utf-8")
full_campaign_payload = full_acceptance_campaign_payload(full_pass_dir)
write(full_pass_dir / "production-full-acceptance-run.json", full_campaign_payload)
(full_pass_dir / "production-full-acceptance-runbook.md").write_text(build_runbook(full_campaign_payload), encoding="utf-8")
full_readiness_payload = {
    "schemaVersion": 1,
    "status": "PASS",
    "reason": "entrypoint_and_requested_runs_passed",
    "generatedAtEpoch": now,
    "target": common_target(),
    "profile": "normal-product-baseline",
    "evidencePolicy": {
        **common_evidence_policy(),
        "autoProductScenarioSuiteForPackageableAcceptance": True,
    },
    "entrypoint": {
        "probeJSON": str(full_pass_dir / "entrypoint-probe.json"),
        "failed": False,
        "diagnosis": "ok",
        "detail": "ok",
        "blocker": {"preventsPerformanceEvidence": False},
    },
    "requestedRuns": {
        "smoke": True,
        "smokeMode": "smoke",
        "productScenarioSuite": False,
        "productScenarioSuiteName": "recommended",
        "baseline": True,
        "fullAcceptance": True,
        "fullAcceptanceCampaign": "production-full-acceptance",
    },
    "artifacts": {
        "runDir": str(full_pass_dir),
        "dashboard": str(full_pass_dir / "current-production-dashboard.md"),
        "stateSummary": str(full_pass_dir / "current-production-state-summary.md"),
        "smokeLog": str(full_pass_dir / "normal-product-smoke.log"),
        "baselineLog": str(full_pass_dir / "normal-product-baseline.log"),
        "fullAcceptanceLog": str(full_pass_dir / "production-full-acceptance.log"),
        "fullAcceptanceRunJSON": str(full_pass_dir / "production-full-acceptance-run.json"),
        "fullAcceptanceRunbook": str(full_pass_dir / "production-full-acceptance-runbook.md"),
    },
    "runs": {"smokeExitCode": 0, "suiteExitCode": None, "baselineExitCode": 0, "fullAcceptanceExitCode": 0},
}
write(full_pass_dir / "current-production-readiness.json", full_readiness_payload)
(full_pass_dir / "current-production-readiness.md").write_text(build_readiness_markdown(full_readiness_payload), encoding="utf-8")

bad_full_campaign_dir = root / "bad-full-campaign"
bad_full_campaign_dir.mkdir(parents=True, exist_ok=True)
for name in [
    "entrypoint-probe.json",
    "current-production-dashboard.json",
    "current-production-state-summary.json",
    "current-production-state-summary.csv",
    "normal-product-smoke.log",
    "normal-product-baseline.log",
    "production-full-acceptance.log",
    "production-full-acceptance-runbook.md",
]:
    source = full_pass_dir / name
    target = bad_full_campaign_dir / name
    target.write_text(source.read_text(encoding="utf-8"), encoding="utf-8")
bad_full_receipt = json.loads((full_pass_dir / "current-production-readiness.json").read_text(encoding="utf-8"))
bad_full_receipt["entrypoint"]["probeJSON"] = str(bad_full_campaign_dir / "entrypoint-probe.json")
bad_full_receipt["artifacts"]["runDir"] = str(bad_full_campaign_dir)
bad_full_receipt["artifacts"]["dashboard"] = str(bad_full_campaign_dir / "current-production-dashboard.md")
bad_full_receipt["artifacts"]["stateSummary"] = str(bad_full_campaign_dir / "current-production-state-summary.md")
bad_full_receipt["artifacts"]["smokeLog"] = str(bad_full_campaign_dir / "normal-product-smoke.log")
bad_full_receipt["artifacts"]["baselineLog"] = str(bad_full_campaign_dir / "normal-product-baseline.log")
bad_full_receipt["artifacts"]["fullAcceptanceLog"] = str(bad_full_campaign_dir / "production-full-acceptance.log")
bad_full_receipt["artifacts"]["fullAcceptanceRunJSON"] = str(bad_full_campaign_dir / "production-full-acceptance-run.json")
bad_full_receipt["artifacts"]["fullAcceptanceRunbook"] = str(bad_full_campaign_dir / "production-full-acceptance-runbook.md")
write(bad_full_campaign_dir / "current-production-readiness.json", bad_full_receipt)
bad_campaign_payload = json.loads((full_pass_dir / "production-full-acceptance-run.json").read_text(encoding="utf-8"))
bad_campaign_payload["campaign"] = "non-large-group-release"
write(bad_full_campaign_dir / "production-full-acceptance-run.json", bad_campaign_payload)

bad_full_required_dir = root / "bad-full-required"
bad_full_required_dir.mkdir(parents=True, exist_ok=True)
for name in [
    "entrypoint-probe.json",
    "current-production-dashboard.json",
    "current-production-state-summary.json",
    "current-production-state-summary.csv",
    "normal-product-smoke.log",
    "normal-product-baseline.log",
    "production-full-acceptance.log",
    "production-full-acceptance-runbook.md",
]:
    source = full_pass_dir / name
    target = bad_full_required_dir / name
    target.write_text(source.read_text(encoding="utf-8"), encoding="utf-8")
bad_full_required_receipt = json.loads((full_pass_dir / "current-production-readiness.json").read_text(encoding="utf-8"))
bad_full_required_receipt["entrypoint"]["probeJSON"] = str(bad_full_required_dir / "entrypoint-probe.json")
bad_full_required_receipt["artifacts"]["runDir"] = str(bad_full_required_dir)
bad_full_required_receipt["artifacts"]["dashboard"] = str(bad_full_required_dir / "current-production-dashboard.md")
bad_full_required_receipt["artifacts"]["stateSummary"] = str(bad_full_required_dir / "current-production-state-summary.md")
bad_full_required_receipt["artifacts"]["smokeLog"] = str(bad_full_required_dir / "normal-product-smoke.log")
bad_full_required_receipt["artifacts"]["baselineLog"] = str(bad_full_required_dir / "normal-product-baseline.log")
bad_full_required_receipt["artifacts"]["fullAcceptanceLog"] = str(bad_full_required_dir / "production-full-acceptance.log")
bad_full_required_receipt["artifacts"]["fullAcceptanceRunJSON"] = str(bad_full_required_dir / "production-full-acceptance-run.json")
bad_full_required_receipt["artifacts"]["fullAcceptanceRunbook"] = str(bad_full_required_dir / "production-full-acceptance-runbook.md")
write(bad_full_required_dir / "current-production-readiness.json", bad_full_required_receipt)
bad_required_payload = json.loads((full_pass_dir / "production-full-acceptance-run.json").read_text(encoding="utf-8"))
bad_required_payload["requiredFailureCount"] = 1
write(bad_full_required_dir / "production-full-acceptance-run.json", bad_required_payload)

bad_state_csv_dir = root / "bad-state-csv"
bad_state_csv_dir.mkdir(parents=True, exist_ok=True)
for name in [
    "entrypoint-probe.json",
    "current-production-dashboard.json",
    "current-production-state-summary.json",
    "normal-product-smoke.log",
    "normal-product-baseline.log",
    "production-full-acceptance.log",
    "production-full-acceptance-run.json",
    "production-full-acceptance-runbook.md",
]:
    source = full_pass_dir / name
    target = bad_state_csv_dir / name
    target.write_text(source.read_text(encoding="utf-8"), encoding="utf-8")
bad_state_csv_receipt = json.loads((full_pass_dir / "current-production-readiness.json").read_text(encoding="utf-8"))
bad_state_csv_receipt["entrypoint"]["probeJSON"] = str(bad_state_csv_dir / "entrypoint-probe.json")
bad_state_csv_receipt["artifacts"]["runDir"] = str(bad_state_csv_dir)
bad_state_csv_receipt["artifacts"]["dashboard"] = str(bad_state_csv_dir / "current-production-dashboard.md")
bad_state_csv_receipt["artifacts"]["stateSummary"] = str(bad_state_csv_dir / "current-production-state-summary.md")
bad_state_csv_receipt["artifacts"]["smokeLog"] = str(bad_state_csv_dir / "normal-product-smoke.log")
bad_state_csv_receipt["artifacts"]["baselineLog"] = str(bad_state_csv_dir / "normal-product-baseline.log")
bad_state_csv_receipt["artifacts"]["fullAcceptanceLog"] = str(bad_state_csv_dir / "production-full-acceptance.log")
bad_state_csv_receipt["artifacts"]["fullAcceptanceRunJSON"] = str(bad_state_csv_dir / "production-full-acceptance-run.json")
bad_state_csv_receipt["artifacts"]["fullAcceptanceRunbook"] = str(bad_state_csv_dir / "production-full-acceptance-runbook.md")
write(bad_state_csv_dir / "current-production-readiness.json", bad_state_csv_receipt)
(bad_state_csv_dir / "current-production-state-summary.csv").write_text(
    "recordType,conclusion,readinessGate,currentReadinessStatus,currentReadinessReason,currentReadinessRequestedSmoke,currentReadinessRequestedBaseline,currentReadinessRequestedFullAcceptance,currentReadinessSmokeExitCode,currentReadinessBaselineExitCode,currentReadinessFullAcceptanceExitCode,currentReadinessFullAcceptanceExpectedCampaign,currentReadinessFullAcceptanceCampaign,currentReadinessFullAcceptanceStatus,currentReadinessFullAcceptanceFailures,currentReadinessFullAcceptanceRequiredFailures,currentReadinessFullAcceptanceAttempted,currentReadinessFullAcceptanceSkipped,currentReadinessOperatorNetworkPreflight,domain\n"
    "summary,READY,,PASS,entrypoint_and_requested_runs_passed,True,True,True,0,0,0,production-full-acceptance,non-large-group-release,PASS,0,0,6,0,False,\n",
    encoding="utf-8",
)

bad_dir = root / "bad-next"
write(bad_dir / "entrypoint-probe.json", json.loads((blocked_dir / "entrypoint-probe.json").read_text(encoding="utf-8")))
write(bad_dir / "current-production-dashboard.json", {
    "summary": {
        "entrypointRescueBlocked": True,
        "entrypointRescueDiagnosis": "cloud_edge_http_403_intercept",
        "entrypointRescueAction": "cloud_console_rescue_required",
    },
    "nextCommand": "BASE_URL=http://127.0.0.1:8080 ./http_entrypoint_probe.sh",
})
write(bad_dir / "current-production-state-summary.json", json.loads((blocked_dir / "current-production-state-summary.json").read_text(encoding="utf-8")))
(bad_dir / "current-production-state-summary.csv").write_text((blocked_dir / "current-production-state-summary.csv").read_text(encoding="utf-8"), encoding="utf-8")
bad_receipt = json.loads((blocked_dir / "current-production-readiness.json").read_text(encoding="utf-8"))
bad_receipt["entrypoint"]["probeJSON"] = str(bad_dir / "entrypoint-probe.json")
bad_receipt["artifacts"]["runDir"] = str(bad_dir)
bad_receipt["artifacts"]["dashboard"] = str(bad_dir / "current-production-dashboard.md")
bad_receipt["artifacts"]["stateSummary"] = str(bad_dir / "current-production-state-summary.md")
write(bad_dir / "current-production-readiness.json", bad_receipt)
bad_rescue_dir = root / "bad-rescue-sidecar"
bad_rescue_dir.mkdir(parents=True, exist_ok=True)
write(bad_rescue_dir / "entrypoint-probe.json", json.loads((blocked_dir / "entrypoint-probe.json").read_text(encoding="utf-8")))
write(bad_rescue_dir / "current-production-dashboard.json", json.loads((blocked_dir / "current-production-dashboard.json").read_text(encoding="utf-8")))
write(bad_rescue_dir / "current-production-state-summary.json", json.loads((blocked_dir / "current-production-state-summary.json").read_text(encoding="utf-8")))
(bad_rescue_dir / "current-production-state-summary.csv").write_text((blocked_dir / "current-production-state-summary.csv").read_text(encoding="utf-8"), encoding="utf-8")
bad_rescue_receipt = json.loads((blocked_dir / "current-production-readiness.json").read_text(encoding="utf-8"))
bad_rescue_receipt["entrypoint"]["probeJSON"] = str(bad_rescue_dir / "entrypoint-probe.json")
bad_rescue_receipt["artifacts"]["runDir"] = str(bad_rescue_dir)
bad_rescue_receipt["artifacts"]["dashboard"] = str(bad_rescue_dir / "current-production-dashboard.md")
bad_rescue_receipt["artifacts"]["stateSummary"] = str(bad_rescue_dir / "current-production-state-summary.md")
bad_rescue_receipt["artifacts"]["rescueSummary"] = str(blocked_rescue_dir / "summary.txt")
bad_rescue_receipt["artifacts"]["rescueTarball"] = str(blocked_dir / "current-node-access-rescue.tar.gz")
bad_rescue_receipt["artifacts"]["rescueTarballVerifyScript"] = str(blocked_dir / "current-node-access-rescue.tar.gz.verify.sh")
bad_rescue_receipt["artifacts"]["rescueTarballSha256"] = str(bad_rescue_dir / "missing-current-node-access-rescue.tar.gz.sha256")
bad_rescue_receipt["artifacts"]["rescueTarballReceipt"] = str(blocked_dir / "current-node-access-rescue.tar.gz.receipt.json")
write(bad_rescue_dir / "current-production-readiness.json", bad_rescue_receipt)
bad_reason_dir = root / "bad-reason"
bad_reason_dir.mkdir(parents=True, exist_ok=True)
write(bad_reason_dir / "entrypoint-probe.json", json.loads((pass_dir / "entrypoint-probe.json").read_text(encoding="utf-8")))
write(bad_reason_dir / "current-production-dashboard.json", json.loads((pass_dir / "current-production-dashboard.json").read_text(encoding="utf-8")))
write(bad_reason_dir / "current-production-state-summary.json", json.loads((pass_dir / "current-production-state-summary.json").read_text(encoding="utf-8")))
(bad_reason_dir / "current-production-state-summary.csv").write_text((pass_dir / "current-production-state-summary.csv").read_text(encoding="utf-8"), encoding="utf-8")
bad_reason_receipt = json.loads((pass_dir / "current-production-readiness.json").read_text(encoding="utf-8"))
bad_reason_receipt["status"] = "FAIL"
bad_reason_receipt["reason"] = "ambiguous_failure"
bad_reason_receipt["entrypoint"]["probeJSON"] = str(bad_reason_dir / "entrypoint-probe.json")
bad_reason_receipt["artifacts"]["runDir"] = str(bad_reason_dir)
bad_reason_receipt["artifacts"]["dashboard"] = str(bad_reason_dir / "current-production-dashboard.md")
bad_reason_receipt["artifacts"]["stateSummary"] = str(bad_reason_dir / "current-production-state-summary.md")
bad_reason_receipt["artifacts"]["smokeLog"] = str(bad_reason_dir / "normal-product-smoke.log")
bad_reason_receipt["artifacts"]["baselineLog"] = str(bad_reason_dir / "normal-product-baseline.log")
(bad_reason_dir / "normal-product-smoke.log").write_text("smoke pass\n", encoding="utf-8")
(bad_reason_dir / "normal-product-baseline.log").write_text("baseline pass\n", encoding="utf-8")
write(bad_reason_dir / "current-production-readiness.json", bad_reason_receipt)

bad_packageable_target_dir = root / "bad-packageable-target"
bad_packageable_target_dir.mkdir(parents=True, exist_ok=True)
write(bad_packageable_target_dir / "entrypoint-probe.json", json.loads((pass_dir / "entrypoint-probe.json").read_text(encoding="utf-8")))
write(bad_packageable_target_dir / "current-production-dashboard.json", json.loads((pass_dir / "current-production-dashboard.json").read_text(encoding="utf-8")))
write(bad_packageable_target_dir / "current-production-state-summary.json", json.loads((pass_dir / "current-production-state-summary.json").read_text(encoding="utf-8")))
(bad_packageable_target_dir / "current-production-state-summary.csv").write_text((pass_dir / "current-production-state-summary.csv").read_text(encoding="utf-8"), encoding="utf-8")
bad_packageable_target_receipt = json.loads((pass_dir / "current-production-readiness.json").read_text(encoding="utf-8"))
bad_packageable_target_receipt["target"]["baseURL"] = "http://47.106.103.10:8080"
bad_packageable_target_receipt["target"]["tcpHost"] = "47.106.103.10"
bad_packageable_target_receipt["entrypoint"]["probeJSON"] = str(bad_packageable_target_dir / "entrypoint-probe.json")
bad_packageable_target_receipt["artifacts"]["runDir"] = str(bad_packageable_target_dir)
bad_packageable_target_receipt["artifacts"]["dashboard"] = str(bad_packageable_target_dir / "current-production-dashboard.md")
bad_packageable_target_receipt["artifacts"]["stateSummary"] = str(bad_packageable_target_dir / "current-production-state-summary.md")
bad_packageable_target_receipt["artifacts"]["smokeLog"] = str(bad_packageable_target_dir / "normal-product-smoke.log")
bad_packageable_target_receipt["artifacts"]["baselineLog"] = str(bad_packageable_target_dir / "normal-product-baseline.log")
(bad_packageable_target_dir / "normal-product-smoke.log").write_text("smoke pass\n", encoding="utf-8")
(bad_packageable_target_dir / "normal-product-baseline.log").write_text("baseline pass\n", encoding="utf-8")
write(bad_packageable_target_dir / "current-production-readiness.json", bad_packageable_target_receipt)
PY
python3 "${SCRIPT_DIR}/perf_current_production_readiness_verify.py" \
  --readiness-json "${current_readiness_verify_dir}/blocked/current-production-readiness.json" \
  >"${current_readiness_verify_dir}/blocked-pass.log"
python3 "${SCRIPT_DIR}/perf_current_production_readiness_verify.py" \
  --readiness-json "${current_readiness_verify_dir}/pass/current-production-readiness.json" \
  >"${current_readiness_verify_dir}/pass-pass.log"
python3 "${SCRIPT_DIR}/perf_current_production_readiness_verify.py" \
  --readiness-json "${current_readiness_verify_dir}/full-pass/current-production-readiness.json" \
  >"${current_readiness_verify_dir}/full-pass.log"
bad_readiness_md_dir="${current_readiness_verify_dir}/bad-readiness-md"
mkdir -p "${bad_readiness_md_dir}"
for name in \
  entrypoint-probe.json \
  current-production-dashboard.json \
  current-production-state-summary.json \
  current-production-state-summary.csv \
  current-production-readiness.json \
  current-production-readiness.md \
  normal-product-smoke.log \
  normal-product-baseline.log \
  production-full-acceptance.log \
  production-full-acceptance-run.json \
  production-full-acceptance-runbook.md
do
  cp "${current_readiness_verify_dir}/full-pass/${name}" "${bad_readiness_md_dir}/${name}"
done
printf '\nmanual drift\n' >>"${bad_readiness_md_dir}/current-production-readiness.md"
python3 - "${bad_readiness_md_dir}/current-production-readiness.json" "${bad_readiness_md_dir}" <<'PY'
import json
import sys
from pathlib import Path

path, root = Path(sys.argv[1]), Path(sys.argv[2])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["entrypoint"]["probeJSON"] = str(root / "entrypoint-probe.json")
artifacts = payload["artifacts"]
artifacts["runDir"] = str(root)
artifacts["dashboard"] = str(root / "current-production-dashboard.md")
artifacts["stateSummary"] = str(root / "current-production-state-summary.md")
artifacts["smokeLog"] = str(root / "normal-product-smoke.log")
artifacts["baselineLog"] = str(root / "normal-product-baseline.log")
artifacts["fullAcceptanceLog"] = str(root / "production-full-acceptance.log")
artifacts["fullAcceptanceRunJSON"] = str(root / "production-full-acceptance-run.json")
artifacts["fullAcceptanceRunbook"] = str(root / "production-full-acceptance-runbook.md")
path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
if python3 "${SCRIPT_DIR}/perf_current_production_readiness_verify.py" \
  --readiness-json "${bad_readiness_md_dir}/current-production-readiness.json" \
  >"${current_readiness_verify_dir}/bad-readiness-md.log" 2>&1; then
  echo "current readiness verifier failed: mismatched readiness markdown unexpectedly passed" >&2
  exit 1
fi
grep -q 'reason=readiness_markdown_mismatch' "${current_readiness_verify_dir}/bad-readiness-md.log" || {
  echo "current readiness verifier failed: readiness markdown mismatch reason missing" >&2
  exit 1
}
relocated_dir="${current_readiness_verify_dir}/relocated-full-pass"
mkdir -p "${relocated_dir}/production-full-acceptance"
cp "${current_readiness_verify_dir}/full-pass/entrypoint-probe.json" "${relocated_dir}/entrypoint-probe.json"
cp "${current_readiness_verify_dir}/full-pass/current-production-dashboard.json" "${relocated_dir}/current-production-dashboard.json"
cp "${current_readiness_verify_dir}/full-pass/current-production-state-summary.json" "${relocated_dir}/current-production-state-summary.json"
cp "${current_readiness_verify_dir}/full-pass/current-production-state-summary.csv" "${relocated_dir}/current-production-state-summary.csv"
cp "${current_readiness_verify_dir}/full-pass/normal-product-smoke.log" "${relocated_dir}/normal-product-smoke.log"
cp "${current_readiness_verify_dir}/full-pass/normal-product-baseline.log" "${relocated_dir}/normal-product-baseline.log"
cp "${current_readiness_verify_dir}/full-pass/production-full-acceptance.log" "${relocated_dir}/production-full-acceptance.log"
cp "${current_readiness_verify_dir}/full-pass/production-full-acceptance-run.json" "${relocated_dir}/production-full-acceptance/product-campaign-run.json"
cp "${current_readiness_verify_dir}/full-pass/production-full-acceptance-runbook.md" "${relocated_dir}/production-full-acceptance/product-campaign-runbook.md"
printf '# Current Production Dashboard\n' >"${relocated_dir}/current-production-dashboard.md"
printf '# Current Production State Summary\n' >"${relocated_dir}/current-production-state-summary.md"
python3 - "${current_readiness_verify_dir}/full-pass/current-production-readiness.json" "${relocated_dir}/current-production-readiness.json" <<'PY'
import json
import sys
from pathlib import Path

source, target = map(Path, sys.argv[1:3])
payload = json.loads(source.read_text(encoding="utf-8"))
payload["entrypoint"]["probeJSON"] = "/missing-relocated-current-readiness/entrypoint-probe.json"
artifacts = payload["artifacts"]
artifacts["runDir"] = "/missing-relocated-current-readiness"
artifacts["dashboard"] = "/missing-relocated-current-readiness/current-production-dashboard.md"
artifacts["stateSummary"] = "/missing-relocated-current-readiness/current-production-state-summary.md"
artifacts["smokeLog"] = "/missing-relocated-current-readiness/normal-product-smoke.log"
artifacts["baselineLog"] = "/missing-relocated-current-readiness/normal-product-baseline.log"
artifacts["fullAcceptanceLog"] = "/missing-relocated-current-readiness/production-full-acceptance.log"
artifacts["fullAcceptanceRunJSON"] = "/missing-relocated-current-readiness/production-full-acceptance/product-campaign-run.json"
artifacts["fullAcceptanceRunbook"] = "/missing-relocated-current-readiness/production-full-acceptance/product-campaign-runbook.md"
target.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
python3 "${SCRIPT_DIR}/perf_current_production_readiness_verify.py" \
  --readiness-json "${relocated_dir}/current-production-readiness.json" \
  --evidence-dir "${relocated_dir}" \
  >"${current_readiness_verify_dir}/relocated-full-pass.log"
bad_full_runbook_dir="${current_readiness_verify_dir}/bad-full-runbook"
mkdir -p "${bad_full_runbook_dir}"
for name in \
  entrypoint-probe.json \
  current-production-dashboard.json \
  current-production-state-summary.json \
  current-production-state-summary.csv \
  normal-product-smoke.log \
  normal-product-baseline.log \
  production-full-acceptance.log \
  production-full-acceptance-run.json \
  production-full-acceptance-runbook.md
do
  cp "${current_readiness_verify_dir}/full-pass/${name}" "${bad_full_runbook_dir}/${name}"
done
printf '\nmanual drift\n' >>"${bad_full_runbook_dir}/production-full-acceptance-runbook.md"
python3 - "${current_readiness_verify_dir}/full-pass/current-production-readiness.json" "${bad_full_runbook_dir}/current-production-readiness.json" "${bad_full_runbook_dir}" <<'PY'
import json
import sys
from pathlib import Path

source, target, root = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
payload = json.loads(source.read_text(encoding="utf-8"))
payload["entrypoint"]["probeJSON"] = str(root / "entrypoint-probe.json")
artifacts = payload["artifacts"]
artifacts["runDir"] = str(root)
artifacts["dashboard"] = str(root / "current-production-dashboard.md")
artifacts["stateSummary"] = str(root / "current-production-state-summary.md")
artifacts["smokeLog"] = str(root / "normal-product-smoke.log")
artifacts["baselineLog"] = str(root / "normal-product-baseline.log")
artifacts["fullAcceptanceLog"] = str(root / "production-full-acceptance.log")
artifacts["fullAcceptanceRunJSON"] = str(root / "production-full-acceptance-run.json")
artifacts["fullAcceptanceRunbook"] = str(root / "production-full-acceptance-runbook.md")
target.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
if python3 "${SCRIPT_DIR}/perf_current_production_readiness_verify.py" \
  --readiness-json "${bad_full_runbook_dir}/current-production-readiness.json" \
  >"${current_readiness_verify_dir}/bad-full-runbook.log" 2>&1; then
  echo "current readiness verifier failed: mismatched full acceptance runbook unexpectedly passed" >&2
  exit 1
fi
grep -q 'reason=full_acceptance_runbook_mismatch' "${current_readiness_verify_dir}/bad-full-runbook.log" || {
  echo "current readiness verifier failed: full acceptance runbook mismatch reason missing" >&2
  exit 1
}
if python3 "${SCRIPT_DIR}/perf_current_production_readiness_verify.py" \
  --readiness-json "${current_readiness_verify_dir}/bad-full-campaign/current-production-readiness.json" \
  >"${current_readiness_verify_dir}/bad-full-campaign.log" 2>&1; then
  echo "current readiness verifier failed: mismatched full acceptance campaign unexpectedly passed" >&2
  exit 1
fi
grep -q 'reason=full_acceptance_campaign_mismatch' "${current_readiness_verify_dir}/bad-full-campaign.log" || {
  echo "current readiness verifier failed: full acceptance campaign mismatch reason missing" >&2
  exit 1
}
if python3 "${SCRIPT_DIR}/perf_current_production_readiness_verify.py" \
  --readiness-json "${current_readiness_verify_dir}/bad-full-required/current-production-readiness.json" \
  >"${current_readiness_verify_dir}/bad-full-required.log" 2>&1; then
  echo "current readiness verifier failed: full acceptance required failure unexpectedly passed" >&2
  exit 1
fi
grep -q 'reason=full_acceptance_campaign_required_failures' "${current_readiness_verify_dir}/bad-full-required.log" || {
  echo "current readiness verifier failed: full acceptance required failure reason missing" >&2
  exit 1
}
if python3 "${SCRIPT_DIR}/perf_current_production_readiness_verify.py" \
  --readiness-json "${current_readiness_verify_dir}/bad-state-csv/current-production-readiness.json" \
  >"${current_readiness_verify_dir}/bad-state-csv.log" 2>&1; then
  echo "current readiness verifier failed: mismatched state csv unexpectedly passed" >&2
  exit 1
fi
grep -q 'reason=full_acceptance_state_csv_mismatch' "${current_readiness_verify_dir}/bad-state-csv.log" || {
  echo "current readiness verifier failed: state csv mismatch reason missing" >&2
  exit 1
}
if python3 "${SCRIPT_DIR}/perf_current_production_readiness_verify.py" \
  --readiness-json "${current_readiness_verify_dir}/bad-next/current-production-readiness.json" \
  >"${current_readiness_verify_dir}/bad-next.log" 2>&1; then
  echo "current readiness verifier failed: mismatched next command unexpectedly passed" >&2
  exit 1
fi
grep -q 'reason=next_command_mismatch' "${current_readiness_verify_dir}/bad-next.log" || {
  echo "current readiness verifier failed: mismatch reason missing" >&2
  exit 1
}
if python3 "${SCRIPT_DIR}/perf_current_production_readiness_verify.py" \
  --readiness-json "${current_readiness_verify_dir}/bad-rescue-sidecar/current-production-readiness.json" \
  >"${current_readiness_verify_dir}/bad-rescue-sidecar.log" 2>&1; then
  echo "current readiness verifier failed: missing rescue sidecar unexpectedly passed" >&2
  exit 1
fi
grep -q 'reason=rescue_tarball_sha256_missing' "${current_readiness_verify_dir}/bad-rescue-sidecar.log" || {
  echo "current readiness verifier failed: missing rescue sidecar reason missing" >&2
  exit 1
}
if python3 "${SCRIPT_DIR}/perf_current_production_readiness_verify.py" \
  --readiness-json "${current_readiness_verify_dir}/bad-reason/current-production-readiness.json" \
  >"${current_readiness_verify_dir}/bad-reason.log" 2>&1; then
  echo "current readiness verifier failed: unknown failure reason unexpectedly passed" >&2
  exit 1
fi
grep -q 'reason=fail_reason_unknown' "${current_readiness_verify_dir}/bad-reason.log" || {
  echo "current readiness verifier failed: unknown reason failure missing" >&2
  exit 1
}
if python3 "${SCRIPT_DIR}/perf_current_production_readiness_verify.py" \
  --readiness-json "${current_readiness_verify_dir}/bad-packageable-target/current-production-readiness.json" \
  >"${current_readiness_verify_dir}/bad-packageable-target.log" 2>&1; then
  echo "current readiness verifier failed: bad packageable public target unexpectedly passed" >&2
  exit 1
fi
grep -q 'reason=public_base_url_https_required' "${current_readiness_verify_dir}/bad-packageable-target.log" || {
  echo "current readiness verifier failed: bad packageable public target reason missing" >&2
  exit 1
}

log "product campaign runner plan self-test"
PERF_DRY_RUN=true \
BASE_URL="https://chat.myim-prod.com" \
TCP_HOST="tcp.myim-prod.com" \
TCP_PORT="9000" \
ACCOUNT_FILE="${SCRIPT_DIR}/accounts/load-5000.csv" \
IM_INTERNAL_SECRET="validate-campaign-secret" \
IM_CONVERSATION_ID="00000000-0000-0000-0000-000000000000" \
python3 "${SCRIPT_DIR}/run_product_campaign.py" \
  --campaign non-large-group-release \
  --result-dir "${RESULT_DIR}/product-campaign-plan" \
  --json-output "${RESULT_DIR}/product-campaign-run.json" \
  --runbook-output "${RESULT_DIR}/product-campaign-runbook.md" >/dev/null
python3 - "${RESULT_DIR}/product-campaign-run.json" "${RESULT_DIR}/product-campaign-runbook.md" <<'PY'
import json
import sys
from pathlib import Path

run_json = Path(sys.argv[1])
runbook = Path(sys.argv[2])
payload = json.loads(run_json.read_text(encoding="utf-8"))
blob = run_json.read_text(encoding="utf-8") + runbook.read_text(encoding="utf-8")
if payload.get("finalStatus") != "PLANNED":
    raise SystemExit(f"Expected product campaign plan status PLANNED, got {payload.get('finalStatus')}.")
if payload.get("stageCount") != 7:
    raise SystemExit(f"Expected non-large-group-release to plan 7 stages, got {payload.get('stageCount')}.")
if payload.get("attemptedStageCount") != 0 or payload.get("skippedStageCount") != 0:
    raise SystemExit("Expected planned non-large-group-release to record zero attempted/skipped stages.")
if any(row.get("status") != "PLANNED" for row in payload.get("stages") or []):
    raise SystemExit("Expected every product campaign stage to be planned.")
if "validate-campaign-secret" in blob:
    raise SystemExit("Product campaign run artifacts leaked IM_INTERNAL_SECRET.")
if "IM_INTERNAL_SECRET=${IM_INTERNAL_SECRET:?set-IM_INTERNAL_SECRET}" not in blob:
    raise SystemExit("Expected product campaign runbook to include secret placeholder.")
commands = " ".join(str(row.get("command") or "") for row in payload.get("stages") or [])
if "SCENARIO_GROUPS=large-group" in commands:
    raise SystemExit("non-large-group-release planned a large-group scenario command.")
PY
cp "${RESULT_DIR}/product-campaign-runbook.md" "${RESULT_DIR}/product-campaign-runbook-bad.md"
printf '\nmanual drift\n' >>"${RESULT_DIR}/product-campaign-runbook-bad.md"
if python3 "${SCRIPT_DIR}/perf_product_campaign_artifacts_verify.py" \
  --campaign-run-json "${RESULT_DIR}/product-campaign-run.json" \
  --runbook "${RESULT_DIR}/product-campaign-runbook-bad.md" \
  --allow-planned \
  --require-production-gate-campaign \
  >"${RESULT_DIR}/product-campaign-runbook-bad.log" 2>&1; then
  echo "Expected modified product campaign runbook to fail exact markdown verification." >&2
  exit 1
fi
grep -q 'reason=runbook_markdown_mismatch' "${RESULT_DIR}/product-campaign-runbook-bad.log" || {
  echo "Expected runbook_markdown_mismatch failure reason." >&2
  exit 1
}
PERF_DRY_RUN=true \
BASE_URL="https://chat.myim-prod.com" \
TCP_HOST="tcp.myim-prod.com" \
TCP_PORT="9000" \
ACCOUNT_FILE="${SCRIPT_DIR}/accounts/load-5000.csv" \
IM_INTERNAL_SECRET="validate-campaign-secret" \
IM_CONVERSATION_ID="00000000-0000-0000-0000-000000000000" \
python3 "${SCRIPT_DIR}/run_product_campaign.py" \
  --campaign product-scenario-regression \
  --result-dir "${RESULT_DIR}/product-scenario-regression-plan" \
  --json-output "${RESULT_DIR}/product-scenario-regression-run.json" \
  --runbook-output "${RESULT_DIR}/product-scenario-regression-runbook.md" >/dev/null
python3 - "${RESULT_DIR}/product-scenario-regression-run.json" "${RESULT_DIR}/product-scenario-regression-runbook.md" <<'PY'
import json
import sys
from pathlib import Path

run_json = Path(sys.argv[1])
runbook = Path(sys.argv[2])
payload = json.loads(run_json.read_text(encoding="utf-8"))
blob = run_json.read_text(encoding="utf-8") + runbook.read_text(encoding="utf-8")
if payload.get("finalStatus") != "PLANNED":
    raise SystemExit(f"Expected product-scenario-regression status PLANNED, got {payload.get('finalStatus')}.")
if payload.get("stageCount") != 9:
    raise SystemExit(f"Expected product-scenario-regression to plan 9 stages, got {payload.get('stageCount')}.")
if payload.get("attemptedStageCount") != 0 or payload.get("skippedStageCount") != 0:
    raise SystemExit("Expected planned product-scenario-regression to record zero attempted/skipped stages.")
if payload.get("stopOnFailure") is not False:
    raise SystemExit("Expected product-scenario-regression to default stopOnFailure=false.")
if "stopOnFailure: `False`" not in blob:
    raise SystemExit("Expected product-scenario-regression runbook to show stopOnFailure false.")
commands = " ".join(str(row.get("command") or "") for row in payload.get("stages") or [])
if "SCENARIO_GROUPS=large-group" in commands:
    raise SystemExit("product-scenario-regression planned a large-group scenario command.")
for stage in [
    "account-security",
    "sync-read",
    "direct-message-workflow",
    "group-workflow",
    "social-governance",
    "media-ai-admin",
    "reliability-realtime",
]:
    if not any(row.get("id") == stage for row in payload.get("stages") or []):
        raise SystemExit(f"product-scenario-regression stage missing: {stage}")
PY
PERF_DRY_RUN=true \
BASE_URL="http://127.0.0.1:8080" \
TCP_HOST="127.0.0.1" \
TCP_PORT="9000" \
ACCOUNT_FILE="${SCRIPT_DIR}/accounts/load-5000.csv" \
IM_INTERNAL_SECRET="validate-campaign-secret" \
IM_CONVERSATION_ID="00000000-0000-0000-0000-000000000000" \
python3 "${SCRIPT_DIR}/run_product_campaign.py" \
  --campaign product-scenario-acceptance \
  --result-dir "${RESULT_DIR}/product-scenario-acceptance-plan" \
  --json-output "${RESULT_DIR}/product-scenario-acceptance-run.json" \
  --runbook-output "${RESULT_DIR}/product-scenario-acceptance-runbook.md" >/dev/null
python3 - "${RESULT_DIR}/product-scenario-acceptance-run.json" "${RESULT_DIR}/product-scenario-acceptance-runbook.md" <<'PY'
import json
import sys
from pathlib import Path

run_json = Path(sys.argv[1])
runbook = Path(sys.argv[2])
payload = json.loads(run_json.read_text(encoding="utf-8"))
blob = run_json.read_text(encoding="utf-8") + runbook.read_text(encoding="utf-8")
if payload.get("finalStatus") != "PLANNED":
    raise SystemExit(f"Expected product-scenario-acceptance status PLANNED, got {payload.get('finalStatus')}.")
if payload.get("stageCount") != 9:
    raise SystemExit(f"Expected product-scenario-acceptance to plan 9 stages, got {payload.get('stageCount')}.")
if payload.get("attemptedStageCount") != 0 or payload.get("skippedStageCount") != 0:
    raise SystemExit("Expected planned product-scenario-acceptance to record zero attempted/skipped stages.")
if payload.get("stopOnFailure") is not False:
    raise SystemExit("Expected product-scenario-acceptance to default stopOnFailure=false.")
if "stopOnFailure: `False`" not in blob:
    raise SystemExit("Expected product-scenario-acceptance runbook to show stopOnFailure false.")
commands = " ".join(str(row.get("command") or "") for row in payload.get("stages") or [])
if "SCENARIO_GROUPS=large-group" in commands:
    raise SystemExit("product-scenario-acceptance planned a large-group scenario command.")
for stage in [
    "real-world-baseline",
    "daily-usage",
    "account-and-sync",
    "message-workflows",
    "ordinary-groups",
    "social-media-governance",
    "recovery-and-realtime",
    "normal-product-baseline",
]:
    if not any(row.get("id") == stage for row in payload.get("stages") or []):
        raise SystemExit(f"product-scenario-acceptance stage missing: {stage}")
PY
PERF_DRY_RUN=true \
BASE_URL="https://chat.myim-prod.com" \
TCP_HOST="tcp.myim-prod.com" \
TCP_PORT="9000" \
ACCOUNT_FILE="${SCRIPT_DIR}/accounts/load-5000.csv" \
IM_INTERNAL_SECRET="validate-campaign-secret" \
IM_CONVERSATION_ID="00000000-0000-0000-0000-000000000000" \
python3 "${SCRIPT_DIR}/run_product_campaign.py" \
  --campaign production-full-acceptance \
  --result-dir "${RESULT_DIR}/production-full-acceptance-plan" \
  --json-output "${RESULT_DIR}/production-full-acceptance-run.json" \
  --runbook-output "${RESULT_DIR}/production-full-acceptance-runbook.md" >/dev/null
python3 "${SCRIPT_DIR}/perf_product_campaign_artifacts_verify.py" \
  --campaign-run-json "${RESULT_DIR}/production-full-acceptance-run.json" \
  --runbook "${RESULT_DIR}/production-full-acceptance-runbook.md" \
  --allow-planned \
  --require-production-gate-campaign >/dev/null
python3 - "${RESULT_DIR}/production-full-acceptance-run.json" "${RESULT_DIR}/production-full-acceptance-bad-capacity-run.json" <<'PY'
import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
payload = json.loads(source.read_text(encoding="utf-8"))
payload["execute"] = True
payload["finalStatus"] = "PASS"
payload["attemptedStageCount"] = len(payload.get("stages") or [])
payload["skippedStageCount"] = 0
payload["failureCount"] = 0
payload["requiredFailureCount"] = 0
for row in payload.get("stages") or []:
    row["status"] = "PASS"
    row["returnCode"] = 0
    if row.get("id") == "normal-product-capacity":
        row["status"] = "FAIL"
        row["returnCode"] = 1
target.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
if python3 "${SCRIPT_DIR}/perf_product_campaign_artifacts_verify.py" \
  --campaign-run-json "${RESULT_DIR}/production-full-acceptance-bad-capacity-run.json" \
  --runbook "${RESULT_DIR}/production-full-acceptance-runbook.md" \
  --require-pass \
  --require-production-gate-campaign \
  >"${RESULT_DIR}/production-full-acceptance-bad-capacity.log" 2>&1; then
  echo "Expected failed capacity stage to fail production-full-acceptance verification." >&2
  exit 1
fi
grep -q 'reason=production_full_acceptance_stage_not_pass' "${RESULT_DIR}/production-full-acceptance-bad-capacity.log" || {
  echo "Expected production_full_acceptance_stage_not_pass failure reason." >&2
  exit 1
}

log "product campaign materialize self-test"
PRODUCT_CAMPAIGN_MATERIALIZE_SELF_TEST=true \
  python3 "${SCRIPT_DIR}/run_product_campaign.py" >/dev/null
log "product campaign execution self-test"
PRODUCT_CAMPAIGN_EXECUTION_SELF_TEST=true \
  python3 "${SCRIPT_DIR}/run_product_campaign.py" >/dev/null

log "product campaign artifact production-gate self-test"
campaign_artifact_test_dir="${RESULT_DIR}/product-campaign-artifact-production-gate"
rm -rf "${campaign_artifact_test_dir}"
mkdir -p "${campaign_artifact_test_dir}/stage"
printf 'stage pass\n' >"${campaign_artifact_test_dir}/stage/stage.log"
python3 - "${campaign_artifact_test_dir}" "${SCRIPT_DIR}" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
script_dir = Path(sys.argv[2])
sys.path.insert(0, str(script_dir))
from run_product_campaign import build_runbook

rescue_dir = root / "rescue-artifact"
rescue_dir.mkdir(parents=True, exist_ok=True)
(rescue_dir / "summary.txt").write_text(
    "status=PASS\n"
    "rescuePlanAction=cloud_console_rescue_required\n"
    "entrypointDiagnosis=cloud_edge_http_403_intercept\n",
    encoding="utf-8",
)
(rescue_dir / "verify-artifact.sh").write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
(rescue_dir / "verify-package.sh").write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
(root / "rescue-artifact.tar.gz").write_text("fake tarball\n", encoding="utf-8")
run_json = root / "product-campaign-run.json"
payload = {
    "schemaVersion": 1,
    "campaign": "product-scenario-regression",
    "description": "non-production regression campaign fixture",
    "execute": True,
    "stopOnFailure": False,
    "resultDir": str(root),
    "runIDPrefix": "artifact-self-test",
    "target": {
        "baseURL": "http://127.0.0.1:8080",
        "tcpHost": "127.0.0.1",
        "tcpPort": "9000",
        "accountFile": "",
        "hasConversationID": "false",
        "hasInternalSecret": "true",
    },
    "finalStatus": "PASS",
    "failureCount": 0,
    "requiredFailureCount": 0,
    "attemptedStageCount": 1,
    "skippedStageCount": 0,
    "stageCount": 1,
    "stages": [
        {
            "index": 1,
            "id": "entrypoint",
            "runner": "product-plan",
            "required": True,
            "isolated": False,
            "status": "PASS",
            "returnCode": 0,
            "runDir": str(root / "stage"),
            "log": str(root / "stage" / "stage.log"),
            "command": "env BASE_URL=http://127.0.0.1:8080 TCP_HOST=127.0.0.1 TCP_PORT=9000 PRODUCT_TEST_PHASES=entrypoint IM_INTERNAL_SECRET=<redacted> ./run_product_test_plan.sh",
            "evidence": "self-test",
            "rescueArtifact": {
                "status": "PASS",
                "dir": str(rescue_dir),
                "summary": str(rescue_dir / "summary.txt"),
                "tarball": str(root / "rescue-artifact.tar.gz"),
                "verifyScript": str(rescue_dir / "verify-artifact.sh"),
                "packageVerifyScript": str(rescue_dir / "verify-package.sh"),
                "rescuePlanAction": "cloud_console_rescue_required",
                "entrypointDiagnosis": "cloud_edge_http_403_intercept",
            },
        }
    ],
}
run_json.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
(root / "product-campaign-runbook.md").write_text(build_runbook(payload), encoding="utf-8")
PY
python3 "${SCRIPT_DIR}/perf_product_campaign_artifacts_verify.py" \
  --campaign-run-json "${campaign_artifact_test_dir}/product-campaign-run.json" \
  --runbook "${campaign_artifact_test_dir}/product-campaign-runbook.md" \
  --require-pass >/dev/null
python3 - "${campaign_artifact_test_dir}/product-campaign-runbook.md" "${campaign_artifact_test_dir}/missing-rescue-runbook.md" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
text = source.read_text(encoding="utf-8")
start = text.index("## Entrypoint Rescue")
end = text.index("Secret values are represented")
target.write_text(text[:start] + text[end:], encoding="utf-8")
PY
if python3 "${SCRIPT_DIR}/perf_product_campaign_artifacts_verify.py" \
  --campaign-run-json "${campaign_artifact_test_dir}/product-campaign-run.json" \
  --runbook "${campaign_artifact_test_dir}/missing-rescue-runbook.md" \
  --require-pass \
  >"${campaign_artifact_test_dir}/missing-rescue-runbook.log" 2>&1; then
  echo "Expected missing rescue runbook section to fail campaign artifact verification." >&2
  exit 1
fi
grep -q 'reason=runbook_rescue_section_missing' "${campaign_artifact_test_dir}/missing-rescue-runbook.log" || {
  echo "Expected runbook_rescue_section_missing failure reason." >&2
  exit 1
}
python3 - "${campaign_artifact_test_dir}/product-campaign-run.json" "${campaign_artifact_test_dir}/bad-rescue-product-campaign-run.json" <<'PY'
import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
payload = json.loads(source.read_text(encoding="utf-8"))
payload["stages"][0]["rescueArtifact"]["summary"] = str(source.parent / "rescue-artifact" / "missing-summary.txt")
target.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
if python3 "${SCRIPT_DIR}/perf_product_campaign_artifacts_verify.py" \
  --campaign-run-json "${campaign_artifact_test_dir}/bad-rescue-product-campaign-run.json" \
  --runbook "${campaign_artifact_test_dir}/product-campaign-runbook.md" \
  --require-pass \
  >"${campaign_artifact_test_dir}/bad-rescue.log" 2>&1; then
  echo "Expected missing rescue artifact summary to fail campaign artifact verification." >&2
  exit 1
fi
grep -q 'reason=rescue_artifact_summary_missing' "${campaign_artifact_test_dir}/bad-rescue.log" || {
  echo "Expected rescue_artifact_summary_missing failure reason." >&2
  exit 1
}
if python3 "${SCRIPT_DIR}/perf_product_campaign_artifacts_verify.py" \
  --campaign-run-json "${campaign_artifact_test_dir}/product-campaign-run.json" \
  --runbook "${campaign_artifact_test_dir}/product-campaign-runbook.md" \
  --require-pass \
  --require-portable-stage-logs \
  >"${campaign_artifact_test_dir}/non-portable-stage-log.log" 2>&1; then
  echo "Expected absolute campaign stage log paths to fail portable artifact verification." >&2
  exit 1
fi
grep -q 'reason=stage_run_dir_not_portable' "${campaign_artifact_test_dir}/non-portable-stage-log.log" || {
  echo "Expected stage_run_dir_not_portable failure reason." >&2
  exit 1
}
python3 - "${campaign_artifact_test_dir}/product-campaign-run.json" "${campaign_artifact_test_dir}/bad-target-product-campaign-run.json" <<'PY'
import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
payload = json.loads(source.read_text(encoding="utf-8"))
payload["stages"][0]["command"] = payload["stages"][0]["command"].replace("TCP_HOST=127.0.0.1", "TCP_HOST=10.0.0.1")
target.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
if python3 "${SCRIPT_DIR}/perf_product_campaign_artifacts_verify.py" \
  --campaign-run-json "${campaign_artifact_test_dir}/bad-target-product-campaign-run.json" \
  --runbook "${campaign_artifact_test_dir}/product-campaign-runbook.md" \
  --require-pass \
  >"${campaign_artifact_test_dir}/bad-target.log" 2>&1; then
  echo "Expected mismatched campaign target to fail campaign artifact verification." >&2
  exit 1
fi
grep -q 'reason=stage_command_target_mismatch' "${campaign_artifact_test_dir}/bad-target.log" || {
  echo "Expected stage_command_target_mismatch failure reason." >&2
  exit 1
}
python3 - "${campaign_artifact_test_dir}/product-campaign-run.json" "${campaign_artifact_test_dir}/local-production-target-product-campaign-run.json" <<'PY'
import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
payload = json.loads(source.read_text(encoding="utf-8"))
payload["campaign"] = "non-large-group-release"
target.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
if python3 "${SCRIPT_DIR}/perf_product_campaign_artifacts_verify.py" \
  --campaign-run-json "${campaign_artifact_test_dir}/local-production-target-product-campaign-run.json" \
  --runbook "${campaign_artifact_test_dir}/product-campaign-runbook.md" \
  --require-pass \
  --require-production-gate-campaign \
  >"${campaign_artifact_test_dir}/local-production-target.log" 2>&1; then
  echo "Expected production-gate campaign with local target to fail campaign artifact verification." >&2
  exit 1
fi
grep -q 'reason=campaign_target_base_url_https_required' "${campaign_artifact_test_dir}/local-production-target.log" || {
  echo "Expected campaign_target_base_url_https_required failure reason." >&2
  exit 1
}
rm -f "${campaign_artifact_test_dir}/stage/stage.log"
if python3 "${SCRIPT_DIR}/perf_product_campaign_artifacts_verify.py" \
  --campaign-run-json "${campaign_artifact_test_dir}/product-campaign-run.json" \
  --runbook "${campaign_artifact_test_dir}/product-campaign-runbook.md" \
  --require-pass \
  >"${campaign_artifact_test_dir}/missing-stage-log.log" 2>&1; then
  echo "Expected missing PASS stage log to fail campaign artifact verification." >&2
  exit 1
fi
grep -q 'reason=stage_log_missing' "${campaign_artifact_test_dir}/missing-stage-log.log" || {
  echo "Expected stage_log_missing failure reason." >&2
  exit 1
}
printf 'stage pass\n' >"${campaign_artifact_test_dir}/stage/stage.log"
if python3 "${SCRIPT_DIR}/perf_product_campaign_artifacts_verify.py" \
  --campaign-run-json "${campaign_artifact_test_dir}/product-campaign-run.json" \
  --runbook "${campaign_artifact_test_dir}/product-campaign-runbook.md" \
  --require-pass \
  --require-production-gate-campaign \
  >"${campaign_artifact_test_dir}/non-production-campaign.log" 2>&1; then
  echo "Expected non-production campaign to fail production-gate verification." >&2
  exit 1
fi
grep -q 'reason=campaign_not_production_gate' "${campaign_artifact_test_dir}/non-production-campaign.log" || {
  echo "Expected campaign_not_production_gate failure reason." >&2
  exit 1
}

log "default profile audit"
python3 "${SCRIPT_DIR}/perf_default_profile_audit.py" \
  --repo-root "${SCRIPT_DIR}/../.." \
  --output "${RESULT_DIR}/default-profile-audit.md" \
  --json-output "${RESULT_DIR}/default-profile-audit.json" \
  --csv-output "${RESULT_DIR}/default-profile-audit.csv" \
  --strict >/dev/null
python3 "${SCRIPT_DIR}/perf_default_profile_audit.py" \
  --verify-json "${RESULT_DIR}/default-profile-audit.json" \
  --verify-md "${RESULT_DIR}/default-profile-audit.md" \
  --strict >/dev/null
cp "${RESULT_DIR}/default-profile-audit.md" "${RESULT_DIR}/default-profile-audit-bad-md.md"
perl -0pi -e 's/- status: `PASS`/- auditStatus: `PASS`/' "${RESULT_DIR}/default-profile-audit-bad-md.md"
if python3 "${SCRIPT_DIR}/perf_default_profile_audit.py" \
  --verify-json "${RESULT_DIR}/default-profile-audit.json" \
  --verify-md "${RESULT_DIR}/default-profile-audit-bad-md.md" \
  --strict >"${RESULT_DIR}/default-profile-audit-bad-md.log" 2>&1; then
  echo "Expected default profile audit verifier to reject mismatched markdown." >&2
  exit 1
fi
grep -q 'markdown_mismatch' "${RESULT_DIR}/default-profile-audit-bad-md.log" || {
  echo "Expected default profile audit bad markdown fixture to report markdown_mismatch." >&2
  exit 1
}

log "docs audit"
python3 "${SCRIPT_DIR}/perf_docs_audit.py" \
  --readme "${SCRIPT_DIR}/README.md" \
  --matrix-script "${SCRIPT_DIR}/run_perf_scenarios.sh" \
  --profile-catalog "${SCRIPT_DIR}/perf_production_profiles.json" \
  --output "${RESULT_DIR}/docs-audit.md" \
  --json-output "${RESULT_DIR}/docs-audit.json" \
  --csv-output "${RESULT_DIR}/docs-audit.csv" \
  --strict >/dev/null
python3 "${SCRIPT_DIR}/perf_docs_audit.py" \
  --verify-json "${RESULT_DIR}/docs-audit.json" \
  --verify-md "${RESULT_DIR}/docs-audit.md" \
  --readme "${SCRIPT_DIR}/README.md" \
  --matrix-script "${SCRIPT_DIR}/run_perf_scenarios.sh" \
  --profile-catalog "${SCRIPT_DIR}/perf_production_profiles.json" >/dev/null
cp "${RESULT_DIR}/docs-audit.md" "${RESULT_DIR}/docs-audit-bad.md"
python3 - "${RESULT_DIR}/docs-audit-bad.md" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text(text.replace("- status:", "- docsStatus:", 1), encoding="utf-8")
PY
if python3 "${SCRIPT_DIR}/perf_docs_audit.py" \
  --verify-json "${RESULT_DIR}/docs-audit.json" \
  --verify-md "${RESULT_DIR}/docs-audit-bad.md" \
  --readme "${SCRIPT_DIR}/README.md" \
  --matrix-script "${SCRIPT_DIR}/run_perf_scenarios.sh" \
  --profile-catalog "${SCRIPT_DIR}/perf_production_profiles.json" \
  >"${RESULT_DIR}/docs-audit-bad-md.log" 2>&1; then
  echo "Expected docs audit verify to fail on mismatched markdown." >&2
  exit 1
fi
grep -q 'reason=markdown_summary_mismatch' "${RESULT_DIR}/docs-audit-bad-md.log" || {
  echo "Expected docs audit bad-md self-test to report markdown_summary_mismatch." >&2
  exit 1
}
cp "${RESULT_DIR}/docs-audit.json" "${RESULT_DIR}/docs-audit-bad-input.json"
python3 - "${RESULT_DIR}/docs-audit-bad-input.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)
payload.setdefault("inputs", {}).setdefault("readme", {})["sha256"] = "0" * 64
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
if python3 "${SCRIPT_DIR}/perf_docs_audit.py" \
  --verify-json "${RESULT_DIR}/docs-audit-bad-input.json" \
  --readme "${SCRIPT_DIR}/README.md" \
  --matrix-script "${SCRIPT_DIR}/run_perf_scenarios.sh" \
  --profile-catalog "${SCRIPT_DIR}/perf_production_profiles.json" \
  >"${RESULT_DIR}/docs-audit-bad-input.log" 2>&1; then
  echo "Expected docs audit verify to fail on mismatched input sha." >&2
  exit 1
fi
grep -q 'reason=input_sha_mismatch' "${RESULT_DIR}/docs-audit-bad-input.log" || {
  echo "Expected docs audit bad-input self-test to report input_sha_mismatch." >&2
  exit 1
}
python3 - "${SCRIPT_DIR}" <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, str(Path(sys.argv[1]).resolve()))
from perf_docs_audit import audit_public_http_8080_examples, audit_stale_public_ip_examples

issues = []
sample = (
    "prod=http://47.106.103.10 "
    "old=http://120.25.106.200 "
    "bad=http://im.example.com:8080 "
    "local=http://127.0.0.1:8080"
)
audit_public_http_8080_examples(sample, label="self-test", issues=issues)
audit_stale_public_ip_examples(sample, label="self-test", issues=issues)
kinds = [item["kind"] for item in issues]
if kinds.count("public-http-8080-doc") != 1:
    raise SystemExit(f"Expected exactly one public-http-8080-doc issue, got {issues!r}")
if kinds.count("stale-public-ip-doc") != 2:
    raise SystemExit(f"Expected two stale-public-ip-doc issues, got {issues!r}")
PY

log "deploy docs security group audit"
python3 - "${SCRIPT_DIR}/../.." <<'PY'
import sys
from pathlib import Path

repo = Path(sys.argv[1]).resolve()
docs = {
    "deploy-readme": repo / "deploy/ubuntu/README.md",
    "aliyun-bootstrap-runbook": repo / "docs/imserver-aliyun-local-binary-deploy.md",
}
required_snippets = {
    "public_https": "`443/tcp` | `0.0.0.0/0`",
    "public_tcp_gateway": "`9000/tcp` | `0.0.0.0/0`",
    "ssh_admin_cidr": "`22/tcp` | `<your-admin-public-ip>/32`",
    "rdp_deleted": "`3389/tcp` | any | Delete",
    "bootstrap_http_removed": "`8080/tcp` | any public CIDR | Delete",
    "internal_ports_private": "`5432`, `6379`, `9092`, `8081`, `8082`, `18080`",
}

errors = []
for label, path in docs.items():
    text = path.read_text(encoding="utf-8")
    for key, snippet in required_snippets.items():
        if snippet not in text:
            errors.append(f"{label}:{key}:missing:{snippet}")
    if "console screenshot alone is not enough" not in text and "A screenshot is useful" not in text:
        errors.append(f"{label}:machine_readable_evidence_note:missing")

if errors:
    for error in errors:
        print(f"deploy-docs-security-group result=fail reason={error}", file=sys.stderr)
    raise SystemExit(1)
PY

log "scenario catalog"
python3 "${SCRIPT_DIR}/perf_scenario_catalog.py" \
  --script "${SCRIPT_DIR}/run_perf_scenarios.sh" \
  --output "${RESULT_DIR}/scenario-catalog.md" \
  --json-output "${RESULT_DIR}/scenario-catalog.json" \
  --csv-output "${RESULT_DIR}/scenario-catalog.csv" >/dev/null

if bool_enabled "${VALIDATE_DRY_RUN}"; then
  log "runner dry-run artifacts"
  requirement_preflight_dir="${RESULT_DIR}/requirement-preflight"
  mkdir -p "${requirement_preflight_dir}"

  set +e
  PERF_DRY_RUN=true \
  PERF_PREFLIGHT=true \
  RUN_ID="missing-account-file" \
  RESULT_ROOT="${requirement_preflight_dir}" \
  BASE_URL="http://127.0.0.1:8080" \
  TCP_HOST="127.0.0.1" \
  SCENARIOS="login-smoke online-idle-1000" \
  "${SCRIPT_DIR}/run_perf_scenarios.sh" >"${requirement_preflight_dir}/missing-account-file.log" 2>&1
  missing_account_rc=$?
  set -e
  if [[ "${missing_account_rc}" != "2" ]]; then
    echo "Expected missing ACCOUNT_FILE preflight to exit 2, got ${missing_account_rc}." >&2
    exit 1
  fi
  grep -q "ACCOUNT_FILE is required" "${requirement_preflight_dir}/missing-account-file.log" || {
    echo "Expected missing ACCOUNT_FILE preflight message." >&2
    exit 1
  }
  if [[ -d "${requirement_preflight_dir}/missing-account-file/login-smoke" ]]; then
    echo "Expected scenario requirement preflight to stop before creating scenario artifacts." >&2
    exit 1
  fi
  if [[ ! -f "${requirement_preflight_dir}/missing-account-file/report.json" ]]; then
    echo "Expected missing ACCOUNT_FILE preflight to generate report.json." >&2
    exit 1
  fi
  python3 - "${requirement_preflight_dir}/missing-account-file/report.json" "${requirement_preflight_dir}/missing-account-file/evidence.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
with open(sys.argv[2]) as handle:
    evidence = json.load(handle)
scenarios = data.get("scenarios") or []
if len(scenarios) != 1:
    raise SystemExit(f"Expected one preflight scenario artifact, got {len(scenarios)}.")
row = scenarios[0]
if row.get("name") != "preflight-scenario-requirements":
    raise SystemExit(f"Expected preflight-scenario-requirements, got {row.get('name')}.")
if row.get("category") != "preflight" or row.get("status") != "FAIL":
    raise SystemExit(f"Expected failed preflight scenario, got {row}.")
if not any("ACCOUNT_FILE is required" in reason for reason in row.get("reasons") or []):
    raise SystemExit("Expected ACCOUNT_FILE requirement reason in report.")
if evidence.get("outcome") != "BLOCKED_PREREQUISITES":
    raise SystemExit(f"Expected BLOCKED_PREREQUISITES evidence outcome, got {evidence.get('outcome')}.")
issues = evidence.get("issues") or []
if not issues or issues[0].get("issueType") != "prerequisites":
    raise SystemExit("Expected prerequisites issue type in evidence.")
PY

  small_account_file="${requirement_preflight_dir}/small-accounts.csv"
  for index in $(seq 1 2); do
    printf 'tiny-%04d@example.com,password1234\n' "${index}"
  done >"${small_account_file}"
  set +e
  PERF_DRY_RUN=true \
  PERF_PREFLIGHT=true \
  RUN_ID="small-account-file" \
  RESULT_ROOT="${requirement_preflight_dir}" \
  BASE_URL="http://127.0.0.1:8080" \
  TCP_HOST="127.0.0.1" \
  ACCOUNT_FILE="${small_account_file}" \
  SCENARIOS="online-idle-1000" \
  "${SCRIPT_DIR}/run_perf_scenarios.sh" >"${requirement_preflight_dir}/small-account-file.log" 2>&1
  small_account_rc=$?
  set -e
  if [[ "${small_account_rc}" != "2" ]]; then
    echo "Expected small ACCOUNT_FILE preflight to exit 2, got ${small_account_rc}." >&2
    exit 1
  fi
  grep -q "needs >= 1000 usable rows" "${requirement_preflight_dir}/small-account-file.log" || {
    echo "Expected account row-count preflight message." >&2
    exit 1
  }
  grep -q "Report: ${requirement_preflight_dir}/small-account-file/report.md" "${requirement_preflight_dir}/small-account-file.log" || {
    echo "Expected account row-count preflight to print report path." >&2
    exit 1
  }

  fifty_account_file="${requirement_preflight_dir}/fifty-accounts.csv"
  for index in $(seq 1 50); do
    printf 'group-%04d@example.com,password1234\n' "${index}"
  done >"${fifty_account_file}"
  set +e
  PERF_DRY_RUN=true \
  PERF_PREFLIGHT=true \
  RUN_ID="missing-conversation-id" \
  RESULT_ROOT="${requirement_preflight_dir}" \
  BASE_URL="http://127.0.0.1:8080" \
  TCP_HOST="127.0.0.1" \
  ACCOUNT_FILE="${fifty_account_file}" \
  SCENARIOS="login-smoke group-delivery-50-5" \
  "${SCRIPT_DIR}/run_perf_scenarios.sh" >"${requirement_preflight_dir}/missing-conversation-id.log" 2>&1
  missing_conversation_rc=$?
  set -e
  if [[ "${missing_conversation_rc}" != "2" ]]; then
    echo "Expected missing IM_CONVERSATION_ID preflight to exit 2, got ${missing_conversation_rc}." >&2
    exit 1
  fi
  grep -q "IM_CONVERSATION_ID is required" "${requirement_preflight_dir}/missing-conversation-id.log" || {
    echo "Expected missing IM_CONVERSATION_ID preflight message." >&2
    exit 1
  }
  if [[ -d "${requirement_preflight_dir}/missing-conversation-id/login-smoke" ]]; then
    echo "Expected missing conversation preflight to stop before creating scenario artifacts." >&2
    exit 1
  fi
  python3 - "${requirement_preflight_dir}/missing-conversation-id/report.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
row = (data.get("scenarios") or [{}])[0]
if row.get("name") != "preflight-scenario-requirements":
    raise SystemExit("Expected missing conversation to generate scenario requirement artifact.")
if not any("IM_CONVERSATION_ID is required" in reason for reason in row.get("reasons") or []):
    raise SystemExit("Expected IM_CONVERSATION_ID requirement reason in report.")
PY

  python3 - "${RESULT_DIR}" <<'PY'
import json
import os
import time
import sys
from pathlib import Path

root = Path(sys.argv[1])
now = int(time.time())
fixtures = [
    (
        root / "current-production-readiness-old" / "current-production-readiness.json",
        {
            "schemaVersion": 1,
            "generatedAtEpoch": now - 60,
            "status": "FAIL",
            "reason": "old-readiness-should-not-be-selected",
            "target": {"baseURL": "https://old.example.com", "tcpHost": "old.example.com", "tcpPort": "9000"},
        },
        now - 60,
    ),
    (
        root / "current-production-readiness-new" / "current-production-readiness.json",
        {
            "schemaVersion": 1,
            "generatedAtEpoch": now,
            "status": "PASS",
            "reason": "latest-readiness-selected",
            "target": {"baseURL": "https://new.example.com", "tcpHost": "new.example.com", "tcpPort": "9000"},
        },
        now,
    ),
    (
        root / "production-acceptance" / "old" / "production-acceptance.json",
        {
            "schemaVersion": 1,
            "status": "FAIL",
            "reason": "old-acceptance-should-not-be-selected",
            "level": "full",
            "target": {"baseURL": "https://old.example.com", "tcpHost": "old.example.com", "tcpPort": "9000", "requiredAccountRows": 10000},
            "policy": {"operatorNetworkPreflight": True},
            "artifacts": {"packagePresent": False, "packageBytes": 0},
        },
        now - 60,
    ),
    (
        root / "production-acceptance" / "new" / "production-acceptance.json",
        {
            "schemaVersion": 1,
            "status": "PASS",
            "reason": "latest-acceptance-selected",
            "level": "full",
            "target": {"baseURL": "https://new.example.com", "tcpHost": "new.example.com", "tcpPort": "9000", "requiredAccountRows": 10000},
            "policy": {"operatorNetworkPreflight": True},
            "artifacts": {"packagePresent": True, "packageBytes": 1234},
        },
        now,
    ),
]
for path, payload, mtime in fixtures:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload), encoding="utf-8")
    os.utime(path, (mtime, mtime))
PY

  PERF_DRY_RUN=true \
  PERF_PREFLIGHT=false \
  RUN_ID="validate-load-tests-dry-run" \
  RESULT_ROOT="${RESULT_DIR}" \
  BASE_URL="http://127.0.0.1:8080" \
  TCP_HOST="127.0.0.1" \
  ACCOUNT_FILE="${SCRIPT_DIR}/accounts/load-1000.csv" \
  IM_INTERNAL_SECRET="validate" \
  IM_CONVERSATION_ID="00000000-0000-0000-0000-000000000000" \
  SCENARIOS="timeline-pagination-smoke" \
  "${SCRIPT_DIR}/run_perf_scenarios.sh" >/dev/null

  python3 - "${RESULT_DIR}/production-gate.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
requirements = data.get("requirements") or {}
if int(requirements.get("maxEvidenceAgeSeconds") or 0) != 604800:
    raise SystemExit(f"Expected run_perf_scenarios production gate to forward max evidence age, got {requirements}.")
PY

  python3 - "${RESULT_DIR}/state-summary.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
summary = data.get("summary") or {}
if summary.get("currentReadinessReason") != "latest-readiness-selected":
    raise SystemExit(f"Expected state summary to select latest current readiness receipt, got {summary.get('currentReadinessReason')}.")
if summary.get("currentReadinessFreshnessStatus") != "PASS":
    raise SystemExit(f"Expected latest current readiness receipt freshness PASS, got {summary.get('currentReadinessFreshnessStatus')}.")
if summary.get("productionAcceptanceReason") != "latest-acceptance-selected":
    raise SystemExit(f"Expected state summary to select latest production acceptance receipt, got {summary.get('productionAcceptanceReason')}.")
if summary.get("productionAcceptancePackagePresent") is not True:
    raise SystemExit("Expected state summary to select latest production acceptance package metadata.")
PY

  negative_gate_dir="${RESULT_DIR}/negative-production-gate-runner"
  rm -rf "${negative_gate_dir}"
  if PERF_DRY_RUN=true \
    PERF_PREFLIGHT=false \
    RUN_ID="negative-production-gate" \
    RESULT_ROOT="${negative_gate_dir}" \
    BASE_URL="http://127.0.0.1:8080" \
    TCP_HOST="127.0.0.1" \
    ACCOUNT_FILE="${SCRIPT_DIR}/accounts/load-1000.csv" \
    IM_INTERNAL_SECRET="validate" \
    IM_CONVERSATION_ID="00000000-0000-0000-0000-000000000000" \
    SCENARIOS="timeline-pagination-smoke" \
    PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=-1 \
      "${SCRIPT_DIR}/run_perf_scenarios.sh" \
      >"${RESULT_DIR}/negative-production-gate-runner.log" 2>&1; then
    echo "Expected run_perf_scenarios to fail when production gate max age is negative." >&2
    exit 1
  fi
  grep -q 'reason=production_gate_artifact_missing' "${RESULT_DIR}/negative-production-gate-runner.log" || {
    echo "Expected run_perf_scenarios production gate artifact failure reason." >&2
    exit 1
  }
  grep -q 'reason=invalid_max_evidence_age' "${negative_gate_dir}/negative-production-gate/production-gate.log" || {
    echo "Expected run_perf_scenarios production gate log to include invalid max age reason." >&2
    exit 1
  }

  python3 - "${RESULT_DIR}/validate-load-tests-dry-run/evidence.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
if data.get("outcome") != "INCOMPLETE_ARTIFACTS":
    raise SystemExit(f"Expected INCOMPLETE_ARTIFACTS dry-run outcome, got {data.get('outcome')}")
PY

  python3 - "${RESULT_DIR}/scenario-status.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
counts = data.get("latestStatusCounts") or {}
if int(counts.get("NEVER_RUN") or 0) <= 0:
    raise SystemExit("Expected scenario-status to report NEVER_RUN scenarios from the matrix.")
PY

  python3 "${SCRIPT_DIR}/perf_scenario_status.py" \
    --results-dir "${RESULT_DIR}" \
    --matrix-script "${SCRIPT_DIR}/run_perf_scenarios.sh" \
    --filter-target \
    --base-url "http://127.0.0.1:8080" \
    --tcp-host "127.0.0.1" \
    --tcp-port "9000" \
    --json-output "${RESULT_DIR}/scenario-status-target-match.json" >/dev/null
  python3 "${SCRIPT_DIR}/perf_scenario_status.py" \
    --results-dir "${RESULT_DIR}" \
    --matrix-script "${SCRIPT_DIR}/run_perf_scenarios.sh" \
    --filter-target \
    --base-url "http://different-target.example:8080" \
    --tcp-host "different-target.example" \
    --tcp-port "9000" \
    --json-output "${RESULT_DIR}/scenario-status-target-mismatch.json" >/dev/null
  python3 - "${RESULT_DIR}/scenario-status-target-match.json" "${RESULT_DIR}/scenario-status-target-mismatch.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    match = json.load(handle)
with open(sys.argv[2]) as handle:
    mismatch = json.load(handle)
match_rows = {row.get("scenario"): row for row in match.get("scenarios") or []}
mismatch_rows = {row.get("scenario"): row for row in mismatch.get("scenarios") or []}
if not (match.get("targetFilter") or {}).get("enabled"):
    raise SystemExit("Expected matching scenario-status target filter to be enabled.")
if match_rows.get("timeline-pagination-smoke", {}).get("latestStatus") != "UNKNOWN":
    raise SystemExit("Expected matching target to retain dry-run scenario evidence.")
if mismatch_rows.get("timeline-pagination-smoke", {}).get("latestStatus") != "NEVER_RUN":
    raise SystemExit("Expected mismatched target to ignore dry-run scenario evidence.")
PY

  python3 - "${RESULT_DIR}/next-actions.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
counts = data.get("priorityCounts") or {}
if int(counts.get("P2") or 0) <= 0:
    raise SystemExit("Expected next-actions to report at least one P2 action for dry-run or never-run scenarios.")
PY

  local_proxy_report_dir="${RESULT_DIR}-local-proxy-entrypoint-report"
  local_proxy_run_dir="${local_proxy_report_dir}/run-local-proxy"
  rm -rf "${local_proxy_report_dir}"
  mkdir -p "${local_proxy_run_dir}/local-proxy-scenario"
  cat >"${local_proxy_run_dir}/local-proxy-scenario/scenario.json" <<'JSON'
{"name":"local-proxy-scenario","category":"preflight","target":"http","baseURL":"http://203.0.113.10:8080","tcpHost":"203.0.113.10","tcpPort":"9000"}
JSON
  printf '1\n' >"${local_proxy_run_dir}/local-proxy-scenario/exit-code.txt"
  cat >"${local_proxy_run_dir}/local-proxy-scenario/stdout.log" <<'LOG'
HTTP structured entrypoint probe:
diagnosis=local_network_proxy_http_403_intercept nginxHealthStatus=403 healthStatus=403 loginStatus=403 localNetworkWarning=tun_route localRouteInterface=utun99 localRouteGateway=198.18.0.1 detail=The local route or proxy environment can intercept traffic before it reaches the server.
LOG
  python3 "${SCRIPT_DIR}/perf_report.py" \
    --run-dir "${local_proxy_run_dir}" \
    --json-output "${local_proxy_run_dir}/report.json" \
    --output "${local_proxy_run_dir}/report.md" \
    --csv-output "${local_proxy_run_dir}/report.csv" >/dev/null || true
  if python3 "${SCRIPT_DIR}/perf_gate.py" \
    --report "${local_proxy_run_dir}/report.json" \
    >"${local_proxy_report_dir}/gate.log" 2>&1; then
    echo "Expected local proxy entrypoint report to fail the performance gate." >&2
    exit 1
  fi
  python3 "${SCRIPT_DIR}/perf_scenario_status.py" \
    --results-dir "${local_proxy_report_dir}" \
    --json-output "${local_proxy_report_dir}/scenario-status.json" \
    --output "${local_proxy_report_dir}/scenario-status.md" \
    --csv-output "${local_proxy_report_dir}/scenario-status.csv" >/dev/null || true
  python3 "${SCRIPT_DIR}/perf_next_actions.py" \
    --scenario-status "${local_proxy_report_dir}/scenario-status.json" \
    --json-output "${local_proxy_report_dir}/next-actions.json" \
    --output "${local_proxy_report_dir}/next-actions.md" \
    --csv-output "${local_proxy_report_dir}/next-actions.csv" >/dev/null || true
  python3 "${SCRIPT_DIR}/perf_triage.py" \
    --report "${local_proxy_run_dir}/report.json" \
    --json-output "${local_proxy_report_dir}/triage.json" \
    --output "${local_proxy_report_dir}/triage.md" \
    --csv-output "${local_proxy_report_dir}/triage.csv" >/dev/null
  python3 - \
    "${local_proxy_run_dir}/report.json" \
    "${local_proxy_report_dir}/next-actions.json" \
    "${local_proxy_report_dir}/triage.json" \
    "${local_proxy_report_dir}/gate.log" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
next_actions = json.load(open(sys.argv[2], encoding="utf-8"))
triage = json.load(open(sys.argv[3], encoding="utf-8"))
gate = open(sys.argv[4], encoding="utf-8").read()
scenario = (report.get("scenarios") or [{}])[0]
hint = scenario.get("optimizationHint") or ""
if "Disable local TUN/proxy" not in hint:
    raise SystemExit(f"Expected local proxy optimization hint, got {hint!r}")
actions = next_actions.get("actions") or []
if not actions or actions[0].get("actionType") != "entrypoint-blocker":
    raise SystemExit(f"Expected local proxy next action to be an entrypoint blocker, got {actions[:1]}")
if actions[0].get("priority") != "P0":
    raise SystemExit(f"Expected local proxy next action priority P0, got {actions[0].get('priority')}")
if "Disable the local TUN/proxy" not in (actions[0].get("action") or ""):
    raise SystemExit(f"Expected local proxy next action text, got {actions[0].get('action')!r}")
issues = triage.get("issues") or []
if not issues or issues[0].get("issueType") != "entrypoint":
    raise SystemExit(f"Expected local proxy triage issue to be entrypoint, got {issues[:1]}")
if "Disable the local TUN/proxy" not in (issues[0].get("action") or ""):
    raise SystemExit(f"Expected local proxy triage action text, got {issues[0].get('action')!r}")
if "entrypoint failure" not in gate:
    raise SystemExit(f"Expected local proxy gate to report entrypoint failure, got {gate!r}")
PY

  python3 - "${RESULT_DIR}/run-plan.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
if data.get("status") not in {"READY", "BLOCKED_BY_P0"}:
    raise SystemExit(f"Unexpected run-plan status: {data.get('status')}")
PY

  python3 - "${RESULT_DIR}/scenario-catalog.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
summary = data.get("summary") or {}
scenarios = data.get("scenarios") or []
if int(summary.get("scenarioCount") or 0) <= 0:
    raise SystemExit("Expected scenario catalog to include matrix scenarios.")
if int(summary.get("domainCount") or 0) <= 0:
    raise SystemExit("Expected scenario catalog to include product domains.")
by_name = {row.get("scenario"): row for row in scenarios}
expected_profiles = {
    "online-chat-mix-5000-10": ("online-chat-mix", "tcp-pair-delivery"),
    "direct-burst-1000-100": ("direct-burst", "tcp-pair-delivery"),
    "direct-burst-1000-200": ("direct-burst", "tcp-pair-delivery"),
}
for scenario, (profile, category) in expected_profiles.items():
    row = by_name.get(scenario)
    if not row:
        raise SystemExit(f"Expected scenario catalog to include {scenario}.")
    if row.get("profile") != profile:
        raise SystemExit(f"Expected {scenario} profile {profile}, got {row.get('profile')}.")
    if row.get("category") != category:
        raise SystemExit(f"Expected {scenario} category {category}, got {row.get('category')}.")
custom_tcp = [
    row.get("scenario")
    for row in scenarios
    if str(row.get("category") or "").startswith("tcp-") and row.get("profile") == "custom"
]
if custom_tcp:
    raise SystemExit(f"Expected TCP scenarios to have explicit profiles, got custom profiles for {custom_tcp}.")
PY

  python3 "${SCRIPT_DIR}/perf_domain_backlog.py" \
    --scenario-catalog "${RESULT_DIR}/scenario-catalog.json" \
    --next-actions "${RESULT_DIR}/next-actions.json" \
    --output "${RESULT_DIR}/domain-backlog.md" \
    --json-output "${RESULT_DIR}/domain-backlog.json" \
    --csv-output "${RESULT_DIR}/domain-backlog.csv" >/dev/null || true

  python3 - "${RESULT_DIR}/domain-backlog.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
summary = data.get("summary") or {}
if int(summary.get("domainCount") or 0) <= 0:
    raise SystemExit("Expected domain backlog to include domains.")
if int(summary.get("openActionCount") or 0) <= 0:
    raise SystemExit("Expected domain backlog to include open actions for dry-run results.")
PY

  python3 "${SCRIPT_DIR}/perf_domain_run_plan.py" \
    --domain-backlog "${RESULT_DIR}/domain-backlog.json" \
    --base-url "http://127.0.0.1:8080" \
    --tcp-host "127.0.0.1" \
    --tcp-port "9000" \
    --account-file "${SCRIPT_DIR}/accounts/load-1000.csv" \
    --conversation-id "00000000-0000-0000-0000-000000000000" \
    --internal-secret "validate" \
    --output "${RESULT_DIR}/domain-run-plan.md" \
    --json-output "${RESULT_DIR}/domain-run-plan.json" >/dev/null || true

  python3 - "${RESULT_DIR}/domain-run-plan.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
if data.get("status") not in {"READY", "BLOCKED_BY_P0", "NO_SCENARIOS"}:
    raise SystemExit(f"Unexpected domain-run-plan status: {data.get('status')}")
PY

  stale_blocker_dir="${RESULT_DIR}/stale-blocker-domain-plan"
  mkdir -p "${stale_blocker_dir}"
  python3 - "${stale_blocker_dir}/domain-backlog.json" <<'PY'
import json
import time
import sys

path = sys.argv[1]
payload = {
    "summary": {
        "domainCount": 1,
        "openActionCount": 2,
        "globalBlockerCount": 1,
        "priorityCounts": {"P0": 1, "P1": 0, "P2": 1, "P3": 0, "P4": 0},
        "scenarioCount": 1,
    },
    "globalBlockers": [{
        "priority": "P0",
        "actionType": "entrypoint-blocker",
        "scenario": "preflight-http-login",
        "category": "preflight",
        "latestStatus": "FAIL",
        "runCount": 1,
        "latestRunID": "stale-preflight",
        "latestRunDir": "/tmp/stale-preflight",
        "latestMtime": time.time() - 3600,
        "latestBaseURL": "http://127.0.0.1:8080",
        "latestTCPHost": "127.0.0.1",
        "latestTCPPort": "9000",
        "reason": "stale failure",
        "action": "Run http_entrypoint_probe.sh.",
    }],
    "domains": [{
        "domain": "client-sync",
        "topPriority": "P2",
        "hint": "rerun client sync",
        "actions": [{
            "priority": "P2",
            "actionType": "rerun-missing-artifacts",
            "scenario": "client-sync-mix-smoke",
            "category": "http-client-sync-mix",
            "latestStatus": "UNKNOWN",
            "runCount": 1,
            "latestRunID": "dry-run",
            "reason": "no runtime evidence",
            "action": "Rerun.",
        }],
    }],
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY
  python3 "${SCRIPT_DIR}/perf_domain_run_plan.py" \
    --domain-backlog "${stale_blocker_dir}/domain-backlog.json" \
    --base-url "http://127.0.0.1:8080" \
    --account-file "${SCRIPT_DIR}/accounts/load-1000.csv" \
    --output "${stale_blocker_dir}/default-domain-run-plan.md" \
    --json-output "${stale_blocker_dir}/default-domain-run-plan.json" >/dev/null || true
  python3 "${SCRIPT_DIR}/perf_domain_run_plan.py" \
    --domain-backlog "${stale_blocker_dir}/domain-backlog.json" \
    --base-url "http://127.0.0.1:8080" \
    --account-file "${SCRIPT_DIR}/accounts/load-1000.csv" \
    --blocker-max-age-seconds 60 \
    --output "${stale_blocker_dir}/fresh-domain-run-plan.md" \
    --json-output "${stale_blocker_dir}/fresh-domain-run-plan.json" >/dev/null || true
  python3 "${SCRIPT_DIR}/perf_domain_run_plan.py" \
    --domain-backlog "${stale_blocker_dir}/domain-backlog.json" \
    --base-url "http://new-target.example:8080" \
    --tcp-host "new-target.example" \
    --tcp-port "9000" \
    --account-file "${SCRIPT_DIR}/accounts/load-1000.csv" \
    --ignore-blockers-for-different-target \
    --output "${stale_blocker_dir}/target-domain-run-plan.md" \
    --json-output "${stale_blocker_dir}/target-domain-run-plan.json" >/dev/null || true
  python3 - "${stale_blocker_dir}/default-domain-run-plan.json" "${stale_blocker_dir}/fresh-domain-run-plan.json" "${stale_blocker_dir}/target-domain-run-plan.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    default = json.load(handle)
with open(sys.argv[2]) as handle:
    fresh = json.load(handle)
with open(sys.argv[3]) as handle:
    target = json.load(handle)
if default.get("status") != "BLOCKED_BY_P0":
    raise SystemExit(f"Expected default stale blocker behavior to remain blocking, got {default.get('status')}")
if fresh.get("status") != "READY":
    raise SystemExit(f"Expected stale blocker max age plan to be READY, got {fresh.get('status')}")
if len(fresh.get("staleGlobalBlockers") or []) != 1:
    raise SystemExit("Expected stale global blocker to be retained for audit.")
if fresh.get("globalBlockers"):
    raise SystemExit("Expected stale global blocker not to remain active.")
if target.get("status") != "READY":
    raise SystemExit(f"Expected different-target blocker plan to be READY, got {target.get('status')}")
if len(target.get("staleGlobalBlockers") or []) != 1:
    raise SystemExit("Expected different-target blocker to be retained for audit.")
if "target differs" not in str((target.get("staleGlobalBlockers") or [{}])[0].get("staleReason") or ""):
    raise SystemExit("Expected different-target stale reason.")
PY

  python3 "${SCRIPT_DIR}/perf_domain_scorecard.py" \
    --domain-backlog "${RESULT_DIR}/domain-backlog.json" \
    --domain-run-plan "${RESULT_DIR}/domain-run-plan.json" \
    --output "${RESULT_DIR}/domain-scorecard.md" \
    --json-output "${RESULT_DIR}/domain-scorecard.json" \
    --csv-output "${RESULT_DIR}/domain-scorecard.csv" >/dev/null

  python3 - "${RESULT_DIR}/domain-scorecard.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
summary = data.get("summary") or {}
if summary.get("overallStatus") not in {"READY", "BLOCKED_BY_P0", "NEEDS_OPTIMIZATION", "NEEDS_RUNTIME_EVIDENCE", "NEEDS_BASELINE_CAPACITY", "NEEDS_TRIAGE", "NO_SCENARIOS"}:
    raise SystemExit(f"Unexpected domain-scorecard status: {summary.get('overallStatus')}")
if int(summary.get("domainCount") or 0) <= 0:
    raise SystemExit("Expected domain scorecard to include domains.")
PY

  python3 "${SCRIPT_DIR}/perf_prereq_audit.py" \
    --scenario-catalog "${RESULT_DIR}/scenario-catalog.json" \
    --domain-run-plan "${RESULT_DIR}/domain-run-plan.json" \
    --base-url "http://127.0.0.1:8080" \
    --tcp-host "127.0.0.1" \
    --tcp-port "9000" \
    --account-file "${SCRIPT_DIR}/accounts/load-1000.csv" \
    --conversation-id "00000000-0000-0000-0000-000000000000" \
    --internal-secret "validate" \
    --output "${RESULT_DIR}/prereq-audit.md" \
    --json-output "${RESULT_DIR}/prereq-audit.json" \
    --csv-output "${RESULT_DIR}/prereq-audit.csv" >/dev/null

  python3 - "${RESULT_DIR}/prereq-audit.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
summary = data.get("summary") or {}
if summary.get("overallStatus") not in {"READY", "WARN", "BLOCKED", "NO_PLANNED_SCENARIOS"}:
    raise SystemExit(f"Unexpected prereq-audit status: {summary.get('overallStatus')}")
if int(summary.get("scenarioCount") or 0) <= 0:
    raise SystemExit("Expected prereq audit to include planned scenarios.")
PY

  python3 "${SCRIPT_DIR}/perf_domain_compare.py" \
    --base "${RESULT_DIR}/validate-load-tests-dry-run/report.json" \
    --current "${RESULT_DIR}/validate-load-tests-dry-run/report.json" \
    --scenario-catalog "${RESULT_DIR}/scenario-catalog.json" \
    --output "${RESULT_DIR}/domain-compare.md" \
    --json-output "${RESULT_DIR}/domain-compare.json" \
    --csv-output "${RESULT_DIR}/domain-compare.csv" >/dev/null

  python3 - "${RESULT_DIR}/domain-compare.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
if int(data.get("domainRegressionCount") or 0) != 0:
    raise SystemExit("Expected self-compare to have no domain regressions.")
if int(data.get("domainCount") or 0) <= 0:
    raise SystemExit("Expected domain compare to include domains.")
PY

  python3 "${SCRIPT_DIR}/perf_readiness_gate.py" \
    --coverage-json "${RESULT_DIR}/coverage.json" \
    --route-audit-json "${RESULT_DIR}/route-audit.json" \
    --matrix-audit-json "${RESULT_DIR}/matrix-audit.json" \
    --domain-scorecard-json "${RESULT_DIR}/domain-scorecard.json" \
    --prereq-audit-json "${RESULT_DIR}/prereq-audit.json" \
    --allow-runtime-evidence-gap \
    --output "${RESULT_DIR}/readiness-gate.txt" \
    --json-output "${RESULT_DIR}/readiness-gate.json" >/dev/null

  python3 - "${RESULT_DIR}/readiness-gate.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
if data.get("status") not in {"PASS", "FAIL"}:
    raise SystemExit(f"Unexpected readiness gate status: {data.get('status')}")
if not data.get("checks"):
    raise SystemExit("Expected readiness gate checks.")
PY

  python3 "${SCRIPT_DIR}/perf_slo_report.py" \
    --report "${RESULT_DIR}/validate-load-tests-dry-run/report.json" \
    --output "${RESULT_DIR}/slo.md" \
    --json-output "${RESULT_DIR}/slo.json" \
    --csv-output "${RESULT_DIR}/slo.csv" >/dev/null

  python3 - "${RESULT_DIR}/slo.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
summary = data.get("summary") or {}
if int(summary.get("scenarioCount") or 0) <= 0:
    raise SystemExit("Expected SLO report to include scenarios.")
if summary.get("status") not in {"PASS", "FAIL", "UNKNOWN"}:
    raise SystemExit(f"Unexpected SLO status: {summary.get('status')}")
PY

  python3 "${SCRIPT_DIR}/perf_slo_status.py" \
    --results-dir "${RESULT_DIR}" \
    --matrix-script "${SCRIPT_DIR}/run_perf_scenarios.sh" \
    --output "${RESULT_DIR}/slo-status.md" \
    --json-output "${RESULT_DIR}/slo-status.json" \
    --csv-output "${RESULT_DIR}/slo-status.csv" >/dev/null || true

  python3 - "${RESULT_DIR}/slo-status.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
counts = data.get("latestSLOStatusCounts") or {}
if int(data.get("matrixScenarioCount") or 0) <= 0:
    raise SystemExit("Expected SLO status to include matrix scenarios.")
if not any(int(counts.get(status) or 0) > 0 for status in ("FAIL", "UNKNOWN", "NEVER_RUN", "PASS")):
    raise SystemExit("Expected SLO status counts.")
if int(data.get("scenarioCount") or 0) < int(data.get("matrixScenarioCount") or 0):
    raise SystemExit("Expected total SLO scenario count to include matrix scenarios.")
PY

  python3 "${SCRIPT_DIR}/perf_slo_status.py" \
    --results-dir "${RESULT_DIR}" \
    --matrix-script "${SCRIPT_DIR}/run_perf_scenarios.sh" \
    --filter-target \
    --base-url "http://127.0.0.1:8080" \
    --tcp-host "127.0.0.1" \
    --tcp-port "9000" \
    --json-output "${RESULT_DIR}/slo-status-target-match.json" >/dev/null || true
  python3 "${SCRIPT_DIR}/perf_slo_status.py" \
    --results-dir "${RESULT_DIR}" \
    --matrix-script "${SCRIPT_DIR}/run_perf_scenarios.sh" \
    --filter-target \
    --base-url "http://different-target.example:8080" \
    --tcp-host "different-target.example" \
    --tcp-port "9000" \
    --json-output "${RESULT_DIR}/slo-status-target-mismatch.json" >/dev/null || true
  python3 - "${RESULT_DIR}/slo-status-target-match.json" "${RESULT_DIR}/slo-status-target-mismatch.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    match = json.load(handle)
with open(sys.argv[2]) as handle:
    mismatch = json.load(handle)
match_rows = {row.get("scenario"): row for row in match.get("scenarios") or []}
mismatch_rows = {row.get("scenario"): row for row in mismatch.get("scenarios") or []}
if not (match.get("targetFilter") or {}).get("enabled"):
    raise SystemExit("Expected matching SLO target filter to be enabled.")
if match_rows.get("timeline-pagination-smoke", {}).get("latestSLOStatus") != "UNKNOWN":
    raise SystemExit("Expected matching target to retain dry-run SLO evidence.")
if mismatch_rows.get("timeline-pagination-smoke", {}).get("latestSLOStatus") != "NEVER_RUN":
    raise SystemExit("Expected mismatched target to ignore dry-run SLO evidence.")
PY

  python3 "${SCRIPT_DIR}/perf_slo_domain_scorecard.py" \
    --slo-status-json "${RESULT_DIR}/slo-status.json" \
    --output "${RESULT_DIR}/slo-domain-scorecard.md" \
    --json-output "${RESULT_DIR}/slo-domain-scorecard.json" \
    --csv-output "${RESULT_DIR}/slo-domain-scorecard.csv" >/dev/null || true

  if python3 "${SCRIPT_DIR}/perf_production_gate.py" \
    --slo-status-json "${RESULT_DIR}/slo-status.json" \
    --profile "minimum-smoke" \
    --output "${RESULT_DIR}/production-gate-fail.md" \
    --json-output "${RESULT_DIR}/production-gate-fail.json" \
    --csv-output "${RESULT_DIR}/production-gate-fail.csv" >/dev/null 2>&1; then
    echo "Expected production gate to fail when required scenarios lack real PASS evidence." >&2
    exit 1
  fi
  if python3 "${SCRIPT_DIR}/perf_production_gate.py" \
    --slo-status-json "${RESULT_DIR}/slo-status.json" \
    --profile "minimum-smoke" \
    --max-evidence-age-seconds -1 \
    --output "${RESULT_DIR}/production-gate-negative-max-age.md" \
    --json-output "${RESULT_DIR}/production-gate-negative-max-age.json" \
    --csv-output "${RESULT_DIR}/production-gate-negative-max-age.csv" \
    >"${RESULT_DIR}/production-gate-negative-max-age.log" 2>&1; then
    echo "Expected production gate to fail when max evidence age is negative." >&2
    exit 1
  fi
  grep -q 'reason=invalid_max_evidence_age' "${RESULT_DIR}/production-gate-negative-max-age.log" || {
    echo "Expected production gate negative max age reason in log." >&2
    exit 1
  }

  python3 - "${RESULT_DIR}/production-gate-pass-input.json" "${RESULT_DIR}/synthetic-pass" "${SCRIPT_DIR}/perf_production_profiles.json" <<'PY'
import json
import sys
import time
from pathlib import Path

with open(sys.argv[3], encoding="utf-8") as handle:
    required = (json.load(handle).get("profiles") or {}).get("minimum-smoke") or []
run_dir = Path(sys.argv[2])
run_dir.mkdir(parents=True, exist_ok=True)
(run_dir / "slo.json").write_text(json.dumps({"scenarios": [{"scenario": scenario, "sloStatus": "PASS"} for scenario in required]}), encoding="utf-8")
(run_dir / "report.json").write_text(json.dumps({"scenarios": [{"scenario": scenario, "status": "PASS"} for scenario in required]}), encoding="utf-8")
for scenario in required:
    scenario_dir = run_dir / scenario
    scenario_dir.mkdir(parents=True, exist_ok=True)
    (scenario_dir / "scenario.json").write_text(json.dumps({"name": scenario}), encoding="utf-8")
    (scenario_dir / "command.sh").write_text("#!/usr/bin/env bash\ntrue\n", encoding="utf-8")
    (scenario_dir / "exit-code.txt").write_text("0\n", encoding="utf-8")
now = int(time.time())
payload = {
    "targetFilter": {"enabled": True, "baseURL": "https://chat.myim-prod.com", "tcpHost": "tcp.myim-prod.com", "tcpPort": "9000"},
    "scenarioCount": len(required),
    "matrixScenarioCount": len(required),
    "latestSLOStatusCounts": {"PASS": len(required), "FAIL": 0, "UNKNOWN": 0, "NEVER_RUN": 0},
    "extraSLOStatusCounts": {},
    "scenarios": [
        {
            "scenario": scenario,
            "category": "http-login" if scenario == "login-smoke" else "synthetic",
            "isMatrixScenario": True,
            "runCount": 1,
            "latestRunID": "synthetic-pass",
            "latestRunDir": str(run_dir),
            "latestMtime": now,
            "latestSLOStatus": "PASS",
            "latestScenarioStatus": "PASS",
            "latestReason": "",
        }
        for scenario in required
    ],
}
with open(sys.argv[1], "w") as handle:
    json.dump(payload, handle)
PY

  python3 "${SCRIPT_DIR}/perf_production_gate.py" \
    --slo-status-json "${RESULT_DIR}/production-gate-pass-input.json" \
    --profile "minimum-smoke" \
    --require-run-artifacts \
    --max-evidence-age-seconds 3600 \
    --output "${RESULT_DIR}/production-gate-pass.md" \
    --json-output "${RESULT_DIR}/production-gate-pass.json" \
    --csv-output "${RESULT_DIR}/production-gate-pass.csv" >/dev/null

  python3 - "${RESULT_DIR}/production-gate-pass.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
if data.get("status") != "PASS":
    raise SystemExit(f"Expected synthetic production gate to pass, got {data.get('status')}")
summary = data.get("summary") or {}
if int(summary.get("requiredScenarioCount") or 0) <= 0:
    raise SystemExit("Expected production gate to include required scenarios.")
if int(summary.get("runArtifactMissingCount") or 0) != 0:
    raise SystemExit("Expected production gate artifacts to be complete.")
if summary.get("failureKindCounts") not in ({}, None):
    raise SystemExit(f"Expected passing production gate to have no failure kind counts, got {summary.get('failureKindCounts')}.")
if not data.get("requirements", {}).get("runArtifacts"):
    raise SystemExit("Expected production gate to record required run artifacts.")
if int(data.get("requirements", {}).get("maxEvidenceAgeSeconds") or 0) != 3600:
    raise SystemExit("Expected production gate to record max evidence age.")
if summary.get("evidenceOldestAgeSeconds") is None or int(summary.get("evidenceOldestAgeSeconds")) < 0:
    raise SystemExit("Expected production gate to record non-negative evidence age.")
target_filter = data.get("targetFilter") or {}
if not target_filter.get("enabled"):
    raise SystemExit("Expected production gate to copy enabled target filter.")
if (
    target_filter.get("baseURL") != "https://chat.myim-prod.com"
    or target_filter.get("tcpHost") != "tcp.myim-prod.com"
    or str(target_filter.get("tcpPort")) != "9000"
):
    raise SystemExit(f"Expected production gate target to match slo-status input, got {target_filter}.")
PY

  python3 - "${RESULT_DIR}/production-gate-local-target-input.json" "${RESULT_DIR}/production-gate-pass-input.json" <<'PY'
import json
import sys

with open(sys.argv[2], encoding="utf-8") as handle:
    payload = json.load(handle)
payload["targetFilter"] = {
    "enabled": True,
    "baseURL": "http://127.0.0.1:8080",
    "tcpHost": "127.0.0.1",
    "tcpPort": "9000",
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
  if python3 "${SCRIPT_DIR}/perf_production_gate.py" \
    --slo-status-json "${RESULT_DIR}/production-gate-local-target-input.json" \
    --profile "minimum-smoke" \
    --require-run-artifacts \
    --max-evidence-age-seconds 3600 \
    --output "${RESULT_DIR}/production-gate-local-target.md" \
    --json-output "${RESULT_DIR}/production-gate-local-target.json" \
    --csv-output "${RESULT_DIR}/production-gate-local-target.csv" >/dev/null 2>&1; then
    echo "Expected production gate to fail when all SLOs pass on a local/non-HTTPS target." >&2
    exit 1
  fi
  python3 - "${RESULT_DIR}/production-gate-local-target.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
if data.get("status") != "FAIL":
    raise SystemExit(f"Expected local target production gate to fail, got {data.get('status')}.")
summary = data.get("summary") or {}
counts = summary.get("failureKindCounts") or {}
if int(counts.get("target_filter_invalid") or 0) <= 0:
    raise SystemExit(f"Expected target_filter_invalid failure kind, got {counts}.")
if int(summary.get("targetFilterInvalidCount") or 0) <= 0:
    raise SystemExit("Expected targetFilterInvalidCount to be positive.")
errors = summary.get("targetFilterErrors") or []
if not any("baseURL" in str(error) for error in errors):
    raise SystemExit(f"Expected baseURL target filter error, got {errors}.")
if not any("tcpHost" in str(error) for error in errors):
    raise SystemExit(f"Expected tcpHost target filter error, got {errors}.")
if int(summary.get("failedScenarioCount") or 0) != 0:
    raise SystemExit("Expected local target failure to be gate-level, not scenario-level.")
PY

  python3 - "${RESULT_DIR}/production-gate-stale-input.json" "${RESULT_DIR}/production-gate-pass-input.json" <<'PY'
import json
import sys
import time

with open(sys.argv[2], encoding="utf-8") as handle:
    payload = json.load(handle)
old = int(time.time()) - 7200
for row in payload.get("scenarios") or []:
    row["latestMtime"] = old
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
  if python3 "${SCRIPT_DIR}/perf_production_gate.py" \
    --slo-status-json "${RESULT_DIR}/production-gate-stale-input.json" \
    --profile "minimum-smoke" \
    --require-run-artifacts \
    --max-evidence-age-seconds 60 \
    --output "${RESULT_DIR}/production-gate-stale.md" \
    --json-output "${RESULT_DIR}/production-gate-stale.json" \
    --csv-output "${RESULT_DIR}/production-gate-stale.csv" >/dev/null 2>&1; then
    echo "Expected production gate to fail when required scenario evidence is stale." >&2
    exit 1
  fi
  python3 - "${RESULT_DIR}/production-gate-stale.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
counts = (data.get("summary") or {}).get("failureKindCounts") or {}
if int(counts.get("evidence_stale") or 0) <= 0:
    raise SystemExit(f"Expected evidence_stale failure kind, got {counts}.")
if int((data.get("summary") or {}).get("evidenceStaleCount") or 0) <= 0:
    raise SystemExit("Expected evidenceStaleCount to be positive.")
PY

  python3 - "${RESULT_DIR}/production-gate-future-input.json" "${RESULT_DIR}/production-gate-pass-input.json" <<'PY'
import json
import sys
import time

with open(sys.argv[2], encoding="utf-8") as handle:
    payload = json.load(handle)
future = int(time.time()) + 600
for row in payload.get("scenarios") or []:
    row["latestMtime"] = future
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
  if python3 "${SCRIPT_DIR}/perf_production_gate.py" \
    --slo-status-json "${RESULT_DIR}/production-gate-future-input.json" \
    --profile "minimum-smoke" \
    --require-run-artifacts \
    --max-evidence-age-seconds 3600 \
    --future-skew-seconds 60 \
    --output "${RESULT_DIR}/production-gate-future.md" \
    --json-output "${RESULT_DIR}/production-gate-future.json" \
    --csv-output "${RESULT_DIR}/production-gate-future.csv" >/dev/null 2>&1; then
    echo "Expected production gate to fail when required scenario evidence is future-dated." >&2
    exit 1
  fi
  python3 - "${RESULT_DIR}/production-gate-future.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
counts = (data.get("summary") or {}).get("failureKindCounts") or {}
if int(counts.get("evidence_time_in_future") or 0) <= 0:
    raise SystemExit(f"Expected evidence_time_in_future failure kind, got {counts}.")
if int((data.get("summary") or {}).get("evidenceTimeInFutureCount") or 0) <= 0:
    raise SystemExit("Expected evidenceTimeInFutureCount to be positive.")
PY

  python3 - "${RESULT_DIR}/production-gate-missing-artifact-input.json" "${RESULT_DIR}/production-gate-pass-input.json" <<'PY'
import json
import sys

with open(sys.argv[2], encoding="utf-8") as handle:
    payload = json.load(handle)
payload["scenarios"][0]["latestRunDir"] = "/tmp/validate-load-tests-missing-run-artifacts"
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
  if python3 "${SCRIPT_DIR}/perf_production_gate.py" \
    --slo-status-json "${RESULT_DIR}/production-gate-missing-artifact-input.json" \
    --profile "minimum-smoke" \
    --require-run-artifacts \
    --output "${RESULT_DIR}/production-gate-missing-artifact.md" \
    --json-output "${RESULT_DIR}/production-gate-missing-artifact.json" \
    --csv-output "${RESULT_DIR}/production-gate-missing-artifact.csv" >/dev/null 2>&1; then
    echo "Expected production gate to fail when latestRunDir artifacts are missing." >&2
    exit 1
  fi
  grep -q 'latestRunDir is missing or not a directory' "${RESULT_DIR}/production-gate-missing-artifact.md" || {
    echo "Expected production gate missing artifact reason in markdown." >&2
    exit 1
  }
  python3 - "${RESULT_DIR}/production-gate-missing-artifact.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
summary = data.get("summary") or {}
counts = summary.get("failureKindCounts") or {}
if int(counts.get("artifact_missing") or 0) != 1:
    raise SystemExit(f"Expected one artifact_missing failure kind, got {counts}.")
if int(summary.get("artifactMissingCount") or 0) != 1:
    raise SystemExit(f"Expected artifactMissingCount=1, got {summary.get('artifactMissingCount')}.")
rows = data.get("requiredScenarios") or []
if not any(row.get("failureKind") == "artifact_missing" for row in rows):
    raise SystemExit("Expected at least one required scenario with failureKind=artifact_missing.")
PY

  python3 - "${RESULT_DIR}/slo-domain-scorecard.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
summary = data.get("summary") or {}
if int(summary.get("domainCount") or 0) <= 0:
    raise SystemExit("Expected SLO domain scorecard to include domains.")
if summary.get("overallStatus") not in {"READY", "BLOCKED_BY_EXTRA_SLO", "NEEDS_SLO_OPTIMIZATION", "NEEDS_RUNTIME_EVIDENCE", "NEEDS_RUN", "NO_SCENARIOS"}:
    raise SystemExit(f"Unexpected SLO domain scorecard status: {summary.get('overallStatus')}")
PY

  python3 "${SCRIPT_DIR}/perf_slo_domain_run_plan.py" \
    --slo-status-json "${RESULT_DIR}/slo-status.json" \
    --slo-domain-scorecard-json "${RESULT_DIR}/slo-domain-scorecard.json" \
    --base-url "http://127.0.0.1:8080" \
    --tcp-host "127.0.0.1" \
    --tcp-port "9000" \
    --account-file "${SCRIPT_DIR}/accounts/load-1000.csv" \
    --conversation-id "00000000-0000-0000-0000-000000000000" \
    --internal-secret "validate" \
    --output "${RESULT_DIR}/slo-domain-run-plan.md" \
    --json-output "${RESULT_DIR}/slo-domain-run-plan.json" >/dev/null || true

  python3 - "${RESULT_DIR}/slo-domain-run-plan.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
if data.get("status") not in {"READY", "NO_SCENARIOS", "BLOCKED_BY_EXTRA_SLO"}:
    raise SystemExit(f"Unexpected SLO domain run plan status: {data.get('status')}")
if not data.get("probeCommand"):
    raise SystemExit("Expected SLO domain run plan to include a probe command.")
PY

  python3 "${SCRIPT_DIR}/perf_readiness_gate.py" \
    --coverage-json "${RESULT_DIR}/coverage.json" \
    --route-audit-json "${RESULT_DIR}/route-audit.json" \
    --matrix-audit-json "${RESULT_DIR}/matrix-audit.json" \
    --domain-scorecard-json "${RESULT_DIR}/domain-scorecard.json" \
    --prereq-audit-json "${RESULT_DIR}/prereq-audit.json" \
    --slo-status-json "${RESULT_DIR}/slo-status.json" \
    --slo-domain-scorecard-json "${RESULT_DIR}/slo-domain-scorecard.json" \
    --production-gate-json "${RESULT_DIR}/production-gate-fail.json" \
    --run-plan-json "${RESULT_DIR}/run-plan.json" \
    --base-url "https://im.example.com" \
    --tcp-host "im.example.com" \
    --tcp-port "9000" \
    --account-file "${SCRIPT_DIR}/accounts/load-1000.csv" \
    --conversation-id "00000000-0000-0000-0000-000000000000" \
    --require-internal-secret \
    --allow-runtime-evidence-gap \
    --allow-slo-runtime-evidence-gap \
    --allow-slo-never-run-gap \
    --output "${RESULT_DIR}/readiness-gate.txt" \
    --json-output "${RESULT_DIR}/readiness-gate.json" >/dev/null || true

  python3 - "${RESULT_DIR}/readiness-gate.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
checks = {row.get("name"): row for row in data.get("checks") or []}
if "slo-status" not in checks:
    raise SystemExit("Expected readiness gate to include slo-status check.")
if "slo-domain-scorecard" not in checks:
    raise SystemExit("Expected readiness gate to include slo-domain-scorecard check.")
if "production-gate" not in checks:
    raise SystemExit("Expected readiness gate to include production-gate check.")
if checks["production-gate"].get("status") != "FAIL":
    raise SystemExit("Expected dry-run production gate check to fail.")
if "failureKinds=" not in str(checks["production-gate"].get("detail") or ""):
    raise SystemExit("Expected readiness production-gate detail to include failureKinds.")
if "./run_production_profile.sh" not in str(data.get("productionProfileCommand") or ""):
    raise SystemExit("Expected readiness gate to expose production profile command.")
profile_command = str(data.get("productionProfileCommand") or "")
if "PRODUCTION_PROFILE_REQUIRE_CLOUD_SECURITY_GROUP=true" not in profile_command:
    raise SystemExit("Expected readiness gate production profile command to require cloud security group evidence.")
for required in (
    "PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_FILE=${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_FILE:?set-PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_FILE}",
    "PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON=${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON:?set-PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON}",
    "PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID:?set-PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID}",
    "PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID:?set-PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID}",
    "PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR:?set-PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR}",
):
    if required not in profile_command:
        raise SystemExit(f"Expected readiness gate production profile command to require {required}.")
current_command = str(data.get("currentProductionReadinessCommand") or "")
if "./run_current_production_readiness.sh" not in current_command:
    raise SystemExit("Expected readiness gate to expose current production readiness command.")
if "CURRENT_PRODUCTION_BASE_URL" not in current_command or "CURRENT_PRODUCTION_TCP_HOST" not in current_command:
    raise SystemExit("Expected readiness gate current production command to require explicit production target.")
for required in (
    "CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_FILE=${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_FILE:?set-CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_FILE}",
    "CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON=${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON:?set-CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON}",
    "CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID:?set-CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID}",
    "CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID:?set-CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID}",
    "CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR:?set-CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR}",
):
    if required not in current_command:
        raise SystemExit(f"Expected readiness gate current production command to require {required}.")
if "BASE_URL=https://im.example.com" in current_command or "TCP_HOST=im.example.com" in current_command:
    raise SystemExit("Readiness gate current production command must not reuse the example production target.")
action_commands = data.get("productionEvidenceActionCommands") or []
roles = {row.get("role") for row in action_commands}
for expected in ("production-profile", "current-production-readiness", "production-acceptance"):
    if expected not in roles:
        raise SystemExit(f"Expected readiness gate production evidence command role {expected}.")
for row in action_commands:
    if "yourdomain.com" in str(row.get("command") or ""):
        raise SystemExit("Readiness gate production evidence command must not embed placeholder yourdomain targets.")
acceptance_command = str(data.get("productionAcceptanceCommand") or "")
if "./run_production_acceptance.sh" not in acceptance_command:
    raise SystemExit("Expected readiness gate to expose production acceptance command.")
if "PRODUCTION_ACCEPTANCE_RESULT_ROOT=results/production-acceptance" not in acceptance_command:
    raise SystemExit("Expected readiness gate production acceptance command to use portable production acceptance result root.")
if "PRODUCTION_ACCEPTANCE_PACKAGE_EVIDENCE=true" not in acceptance_command:
    raise SystemExit("Expected readiness gate production acceptance command to package evidence.")
if "BASE_URL=${PRODUCTION_ACCEPTANCE_BASE_URL:?set-PRODUCTION_ACCEPTANCE_BASE_URL}" not in acceptance_command:
    raise SystemExit("Expected readiness gate production acceptance command to require an explicit production base URL.")
if "TCP_HOST=${PRODUCTION_ACCEPTANCE_TCP_HOST:?set-PRODUCTION_ACCEPTANCE_TCP_HOST}" not in acceptance_command:
    raise SystemExit("Expected readiness gate production acceptance command to require an explicit production TCP host.")
if "TCP_PORT=${PRODUCTION_ACCEPTANCE_TCP_PORT:?set-PRODUCTION_ACCEPTANCE_TCP_PORT}" not in acceptance_command:
    raise SystemExit("Expected readiness gate production acceptance command to require an explicit production TCP port.")
if "BASE_URL=https://im.example.com" in acceptance_command or "TCP_HOST=im.example.com" in acceptance_command:
    raise SystemExit("Readiness gate production acceptance command must not reuse the example production target.")
if "ACCOUNT_FILE=${PRODUCTION_ACCEPTANCE_ACCOUNT_FILE:?set-PRODUCTION_ACCEPTANCE_ACCOUNT_FILE}" not in acceptance_command:
    raise SystemExit("Expected readiness gate production acceptance command to require an explicit full-scale account file.")
if "ACCOUNT_FILE=accounts/load-1000.csv" in acceptance_command:
    raise SystemExit("Readiness gate production acceptance command must not reuse the smoke-scale account file.")
if "IM_CONVERSATION_ID=${PRODUCTION_ACCEPTANCE_CONVERSATION_ID:?set-PRODUCTION_ACCEPTANCE_CONVERSATION_ID}" not in acceptance_command:
    raise SystemExit("Expected readiness gate production acceptance command to require an explicit production conversation id.")
if "IM_CONVERSATION_ID=00000000-0000-0000-0000-000000000000" in acceptance_command:
    raise SystemExit("Readiness gate production acceptance command must not reuse the smoke-scale conversation id.")
if "PRODUCTION_ACCEPTANCE_RECEIPT_MAX_AGE_SECONDS=86400" not in acceptance_command:
    raise SystemExit("Expected readiness gate production acceptance command to pin receipt max age.")
if "PRODUCTION_ACCEPTANCE_RECEIPT_MAX_FUTURE_SKEW_SECONDS=300" not in acceptance_command:
    raise SystemExit("Expected readiness gate production acceptance command to pin receipt max future skew.")
if "PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS=86400" not in acceptance_command:
    raise SystemExit("Expected readiness gate production acceptance command to pin cloud security group repair receipt max age.")
if "PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON=${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON:?set-PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON}" not in acceptance_command:
    raise SystemExit("Expected readiness gate production acceptance command to require cloud security group repair receipt JSON.")
if "/Users/" in acceptance_command or "/Desktop/" in acceptance_command:
    raise SystemExit("Readiness gate production acceptance command must not embed workstation-specific absolute paths.")
if "./run_production_profile.sh" not in str(data.get("nextCommand") or ""):
    raise SystemExit("Expected readiness gate nextCommand to run production profile.")
next_command = str(data.get("nextCommand") or "")
if "BASE_URL=${PRODUCTION_PROFILE_BASE_URL:?set-PRODUCTION_PROFILE_BASE_URL}" not in next_command:
    raise SystemExit("Expected readiness gate nextCommand to require an explicit production profile base URL.")
if "TCP_HOST=${PRODUCTION_PROFILE_TCP_HOST:?set-PRODUCTION_PROFILE_TCP_HOST}" not in next_command:
    raise SystemExit("Expected readiness gate nextCommand to require an explicit production profile TCP host.")
if "ACCOUNT_FILE=${PRODUCTION_PROFILE_ACCOUNT_FILE:?set-PRODUCTION_PROFILE_ACCOUNT_FILE}" not in next_command:
    raise SystemExit("Expected readiness gate nextCommand to require an explicit production profile account file.")
if "IM_CONVERSATION_ID=${PRODUCTION_PROFILE_CONVERSATION_ID:?set-PRODUCTION_PROFILE_CONVERSATION_ID}" not in next_command:
    raise SystemExit("Expected readiness gate nextCommand to require an explicit production profile conversation id.")
if "PRODUCTION_PROFILE_REQUIRE_CLOUD_SECURITY_GROUP=true" not in next_command:
    raise SystemExit("Expected readiness gate nextCommand to require production profile cloud security group evidence.")
if "BASE_URL=https://im.example.com" in next_command or "TCP_HOST=im.example.com" in next_command:
    raise SystemExit("Readiness gate nextCommand must not reuse the example production target.")
if "ACCOUNT_FILE=accounts/load-1000.csv" in next_command:
    raise SystemExit("Readiness gate nextCommand must not reuse the smoke-scale account file.")
if "IM_CONVERSATION_ID=00000000-0000-0000-0000-000000000000" in next_command:
    raise SystemExit("Readiness gate nextCommand must not reuse the placeholder conversation id.")
if "BASE_URL=http://127.0.0.1:8080" in next_command:
    raise SystemExit("Readiness gate nextCommand must not fall back to local HTTP target when production target override is provided.")
if not data.get("productionGateFailedScenarios"):
    raise SystemExit("Expected readiness gate to expose production gate failed scenarios.")
if data.get("status") not in {"PASS", "FAIL"}:
    raise SystemExit(f"Unexpected readiness gate status after SLO checks: {data.get('status')}")
PY

  python3 "${SCRIPT_DIR}/perf_dashboard.py" \
    --scenario-status-json "${RESULT_DIR}/scenario-status.json" \
    --slo-status-json "${RESULT_DIR}/slo-status.json" \
    --slo-domain-scorecard-json "${RESULT_DIR}/slo-domain-scorecard.json" \
    --slo-domain-run-plan-json "${RESULT_DIR}/slo-domain-run-plan.json" \
    --next-actions-json "${RESULT_DIR}/next-actions.json" \
    --scenario-catalog-json "${RESULT_DIR}/scenario-catalog.json" \
    --domain-backlog-json "${RESULT_DIR}/domain-backlog.json" \
    --run-plan-json "${RESULT_DIR}/run-plan.json" \
    --domain-run-plan-json "${RESULT_DIR}/domain-run-plan.json" \
    --domain-scorecard-json "${RESULT_DIR}/domain-scorecard.json" \
    --prereq-audit-json "${RESULT_DIR}/prereq-audit.json" \
    --readiness-gate-json "${RESULT_DIR}/readiness-gate.json" \
    --production-gate-json "${RESULT_DIR}/production-gate-fail.json" \
    --base-url "https://im.example.com" \
    --tcp-host "im.example.com" \
    --tcp-port "9000" \
    --account-file "${SCRIPT_DIR}/accounts/load-1000.csv" \
    --conversation-id "00000000-0000-0000-0000-000000000000" \
    --require-internal-secret \
    --output "${RESULT_DIR}/dashboard.md" \
    --json-output "${RESULT_DIR}/dashboard.json" >/dev/null

  python3 - "${RESULT_DIR}/dashboard.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
summary = data.get("summary") or {}
if not summary.get("readinessGate"):
    raise SystemExit("Expected dashboard readinessGate summary.")
if int(summary.get("scenarioCount") or 0) <= 0:
    raise SystemExit("Expected dashboard scenario count.")
if not summary.get("sloStatusCounts"):
    raise SystemExit("Expected dashboard SLO status counts.")
if summary.get("productionGate") != "FAIL":
    raise SystemExit("Expected dashboard to expose failing production gate status.")
if not summary.get("productionGateFailureKinds"):
    raise SystemExit("Expected dashboard to expose production gate failure kind counts.")
blockers = data.get("productionEvidenceBlockers") or []
blocker_codes = set(summary.get("productionEvidenceBlockers") or [])
if int(summary.get("productionEvidenceBlockerCount") or 0) <= 0:
    raise SystemExit("Expected dashboard to expose production evidence blocker count.")
if len(blockers) != int(summary.get("productionEvidenceBlockerCount") or 0):
    raise SystemExit("Expected dashboard production evidence blocker count to match blocker rows.")
for expected in ("current_production_readiness_missing", "production_acceptance_receipt_missing"):
    if expected not in blocker_codes:
        raise SystemExit(f"Expected dashboard production evidence blocker {expected}.")
if not any(str(code).startswith("production_gate_") for code in blocker_codes):
    raise SystemExit("Expected dashboard to expose at least one production gate blocker code.")
for row in blockers:
    for key in ("code", "severity", "source", "reason", "action", "commandRole", "command"):
        if not row.get(key):
            raise SystemExit(f"Expected dashboard production evidence blocker field {key}.")
action_commands = data.get("productionEvidenceActionCommands") or []
roles = {row.get("role") for row in action_commands}
for expected in ("production-profile", "current-production-readiness", "production-acceptance"):
    if expected not in roles:
        raise SystemExit(f"Expected dashboard production evidence action command role {expected}.")
for row in action_commands:
    if "yourdomain.com" in str(row.get("command") or ""):
        raise SystemExit("Dashboard production evidence action command must not embed placeholder yourdomain targets.")
if "./run_current_production_readiness.sh" not in str(data.get("currentProductionReadinessCommand") or ""):
    raise SystemExit("Expected dashboard to expose current production readiness command.")
if not data.get("productionGateFailedScenarios"):
    raise SystemExit("Expected dashboard to expose production gate failed scenarios.")
if "./run_production_profile.sh" not in str(data.get("productionProfileCommand") or ""):
    raise SystemExit("Expected dashboard to expose production profile command.")
acceptance_command = str(data.get("productionAcceptanceCommand") or "")
if "./run_production_acceptance.sh" not in acceptance_command:
    raise SystemExit("Expected dashboard to expose production acceptance command.")
if "BASE_URL=${PRODUCTION_ACCEPTANCE_BASE_URL:?set-PRODUCTION_ACCEPTANCE_BASE_URL}" not in acceptance_command:
    raise SystemExit("Expected dashboard production acceptance command to require an explicit production base URL.")
if "TCP_HOST=${PRODUCTION_ACCEPTANCE_TCP_HOST:?set-PRODUCTION_ACCEPTANCE_TCP_HOST}" not in acceptance_command:
    raise SystemExit("Expected dashboard production acceptance command to require an explicit production TCP host.")
if "TCP_PORT=${PRODUCTION_ACCEPTANCE_TCP_PORT:?set-PRODUCTION_ACCEPTANCE_TCP_PORT}" not in acceptance_command:
    raise SystemExit("Expected dashboard production acceptance command to require an explicit production TCP port.")
if "BASE_URL=https://im.example.com" in acceptance_command or "TCP_HOST=im.example.com" in acceptance_command:
    raise SystemExit("Dashboard production acceptance command must not reuse the example production target.")
if "ACCOUNT_FILE=${PRODUCTION_ACCEPTANCE_ACCOUNT_FILE:?set-PRODUCTION_ACCEPTANCE_ACCOUNT_FILE}" not in acceptance_command:
    raise SystemExit("Expected dashboard production acceptance command to require an explicit full-scale account file.")
if "ACCOUNT_FILE=accounts/load-1000.csv" in acceptance_command:
    raise SystemExit("Dashboard production acceptance command must not reuse the smoke-scale account file.")
if "IM_CONVERSATION_ID=${PRODUCTION_ACCEPTANCE_CONVERSATION_ID:?set-PRODUCTION_ACCEPTANCE_CONVERSATION_ID}" not in acceptance_command:
    raise SystemExit("Expected dashboard production acceptance command to require an explicit production conversation id.")
if "IM_CONVERSATION_ID=00000000-0000-0000-0000-000000000000" in acceptance_command:
    raise SystemExit("Dashboard production acceptance command must not reuse the smoke-scale conversation id.")
if "cd IMServer/LoadTests &&" not in acceptance_command:
    raise SystemExit("Expected dashboard production acceptance command to be runnable from the repository root.")
if "/Users/" in acceptance_command or "/Desktop/" in acceptance_command:
    raise SystemExit("Dashboard production acceptance command must not embed workstation-specific absolute paths.")
if "./run_production_profile.sh" not in str(data.get("nextCommand") or ""):
    raise SystemExit("Expected dashboard nextCommand to prefer production profile command when production gate is the active failure.")
next_command = str(data.get("nextCommand") or "")
if "BASE_URL=${PRODUCTION_PROFILE_BASE_URL:?set-PRODUCTION_PROFILE_BASE_URL}" not in next_command:
    raise SystemExit("Expected dashboard nextCommand to require an explicit production profile base URL.")
if "TCP_HOST=${PRODUCTION_PROFILE_TCP_HOST:?set-PRODUCTION_PROFILE_TCP_HOST}" not in next_command:
    raise SystemExit("Expected dashboard nextCommand to require an explicit production profile TCP host.")
if "ACCOUNT_FILE=${PRODUCTION_PROFILE_ACCOUNT_FILE:?set-PRODUCTION_PROFILE_ACCOUNT_FILE}" not in next_command:
    raise SystemExit("Expected dashboard nextCommand to require an explicit production profile account file.")
if "IM_CONVERSATION_ID=${PRODUCTION_PROFILE_CONVERSATION_ID:?set-PRODUCTION_PROFILE_CONVERSATION_ID}" not in next_command:
    raise SystemExit("Expected dashboard nextCommand to require an explicit production profile conversation id.")
if "BASE_URL=https://im.example.com" in next_command or "TCP_HOST=im.example.com" in next_command:
    raise SystemExit("Dashboard nextCommand must not reuse the example production target.")
if "ACCOUNT_FILE=accounts/load-1000.csv" in next_command:
    raise SystemExit("Dashboard nextCommand must not reuse the smoke-scale account file.")
if "IM_CONVERSATION_ID=00000000-0000-0000-0000-000000000000" in next_command:
    raise SystemExit("Dashboard nextCommand must not reuse the placeholder conversation id.")
if "BASE_URL=http://127.0.0.1:8080" in next_command:
    raise SystemExit("Dashboard nextCommand must not fall back to local HTTP target when production target override is provided.")
if "productionGateMaxEvidenceAgeSeconds" not in summary:
    raise SystemExit("Expected dashboard to expose production gate max evidence age.")
if "productionGateEvidenceStaleCount" not in summary:
    raise SystemExit("Expected dashboard to expose production gate evidence stale count.")
PY
  grep -q 'Production Evidence Blockers' "${RESULT_DIR}/dashboard.md"
  grep -q 'Production Evidence Commands' "${RESULT_DIR}/dashboard.md"

  cat >"${RESULT_DIR}/entrypoint-rescue-summary.txt" <<'EOF'
status=BLOCKED
rescuePlanAction=cloud_console_rescue_required
entrypointDiagnosis=public_listener_not_imserver_nginx
entrypointFailed=True
entrypointDetail=/nginx-health returned empty 403.
EOF
  cat >"${RESULT_DIR}/verify-artifact.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'verify-artifact result=pass\n'
EOF
  chmod +x "${RESULT_DIR}/verify-artifact.sh"
  cat >"${RESULT_DIR}/entrypoint-rescue-plan.md" <<'EOF'
# Entrypoint Rescue Plan
EOF
  python3 "${SCRIPT_DIR}/perf_dashboard.py" \
    --scenario-status-json "${RESULT_DIR}/scenario-status.json" \
    --slo-status-json "${RESULT_DIR}/slo-status.json" \
    --slo-domain-scorecard-json "${RESULT_DIR}/slo-domain-scorecard.json" \
    --slo-domain-run-plan-json "${RESULT_DIR}/slo-domain-run-plan.json" \
    --next-actions-json "${RESULT_DIR}/next-actions.json" \
    --scenario-catalog-json "${RESULT_DIR}/scenario-catalog.json" \
    --domain-backlog-json "${RESULT_DIR}/domain-backlog.json" \
    --run-plan-json "${RESULT_DIR}/run-plan.json" \
    --domain-run-plan-json "${RESULT_DIR}/domain-run-plan.json" \
    --domain-scorecard-json "${RESULT_DIR}/domain-scorecard.json" \
    --prereq-audit-json "${RESULT_DIR}/prereq-audit.json" \
    --readiness-gate-json "${RESULT_DIR}/readiness-gate.json" \
    --production-gate-json "${RESULT_DIR}/production-gate-fail.json" \
    --entrypoint-rescue-summary "${RESULT_DIR}/entrypoint-rescue-summary.txt" \
    --json-output "${RESULT_DIR}/dashboard-entrypoint-blocked.json" >/dev/null

  python3 - "${RESULT_DIR}/dashboard-entrypoint-blocked.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
summary = data.get("summary") or {}
if summary.get("entrypointRescueBlocked") is not True:
    raise SystemExit("Expected dashboard to expose blocked entrypoint rescue state.")
if summary.get("entrypointRescueAction") != "cloud_console_rescue_required":
    raise SystemExit("Expected dashboard entrypoint rescue action.")
if summary.get("entrypointRescueDiagnosis") != "public_listener_not_imserver_nginx":
    raise SystemExit("Expected dashboard entrypoint rescue diagnosis.")
if "entrypoint-rescue-plan.md" not in str(data.get("nextCommand") or ""):
    raise SystemExit("Expected dashboard nextCommand to point to the entrypoint rescue plan.")
if "./run_production_profile.sh" in str(data.get("nextCommand") or ""):
    raise SystemExit("Expected dashboard entrypoint rescue state to avoid production profile command.")
PY

  python3 "${SCRIPT_DIR}/perf_optimization_playbook.py" \
    --dashboard-json "${RESULT_DIR}/dashboard.json" \
    --domain-backlog-json "${RESULT_DIR}/domain-backlog.json" \
    --run-plan-json "${RESULT_DIR}/run-plan.json" \
    --domain-run-plan-json "${RESULT_DIR}/domain-run-plan.json" \
    --prereq-audit-json "${RESULT_DIR}/prereq-audit.json" \
    --readiness-gate-json "${RESULT_DIR}/readiness-gate.json" \
    --slo-status-json "${RESULT_DIR}/slo-status.json" \
    --production-gate-json "${RESULT_DIR}/production-gate-fail.json" \
    --base-url "https://im.example.com" \
    --tcp-host "im.example.com" \
    --tcp-port "9000" \
    --account-file "${SCRIPT_DIR}/accounts/load-1000.csv" \
    --conversation-id "00000000-0000-0000-0000-000000000000" \
    --require-internal-secret \
    --output "${RESULT_DIR}/optimization-playbook.md" \
    --json-output "${RESULT_DIR}/optimization-playbook.json" \
    --csv-output "${RESULT_DIR}/optimization-playbook.csv" >/dev/null

  python3 - "${RESULT_DIR}/optimization-playbook.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
summary = data.get("summary") or {}
if int(summary.get("itemCount") or 0) <= 0:
    raise SystemExit("Expected optimization playbook to include work items.")
if not data.get("workItems"):
    raise SystemExit("Expected optimization playbook workItems.")
first = data["workItems"][0]
if first.get("actionType") != "production-profile-evidence":
    raise SystemExit(f"Expected optimization playbook to prioritize production profile evidence, got {first.get('actionType')}.")
if "./run_production_profile.sh" not in " ".join(first.get("commands") or []):
    raise SystemExit("Expected optimization playbook first item to include production profile command.")
if "./run_current_production_readiness.sh" not in " ".join(first.get("commands") or []):
    raise SystemExit("Expected optimization playbook first item to include current production readiness command.")
if "./run_production_acceptance.sh" not in " ".join(first.get("commands") or []):
    raise SystemExit("Expected optimization playbook first item to include production acceptance command.")
first_command = str((first.get("commands") or [""])[0])
if "RESULT_ROOT=results/production-acceptance" not in first_command:
    raise SystemExit("Expected optimization playbook production profile command to use portable production acceptance result root.")
if "BASE_URL=${PRODUCTION_PROFILE_BASE_URL:?set-PRODUCTION_PROFILE_BASE_URL}" not in first_command:
    raise SystemExit("Expected optimization playbook production profile command to require an explicit production base URL.")
if "TCP_HOST=${PRODUCTION_PROFILE_TCP_HOST:?set-PRODUCTION_PROFILE_TCP_HOST}" not in first_command:
    raise SystemExit("Expected optimization playbook production profile command to require an explicit production TCP host.")
if "ACCOUNT_FILE=${PRODUCTION_PROFILE_ACCOUNT_FILE:?set-PRODUCTION_PROFILE_ACCOUNT_FILE}" not in first_command:
    raise SystemExit("Expected optimization playbook production profile command to require an explicit production account file.")
if "IM_CONVERSATION_ID=${PRODUCTION_PROFILE_CONVERSATION_ID:?set-PRODUCTION_PROFILE_CONVERSATION_ID}" not in first_command:
    raise SystemExit("Expected optimization playbook production profile command to require an explicit production conversation id.")
if "PRODUCTION_PROFILE_REQUIRE_CLOUD_SECURITY_GROUP=true" not in first_command:
    raise SystemExit("Expected optimization playbook production profile command to require cloud security group evidence.")
for required in (
    "PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_FILE=${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_FILE:?set-PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_FILE}",
    "PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON=${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON:?set-PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON}",
    "PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID:?set-PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID}",
    "PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID:?set-PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID}",
    "PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=${PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR:?set-PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR}",
):
    if required not in first_command:
        raise SystemExit(f"Expected optimization playbook production profile command to require {required}.")
if "BASE_URL=https://im.example.com" in first_command or "TCP_HOST=im.example.com" in first_command:
    raise SystemExit("Optimization playbook production profile command must not reuse the example production target.")
if "ACCOUNT_FILE=accounts/load-1000.csv" in first_command:
    raise SystemExit("Optimization playbook production profile command must not reuse the smoke-scale account file.")
if "IM_CONVERSATION_ID=00000000-0000-0000-0000-000000000000" in first_command:
    raise SystemExit("Optimization playbook production profile command must not reuse the placeholder conversation id.")
if "cd IMServer/LoadTests &&" not in first_command:
    raise SystemExit("Expected optimization playbook production profile command to be runnable from the repository root.")
if "/Users/" in first_command or "/Desktop/" in first_command:
    raise SystemExit("Optimization playbook production profile command must not embed workstation-specific absolute paths.")
first_commands = first.get("commands") or []
current_command = next((str(command) for command in first_commands if "./run_current_production_readiness.sh" in str(command)), "")
if not current_command:
    raise SystemExit("Expected optimization playbook current production readiness command.")
if "CURRENT_PRODUCTION_BASE_URL" not in current_command or "CURRENT_PRODUCTION_TCP_HOST" not in current_command:
    raise SystemExit("Expected optimization playbook current production command to require explicit production target.")
for required in (
    "CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_FILE=${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_FILE:?set-CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_FILE}",
    "CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON=${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON:?set-CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON}",
    "CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID:?set-CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID}",
    "CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID:?set-CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID}",
    "CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=${CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR:?set-CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR}",
):
    if required not in current_command:
        raise SystemExit(f"Expected optimization playbook current production command to require {required}.")
if "BASE_URL=https://im.example.com" in current_command or "TCP_HOST=im.example.com" in current_command:
    raise SystemExit("Optimization playbook current production command must not reuse the example production target.")
if "/Users/" in current_command or "/Desktop/" in current_command:
    raise SystemExit("Optimization playbook current production command must not embed workstation-specific absolute paths.")
second_command = next((str(command) for command in first_commands if "./run_production_acceptance.sh" in str(command)), "")
if not second_command:
    raise SystemExit("Expected optimization playbook production acceptance command.")
if "PRODUCTION_ACCEPTANCE_RESULT_ROOT=results/production-acceptance" not in second_command:
    raise SystemExit("Expected optimization playbook production acceptance command to use portable production acceptance result root.")
if "BASE_URL=${PRODUCTION_ACCEPTANCE_BASE_URL:?set-PRODUCTION_ACCEPTANCE_BASE_URL}" not in second_command:
    raise SystemExit("Expected optimization playbook production acceptance command to require an explicit production base URL.")
if "TCP_HOST=${PRODUCTION_ACCEPTANCE_TCP_HOST:?set-PRODUCTION_ACCEPTANCE_TCP_HOST}" not in second_command:
    raise SystemExit("Expected optimization playbook production acceptance command to require an explicit production TCP host.")
if "TCP_PORT=${PRODUCTION_ACCEPTANCE_TCP_PORT:?set-PRODUCTION_ACCEPTANCE_TCP_PORT}" not in second_command:
    raise SystemExit("Expected optimization playbook production acceptance command to require an explicit production TCP port.")
if "BASE_URL=https://im.example.com" in second_command or "TCP_HOST=im.example.com" in second_command:
    raise SystemExit("Optimization playbook production acceptance command must not reuse the example production target.")
if "ACCOUNT_FILE=${PRODUCTION_ACCEPTANCE_ACCOUNT_FILE:?set-PRODUCTION_ACCEPTANCE_ACCOUNT_FILE}" not in second_command:
    raise SystemExit("Expected optimization playbook production acceptance command to require an explicit full-scale account file.")
if "ACCOUNT_FILE=accounts/load-1000.csv" in second_command:
    raise SystemExit("Optimization playbook production acceptance command must not reuse the smoke-scale account file.")
if "IM_CONVERSATION_ID=${PRODUCTION_ACCEPTANCE_CONVERSATION_ID:?set-PRODUCTION_ACCEPTANCE_CONVERSATION_ID}" not in second_command:
    raise SystemExit("Expected optimization playbook production acceptance command to require an explicit production conversation id.")
if "IM_CONVERSATION_ID=00000000-0000-0000-0000-000000000000" in second_command:
    raise SystemExit("Optimization playbook production acceptance command must not reuse the smoke-scale conversation id.")
if "PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_RULES_FILE=${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_RULES_FILE:?set-PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_RULES_FILE}" not in second_command:
    raise SystemExit("Expected optimization playbook production acceptance command to require cloud security group rules file.")
if "IM_INTERNAL_SECRET=${IM_INTERNAL_SECRET:?set-IM_INTERNAL_SECRET}" not in second_command:
    raise SystemExit("Expected optimization playbook production acceptance command to require internal secret without embedding it.")
if "/Users/" in second_command or "/Desktop/" in second_command:
    raise SystemExit("Optimization playbook production acceptance command must not embed workstation-specific absolute paths.")
if not first.get("requiredScenarios"):
    raise SystemExit("Expected optimization playbook first item to list production gate required scenarios.")
PY

  python3 "${SCRIPT_DIR}/perf_state_summary.py" \
    --scenario-status-json "${RESULT_DIR}/scenario-status.json" \
    --slo-status-json "${RESULT_DIR}/slo-status.json" \
    --slo-domain-scorecard-json "${RESULT_DIR}/slo-domain-scorecard.json" \
    --readiness-gate-json "${RESULT_DIR}/readiness-gate.json" \
    --next-actions-json "${RESULT_DIR}/next-actions.json" \
    --scenario-catalog-json "${RESULT_DIR}/scenario-catalog.json" \
    --dashboard-json "${RESULT_DIR}/dashboard.json" \
    --run-plan-json "${RESULT_DIR}/run-plan.json" \
    --production-gate-json "${RESULT_DIR}/production-gate-fail.json" \
    --base-url "https://im.example.com" \
    --tcp-host "im.example.com" \
    --tcp-port "9000" \
    --account-file "${SCRIPT_DIR}/accounts/load-1000.csv" \
    --conversation-id "00000000-0000-0000-0000-000000000000" \
    --require-internal-secret \
    --output "${RESULT_DIR}/state-summary.md" \
    --json-output "${RESULT_DIR}/state-summary.json" \
    --csv-output "${RESULT_DIR}/state-summary.csv" >/dev/null

  python3 - "${RESULT_DIR}/state-summary.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
summary = data.get("summary") or {}
if not summary.get("conclusion"):
    raise SystemExit("Expected state summary conclusion.")
if summary.get("conclusion") != "NEEDS_PRODUCTION_EVIDENCE":
    raise SystemExit(f"Expected production evidence conclusion, got {summary.get('conclusion')}")
if not summary.get("productionGateFailureKinds"):
    raise SystemExit("Expected state summary to expose production gate failure kind counts.")
if "productionGateMaxEvidenceAgeSeconds" not in summary:
    raise SystemExit("Expected state summary to expose production gate max evidence age.")
if "productionGateEvidenceStaleCount" not in summary:
    raise SystemExit("Expected state summary to expose production gate evidence stale count.")
blockers = data.get("productionEvidenceBlockers") or []
blocker_codes = set(summary.get("productionEvidenceBlockers") or [])
if int(summary.get("productionEvidenceBlockerCount") or 0) <= 0:
    raise SystemExit("Expected state summary to expose production evidence blocker count.")
if len(blockers) != int(summary.get("productionEvidenceBlockerCount") or 0):
    raise SystemExit("Expected production evidence blocker count to match blocker rows.")
for expected in ("current_production_readiness_missing", "production_acceptance_receipt_missing"):
    if expected not in blocker_codes:
        raise SystemExit(f"Expected production evidence blocker {expected}.")
if not any(str(code).startswith("production_gate_") for code in blocker_codes):
    raise SystemExit("Expected at least one production gate blocker code.")
for row in blockers:
    for key in ("code", "severity", "source", "reason", "action", "commandRole", "command"):
        if not row.get(key):
            raise SystemExit(f"Expected production evidence blocker field {key}.")
action_commands = data.get("productionEvidenceActionCommands") or []
roles = {row.get("role") for row in action_commands}
for expected in ("production-profile", "current-production-readiness", "production-acceptance"):
    if expected not in roles:
        raise SystemExit(f"Expected state summary production evidence action command role {expected}.")
for row in action_commands:
    if "yourdomain.com" in str(row.get("command") or ""):
        raise SystemExit("State summary production evidence action command must not embed placeholder yourdomain targets.")
if "./run_current_production_readiness.sh" not in str(data.get("currentProductionReadinessCommand") or ""):
    raise SystemExit("Expected state summary to expose current production readiness command.")
if not data.get("productionGateFailedScenarios"):
    raise SystemExit("Expected state summary to expose production gate failed scenarios.")
if "./run_production_profile.sh" not in str(data.get("productionProfileCommand") or ""):
    raise SystemExit("Expected state summary to expose production profile command.")
acceptance_command = str(data.get("productionAcceptanceCommand") or "")
if "./run_production_acceptance.sh" not in acceptance_command:
    raise SystemExit("Expected state summary to expose production acceptance command.")
if "PRODUCTION_ACCEPTANCE_RESULT_ROOT=results/production-acceptance" not in acceptance_command:
    raise SystemExit("Expected state summary production acceptance command to use portable production acceptance result root.")
if "BASE_URL=${PRODUCTION_ACCEPTANCE_BASE_URL:?set-PRODUCTION_ACCEPTANCE_BASE_URL}" not in acceptance_command:
    raise SystemExit("Expected state summary production acceptance command to require an explicit production base URL.")
if "TCP_HOST=${PRODUCTION_ACCEPTANCE_TCP_HOST:?set-PRODUCTION_ACCEPTANCE_TCP_HOST}" not in acceptance_command:
    raise SystemExit("Expected state summary production acceptance command to require an explicit production TCP host.")
if "TCP_PORT=${PRODUCTION_ACCEPTANCE_TCP_PORT:?set-PRODUCTION_ACCEPTANCE_TCP_PORT}" not in acceptance_command:
    raise SystemExit("Expected state summary production acceptance command to require an explicit production TCP port.")
if "BASE_URL=https://im.example.com" in acceptance_command or "TCP_HOST=im.example.com" in acceptance_command:
    raise SystemExit("State summary production acceptance command must not reuse the example production target.")
if "ACCOUNT_FILE=${PRODUCTION_ACCEPTANCE_ACCOUNT_FILE:?set-PRODUCTION_ACCEPTANCE_ACCOUNT_FILE}" not in acceptance_command:
    raise SystemExit("Expected state summary production acceptance command to require an explicit full-scale account file.")
if "ACCOUNT_FILE=accounts/load-1000.csv" in acceptance_command:
    raise SystemExit("State summary production acceptance command must not reuse the smoke-scale account file.")
if "IM_CONVERSATION_ID=${PRODUCTION_ACCEPTANCE_CONVERSATION_ID:?set-PRODUCTION_ACCEPTANCE_CONVERSATION_ID}" not in acceptance_command:
    raise SystemExit("Expected state summary production acceptance command to require an explicit production conversation id.")
if "IM_CONVERSATION_ID=00000000-0000-0000-0000-000000000000" in acceptance_command:
    raise SystemExit("State summary production acceptance command must not reuse the smoke-scale conversation id.")
if "PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR:?set-PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR}" not in acceptance_command:
    raise SystemExit("Expected state summary production acceptance command to require expected admin CIDR.")
if "/Users/" in acceptance_command or "/Desktop/" in acceptance_command:
    raise SystemExit("State summary production acceptance command must not embed workstation-specific absolute paths.")
if "./run_production_profile.sh" not in str(data.get("nextCommand") or ""):
    raise SystemExit("Expected state summary nextCommand to prefer production profile command.")
next_command = str(data.get("nextCommand") or "")
if "BASE_URL=${PRODUCTION_PROFILE_BASE_URL:?set-PRODUCTION_PROFILE_BASE_URL}" not in next_command:
    raise SystemExit("Expected state summary nextCommand to require an explicit production profile base URL.")
if "TCP_HOST=${PRODUCTION_PROFILE_TCP_HOST:?set-PRODUCTION_PROFILE_TCP_HOST}" not in next_command:
    raise SystemExit("Expected state summary nextCommand to require an explicit production profile TCP host.")
if "ACCOUNT_FILE=${PRODUCTION_PROFILE_ACCOUNT_FILE:?set-PRODUCTION_PROFILE_ACCOUNT_FILE}" not in next_command:
    raise SystemExit("Expected state summary nextCommand to require an explicit production profile account file.")
if "IM_CONVERSATION_ID=${PRODUCTION_PROFILE_CONVERSATION_ID:?set-PRODUCTION_PROFILE_CONVERSATION_ID}" not in next_command:
    raise SystemExit("Expected state summary nextCommand to require an explicit production profile conversation id.")
if "BASE_URL=https://im.example.com" in next_command or "TCP_HOST=im.example.com" in next_command:
    raise SystemExit("State summary nextCommand must not reuse the example production target.")
if "ACCOUNT_FILE=accounts/load-1000.csv" in next_command:
    raise SystemExit("State summary nextCommand must not reuse the smoke-scale account file.")
if "IM_CONVERSATION_ID=00000000-0000-0000-0000-000000000000" in next_command:
    raise SystemExit("State summary nextCommand must not reuse the placeholder conversation id.")
if "BASE_URL=http://127.0.0.1:8080" in next_command:
    raise SystemExit("State summary nextCommand must not fall back to local HTTP target when production target override is provided.")
if int(summary.get("matrixScenarioCount") or 0) <= 0:
    raise SystemExit("Expected state summary matrix scenario count.")
if not data.get("domains"):
    raise SystemExit("Expected state summary domains.")
PY

  grep -q 'Production Evidence Blockers' "${RESULT_DIR}/state-summary.md"
  grep -q 'Production Evidence Commands' "${RESULT_DIR}/state-summary.md"
  python3 - "${RESULT_DIR}/state-summary.csv" <<'PY'
import csv
import sys

rows = list(csv.DictReader(open(sys.argv[1], newline="")))
summary = next((row for row in rows if row.get("recordType") == "summary"), None)
if summary is None:
    raise SystemExit("Expected state summary CSV summary row.")
if int(summary.get("productionEvidenceBlockerCount") or 0) <= 0:
    raise SystemExit("Expected state summary CSV production evidence blocker count.")
if "production_acceptance_receipt_missing" not in str(summary.get("productionEvidenceBlockers") or ""):
    raise SystemExit("Expected state summary CSV production acceptance blocker.")
if "production-acceptance" not in str(summary.get("productionEvidenceActionCommands") or ""):
    raise SystemExit("Expected state summary CSV production evidence action command roles.")
PY

  cat >"${RESULT_DIR}/state-current-readiness-placeholder-target.json" <<EOF_JSON
{
  "schemaVersion": 1,
  "generatedAtEpoch": $(date +%s),
  "status": "PASS",
  "reason": "ok",
  "target": {
    "baseURL": "https://chat.yourdomain.com",
    "tcpHost": "tcp.yourdomain.com",
    "tcpPort": "9000"
  },
  "evidencePolicy": {
    "requirePackageableEvidence": true,
    "requireCloudSecurityGroup": false,
    "requirePublicPortPolicy": true,
    "operatorNetworkPreflight": true
  },
  "artifacts": {
    "operatorNetworkLog": "state-placeholder-operator-network.log"
  }
}
EOF_JSON
  printf 'operator-network target=https://chat.yourdomain.com host=tcp.yourdomain.com status=pass warning=clean routeInterface=en0 routeGateway=192.0.2.1 proxyEnv=<none>\noperator-network result=pass failures=0 action=none\n' \
    >"${RESULT_DIR}/state-placeholder-operator-network.log"
  python3 "${SCRIPT_DIR}/perf_state_summary.py" \
    --scenario-status-json "${RESULT_DIR}/scenario-status.json" \
    --slo-status-json "${RESULT_DIR}/slo-status.json" \
    --slo-domain-scorecard-json "${RESULT_DIR}/slo-domain-scorecard.json" \
    --readiness-gate-json "${RESULT_DIR}/readiness-gate.json" \
    --next-actions-json "${RESULT_DIR}/next-actions.json" \
    --scenario-catalog-json "${RESULT_DIR}/scenario-catalog.json" \
    --dashboard-json "${RESULT_DIR}/dashboard.json" \
    --run-plan-json "${RESULT_DIR}/run-plan.json" \
    --production-gate-json "${RESULT_DIR}/production-gate-fail.json" \
    --current-readiness-json "${RESULT_DIR}/state-current-readiness-placeholder-target.json" \
    --base-url "https://chat.yourdomain.com" \
    --tcp-host "tcp.yourdomain.com" \
    --tcp-port "9000" \
    --account-file "${SCRIPT_DIR}/accounts/load-1000.csv" \
    --conversation-id "00000000-0000-0000-0000-000000000000" \
    --require-internal-secret \
    --output "${RESULT_DIR}/state-summary-placeholder-target.md" \
    --json-output "${RESULT_DIR}/state-summary-placeholder-target.json" \
    --csv-output "${RESULT_DIR}/state-summary-placeholder-target.csv" >/dev/null
  python3 - "${RESULT_DIR}/state-summary-placeholder-target.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
next_command = str(data.get("nextCommand") or "")
profile_command = str(data.get("productionProfileCommand") or "")
codes = set((data.get("summary") or {}).get("productionEvidenceBlockers") or [])
summary = data.get("summary") or {}
if summary.get("currentReadinessFreshnessStatus") != "PASS":
    raise SystemExit(f"Expected current readiness freshness PASS, got {summary.get('currentReadinessFreshnessStatus')} reason={summary.get('currentReadinessFreshnessReason')}")
age_seconds = summary.get("currentReadinessAgeSeconds")
if age_seconds is None or int(age_seconds) < 0:
    raise SystemExit("Expected non-negative current readiness age in state summary.")
for expected in ("public_https_dns_missing", "public_tcp_dns_missing"):
    if expected not in codes:
        raise SystemExit(f"Expected placeholder target blocker {expected}, got {sorted(codes)}")
for command_name, command in (("nextCommand", next_command), ("productionProfileCommand", profile_command)):
    if "BASE_URL=https://chat.yourdomain.com" in command or "TCP_HOST=tcp.yourdomain.com" in command:
        raise SystemExit(f"Expected {command_name} to reject yourdomain placeholder targets.")
    if "BASE_URL=${PRODUCTION_PROFILE_BASE_URL:?set-PRODUCTION_PROFILE_BASE_URL}" not in command:
        raise SystemExit(f"Expected {command_name} to require production profile base URL for yourdomain placeholder target.")
    if "TCP_HOST=${PRODUCTION_PROFILE_TCP_HOST:?set-PRODUCTION_PROFILE_TCP_HOST}" not in command:
        raise SystemExit(f"Expected {command_name} to require production profile TCP host for yourdomain placeholder target.")
PY

  cat >"${RESULT_DIR}/state-production-acceptance-placeholder-target.json" <<EOF_JSON
{
  "schemaVersion": 1,
  "status": "PASS",
  "reason": "ok",
  "level": "full",
  "target": {
    "baseURL": "https://chat.yourdomain.com",
    "tcpHost": "tcp.yourdomain.com",
    "tcpPort": "9000",
    "requiredAccountRows": 10000
  },
  "policy": {
    "requirePackageableEvidence": true,
    "requireCloudSecurityGroup": true,
    "requireCloudSecurityGroupRepairReceipt": true,
    "requirePublicPortPolicy": true,
    "allowTempHTTP8080": false,
    "cloudSecurityGroupRulesMaxAgeSeconds": 86400,
    "cloudSecurityGroupRulesRequireRootOwner": true,
    "operatorNetworkPreflight": true,
    "cloudSecurityGroupRulesFile": "${RESULT_DIR}/state-production-placeholder-cloud-sg.json",
    "cloudSecurityGroupRepairReceiptJSON": "${RESULT_DIR}/state-production-placeholder-cloud-sg-repair.json",
    "cloudSecurityGroupRepairReceiptExpectSecurityGroupID": "sg-prod",
    "cloudSecurityGroupRepairReceiptExpectRegionID": "cn-shenzhen",
    "cloudSecurityGroupRepairReceiptExpectAdminCIDR": "203.0.113.10/32"
  },
  "artifacts": {
    "packagePresent": true,
    "packageBytes": 1234
  }
}
EOF_JSON
  printf '{}\n' >"${RESULT_DIR}/state-production-placeholder-cloud-sg.json"
  printf '{}\n' >"${RESULT_DIR}/state-production-placeholder-cloud-sg-repair.json"
  python3 "${SCRIPT_DIR}/perf_state_summary.py" \
    --scenario-status-json "${RESULT_DIR}/scenario-status.json" \
    --slo-status-json "${RESULT_DIR}/slo-status.json" \
    --slo-domain-scorecard-json "${RESULT_DIR}/slo-domain-scorecard.json" \
    --readiness-gate-json "${RESULT_DIR}/readiness-gate.json" \
    --next-actions-json "${RESULT_DIR}/next-actions.json" \
    --scenario-catalog-json "${RESULT_DIR}/scenario-catalog.json" \
    --dashboard-json "${RESULT_DIR}/dashboard.json" \
    --run-plan-json "${RESULT_DIR}/run-plan.json" \
    --production-gate-json "${RESULT_DIR}/production-gate-fail.json" \
    --production-acceptance-json "${RESULT_DIR}/state-production-acceptance-placeholder-target.json" \
    --base-url "https://chat.yourdomain.com" \
    --tcp-host "tcp.yourdomain.com" \
    --tcp-port "9000" \
    --account-file "${SCRIPT_DIR}/accounts/load-1000.csv" \
    --conversation-id "00000000-0000-0000-0000-000000000000" \
    --require-internal-secret \
    --output "${RESULT_DIR}/state-summary-production-acceptance-placeholder-target.md" \
    --json-output "${RESULT_DIR}/state-summary-production-acceptance-placeholder-target.json" \
    --csv-output "${RESULT_DIR}/state-summary-production-acceptance-placeholder-target.csv" >/dev/null
  python3 - "${RESULT_DIR}/state-summary-production-acceptance-placeholder-target.json" "${RESULT_DIR}/state-summary-production-acceptance-placeholder-target.csv" <<'PY'
import csv
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
next_command = str(data.get("nextCommand") or "")
profile_command = str(data.get("productionProfileCommand") or "")
codes = set((data.get("summary") or {}).get("productionEvidenceBlockers") or [])
for expected in ("production_acceptance_https_dns_missing", "production_acceptance_tcp_dns_missing"):
    if expected not in codes:
        raise SystemExit(f"Expected production acceptance placeholder target blocker {expected}, got {sorted(codes)}")
for command_name, command in (("nextCommand", next_command), ("productionProfileCommand", profile_command)):
    if "BASE_URL=https://chat.yourdomain.com" in command or "TCP_HOST=tcp.yourdomain.com" in command:
        raise SystemExit(f"Expected {command_name} to reject production acceptance yourdomain placeholder targets.")
    if "BASE_URL=${PRODUCTION_PROFILE_BASE_URL:?set-PRODUCTION_PROFILE_BASE_URL}" not in command:
        raise SystemExit(f"Expected {command_name} to require production profile base URL for production acceptance placeholder target.")
    if "TCP_HOST=${PRODUCTION_PROFILE_TCP_HOST:?set-PRODUCTION_PROFILE_TCP_HOST}" not in command:
        raise SystemExit(f"Expected {command_name} to require production profile TCP host for production acceptance placeholder target.")
rows = list(csv.DictReader(open(sys.argv[2], newline="")))
summary = next((row for row in rows if row.get("recordType") == "summary"), None)
if summary is None:
    raise SystemExit("Expected production acceptance placeholder state summary CSV summary row.")
for expected in ("production_acceptance_https_dns_missing", "production_acceptance_tcp_dns_missing"):
    if expected not in str(summary.get("productionEvidenceBlockers") or ""):
        raise SystemExit(f"Expected production acceptance placeholder blocker {expected} in CSV.")
PY
  grep -q 'Production Evidence Blockers' "${RESULT_DIR}/state-summary-production-acceptance-placeholder-target.md"
  python3 "${SCRIPT_DIR}/perf_dashboard.py" \
    --scenario-status-json "${RESULT_DIR}/scenario-status.json" \
    --slo-status-json "${RESULT_DIR}/slo-status.json" \
    --slo-domain-scorecard-json "${RESULT_DIR}/slo-domain-scorecard.json" \
    --slo-domain-run-plan-json "${RESULT_DIR}/slo-domain-run-plan.json" \
    --next-actions-json "${RESULT_DIR}/next-actions.json" \
    --scenario-catalog-json "${RESULT_DIR}/scenario-catalog.json" \
    --domain-backlog-json "${RESULT_DIR}/domain-backlog.json" \
    --run-plan-json "${RESULT_DIR}/run-plan.json" \
    --domain-run-plan-json "${RESULT_DIR}/domain-run-plan.json" \
    --domain-scorecard-json "${RESULT_DIR}/domain-scorecard.json" \
    --prereq-audit-json "${RESULT_DIR}/prereq-audit.json" \
    --readiness-gate-json "${RESULT_DIR}/readiness-gate.json" \
    --production-gate-json "${RESULT_DIR}/production-gate-fail.json" \
    --production-acceptance-json "${RESULT_DIR}/state-production-acceptance-placeholder-target.json" \
    --base-url "https://chat.yourdomain.com" \
    --tcp-host "tcp.yourdomain.com" \
    --tcp-port "9000" \
    --account-file "${SCRIPT_DIR}/accounts/load-1000.csv" \
    --conversation-id "00000000-0000-0000-0000-000000000000" \
    --require-internal-secret \
    --output "${RESULT_DIR}/dashboard-production-acceptance-placeholder-target.md" \
    --json-output "${RESULT_DIR}/dashboard-production-acceptance-placeholder-target.json" >/dev/null
  python3 - "${RESULT_DIR}/dashboard-production-acceptance-placeholder-target.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
next_command = str(data.get("nextCommand") or "")
profile_command = str(data.get("productionProfileCommand") or "")
codes = set((data.get("summary") or {}).get("productionEvidenceBlockers") or [])
for expected in ("production_acceptance_https_dns_missing", "production_acceptance_tcp_dns_missing"):
    if expected not in codes:
        raise SystemExit(f"Expected dashboard production acceptance placeholder target blocker {expected}, got {sorted(codes)}")
for command_name, command in (("nextCommand", next_command), ("productionProfileCommand", profile_command)):
    if "BASE_URL=https://chat.yourdomain.com" in command or "TCP_HOST=tcp.yourdomain.com" in command:
        raise SystemExit(f"Expected dashboard {command_name} to reject production acceptance yourdomain placeholder targets.")
    if "BASE_URL=${PRODUCTION_PROFILE_BASE_URL:?set-PRODUCTION_PROFILE_BASE_URL}" not in command:
        raise SystemExit(f"Expected dashboard {command_name} to require production profile base URL for production acceptance placeholder target.")
    if "TCP_HOST=${PRODUCTION_PROFILE_TCP_HOST:?set-PRODUCTION_PROFILE_TCP_HOST}" not in command:
        raise SystemExit(f"Expected dashboard {command_name} to require production profile TCP host for production acceptance placeholder target.")
if len(data.get("productionEvidenceBlockers") or []) != int((data.get("summary") or {}).get("productionEvidenceBlockerCount") or 0):
    raise SystemExit("Expected dashboard production acceptance placeholder blocker rows to match summary count.")
PY
  grep -q 'Production Evidence Blockers' "${RESULT_DIR}/dashboard-production-acceptance-placeholder-target.md"

  cat >"${RESULT_DIR}/state-current-readiness-operator.json" <<EOF_JSON
{
  "schemaVersion": 1,
  "generatedAtEpoch": $(date +%s),
  "status": "PASS",
  "reason": "ok",
  "target": {
    "baseURL": "https://im.example.com",
    "tcpHost": "im.example.com",
    "tcpPort": "9000"
  },
  "evidencePolicy": {
    "requirePackageableEvidence": true,
    "requireCloudSecurityGroup": false,
    "requirePublicPortPolicy": true,
    "allowTempHTTP8080": false,
    "cloudSecurityGroupRulesMaxAgeSeconds": 86400,
    "cloudSecurityGroupRulesRequireRootOwner": false,
    "operatorNetworkPreflight": true
  },
  "artifacts": {
    "operatorNetworkLog": "${RESULT_DIR}/state-operator-network.log"
  }
}
EOF_JSON
  printf 'operator-network target=https://im.example.com host=im.example.com status=fail warning=tun_route routeInterface=utun8 routeGateway=198.18.0.1 proxyEnv=<none>\noperator-network result=fail failures=1 action=disconnect_local_tun_or_use_clean_network\n' \
    >"${RESULT_DIR}/state-operator-network.log"
  cat >"${RESULT_DIR}/state-production-acceptance-operator.json" <<EOF_JSON
{
  "schemaVersion": 1,
  "status": "PASS",
  "reason": "ok",
  "level": "full",
  "target": {
    "baseURL": "https://im.example.com",
    "tcpHost": "im.example.com",
    "tcpPort": "9000",
    "requiredAccountRows": 10000
  },
  "policy": {
    "requirePackageableEvidence": true,
    "requireCloudSecurityGroup": true,
    "requireCloudSecurityGroupRepairReceipt": true,
    "requirePublicPortPolicy": true,
    "allowTempHTTP8080": false,
    "cloudSecurityGroupRulesMaxAgeSeconds": 86400,
    "cloudSecurityGroupRulesRequireRootOwner": true,
    "operatorNetworkPreflight": false,
    "cloudSecurityGroupRulesFile": "${RESULT_DIR}/state-cloud-sg.json",
    "cloudSecurityGroupRepairReceiptJSON": "${RESULT_DIR}/state-cloud-sg-repair.json",
    "cloudSecurityGroupRepairReceiptExpectSecurityGroupID": "sg-prod",
    "cloudSecurityGroupRepairReceiptExpectRegionID": "cn-shenzhen",
    "cloudSecurityGroupRepairReceiptExpectAdminCIDR": "203.0.113.10/32"
  },
  "artifacts": {
    "packagePresent": true,
    "packageBytes": 1234
  }
}
EOF_JSON
  printf '{}\n' >"${RESULT_DIR}/state-cloud-sg.json"
  printf '{}\n' >"${RESULT_DIR}/state-cloud-sg-repair.json"
  python3 "${SCRIPT_DIR}/perf_state_summary.py" \
    --scenario-status-json "${RESULT_DIR}/scenario-status.json" \
    --slo-status-json "${RESULT_DIR}/slo-status.json" \
    --slo-domain-scorecard-json "${RESULT_DIR}/slo-domain-scorecard.json" \
    --readiness-gate-json "${RESULT_DIR}/readiness-gate.json" \
    --next-actions-json "${RESULT_DIR}/next-actions.json" \
    --scenario-catalog-json "${RESULT_DIR}/scenario-catalog.json" \
    --dashboard-json "${RESULT_DIR}/dashboard.json" \
    --run-plan-json "${RESULT_DIR}/run-plan.json" \
    --production-gate-json "${RESULT_DIR}/production-gate-fail.json" \
    --current-readiness-json "${RESULT_DIR}/state-current-readiness-operator.json" \
    --production-acceptance-json "${RESULT_DIR}/state-production-acceptance-operator.json" \
    --base-url "https://im.example.com" \
    --tcp-host "im.example.com" \
    --tcp-port "9000" \
    --account-file "${SCRIPT_DIR}/accounts/load-1000.csv" \
    --conversation-id "00000000-0000-0000-0000-000000000000" \
    --require-internal-secret \
    --output "${RESULT_DIR}/state-summary-operator.md" \
    --json-output "${RESULT_DIR}/state-summary-operator.json" \
    --csv-output "${RESULT_DIR}/state-summary-operator.csv" >/dev/null

  python3 - "${RESULT_DIR}/state-summary-operator.json" "${RESULT_DIR}/state-summary-operator.csv" <<'PY'
import csv
import json
import sys

data = json.load(open(sys.argv[1]))
summary = data.get("summary") or {}
codes = set(summary.get("productionEvidenceBlockers") or [])
for expected in ("operator_network_failed", "operator_network_warning", "operator_network_preflight_policy_missing"):
    if expected not in codes:
        raise SystemExit(f"Expected operator network production evidence blocker {expected}.")
if summary.get("currentReadinessOperatorNetworkPreflight") is not True:
    raise SystemExit("Expected current readiness operator network policy in state summary.")
if summary.get("currentReadinessFreshnessStatus") != "PASS":
    raise SystemExit("Expected current readiness freshness PASS in state summary.")
if summary.get("currentReadinessOperatorNetworkLogPresent") is not True:
    raise SystemExit("Expected current readiness operator network log presence in state summary.")
if summary.get("currentReadinessOperatorNetworkFailed") is not True:
    raise SystemExit("Expected current readiness operator network failure in state summary.")
if "tun_route" not in (summary.get("currentReadinessOperatorNetworkWarnings") or []):
    raise SystemExit("Expected current readiness operator network warning in state summary.")
if "utun8" not in (summary.get("currentReadinessOperatorNetworkRouteInterfaces") or []):
    raise SystemExit("Expected current readiness operator network route interface in state summary.")
if "198.18.0.1" not in (summary.get("currentReadinessOperatorNetworkRouteGateways") or []):
    raise SystemExit("Expected current readiness operator network route gateway in state summary.")
if summary.get("productionAcceptanceOperatorNetworkPreflight") is not False:
    raise SystemExit("Expected production acceptance operator network policy in state summary.")

rows = list(csv.DictReader(open(sys.argv[2], newline="")))
csv_summary = next((row for row in rows if row.get("recordType") == "summary"), None)
if csv_summary is None:
    raise SystemExit("Expected operator state summary CSV summary row.")
if csv_summary.get("currentReadinessOperatorNetworkFailed") != "True":
    raise SystemExit("Expected operator network failure in state summary CSV.")
if csv_summary.get("currentReadinessFreshnessStatus") != "PASS":
    raise SystemExit("Expected current readiness freshness in state summary CSV.")
if "operator_network_failed" not in str(csv_summary.get("productionEvidenceBlockers") or ""):
    raise SystemExit("Expected operator network blocker in state summary CSV.")
PY

  python3 - "${SCRIPT_DIR}" "${RESULT_DIR}/state-summary.json" "${RESULT_DIR}/state-summary.csv" <<'PY'
import copy
import json
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from perf_current_production_readiness_verify import require_state_production_evidence_blocker_contract

state = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
csv_path = Path(sys.argv[3])
require_state_production_evidence_blocker_contract(state, csv_path)
bad_state = copy.deepcopy(state)
bad_state["summary"]["productionEvidenceBlockerCount"] = 0
bad_state["summary"]["productionEvidenceBlockers"] = []
bad_state["productionEvidenceBlockers"] = []
try:
    require_state_production_evidence_blocker_contract(bad_state, None)
except SystemExit as exc:
    if "state_production_evidence_blockers_missing" not in str(exc):
        raise
else:
    raise SystemExit("Expected current production readiness verifier to reject NEEDS_PRODUCTION_EVIDENCE without blockers.")
bad_state = copy.deepcopy(state)
bad_state["productionEvidenceBlockers"][0]["command"] = ""
try:
    require_state_production_evidence_blocker_contract(bad_state, None)
except SystemExit as exc:
    if "state_production_evidence_blocker_field_missing" not in str(exc):
        raise
else:
    raise SystemExit("Expected current production readiness verifier to reject production blockers without commands.")
bad_state = copy.deepcopy(state)
bad_state["productionEvidenceActionCommands"] = []
bad_state["summary"]["productionEvidenceActionCommands"] = []
try:
    require_state_production_evidence_blocker_contract(bad_state, None)
except SystemExit as exc:
    if "state_production_evidence_action_commands_missing" not in str(exc):
        raise
else:
    raise SystemExit("Expected current production readiness verifier to reject missing production evidence action commands.")
bad_state = copy.deepcopy(state)
bad_state["productionEvidenceBlockers"][0]["commandRole"] = "production-acceptance"
try:
    require_state_production_evidence_blocker_contract(bad_state, None)
except SystemExit as exc:
    if "state_production_evidence_blocker_command_role_mismatch" not in str(exc):
        raise
else:
    raise SystemExit("Expected current production readiness verifier to reject mismatched production evidence command role.")
PY

  python3 - "${RESULT_DIR}/dashboard.json" "${RESULT_DIR}/state-summary.json" "${RESULT_DIR}/optimization-playbook.json" "${RESULT_DIR}/readiness-gate.json" "${RESULT_DIR}/production-gate-fail.json" <<'PY'
import json
import sys

dashboard = json.load(open(sys.argv[1]))
state = json.load(open(sys.argv[2]))
playbook = json.load(open(sys.argv[3]))
readiness = json.load(open(sys.argv[4]))
production_gate = json.load(open(sys.argv[5]))

if production_gate.get("status") != "FAIL":
    raise SystemExit("Expected failing production gate fixture.")
dashboard_command = str(dashboard.get("nextCommand") or "")
state_command = str(state.get("nextCommand") or "")
dashboard_acceptance_command = str(dashboard.get("productionAcceptanceCommand") or "")
state_acceptance_command = str(state.get("productionAcceptanceCommand") or "")
dashboard_current_command = str(dashboard.get("currentProductionReadinessCommand") or "")
state_current_command = str(state.get("currentProductionReadinessCommand") or "")
playbook_first = (playbook.get("workItems") or [{}])[0]
playbook_commands = playbook_first.get("commands") or []
playbook_command = str(playbook_commands[0] if playbook_commands else "")
playbook_current_command = next((str(command) for command in playbook_commands if "./run_current_production_readiness.sh" in str(command)), "")
playbook_acceptance_command = next((str(command) for command in playbook_commands if "./run_production_acceptance.sh" in str(command)), "")
readiness_command = str(readiness.get("nextCommand") or "")
readiness_current_command = str(readiness.get("currentProductionReadinessCommand") or "")
readiness_acceptance_command = str(readiness.get("productionAcceptanceCommand") or "")
if not dashboard_command or dashboard_command != state_command or state_command != playbook_command or playbook_command != readiness_command:
    raise SystemExit("Expected dashboard, state summary, optimization playbook, and readiness gate to agree on the production profile command.")
if (
    not dashboard_current_command
    or dashboard_current_command != state_current_command
    or state_current_command != playbook_current_command
    or playbook_current_command != readiness_current_command
):
    raise SystemExit("Expected dashboard, state summary, optimization playbook, and readiness gate to agree on the current production readiness command.")
if (
    not dashboard_acceptance_command
    or dashboard_acceptance_command != state_acceptance_command
    or state_acceptance_command != playbook_acceptance_command
    or playbook_acceptance_command != readiness_acceptance_command
):
    raise SystemExit("Expected dashboard, state summary, optimization playbook, and readiness gate to agree on the production acceptance command.")
if "./run_production_profile.sh" not in dashboard_command:
    raise SystemExit("Expected cross-report next command to run production profile.")
if "./run_production_acceptance.sh" not in dashboard_acceptance_command:
    raise SystemExit("Expected cross-report production acceptance command to run production acceptance.")
if "RESULT_ROOT=results/production-acceptance" not in dashboard_command:
    raise SystemExit("Expected cross-report production profile command to use portable production acceptance result root.")
if "PRODUCTION_ACCEPTANCE_RESULT_ROOT=results/production-acceptance" not in dashboard_acceptance_command:
    raise SystemExit("Expected cross-report production acceptance command to use portable production acceptance result root.")
if "BASE_URL=${PRODUCTION_PROFILE_BASE_URL:?set-PRODUCTION_PROFILE_BASE_URL}" not in dashboard_command:
    raise SystemExit("Expected cross-report production profile command to require an explicit production base URL.")
if "TCP_HOST=${PRODUCTION_PROFILE_TCP_HOST:?set-PRODUCTION_PROFILE_TCP_HOST}" not in dashboard_command:
    raise SystemExit("Expected cross-report production profile command to require an explicit production TCP host.")
if "ACCOUNT_FILE=${PRODUCTION_PROFILE_ACCOUNT_FILE:?set-PRODUCTION_PROFILE_ACCOUNT_FILE}" not in dashboard_command:
    raise SystemExit("Expected cross-report production profile command to require an explicit production account file.")
if "IM_CONVERSATION_ID=${PRODUCTION_PROFILE_CONVERSATION_ID:?set-PRODUCTION_PROFILE_CONVERSATION_ID}" not in dashboard_command:
    raise SystemExit("Expected cross-report production profile command to require an explicit production conversation id.")
if "BASE_URL=https://im.example.com" in dashboard_command or "TCP_HOST=im.example.com" in dashboard_command:
    raise SystemExit("Cross-report production profile command must not reuse the example production target.")
if "ACCOUNT_FILE=accounts/load-1000.csv" in dashboard_command:
    raise SystemExit("Cross-report production profile command must not reuse the smoke-scale account file.")
if "IM_CONVERSATION_ID=00000000-0000-0000-0000-000000000000" in dashboard_command:
    raise SystemExit("Cross-report production profile command must not reuse the placeholder conversation id.")
if "BASE_URL=${PRODUCTION_ACCEPTANCE_BASE_URL:?set-PRODUCTION_ACCEPTANCE_BASE_URL}" not in dashboard_acceptance_command:
    raise SystemExit("Expected cross-report production acceptance command to require an explicit production base URL.")
if "TCP_HOST=${PRODUCTION_ACCEPTANCE_TCP_HOST:?set-PRODUCTION_ACCEPTANCE_TCP_HOST}" not in dashboard_acceptance_command:
    raise SystemExit("Expected cross-report production acceptance command to require an explicit production TCP host.")
if "TCP_PORT=${PRODUCTION_ACCEPTANCE_TCP_PORT:?set-PRODUCTION_ACCEPTANCE_TCP_PORT}" not in dashboard_acceptance_command:
    raise SystemExit("Expected cross-report production acceptance command to require an explicit production TCP port.")
if "BASE_URL=https://im.example.com" in dashboard_acceptance_command or "TCP_HOST=im.example.com" in dashboard_acceptance_command:
    raise SystemExit("Cross-report production acceptance command must not reuse the example production target.")
if "ACCOUNT_FILE=${PRODUCTION_ACCEPTANCE_ACCOUNT_FILE:?set-PRODUCTION_ACCEPTANCE_ACCOUNT_FILE}" not in dashboard_acceptance_command:
    raise SystemExit("Expected cross-report production acceptance command to require an explicit full-scale account file.")
if "ACCOUNT_FILE=accounts/load-1000.csv" in dashboard_acceptance_command:
    raise SystemExit("Cross-report production acceptance command must not reuse the smoke-scale account file.")
if "IM_CONVERSATION_ID=${PRODUCTION_ACCEPTANCE_CONVERSATION_ID:?set-PRODUCTION_ACCEPTANCE_CONVERSATION_ID}" not in dashboard_acceptance_command:
    raise SystemExit("Expected cross-report production acceptance command to require an explicit production conversation id.")
if "IM_CONVERSATION_ID=00000000-0000-0000-0000-000000000000" in dashboard_acceptance_command:
    raise SystemExit("Cross-report production acceptance command must not reuse the smoke-scale conversation id.")
if "cd IMServer/LoadTests &&" not in dashboard_command:
    raise SystemExit("Expected cross-report production profile command to be runnable from the repository root.")
if "cd IMServer/LoadTests &&" not in dashboard_acceptance_command:
    raise SystemExit("Expected cross-report production acceptance command to be runnable from the repository root.")
if "/Users/" in dashboard_command or "/Desktop/" in dashboard_command:
    raise SystemExit("Cross-report production profile command must not embed workstation-specific absolute paths.")
if "/Users/" in dashboard_acceptance_command or "/Desktop/" in dashboard_acceptance_command:
    raise SystemExit("Cross-report production acceptance command must not embed workstation-specific absolute paths.")
required_acceptance_tokens = [
    "PRODUCTION_ACCEPTANCE_PACKAGE_EVIDENCE=true",
    "BASE_URL=${PRODUCTION_ACCEPTANCE_BASE_URL:?set-PRODUCTION_ACCEPTANCE_BASE_URL}",
    "TCP_HOST=${PRODUCTION_ACCEPTANCE_TCP_HOST:?set-PRODUCTION_ACCEPTANCE_TCP_HOST}",
    "TCP_PORT=${PRODUCTION_ACCEPTANCE_TCP_PORT:?set-PRODUCTION_ACCEPTANCE_TCP_PORT}",
    "ACCOUNT_FILE=${PRODUCTION_ACCEPTANCE_ACCOUNT_FILE:?set-PRODUCTION_ACCEPTANCE_ACCOUNT_FILE}",
    "IM_CONVERSATION_ID=${PRODUCTION_ACCEPTANCE_CONVERSATION_ID:?set-PRODUCTION_ACCEPTANCE_CONVERSATION_ID}",
    "PRODUCTION_ACCEPTANCE_RECEIPT_MAX_AGE_SECONDS=86400",
    "PRODUCTION_ACCEPTANCE_RECEIPT_MAX_FUTURE_SKEW_SECONDS=300",
    "PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS=86400",
    "IM_INTERNAL_SECRET=${IM_INTERNAL_SECRET:?set-IM_INTERNAL_SECRET}",
    "PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_RULES_FILE=${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_RULES_FILE:?set-PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_RULES_FILE}",
    "PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON=${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON:?set-PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON}",
    "PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID:?set-PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID}",
    "PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID:?set-PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID}",
    "PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=${PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR:?set-PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR}",
]
missing_acceptance_tokens = [token for token in required_acceptance_tokens if token not in dashboard_acceptance_command]
if missing_acceptance_tokens:
    raise SystemExit(f"Expected cross-report production acceptance command tokens missing: {missing_acceptance_tokens}")
dashboard_failed = {row.get("scenario") for row in dashboard.get("productionGateFailedScenarios") or []}
state_failed = {row.get("scenario") for row in state.get("productionGateFailedScenarios") or []}
playbook_failed = set(playbook_first.get("requiredScenarios") or [])
readiness_failed = {row.get("scenario") for row in readiness.get("productionGateFailedScenarios") or []}
gate_failed = {row.get("scenario") for row in production_gate.get("requiredScenarios") or [] if not row.get("passed")}
if not gate_failed:
    raise SystemExit("Expected failing production gate scenarios.")
if dashboard_failed != state_failed or state_failed != playbook_failed or playbook_failed != readiness_failed or readiness_failed != gate_failed:
    raise SystemExit("Expected production gate failed scenario sets to match across dashboard, state summary, playbook, readiness gate, and gate JSON.")
PY

  python3 "${SCRIPT_DIR}/perf_state_summary.py" \
    --scenario-status-json "${RESULT_DIR}/scenario-status.json" \
    --slo-status-json "${RESULT_DIR}/slo-status.json" \
    --slo-domain-scorecard-json "${RESULT_DIR}/slo-domain-scorecard.json" \
    --readiness-gate-json "${RESULT_DIR}/readiness-gate.json" \
    --next-actions-json "${RESULT_DIR}/next-actions.json" \
    --scenario-catalog-json "${RESULT_DIR}/scenario-catalog.json" \
    --dashboard-json "${RESULT_DIR}/dashboard.json" \
    --run-plan-json "${RESULT_DIR}/run-plan.json" \
    --production-gate-json "${RESULT_DIR}/production-gate-fail.json" \
    --entrypoint-rescue-summary "${RESULT_DIR}/entrypoint-rescue-summary.txt" \
    --json-output "${RESULT_DIR}/state-summary-entrypoint-blocked.json" >/dev/null
  python3 - "${RESULT_DIR}/state-summary-entrypoint-blocked.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
summary = data.get("summary") or {}
if summary.get("conclusion") != "BLOCKED_ENTRYPOINT":
    raise SystemExit(f"Expected BLOCKED_ENTRYPOINT, got {summary.get('conclusion')}")
if summary.get("entrypointRescueAction") != "cloud_console_rescue_required":
    raise SystemExit("Expected entrypoint rescue action in state summary.")
if summary.get("entrypointRescueDiagnosis") != "public_listener_not_imserver_nginx":
    raise SystemExit("Expected entrypoint rescue diagnosis in state summary.")
if "entrypoint-rescue-plan.md" not in str(data.get("nextCommand") or ""):
    raise SystemExit("Expected state summary nextCommand to point to the entrypoint rescue plan.")
PY

fi

if bool_enabled "${VALIDATE_TCP_LADDER_TEST}"; then
  log "tcp ladder self-test"
  "${SCRIPT_DIR}/tcp_capacity_ladder_test.sh"
fi

if bool_enabled "${VALIDATE_SWIFT_BUILD}"; then
  log "TCPDriver swift build"
  swift build -c release --package-path "${SCRIPT_DIR}/TCPDriver"
fi

log "summary"
if bool_enabled "${VALIDATE_DRY_RUN}"; then
python3 - "${RESULT_DIR}/coverage.json" "${RESULT_DIR}/route-audit.json" "${RESULT_DIR}/matrix-audit.json" "${RESULT_DIR}/production-profile-audit.json" "${RESULT_DIR}/product-profile-gate.json" "${RESULT_DIR}/product-campaign-audit.json" "${RESULT_DIR}/default-profile-audit.json" "${RESULT_DIR}/docs-audit.json" "${RESULT_DIR}/validation-inventory.json" "${RESULT_DIR}/scenario-catalog.json" "${RESULT_DIR}/domain-backlog.json" "${RESULT_DIR}/domain-run-plan.json" "${RESULT_DIR}/domain-scorecard.json" "${RESULT_DIR}/prereq-audit.json" "${RESULT_DIR}/domain-compare.json" "${RESULT_DIR}/readiness-gate.json" "${RESULT_DIR}/dashboard.json" "${RESULT_DIR}/optimization-playbook.json" "${RESULT_DIR}/slo.json" "${RESULT_DIR}/slo-status.json" "${RESULT_DIR}/slo-domain-scorecard.json" "${RESULT_DIR}/slo-domain-run-plan.json" "${RESULT_DIR}/state-summary.json" "${RESULT_DIR}/production-gate-fail.json" <<'PY'
import json
import sys

coverage = json.load(open(sys.argv[1]))
route = json.load(open(sys.argv[2]))
matrix = json.load(open(sys.argv[3]))
profile_audit = json.load(open(sys.argv[4]))
product_profile_gate = json.load(open(sys.argv[5]))
product_campaign_audit = json.load(open(sys.argv[6]))
default_profile = json.load(open(sys.argv[7]))
docs = json.load(open(sys.argv[8]))
inventory = json.load(open(sys.argv[9]))
catalog = json.load(open(sys.argv[10]))
backlog = json.load(open(sys.argv[11]))
domain_plan = json.load(open(sys.argv[12]))
scorecard = json.load(open(sys.argv[13]))
prereq = json.load(open(sys.argv[14]))
domain_compare = json.load(open(sys.argv[15]))
readiness = json.load(open(sys.argv[16]))
dashboard = json.load(open(sys.argv[17]))
playbook = json.load(open(sys.argv[18]))
slo = json.load(open(sys.argv[19]))
slo_status = json.load(open(sys.argv[20]))
slo_domain = json.load(open(sys.argv[21]))
slo_domain_plan = json.load(open(sys.argv[22]))
state_summary = json.load(open(sys.argv[23]))
production_gate = json.load(open(sys.argv[24]))
print(f"criticalCoverage={coverage['coveredCriticalEndpointCount']}/{coverage['criticalEndpointCount']}")
print(f"routeMissing={route['missingManifestRouteCount']} routeOrphans={route['orphanCoverageEndpointCount']}")
print(f"matrixScenarios={matrix['listedScenarioCount']} matrixErrors={matrix['errorCount']} matrixWarnings={matrix['warningCount']}")
print(f"productionProfiles={profile_audit['profileCount']} productionProfileErrors={profile_audit['errorCount']} productionProfileWarnings={profile_audit['warningCount']}")
print(f"productProfileGate={product_profile_gate['status']} checked={product_profile_gate['profileCount']} requiredDomains={len(product_profile_gate['requiredDomains'])} errors={product_profile_gate['errorCount']}")
print(f"productCampaignAudit={product_campaign_audit['status']} campaigns={product_campaign_audit['campaignCount']} requiredPhasePolicies={len(product_campaign_audit.get('requiredPhasePolicies') or [])} errors={product_campaign_audit['errorCount']} warnings={product_campaign_audit['warningCount']}")
print(f"defaultProfileAudit={default_profile['status']} checked={default_profile['checkedCount']} errors={default_profile['errorCount']} expected={default_profile['expectedDefaultProfile']}")
print(f"docsAudit={docs['status']} docsGroups={docs['presetsGroupCount']}/{docs['listedGroupCount']} docsErrors={docs['errorCount']} inventoryDocs={inventory['summary'].get('docs', 0)}")
print(f"scenarioDomains={catalog['summary']['domainCount']} maturityGaps={catalog['summary']['maturityGapCount']}")
print(f"domainBacklogActions={backlog['summary']['openActionCount']} globalBlockers={backlog['summary']['globalBlockerCount']}")
print(f"domainRunPlanStatus={domain_plan['status']} domainBatches={len(domain_plan.get('domainPlans') or [])}")
print(f"domainScorecardStatus={scorecard['summary']['overallStatus']} readyDomains={scorecard['summary']['readinessCounts'].get('READY', 0)}")
print(f"prereqStatus={prereq['summary']['overallStatus']} missingRequired={prereq['summary']['missingRequiredCount']} missingRecommended={prereq['summary']['missingRecommendedCount']}")
print(f"domainCompareRegressions={domain_compare['domainRegressionCount']} domainCompareImprovements={domain_compare['domainImprovementCount']}")
print(f"readinessGate={readiness['status']} readinessFailures={readiness['failureCount']}")
print(f"productionGate={production_gate['status']} productionGateFailed={production_gate['summary']['failedScenarioCount']}")
print(f"dashboardReadiness={dashboard['summary']['readinessGate']} dashboardRunPlan={dashboard['summary']['runPlan']}")
print(f"playbookItems={playbook['summary']['itemCount']}")
print(f"sloStatus={slo['summary']['status']} sloFail={slo['summary']['fail']} sloUnknown={slo['summary']['unknown']}")
extra_counts = slo_status.get('extraSLOStatusCounts') or {}
print(f"sloMatrix={slo_status['matrixScenarioCount']} sloLatestFail={slo_status['latestSLOStatusCounts']['FAIL']} sloLatestUnknown={slo_status['latestSLOStatusCounts']['UNKNOWN']} sloLatestNever={slo_status['latestSLOStatusCounts']['NEVER_RUN']} sloExtraFail={extra_counts.get('FAIL', 0)}")
print(f"sloDomainStatus={slo_domain['summary']['overallStatus']} sloDomainCount={slo_domain['summary']['domainCount']}")
print(f"sloDomainRunPlanStatus={slo_domain_plan['status']} sloDomainRunPlanBatches={len(slo_domain_plan.get('domainPlans') or [])}")
print(f"stateSummary={state_summary['summary']['conclusion']} stateScenarioRun={state_summary['summary']['ranScenarioCount']}/{state_summary['summary']['matrixScenarioCount']}")
PY
else
python3 - "${RESULT_DIR}/coverage.json" "${RESULT_DIR}/route-audit.json" "${RESULT_DIR}/matrix-audit.json" "${RESULT_DIR}/production-profile-audit.json" "${RESULT_DIR}/product-profile-gate.json" "${RESULT_DIR}/product-campaign-audit.json" "${RESULT_DIR}/default-profile-audit.json" "${RESULT_DIR}/docs-audit.json" "${RESULT_DIR}/validation-inventory.json" "${RESULT_DIR}/scenario-catalog.json" <<'PY'
import json
import sys

coverage = json.load(open(sys.argv[1]))
route = json.load(open(sys.argv[2]))
matrix = json.load(open(sys.argv[3]))
profile_audit = json.load(open(sys.argv[4]))
product_profile_gate = json.load(open(sys.argv[5]))
product_campaign_audit = json.load(open(sys.argv[6]))
default_profile = json.load(open(sys.argv[7]))
docs = json.load(open(sys.argv[8]))
inventory = json.load(open(sys.argv[9]))
catalog = json.load(open(sys.argv[10]))
print(f"criticalCoverage={coverage['coveredCriticalEndpointCount']}/{coverage['criticalEndpointCount']}")
print(f"routeMissing={route['missingManifestRouteCount']} routeOrphans={route['orphanCoverageEndpointCount']}")
print(f"matrixScenarios={matrix['listedScenarioCount']} matrixErrors={matrix['errorCount']} matrixWarnings={matrix['warningCount']}")
print(f"productionProfiles={profile_audit['profileCount']} productionProfileErrors={profile_audit['errorCount']} productionProfileWarnings={profile_audit['warningCount']}")
print(f"productProfileGate={product_profile_gate['status']} checked={product_profile_gate['profileCount']} requiredDomains={len(product_profile_gate['requiredDomains'])} errors={product_profile_gate['errorCount']}")
print(f"productCampaignAudit={product_campaign_audit['status']} campaigns={product_campaign_audit['campaignCount']} requiredPhasePolicies={len(product_campaign_audit.get('requiredPhasePolicies') or [])} errors={product_campaign_audit['errorCount']} warnings={product_campaign_audit['warningCount']}")
print(f"defaultProfileAudit={default_profile['status']} checked={default_profile['checkedCount']} errors={default_profile['errorCount']} expected={default_profile['expectedDefaultProfile']}")
print(f"docsAudit={docs['status']} docsGroups={docs['presetsGroupCount']}/{docs['listedGroupCount']} docsErrors={docs['errorCount']} inventoryDocs={inventory['summary'].get('docs', 0)}")
print(f"scenarioDomains={catalog['summary']['domainCount']} maturityGaps={catalog['summary']['maturityGapCount']}")
print("dryRunSummary=skipped")
PY
fi

log "load-test validation passed"
