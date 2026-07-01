#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${PRODUCTION_ACCEPTANCE_ENV_FILE:-${SCRIPT_DIR}/production-acceptance.env}"
MODE="${PRODUCTION_ACCEPTANCE_ENV_MODE:-run}"
SELF_TEST="${PRODUCTION_ACCEPTANCE_ENV_SELF_TEST:-false}"
PRODUCTION_TARGET_POLICY="${PRODUCTION_TARGET_POLICY:-${SCRIPT_DIR}/production_target_policy.py}"
export PRODUCTION_TARGET_POLICY
PRODUCTION_TOPOLOGY_SMOKE_VERIFIER="${PRODUCTION_TOPOLOGY_SMOKE_VERIFIER:-${SCRIPT_DIR}/../scripts/verify_production_smoke.py}"
export PRODUCTION_TOPOLOGY_SMOKE_VERIFIER

usage() {
  cat <<'EOF'
Usage:
  IM_INTERNAL_SECRET=<secret> \
  PRODUCTION_ACCEPTANCE_ENV_FILE=IMServer/LoadTests/production-acceptance.env \
    ./validate_production_acceptance_env.sh

Modes:
  PRODUCTION_ACCEPTANCE_ENV_MODE=run     Validate inputs before run_production_acceptance.sh.
  PRODUCTION_ACCEPTANCE_ENV_MODE=verify  Also require topology smoke, deploy readiness, production acceptance receipt, and evidence package paths.

The validator sources the env file and rejects placeholders, local/IP targets,
missing account/security-group evidence, missing secrets, and unsafe acceptance
levels before a long production acceptance run starts.
EOF
}

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

fail() {
  local reason="$1"
  local detail="${2:-}"
  if [[ -n "${detail}" ]]; then
    printf 'production_acceptance_env result=fail reason=%s %s\n' "${reason}" "${detail}" >&2
  else
    printf 'production_acceptance_env result=fail reason=%s\n' "${reason}" >&2
  fi
  exit 1
}

source_env_file() {
  [[ -f "${ENV_FILE}" ]] || fail "env_file_missing" "path=${ENV_FILE}"
  [[ -n "${IM_INTERNAL_SECRET:-}" ]] || fail "internal_secret_required_before_source"
  set -a
  # shellcheck disable=SC1090
  . "${ENV_FILE}"
  set +a
}

validate_env() {
  python3 - "${MODE}" <<'PY'
import csv
import hashlib
import ipaddress
import json
import os
import subprocess
import sys
import tarfile
import time
import uuid
from pathlib import Path
from urllib.parse import urlparse

mode = sys.argv[1]

def fail(reason: str, detail: str = "") -> None:
    suffix = f" {detail}" if detail else ""
    raise SystemExit(f"production_acceptance_env result=fail reason={reason}{suffix}")

def env(name: str) -> str:
    return os.environ.get(name, "").strip()

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

MAX_PACKAGE_ARCHIVE_MEMBER_BYTES = 512 * 1024 * 1024
MAX_PACKAGE_ARCHIVE_TOTAL_BYTES = 2 * 1024 * 1024 * 1024
MAX_PACKAGE_ARCHIVE_TEXT_MEMBER_BYTES = 16 * 1024 * 1024

def require_file(name: str, reason: str) -> Path:
    value = env(name)
    if not value:
        fail(reason, f"name={name}")
    path = Path(value)
    if not path.is_file():
        fail(reason, f"name={name} path={path}")
    return path

def usable_account_rows(path: Path) -> int:
    count = 0
    try:
        with path.open(newline="", encoding="utf-8") as handle:
            for row in csv.reader(handle):
                if len(row) >= 2 and row[0].strip() and row[1].strip():
                    count += 1
    except Exception as exc:
        fail("account_file_read_failed", f"path={path} error={exc}")
    return count

def positive_int_env(name: str, reason: str) -> int:
    value = env(name)
    if not value:
        fail(reason, f"name={name}")
    try:
        parsed = int(value)
    except Exception:
        fail(reason, f"name={name} value={value}")
    if parsed <= 0:
        fail(reason, f"name={name} value={value}")
    return parsed

def validate_cloud_security_group_repair_receipt(
    path: Path,
    *,
    max_age_seconds: int,
    expected_security_group_id: str,
    expected_region_id: str,
    expected_admin_cidr: str,
) -> None:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        fail("cloud_security_group_repair_receipt_read_failed", f"path={path} error={exc}")
    if not isinstance(payload, dict):
        fail("cloud_security_group_repair_receipt_invalid", f"path={path} error=not-object")
    if payload.get("schemaVersion") != 1:
        fail("cloud_security_group_repair_receipt_schema_version", f"path={path}")
    try:
        generated_at = int(payload.get("generatedAtEpoch") or 0)
    except Exception:
        fail("cloud_security_group_repair_receipt_generated_at_invalid", f"path={path}")
    if generated_at <= 0:
        fail("cloud_security_group_repair_receipt_generated_at_invalid", f"path={path} value={generated_at}")
    age_seconds = int(time.time()) - generated_at
    if age_seconds > max_age_seconds:
        fail(
            "cloud_security_group_repair_receipt_stale",
            f"path={path} ageSeconds={age_seconds} maxAgeSeconds={max_age_seconds}",
        )
    status = str(payload.get("status") or "")
    if status != "APPLIED_VERIFIED":
        fail("cloud_security_group_repair_receipt_status", f"path={path} status={status or '-'}")
    if payload.get("applied") is not True:
        fail("cloud_security_group_repair_receipt_not_applied", f"path={path}")
    if payload.get("verified") is not True:
        fail("cloud_security_group_repair_receipt_not_verified", f"path={path}")
    security_group_id = str(payload.get("securityGroupId") or "")
    if security_group_id != expected_security_group_id:
        fail(
            "cloud_security_group_repair_receipt_security_group_mismatch",
            f"path={path} expected={expected_security_group_id} actual={security_group_id or '-'}",
        )
    region_id = str(payload.get("regionId") or "")
    if region_id != expected_region_id:
        fail(
            "cloud_security_group_repair_receipt_region_mismatch",
            f"path={path} expected={expected_region_id} actual={region_id or '-'}",
        )
    admin_cidr = str(payload.get("adminCidr") or "")
    if admin_cidr != expected_admin_cidr:
        fail(
            "cloud_security_group_repair_receipt_admin_cidr_mismatch",
            f"path={path} expected={expected_admin_cidr} actual={admin_cidr or '-'}",
        )
    plan_status = str(payload.get("planStatus") or "")
    if plan_status not in {"CHANGE_REQUIRED", "NOOP"}:
        fail("cloud_security_group_repair_receipt_plan_status_invalid", f"path={path} planStatus={plan_status or '-'}")
    summary = payload.get("summary")
    if not isinstance(summary, dict) or "actionCount" not in summary:
        fail("cloud_security_group_repair_receipt_summary_missing", f"path={path}")
    artifacts = payload.get("artifacts")
    if not isinstance(artifacts, dict):
        fail("cloud_security_group_repair_receipt_artifacts_missing", f"path={path}")

def archive_member_bytes(
    archive: tarfile.TarFile,
    member: tarfile.TarInfo,
    name: str,
    max_bytes: int = MAX_PACKAGE_ARCHIVE_TEXT_MEMBER_BYTES,
) -> bytes:
    if not member.isfile():
        fail("production_evidence_package_member_not_file", f"member={name}")
    if member.size < 0:
        fail("production_evidence_package_member_size_invalid", f"member={name} size={member.size}")
    if member.size > max_bytes:
        fail("production_evidence_package_text_member_too_large", f"member={name} size={member.size} max={max_bytes}")
    handle = archive.extractfile(member)
    if handle is None:
        fail("production_evidence_package_member_read_failed", f"member={name}")
    data = handle.read(max_bytes + 1)
    if len(data) > max_bytes:
        fail("production_evidence_package_text_member_too_large", f"member={name} max={max_bytes}")
    return data

def archive_member_sha256(archive: tarfile.TarFile, member: tarfile.TarInfo, name: str) -> str:
    if not member.isfile():
        fail("production_evidence_package_member_not_file", f"member={name}")
    if member.size < 0:
        fail("production_evidence_package_member_size_invalid", f"member={name} size={member.size}")
    handle = archive.extractfile(member)
    if handle is None:
        fail("production_evidence_package_member_read_failed", f"member={name}")
    digest = hashlib.sha256()
    read_bytes = 0
    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
        read_bytes += len(chunk)
        digest.update(chunk)
    if read_bytes != member.size:
        fail("production_evidence_package_member_size_mismatch", f"member={name} expected={member.size} actual={read_bytes}")
    return digest.hexdigest()

def is_local_metadata_member(name: str) -> bool:
    base_name = Path(name).name
    return base_name.startswith("._") or base_name == ".DS_Store"

def read_archive_json(archive: tarfile.TarFile, members: dict[str, tarfile.TarInfo], name: str) -> dict:
    member = members.get(name)
    if member is None:
        fail("production_evidence_package_member_missing", f"member={name}")
    try:
        payload = json.loads(archive_member_bytes(archive, member, name).decode("utf-8"))
    except Exception as exc:
        fail("production_evidence_package_member_invalid_json", f"member={name} error={exc}")
    if not isinstance(payload, dict):
        fail("production_evidence_package_member_invalid_json", f"member={name} error=not-object")
    return payload

def verify_archive_checksums(archive: tarfile.TarFile, members: dict[str, tarfile.TarInfo]) -> None:
    checksum_member = members.get("SHA256SUMS")
    if checksum_member is None:
        fail("production_evidence_package_member_missing", "member=SHA256SUMS")
    try:
        checksum_text = archive_member_bytes(archive, checksum_member, "SHA256SUMS").decode("utf-8")
    except UnicodeDecodeError as exc:
        fail("production_evidence_package_checksum_invalid", f"error={exc}")

    checksum_rows: dict[str, str] = {}
    for lineno, raw in enumerate(checksum_text.splitlines(), start=1):
        if not raw:
            continue
        if raw.startswith("\\") or len(raw) < 67 or raw[64] != " " or raw[65] not in {" ", "*"}:
            fail("production_evidence_package_checksum_invalid", f"line={lineno}")
        digest = raw[:64]
        if any(char not in "0123456789abcdefABCDEF" for char in digest):
            fail("production_evidence_package_checksum_invalid", f"line={lineno}")
        name = raw[66:]
        normalized = name[2:] if name.startswith("./") else name
        parts = Path(normalized).parts
        if (
            not normalized
            or normalized == "."
            or normalized.startswith("/")
            or ".." in parts
            or "/" in normalized
            or normalized == "SHA256SUMS"
            or is_local_metadata_member(normalized)
        ):
            fail("production_evidence_package_checksum_path_unsafe", f"line={lineno} path={name}")
        if normalized in checksum_rows:
            fail("production_evidence_package_checksum_duplicate_path", f"path={normalized}")
        member = members.get(normalized)
        if member is None:
            fail("production_evidence_package_checksum_file_missing", f"line={lineno} path={name}")
        actual = archive_member_sha256(archive, member, normalized)
        if actual.lower() != digest.lower():
            fail("production_evidence_package_checksum_mismatch", f"path={normalized}")
        checksum_rows[normalized] = digest

    expected = {name for name, member in members.items() if member.isfile() and name != "SHA256SUMS"}
    missing = sorted(expected - set(checksum_rows))
    if missing:
        fail("production_evidence_package_checksum_member_missing", f"path={missing[0]}")

def require_target_matches(target: object, expected: dict[str, str], reason: str) -> None:
    if not isinstance(target, dict):
        fail(reason, "field=target")
    for key, expected_value in expected.items():
        actual_value = str(target.get(key) or "")
        if actual_value != expected_value:
            fail(reason, f"field={key} expected={expected_value} actual={actual_value or '-'}")

def validate_evidence_package_target(path: Path, expected_target: dict[str, str]) -> None:
    required_members = {
        "production-evidence-manifest.json",
        "SHA256SUMS",
        "current-production-readiness.json",
        "current-production-readiness.md",
    }
    try:
        with tarfile.open(path, "r:gz") as archive:
            members: dict[str, tarfile.TarInfo] = {}
            total_bytes = 0
            for member in archive.getmembers():
                name = member.name
                normalized = name[2:] if name.startswith("./") else name
                parts = Path(normalized).parts
                if normalized == "." and member.isdir():
                    continue
                if (
                    not normalized
                    or normalized.startswith("/")
                    or ".." in parts
                    or member.issym()
                    or member.islnk()
                    or not member.isfile()
                    or is_local_metadata_member(normalized)
                ):
                    fail("production_evidence_package_unsafe_member", f"member={name}")
                if member.size < 0:
                    fail("production_evidence_package_member_size_invalid", f"member={normalized} size={member.size}")
                if member.size > MAX_PACKAGE_ARCHIVE_MEMBER_BYTES:
                    fail(
                        "production_evidence_package_member_too_large",
                        f"member={normalized} size={member.size} max={MAX_PACKAGE_ARCHIVE_MEMBER_BYTES}",
                    )
                total_bytes += member.size
                if total_bytes > MAX_PACKAGE_ARCHIVE_TOTAL_BYTES:
                    fail("production_evidence_package_total_too_large", f"size={total_bytes} max={MAX_PACKAGE_ARCHIVE_TOTAL_BYTES}")
                if normalized in members:
                    fail("production_evidence_package_duplicate_member", f"member={normalized}")
                members[normalized] = member

            missing = sorted(required_members - set(members))
            if missing:
                fail("production_evidence_package_member_missing", f"member={missing[0]}")
            verify_archive_checksums(archive, members)
            manifest = read_archive_json(archive, members, "production-evidence-manifest.json")
            readiness = read_archive_json(archive, members, "current-production-readiness.json")
    except tarfile.TarError as exc:
        fail("production_evidence_package_read_failed", f"path={path} error={exc}")
    except OSError as exc:
        fail("production_evidence_package_read_failed", f"path={path} error={exc}")

    current_readiness = manifest.get("currentReadiness") or {}
    if manifest.get("schemaVersion") != 1:
        fail("production_evidence_manifest_invalid", f"field=schemaVersion value={manifest.get('schemaVersion')}")
    if not isinstance(current_readiness, dict):
        fail("production_evidence_manifest_invalid", "field=currentReadiness")
    if current_readiness.get("present") is not True:
        fail("production_evidence_manifest_invalid", "field=currentReadiness.present")
    require_target_matches(
        current_readiness.get("target"),
        expected_target,
        "production_evidence_manifest_target_mismatch",
    )
    require_target_matches(
        readiness.get("target"),
        expected_target,
        "production_evidence_current_readiness_target_mismatch",
    )

def validate_topology_smoke_receipt(path: Path) -> None:
    verifier = env("PRODUCTION_TOPOLOGY_SMOKE_VERIFIER")
    if not verifier:
        fail("production_topology_smoke_verifier_missing")
    max_age_seconds = env("PRODUCTION_TOPOLOGY_SMOKE_MAX_AGE_SECONDS") or "86400"
    max_future_skew_seconds = env("PRODUCTION_TOPOLOGY_SMOKE_MAX_FUTURE_SKEW_SECONDS") or "300"
    try:
        int(max_age_seconds)
        int(max_future_skew_seconds)
    except Exception:
        fail(
            "production_topology_smoke_freshness_invalid",
            f"maxAgeSeconds={max_age_seconds} maxFutureSkewSeconds={max_future_skew_seconds}",
        )
    result = subprocess.run(
        [
            sys.executable,
            verifier,
            "--receipt-json",
            str(path),
            "--require-pass",
            "--require-artifacts-exist",
            "--max-age-seconds",
            max_age_seconds,
            "--max-future-skew-seconds",
            max_future_skew_seconds,
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode == 0:
        return
    output = f"{result.stdout} {result.stderr}".strip()
    reason = "production_topology_smoke_receipt_invalid"
    if "reason=" in output:
        reason = output.split("reason=", 1)[1].split()[0]
    fail("production_topology_smoke_receipt_invalid", f"verifierReason={reason} path={path}")

def validate_deploy_readiness_receipt(path: Path, expected_target: dict[str, str]) -> None:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        fail("production_deploy_readiness_receipt_read_failed", f"path={path} error={exc}")
    if payload.get("kind") != "imserver-production-readiness-gate":
        fail("production_deploy_readiness_receipt_kind", f"path={path} actual={payload.get('kind') or '-'}")
    if payload.get("status") != "pass":
        fail("production_deploy_readiness_receipt_status", f"path={path} actual={payload.get('status') or '-'}")
    try:
        generated_at = int(payload.get("generatedAtEpoch") or 0)
    except Exception:
        fail("production_deploy_readiness_receipt_generated_at_invalid", f"path={path}")
    if generated_at <= 0:
        fail("production_deploy_readiness_receipt_generated_at_invalid", f"path={path} value={generated_at}")
    max_age_seconds = positive_int_env(
        "PRODUCTION_DEPLOY_READINESS_MAX_AGE_SECONDS",
        "production_deploy_readiness_receipt_max_age_invalid",
    )
    max_future_skew_seconds = int(env("PRODUCTION_DEPLOY_READINESS_MAX_FUTURE_SKEW_SECONDS") or "300")
    if max_future_skew_seconds < 0:
        fail(
            "production_deploy_readiness_receipt_max_future_skew_invalid",
            f"value={max_future_skew_seconds}",
        )
    now = int(time.time())
    future_skew_seconds = generated_at - now
    if future_skew_seconds > max_future_skew_seconds:
        fail(
            "production_deploy_readiness_receipt_in_future",
            f"path={path} skewSeconds={future_skew_seconds} maxFutureSkewSeconds={max_future_skew_seconds}",
        )
    age_seconds = now - generated_at
    if age_seconds > max_age_seconds:
        fail(
            "production_deploy_readiness_receipt_stale",
            f"path={path} ageSeconds={age_seconds} maxAgeSeconds={max_age_seconds}",
        )

    target = payload.get("target") or {}
    deploy_expected = {
        "publicBaseURL": expected_target["baseURL"],
        "performanceGateExpectBaseURL": expected_target["baseURL"],
        "performanceGateExpectTCPHost": expected_target["tcpHost"],
        "performanceGateExpectTCPPort": expected_target["tcpPort"],
    }
    for key, expected_value in deploy_expected.items():
        actual_value = str(target.get(key) or "")
        if actual_value != expected_value:
            fail(
                "production_deploy_readiness_receipt_target_mismatch",
                f"field={key} expected={expected_value} actual={actual_value or '-'} path={path}",
            )

    policy = payload.get("policy") or {}
    for field in (
        "requirePerformanceGate",
        "requireBackup",
        "verifyBackup",
        "requireLatestBackupFreshness",
        "requireRestoreDrillFreshness",
        "requireOffsiteBackupFreshness",
        "requireAuditTimer",
        "requireRestoreDrillTimer",
        "requireTimeSync",
        "requireAlertWebhook",
        "requireCloudSecurityGroup",
        "requireCloudSecurityGroupRepairReceipt",
        "requireNginxConfig",
        "requireTopologySmoke",
        "topologySmokeRequireArtifacts",
    ):
        if policy.get(field) is not True:
            fail("production_deploy_readiness_receipt_policy", f"field={field} value={policy.get(field)!r} path={path}")

    performance_policy = payload.get("performanceEvidencePolicy") or {}
    for field in (
        "requireProfileArtifacts",
        "requireProductPlanArtifacts",
        "requireProductCampaignArtifacts",
        "requireProductScenarioSuiteArtifacts",
        "requireProductScenarioSuiteNoLargeGroup",
        "requireValidationInventory",
        "requireCurrentReadinessArtifacts",
        "requireCloudSecurityGroup",
        "requireProductionAcceptance",
    ):
        if performance_policy.get(field) is not True:
            fail("production_deploy_readiness_receipt_performance_policy", f"field={field} value={performance_policy.get(field)!r} path={path}")

    steps = payload.get("steps") or []
    step_status = {str(step.get("name") or ""): str(step.get("status") or "") for step in steps if isinstance(step, dict)}
    for name in (
        "systemd-units",
        "production-env",
        "entrypoint",
        "application-smoke",
        "topology-smoke-receipt",
        "operational-audit",
        "latest-backup-verify",
        "diagnostics-redaction-self-test",
        "performance-gate",
        "performance-evidence",
        "receipt",
    ):
        if step_status.get(name) != "pass":
            fail("production_deploy_readiness_receipt_step", f"step={name} status={step_status.get(name) or '-'} path={path}")

if mode not in {"run", "verify"}:
    fail("mode_invalid", f"mode={mode}")

base_url = env("BASE_URL")
tcp_host = env("TCP_HOST")
tcp_port = env("TCP_PORT") or "9000"
target_policy = env("PRODUCTION_TARGET_POLICY")
if not target_policy:
    fail("production_target_policy_missing")
target_policy_result = subprocess.run(
    [
        sys.executable,
        target_policy,
        "--base-url",
        base_url,
        "--tcp-host",
        tcp_host,
        "--tcp-port",
        tcp_port,
        "--result-prefix",
        "production_acceptance_env",
    ],
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)
if target_policy_result.returncode != 0:
    if target_policy_result.stderr:
        print(target_policy_result.stderr, end="", file=sys.stderr)
    elif target_policy_result.stdout:
        print(target_policy_result.stdout, end="", file=sys.stderr)
    raise SystemExit(target_policy_result.returncode)
port = int(tcp_port)

level = env("PRODUCTION_ACCEPTANCE_LEVEL") or "full"
if level != "full":
    fail("level_must_be_full_for_production", f"value={level or '-'}")
if (env("PRODUCTION_ACCEPTANCE_PACKAGE_EVIDENCE") or "true").lower() not in {"1", "true", "yes", "on"}:
    fail("package_evidence_required")
if (env("PRODUCTION_ACCEPTANCE_VERIFY_RECEIPT") or "true").lower() not in {"1", "true", "yes", "on"}:
    fail("verify_receipt_required")

account_file = require_file("ACCOUNT_FILE", "account_file_missing")
rows = usable_account_rows(account_file)
if rows < 10000:
    fail("account_file_too_small", f"rows={rows} required=10000 path={account_file}")

conversation_id = env("IM_CONVERSATION_ID")
if not conversation_id or conversation_id == "REPLACE_WITH_REAL_CONVERSATION_UUID":
    fail("conversation_id_required")
try:
    parsed_uuid = uuid.UUID(conversation_id)
except ValueError:
    fail("conversation_id_invalid")
if parsed_uuid.int == 0:
    fail("conversation_id_nil")

if not env("IM_INTERNAL_SECRET"):
    fail("internal_secret_required")

sg_id = env("PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID")
if not sg_id or sg_id in {"sg-REPLACE_ME", "sg-..."} or "REPLACE" in sg_id:
    fail("cloud_security_group_id_placeholder", f"value={sg_id or '-'}")
region = env("PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID")
if not region:
    fail("cloud_security_group_region_required")
admin_cidr = env("PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR")
if not admin_cidr:
    fail("admin_cidr_required")
try:
    admin_network = ipaddress.ip_network(admin_cidr, strict=False)
except ValueError:
    fail("admin_cidr_invalid", f"value={admin_cidr}")
if admin_network.version == 4 and admin_network.prefixlen < 32:
    fail("admin_cidr_too_broad", f"value={admin_cidr}")
if admin_network.version == 6 and admin_network.prefixlen < 128:
    fail("admin_cidr_too_broad", f"value={admin_cidr}")

require_file("CLOUD_SECURITY_GROUP_RULES_FILE", "cloud_security_group_snapshot_missing")
repair_receipt_path = require_file(
    "PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON",
    "cloud_security_group_repair_receipt_missing",
)
repair_receipt_max_age_seconds = positive_int_env(
    "PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS",
    "cloud_security_group_repair_receipt_max_age_invalid",
)
validate_cloud_security_group_repair_receipt(
    repair_receipt_path,
    max_age_seconds=repair_receipt_max_age_seconds,
    expected_security_group_id=sg_id,
    expected_region_id=region,
    expected_admin_cidr=admin_cidr,
)

if mode == "verify":
    expected_target = {
        "baseURL": base_url,
        "tcpHost": tcp_host,
        "tcpPort": str(port),
    }
    topology_smoke_receipt_path = require_file(
        "PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON",
        "production_topology_smoke_receipt_missing",
    )
    validate_topology_smoke_receipt(topology_smoke_receipt_path)
    deploy_readiness_receipt_path = require_file(
        "PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON",
        "production_deploy_readiness_receipt_missing",
    )
    validate_deploy_readiness_receipt(deploy_readiness_receipt_path, expected_target)
    receipt_path = require_file("PRODUCTION_ACCEPTANCE_RECEIPT_JSON", "production_acceptance_receipt_missing")
    package_path = require_file("PRODUCTION_EVIDENCE_PACKAGE", "production_evidence_package_missing")
    try:
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    except Exception as exc:
        fail("production_acceptance_receipt_read_failed", f"path={receipt_path} error={exc}")
    target = receipt.get("target") or {}
    for key, expected_value in expected_target.items():
        actual_value = str(target.get(key) or "")
        if actual_value != expected_value:
            fail("production_acceptance_receipt_target_mismatch", f"field={key} expected={expected_value} actual={actual_value or '-'}")
    validate_evidence_package_target(package_path, expected_target)

print(
    "production_acceptance_env result=pass "
    f"mode={mode} baseURL={base_url} tcpHost={tcp_host} tcpPort={port} accountRows={rows}"
)
PY
}

run_self_test() {
  local tmpdir good_env accounts sg repair topology_smoke deploy_readiness receipt package log
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' RETURN
  good_env="${tmpdir}/production-acceptance.env"
  accounts="${tmpdir}/accounts.csv"
  sg="${tmpdir}/cloud-security-group.json"
  repair="${tmpdir}/repair-receipt.json"
  topology_smoke="${tmpdir}/latest-production-smoke.json"
  deploy_readiness="${tmpdir}/deploy-readiness.json"
  receipt="${tmpdir}/production-acceptance.json"
  package="${tmpdir}/production-evidence.tar.gz"
  log="${tmpdir}/validator.log"

  python3 - "${accounts}" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
with path.open("w", encoding="utf-8") as handle:
    for i in range(10000):
        handle.write(f"user{i}@example.internal,password{i}\n")
PY
  printf '{"rules":[]}\n' >"${sg}"
  python3 - "${repair}" <<'PY'
import json
import sys
import time
from pathlib import Path

path = Path(sys.argv[1])
payload = {
    "schemaVersion": 1,
    "status": "APPLIED_VERIFIED",
    "generatedAtEpoch": int(time.time()),
    "securityGroupId": "sg-prod-selftest",
    "regionId": "cn-shenzhen",
    "adminCidr": "203.0.113.10/32",
    "applied": True,
    "verified": True,
    "planStatus": "NOOP",
    "summary": {
        "actionCount": 0,
        "authorizeCount": 0,
        "revokeCount": 0,
    },
    "artifacts": {},
}
path.write_text(json.dumps(payload), encoding="utf-8")
PY
  python3 - "${topology_smoke}" "${tmpdir}/topology-smoke-artifacts" <<'PY'
import json
import sys
import time
from pathlib import Path

receipt = Path(sys.argv[1])
artifact_dir = Path(sys.argv[2])
artifact_dir.mkdir(parents=True, exist_ok=True)
artifacts = {}
for name in ("markdownReport", "stateFile", "composePs", "composeLog", "outboxInspect"):
    artifact = artifact_dir / f"{name}.txt"
    artifact.write_text("ok\n", encoding="utf-8")
    artifacts[name] = str(artifact)
checks = [
    "auth_register_or_login",
    "changes_projection",
    "conversation_create",
    "docker_compose_runtime_roles",
    "http_health",
    "message_write",
    "messages_since",
    "metrics_secret",
    "outbox_recovery",
    "runtime_services_health",
    "summary_projection",
]
receipt.write_text(json.dumps({
    "schemaVersion": 1,
    "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "status": "passed",
    "exitCode": 0,
    "environment": "production-smoke",
    "project": "imserver-production-smoke",
    "runtimeEvidence": True,
    "composeFile": "docker-compose.production-smoke.yml",
    "endpoints": {
        "gateway": "http://127.0.0.1:8080",
        "command": "http://127.0.0.1:8081",
        "query": "http://127.0.0.1:8082",
    },
    "conversations": {
        "directConversationID": "direct-1",
        "groupConversationID": "group-1",
    },
    "source": {
        "gitCommit": "abc123",
        "gitBranch": "main",
        "gitDirty": False,
    },
    "artifacts": artifacts,
    "checks": [{"name": name, "status": "passed"} for name in checks],
}), encoding="utf-8")
PY
  python3 - "${deploy_readiness}" "${topology_smoke}" <<'PY'
import json
import sys
import time
from pathlib import Path

path = Path(sys.argv[1])
topology_smoke = Path(sys.argv[2])
payload = {
    "schemaVersion": 1,
    "kind": "imserver-production-readiness-gate",
    "status": "pass",
    "generatedAtEpoch": int(time.time()),
    "target": {
        "publicBaseURL": "https://chat.myim-prod.com",
        "performanceGateExpectBaseURL": "https://chat.myim-prod.com",
        "performanceGateExpectTCPHost": "tcp.myim-prod.com",
        "performanceGateExpectTCPPort": "9000",
    },
    "policy": {
        "requirePerformanceGate": True,
        "requireBackup": True,
        "verifyBackup": True,
        "requireLatestBackupFreshness": True,
        "requireRestoreDrillFreshness": True,
        "requireOffsiteBackupFreshness": True,
        "requireAuditTimer": True,
        "requireRestoreDrillTimer": True,
        "requireTimeSync": True,
        "requireAlertWebhook": True,
        "requireCloudSecurityGroup": True,
        "requireCloudSecurityGroupRepairReceipt": True,
        "requireNginxConfig": True,
        "requireTopologySmoke": True,
        "topologySmokeRequireArtifacts": True,
    },
    "performanceEvidencePolicy": {
        "requireProfileArtifacts": True,
        "requireProductPlanArtifacts": True,
        "requireProductCampaignArtifacts": True,
        "requireProductScenarioSuiteArtifacts": True,
        "requireProductScenarioSuiteNoLargeGroup": True,
        "requireValidationInventory": True,
        "requireCurrentReadinessArtifacts": True,
        "requireCloudSecurityGroup": True,
        "requireProductionAcceptance": True,
    },
    "artifacts": {
        "topologySmokeReceipt": str(topology_smoke),
    },
    "steps": [
        {"name": "systemd-units", "status": "pass"},
        {"name": "production-env", "status": "pass"},
        {"name": "entrypoint", "status": "pass"},
        {"name": "application-smoke", "status": "pass"},
        {"name": "topology-smoke-receipt", "status": "pass"},
        {"name": "operational-audit", "status": "pass"},
        {"name": "latest-backup-verify", "status": "pass"},
        {"name": "diagnostics-redaction-self-test", "status": "pass"},
        {"name": "performance-gate", "status": "pass"},
        {"name": "performance-evidence", "status": "pass"},
        {"name": "receipt", "status": "pass"},
    ],
}
path.write_text(json.dumps(payload), encoding="utf-8")
PY
  cat >"${receipt}" <<'JSON'
{"schemaVersion":1,"target":{"baseURL":"https://chat.myim-prod.com","tcpHost":"tcp.myim-prod.com","tcpPort":"9000"}}
JSON
  python3 - "${package}" <<'PY'
import hashlib
import json
import tarfile
import tempfile
import sys
from pathlib import Path

package = Path(sys.argv[1])
target = {
    "baseURL": "https://chat.myim-prod.com",
    "tcpHost": "tcp.myim-prod.com",
    "tcpPort": "9000",
}
with tempfile.TemporaryDirectory(prefix="production-evidence-package-") as tmp:
    stage = Path(tmp)
    (stage / "production-evidence-manifest.json").write_text(json.dumps({
        "schemaVersion": 1,
        "currentReadiness": {
            "present": True,
            "target": target,
        },
    }), encoding="utf-8")
    (stage / "current-production-readiness.json").write_text(json.dumps({
        "schemaVersion": 1,
        "target": target,
    }), encoding="utf-8")
    (stage / "current-production-readiness.md").write_text("# Current Production Readiness\n", encoding="utf-8")
    rows = []
    for member in sorted(stage.iterdir()):
        if member.name == "SHA256SUMS":
            continue
        digest = hashlib.sha256(member.read_bytes()).hexdigest()
        rows.append(f"{digest}  ./{member.name}\n")
    (stage / "SHA256SUMS").write_text("".join(rows), encoding="utf-8")
    with tarfile.open(package, "w:gz") as archive:
        for member in sorted(stage.iterdir()):
            archive.add(member, arcname=member.name)
PY
  cat >"${good_env}" <<EOF
BASE_URL=https://chat.myim-prod.com
TCP_HOST=tcp.myim-prod.com
TCP_PORT=9000
ACCOUNT_FILE=${accounts}
IM_CONVERSATION_ID=11111111-1111-4111-8111-111111111111
IM_INTERNAL_SECRET=\${IM_INTERNAL_SECRET:?set-IM_INTERNAL_SECRET}
PRODUCTION_ACCEPTANCE_LEVEL=full
PRODUCTION_ACCEPTANCE_PACKAGE_EVIDENCE=true
PRODUCTION_ACCEPTANCE_VERIFY_RECEIPT=true
CLOUD_SECURITY_GROUP_RULES_FILE=${sg}
PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON=${repair}
PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS=86400
PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=sg-prod-selftest
PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=cn-shenzhen
PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR=203.0.113.10/32
PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON=${topology_smoke}
PRODUCTION_TOPOLOGY_SMOKE_MAX_AGE_SECONDS=86400
PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON=${deploy_readiness}
PRODUCTION_DEPLOY_READINESS_MAX_AGE_SECONDS=86400
PRODUCTION_ACCEPTANCE_RECEIPT_JSON=${receipt}
PRODUCTION_EVIDENCE_PACKAGE=${package}
EOF

  IM_INTERNAL_SECRET=secret \
  PRODUCTION_ACCEPTANCE_ENV_FILE="${good_env}" \
  PRODUCTION_ACCEPTANCE_ENV_MODE=run \
  PRODUCTION_ACCEPTANCE_ENV_SELF_TEST=false \
    bash "${BASH_SOURCE[0]}" >"${log}"
  grep -q 'production_acceptance_env result=pass mode=run' "${log}"

  IM_INTERNAL_SECRET=secret \
  PRODUCTION_ACCEPTANCE_ENV_FILE="${good_env}" \
  PRODUCTION_ACCEPTANCE_ENV_MODE=verify \
  PRODUCTION_ACCEPTANCE_ENV_SELF_TEST=false \
    bash "${BASH_SOURCE[0]}" >"${log}"
  grep -q 'production_acceptance_env result=pass mode=verify' "${log}"

  sed 's/chat.myim-prod.com/chat.example.com/' "${good_env}" >"${tmpdir}/bad-target.env"
  if IM_INTERNAL_SECRET=secret \
    PRODUCTION_ACCEPTANCE_ENV_FILE="${tmpdir}/bad-target.env" \
    PRODUCTION_ACCEPTANCE_ENV_MODE=run \
    PRODUCTION_ACCEPTANCE_ENV_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    fail "self_test_placeholder_target_passed"
  fi
  grep -q 'reason=base_url_dns_required' "${log}"

  sed 's#BASE_URL=https://chat.myim-prod.com#BASE_URL=https://chat.myim-prod.com/api#' "${good_env}" >"${tmpdir}/bad-origin.env"
  if IM_INTERNAL_SECRET=secret \
    PRODUCTION_ACCEPTANCE_ENV_FILE="${tmpdir}/bad-origin.env" \
    PRODUCTION_ACCEPTANCE_ENV_MODE=run \
    PRODUCTION_ACCEPTANCE_ENV_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    fail "self_test_path_target_passed"
  fi
  grep -q 'reason=base_url_origin_required' "${log}"

  sed 's/TCP_PORT=9000/TCP_PORT=9443/' "${good_env}" >"${tmpdir}/bad-tcp-port.env"
  if IM_INTERNAL_SECRET=secret \
    PRODUCTION_ACCEPTANCE_ENV_FILE="${tmpdir}/bad-tcp-port.env" \
    PRODUCTION_ACCEPTANCE_ENV_MODE=run \
    PRODUCTION_ACCEPTANCE_ENV_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    fail "self_test_bad_tcp_port_passed"
  fi
  grep -q 'reason=tcp_port_required' "${log}"

  sed 's/sg-prod-selftest/sg-REPLACE_ME/' "${good_env}" >"${tmpdir}/bad-sg.env"
  if IM_INTERNAL_SECRET=secret \
    PRODUCTION_ACCEPTANCE_ENV_FILE="${tmpdir}/bad-sg.env" \
    PRODUCTION_ACCEPTANCE_ENV_MODE=run \
    PRODUCTION_ACCEPTANCE_ENV_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    fail "self_test_placeholder_sg_passed"
  fi
  grep -q 'reason=cloud_security_group_id_placeholder' "${log}"

  sed 's/sg-prod-selftest/sg-other-prod/' "${good_env}" >"${tmpdir}/wrong-sg-receipt.env"
  if IM_INTERNAL_SECRET=secret \
    PRODUCTION_ACCEPTANCE_ENV_FILE="${tmpdir}/wrong-sg-receipt.env" \
    PRODUCTION_ACCEPTANCE_ENV_MODE=run \
    PRODUCTION_ACCEPTANCE_ENV_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    fail "self_test_security_group_receipt_mismatch_passed"
  fi
  grep -q 'reason=cloud_security_group_repair_receipt_security_group_mismatch' "${log}"

  sed 's/PRODUCTION_EVIDENCE_PACKAGE=.*/# PRODUCTION_EVIDENCE_PACKAGE=missing/' "${good_env}" >"${tmpdir}/missing-package.env"
  if IM_INTERNAL_SECRET=secret \
    PRODUCTION_ACCEPTANCE_ENV_FILE="${tmpdir}/missing-package.env" \
    PRODUCTION_ACCEPTANCE_ENV_MODE=verify \
    PRODUCTION_ACCEPTANCE_ENV_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    fail "self_test_missing_verify_package_passed"
  fi
  grep -q 'reason=production_evidence_package_missing' "${log}"

  sed 's#PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON=.*#PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON=/tmp/missing-production-smoke.json#' "${good_env}" >"${tmpdir}/missing-topology-smoke.env"
  if IM_INTERNAL_SECRET=secret \
    PRODUCTION_ACCEPTANCE_ENV_FILE="${tmpdir}/missing-topology-smoke.env" \
    PRODUCTION_ACCEPTANCE_ENV_MODE=verify \
    PRODUCTION_ACCEPTANCE_ENV_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    fail "self_test_missing_topology_smoke_receipt_passed"
  fi
  grep -q 'reason=production_topology_smoke_receipt_missing' "${log}"

  sed 's#PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON=.*#PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON=/tmp/missing-deploy-readiness.json#' "${good_env}" >"${tmpdir}/missing-deploy-readiness.env"
  if IM_INTERNAL_SECRET=secret \
    PRODUCTION_ACCEPTANCE_ENV_FILE="${tmpdir}/missing-deploy-readiness.env" \
    PRODUCTION_ACCEPTANCE_ENV_MODE=verify \
    PRODUCTION_ACCEPTANCE_ENV_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    fail "self_test_missing_deploy_readiness_receipt_passed"
  fi
  grep -q 'reason=production_deploy_readiness_receipt_missing' "${log}"

  python3 - "${deploy_readiness}" "${tmpdir}/weakened-deploy-readiness.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
payload["policy"]["requireRestoreDrillFreshness"] = False
Path(sys.argv[2]).write_text(json.dumps(payload), encoding="utf-8")
PY
  sed "s#PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON=${deploy_readiness}#PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON=${tmpdir}/weakened-deploy-readiness.json#" "${good_env}" >"${tmpdir}/weakened-deploy-readiness.env"
  if IM_INTERNAL_SECRET=secret \
    PRODUCTION_ACCEPTANCE_ENV_FILE="${tmpdir}/weakened-deploy-readiness.env" \
    PRODUCTION_ACCEPTANCE_ENV_MODE=verify \
    PRODUCTION_ACCEPTANCE_ENV_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    fail "self_test_weakened_deploy_readiness_receipt_passed"
  fi
  grep -q 'reason=production_deploy_readiness_receipt_policy field=requireRestoreDrillFreshness' "${log}"

  python3 - "${topology_smoke}" "${tmpdir}/failed-production-smoke.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
payload["status"] = "failed"
payload["exitCode"] = 1
Path(sys.argv[2]).write_text(json.dumps(payload), encoding="utf-8")
PY
  sed "s#PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON=${topology_smoke}#PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON=${tmpdir}/failed-production-smoke.json#" "${good_env}" >"${tmpdir}/failed-topology-smoke.env"
  if IM_INTERNAL_SECRET=secret \
    PRODUCTION_ACCEPTANCE_ENV_FILE="${tmpdir}/failed-topology-smoke.env" \
    PRODUCTION_ACCEPTANCE_ENV_MODE=verify \
    PRODUCTION_ACCEPTANCE_ENV_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    fail "self_test_failed_topology_smoke_receipt_passed"
  fi
  grep -q 'reason=production_topology_smoke_receipt_invalid verifierReason=status_not_passed' "${log}"

  python3 - "${receipt}" "${tmpdir}/wrong-target-receipt.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
payload["target"]["baseURL"] = "https://other.myim-prod.com"
Path(sys.argv[2]).write_text(json.dumps(payload), encoding="utf-8")
PY
  sed "s#PRODUCTION_ACCEPTANCE_RECEIPT_JSON=${receipt}#PRODUCTION_ACCEPTANCE_RECEIPT_JSON=${tmpdir}/wrong-target-receipt.json#" "${good_env}" >"${tmpdir}/wrong-target-receipt.env"
  if IM_INTERNAL_SECRET=secret \
    PRODUCTION_ACCEPTANCE_ENV_FILE="${tmpdir}/wrong-target-receipt.env" \
    PRODUCTION_ACCEPTANCE_ENV_MODE=verify \
    PRODUCTION_ACCEPTANCE_ENV_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    fail "self_test_receipt_target_mismatch_passed"
  fi
  grep -q 'reason=production_acceptance_receipt_target_mismatch field=baseURL' "${log}"

  if grep -q 'hashlib\.sha256(archive_member_bytes' "${BASH_SOURCE[0]}"; then
    fail "self_test_package_archive_full_read_hash_detected"
  fi
  grep -q 'archive_member_sha256(' "${BASH_SOURCE[0]}"
  grep -q 'MAX_PACKAGE_ARCHIVE_TEXT_MEMBER_BYTES' "${BASH_SOURCE[0]}"
  grep -q 'production_evidence_package_text_member_too_large' "${BASH_SOURCE[0]}"

  python3 - "${package}" "${tmpdir}/tampered-package.tar.gz" <<'PY'
import tarfile
import tempfile
import sys
from pathlib import Path

source = Path(sys.argv[1])
target_package = Path(sys.argv[2])
with tempfile.TemporaryDirectory(prefix="tampered-production-evidence-package-") as tmp:
    stage = Path(tmp)
    with tarfile.open(source, "r:gz") as archive:
        archive.extractall(stage)
    (stage / "current-production-readiness.md").write_text("# Tampered Production Readiness\n", encoding="utf-8")
    with tarfile.open(target_package, "w:gz") as archive:
        for member in sorted(stage.iterdir()):
            archive.add(member, arcname=member.name)
PY
  sed "s#PRODUCTION_EVIDENCE_PACKAGE=${package}#PRODUCTION_EVIDENCE_PACKAGE=${tmpdir}/tampered-package.tar.gz#" "${good_env}" >"${tmpdir}/tampered-package.env"
  if IM_INTERNAL_SECRET=secret \
    PRODUCTION_ACCEPTANCE_ENV_FILE="${tmpdir}/tampered-package.env" \
    PRODUCTION_ACCEPTANCE_ENV_MODE=verify \
    PRODUCTION_ACCEPTANCE_ENV_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    fail "self_test_package_checksum_mismatch_passed"
  fi
  grep -q 'reason=production_evidence_package_checksum_mismatch path=current-production-readiness.md' "${log}"

  python3 - "${package}" "${tmpdir}/wrong-target-package.tar.gz" <<'PY'
import hashlib
import json
import tarfile
import tempfile
import sys
from pathlib import Path

source = Path(sys.argv[1])
target_package = Path(sys.argv[2])
with tempfile.TemporaryDirectory(prefix="wrong-production-evidence-package-") as tmp:
    stage = Path(tmp)
    with tarfile.open(source, "r:gz") as archive:
        archive.extractall(stage)
    manifest_path = stage / "production-evidence-manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["currentReadiness"]["target"]["tcpHost"] = "tcp.other-myim-prod.com"
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
    rows = []
    for member in sorted(stage.iterdir()):
        if member.name == "SHA256SUMS":
            continue
        digest = hashlib.sha256(member.read_bytes()).hexdigest()
        rows.append(f"{digest}  ./{member.name}\n")
    (stage / "SHA256SUMS").write_text("".join(rows), encoding="utf-8")
    with tarfile.open(target_package, "w:gz") as archive:
        for member in sorted(stage.iterdir()):
            archive.add(member, arcname=member.name)
PY
  sed "s#PRODUCTION_EVIDENCE_PACKAGE=${package}#PRODUCTION_EVIDENCE_PACKAGE=${tmpdir}/wrong-target-package.tar.gz#" "${good_env}" >"${tmpdir}/wrong-target-package.env"
  if IM_INTERNAL_SECRET=secret \
    PRODUCTION_ACCEPTANCE_ENV_FILE="${tmpdir}/wrong-target-package.env" \
    PRODUCTION_ACCEPTANCE_ENV_MODE=verify \
    PRODUCTION_ACCEPTANCE_ENV_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" >"${log}" 2>&1; then
    fail "self_test_package_target_mismatch_passed"
  fi
  grep -q 'reason=production_evidence_manifest_target_mismatch field=tcpHost' "${log}"

  printf 'production_acceptance_env_self_test result=pass\n'
}

case "${1:-}" in
  --help|-h)
    usage
    exit 0
    ;;
esac

if bool_enabled "${SELF_TEST}"; then
  run_self_test
  exit 0
fi

source_env_file
validate_env
