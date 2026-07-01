#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import ipaddress
import json
import os
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from perf_product_scenario_suite_verify import verify as verify_product_scenario_suite
from run_product_campaign import build_runbook as build_product_campaign_runbook


VALID_STATUSES = {"BLOCKED_ENTRYPOINT", "FAIL", "PASS"}
REPO_ROOT = Path(__file__).resolve().parents[2]
CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_VERIFIER = REPO_ROOT / "deploy/ubuntu/31_verify_aliyun_security_group_repair_receipt.sh"
VALID_FAIL_REASONS = {
    "requested_run_prereq_failed",
    "smoke_failed",
    "product_scenario_suite_failed",
    "baseline_failed",
    "full_acceptance_failed",
}
PRODUCTION_EVIDENCE_COMMAND_SCRIPTS = {
    "production-profile": "./run_production_profile.sh",
    "current-production-readiness": "./run_current_production_readiness.sh",
    "production-acceptance": "./run_production_acceptance.sh",
}


def fail(reason: str, **fields: Any) -> None:
    details = " ".join(f"{key}={value}" for key, value in fields.items())
    message = f"current_production_readiness_artifacts result=fail reason={reason}"
    if details:
        message = f"{message} {details}"
    raise SystemExit(message)


def read_json(path: Path) -> dict[str, Any]:
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except Exception as exc:
        fail("json_read_failed", path=path, error=exc)


def require_file(path: Path, reason: str) -> None:
    if not path.is_file():
        fail(reason, path=path)


def build_readiness_markdown(payload: dict[str, Any]) -> str:
    target = payload.get("target") or {}
    policy = payload.get("evidencePolicy") or {}
    entrypoint = payload.get("entrypoint") or {}
    operator_network = payload.get("operatorNetwork") or {}
    artifacts = payload.get("artifacts") or {}
    runs = payload.get("runs") or {}

    def dash(value: Any) -> Any:
        return value if value not in {None, ""} else "-"

    warnings = operator_network.get("warnings") or []
    route_interfaces = operator_network.get("routeInterfaces") or []
    route_gateways = operator_network.get("routeGateways") or []

    lines = [
        "# Current Production Readiness",
        "",
        f"- status: `{payload.get('status') or ''}`",
        f"- reason: `{payload.get('reason') or ''}`",
        f"- baseURL: `{target.get('baseURL') or ''}`",
        f"- tcpHost: `{target.get('tcpHost') or ''}`",
        f"- tcpPort: `{target.get('tcpPort') or ''}`",
        f"- profile: `{payload.get('profile') or ''}`",
        f"- requirePackageableEvidence: `{policy.get('requirePackageableEvidence')}`",
        f"- requireCloudSecurityGroup: `{policy.get('requireCloudSecurityGroup')}`",
        f"- requirePublicPortPolicy: `{policy.get('requirePublicPortPolicy')}`",
        f"- allowTempHTTP8080: `{policy.get('allowTempHTTP8080')}`",
        f"- cloudSecurityGroupRulesFile: `{dash(policy.get('cloudSecurityGroupRulesFile'))}`",
        f"- cloudSecurityGroupRulesMaxAgeSeconds: `{policy.get('cloudSecurityGroupRulesMaxAgeSeconds')}`",
        f"- cloudSecurityGroupRulesRequireRootOwner: `{policy.get('cloudSecurityGroupRulesRequireRootOwner')}`",
        f"- cloudSecurityGroupAuditLog: `{dash(artifacts.get('cloudSecurityGroupAuditLog'))}`",
        f"- requireCloudSecurityGroupRepairReceipt: `{policy.get('requireCloudSecurityGroupRepairReceipt')}`",
        f"- cloudSecurityGroupRepairReceiptJSON: `{dash(policy.get('cloudSecurityGroupRepairReceiptJSON'))}`",
        f"- cloudSecurityGroupRepairReceiptExpectSecurityGroupID: `{dash(policy.get('cloudSecurityGroupRepairReceiptExpectSecurityGroupID'))}`",
        f"- cloudSecurityGroupRepairReceiptExpectRegionID: `{dash(policy.get('cloudSecurityGroupRepairReceiptExpectRegionID'))}`",
        f"- cloudSecurityGroupRepairReceiptExpectAdminCIDR: `{dash(policy.get('cloudSecurityGroupRepairReceiptExpectAdminCIDR'))}`",
        f"- cloudSecurityGroupRepairReceiptVerifyLog: `{dash(artifacts.get('cloudSecurityGroupRepairReceiptVerifyLog'))}`",
        f"- operatorNetworkPreflight: `{policy.get('operatorNetworkPreflight')}`",
        f"- autoProductScenarioSuiteForPackageableAcceptance: `{policy.get('autoProductScenarioSuiteForPackageableAcceptance')}`",
        f"- entrypointDiagnosis: `{dash(entrypoint.get('diagnosis'))}`",
        f"- operatorNetworkStatus: `{dash(operator_network.get('status'))}`",
        f"- operatorNetworkFailed: `{operator_network.get('failed') if operator_network.get('failed') is not None else '-'}`",
        f"- operatorNetworkWarnings: `{','.join(str(item) for item in warnings) or '-'}`",
        f"- operatorNetworkRouteInterfaces: `{','.join(str(item) for item in route_interfaces) or '-'}`",
        f"- operatorNetworkRouteGateways: `{','.join(str(item) for item in route_gateways) or '-'}`",
        f"- operatorNetworkAction: `{dash(operator_network.get('action'))}`",
        f"- operatorNetworkLog: `{dash(artifacts.get('operatorNetworkLog'))}`",
        f"- operatorNetworkJSON: `{dash(artifacts.get('operatorNetworkJSON'))}`",
        f"- rescueSummary: `{dash(artifacts.get('rescueSummary'))}`",
        f"- rescueTarball: `{dash(artifacts.get('rescueTarball'))}`",
        f"- smokeExitCode: `{runs.get('smokeExitCode') if runs.get('smokeExitCode') is not None else '-'}`",
        f"- smokeLog: `{dash(artifacts.get('smokeLog'))}`",
        f"- productScenarioSuiteExitCode: `{runs.get('suiteExitCode') if runs.get('suiteExitCode') is not None else '-'}`",
        f"- productScenarioSuiteLog: `{dash(artifacts.get('productScenarioSuiteLog'))}`",
        f"- productScenarioSuiteRunJSON: `{dash(artifacts.get('productScenarioSuiteRunJSON'))}`",
        f"- productScenarioSuiteRunMarkdown: `{dash(artifacts.get('productScenarioSuiteRunMarkdown'))}`",
        f"- baselineExitCode: `{runs.get('baselineExitCode') if runs.get('baselineExitCode') is not None else '-'}`",
        f"- baselineLog: `{dash(artifacts.get('baselineLog'))}`",
        f"- fullAcceptanceExitCode: `{runs.get('fullAcceptanceExitCode') if runs.get('fullAcceptanceExitCode') is not None else '-'}`",
        f"- fullAcceptanceLog: `{dash(artifacts.get('fullAcceptanceLog'))}`",
        f"- fullAcceptanceRunJSON: `{dash(artifacts.get('fullAcceptanceRunJSON'))}`",
        f"- fullAcceptanceRunbook: `{dash(artifacts.get('fullAcceptanceRunbook'))}`",
        "",
    ]
    return "\n".join(lines)


def verify_readiness_markdown(readiness_json: Path, payload: dict[str, Any], evidence_dir: Path | None = None) -> None:
    markdown_path = readiness_json.with_suffix(".md")
    if not markdown_path.is_file() and evidence_dir is not None:
        relocated = evidence_dir / markdown_path.name
        if relocated.is_file():
            markdown_path = relocated
    if not markdown_path.is_file():
        return
    expected = build_readiness_markdown(payload)
    actual = markdown_path.read_text(encoding="utf-8", errors="replace")
    if actual != expected:
        fail("readiness_markdown_mismatch", path=markdown_path)


def as_bool(value: Any) -> bool:
    return value is True or str(value).lower() == "true"


def require_readiness_timestamp(
    receipt: dict[str, Any],
    *,
    max_age_seconds: int,
    max_future_skew_seconds: int,
) -> None:
    if max_age_seconds <= 0:
        fail("readiness_max_age_invalid", value=max_age_seconds)
    if max_future_skew_seconds < 0:
        fail("readiness_max_future_skew_invalid", value=max_future_skew_seconds)
    try:
        generated_at = int(receipt.get("generatedAtEpoch"))
    except Exception:
        fail("readiness_generated_at_invalid", value=receipt.get("generatedAtEpoch"))
    if generated_at <= 0:
        fail("readiness_generated_at_invalid", value=generated_at)
    now = int(time.time())
    future_skew_seconds = generated_at - now
    if future_skew_seconds > max_future_skew_seconds:
        fail(
            "readiness_generated_at_in_future",
            skewSeconds=future_skew_seconds,
            maxFutureSkewSeconds=max_future_skew_seconds,
        )
    age_seconds = now - generated_at
    if age_seconds > max_age_seconds:
        fail(
            "readiness_stale",
            ageSeconds=age_seconds,
            maxAgeSeconds=max_age_seconds,
        )


def operator_network_summary(path: Path | None) -> dict[str, Any]:
    summary: dict[str, Any] = {
        "present": bool(path and path.is_file()),
        "failed": False,
        "warnings": [],
        "routeInterfaces": [],
        "routeGateways": [],
        "failureCount": 0,
    }
    if not path or not path.is_file():
        return summary

    warnings: set[str] = set()
    interfaces: set[str] = set()
    gateways: set[str] = set()
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        fields: dict[str, str] = {}
        for token in line.split():
            if "=" not in token:
                continue
            key, value = token.split("=", 1)
            fields[key] = value
        status = fields.get("status", "")
        warning = fields.get("warning", "")
        route_interface = fields.get("routeInterface", "")
        route_gateway = fields.get("routeGateway", "")
        if status == "fail":
            summary["failed"] = True
        if warning and warning not in {"clean", "<none>"}:
            warnings.add(warning)
        if route_interface and route_interface != "<none>":
            interfaces.add(route_interface)
        if route_gateway and route_gateway != "<none>":
            gateways.add(route_gateway)
        if "failures" in fields:
            try:
                summary["failureCount"] = max(int(summary["failureCount"]), int(fields["failures"]))
            except Exception:
                pass
    summary["warnings"] = sorted(warnings)
    summary["routeInterfaces"] = sorted(interfaces)
    summary["routeGateways"] = sorted(gateways)
    return summary


def operator_network_json_summary(path: Path | None) -> dict[str, Any]:
    summary: dict[str, Any] = {
        "present": bool(path and path.is_file()),
        "failed": False,
        "warnings": [],
        "routeInterfaces": [],
        "routeGateways": [],
        "failureCount": 0,
    }
    if not path or not path.is_file():
        return summary
    payload = read_json(path)
    summary["failed"] = payload.get("failed") is True or str(payload.get("status") or "") == "fail"
    summary["warnings"] = sorted(str(item) for item in payload.get("warnings") or [])
    summary["routeInterfaces"] = sorted(str(item) for item in payload.get("routeInterfaces") or [])
    summary["routeGateways"] = sorted(str(item) for item in payload.get("routeGateways") or [])
    try:
        summary["failureCount"] = int(payload.get("failureCount") or 0)
    except Exception:
        summary["failureCount"] = 0
    return summary


def operator_network_evidence_summary(log_path: Path | None, json_path: Path | None) -> dict[str, Any]:
    json_summary = operator_network_json_summary(json_path)
    if json_summary.get("present"):
        return json_summary
    return operator_network_summary(log_path)


def verify_cloud_security_group_repair_receipt(
    path: Path,
    max_age_seconds: int,
    *,
    expect_security_group_id: str,
    expect_region_id: str,
    expect_admin_cidr: str,
) -> None:
    require_file(CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_VERIFIER, "cloud_security_group_repair_receipt_verifier_missing")
    env = dict(os.environ)
    env.update({
        "ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_JSON": str(path),
        "ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_REQUIRE_APPLIED": "true",
        "ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_REQUIRE_VERIFIED": "true",
        "ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS": str(max_age_seconds),
        "ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID": expect_security_group_id,
        "ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID": expect_region_id,
        "ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR": expect_admin_cidr,
    })
    try:
        subprocess.run(
            ["bash", str(CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_VERIFIER)],
            check=True,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
    except subprocess.CalledProcessError as exc:
        fail(
            "cloud_security_group_repair_receipt_verify_failed",
            path=path,
            verifier=CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_VERIFIER,
            output=(exc.stdout or "").replace("\n", "\\n")[:500],
        )


def int_value(payload: dict[str, Any], key: str, context: str) -> int:
    if key not in payload:
        fail(f"{context}_{key}_missing")
    try:
        return int(payload.get(key))
    except Exception:
        fail(f"{context}_{key}_invalid", value=payload.get(key))


def artifact_path(
    receipt_path: Path,
    value: Any,
    fallback_name: str,
    *,
    evidence_dir: Path | None = None,
) -> Path:
    return artifact_file(receipt_path, value, fallback_name, evidence_dir=evidence_dir)


def artifact_file(
    receipt_path: Path,
    value: Any,
    fallback_name: str,
    *,
    evidence_dir: Path | None = None,
    suffix: str | None = None,
) -> Path:
    candidates: list[Path] = []
    if value:
        raw = Path(str(value)).expanduser()
        candidates.append(raw)
        if not raw.is_absolute():
            candidates.append(receipt_path.parent / raw)
            if evidence_dir is not None:
                candidates.append(evidence_dir / raw)
    if fallback_name:
        candidates.append(receipt_path.parent / fallback_name)
        if evidence_dir is not None:
            candidates.append(evidence_dir / fallback_name)

    normalized: list[Path] = []
    for candidate in candidates:
        if suffix is not None:
            normalized.append(candidate.with_suffix(suffix))
        normalized.append(candidate)
    for candidate in normalized:
        if candidate.is_file():
            return candidate
    if normalized:
        return normalized[0]
    return receipt_path.parent / fallback_name


def require_target(receipt: dict[str, Any]) -> None:
    target = receipt.get("target") or {}
    for key in ("baseURL", "tcpHost", "tcpPort"):
        if not str(target.get(key) or "").strip():
            fail("target_field_missing", field=key)


def public_host_reason(host: str) -> str:
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


def require_packageable_public_target(receipt: dict[str, Any], status: str, policy: dict[str, Any]) -> None:
    if status != "PASS" or not as_bool(policy.get("requirePackageableEvidence")):
        return
    target = receipt.get("target") or {}
    base_url = str(target.get("baseURL") or "")
    tcp_host = str(target.get("tcpHost") or "")
    parsed = urlparse(base_url)
    if parsed.scheme != "https":
        fail("public_base_url_https_required", baseURL=base_url or "-")
    try:
        base_port = parsed.port or 443
    except ValueError:
        fail("public_base_url_port_invalid", baseURL=base_url or "-")
    if base_port != 443:
        fail("public_base_url_default_https_port_required", baseURL=base_url or "-", port=base_port)
    base_host = parsed.hostname or ""
    base_reason = public_host_reason(base_host)
    if base_reason:
        fail("public_base_url_domain_required", host=base_host or "-", hostReason=base_reason)
    tcp_reason = public_host_reason(tcp_host)
    if tcp_reason:
        fail("tcp_host_domain_required", tcpHost=tcp_host or "-", hostReason=tcp_reason)


def require_expected_target(receipt: dict[str, Any], args: argparse.Namespace) -> None:
    target = receipt.get("target") or {}
    expected = {
        "baseURL": getattr(args, "expect_base_url", None),
        "tcpHost": getattr(args, "expect_tcp_host", None),
        "tcpPort": getattr(args, "expect_tcp_port", None),
    }
    for key, expected_value in expected.items():
        if expected_value is None or str(expected_value).strip() == "":
            continue
        actual = str(target.get(key) or "")
        expected_text = str(expected_value)
        if actual != expected_text:
            fail(
                "target_mismatch",
                field=key,
                expected=expected_text,
                actual=actual or "-",
            )


def requested_runs(receipt: dict[str, Any]) -> dict[str, Any]:
    requested = receipt.get("requestedRuns")
    if not isinstance(requested, dict):
        fail("requested_runs_missing")
    return requested


def require_evidence_policy(
    receipt_path: Path,
    receipt: dict[str, Any],
    status: str,
    *,
    evidence_dir: Path | None = None,
) -> dict[str, Any]:
    policy = receipt.get("evidencePolicy")
    if not isinstance(policy, dict):
        fail("evidence_policy_missing")
    for key in ("requirePackageableEvidence", "autoProductScenarioSuiteForPackageableAcceptance"):
        if key not in policy:
            fail("evidence_policy_field_missing", field=key)
    if "requireCloudSecurityGroup" not in policy:
        fail("evidence_policy_field_missing", field="requireCloudSecurityGroup")
    if "requirePublicPortPolicy" not in policy:
        fail("evidence_policy_field_missing", field="requirePublicPortPolicy")
    if "allowTempHTTP8080" not in policy:
        fail("evidence_policy_field_missing", field="allowTempHTTP8080")
    if "cloudSecurityGroupRulesFile" not in policy:
        fail("evidence_policy_field_missing", field="cloudSecurityGroupRulesFile")
    if "cloudSecurityGroupRulesMaxAgeSeconds" not in policy:
        fail("evidence_policy_field_missing", field="cloudSecurityGroupRulesMaxAgeSeconds")
    if "cloudSecurityGroupRulesRequireRootOwner" not in policy:
        fail("evidence_policy_field_missing", field="cloudSecurityGroupRulesRequireRootOwner")
    if "requireCloudSecurityGroupRepairReceipt" not in policy:
        fail("evidence_policy_field_missing", field="requireCloudSecurityGroupRepairReceipt")
    if "cloudSecurityGroupRepairReceiptJSON" not in policy:
        fail("evidence_policy_field_missing", field="cloudSecurityGroupRepairReceiptJSON")

    if as_bool(policy.get("requireCloudSecurityGroup")) and not as_bool(policy.get("requirePublicPortPolicy")):
        fail("public_port_policy_required_when_cloud_security_group_required")
    if as_bool(policy.get("requireCloudSecurityGroup")) and not as_bool(policy.get("requireCloudSecurityGroupRepairReceipt")):
        fail("cloud_security_group_repair_receipt_required_when_cloud_security_group_required")
    if as_bool(policy.get("requireCloudSecurityGroup")) and status == "PASS" and as_bool(policy.get("allowTempHTTP8080")):
        fail("temp_http_8080_not_allowed_for_production")

    if as_bool(policy.get("requireCloudSecurityGroup")) and status == "PASS":
        try:
            rules_max_age_seconds = int(policy.get("cloudSecurityGroupRulesMaxAgeSeconds") or 0)
        except Exception:
            fail("cloud_security_group_rules_max_age_invalid", value=policy.get("cloudSecurityGroupRulesMaxAgeSeconds"))
        if rules_max_age_seconds <= 0:
            fail("cloud_security_group_rules_max_age_invalid", value=rules_max_age_seconds)
        if not as_bool(policy.get("cloudSecurityGroupRulesRequireRootOwner")):
            fail("cloud_security_group_rules_root_owner_required_for_production")
        rules_file = str(policy.get("cloudSecurityGroupRulesFile") or "")
        if not rules_file:
            fail("cloud_security_group_rules_file_missing")
        rules_file_path = artifact_file(
            receipt_path,
            rules_file,
            "cloud-security-group.json",
            evidence_dir=evidence_dir,
        )
        require_file(rules_file_path, "cloud_security_group_rules_file_missing")
        artifacts = receipt.get("artifacts") or {}
        artifact_rules = str(artifacts.get("cloudSecurityGroupRulesFile") or "")
        if artifact_rules != rules_file:
            fail("cloud_security_group_rules_artifact_mismatch", policy=rules_file, artifact=artifact_rules or "-")
        require_file(
            artifact_path(
                receipt_path,
                artifacts.get("cloudSecurityGroupAuditLog"),
                "cloud-security-group-audit.log",
                evidence_dir=evidence_dir,
            ),
            "cloud_security_group_audit_log_missing",
        )
        repair_receipt = str(policy.get("cloudSecurityGroupRepairReceiptJSON") or "")
        if not repair_receipt:
            fail("cloud_security_group_repair_receipt_json_missing")
        repair_receipt_path = artifact_file(
            receipt_path,
            repair_receipt,
            "cloud-security-group-repair-receipt.json",
            evidence_dir=evidence_dir,
        )
        require_file(repair_receipt_path, "cloud_security_group_repair_receipt_missing")
        artifact_receipt = str(artifacts.get("cloudSecurityGroupRepairReceiptJSON") or "")
        if artifact_receipt != repair_receipt:
            fail("cloud_security_group_repair_receipt_artifact_mismatch", policy=repair_receipt, artifact=artifact_receipt or "-")
        require_file(
            artifact_path(
                receipt_path,
                artifacts.get("cloudSecurityGroupRepairReceiptVerifyLog"),
                "cloud-security-group-repair-receipt-verify.log",
                evidence_dir=evidence_dir,
            ),
            "cloud_security_group_repair_receipt_verify_log_missing",
        )
        try:
            max_age_seconds = int(policy.get("cloudSecurityGroupRepairReceiptMaxAgeSeconds") or 0)
        except Exception:
            fail("cloud_security_group_repair_receipt_max_age_invalid", value=policy.get("cloudSecurityGroupRepairReceiptMaxAgeSeconds"))
        expect_security_group_id = str(policy.get("cloudSecurityGroupRepairReceiptExpectSecurityGroupID") or "")
        if not expect_security_group_id:
            fail("cloud_security_group_repair_receipt_expected_security_group_id_missing")
        expect_region_id = str(policy.get("cloudSecurityGroupRepairReceiptExpectRegionID") or "")
        if not expect_region_id:
            fail("cloud_security_group_repair_receipt_expected_region_id_missing")
        expect_admin_cidr = str(policy.get("cloudSecurityGroupRepairReceiptExpectAdminCIDR") or "")
        if not expect_admin_cidr:
            fail("cloud_security_group_repair_receipt_expected_admin_cidr_missing")
        verify_cloud_security_group_repair_receipt(
            repair_receipt_path,
            max_age_seconds,
            expect_security_group_id=expect_security_group_id,
            expect_region_id=expect_region_id,
            expect_admin_cidr=expect_admin_cidr,
        )
    return policy


def require_probe_consistency(
    receipt_path: Path,
    receipt: dict[str, Any],
    policy: dict[str, Any],
    status: str,
    probe_arg: Path | None,
    *,
    evidence_dir: Path | None = None,
) -> dict[str, Any]:
    entrypoint = receipt.get("entrypoint") or {}
    probe_path = probe_arg or artifact_path(
        receipt_path,
        entrypoint.get("probeJSON"),
        "entrypoint-probe.json",
        evidence_dir=evidence_dir,
    )
    require_file(probe_path, "probe_json_missing")
    probe = read_json(probe_path)
    if as_bool(probe.get("failed")) != as_bool(entrypoint.get("failed")):
        fail(
            "probe_failed_mismatch",
            receipt=entrypoint.get("failed"),
            probe=probe.get("failed"),
        )
    probe_diagnosis = str(probe.get("diagnosis") or "")
    receipt_diagnosis = str(entrypoint.get("diagnosis") or "")
    if probe_diagnosis != receipt_diagnosis:
        fail("probe_diagnosis_mismatch", receipt=receipt_diagnosis or "-", probe=probe_diagnosis or "-")
    if as_bool(policy.get("requirePublicPortPolicy")) and status == "PASS":
        public_status = str(probe.get("publicPortPolicyStatus") or (probe.get("signals") or {}).get("publicPortPolicyStatus") or "")
        if public_status != "pass":
            fail("public_port_policy_not_pass", status=public_status or "-")
        denied_ports = probe.get("publicDeniedPortsOpen")
        if denied_ports is None:
            denied_ports = (probe.get("signals") or {}).get("publicDeniedPortsOpen")
        if denied_ports:
            fail("public_denied_ports_open", ports=",".join(str(item) for item in denied_ports))
        missing_ports = probe.get("publicExpectedPortsMissing")
        if missing_ports is None:
            missing_ports = (probe.get("signals") or {}).get("publicExpectedPortsMissing")
        if missing_ports:
            fail("public_expected_ports_missing", ports=",".join(str(item) for item in missing_ports))
    return probe


def require_optional_rescue_artifacts(
    receipt_path: Path,
    receipt: dict[str, Any],
    *,
    evidence_dir: Path | None = None,
) -> None:
    artifacts = receipt.get("artifacts") or {}
    rescue_summary = str(artifacts.get("rescueSummary") or "")
    if rescue_summary:
        require_file(
            artifact_path(receipt_path, rescue_summary, "entrypoint-rescue-summary.txt", evidence_dir=evidence_dir),
            "rescue_summary_missing",
        )
    rescue_manifest = str(artifacts.get("rescueManifest") or "")
    if rescue_manifest:
        require_file(
            artifact_path(receipt_path, rescue_manifest, "artifact-manifest.json", evidence_dir=evidence_dir),
            "rescue_manifest_missing",
        )
    rescue_tarball = str(artifacts.get("rescueTarball") or "")
    if not rescue_tarball:
        return
    require_file(
        artifact_path(receipt_path, rescue_tarball, "current-node-access-rescue.tar.gz", evidence_dir=evidence_dir),
        "rescue_tarball_missing",
    )
    for field, fallback, reason in (
        ("rescueTarballVerifyScript", "current-node-access-rescue.tar.gz.verify.sh", "rescue_tarball_verify_script_missing"),
        ("rescueTarballSha256", "current-node-access-rescue.tar.gz.sha256", "rescue_tarball_sha256_missing"),
        ("rescueTarballReceipt", "current-node-access-rescue.tar.gz.receipt.json", "rescue_tarball_receipt_missing"),
    ):
        value = str(artifacts.get(field) or "")
        if not value:
            fail(f"{field}_field_missing")
        require_file(artifact_path(receipt_path, value, fallback, evidence_dir=evidence_dir), reason)


def next_command(payload: dict[str, Any]) -> str:
    return str(payload.get("nextCommand") or (payload.get("summary") or {}).get("nextCommand") or "")


def require_next_command_consistency(dashboard: dict[str, Any], state: dict[str, Any]) -> None:
    dashboard_command = next_command(dashboard)
    state_command = next_command(state)
    if dashboard_command and state_command and dashboard_command != state_command:
        fail("next_command_mismatch", dashboard=dashboard_command, state=state_command)


def production_blocker_codes(summary: dict[str, Any]) -> list[str]:
    value = summary.get("productionEvidenceBlockers")
    if isinstance(value, list):
        return [str(item) for item in value if str(item)]
    if isinstance(value, str) and value:
        return [item for item in value.split(",") if item]
    return []


def production_action_command_roles(summary: dict[str, Any]) -> list[str]:
    value = summary.get("productionEvidenceActionCommands")
    if isinstance(value, list):
        return [str(item) for item in value if str(item)]
    if isinstance(value, str) and value:
        return [item for item in value.split(",") if item]
    return []


def expected_production_evidence_command_role(code: str, source: str = "") -> str:
    if source == "current-production-readiness":
        return "current-production-readiness"
    if source == "production-acceptance":
        return "production-acceptance"
    if source == "production-gate":
        return "production-profile"
    if code.startswith("production_acceptance_") or code in {
        "operator_network_preflight_policy_missing",
        "cloud_security_group_repair_receipt_policy_missing",
        "cloud_security_group_repair_receipt_missing",
        "cloud_security_group_repair_receipt_expected_security_group_missing",
        "cloud_security_group_repair_receipt_expected_region_missing",
        "cloud_security_group_repair_receipt_expected_admin_cidr_missing",
    }:
        return "production-acceptance"
    if code.startswith("public_") or code.startswith("operator_network_") or code in {
        "current_production_readiness_missing",
        "current_production_readiness_not_pass",
    }:
        return "current-production-readiness"
    return "production-profile"


def require_production_evidence_command(role: str, command: str, context: str) -> None:
    expected_script = PRODUCTION_EVIDENCE_COMMAND_SCRIPTS.get(role)
    if not expected_script:
        fail("production_evidence_command_role_invalid", context=context, role=role or "-")
    if not command:
        fail("production_evidence_command_missing", context=context, role=role)
    if expected_script not in command:
        fail("production_evidence_command_script_mismatch", context=context, role=role, command=command)
    if "yourdomain.com" in command or "BASE_URL=https://im.example.com" in command or "TCP_HOST=im.example.com" in command:
        fail("production_evidence_command_placeholder_target", context=context, role=role)
    if "/Users/" in command or "/Desktop/" in command:
        fail("production_evidence_command_workstation_path", context=context, role=role)


def require_state_production_evidence_blocker_contract(state: dict[str, Any], state_csv_path: Path | None = None) -> None:
    summary = state.get("summary") or {}
    conclusion = str(summary.get("conclusion") or "")
    blockers = state.get("productionEvidenceBlockers") or []
    if not isinstance(blockers, list):
        fail("state_production_evidence_blockers_invalid")
    codes = production_blocker_codes(summary)
    try:
        blocker_count = int(summary.get("productionEvidenceBlockerCount") or 0)
    except Exception:
        fail("state_production_evidence_blocker_count_invalid", value=summary.get("productionEvidenceBlockerCount"))
    if blocker_count != len(blockers):
        fail("state_production_evidence_blocker_count_mismatch", summary=blocker_count, rows=len(blockers))
    if sorted(codes) != sorted(str(row.get("code") or "") for row in blockers if isinstance(row, dict) and row.get("code")):
        fail("state_production_evidence_blocker_codes_mismatch")
    for row in blockers:
        if not isinstance(row, dict):
            fail("state_production_evidence_blocker_row_invalid")
        for key in ("code", "severity", "source", "reason", "action", "commandRole", "command"):
            if not str(row.get(key) or ""):
                fail("state_production_evidence_blocker_field_missing", field=key)
        code = str(row.get("code") or "")
        source = str(row.get("source") or "")
        role = str(row.get("commandRole") or "")
        expected_role = expected_production_evidence_command_role(code, source)
        if role != expected_role:
            fail("state_production_evidence_blocker_command_role_mismatch", code=code, expected=expected_role, actual=role)
        require_production_evidence_command(role, str(row.get("command") or ""), f"blocker:{code}")
    if conclusion == "NEEDS_PRODUCTION_EVIDENCE" and blocker_count <= 0:
        fail("state_production_evidence_blockers_missing")
    if conclusion == "READY" and blocker_count != 0:
        fail("state_ready_has_production_evidence_blockers", count=blocker_count)
    action_commands = state.get("productionEvidenceActionCommands") or []
    if blocker_count > 0 and not isinstance(action_commands, list):
        fail("state_production_evidence_action_commands_invalid")
    if blocker_count > 0 and not action_commands:
        fail("state_production_evidence_action_commands_missing")
    action_roles: set[str] = set()
    for row in action_commands:
        if not isinstance(row, dict):
            fail("state_production_evidence_action_command_row_invalid")
        role = str(row.get("role") or "")
        command = str(row.get("command") or "")
        require_production_evidence_command(role, command, f"action:{role}")
        action_roles.add(role)
    blocker_roles = {str(row.get("commandRole") or "") for row in blockers if isinstance(row, dict) and row.get("commandRole")}
    if blocker_roles and not blocker_roles.issubset(action_roles):
        fail(
            "state_production_evidence_action_command_roles_missing",
            expected=",".join(sorted(blocker_roles)),
            actual=",".join(sorted(action_roles)) or "-",
        )
    summary_action_roles = production_action_command_roles(summary)
    if sorted(summary_action_roles) != sorted(action_roles):
        fail(
            "state_production_evidence_action_command_summary_mismatch",
            summary=",".join(sorted(summary_action_roles)) or "-",
            rows=",".join(sorted(action_roles)) or "-",
        )
    if state_csv_path is None:
        return
    require_file(state_csv_path, "state_csv_missing")
    try:
        with state_csv_path.open(newline="", encoding="utf-8") as handle:
            rows = list(csv.DictReader(handle))
    except Exception as exc:
        fail("state_csv_read_failed", path=state_csv_path, error=exc)
    csv_summary = next((row for row in rows if row.get("recordType") == "summary"), None)
    if csv_summary is None:
        fail("state_csv_summary_row_missing", path=state_csv_path)
    try:
        csv_blocker_count = int(csv_summary.get("productionEvidenceBlockerCount") or 0)
    except Exception:
        fail("state_csv_production_evidence_blocker_count_invalid", value=csv_summary.get("productionEvidenceBlockerCount"))
    if csv_blocker_count != blocker_count:
        fail("state_csv_production_evidence_blocker_count_mismatch", csv=csv_blocker_count, json=blocker_count)
    csv_codes = production_blocker_codes({"productionEvidenceBlockers": csv_summary.get("productionEvidenceBlockers") or ""})
    if sorted(csv_codes) != sorted(codes):
        fail("state_csv_production_evidence_blocker_codes_mismatch")
    csv_action_roles = production_action_command_roles({"productionEvidenceActionCommands": csv_summary.get("productionEvidenceActionCommands") or ""})
    if sorted(csv_action_roles) != sorted(action_roles):
        fail(
            "state_csv_production_evidence_action_command_roles_mismatch",
            csv=",".join(sorted(csv_action_roles)) or "-",
            json=",".join(sorted(action_roles)) or "-",
        )


def csv_list(value: str | None) -> list[str]:
    if not value:
        return []
    return [item for item in str(value).split(",") if item]


def require_operator_network_state_consistency(
    receipt_path: Path,
    receipt: dict[str, Any],
    state: dict[str, Any],
    state_csv_path: Path,
    *,
    evidence_dir: Path | None = None,
) -> None:
    policy = receipt.get("evidencePolicy") if isinstance(receipt.get("evidencePolicy"), dict) else {}
    artifacts = receipt.get("artifacts") if isinstance(receipt.get("artifacts"), dict) else {}
    operator_required = policy.get("operatorNetworkPreflight") is True
    operator_log = artifact_path(
        receipt_path,
        artifacts.get("operatorNetworkLog"),
        "operator-network.log",
        evidence_dir=evidence_dir,
    )
    operator_json = artifact_path(
        receipt_path,
        artifacts.get("operatorNetworkJSON"),
        "operator-network.json",
        evidence_dir=evidence_dir,
    )
    expected = operator_network_evidence_summary(operator_log, operator_json)
    operator_log_present = bool(operator_log and operator_log.is_file())
    operator_json_present = bool(operator_json and operator_json.is_file())
    summary = state.get("summary") or {}

    if "currentReadinessOperatorNetworkPreflight" not in summary:
        fail("state_operator_network_policy_missing")
    if summary.get("currentReadinessOperatorNetworkPreflight") != policy.get("operatorNetworkPreflight"):
        fail(
            "state_operator_network_policy_mismatch",
            expected=policy.get("operatorNetworkPreflight"),
            actual=summary.get("currentReadinessOperatorNetworkPreflight"),
        )
    if operator_required:
        if not operator_log_present:
            fail("operator_network_log_missing", path=operator_log)
        if "operatorNetworkJSON" in artifacts and not operator_json_present:
            fail("operator_network_json_missing", path=operator_json)
        expected_scalar = {
            "currentReadinessOperatorNetworkLogPresent": operator_log_present,
            "currentReadinessOperatorNetworkFailed": expected.get("failed"),
            "currentReadinessOperatorNetworkFailureCount": expected.get("failureCount"),
        }
        if "currentReadinessOperatorNetworkJSONPresent" in summary:
            expected_scalar["currentReadinessOperatorNetworkJSONPresent"] = operator_json_present
        if "currentReadinessOperatorNetworkEvidencePresent" in summary:
            expected_scalar["currentReadinessOperatorNetworkEvidencePresent"] = expected.get("present")
        for key, expected_value in expected_scalar.items():
            if summary.get(key) != expected_value:
                fail(
                    "state_operator_network_summary_mismatch",
                    field=key,
                    expected=expected_value,
                    actual=summary.get(key),
                )
        expected_lists = {
            "currentReadinessOperatorNetworkWarnings": expected.get("warnings") or [],
            "currentReadinessOperatorNetworkRouteInterfaces": expected.get("routeInterfaces") or [],
            "currentReadinessOperatorNetworkRouteGateways": expected.get("routeGateways") or [],
        }
        for key, expected_value in expected_lists.items():
            actual_value = summary.get(key)
            if sorted(str(item) for item in (actual_value or [])) != sorted(str(item) for item in expected_value):
                fail(
                    "state_operator_network_summary_mismatch",
                    field=key,
                    expected=",".join(str(item) for item in expected_value) or "-",
                    actual=",".join(str(item) for item in (actual_value or [])) or "-",
                )
        codes = set(production_blocker_codes(summary))
        if expected.get("failed") is True and "operator_network_failed" not in codes:
            fail("state_operator_network_failed_blocker_missing")
        warnings = [str(item) for item in expected.get("warnings") or [] if str(item)]
        if warnings and "operator_network_warning" not in codes:
            fail("state_operator_network_warning_blocker_missing")

    require_file(state_csv_path, "state_csv_missing")
    try:
        with state_csv_path.open(newline="", encoding="utf-8") as handle:
            rows = list(csv.DictReader(handle))
    except Exception as exc:
        fail("state_csv_read_failed", path=state_csv_path, error=exc)
    csv_summary = next((row for row in rows if row.get("recordType") == "summary"), None)
    if csv_summary is None:
        fail("state_csv_summary_row_missing", path=state_csv_path)
    expected_policy_csv = "" if policy.get("operatorNetworkPreflight") is None else str(policy.get("operatorNetworkPreflight"))
    if csv_summary.get("currentReadinessOperatorNetworkPreflight") != expected_policy_csv:
        fail(
            "state_csv_operator_network_policy_mismatch",
            expected=expected_policy_csv,
            actual=csv_summary.get("currentReadinessOperatorNetworkPreflight"),
        )
    if operator_required:
        csv_expected = {
            "currentReadinessOperatorNetworkLogPresent": str(expected.get("present")),
            "currentReadinessOperatorNetworkFailed": str(expected.get("failed")),
            "currentReadinessOperatorNetworkFailureCount": str(expected.get("failureCount")),
        }
        for key, expected_value in csv_expected.items():
            if csv_summary.get(key) != expected_value:
                fail(
                    "state_csv_operator_network_summary_mismatch",
                    field=key,
                    expected=expected_value,
                    actual=csv_summary.get(key),
                )
        csv_expected_lists = {
            "currentReadinessOperatorNetworkWarnings": expected.get("warnings") or [],
            "currentReadinessOperatorNetworkRouteInterfaces": expected.get("routeInterfaces") or [],
            "currentReadinessOperatorNetworkRouteGateways": expected.get("routeGateways") or [],
        }
        for key, expected_value in csv_expected_lists.items():
            actual_value = csv_list(csv_summary.get(key))
            if sorted(actual_value) != sorted(str(item) for item in expected_value):
                fail(
                    "state_csv_operator_network_summary_mismatch",
                    field=key,
                    expected=",".join(str(item) for item in expected_value) or "-",
                    actual=",".join(actual_value) or "-",
                )


def require_attempted_run_artifacts(
    receipt_path: Path,
    receipt: dict[str, Any],
    *,
    evidence_dir: Path | None = None,
) -> None:
    artifacts = receipt.get("artifacts") or {}
    runs = receipt.get("runs") or {}
    requested = requested_runs(receipt)
    smoke_exit = runs.get("smokeExitCode")
    suite_exit = runs.get("suiteExitCode")
    baseline_exit = runs.get("baselineExitCode")
    full_acceptance_exit = runs.get("fullAcceptanceExitCode")

    if smoke_exit is not None:
        require_file(
            artifact_path(receipt_path, artifacts.get("smokeLog"), "normal-product-smoke.log", evidence_dir=evidence_dir),
            "smoke_log_missing",
        )
    if suite_exit is not None:
        require_file(
            artifact_path(
                receipt_path,
                artifacts.get("productScenarioSuiteLog"),
                "product-scenario-suite.log",
                evidence_dir=evidence_dir,
            ),
            "product_scenario_suite_log_missing",
        )
        if suite_exit == 0:
            suite_run_json = artifact_path(
                receipt_path,
                artifacts.get("productScenarioSuiteRunJSON"),
                "product-scenario-suite/product-scenario-suite-run.json",
                evidence_dir=evidence_dir,
            )
            suite_run_md = artifact_path(
                receipt_path,
                artifacts.get("productScenarioSuiteRunMarkdown"),
                "product-scenario-suite/product-scenario-suite-run.md",
                evidence_dir=evidence_dir,
            )
            require_file(suite_run_json, "product_scenario_suite_run_json_missing")
            require_file(suite_run_md, "product_scenario_suite_markdown_missing")
            suite = read_json(suite_run_json)
            try:
                verify_product_scenario_suite(
                    suite,
                    suite_run_md,
                    receipt_base=suite_run_json.parent,
                    require_pass=True,
                    allow_planned=False,
                    require_no_large_group=True,
                )
            except SystemExit as exc:
                fail("product_scenario_suite_artifact_verify_failed", verifier=str(exc))
            requested_suite = str(requested.get("productScenarioSuiteName") or "").strip()
            if not requested_suite:
                fail("product_scenario_suite_expected_missing")
            actual_suite = str(suite.get("suite") or "")
            if actual_suite != requested_suite:
                fail("product_scenario_suite_name_mismatch", expected=requested_suite, actual=actual_suite or "-")
            if str(suite.get("status") or "") != "PASS":
                fail("product_scenario_suite_not_pass", status=suite.get("status") or "-")
            coverage = suite.get("coverageSummary") or {}
            if int(coverage.get("coverageErrorCount") or 0) != 0:
                fail("product_scenario_suite_coverage_errors", count=coverage.get("coverageErrorCount"))
            if int(coverage.get("uniqueScenarioCount") or 0) <= 0:
                fail("product_scenario_suite_empty")
            if coverage.get("largeGroupIncluded") is not False:
                fail("product_scenario_suite_large_group_included", largeGroupIncluded=coverage.get("largeGroupIncluded"))
    if baseline_exit is not None:
        require_file(
            artifact_path(
                receipt_path,
                artifacts.get("baselineLog"),
                "normal-product-baseline.log",
                evidence_dir=evidence_dir,
            ),
            "baseline_log_missing",
        )
    if full_acceptance_exit is not None:
        require_file(
            artifact_path(
                receipt_path,
                artifacts.get("fullAcceptanceLog"),
                "production-full-acceptance.log",
                evidence_dir=evidence_dir,
            ),
            "full_acceptance_log_missing",
        )
        if full_acceptance_exit == 0:
            run_json_path = artifact_path(
                receipt_path,
                artifacts.get("fullAcceptanceRunJSON"),
                "production-full-acceptance/product-campaign-run.json",
                evidence_dir=evidence_dir,
            )
            runbook_path = artifact_path(
                receipt_path,
                artifacts.get("fullAcceptanceRunbook"),
                "production-full-acceptance/product-campaign-runbook.md",
                evidence_dir=evidence_dir,
            )
            require_file(run_json_path, "full_acceptance_run_json_missing")
            require_file(runbook_path, "full_acceptance_runbook_missing")
            campaign = read_json(run_json_path)
            expected_campaign = str(requested.get("fullAcceptanceCampaign") or "").strip()
            if not expected_campaign:
                fail("full_acceptance_campaign_expected_missing")
            actual_campaign = str(campaign.get("campaign") or "")
            if actual_campaign != expected_campaign:
                fail(
                    "full_acceptance_campaign_mismatch",
                    expected=expected_campaign,
                    actual=actual_campaign or "-",
                )
            if str(campaign.get("finalStatus") or "") != "PASS":
                fail("full_acceptance_campaign_not_pass", status=campaign.get("finalStatus") or "-")
            if campaign.get("execute") is False:
                fail("full_acceptance_campaign_not_executed")
            failure_count = int_value(campaign, "failureCount", "full_acceptance_campaign")
            required_failure_count = int_value(campaign, "requiredFailureCount", "full_acceptance_campaign")
            attempted_stage_count = int_value(campaign, "attemptedStageCount", "full_acceptance_campaign")
            skipped_stage_count = int_value(campaign, "skippedStageCount", "full_acceptance_campaign")
            if required_failure_count != 0:
                fail("full_acceptance_campaign_required_failures", count=required_failure_count)
            if failure_count != 0:
                fail("full_acceptance_campaign_failures", count=failure_count)
            if attempted_stage_count <= 0:
                fail("full_acceptance_campaign_not_attempted", count=attempted_stage_count)
            if skipped_stage_count != 0:
                fail("full_acceptance_campaign_skipped_stages", count=skipped_stage_count)
            runbook_text = runbook_path.read_text(encoding="utf-8", errors="replace")
            try:
                expected_runbook = build_product_campaign_runbook(campaign)
            except KeyError as exc:
                fail("full_acceptance_campaign_runbook_field_missing", field=exc.args[0])
            if runbook_text != expected_runbook:
                fail("full_acceptance_runbook_mismatch", runbook=runbook_path)


def full_acceptance_summary(
    receipt_path: Path,
    receipt: dict[str, Any],
    *,
    evidence_dir: Path | None = None,
) -> dict[str, Any] | None:
    requested = requested_runs(receipt)
    runs = receipt.get("runs") or {}
    if not as_bool(requested.get("fullAcceptance")) or runs.get("fullAcceptanceExitCode") != 0:
        return None
    artifacts = receipt.get("artifacts") or {}
    run_json_path = artifact_path(
        receipt_path,
        artifacts.get("fullAcceptanceRunJSON"),
        "production-full-acceptance/product-campaign-run.json",
        evidence_dir=evidence_dir,
    )
    require_file(run_json_path, "full_acceptance_run_json_missing")
    campaign = read_json(run_json_path)
    return {
        "currentReadinessStatus": str(receipt.get("status") or ""),
        "currentReadinessReason": str(receipt.get("reason") or ""),
        "currentReadinessRequestedSmoke": requested.get("smoke"),
        "currentReadinessRequestedBaseline": requested.get("baseline"),
        "currentReadinessRequestedFullAcceptance": requested.get("fullAcceptance"),
        "currentReadinessSmokeExitCode": runs.get("smokeExitCode"),
        "currentReadinessBaselineExitCode": runs.get("baselineExitCode"),
        "currentReadinessFullAcceptanceExitCode": runs.get("fullAcceptanceExitCode"),
        "currentReadinessFullAcceptanceExpectedCampaign": requested.get("fullAcceptanceCampaign"),
        "currentReadinessFullAcceptanceCampaign": campaign.get("campaign"),
        "currentReadinessFullAcceptanceStatus": campaign.get("finalStatus"),
        "currentReadinessFullAcceptanceFailures": campaign.get("failureCount"),
        "currentReadinessFullAcceptanceRequiredFailures": campaign.get("requiredFailureCount"),
        "currentReadinessFullAcceptanceAttempted": campaign.get("attemptedStageCount"),
        "currentReadinessFullAcceptanceSkipped": campaign.get("skippedStageCount"),
    }


def product_scenario_suite_summary(
    receipt_path: Path,
    receipt: dict[str, Any],
    *,
    evidence_dir: Path | None = None,
) -> dict[str, Any] | None:
    requested = requested_runs(receipt)
    runs = receipt.get("runs") or {}
    if not as_bool(requested.get("productScenarioSuite")) or runs.get("suiteExitCode") != 0:
        return None
    artifacts = receipt.get("artifacts") or {}
    suite_run_path = artifact_path(
        receipt_path,
        artifacts.get("productScenarioSuiteRunJSON"),
        "product-scenario-suite/product-scenario-suite-run.json",
        evidence_dir=evidence_dir,
    )
    require_file(suite_run_path, "product_scenario_suite_run_json_missing")
    suite = read_json(suite_run_path)
    coverage = suite.get("coverageSummary") or {}
    return {
        "currentReadinessStatus": str(receipt.get("status") or ""),
        "currentReadinessReason": str(receipt.get("reason") or ""),
        "currentReadinessRequestedSmoke": requested.get("smoke"),
        "currentReadinessRequestedProductScenarioSuite": requested.get("productScenarioSuite"),
        "currentReadinessRequestedBaseline": requested.get("baseline"),
        "currentReadinessRequestedFullAcceptance": requested.get("fullAcceptance"),
        "currentReadinessSmokeExitCode": runs.get("smokeExitCode"),
        "currentReadinessProductScenarioSuiteExitCode": runs.get("suiteExitCode"),
        "currentReadinessBaselineExitCode": runs.get("baselineExitCode"),
        "currentReadinessFullAcceptanceExitCode": runs.get("fullAcceptanceExitCode"),
        "currentReadinessProductScenarioSuiteExpected": requested.get("productScenarioSuiteName"),
        "currentReadinessProductScenarioSuite": suite.get("suite"),
        "currentReadinessProductScenarioSuiteStatus": suite.get("status"),
        "currentReadinessProductScenarioSuiteStageCount": suite.get("stageCount"),
        "currentReadinessProductScenarioSuiteFailedStages": suite.get("failedStageCount"),
        "currentReadinessProductScenarioSuitePlannedStages": suite.get("plannedStageCount"),
        "currentReadinessProductScenarioSuiteScenarios": coverage.get("uniqueScenarioCount"),
        "currentReadinessProductScenarioSuiteProductPlanStages": coverage.get("productPlanStageCount"),
        "currentReadinessProductScenarioSuiteLargeGroupIncluded": coverage.get("largeGroupIncluded"),
    }


def require_product_scenario_suite_dashboard_state_consistency(
    receipt_path: Path,
    receipt: dict[str, Any],
    dashboard: dict[str, Any],
    state: dict[str, Any],
    state_csv_path: Path,
    *,
    evidence_dir: Path | None = None,
) -> None:
    expected = product_scenario_suite_summary(receipt_path, receipt, evidence_dir=evidence_dir)
    if expected is None:
        return
    for source, payload in (("dashboard", dashboard), ("state", state)):
        summary = payload.get("summary") or {}
        for key, expected_value in expected.items():
            actual_value = summary.get(key)
            if actual_value != expected_value:
                fail(
                    "product_scenario_suite_summary_mismatch",
                    source=source,
                    field=key,
                    expected=expected_value,
                    actual=actual_value,
                )
    require_file(state_csv_path, "state_csv_missing")
    try:
        with state_csv_path.open(newline="", encoding="utf-8") as handle:
            rows = list(csv.DictReader(handle))
    except Exception as exc:
        fail("state_csv_read_failed", path=state_csv_path, error=exc)
    summary_rows = [row for row in rows if row.get("recordType") == "summary"]
    if not summary_rows:
        fail("state_csv_summary_row_missing", path=state_csv_path)
    csv_summary = summary_rows[0]
    for key, expected_value in expected.items():
        actual_value = csv_summary.get(key)
        normalized_expected = "" if expected_value is None else str(expected_value)
        if actual_value != normalized_expected:
            fail(
                "product_scenario_suite_state_csv_mismatch",
                field=key,
                expected=normalized_expected,
                actual=actual_value,
            )


def require_full_acceptance_dashboard_state_consistency(
    receipt_path: Path,
    receipt: dict[str, Any],
    dashboard: dict[str, Any],
    state: dict[str, Any],
    state_csv_path: Path,
    *,
    evidence_dir: Path | None = None,
) -> None:
    expected = full_acceptance_summary(receipt_path, receipt, evidence_dir=evidence_dir)
    if expected is None:
        return
    for source, payload in (("dashboard", dashboard), ("state", state)):
        summary = payload.get("summary") or {}
        for key, expected_value in expected.items():
            actual_value = summary.get(key)
            if actual_value != expected_value:
                fail(
                    "full_acceptance_summary_mismatch",
                    source=source,
                    field=key,
                    expected=expected_value,
                    actual=actual_value,
                )
    require_file(state_csv_path, "state_csv_missing")
    try:
        with state_csv_path.open(newline="", encoding="utf-8") as handle:
            rows = list(csv.DictReader(handle))
    except Exception as exc:
        fail("state_csv_read_failed", path=state_csv_path, error=exc)
    summary_rows = [row for row in rows if row.get("recordType") == "summary"]
    if not summary_rows:
        fail("state_csv_summary_row_missing", path=state_csv_path)
    csv_summary = summary_rows[0]
    for key, expected_value in expected.items():
        actual_value = csv_summary.get(key)
        normalized_expected = "" if expected_value is None else str(expected_value)
        if actual_value != normalized_expected:
            fail(
                "full_acceptance_state_csv_mismatch",
                field=key,
                expected=normalized_expected,
                actual=actual_value,
            )


def verify_blocked(
    receipt_path: Path,
    receipt: dict[str, Any],
    probe: dict[str, Any],
    dashboard: dict[str, Any],
    state: dict[str, Any],
    *,
    evidence_dir: Path | None = None,
) -> None:
    entrypoint = receipt.get("entrypoint") or {}
    blocker = entrypoint.get("blocker") or {}
    blocker_action = str(blocker.get("action") or "")
    if as_bool(entrypoint.get("failed")) is not True or as_bool(probe.get("failed")) is not True:
        fail("blocked_entrypoint_probe_not_failed")
    if blocker.get("type") != "entrypoint":
        fail("blocked_entrypoint_blocker_type_invalid", blockerType=blocker.get("type") or "-")
    if blocker.get("severity") != "P0":
        fail("blocked_entrypoint_blocker_severity_invalid", severity=blocker.get("severity") or "-")
    if blocker.get("preventsPerformanceEvidence") is not True:
        fail("blocked_entrypoint_blocker_not_preventing_performance")
    if not str((receipt.get("artifacts") or {}).get("rescueSummary") or ""):
        fail("blocked_entrypoint_rescue_summary_missing")
    require_optional_rescue_artifacts(receipt_path, receipt, evidence_dir=evidence_dir)
    if receipt_diagnosis := str(entrypoint.get("diagnosis") or ""):
        if receipt_diagnosis == "local_operator_network_blocked":
            operator_log = artifact_path(
                receipt_path,
                (receipt.get("artifacts") or {}).get("operatorNetworkLog"),
                "operator-network.log",
                evidence_dir=evidence_dir,
            )
            require_file(operator_log, "operator_network_log_missing")
            try:
                operator_log_text = operator_log.read_text(encoding="utf-8", errors="replace")
            except Exception as exc:
                fail("operator_network_log_read_failed", path=operator_log, error=exc)
            if "operator-network result=fail" not in operator_log_text:
                fail("operator_network_log_result_missing", path=operator_log)

    dashboard_summary = dashboard.get("summary") or {}
    state_summary = state.get("summary") or {}
    if dashboard_summary.get("entrypointRescueBlocked") is not True:
        fail("dashboard_entrypoint_rescue_not_blocked")
    if state_summary.get("conclusion") != "BLOCKED_ENTRYPOINT":
        fail("state_conclusion_not_blocked", conclusion=state_summary.get("conclusion") or "-")
    state_csv_path = artifact_path(
        receipt_path,
        (receipt.get("artifacts") or {}).get("stateSummary"),
        "current-production-state-summary.md",
        evidence_dir=evidence_dir,
    ).with_suffix(".csv")
    require_state_production_evidence_blocker_contract(state, state_csv_path)
    require_operator_network_state_consistency(receipt_path, receipt, state, state_csv_path, evidence_dir=evidence_dir)
    for name, summary in (("dashboard", dashboard_summary), ("state", state_summary)):
        diagnosis = str(summary.get("entrypointRescueDiagnosis") or "")
        if diagnosis != receipt_diagnosis:
            fail("entrypoint_diagnosis_mismatch", source=name, receipt=receipt_diagnosis or "-", actual=diagnosis or "-")
    command = next_command(state)
    if blocker_action == "cloud_console_rescue_required":
        if "entrypoint-rescue-plan.md" not in command and "post-rescue-verify.sh" not in command:
            fail("blocked_entrypoint_next_command_not_rescue", nextCommand=command or "-")

    runs = receipt.get("runs") or {}
    requested = requested_runs(receipt)
    if runs.get("smokeExitCode") is not None or runs.get("suiteExitCode") is not None or runs.get("baselineExitCode") is not None:
        fail("blocked_entrypoint_has_load_exit_codes")
    if runs.get("fullAcceptanceExitCode") is not None:
        fail("blocked_entrypoint_has_full_acceptance_exit_code")
    for key in ("smoke", "productScenarioSuite", "baseline", "fullAcceptance"):
        if key not in requested:
            fail("requested_run_field_missing", field=key)


def verify_unblocked(
    status: str,
    receipt_path: Path,
    receipt: dict[str, Any],
    dashboard: dict[str, Any],
    state: dict[str, Any],
    *,
    evidence_dir: Path | None = None,
) -> None:
    entrypoint = receipt.get("entrypoint") or {}
    if as_bool(entrypoint.get("failed")):
        fail("unblocked_entrypoint_marked_failed", status=status)
    dashboard_summary = dashboard.get("summary") or {}
    state_summary = state.get("summary") or {}
    if dashboard_summary.get("entrypointRescueBlocked") is True:
        fail("unblocked_dashboard_entrypoint_rescue_blocked", status=status)
    if state_summary.get("conclusion") == "BLOCKED_ENTRYPOINT":
        fail("unblocked_state_conclusion_blocked", status=status)

    runs = receipt.get("runs") or {}
    requested = requested_runs(receipt)
    require_attempted_run_artifacts(receipt_path, receipt, evidence_dir=evidence_dir)
    state_csv_path = artifact_path(
        receipt_path,
        (receipt.get("artifacts") or {}).get("stateSummary"),
        "current-production-state-summary.md",
        evidence_dir=evidence_dir,
    ).with_suffix(".csv")
    require_state_production_evidence_blocker_contract(state, state_csv_path)
    require_operator_network_state_consistency(receipt_path, receipt, state, state_csv_path, evidence_dir=evidence_dir)
    require_product_scenario_suite_dashboard_state_consistency(
        receipt_path,
        receipt,
        dashboard,
        state,
        state_csv_path,
        evidence_dir=evidence_dir,
    )
    require_full_acceptance_dashboard_state_consistency(
        receipt_path,
        receipt,
        dashboard,
        state,
        state_csv_path,
        evidence_dir=evidence_dir,
    )
    smoke_exit = runs.get("smokeExitCode")
    suite_exit = runs.get("suiteExitCode")
    baseline_exit = runs.get("baselineExitCode")
    full_acceptance_exit = runs.get("fullAcceptanceExitCode")
    reason = str(receipt.get("reason") or "")
    if status == "PASS":
        if as_bool(requested.get("smoke")) and smoke_exit != 0:
            fail("pass_requested_smoke_not_passed", smokeExitCode=smoke_exit)
        if not as_bool(requested.get("smoke")) and smoke_exit is not None:
            fail("pass_unrequested_smoke_exit_present", smokeExitCode=smoke_exit)
        if as_bool(requested.get("productScenarioSuite")) and suite_exit != 0:
            fail("pass_requested_product_scenario_suite_not_passed", suiteExitCode=suite_exit)
        if not as_bool(requested.get("productScenarioSuite")) and suite_exit is not None:
            fail("pass_unrequested_product_scenario_suite_exit_present", suiteExitCode=suite_exit)
        if as_bool(requested.get("baseline")) and baseline_exit != 0:
            fail("pass_requested_baseline_not_passed", baselineExitCode=baseline_exit)
        if not as_bool(requested.get("baseline")) and baseline_exit is not None:
            fail("pass_unrequested_baseline_exit_present", baselineExitCode=baseline_exit)
        if as_bool(requested.get("fullAcceptance")) and full_acceptance_exit != 0:
            fail("pass_requested_full_acceptance_not_passed", fullAcceptanceExitCode=full_acceptance_exit)
        if not as_bool(requested.get("fullAcceptance")) and full_acceptance_exit is not None:
            fail("pass_unrequested_full_acceptance_exit_present", fullAcceptanceExitCode=full_acceptance_exit)
        if smoke_exit not in (0, None):
            fail("pass_smoke_exit_invalid", smokeExitCode=smoke_exit)
        if suite_exit not in (0, None):
            fail("pass_product_scenario_suite_exit_invalid", suiteExitCode=suite_exit)
        if baseline_exit not in (0, None):
            fail("pass_baseline_exit_invalid", baselineExitCode=baseline_exit)
        if full_acceptance_exit not in (0, None):
            fail("pass_full_acceptance_exit_invalid", fullAcceptanceExitCode=full_acceptance_exit)
    elif reason == "smoke_failed":
        if not as_bool(requested.get("smoke")):
            fail("smoke_failed_but_not_requested")
        if smoke_exit in (None, 0):
            fail("smoke_failed_exit_missing", smokeExitCode=smoke_exit)
    elif reason == "baseline_failed":
        if not as_bool(requested.get("baseline")):
            fail("baseline_failed_but_not_requested")
        if smoke_exit != 0:
            fail("baseline_failed_smoke_not_passed", smokeExitCode=smoke_exit)
        if as_bool(requested.get("productScenarioSuite")) and suite_exit != 0:
            fail("baseline_failed_product_scenario_suite_not_passed", suiteExitCode=suite_exit)
        if baseline_exit in (None, 0):
            fail("baseline_failed_exit_missing", baselineExitCode=baseline_exit)
    elif reason == "product_scenario_suite_failed":
        if not as_bool(requested.get("productScenarioSuite")):
            fail("product_scenario_suite_failed_but_not_requested")
        if smoke_exit != 0:
            fail("product_scenario_suite_failed_smoke_not_passed", smokeExitCode=smoke_exit)
        if suite_exit in (None, 0):
            fail("product_scenario_suite_failed_exit_missing", suiteExitCode=suite_exit)
    elif reason == "full_acceptance_failed":
        if not as_bool(requested.get("fullAcceptance")):
            fail("full_acceptance_failed_but_not_requested")
        if smoke_exit != 0:
            fail("full_acceptance_failed_smoke_not_passed", smokeExitCode=smoke_exit)
        if as_bool(requested.get("productScenarioSuite")) and suite_exit != 0:
            fail("full_acceptance_failed_product_scenario_suite_not_passed", suiteExitCode=suite_exit)
        if baseline_exit != 0:
            fail("full_acceptance_failed_baseline_not_passed", baselineExitCode=baseline_exit)
        if full_acceptance_exit in (None, 0):
            fail("full_acceptance_failed_exit_missing", fullAcceptanceExitCode=full_acceptance_exit)
    elif reason == "requested_run_prereq_failed":
        if smoke_exit is not None or suite_exit is not None or baseline_exit is not None or full_acceptance_exit is not None:
            fail("prereq_failed_has_run_exit_codes")
        prereq_summary = artifact_path(
            receipt_path,
            (receipt.get("artifacts") or {}).get("prereqSummary"),
            "current-production-prereq-summary.txt",
            evidence_dir=evidence_dir,
        )
        require_file(
            prereq_summary,
            "prereq_summary_missing",
        )
        policy = receipt.get("evidencePolicy") or {}
        if as_bool(policy.get("requireCloudSecurityGroup")):
            try:
                summary_text = prereq_summary.read_text(encoding="utf-8", errors="replace")
            except Exception as exc:
                fail("prereq_summary_read_failed", path=prereq_summary, error=exc)
            if "requireCloudSecurityGroup=true" not in summary_text:
                fail("prereq_summary_cloud_security_group_policy_missing")
    elif status == "FAIL":
        fail("fail_reason_unknown", failureReason=reason or "-")


def verify(args: argparse.Namespace) -> None:
    receipt = read_json(args.readiness_json)
    evidence_dir = getattr(args, "evidence_dir", None)
    status = str(receipt.get("status") or "")
    if receipt.get("schemaVersion") != 1:
        fail("schema_version_invalid", schemaVersion=receipt.get("schemaVersion") or "-")
    require_readiness_timestamp(
        receipt,
        max_age_seconds=getattr(args, "max_age_seconds", 86400),
        max_future_skew_seconds=getattr(args, "max_future_skew_seconds", 300),
    )
    if status not in VALID_STATUSES:
        fail("status_invalid", status=status or "-")
    reason = str(receipt.get("reason") or "")
    if status == "FAIL" and reason not in VALID_FAIL_REASONS:
        fail("fail_reason_unknown", failureReason=reason or "-")
    require_target(receipt)
    require_expected_target(receipt, args)
    policy = require_evidence_policy(args.readiness_json, receipt, status, evidence_dir=evidence_dir)
    require_packageable_public_target(receipt, status, policy)
    verify_readiness_markdown(args.readiness_json, receipt, evidence_dir=evidence_dir)

    artifacts = receipt.get("artifacts") or {}
    dashboard_path = args.dashboard_json or artifact_file(
        args.readiness_json,
        artifacts.get("dashboard"),
        "current-production-dashboard.md",
        evidence_dir=evidence_dir,
        suffix=".json",
    )
    state_path = args.state_json or artifact_file(
        args.readiness_json,
        artifacts.get("stateSummary"),
        "current-production-state-summary.md",
        evidence_dir=evidence_dir,
        suffix=".json",
    )
    require_file(dashboard_path, "dashboard_json_missing")
    require_file(state_path, "state_json_missing")
    dashboard = read_json(dashboard_path)
    state = read_json(state_path)
    probe = require_probe_consistency(
        args.readiness_json,
        receipt,
        policy,
        status,
        args.probe_json,
        evidence_dir=evidence_dir,
    )
    require_next_command_consistency(dashboard, state)

    artifact_run_dir = str(artifacts.get("runDir") or "")
    if artifact_run_dir:
        run_dir = Path(artifact_run_dir).expanduser()
        if not run_dir.is_dir():
            if evidence_dir is None or not evidence_dir.is_dir():
                fail("run_dir_missing", runDir=artifact_run_dir)

    if status == "BLOCKED_ENTRYPOINT":
        verify_blocked(args.readiness_json, receipt, probe, dashboard, state, evidence_dir=evidence_dir)
    else:
        verify_unblocked(status, args.readiness_json, receipt, dashboard, state, evidence_dir=evidence_dir)


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")


def run_self_test() -> int:
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        readiness = root / "current-production-readiness.json"
        dashboard = root / "current-production-dashboard.json"
        state = root / "current-production-state-summary.json"
        state_csv = root / "current-production-state-summary.csv"
        probe = root / "entrypoint-probe.json"
        target = {
            "baseURL": "https://chat.myim-prod.com",
            "tcpHost": "tcp.myim-prod.com",
            "tcpPort": "9000",
        }
        receipt = {
            "schemaVersion": 1,
            "generatedAtEpoch": int(time.time()),
            "status": "PASS",
            "reason": "",
            "profile": "self-test",
            "target": target,
            "evidencePolicy": {
                "requirePackageableEvidence": False,
                "autoProductScenarioSuiteForPackageableAcceptance": False,
                "requireCloudSecurityGroup": False,
                "requirePublicPortPolicy": False,
                "allowTempHTTP8080": False,
                "cloudSecurityGroupRulesFile": "",
                "cloudSecurityGroupRulesMaxAgeSeconds": 0,
                "cloudSecurityGroupRulesRequireRootOwner": False,
                "requireCloudSecurityGroupRepairReceipt": False,
                "cloudSecurityGroupRepairReceiptJSON": "",
                "operatorNetworkPreflight": False,
            },
            "entrypoint": {
                "failed": False,
                "diagnosis": "ok",
                "probeJSON": probe.name,
            },
            "requestedRuns": {
                "smoke": False,
                "productScenarioSuite": False,
                "baseline": False,
                "fullAcceptance": False,
            },
            "runs": {},
            "artifacts": {
                "dashboard": str(root / "current-production-dashboard.md"),
                "stateSummary": str(root / "current-production-state-summary.md"),
            },
        }
        summary = {
            "entrypointRescueBlocked": False,
            "conclusion": "READY",
            "nextCommand": "",
            "productionEvidenceBlockerCount": 0,
            "productionEvidenceBlockers": [],
            "productionEvidenceActionCommands": [],
            "currentReadinessOperatorNetworkPreflight": False,
        }
        write_json(readiness, receipt)
        write_json(dashboard, {"summary": dict(summary)})
        write_json(state, {
            "summary": dict(summary),
            "productionEvidenceBlockers": [],
            "productionEvidenceActionCommands": [],
        })
        write_json(probe, {"failed": False, "diagnosis": "ok"})
        state_csv.write_text(
            "recordType,productionEvidenceBlockerCount,productionEvidenceBlockers,productionEvidenceActionCommands,currentReadinessOperatorNetworkPreflight\n"
            "summary,0,,,False\n",
            encoding="utf-8",
        )
        good_args = argparse.Namespace(
            readiness_json=readiness,
            dashboard_json=dashboard,
            state_json=state,
            probe_json=probe,
            evidence_dir=None,
            expect_base_url=target["baseURL"],
            expect_tcp_host=target["tcpHost"],
            expect_tcp_port=target["tcpPort"],
            max_age_seconds=86400,
            max_future_skew_seconds=300,
        )
        verify(good_args)
        bad_args = argparse.Namespace(**{**vars(good_args), "expect_tcp_port": "9443"})
        try:
            verify(bad_args)
        except SystemExit as exc:
            if "target_mismatch" not in str(exc):
                raise
        else:
            raise SystemExit("current_production_readiness_verify_self_test result=fail reason=target_mismatch_not_detected")
    print("current_production_readiness_verify_self_test result=pass")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify current production readiness receipt, probe, dashboard, and state summary artifacts.")
    parser.add_argument("--readiness-json", type=Path)
    parser.add_argument("--dashboard-json", type=Path)
    parser.add_argument("--state-json", type=Path)
    parser.add_argument("--probe-json", type=Path)
    parser.add_argument("--evidence-dir", type=Path)
    parser.add_argument("--expect-base-url")
    parser.add_argument("--expect-tcp-host")
    parser.add_argument("--expect-tcp-port")
    parser.add_argument("--max-age-seconds", type=int, default=86400)
    parser.add_argument("--max-future-skew-seconds", type=int, default=300)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        return run_self_test()
    if args.readiness_json is None:
        parser.error("--readiness-json is required unless --self-test is set")

    verify(args)
    print(f"current_production_readiness_artifacts result=pass readiness={args.readiness_json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
