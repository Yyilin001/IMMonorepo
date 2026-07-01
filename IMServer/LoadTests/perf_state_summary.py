#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import ipaddress
import json
import time
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from perf_entrypoint_rescue import entrypoint_rescue_failed, entrypoint_rescue_next_command
from perf_production_next_step import (
    attach_production_evidence_commands,
    build_current_production_readiness_command,
    build_production_acceptance_command,
    build_production_profile_command,
    failed_production_gate_scenarios,
    unique_production_evidence_action_commands,
)


def read_json(path: str | None) -> dict[str, Any]:
    if not path:
        return {}
    try:
        return json.loads(Path(path).read_text())
    except Exception:
        return {}


def read_kv(path: str | None) -> dict[str, str]:
    if not path:
        return {}
    try:
        rows = Path(path).read_text(encoding="utf-8", errors="replace").splitlines()
    except Exception:
        return {}
    values: dict[str, str] = {}
    for raw in rows:
        if not raw or raw.lstrip().startswith("#") or "=" not in raw:
            continue
        key, value = raw.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def artifact_path(receipt_path: Path, value: Any) -> Path | None:
    if not value:
        return None
    path = Path(str(value)).expanduser()
    if not path.is_absolute():
        path = receipt_path.parent / path
    return path


def as_bool(value: Any) -> bool:
    return value is True or str(value).lower() in {"1", "true", "yes", "on"}


def file_present(receipt_path: Path, value: Any) -> bool:
    path = artifact_path(receipt_path, value)
    return bool(path and path.is_file())


def current_readiness_freshness(
    receipt: dict[str, Any],
    max_age_seconds: int,
    future_skew_seconds: int,
) -> dict[str, Any]:
    generated_at = receipt.get("generatedAt")
    try:
        generated_at_epoch = int(receipt.get("generatedAtEpoch"))
    except Exception:
        return {
            "currentReadinessGeneratedAt": generated_at,
            "currentReadinessGeneratedAtEpoch": receipt.get("generatedAtEpoch"),
            "currentReadinessAgeSeconds": None,
            "currentReadinessMaxAgeSeconds": max_age_seconds,
            "currentReadinessFreshnessStatus": "FAIL",
            "currentReadinessFreshnessReason": "generated_at_invalid",
        }
    now = int(time.time())
    age_seconds = now - generated_at_epoch
    if generated_at_epoch <= 0:
        status = "FAIL"
        reason = "generated_at_invalid"
    elif age_seconds < -future_skew_seconds:
        status = "FAIL"
        reason = "generated_at_in_future"
    elif max_age_seconds > 0 and age_seconds > max_age_seconds:
        status = "FAIL"
        reason = "stale"
    else:
        status = "PASS"
        reason = "fresh"
    return {
        "currentReadinessGeneratedAt": generated_at,
        "currentReadinessGeneratedAtEpoch": generated_at_epoch,
        "currentReadinessAgeSeconds": age_seconds,
        "currentReadinessMaxAgeSeconds": max_age_seconds,
        "currentReadinessFreshnessStatus": status,
        "currentReadinessFreshnessReason": reason,
    }


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
    payload = read_json(str(path))
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


def is_real_dns_host(host: str) -> bool:
    value = host.strip().lower().strip("[]")
    if not value or value in {"localhost", "127.0.0.1", "::1", "0.0.0.0"}:
        return False
    try:
        ipaddress.ip_address(value)
        return False
    except ValueError:
        pass
    if "." not in value:
        return False
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
    return value not in placeholder_hosts and not any(value.endswith(suffix) for suffix in placeholder_suffixes)


def https_dns_ok(base_url: str) -> bool:
    parsed = urlparse(base_url)
    return parsed.scheme == "https" and is_real_dns_host(parsed.hostname or "")


def current_readiness_summary(
    path: str | None,
    max_age_seconds: int = 86400,
    future_skew_seconds: int = 300,
) -> dict[str, Any]:
    if not path:
        return {}
    receipt_path = Path(path).expanduser()
    receipt = read_json(str(receipt_path))
    if not receipt:
        return {}
    requested = receipt.get("requestedRuns") or {}
    runs = receipt.get("runs") or {}
    artifacts = receipt.get("artifacts") or {}
    target = receipt.get("target") or {}
    policy = receipt.get("evidencePolicy") or {}
    entrypoint = receipt.get("entrypoint") or {}
    operator_log_path = artifact_path(receipt_path, artifacts.get("operatorNetworkLog"))
    operator_json_path = artifact_path(receipt_path, artifacts.get("operatorNetworkJSON"))
    operator_network = operator_network_evidence_summary(operator_log_path, operator_json_path)
    operator_log_present = bool(operator_log_path and operator_log_path.is_file())
    operator_json_present = bool(operator_json_path and operator_json_path.is_file())
    suite_run: dict[str, Any] = {}
    suite_run_path = artifact_path(receipt_path, artifacts.get("productScenarioSuiteRunJSON"))
    if suite_run_path is not None:
        suite_run = read_json(str(suite_run_path))
    full_run: dict[str, Any] = {}
    full_run_path = artifact_path(receipt_path, artifacts.get("fullAcceptanceRunJSON"))
    if full_run_path is not None:
        full_run = read_json(str(full_run_path))
    suite_coverage = suite_run.get("coverageSummary") or {}

    return {
        **current_readiness_freshness(
            receipt,
            max_age_seconds=max_age_seconds,
            future_skew_seconds=future_skew_seconds,
        ),
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
        "currentReadinessProductScenarioSuite": suite_run.get("suite"),
        "currentReadinessProductScenarioSuiteStatus": suite_run.get("status"),
        "currentReadinessProductScenarioSuiteStageCount": suite_run.get("stageCount"),
        "currentReadinessProductScenarioSuiteFailedStages": suite_run.get("failedStageCount"),
        "currentReadinessProductScenarioSuitePlannedStages": suite_run.get("plannedStageCount"),
        "currentReadinessProductScenarioSuiteScenarios": suite_coverage.get("uniqueScenarioCount"),
        "currentReadinessProductScenarioSuiteProductPlanStages": suite_coverage.get("productPlanStageCount"),
        "currentReadinessProductScenarioSuiteLargeGroupIncluded": suite_coverage.get("largeGroupIncluded"),
        "currentReadinessFullAcceptanceExpectedCampaign": requested.get("fullAcceptanceCampaign"),
        "currentReadinessFullAcceptanceCampaign": full_run.get("campaign"),
        "currentReadinessFullAcceptanceStatus": full_run.get("finalStatus"),
        "currentReadinessFullAcceptanceFailures": full_run.get("failureCount"),
        "currentReadinessFullAcceptanceRequiredFailures": full_run.get("requiredFailureCount"),
        "currentReadinessFullAcceptanceAttempted": full_run.get("attemptedStageCount"),
        "currentReadinessFullAcceptanceSkipped": full_run.get("skippedStageCount"),
        "currentReadinessBaseURL": target.get("baseURL"),
        "currentReadinessTCPHost": target.get("tcpHost"),
        "currentReadinessTCPPort": target.get("tcpPort"),
        "currentReadinessRequirePackageableEvidence": policy.get("requirePackageableEvidence"),
        "currentReadinessRequireCloudSecurityGroup": policy.get("requireCloudSecurityGroup"),
        "currentReadinessRequirePublicPortPolicy": policy.get("requirePublicPortPolicy"),
        "currentReadinessOperatorNetworkPreflight": policy.get("operatorNetworkPreflight"),
        "currentReadinessOperatorNetworkLog": artifacts.get("operatorNetworkLog"),
        "currentReadinessOperatorNetworkJSON": artifacts.get("operatorNetworkJSON"),
        "currentReadinessOperatorNetworkLogPresent": operator_log_present,
        "currentReadinessOperatorNetworkJSONPresent": operator_json_present,
        "currentReadinessOperatorNetworkEvidencePresent": operator_network.get("present"),
        "currentReadinessOperatorNetworkFailed": operator_network.get("failed"),
        "currentReadinessOperatorNetworkWarnings": operator_network.get("warnings"),
        "currentReadinessOperatorNetworkRouteInterfaces": operator_network.get("routeInterfaces"),
        "currentReadinessOperatorNetworkRouteGateways": operator_network.get("routeGateways"),
        "currentReadinessOperatorNetworkFailureCount": operator_network.get("failureCount"),
        "currentReadinessCloudSecurityGroupRulesFile": policy.get("cloudSecurityGroupRulesFile"),
        "currentReadinessCloudSecurityGroupRulesFilePresent": file_present(receipt_path, policy.get("cloudSecurityGroupRulesFile")),
        "currentReadinessCloudSecurityGroupArtifactPresent": file_present(receipt_path, artifacts.get("cloudSecurityGroupRulesFile")),
        "currentReadinessCloudSecurityGroupAuditLogPresent": file_present(receipt_path, artifacts.get("cloudSecurityGroupAuditLog")),
        "currentReadinessRequireCloudSecurityGroupRepairReceipt": policy.get("requireCloudSecurityGroupRepairReceipt"),
        "currentReadinessCloudSecurityGroupRepairReceiptJSON": policy.get("cloudSecurityGroupRepairReceiptJSON"),
        "currentReadinessCloudSecurityGroupRepairReceiptExpectSecurityGroupID": policy.get("cloudSecurityGroupRepairReceiptExpectSecurityGroupID"),
        "currentReadinessCloudSecurityGroupRepairReceiptExpectRegionID": policy.get("cloudSecurityGroupRepairReceiptExpectRegionID"),
        "currentReadinessCloudSecurityGroupRepairReceiptExpectAdminCIDR": policy.get("cloudSecurityGroupRepairReceiptExpectAdminCIDR"),
        "currentReadinessCloudSecurityGroupRepairReceiptPresent": file_present(receipt_path, policy.get("cloudSecurityGroupRepairReceiptJSON")),
        "currentReadinessCloudSecurityGroupRepairReceiptArtifactPresent": file_present(receipt_path, artifacts.get("cloudSecurityGroupRepairReceiptJSON")),
        "currentReadinessCloudSecurityGroupRepairReceiptVerifyLogPresent": file_present(receipt_path, artifacts.get("cloudSecurityGroupRepairReceiptVerifyLog")),
        "currentReadinessEntrypointFailed": entrypoint.get("failed"),
        "currentReadinessEntrypointDiagnosis": entrypoint.get("diagnosis"),
        "currentReadinessEntrypointDetail": entrypoint.get("detail"),
    }


def production_acceptance_summary(path: str | None) -> dict[str, Any]:
    if not path:
        return {}
    receipt_path = Path(path).expanduser()
    receipt = read_json(str(receipt_path))
    if not receipt:
        return {}
    target = receipt.get("target") or {}
    policy = receipt.get("policy") or {}
    artifacts = receipt.get("artifacts") or {}
    repair_receipt = policy.get("cloudSecurityGroupRepairReceiptJSON")
    package_present = artifacts.get("packagePresent")
    try:
        package_bytes = int(artifacts.get("packageBytes") or 0)
    except Exception:
        package_bytes = 0
    return {
        "productionAcceptanceStatus": str(receipt.get("status") or ""),
        "productionAcceptanceReason": str(receipt.get("reason") or ""),
        "productionAcceptanceLevel": str(receipt.get("level") or ""),
        "productionAcceptanceBaseURL": target.get("baseURL"),
        "productionAcceptanceTCPHost": target.get("tcpHost"),
        "productionAcceptanceTCPPort": target.get("tcpPort"),
        "productionAcceptanceRequiredAccountRows": target.get("requiredAccountRows"),
        "productionAcceptanceRequirePackageableEvidence": policy.get("requirePackageableEvidence"),
        "productionAcceptanceRequireCloudSecurityGroup": policy.get("requireCloudSecurityGroup"),
        "productionAcceptanceRequireCloudSecurityGroupRepairReceipt": policy.get("requireCloudSecurityGroupRepairReceipt"),
        "productionAcceptanceRequirePublicPortPolicy": policy.get("requirePublicPortPolicy"),
        "productionAcceptanceOperatorNetworkPreflight": policy.get("operatorNetworkPreflight"),
        "productionAcceptanceCloudSecurityGroupRulesFile": policy.get("cloudSecurityGroupRulesFile"),
        "productionAcceptanceCloudSecurityGroupRulesFilePresent": file_present(receipt_path, policy.get("cloudSecurityGroupRulesFile")),
        "productionAcceptanceCloudSecurityGroupRepairReceiptJSON": repair_receipt,
        "productionAcceptanceCloudSecurityGroupRepairReceiptExpectSecurityGroupID": policy.get("cloudSecurityGroupRepairReceiptExpectSecurityGroupID"),
        "productionAcceptanceCloudSecurityGroupRepairReceiptExpectRegionID": policy.get("cloudSecurityGroupRepairReceiptExpectRegionID"),
        "productionAcceptanceCloudSecurityGroupRepairReceiptExpectAdminCIDR": policy.get("cloudSecurityGroupRepairReceiptExpectAdminCIDR"),
        "productionAcceptanceCloudSecurityGroupRepairReceiptPresent": file_present(receipt_path, repair_receipt),
        "productionAcceptancePackagePresent": package_present,
        "productionAcceptancePackageBytes": package_bytes,
    }


def production_evidence_blockers(
    production_gate_status: str,
    production_gate_summary: dict[str, Any],
    current_readiness: dict[str, Any],
    production_acceptance: dict[str, Any],
    *,
    production_acceptance_requested: bool,
) -> list[dict[str, str]]:
    blockers: list[dict[str, str]] = []

    def add(code: str, source: str, reason: str, action: str, severity: str = "P0") -> None:
        if any(row.get("code") == code for row in blockers):
            return
        blockers.append({
            "code": code,
            "severity": severity,
            "source": source,
            "reason": reason,
            "action": action,
        })

    failure_kinds = production_gate_summary.get("failureKindCounts") or {}
    if production_gate_status == "FAIL":
        if int(failure_kinds.get("target_filter_invalid") or 0) > 0:
            add(
                "production_gate_target_filter_invalid",
                "production-gate",
                "production gate evidence target is not an enabled public HTTPS/DNS target filter",
                "rerun SLO status and production gate with PERF_STATUS_FILTER_TARGET=true on the public production HTTPS/TCP endpoints",
            )
        if int(failure_kinds.get("missing_runtime_evidence") or 0) > 0 or int(failure_kinds.get("missing_scenario") or 0) > 0:
            add(
                "production_gate_runtime_evidence_missing",
                "production-gate",
                "required production scenarios have no real runtime evidence",
                "run the selected production profile on the public target and package the evidence",
            )
        if int(failure_kinds.get("slo_not_pass") or 0) > 0:
            add(
                "production_gate_slo_not_pass",
                "production-gate",
                "required production scenarios have failing SLO results",
                "optimize the failing scenario domain, then rerun the production profile",
            )
        if int(failure_kinds.get("artifact_missing") or 0) > 0:
            add(
                "production_gate_artifact_missing",
                "production-gate",
                "passing production scenarios are missing required run artifacts",
                "rerun with artifact collection enabled or repair the evidence package",
            )
        if int(failure_kinds.get("evidence_stale") or 0) > 0:
            add(
                "production_gate_fresh_evidence_missing",
                "production-gate",
                "production evidence is older than the configured freshness window",
                "rerun the production profile before deployment acceptance",
            )
        if int(failure_kinds.get("evidence_time_in_future") or 0) > 0:
            add(
                "production_gate_clock_skew",
                "production-gate",
                "production evidence timestamps are in the future",
                "fix host clock skew and regenerate evidence",
            )
        if int(failure_kinds.get("missing_evidence_time") or 0) > 0:
            add(
                "production_gate_evidence_timestamp_missing",
                "production-gate",
                "production evidence lacks timestamp data while freshness is required",
                "rerun with timestamped run artifacts",
            )

    readiness_status = str(current_readiness.get("currentReadinessStatus") or "")
    if current_readiness:
        base_url = str(current_readiness.get("currentReadinessBaseURL") or "")
        tcp_host = str(current_readiness.get("currentReadinessTCPHost") or "")
        if base_url and not https_dns_ok(base_url):
            add(
                "public_https_dns_missing",
                "current-production-readiness",
                "public base URL is not an HTTPS DNS hostname",
                "configure DNS and HTTPS, then rerun current production readiness",
            )
        if tcp_host and not is_real_dns_host(tcp_host):
            add(
                "public_tcp_dns_missing",
                "current-production-readiness",
                "public TCP host is not a DNS hostname",
                "configure TCP DNS, then rerun current production readiness",
            )
        if as_bool(current_readiness.get("currentReadinessEntrypointFailed")):
            add(
                "public_entrypoint_blocked",
                "current-production-readiness",
                str(current_readiness.get("currentReadinessEntrypointDiagnosis") or "entrypoint probe failed"),
                "repair the public entrypoint and rerun current production readiness",
            )
        if readiness_status and readiness_status != "PASS":
            add(
                "current_production_readiness_not_pass",
                "current-production-readiness",
                str(current_readiness.get("currentReadinessReason") or readiness_status),
                "fix the readiness failure and rerun current production readiness",
            )
        if current_readiness.get("currentReadinessOperatorNetworkPreflight") is not True:
            add(
                "operator_network_preflight_policy_missing",
                "current-production-readiness",
                "current production readiness did not require an operator network preflight",
                "rerun readiness with CURRENT_PRODUCTION_OPERATOR_NETWORK_PREFLIGHT=true and CURRENT_PRODUCTION_FAIL_ON_OPERATOR_NETWORK=true",
            )
        else:
            if current_readiness.get("currentReadinessOperatorNetworkLogPresent") is not True:
                add(
                    "operator_network_log_missing",
                    "current-production-readiness",
                    "operator network preflight is required but the log artifact is missing",
                    "rerun current production readiness and keep operator-network.log",
                )
            if current_readiness.get("currentReadinessOperatorNetworkFailed") is True:
                add(
                    "operator_network_failed",
                    "current-production-readiness",
                    "operator workstation route/proxy preflight failed",
                    "disconnect local TUN/proxy or use a clean network, then rerun current production readiness",
                )
            warnings = [str(item) for item in current_readiness.get("currentReadinessOperatorNetworkWarnings") or [] if str(item)]
            if warnings:
                add(
                    "operator_network_warning",
                    "current-production-readiness",
                    f"operator network preflight reported warning={warnings[0]}",
                    "disconnect local TUN/proxy or use a clean network, then rerun current production readiness",
                )
        if as_bool(current_readiness.get("currentReadinessRequireCloudSecurityGroup")):
            if not as_bool(current_readiness.get("currentReadinessRequireCloudSecurityGroupRepairReceipt")):
                add(
                    "cloud_security_group_repair_receipt_policy_missing",
                    "current-production-readiness",
                    "cloud security group policy is required but repair receipt policy is not enabled",
                    "rerun readiness with CURRENT_PRODUCTION_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT=true",
                )
            rules_present = (
                current_readiness.get("currentReadinessCloudSecurityGroupRulesFilePresent") is True
                or current_readiness.get("currentReadinessCloudSecurityGroupArtifactPresent") is True
            )
            if not rules_present:
                add(
                    "cloud_security_group_snapshot_missing",
                    "current-production-readiness",
                    "cloud security group policy is required but no audited snapshot artifact is present",
                    "fetch/audit the cloud security group snapshot and rerun readiness",
                )
            if current_readiness.get("currentReadinessCloudSecurityGroupAuditLogPresent") is not True:
                add(
                    "cloud_security_group_audit_log_missing",
                    "current-production-readiness",
                    "cloud security group policy is required but audit log artifact is missing",
                    "rerun readiness with cloud security group audit enabled",
                )
            repair_receipt_present = (
                current_readiness.get("currentReadinessCloudSecurityGroupRepairReceiptPresent") is True
                or current_readiness.get("currentReadinessCloudSecurityGroupRepairReceiptArtifactPresent") is True
            )
            if not repair_receipt_present:
                add(
                    "cloud_security_group_repair_receipt_missing",
                    "current-production-readiness",
                    "cloud security group repair receipt is required but no verified receipt artifact is present",
                    "apply/verify the cloud security group repair and rerun current production readiness",
                )
            if not str(current_readiness.get("currentReadinessCloudSecurityGroupRepairReceiptExpectSecurityGroupID") or ""):
                add(
                    "cloud_security_group_repair_receipt_expected_security_group_id_missing",
                    "current-production-readiness",
                    "cloud security group repair receipt expected security group ID is missing",
                    "rerun readiness with CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID",
                )
            if not str(current_readiness.get("currentReadinessCloudSecurityGroupRepairReceiptExpectRegionID") or ""):
                add(
                    "cloud_security_group_repair_receipt_expected_region_id_missing",
                    "current-production-readiness",
                    "cloud security group repair receipt expected region is missing",
                    "rerun readiness with CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID",
                )
            if not str(current_readiness.get("currentReadinessCloudSecurityGroupRepairReceiptExpectAdminCIDR") or ""):
                add(
                    "cloud_security_group_repair_receipt_expected_admin_cidr_missing",
                    "current-production-readiness",
                    "cloud security group repair receipt expected admin CIDR is missing",
                    "rerun readiness with CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR",
                )
            if current_readiness.get("currentReadinessCloudSecurityGroupRepairReceiptVerifyLogPresent") is not True:
                add(
                    "cloud_security_group_repair_receipt_verify_log_missing",
                    "current-production-readiness",
                    "cloud security group repair receipt is required but verifier log is missing",
                    "rerun current production readiness with repair receipt verification enabled",
                )
    elif production_gate_status == "FAIL":
        add(
            "current_production_readiness_missing",
            "current-production-readiness",
            "no current production readiness receipt was supplied",
            "run run_current_production_readiness.sh on the public target",
        )

    if production_acceptance_requested:
        acceptance_status = str(production_acceptance.get("productionAcceptanceStatus") or "")
        if not production_acceptance:
            add(
                "production_acceptance_receipt_missing",
                "production-acceptance",
                "no production acceptance receipt was supplied",
                "run run_production_acceptance.sh and keep production-acceptance.json with its package",
            )
        else:
            base_url = str(production_acceptance.get("productionAcceptanceBaseURL") or "")
            tcp_host = str(production_acceptance.get("productionAcceptanceTCPHost") or "")
            if base_url and not https_dns_ok(base_url):
                add(
                    "production_acceptance_https_dns_missing",
                    "production-acceptance",
                    "production acceptance target base URL is not an HTTPS DNS hostname",
                    "rerun production acceptance against the real HTTPS DNS endpoint",
                )
            if tcp_host and not is_real_dns_host(tcp_host):
                add(
                    "production_acceptance_tcp_dns_missing",
                    "production-acceptance",
                    "production acceptance TCP host is not a DNS hostname",
                    "rerun production acceptance against the real TCP DNS endpoint",
                )
            if acceptance_status != "PASS":
                add(
                    "production_acceptance_not_pass",
                    "production-acceptance",
                    str(production_acceptance.get("productionAcceptanceReason") or acceptance_status or "missing status"),
                    "fix acceptance failures and rerun run_production_acceptance.sh",
                )
            if production_acceptance.get("productionAcceptancePackagePresent") is not True or int(production_acceptance.get("productionAcceptancePackageBytes") or 0) <= 0:
                add(
                    "production_acceptance_package_missing",
                    "production-acceptance",
                    "production acceptance package artifact is missing or empty",
                    "rerun production acceptance packaging and verify the package",
                )
            if production_acceptance.get("productionAcceptanceOperatorNetworkPreflight") is not True:
                add(
                    "operator_network_preflight_policy_missing",
                    "production-acceptance",
                    "production acceptance did not require operator network preflight",
                    "rerun production acceptance with operator network preflight enabled",
                )
            if production_acceptance.get("productionAcceptanceRequireCloudSecurityGroupRepairReceipt") is not True:
                add(
                    "cloud_security_group_repair_receipt_policy_missing",
                    "production-acceptance",
                    "production acceptance does not require a cloud security group repair receipt",
                    "rerun production acceptance with repair receipt policy enabled",
                )
            if production_acceptance.get("productionAcceptanceCloudSecurityGroupRepairReceiptPresent") is not True:
                add(
                    "cloud_security_group_repair_receipt_missing",
                    "production-acceptance",
                    "cloud security group repair receipt artifact is missing",
                    "apply/verify the cloud security group repair and rerun production acceptance",
                )
            if not str(production_acceptance.get("productionAcceptanceCloudSecurityGroupRepairReceiptExpectSecurityGroupID") or ""):
                add(
                    "cloud_security_group_repair_receipt_expected_security_group_id_missing",
                    "production-acceptance",
                    "production acceptance repair receipt expected security group ID is missing",
                    "rerun production acceptance with expected security group ID",
                )
            if not str(production_acceptance.get("productionAcceptanceCloudSecurityGroupRepairReceiptExpectRegionID") or ""):
                add(
                    "cloud_security_group_repair_receipt_expected_region_id_missing",
                    "production-acceptance",
                    "production acceptance repair receipt expected region is missing",
                    "rerun production acceptance with expected region",
                )
            if not str(production_acceptance.get("productionAcceptanceCloudSecurityGroupRepairReceiptExpectAdminCIDR") or ""):
                add(
                    "cloud_security_group_repair_receipt_expected_admin_cidr_missing",
                    "production-acceptance",
                    "production acceptance repair receipt expected admin CIDR is missing",
                    "rerun production acceptance with expected admin CIDR",
                )
    return blockers


def count_status(rows: list[dict[str, Any]], field: str) -> dict[str, int]:
    counts: dict[str, int] = {}
    for row in rows:
        value = str(row.get(field) or "UNKNOWN")
        counts[value] = counts.get(value, 0) + 1
    return counts


def table(rows: list[list[str]]) -> str:
    if not rows:
        return ""
    lines = [
        "| " + " | ".join(rows[0]) + " |",
        "| " + " | ".join(["---"] * len(rows[0])) + " |",
    ]
    for row in rows[1:]:
        lines.append("| " + " | ".join(cell.replace("\n", " ") for cell in row) + " |")
    return "\n".join(lines)


def top_actions(actions: list[dict[str, Any]], limit: int) -> list[dict[str, Any]]:
    rank = {"P0": 0, "P1": 1, "P2": 2, "P3": 3, "P4": 4}
    return sorted(
        actions,
        key=lambda item: (
            rank.get(str(item.get("priority") or ""), 9),
            str(item.get("category") or ""),
            str(item.get("scenario") or ""),
        ),
    )[:limit]


def domain_catalog(catalog: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {
        str(row.get("domain") or ""): row
        for row in catalog.get("domains") or []
        if row.get("domain")
    }


def slo_domain_rows(slo_domain: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {
        str(row.get("domain") or ""): row
        for row in slo_domain.get("domains") or []
        if row.get("domain")
    }


def build_summary(args: argparse.Namespace) -> dict[str, Any]:
    scenario_status = read_json(args.scenario_status_json)
    slo_status = read_json(args.slo_status_json)
    slo_domain = read_json(args.slo_domain_scorecard_json)
    readiness = read_json(args.readiness_gate_json)
    next_actions = read_json(args.next_actions_json)
    catalog = read_json(args.scenario_catalog_json)
    dashboard = read_json(args.dashboard_json)
    run_plan = read_json(args.run_plan_json)
    production_gate = read_json(args.production_gate_json)
    entrypoint_rescue = read_kv(args.entrypoint_rescue_summary)
    current_readiness = current_readiness_summary(
        args.current_readiness_json,
        max_age_seconds=int(args.current_readiness_max_age_seconds),
        future_skew_seconds=int(args.current_readiness_future_skew_seconds),
    )
    production_acceptance = production_acceptance_summary(args.production_acceptance_json)

    scenarios = scenario_status.get("scenarios") or []
    matrix_scenarios = [
        row for row in scenarios
        if str(row.get("category") or "") != "preflight"
    ]
    status_counts = count_status(matrix_scenarios, "latestStatus")
    matrix_count = int((catalog.get("summary") or {}).get("scenarioCount") or len(matrix_scenarios))
    ran_count = sum(1 for row in matrix_scenarios if int(row.get("runCount") or 0) > 0)
    parseable_count = sum(1 for row in matrix_scenarios if str(row.get("latestStatus") or "") in {"PASS", "FAIL"})
    unknown_count = int(status_counts.get("UNKNOWN") or 0)
    never_run_count = int(status_counts.get("NEVER_RUN") or 0)
    pass_count = int(status_counts.get("PASS") or 0)
    fail_count = int(status_counts.get("FAIL") or 0)

    actions = next_actions.get("actions") or []
    p0_actions = [row for row in actions if str(row.get("priority") or "") == "P0"]
    prerequisite_actions = [row for row in p0_actions if str(row.get("actionType") or "") == "prerequisite-blocker"]
    entrypoint_actions = [
        row for row in p0_actions
        if str(row.get("actionType") or "") == "entrypoint-blocker"
        or "entrypoint" in str(row.get("action") or "").lower()
    ]
    p1_actions = [row for row in actions if str(row.get("priority") or "") == "P1"]
    extra_slo_counts = slo_status.get("extraSLOStatusCounts") or {}
    slo_counts = slo_status.get("latestSLOStatusCounts") or {}
    slo_domain_summary = slo_domain.get("summary") or {}
    dashboard_summary = dashboard.get("summary") or {}
    production_gate_summary = production_gate.get("summary") or {}
    production_gate_requirements = production_gate.get("requirements") or {}
    production_gate_status = str(production_gate.get("status") or dashboard_summary.get("productionGate") or "")
    production_gate_failed_scenarios = failed_production_gate_scenarios(production_gate)
    current_readiness_command = build_current_production_readiness_command(args, run_plan)
    production_profile_command = build_production_profile_command(args, production_gate, run_plan)
    production_acceptance_command = build_production_acceptance_command(args, production_gate, run_plan)
    production_acceptance_requested = bool(args.production_acceptance_json) or production_gate_status == "FAIL"
    production_blockers = production_evidence_blockers(
        production_gate_status,
        production_gate_summary,
        current_readiness,
        production_acceptance,
        production_acceptance_requested=production_acceptance_requested,
    )
    production_blockers = attach_production_evidence_commands(
        production_blockers,
        current_readiness_command=current_readiness_command,
        production_profile_command=production_profile_command,
        production_acceptance_command=production_acceptance_command,
    )
    production_action_commands = unique_production_evidence_action_commands(production_blockers)

    entrypoint_rescue_blocked = entrypoint_rescue_failed(entrypoint_rescue)
    entrypoint_rescue_command = entrypoint_rescue_next_command(args.entrypoint_rescue_summary, entrypoint_rescue)

    if entrypoint_rescue_blocked:
        conclusion = "BLOCKED_ENTRYPOINT"
        diagnosis = entrypoint_rescue.get("entrypointDiagnosis") or "unknown"
        action = entrypoint_rescue.get("rescuePlanAction") or "repair_entrypoint"
        recommendation = f"Repair the public entrypoint first: diagnosis={diagnosis} action={action}."
    elif prerequisite_actions:
        conclusion = "BLOCKED_PREREQUISITES"
        recommendation = "Fix ACCOUNT_FILE size/path, IM_CONVERSATION_ID, or selected scenario inputs before treating any scenario result as performance evidence."
    elif entrypoint_actions or int(extra_slo_counts.get("FAIL") or 0) > 0:
        conclusion = "BLOCKED_ENTRYPOINT"
        recommendation = "Fix the HTTP entrypoint/preflight failure before treating any scenario result as performance evidence."
    elif p0_actions:
        conclusion = "BLOCKED_PRECHECK"
        recommendation = "Fix the P0 precheck blocker before treating any scenario result as performance evidence."
    elif production_gate_status == "FAIL":
        conclusion = "NEEDS_PRODUCTION_EVIDENCE"
        recommendation = "Run or fix the required production-gate scenarios until the selected profile has latest real SLO PASS evidence."
    elif fail_count > 0 or int(slo_counts.get("FAIL") or 0) > 0 or p1_actions:
        conclusion = "NEEDS_OPTIMIZATION"
        recommendation = "Optimize the failing P1/SLO scenarios, then rerun the matching domain batch."
    elif unknown_count > 0:
        conclusion = "NEEDS_RUNTIME_EVIDENCE"
        recommendation = "Rerun UNKNOWN scenarios without PERF_DRY_RUN and verify k6 summaries or TCP JSONL artifacts."
    elif never_run_count > 0:
        conclusion = "NEEDS_MORE_SCENARIOS"
        recommendation = "Run the remaining smoke scenarios first, then baseline/capacity by domain."
    else:
        conclusion = "READY"
        recommendation = "All matrix scenarios have parseable runtime evidence and no current failures."

    domains: list[dict[str, Any]] = []
    catalog_by_domain = domain_catalog(catalog)
    slo_by_domain = slo_domain_rows(slo_domain)
    for domain in sorted(set(catalog_by_domain) | set(slo_by_domain)):
        catalog_row = catalog_by_domain.get(domain, {})
        slo_row = slo_by_domain.get(domain, {})
        domains.append({
            "domain": domain,
            "scenarioCount": int(catalog_row.get("scenarioCount") or slo_row.get("scenarioCount") or 0),
            "familyCount": int(catalog_row.get("familyCount") or slo_row.get("familyCount") or 0),
            "latestPass": int(catalog_row.get("pass") or 0),
            "latestFail": int(catalog_row.get("fail") or 0),
            "latestUnknown": int(catalog_row.get("unknown") or 0),
            "latestNeverRun": int(catalog_row.get("neverRun") or 0),
            "sloReadiness": str(slo_row.get("readiness") or ""),
            "sloPass": int(slo_row.get("pass") or 0),
            "sloFail": int(slo_row.get("fail") or 0),
            "sloUnknown": int(slo_row.get("unknown") or 0),
            "sloNeverRun": int(slo_row.get("neverRun") or 0),
            "nextAction": str(slo_row.get("nextAction") or slo_row.get("reason") or ""),
        })
    domains.sort(key=lambda item: (
        {
            "NEEDS_SLO_OPTIMIZATION": 0,
            "NEEDS_RUNTIME_EVIDENCE": 1,
            "NEEDS_RUN": 2,
            "READY": 3,
        }.get(str(item.get("sloReadiness") or ""), 9),
        -int(item.get("scenarioCount") or 0),
        str(item.get("domain") or ""),
    ))

    if conclusion == "BLOCKED_ENTRYPOINT" and entrypoint_rescue_command:
        next_command = entrypoint_rescue_command
    elif conclusion == "NEEDS_PRODUCTION_EVIDENCE" and production_profile_command:
        next_command = production_profile_command
    else:
        next_command = (
            str(run_plan.get("probeCommand") or "")
            or str((dashboard.get("nextCommand") or ""))
            or str(run_plan.get("runCommand") or "")
        )

    return {
        "summary": {
            "conclusion": conclusion,
            "recommendation": recommendation,
            "matrixScenarioCount": matrix_count,
            "ranScenarioCount": ran_count,
            "parseableScenarioCount": parseable_count,
            "pass": pass_count,
            "fail": fail_count,
            "unknown": unknown_count,
            "neverRun": never_run_count,
            "coveragePercentByRun": round((ran_count / matrix_count) * 100, 2) if matrix_count else 0,
            "coveragePercentByParseableEvidence": round((parseable_count / matrix_count) * 100, 2) if matrix_count else 0,
            "readinessGate": readiness.get("status") or dashboard_summary.get("readinessGate") or "UNKNOWN",
            "readinessFailures": readiness.get("failureCount"),
            "currentReadinessGeneratedAt": current_readiness.get("currentReadinessGeneratedAt", dashboard_summary.get("currentReadinessGeneratedAt")),
            "currentReadinessGeneratedAtEpoch": current_readiness.get("currentReadinessGeneratedAtEpoch", dashboard_summary.get("currentReadinessGeneratedAtEpoch")),
            "currentReadinessAgeSeconds": current_readiness.get("currentReadinessAgeSeconds", dashboard_summary.get("currentReadinessAgeSeconds")),
            "currentReadinessMaxAgeSeconds": current_readiness.get("currentReadinessMaxAgeSeconds", dashboard_summary.get("currentReadinessMaxAgeSeconds")),
            "currentReadinessFreshnessStatus": current_readiness.get("currentReadinessFreshnessStatus", dashboard_summary.get("currentReadinessFreshnessStatus")),
            "currentReadinessFreshnessReason": current_readiness.get("currentReadinessFreshnessReason", dashboard_summary.get("currentReadinessFreshnessReason")),
            "currentReadinessStatus": current_readiness.get("currentReadinessStatus") or dashboard_summary.get("currentReadinessStatus"),
            "currentReadinessReason": current_readiness.get("currentReadinessReason") or dashboard_summary.get("currentReadinessReason"),
            "currentReadinessRequestedSmoke": current_readiness.get("currentReadinessRequestedSmoke", dashboard_summary.get("currentReadinessRequestedSmoke")),
            "currentReadinessRequestedProductScenarioSuite": current_readiness.get("currentReadinessRequestedProductScenarioSuite", dashboard_summary.get("currentReadinessRequestedProductScenarioSuite")),
            "currentReadinessRequestedBaseline": current_readiness.get("currentReadinessRequestedBaseline", dashboard_summary.get("currentReadinessRequestedBaseline")),
            "currentReadinessRequestedFullAcceptance": current_readiness.get("currentReadinessRequestedFullAcceptance", dashboard_summary.get("currentReadinessRequestedFullAcceptance")),
            "currentReadinessSmokeExitCode": current_readiness.get("currentReadinessSmokeExitCode", dashboard_summary.get("currentReadinessSmokeExitCode")),
            "currentReadinessProductScenarioSuiteExitCode": current_readiness.get("currentReadinessProductScenarioSuiteExitCode", dashboard_summary.get("currentReadinessProductScenarioSuiteExitCode")),
            "currentReadinessBaselineExitCode": current_readiness.get("currentReadinessBaselineExitCode", dashboard_summary.get("currentReadinessBaselineExitCode")),
            "currentReadinessFullAcceptanceExitCode": current_readiness.get("currentReadinessFullAcceptanceExitCode", dashboard_summary.get("currentReadinessFullAcceptanceExitCode")),
            "currentReadinessProductScenarioSuiteExpected": current_readiness.get("currentReadinessProductScenarioSuiteExpected") or dashboard_summary.get("currentReadinessProductScenarioSuiteExpected"),
            "currentReadinessProductScenarioSuite": current_readiness.get("currentReadinessProductScenarioSuite") or dashboard_summary.get("currentReadinessProductScenarioSuite"),
            "currentReadinessProductScenarioSuiteStatus": current_readiness.get("currentReadinessProductScenarioSuiteStatus") or dashboard_summary.get("currentReadinessProductScenarioSuiteStatus"),
            "currentReadinessProductScenarioSuiteStageCount": current_readiness.get("currentReadinessProductScenarioSuiteStageCount", dashboard_summary.get("currentReadinessProductScenarioSuiteStageCount")),
            "currentReadinessProductScenarioSuiteFailedStages": current_readiness.get("currentReadinessProductScenarioSuiteFailedStages", dashboard_summary.get("currentReadinessProductScenarioSuiteFailedStages")),
            "currentReadinessProductScenarioSuitePlannedStages": current_readiness.get("currentReadinessProductScenarioSuitePlannedStages", dashboard_summary.get("currentReadinessProductScenarioSuitePlannedStages")),
            "currentReadinessProductScenarioSuiteScenarios": current_readiness.get("currentReadinessProductScenarioSuiteScenarios", dashboard_summary.get("currentReadinessProductScenarioSuiteScenarios")),
            "currentReadinessProductScenarioSuiteProductPlanStages": current_readiness.get("currentReadinessProductScenarioSuiteProductPlanStages", dashboard_summary.get("currentReadinessProductScenarioSuiteProductPlanStages")),
            "currentReadinessProductScenarioSuiteLargeGroupIncluded": current_readiness.get("currentReadinessProductScenarioSuiteLargeGroupIncluded", dashboard_summary.get("currentReadinessProductScenarioSuiteLargeGroupIncluded")),
            "currentReadinessFullAcceptanceExpectedCampaign": current_readiness.get("currentReadinessFullAcceptanceExpectedCampaign") or dashboard_summary.get("currentReadinessFullAcceptanceExpectedCampaign"),
            "currentReadinessFullAcceptanceCampaign": current_readiness.get("currentReadinessFullAcceptanceCampaign") or dashboard_summary.get("currentReadinessFullAcceptanceCampaign"),
            "currentReadinessFullAcceptanceStatus": current_readiness.get("currentReadinessFullAcceptanceStatus") or dashboard_summary.get("currentReadinessFullAcceptanceStatus"),
            "currentReadinessFullAcceptanceFailures": current_readiness.get("currentReadinessFullAcceptanceFailures", dashboard_summary.get("currentReadinessFullAcceptanceFailures")),
            "currentReadinessFullAcceptanceRequiredFailures": current_readiness.get("currentReadinessFullAcceptanceRequiredFailures", dashboard_summary.get("currentReadinessFullAcceptanceRequiredFailures")),
            "currentReadinessFullAcceptanceAttempted": current_readiness.get("currentReadinessFullAcceptanceAttempted", dashboard_summary.get("currentReadinessFullAcceptanceAttempted")),
            "currentReadinessFullAcceptanceSkipped": current_readiness.get("currentReadinessFullAcceptanceSkipped", dashboard_summary.get("currentReadinessFullAcceptanceSkipped")),
            "currentReadinessOperatorNetworkPreflight": current_readiness.get("currentReadinessOperatorNetworkPreflight", dashboard_summary.get("currentReadinessOperatorNetworkPreflight")),
            "currentReadinessOperatorNetworkLogPresent": current_readiness.get("currentReadinessOperatorNetworkLogPresent", dashboard_summary.get("currentReadinessOperatorNetworkLogPresent")),
            "currentReadinessOperatorNetworkJSONPresent": current_readiness.get("currentReadinessOperatorNetworkJSONPresent", dashboard_summary.get("currentReadinessOperatorNetworkJSONPresent")),
            "currentReadinessOperatorNetworkEvidencePresent": current_readiness.get("currentReadinessOperatorNetworkEvidencePresent", dashboard_summary.get("currentReadinessOperatorNetworkEvidencePresent")),
            "currentReadinessOperatorNetworkFailed": current_readiness.get("currentReadinessOperatorNetworkFailed", dashboard_summary.get("currentReadinessOperatorNetworkFailed")),
            "currentReadinessOperatorNetworkWarnings": current_readiness.get("currentReadinessOperatorNetworkWarnings", dashboard_summary.get("currentReadinessOperatorNetworkWarnings")),
            "currentReadinessOperatorNetworkRouteInterfaces": current_readiness.get("currentReadinessOperatorNetworkRouteInterfaces", dashboard_summary.get("currentReadinessOperatorNetworkRouteInterfaces")),
            "currentReadinessOperatorNetworkRouteGateways": current_readiness.get("currentReadinessOperatorNetworkRouteGateways", dashboard_summary.get("currentReadinessOperatorNetworkRouteGateways")),
            "currentReadinessOperatorNetworkFailureCount": current_readiness.get("currentReadinessOperatorNetworkFailureCount", dashboard_summary.get("currentReadinessOperatorNetworkFailureCount")),
            "productionGate": production_gate_status or "UNKNOWN",
            "productionGateProfile": production_gate.get("profile") or dashboard_summary.get("productionGateProfile"),
            "productionGateRequired": int(production_gate_summary.get("requiredScenarioCount") or dashboard_summary.get("productionGateRequired") or 0),
            "productionGatePassed": int(production_gate_summary.get("passedScenarioCount") or dashboard_summary.get("productionGatePassed") or 0),
            "productionGateFailed": int(production_gate_summary.get("failedScenarioCount") or dashboard_summary.get("productionGateFailed") or 0),
            "productionGateMissing": int(production_gate_summary.get("missingScenarioCount") or dashboard_summary.get("productionGateMissing") or 0),
            "productionGateFailureKinds": production_gate_summary.get("failureKindCounts") or dashboard_summary.get("productionGateFailureKinds") or {},
            "productionGateMaxEvidenceAgeSeconds": production_gate_requirements.get("maxEvidenceAgeSeconds", dashboard_summary.get("productionGateMaxEvidenceAgeSeconds")),
            "productionGateEvidenceOldestAgeSeconds": production_gate_summary.get("evidenceOldestAgeSeconds", dashboard_summary.get("productionGateEvidenceOldestAgeSeconds")),
            "productionGateEvidenceNewestAgeSeconds": production_gate_summary.get("evidenceNewestAgeSeconds", dashboard_summary.get("productionGateEvidenceNewestAgeSeconds")),
            "productionGateEvidenceStaleCount": int(production_gate_summary.get("evidenceStaleCount") or dashboard_summary.get("productionGateEvidenceStaleCount") or 0),
            "productionGateEvidenceTimeInFutureCount": int(production_gate_summary.get("evidenceTimeInFutureCount") or dashboard_summary.get("productionGateEvidenceTimeInFutureCount") or 0),
            "productionGateMissingEvidenceTimeCount": int(production_gate_summary.get("missingEvidenceTimeCount") or dashboard_summary.get("productionGateMissingEvidenceTimeCount") or 0),
            "productionEvidenceBlockerCount": len(production_blockers),
            "productionEvidenceBlockers": [str(row.get("code") or "") for row in production_blockers],
            "productionEvidenceActionCommands": [str(row.get("role") or "") for row in production_action_commands],
            "productionAcceptanceStatus": production_acceptance.get("productionAcceptanceStatus"),
            "productionAcceptanceReason": production_acceptance.get("productionAcceptanceReason"),
            "productionAcceptanceLevel": production_acceptance.get("productionAcceptanceLevel"),
            "productionAcceptancePackagePresent": production_acceptance.get("productionAcceptancePackagePresent"),
            "productionAcceptanceOperatorNetworkPreflight": production_acceptance.get("productionAcceptanceOperatorNetworkPreflight"),
            "productionAcceptanceRequireCloudSecurityGroupRepairReceipt": production_acceptance.get("productionAcceptanceRequireCloudSecurityGroupRepairReceipt"),
            "productionAcceptanceCloudSecurityGroupRepairReceiptPresent": production_acceptance.get("productionAcceptanceCloudSecurityGroupRepairReceiptPresent"),
            "entrypointRescueStatus": entrypoint_rescue.get("status") or "",
            "entrypointRescueAction": entrypoint_rescue.get("rescuePlanAction") or "",
            "entrypointRescueDiagnosis": entrypoint_rescue.get("entrypointDiagnosis") or "",
            "entrypointRescueDetail": entrypoint_rescue.get("entrypointDetail") or "",
            "entrypointRescueCommand": entrypoint_rescue_command,
            "sloPass": int(slo_counts.get("PASS") or 0),
            "sloFail": int(slo_counts.get("FAIL") or 0),
            "sloUnknown": int(slo_counts.get("UNKNOWN") or 0),
            "sloNeverRun": int(slo_counts.get("NEVER_RUN") or 0),
            "extraSloFail": int(extra_slo_counts.get("FAIL") or 0),
            "sloDomainStatus": slo_domain_summary.get("overallStatus") or "UNKNOWN",
            "sloDomainReadinessCounts": slo_domain_summary.get("readinessCounts") or {},
            "priorityCounts": next_actions.get("priorityCounts") or {},
            "domainCount": len(domains),
        },
        "domains": domains,
        "topActions": top_actions(actions, args.action_limit),
        "productionGateFailedScenarios": production_gate_failed_scenarios,
        "productionEvidenceBlockers": production_blockers,
        "productionEvidenceActionCommands": production_action_commands,
        "currentProductionReadinessCommand": current_readiness_command,
        "productionProfileCommand": production_profile_command,
        "productionAcceptanceCommand": production_acceptance_command,
        "nextCommand": next_command,
        "sources": {
            "scenarioStatus": args.scenario_status_json,
            "sloStatus": args.slo_status_json,
            "sloDomainScorecard": args.slo_domain_scorecard_json,
            "readinessGate": args.readiness_gate_json,
            "nextActions": args.next_actions_json,
            "scenarioCatalog": args.scenario_catalog_json,
            "dashboard": args.dashboard_json,
            "runPlan": args.run_plan_json,
            "productionGate": args.production_gate_json,
            "entrypointRescueSummary": args.entrypoint_rescue_summary,
            "currentReadiness": args.current_readiness_json,
            "productionAcceptance": args.production_acceptance_json,
        },
    }


def build_markdown(payload: dict[str, Any]) -> str:
    summary = payload["summary"]
    priority = summary.get("priorityCounts") or {}
    slo_domain_counts = summary.get("sloDomainReadinessCounts") or {}
    production_failure_kinds = summary.get("productionGateFailureKinds") or {}
    production_blockers = payload.get("productionEvidenceBlockers") or []
    production_failure_text = ", ".join(
        f"{kind}={count}" for kind, count in sorted(production_failure_kinds.items())
    ) or "-"
    production_blocker_text = ", ".join(str(row.get("code") or "") for row in production_blockers) or "-"
    operator_warnings = summary.get("currentReadinessOperatorNetworkWarnings") or []
    operator_interfaces = summary.get("currentReadinessOperatorNetworkRouteInterfaces") or []
    operator_gateways = summary.get("currentReadinessOperatorNetworkRouteGateways") or []
    overview_rows = [
        ["Metric", "Value"],
        ["Conclusion", f"`{summary['conclusion']}`"],
        ["Recommendation", str(summary["recommendation"])],
        ["Readiness gate", f"`{summary.get('readinessGate')}` failures=`{summary.get('readinessFailures')}`"],
        ["Current readiness", f"`{summary.get('currentReadinessStatus') or '-'}` reason=`{summary.get('currentReadinessReason') or '-'}`"],
        ["Current readiness freshness", f"`{summary.get('currentReadinessFreshnessStatus') or '-'}` reason=`{summary.get('currentReadinessFreshnessReason') or '-'}` age/max=`{summary.get('currentReadinessAgeSeconds') if summary.get('currentReadinessAgeSeconds') is not None else '-'}`/`{summary.get('currentReadinessMaxAgeSeconds') if summary.get('currentReadinessMaxAgeSeconds') is not None else '-'}` seconds generatedAt=`{summary.get('currentReadinessGeneratedAt') or summary.get('currentReadinessGeneratedAtEpoch') or '-'}`"],
        ["Current readiness requested S/PS/B/F", f"`{summary.get('currentReadinessRequestedSmoke') if summary.get('currentReadinessRequestedSmoke') is not None else '-'}`/`{summary.get('currentReadinessRequestedProductScenarioSuite') if summary.get('currentReadinessRequestedProductScenarioSuite') is not None else '-'}`/`{summary.get('currentReadinessRequestedBaseline') if summary.get('currentReadinessRequestedBaseline') is not None else '-'}`/`{summary.get('currentReadinessRequestedFullAcceptance') if summary.get('currentReadinessRequestedFullAcceptance') is not None else '-'}`"],
        ["Current readiness exits S/PS/B/F", f"`{summary.get('currentReadinessSmokeExitCode') if summary.get('currentReadinessSmokeExitCode') is not None else '-'}`/`{summary.get('currentReadinessProductScenarioSuiteExitCode') if summary.get('currentReadinessProductScenarioSuiteExitCode') is not None else '-'}`/`{summary.get('currentReadinessBaselineExitCode') if summary.get('currentReadinessBaselineExitCode') is not None else '-'}`/`{summary.get('currentReadinessFullAcceptanceExitCode') if summary.get('currentReadinessFullAcceptanceExitCode') is not None else '-'}`"],
        ["Current product scenario suite", f"expected=`{summary.get('currentReadinessProductScenarioSuiteExpected') or '-'}` actual=`{summary.get('currentReadinessProductScenarioSuite') or '-'}` status=`{summary.get('currentReadinessProductScenarioSuiteStatus') or '-'}` stages failed/planned=`{summary.get('currentReadinessProductScenarioSuiteFailedStages') if summary.get('currentReadinessProductScenarioSuiteFailedStages') is not None else '-'}`/`{summary.get('currentReadinessProductScenarioSuitePlannedStages') if summary.get('currentReadinessProductScenarioSuitePlannedStages') is not None else '-'}` of `{summary.get('currentReadinessProductScenarioSuiteStageCount') if summary.get('currentReadinessProductScenarioSuiteStageCount') is not None else '-'}` scenarios=`{summary.get('currentReadinessProductScenarioSuiteScenarios') if summary.get('currentReadinessProductScenarioSuiteScenarios') is not None else '-'}` productPlanStages=`{summary.get('currentReadinessProductScenarioSuiteProductPlanStages') if summary.get('currentReadinessProductScenarioSuiteProductPlanStages') is not None else '-'}` largeGroup=`{summary.get('currentReadinessProductScenarioSuiteLargeGroupIncluded') if summary.get('currentReadinessProductScenarioSuiteLargeGroupIncluded') is not None else '-'}`"],
        ["Current full acceptance", f"expected=`{summary.get('currentReadinessFullAcceptanceExpectedCampaign') or '-'}` actual=`{summary.get('currentReadinessFullAcceptanceCampaign') or '-'}` status=`{summary.get('currentReadinessFullAcceptanceStatus') or '-'}` failures=`{summary.get('currentReadinessFullAcceptanceFailures') if summary.get('currentReadinessFullAcceptanceFailures') is not None else '-'}`/`{summary.get('currentReadinessFullAcceptanceRequiredFailures') if summary.get('currentReadinessFullAcceptanceRequiredFailures') is not None else '-'}` attempted/skipped=`{summary.get('currentReadinessFullAcceptanceAttempted') if summary.get('currentReadinessFullAcceptanceAttempted') is not None else '-'}`/`{summary.get('currentReadinessFullAcceptanceSkipped') if summary.get('currentReadinessFullAcceptanceSkipped') is not None else '-'}`"],
        ["Current operator network", f"preflight=`{summary.get('currentReadinessOperatorNetworkPreflight') if summary.get('currentReadinessOperatorNetworkPreflight') is not None else '-'}` log=`{summary.get('currentReadinessOperatorNetworkLogPresent') if summary.get('currentReadinessOperatorNetworkLogPresent') is not None else '-'}` json=`{summary.get('currentReadinessOperatorNetworkJSONPresent') if summary.get('currentReadinessOperatorNetworkJSONPresent') is not None else '-'}` evidence=`{summary.get('currentReadinessOperatorNetworkEvidencePresent') if summary.get('currentReadinessOperatorNetworkEvidencePresent') is not None else '-'}` failed=`{summary.get('currentReadinessOperatorNetworkFailed') if summary.get('currentReadinessOperatorNetworkFailed') is not None else '-'}` failures=`{summary.get('currentReadinessOperatorNetworkFailureCount') if summary.get('currentReadinessOperatorNetworkFailureCount') is not None else '-'}` warnings=`{','.join(str(item) for item in operator_warnings) or '-'}` route=`{','.join(str(item) for item in operator_interfaces) or '-'}` gateway=`{','.join(str(item) for item in operator_gateways) or '-'}`"],
        ["Production gate", f"`{summary.get('productionGate')}` profile=`{summary.get('productionGateProfile')}` required=`{summary.get('productionGateRequired')}` passed/failed/missing=`{summary.get('productionGatePassed')}/{summary.get('productionGateFailed')}/{summary.get('productionGateMissing')}`"],
        ["Production gate failure kinds", production_failure_text],
        ["Production evidence age", f"oldest/newest/max=`{summary.get('productionGateEvidenceOldestAgeSeconds') if summary.get('productionGateEvidenceOldestAgeSeconds') is not None else '-'}`/`{summary.get('productionGateEvidenceNewestAgeSeconds') if summary.get('productionGateEvidenceNewestAgeSeconds') is not None else '-'}`/`{summary.get('productionGateMaxEvidenceAgeSeconds') if summary.get('productionGateMaxEvidenceAgeSeconds') is not None else '-'}` seconds"],
        ["Production evidence stale/future/missing-time", f"`{summary.get('productionGateEvidenceStaleCount', 0)}/{summary.get('productionGateEvidenceTimeInFutureCount', 0)}/{summary.get('productionGateMissingEvidenceTimeCount', 0)}`"],
        ["Production evidence blockers", f"`{summary.get('productionEvidenceBlockerCount', 0)}` {production_blocker_text}"],
        ["Production acceptance", f"`{summary.get('productionAcceptanceStatus') or '-'}` reason=`{summary.get('productionAcceptanceReason') or '-'}` package=`{summary.get('productionAcceptancePackagePresent') if summary.get('productionAcceptancePackagePresent') is not None else '-'}` operatorNetwork=`{summary.get('productionAcceptanceOperatorNetworkPreflight') if summary.get('productionAcceptanceOperatorNetworkPreflight') is not None else '-'}` repairReceipt=`{summary.get('productionAcceptanceCloudSecurityGroupRepairReceiptPresent') if summary.get('productionAcceptanceCloudSecurityGroupRepairReceiptPresent') is not None else '-'}`"],
        ["Entrypoint rescue", f"`{summary.get('entrypointRescueStatus') or '-'}` diagnosis=`{summary.get('entrypointRescueDiagnosis') or '-'}` action=`{summary.get('entrypointRescueAction') or '-'}`"],
        ["Scenarios run/total", f"`{summary['ranScenarioCount']}/{summary['matrixScenarioCount']}` ({summary['coveragePercentByRun']}%)"],
        ["Parseable evidence/total", f"`{summary['parseableScenarioCount']}/{summary['matrixScenarioCount']}` ({summary['coveragePercentByParseableEvidence']}%)"],
        ["Scenario PASS/FAIL/UNKNOWN/NEVER", f"`{summary['pass']}/{summary['fail']}/{summary['unknown']}/{summary['neverRun']}`"],
        ["SLO PASS/FAIL/UNKNOWN/NEVER", f"`{summary['sloPass']}/{summary['sloFail']}/{summary['sloUnknown']}/{summary['sloNeverRun']}`"],
        ["Extra SLO FAIL", f"`{summary['extraSloFail']}`"],
        ["SLO domain status", f"`{summary['sloDomainStatus']}`"],
        ["SLO domains READY/OPT/EVIDENCE/RUN", f"`{slo_domain_counts.get('READY', 0)}/{slo_domain_counts.get('NEEDS_SLO_OPTIMIZATION', 0)}/{slo_domain_counts.get('NEEDS_RUNTIME_EVIDENCE', 0)}/{slo_domain_counts.get('NEEDS_RUN', 0)}`"],
        ["Actions P0/P1/P2/P3", f"`{priority.get('P0', 0)}/{priority.get('P1', 0)}/{priority.get('P2', 0)}/{priority.get('P3', 0)}`"],
    ]

    domain_rows = [["Domain", "Scenarios", "Latest PASS/FAIL/UNKNOWN/NEVER", "SLO Readiness", "SLO PASS/FAIL/UNKNOWN/NEVER", "Next"]]
    for row in payload.get("domains") or []:
        domain_rows.append([
            str(row.get("domain") or ""),
            str(row.get("scenarioCount") or 0),
            f"{row.get('latestPass', 0)}/{row.get('latestFail', 0)}/{row.get('latestUnknown', 0)}/{row.get('latestNeverRun', 0)}",
            str(row.get("sloReadiness") or ""),
            f"{row.get('sloPass', 0)}/{row.get('sloFail', 0)}/{row.get('sloUnknown', 0)}/{row.get('sloNeverRun', 0)}",
            str(row.get("nextAction") or "")[:160],
        ])

    action_rows = [["Priority", "Scenario", "Category", "Action"]]
    for row in payload.get("topActions") or []:
        action_rows.append([
            str(row.get("priority") or ""),
            f"`{row.get('scenario') or ''}`",
            f"`{row.get('category') or ''}`",
            str(row.get("action") or "")[:180],
        ])

    production_rows = [["Scenario", "Category", "Failure", "SLO", "Runs", "Reason"]]
    for row in payload.get("productionGateFailedScenarios") or []:
        production_rows.append([
            f"`{row.get('scenario') or ''}`",
            f"`{row.get('category') or ''}`",
            str(row.get("failureKind") or ""),
            str(row.get("latestSLOStatus") or ""),
            str(row.get("runCount") or 0),
            str(row.get("reason") or "")[:160],
        ])

    blocker_rows = [["Code", "Severity", "Source", "Reason", "Action", "Command Role"]]
    for row in production_blockers:
        blocker_rows.append([
            f"`{row.get('code') or ''}`",
            str(row.get("severity") or ""),
            f"`{row.get('source') or ''}`",
            str(row.get("reason") or "")[:160],
            str(row.get("action") or "")[:180],
            f"`{row.get('commandRole') or '-'}`",
        ])

    lines = [
        "# Performance State Summary",
        "",
        "## Overview",
        "",
        table(overview_rows),
        "",
    ]
    if payload.get("nextCommand"):
        lines.extend([
            "## Next Command",
            "",
            "```bash",
            str(payload["nextCommand"]),
            "```",
            "",
        ])
    if len(production_rows) > 1:
        lines.extend([
            "## Production Gate Missing Evidence",
            "",
            table(production_rows),
            "",
        ])
    if len(blocker_rows) > 1:
        lines.extend([
            "## Production Evidence Blockers",
            "",
            table(blocker_rows),
            "",
        ])
    if payload.get("productionEvidenceActionCommands"):
        lines.extend([
            "## Production Evidence Commands",
            "",
        ])
        for row in payload.get("productionEvidenceActionCommands") or []:
            lines.extend([
                f"### {row.get('role') or 'production-evidence'}",
                "",
                "```bash",
                str(row.get("command") or ""),
                "```",
                "",
            ])
    lines.extend([
        "## Domains",
        "",
        table(domain_rows),
        "",
        "## Top Actions",
        "",
        table(action_rows) if len(action_rows) > 1 else "No open actions.",
        "",
        "## Sources",
        "",
    ])
    for name, source in (payload.get("sources") or {}).items():
        if source:
            lines.append(f"- {name}: `{source}`")
    lines.append("")
    return "\n".join(lines)


SUMMARY_CSV_FIELDS = [
    "conclusion",
    "readinessGate",
    "currentReadinessGeneratedAt",
    "currentReadinessGeneratedAtEpoch",
    "currentReadinessAgeSeconds",
    "currentReadinessMaxAgeSeconds",
    "currentReadinessFreshnessStatus",
    "currentReadinessFreshnessReason",
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
    "currentReadinessOperatorNetworkJSONPresent",
    "currentReadinessOperatorNetworkEvidencePresent",
    "currentReadinessOperatorNetworkFailed",
    "currentReadinessOperatorNetworkWarnings",
    "currentReadinessOperatorNetworkRouteInterfaces",
    "currentReadinessOperatorNetworkRouteGateways",
    "currentReadinessOperatorNetworkFailureCount",
    "productionEvidenceBlockerCount",
    "productionEvidenceBlockers",
    "productionEvidenceActionCommands",
    "productionAcceptanceStatus",
    "productionAcceptanceReason",
    "productionAcceptanceLevel",
    "productionAcceptancePackagePresent",
    "productionAcceptanceOperatorNetworkPreflight",
    "productionAcceptanceRequireCloudSecurityGroupRepairReceipt",
    "productionAcceptanceCloudSecurityGroupRepairReceiptPresent",
]


def write_csv(path: Path, payload: dict[str, Any]) -> None:
    fieldnames = [
        "recordType",
        *SUMMARY_CSV_FIELDS,
        "domain",
        "scenarioCount",
        "familyCount",
        "latestPass",
        "latestFail",
        "latestUnknown",
        "latestNeverRun",
        "sloReadiness",
        "sloPass",
        "sloFail",
        "sloUnknown",
        "sloNeverRun",
        "nextAction",
    ]
    summary = payload.get("summary") or {}
    rows = payload.get("domains") or []
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        summary_row = {key: "" for key in fieldnames}
        summary_row["recordType"] = "summary"
        for key in SUMMARY_CSV_FIELDS:
            value = summary.get(key, "")
            if isinstance(value, list):
                value = ",".join(str(item) for item in value)
            summary_row[key] = value
        writer.writerow(summary_row)
        for row in rows:
            output = {key: "" for key in fieldnames}
            output["recordType"] = "domain"
            for key in fieldnames:
                if key in row:
                    output[key] = row.get(key, "")
            writer.writerow(output)


def main() -> int:
    parser = argparse.ArgumentParser(description="Summarize current performance coverage, result status, SLO state, blockers, and next command.")
    parser.add_argument("--scenario-status-json")
    parser.add_argument("--slo-status-json")
    parser.add_argument("--slo-domain-scorecard-json")
    parser.add_argument("--readiness-gate-json")
    parser.add_argument("--next-actions-json")
    parser.add_argument("--scenario-catalog-json")
    parser.add_argument("--dashboard-json")
    parser.add_argument("--run-plan-json")
    parser.add_argument("--production-gate-json")
    parser.add_argument("--entrypoint-rescue-summary")
    parser.add_argument("--current-readiness-json")
    parser.add_argument("--current-readiness-max-age-seconds", type=int, default=86400)
    parser.add_argument("--current-readiness-future-skew-seconds", type=int, default=300)
    parser.add_argument("--production-acceptance-json")
    parser.add_argument("--base-url")
    parser.add_argument("--tcp-host")
    parser.add_argument("--tcp-port")
    parser.add_argument("--account-file")
    parser.add_argument("--conversation-id")
    parser.add_argument("--require-internal-secret", action="store_true")
    parser.add_argument("--action-limit", type=int, default=12)
    parser.add_argument("--output")
    parser.add_argument("--json-output")
    parser.add_argument("--csv-output")
    args = parser.parse_args()
    if args.action_limit <= 0:
        parser.error("--action-limit must be greater than 0")
    if args.current_readiness_max_age_seconds < 0:
        parser.error("--current-readiness-max-age-seconds must be greater than or equal to 0")
    if args.current_readiness_future_skew_seconds < 0:
        parser.error("--current-readiness-future-skew-seconds must be greater than or equal to 0")

    payload = build_summary(args)
    markdown = build_markdown(payload)
    if args.output:
        Path(args.output).write_text(markdown)
    else:
        print(markdown)
    if args.json_output:
        Path(args.json_output).write_text(json.dumps(payload, indent=2, sort_keys=True))
    if args.csv_output:
        write_csv(Path(args.csv_output), payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
