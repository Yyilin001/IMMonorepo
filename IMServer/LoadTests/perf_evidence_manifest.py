#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import tempfile
import time
from pathlib import Path
from typing import Any

from perf_product_campaign_artifacts_verify import (
    PRODUCTION_GATE_CAMPAIGNS,
    verify as verify_product_campaign_artifacts,
)
from perf_current_production_readiness_verify import verify as verify_current_production_readiness
from perf_docs_audit import verify_markdown as verify_docs_audit_markdown
from perf_product_campaign_audit import verify_markdown as verify_product_campaign_audit_markdown
from perf_product_plan_artifacts_verify import verify as verify_product_plan_artifacts
from perf_product_profile_gate import verify_markdown as verify_product_profile_gate_markdown
from perf_profile_artifacts_verify import verify as verify_profile_artifacts
from perf_product_scenario_suite_verify import verify as verify_product_scenario_suite
from perf_validation_inventory import (
    REQUIRED_INVENTORY_RECORDS,
    verify_inventory as verify_validation_inventory,
    verify_inventory_markdown as verify_validation_inventory_markdown,
)


MANIFEST_NAME = "production-evidence-manifest.json"
PRODUCTION_ACCEPTANCE_SIDECARS = {
    "production-acceptance.json",
    "production-acceptance-package.tar.gz",
}
EXCLUDED = {MANIFEST_NAME, "SHA256SUMS", *PRODUCTION_ACCEPTANCE_SIDECARS}
REQUIRED_FILES = {
    "README.md",
    "docs-audit.json",
    "docs-audit.md",
    "product-profile-gate.json",
    "product-profile-gate.md",
    "product-campaign-audit.json",
    "product-campaign-audit.md",
    "secret-scan.log",
    "production-profile-entrypoint-probe.json",
    "production-profile-entrypoint-probe.log",
    "production-profile-runbook.json",
    "production-profile-runbook.md",
    "production-gate.json",
    "perf_production_profiles.json",
    "perf_product_campaigns.json",
    "validation-inventory.json",
    "validation-inventory.md",
}
PROFILE_FILES = {
    "production-profile-run.json",
    "production-profile-plan.json",
    "production-profile-prereq-plan.json",
    "production-profile-prereq-audit.json",
    "production-profile-prereq-audit.md",
    "production-profile-scenario-catalog.json",
    "production-profile-runbook.json",
    "production-profile-runbook.md",
}
PROFILE_OPTIONAL_FILES = {
    "production-profile-operator-network.log",
    "production-profile-operator-network.json",
}
PRODUCT_PLAN_FILES = {
    "product-test-plan-run.json",
    "product-test-plan-preview.json",
    "product-test-plan-phases.tsv",
    "product-test-prereq-plan.json",
    "product-test-prereq-audit.json",
    "product-test-prereq-audit.md",
    "product-test-scenario-catalog.json",
    "product-test-runbook.json",
    "product-test-runbook.md",
}
PRODUCT_CAMPAIGN_FILES = {
    "product-campaign-run.json",
    "product-campaign-runbook.md",
}
PRODUCT_SCENARIO_SUITE_FILES = {
    "product-scenario-suite-run.json",
    "product-scenario-suite-run.md",
}
PRODUCT_SCENARIO_SUITE_OPTIONAL_FILES = {
    "product-scenario-suite-stages.tsv",
}
CURRENT_READINESS_FILES = {
    "current-production-readiness.json",
    "current-production-readiness.md",
    "current-production-state-summary.csv",
}
CURRENT_READINESS_OPTIONAL_FILES = {
    "current-readiness-operator-network.log",
    "current-readiness-operator-network.json",
    "current-readiness-entrypoint-probe.json",
    "current-readiness-entrypoint-probe.log",
    "current-readiness-normal-product-smoke.log",
    "current-readiness-product-scenario-suite.log",
    "current-readiness-normal-product-baseline.log",
    "current-readiness-production-full-acceptance.log",
    "current-readiness-full-acceptance-run.json",
    "current-readiness-full-acceptance-runbook.md",
    "current-readiness-cloud-security-group-repair-receipt.json",
    "current-readiness-cloud-security-group-repair-receipt-verify.log",
    "current-production-dashboard.json",
    "current-production-dashboard.md",
    "current-production-state-summary.json",
    "current-production-state-summary.md",
    "current-production-prereq-summary.txt",
}
CLOUD_SECURITY_GROUP_FILE = "cloud-security-group.json"
CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_FILE = "cloud-security-group-repair-receipt.json"
CLOUD_SECURITY_GROUP_REPAIR_FILES = {
    CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_FILE,
    "cloud-security-group-repair-plan.json",
    "cloud-security-group-repair-snapshot.json",
    "cloud-security-group-repair-post-apply-snapshot.json",
}
POLICY_KEYS = {
    "requireProfileArtifacts",
    "requireProductPlanArtifacts",
    "requireProductCampaignArtifacts",
    "requireProductScenarioSuiteArtifacts",
    "requireProductScenarioSuiteNoLargeGroup",
    "requireCurrentReadinessArtifacts",
    "requireCloudSecurityGroup",
    "allowTempHTTP8080",
    "cloudSecurityGroupRulesMaxAgeSeconds",
    "cloudSecurityGroupRulesRequireRootOwner",
    "requireCloudSecurityGroupRepairReceipt",
}


def expected_required_inventory_records() -> dict[str, list[str]]:
    return {
        name: sorted(records)
        for name, records in sorted(REQUIRED_INVENTORY_RECORDS.items())
    }


def inventory_record_paths(inventory: dict[str, Any]) -> dict[str, set[str]]:
    result: dict[str, set[str]] = {}
    for group, records in (inventory.get("groups") or {}).items():
        if not isinstance(records, list):
            continue
        result[str(group)] = {
            str(record.get("path") or "")
            for record in records
            if isinstance(record, dict) and str(record.get("path") or "")
        }
    return result


def missing_required_inventory_records(inventory: dict[str, Any]) -> dict[str, list[str]]:
    paths = inventory_record_paths(inventory)
    missing: dict[str, list[str]] = {}
    for group, required in expected_required_inventory_records().items():
        group_paths = paths.get(group, set())
        group_missing = sorted(item for item in required if item not in group_paths)
        if group_missing:
            missing[group] = group_missing
    return missing


def read_json(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def operator_network_summary(path: Path) -> dict[str, Any]:
    summary: dict[str, Any] = {
        "present": path.is_file(),
        "failed": False,
        "warnings": [],
        "routeInterfaces": [],
        "routeGateways": [],
        "failureCount": 0,
    }
    if not path.is_file():
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


def operator_network_json_summary(path: Path) -> dict[str, Any]:
    summary: dict[str, Any] = {
        "present": path.is_file(),
        "failed": False,
        "warnings": [],
        "routeInterfaces": [],
        "routeGateways": [],
        "failureCount": 0,
    }
    if not path.is_file():
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


def operator_network_evidence_summary(log_path: Path, json_path: Path) -> dict[str, Any]:
    json_summary = operator_network_json_summary(json_path)
    if json_summary.get("present"):
        return json_summary
    return operator_network_summary(log_path)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def iter_payload_files(root: Path) -> list[Path]:
    files: list[Path] = []
    for path in sorted(root.iterdir(), key=lambda item: item.name):
        if not path.is_file() or path.name in EXCLUDED:
            continue
        files.append(path)
    return files


def relative_name(root: Path, path: Path) -> str:
    return str(path.relative_to(root))


def run_self_test() -> None:
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        payload = root / "payload.log"
        nested = root / "nested"
        nested.mkdir()
        nested_payload = nested / "ignored-nested.log"
        manifest = root / MANIFEST_NAME
        shasums = root / "SHA256SUMS"
        acceptance = root / "production-acceptance.json"

        payload.write_text("payload\n", encoding="utf-8")
        nested_payload.write_text("nested payload\n", encoding="utf-8")
        manifest.write_text("{}\n", encoding="utf-8")
        shasums.write_text("ignored\n", encoding="utf-8")
        acceptance.write_text("{}\n", encoding="utf-8")

        files = [relative_name(root, path) for path in iter_payload_files(root)]
        if files != ["payload.log"]:
            raise SystemExit(f"self_test_payload_files_mismatch files={files}")
        expected_sha = hashlib.sha256(b"payload\n").hexdigest()
        actual_sha = sha256_file(payload)
        if actual_sha != expected_sha:
            raise SystemExit("self_test_sha256_mismatch")
        if relative_name(root, payload) != "payload.log":
            raise SystemExit("self_test_relative_name_mismatch")
        if MANIFEST_NAME not in EXCLUDED or "SHA256SUMS" not in EXCLUDED:
            raise SystemExit("self_test_excluded_contract_mismatch")
    print("evidence_manifest_self_test result=pass")


def env_bool(name: str, default: bool) -> bool:
    value = os.environ.get(name)
    if value is None or value == "":
        return default
    return value.lower() in {"1", "true", "yes", "on"}


def env_text(name: str) -> str:
    return str(os.environ.get(name) or "")


def env_int(name: str, default: int) -> int:
    value = os.environ.get(name)
    if value is None or value == "":
        return default
    try:
        return int(value)
    except Exception:
        return default


def entrypoint_probe_summary(root: Path) -> dict[str, Any]:
    path = root / "production-profile-entrypoint-probe.json"
    if not path.is_file():
        return {
            "present": False,
            "failed": None,
            "diagnosis": "",
            "tcpStatus": "",
            "edgeIntercept": "",
            "additionalProtocolHosts": [],
            "portProtocols": [],
            "blocker": {},
        }
    probe = read_json(path)
    blocker = probe.get("blocker") if isinstance(probe.get("blocker"), dict) else {}
    signals = probe.get("signals") if isinstance(probe.get("signals"), dict) else {}
    port_protocols = probe.get("portProtocols") or signals.get("portProtocols") or []
    additional_protocol_hosts = probe.get("additionalProtocolHosts") or signals.get("additionalProtocolHosts") or []
    return {
        "present": True,
        "failed": probe.get("failed"),
        "diagnosis": probe.get("diagnosis") or "",
        "tcpStatus": probe.get("tcpStatus") or signals.get("tcpStatus") or "",
        "edgeIntercept": probe.get("edgeIntercept") or signals.get("edgeIntercept") or "",
        "additionalProtocolHosts": additional_protocol_hosts if isinstance(additional_protocol_hosts, list) else [],
        "portProtocols": port_protocols if isinstance(port_protocols, list) else [],
        "blocker": {
            "type": blocker.get("type") or "",
            "severity": blocker.get("severity") or "",
            "preventsPerformanceEvidence": blocker.get("preventsPerformanceEvidence") if "preventsPerformanceEvidence" in blocker else "",
            "action": blocker.get("action") or "",
        },
    }


def build_manifest(root: Path) -> dict[str, Any]:
    gate_path = root / "production-gate.json"
    gate = read_json(gate_path)
    source = gate.get("source") or {}
    profile_catalog = gate.get("profileCatalog") or {}
    profile_run = read_json(root / "production-profile-run.json") if (root / "production-profile-run.json").is_file() else {}
    profile_entrypoint_probe = entrypoint_probe_summary(root)
    profile_operator_network = operator_network_evidence_summary(
        root / "production-profile-operator-network.log",
        root / "production-profile-operator-network.json",
    )
    product_run = read_json(root / "product-test-plan-run.json") if (root / "product-test-plan-run.json").is_file() else {}
    product_preview = read_json(root / "product-test-plan-preview.json") if (root / "product-test-plan-preview.json").is_file() else {}
    product_preview_summary = product_preview.get("summary") or {}
    product_profile_gate = read_json(root / "product-profile-gate.json") if (root / "product-profile-gate.json").is_file() else {}
    product_campaign_audit = read_json(root / "product-campaign-audit.json") if (root / "product-campaign-audit.json").is_file() else {}
    campaign_run = read_json(root / "product-campaign-run.json") if (root / "product-campaign-run.json").is_file() else {}
    campaign_target = campaign_run.get("target") or {}
    suite_run = read_json(root / "product-scenario-suite-run.json") if (root / "product-scenario-suite-run.json").is_file() else {}
    suite_coverage = suite_run.get("coverageSummary") or {}
    current_readiness = read_json(root / "current-production-readiness.json") if (root / "current-production-readiness.json").is_file() else {}
    current_requested = current_readiness.get("requestedRuns") or {}
    current_runs = current_readiness.get("runs") or {}
    current_target = current_readiness.get("target") or {}
    current_full_acceptance_run = read_json(root / "current-readiness-full-acceptance-run.json") if (root / "current-readiness-full-acceptance-run.json").is_file() else {}
    current_operator_network = operator_network_evidence_summary(
        root / "current-readiness-operator-network.log",
        root / "current-readiness-operator-network.json",
    )
    validation_inventory = read_json(root / "validation-inventory.json") if (root / "validation-inventory.json").is_file() else {}
    validation_inventory_markdown_path = root / "validation-inventory.md"
    cloud_security_group_path = root / CLOUD_SECURITY_GROUP_FILE
    cloud_security_group_repair_receipt_path = root / CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_FILE
    cloud_security_group_repair_present_files = sorted(
        name
        for name in CLOUD_SECURITY_GROUP_REPAIR_FILES
        if (root / name).is_file()
    )
    files = [
        {
            "path": relative_name(root, path),
            "bytes": path.stat().st_size,
            "sha256": sha256_file(path),
        }
        for path in iter_payload_files(root)
    ]
    present_profile_files = sorted(name for name in PROFILE_FILES | PROFILE_OPTIONAL_FILES if (root / name).is_file())
    present_product_files = sorted(name for name in PRODUCT_PLAN_FILES if (root / name).is_file())
    present_campaign_files = sorted(name for name in PRODUCT_CAMPAIGN_FILES if (root / name).is_file())
    present_suite_files = sorted(
        name
        for name in PRODUCT_SCENARIO_SUITE_FILES | PRODUCT_SCENARIO_SUITE_OPTIONAL_FILES
        if (root / name).is_file()
    )
    campaign_name = str(campaign_run.get("campaign") or "")
    return {
        "schemaVersion": 1,
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "profile": gate.get("profile") or "",
        "source": {
            "gitCommit": source.get("gitCommit") or "",
            "gitBranch": source.get("gitBranch") or "",
            "gitDirty": source.get("gitDirty"),
        },
        "profileCatalog": {
            "sha256": profile_catalog.get("sha256") or "",
            "schemaVersion": profile_catalog.get("schemaVersion"),
        },
        "policy": {
            "requireProfileArtifacts": env_bool("PRODUCTION_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS", True),
            "requireProductPlanArtifacts": env_bool("PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS", True),
            "requireProductCampaignArtifacts": env_bool("PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS", True),
            "requireProductScenarioSuiteArtifacts": env_bool("PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS", True),
            "requireProductScenarioSuiteNoLargeGroup": env_bool("PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP", True),
            "requireCurrentReadinessArtifacts": env_bool("PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS", True),
            "requireCloudSecurityGroup": env_bool("PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP", False),
            "allowTempHTTP8080": env_bool("PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080", False),
            "cloudSecurityGroupRulesMaxAgeSeconds": env_int(
                "PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS",
                86400,
            ),
            "cloudSecurityGroupRulesRequireRootOwner": env_bool(
                "PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER",
                False,
            ),
            "requireCloudSecurityGroupRepairReceipt": env_bool(
                "PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT",
                env_bool("PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP", False),
            ),
            "cloudSecurityGroupRepairReceiptExpectSecurityGroupID": env_text(
                "PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID"
            ),
            "cloudSecurityGroupRepairReceiptExpectRegionID": env_text(
                "PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID"
            ),
            "cloudSecurityGroupRepairReceiptExpectAdminCIDR": env_text(
                "PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR"
            ),
        },
        "productionProfile": {
            "present": (root / "production-profile-run.json").is_file(),
            "finalStatus": profile_run.get("finalStatus") or "",
            "blockerType": profile_run.get("blockerType") or "",
            "entrypointProbe": profile_entrypoint_probe,
            "operatorNetwork": profile_operator_network,
            "requiredFiles": sorted(PROFILE_FILES),
            "presentFiles": present_profile_files,
        },
        "requiredFiles": sorted(REQUIRED_FILES),
        "validationInventory": {
            "present": (root / "validation-inventory.json").is_file(),
            "summary": validation_inventory.get("summary") or {},
            "requiredRecords": validation_inventory.get("requiredRecords") or {},
            "expectedRequiredRecords": expected_required_inventory_records(),
            "missingRequiredRecords": missing_required_inventory_records(validation_inventory),
            "markdown": {
                "present": validation_inventory_markdown_path.is_file(),
                "path": "validation-inventory.md" if validation_inventory_markdown_path.is_file() else "",
                "bytes": validation_inventory_markdown_path.stat().st_size if validation_inventory_markdown_path.is_file() else 0,
                "sha256": sha256_file(validation_inventory_markdown_path) if validation_inventory_markdown_path.is_file() else "",
            },
        },
        "cloudSecurityGroup": {
            "present": cloud_security_group_path.is_file(),
            "path": CLOUD_SECURITY_GROUP_FILE if cloud_security_group_path.is_file() else "",
            "bytes": cloud_security_group_path.stat().st_size if cloud_security_group_path.is_file() else 0,
            "sha256": sha256_file(cloud_security_group_path) if cloud_security_group_path.is_file() else "",
            "repairReceipt": {
                "present": cloud_security_group_repair_receipt_path.is_file(),
                "path": CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_FILE if cloud_security_group_repair_receipt_path.is_file() else "",
                "bytes": cloud_security_group_repair_receipt_path.stat().st_size if cloud_security_group_repair_receipt_path.is_file() else 0,
                "sha256": sha256_file(cloud_security_group_repair_receipt_path) if cloud_security_group_repair_receipt_path.is_file() else "",
                "requiredFiles": sorted(CLOUD_SECURITY_GROUP_REPAIR_FILES),
                "presentFiles": cloud_security_group_repair_present_files,
            },
        },
        "productPlan": {
            "present": (root / "product-test-plan-run.json").is_file(),
            "finalStatus": product_run.get("finalStatus") or "",
            "blockerType": product_run.get("blockerType") or "",
            "scenarioCount": product_preview_summary.get("uniqueScenarioCount") or 0,
            "largeGroupIncluded": product_preview_summary.get("largeGroupIncluded"),
            "coveredProductDomains": product_preview_summary.get("coveredProductDomains") or [],
            "requiredProductDomains": product_preview_summary.get("requiredProductDomains") or [],
            "missingProductDomains": product_preview_summary.get("missingProductDomains") or [],
            "requiredProductDomainsCovered": product_preview_summary.get("requiredProductDomainsCovered"),
            "requiredFiles": sorted(PRODUCT_PLAN_FILES),
            "presentFiles": present_product_files,
        },
        "productProfileGate": {
            "present": (root / "product-profile-gate.json").is_file(),
            "status": product_profile_gate.get("status") or "",
            "profilesChecked": product_profile_gate.get("profilesChecked") or [],
            "requiredDomains": product_profile_gate.get("requiredDomains") or [],
            "forbiddenScenarioPrefixes": product_profile_gate.get("forbiddenScenarioPrefixes") or [],
            "profileCount": product_profile_gate.get("profileCount") or 0,
            "errorCount": product_profile_gate.get("errorCount") or 0,
            "warningCount": product_profile_gate.get("warningCount") or 0,
            "profiles": [
                {
                    "profile": row.get("profile") or "",
                    "status": row.get("status") or "",
                    "scenarioCount": row.get("scenarioCount") or 0,
                    "domainCount": row.get("domainCount") or 0,
                    "missingDomains": row.get("missingDomains") or [],
                    "largeGroupScenarioCount": row.get("largeGroupScenarioCount") or 0,
                    "forbiddenScenarioCount": row.get("forbiddenScenarioCount") or 0,
                    "unknownScenarioCount": row.get("unknownScenarioCount") or 0,
                }
                for row in product_profile_gate.get("profiles") or []
                if isinstance(row, dict)
            ],
        },
        "productCampaign": {
            "present": (root / "product-campaign-run.json").is_file(),
            "audit": {
                "present": (root / "product-campaign-audit.json").is_file(),
                "status": product_campaign_audit.get("status") or "",
                "campaignCount": product_campaign_audit.get("campaignCount") or 0,
                "errorCount": product_campaign_audit.get("errorCount") or 0,
                "warningCount": product_campaign_audit.get("warningCount") or 0,
                "requiredPhasePolicyCount": len(product_campaign_audit.get("requiredPhasePolicies") or []),
                "requiredPhasePolicies": product_campaign_audit.get("requiredPhasePolicies") or [],
                "inputs": product_campaign_audit.get("inputs") or {},
            },
            "campaign": campaign_name,
            "productionGateCampaign": campaign_name in PRODUCTION_GATE_CAMPAIGNS,
            "finalStatus": campaign_run.get("finalStatus") or "",
            "target": {
                "baseURL": campaign_target.get("baseURL") or "",
                "tcpHost": campaign_target.get("tcpHost") or "",
                "tcpPort": campaign_target.get("tcpPort") or "",
                "accountFile": campaign_target.get("accountFile") or "",
                "hasConversationID": campaign_target.get("hasConversationID") or "",
                "hasInternalSecret": campaign_target.get("hasInternalSecret") or "",
            },
            "requiredFailureCount": campaign_run.get("requiredFailureCount") or 0,
            "failureCount": campaign_run.get("failureCount") or 0,
            "attemptedStageCount": campaign_run.get("attemptedStageCount") or 0,
            "skippedStageCount": campaign_run.get("skippedStageCount") or 0,
            "requiredFiles": sorted(PRODUCT_CAMPAIGN_FILES),
            "presentFiles": present_campaign_files,
        },
        "productScenarioSuite": {
            "present": (root / "product-scenario-suite-run.json").is_file(),
            "suite": suite_run.get("suite") or "",
            "status": suite_run.get("status") or "",
            "reason": suite_run.get("reason") or "",
            "stageCount": suite_run.get("stageCount") or 0,
            "failedStageCount": suite_run.get("failedStageCount") or 0,
            "plannedStageCount": suite_run.get("plannedStageCount") or 0,
            "coverage": {
                "uniqueScenarioCount": suite_coverage.get("uniqueScenarioCount") or 0,
                "largeGroupIncluded": suite_coverage.get("largeGroupIncluded"),
                "coveredProductDomains": suite_coverage.get("coveredProductDomains") or [],
                "requiredProductDomains": suite_coverage.get("requiredProductDomains") or [],
                "missingProductDomains": suite_coverage.get("missingProductDomains") or [],
                "requiredProductDomainsCovered": suite_coverage.get("requiredProductDomainsCovered"),
                "coverageErrorCount": suite_coverage.get("coverageErrorCount") or 0,
            },
            "requiredFiles": sorted(PRODUCT_SCENARIO_SUITE_FILES),
            "presentFiles": present_suite_files,
        },
        "currentReadiness": {
            "present": (root / "current-production-readiness.json").is_file(),
            "status": current_readiness.get("status") or "",
            "reason": current_readiness.get("reason") or "",
            "target": {
                "baseURL": current_target.get("baseURL") or "",
                "tcpHost": current_target.get("tcpHost") or "",
                "tcpPort": current_target.get("tcpPort") or "",
                "accountFile": current_target.get("accountFile") or "",
                "conversationIDPresent": current_target.get("conversationIDPresent"),
            },
            "requestedRuns": {
                "smoke": current_requested.get("smoke"),
                "smokeMode": current_requested.get("smokeMode") or "",
                "productScenarioSuite": current_requested.get("productScenarioSuite"),
                "productScenarioSuiteName": current_requested.get("productScenarioSuiteName") or "",
                "baseline": current_requested.get("baseline"),
                "fullAcceptance": current_requested.get("fullAcceptance"),
                "fullAcceptanceCampaign": current_requested.get("fullAcceptanceCampaign") or "",
            },
            "runs": {
                "smokeExitCode": current_runs.get("smokeExitCode"),
                "suiteExitCode": current_runs.get("suiteExitCode"),
                "baselineExitCode": current_runs.get("baselineExitCode"),
                "fullAcceptanceExitCode": current_runs.get("fullAcceptanceExitCode"),
            },
            "operatorNetwork": current_operator_network,
            "productScenarioSuiteRun": {
                "present": (root / "product-scenario-suite-run.json").is_file(),
                "suite": suite_run.get("suite") or "",
                "status": suite_run.get("status") or "",
                "stageCount": suite_run.get("stageCount") or 0,
                "failedStageCount": suite_run.get("failedStageCount") or 0,
                "plannedStageCount": suite_run.get("plannedStageCount") or 0,
                "uniqueScenarioCount": suite_coverage.get("uniqueScenarioCount") or 0,
                "largeGroupIncluded": suite_coverage.get("largeGroupIncluded"),
            },
            "fullAcceptanceRun": {
                "present": (root / "current-readiness-full-acceptance-run.json").is_file(),
                "campaign": current_full_acceptance_run.get("campaign") or "",
                "execute": current_full_acceptance_run.get("execute"),
                "finalStatus": current_full_acceptance_run.get("finalStatus") or "",
                "failureCount": current_full_acceptance_run.get("failureCount"),
                "requiredFailureCount": current_full_acceptance_run.get("requiredFailureCount"),
                "attemptedStageCount": current_full_acceptance_run.get("attemptedStageCount"),
                "skippedStageCount": current_full_acceptance_run.get("skippedStageCount"),
            },
            "requiredFiles": sorted(CURRENT_READINESS_FILES),
            "presentFiles": sorted(
                name
                for name in CURRENT_READINESS_FILES | CURRENT_READINESS_OPTIONAL_FILES
                if (root / name).is_file()
            ),
        },
        "files": files,
    }


def fail(reason: str, **fields: Any) -> None:
    details = " ".join(f"{key}={value}" for key, value in fields.items())
    message = f"evidence_manifest result=fail reason={reason}"
    if details:
        message = f"{message} {details}"
    raise SystemExit(message)


def manifest_policy_bool(policy: Any, key: str) -> bool:
    if key not in POLICY_KEYS:
        fail("manifest_policy_field_unknown", field=key)
    if not isinstance(policy, dict):
        fail("manifest_policy_missing")
    if key not in policy:
        fail("manifest_policy_field_missing", field=key)
    value = policy.get(key)
    if not isinstance(value, bool):
        fail("manifest_policy_field_invalid", field=key, type=type(value).__name__)
    return value


def manifest_policy_text(policy: Any, key: str, required: bool = False) -> str:
    if not isinstance(policy, dict):
        fail("manifest_policy_missing")
    value = policy.get(key)
    if value is None:
        if required:
            fail("manifest_policy_field_missing", field=key)
        return ""
    if not isinstance(value, str):
        fail("manifest_policy_field_invalid", field=key, type=type(value).__name__)
    if required and not value:
        fail("manifest_policy_field_empty", field=key)
    return value


def manifest_policy_int(policy: Any, key: str, required: bool = False) -> int:
    if not isinstance(policy, dict):
        fail("manifest_policy_missing")
    if key not in policy:
        if required:
            fail("manifest_policy_field_missing", field=key)
        return 0
    value = policy.get(key)
    if not isinstance(value, int) or isinstance(value, bool):
        fail("manifest_policy_field_invalid", field=key, type=type(value).__name__)
    if required and value <= 0:
        fail("manifest_policy_field_invalid", field=key, value=value)
    return value


def optional_text(value: Any) -> str:
    return "" if value is None else str(value)


def verify_docs_audit(root: Path, expected_profile_catalog_sha: str) -> None:
    docs_path = root / "docs-audit.json"
    docs_markdown_path = root / "docs-audit.md"
    if not docs_path.is_file():
        fail("docs_audit_missing", path="docs-audit.json")
    if not docs_markdown_path.is_file():
        fail("docs_audit_markdown_missing", path="docs-audit.md")
    try:
        docs = read_json(docs_path)
    except Exception as exc:
        fail("docs_audit_invalid_json", path="docs-audit.json", error=exc)
    try:
        verify_docs_audit_markdown(docs_path, docs_markdown_path)
    except SystemExit as exc:
        fail("docs_audit_markdown_verify_failed", detail=str(exc))
    if str(docs.get("status") or "") != "PASS":
        fail("docs_audit_failed", path="docs-audit.json", status=docs.get("status") or "-")
    if int(docs.get("errorCount") or 0) != 0:
        fail("docs_audit_errors", path="docs-audit.json", errors=docs.get("errorCount"))
    listed_groups = int(docs.get("listedGroupCount") or 0)
    presets_groups = int(docs.get("presetsGroupCount") or 0)
    if listed_groups <= 0 or presets_groups != listed_groups:
        fail(
            "docs_audit_group_count_mismatch",
            path="docs-audit.json",
            presets=presets_groups,
            listed=listed_groups,
        )
    inputs = docs.get("inputs") or {}
    for name in ("readme", "matrixScript", "profileCatalog"):
        sha = str((inputs.get(name) or {}).get("sha256") or "")
        if not sha:
            fail("docs_audit_input_sha_missing", path="docs-audit.json", input=name)
    docs_catalog_sha = str((inputs.get("profileCatalog") or {}).get("sha256") or "")
    if expected_profile_catalog_sha and docs_catalog_sha != expected_profile_catalog_sha:
        fail(
            "docs_audit_profile_catalog_sha_mismatch",
            path="docs-audit.json",
            expected=expected_profile_catalog_sha,
            actual=docs_catalog_sha or "-",
        )
    inventory_path = root / "validation-inventory.json"
    if inventory_path.is_file():
        try:
            inventory = read_json(inventory_path)
        except Exception as exc:
            fail("validation_inventory_invalid_json", path="validation-inventory.json", error=exc)
        inventory_records = {
            str(record.get("path") or ""): str(record.get("sha256") or "")
            for records in (inventory.get("groups") or {}).values()
            if isinstance(records, list)
            for record in records
            if isinstance(record, dict)
        }
        expected_inputs = {
            "readme": "IMServer/LoadTests/README.md",
            "deployReadme": "deploy/ubuntu/README.md",
            "matrixScript": "IMServer/LoadTests/run_perf_scenarios.sh",
            "profileCatalog": "IMServer/LoadTests/perf_production_profiles.json",
        }
        for input_name, inventory_key in expected_inputs.items():
            docs_sha = str((inputs.get(input_name) or {}).get("sha256") or "")
            inventory_sha = inventory_records.get(inventory_key, "")
            if not inventory_sha:
                fail("docs_audit_inventory_record_missing", path="validation-inventory.json", input=input_name, record=inventory_key)
            if docs_sha != inventory_sha:
                fail(
                    "docs_audit_inventory_sha_mismatch",
                    path="docs-audit.json",
                    input=input_name,
                    expected=inventory_sha,
                    actual=docs_sha or "-",
                )


def verify_secret_scan_log(root: Path) -> None:
    path = root / "secret-scan.log"
    if not path.is_file():
        fail("secret_scan_log_missing", path="secret-scan.log")
    text = path.read_text(encoding="utf-8", errors="replace")
    if "perf_secret_scan result=pass" not in text:
        fail("secret_scan_not_pass", path="secret-scan.log")
    if "perf_secret_scan result=fail" in text:
        fail("secret_scan_failed", path="secret-scan.log")


def verify_readme_summary(root: Path, manifest: dict[str, Any], gate: dict[str, Any]) -> None:
    path = root / "README.md"
    if not path.is_file():
        fail("readme_missing", path="README.md")
    text = path.read_text(encoding="utf-8", errors="replace")

    def require_snippet(snippet: str, reason: str) -> None:
        if snippet not in text:
            fail(reason, path="README.md", expected=snippet.replace(" ", "_"))

    require_snippet("69_install_performance_evidence_package.sh", "readme_install_command_missing")
    require_snippet("Do not install only `production-gate.json`", "readme_gate_only_warning_missing")
    require_snippet(f"- status: `{gate.get('status') or 'UNKNOWN'}`", "readme_gate_status_mismatch")
    require_snippet(f"- profile: `{gate.get('profile') or '-'}`", "readme_profile_mismatch")

    docs_audit = read_json(root / "docs-audit.json") if (root / "docs-audit.json").is_file() else {}
    require_snippet(f"- docsAudit: `{docs_audit.get('status') or '-'}`", "readme_docs_audit_mismatch")

    profile_gate = manifest.get("productProfileGate") or {}
    require_snippet(
        f"- productProfileGate: `{profile_gate.get('status') or '-'}`",
        "readme_product_profile_gate_mismatch",
    )

    campaign = manifest.get("productCampaign") or {}
    if campaign.get("present"):
        require_snippet(f"- productCampaign: `{campaign.get('campaign') or '-'}`", "readme_product_campaign_mismatch")
        require_snippet(
            f"- productCampaignStatus: `{campaign.get('finalStatus') or '-'}`",
            "readme_product_campaign_status_mismatch",
        )

    current = manifest.get("currentReadiness") or {}
    if current.get("present"):
        require_snippet(
            f"- currentReadinessStatus: `{current.get('status') or '-'}`",
            "readme_current_readiness_status_mismatch",
        )
        requested = current.get("requestedRuns") or {}
        runs = current.get("runs") or {}
        require_snippet(
            "- currentReadinessRequestedSmoke/ProductSuite/Baseline/Full: "
            f"`{requested.get('smoke')}/{requested.get('productScenarioSuite')}/"
            f"{requested.get('baseline')}/{requested.get('fullAcceptance')}`",
            "readme_current_readiness_requested_runs_mismatch",
        )
        require_snippet(
            "- currentReadinessExitCodesSmoke/ProductSuite/Baseline/Full: "
            f"`{runs.get('smokeExitCode')}/{runs.get('suiteExitCode')}/"
            f"{runs.get('baselineExitCode')}/{runs.get('fullAcceptanceExitCode')}`",
            "readme_current_readiness_exit_codes_mismatch",
        )


def verify_manifest(root: Path) -> None:
    manifest_path = root / MANIFEST_NAME
    if not manifest_path.is_file():
        fail("manifest_missing", path=manifest_path)
    try:
        manifest = read_json(manifest_path)
    except Exception as exc:
        fail("manifest_invalid_json", path=manifest_path, error=exc)
    if int(manifest.get("schemaVersion") or 0) != 1:
        fail("manifest_invalid_schema", path=manifest_path)

    gate_path = root / "production-gate.json"
    if not gate_path.is_file():
        fail("gate_missing", path=gate_path)
    gate = read_json(gate_path)
    gate_source = gate.get("source") or {}
    manifest_source = manifest.get("source") or {}
    if str(manifest.get("profile") or "") != str(gate.get("profile") or ""):
        fail("profile_mismatch", manifest=manifest.get("profile") or "-", gate=gate.get("profile") or "-")
    if str(manifest_source.get("gitCommit") or "") != str(gate_source.get("gitCommit") or ""):
        fail("source_git_commit_mismatch")
    if manifest_source.get("gitDirty") != gate_source.get("gitDirty"):
        fail("source_git_dirty_mismatch")
    gate_catalog_sha = str((gate.get("profileCatalog") or {}).get("sha256") or "")
    manifest_catalog_sha = str((manifest.get("profileCatalog") or {}).get("sha256") or "")
    if not gate_catalog_sha or manifest_catalog_sha != gate_catalog_sha:
        fail("profile_catalog_sha_mismatch", manifest=manifest_catalog_sha or "-", gate=gate_catalog_sha or "-")
    catalog_snapshot = root / "perf_production_profiles.json"
    if not catalog_snapshot.is_file():
        fail("profile_catalog_snapshot_missing", path="perf_production_profiles.json")
    actual_catalog_sha = sha256_file(catalog_snapshot)
    if actual_catalog_sha != gate_catalog_sha:
        fail(
            "profile_catalog_snapshot_sha_mismatch",
            path="perf_production_profiles.json",
            expected=gate_catalog_sha,
            actual=actual_catalog_sha,
        )

    required = set(str(item) for item in manifest.get("requiredFiles") or [])
    missing_required = sorted(item for item in REQUIRED_FILES if item not in required or not (root / item).is_file())
    if missing_required:
        fail("required_file_missing", file=missing_required[0])
    verify_secret_scan_log(root)
    verify_validation_inventory_manifest(root, manifest)
    verify_docs_audit(root, gate_catalog_sha)
    verify_product_profile_gate(root, manifest)
    verify_product_campaign_audit(root, manifest)
    policy = manifest.get("policy")
    require_profile = manifest_policy_bool(policy, "requireProfileArtifacts")
    require_product_plan = manifest_policy_bool(policy, "requireProductPlanArtifacts")
    require_product_campaign = manifest_policy_bool(policy, "requireProductCampaignArtifacts")
    require_product_scenario_suite = manifest_policy_bool(policy, "requireProductScenarioSuiteArtifacts")
    require_current_readiness = manifest_policy_bool(policy, "requireCurrentReadinessArtifacts")
    require_cloud_security_group = manifest_policy_bool(policy, "requireCloudSecurityGroup")
    allow_temp_http_8080 = manifest_policy_bool(policy, "allowTempHTTP8080")
    rules_max_age_seconds = manifest_policy_int(
        policy,
        "cloudSecurityGroupRulesMaxAgeSeconds",
        required=require_cloud_security_group,
    )
    rules_require_root_owner = manifest_policy_bool(policy, "cloudSecurityGroupRulesRequireRootOwner")
    require_cloud_security_group_repair_receipt = manifest_policy_bool(policy, "requireCloudSecurityGroupRepairReceipt")
    expected_security_group_id = manifest_policy_text(
        policy,
        "cloudSecurityGroupRepairReceiptExpectSecurityGroupID",
        required=require_cloud_security_group_repair_receipt,
    )
    expected_region_id = manifest_policy_text(
        policy,
        "cloudSecurityGroupRepairReceiptExpectRegionID",
        required=require_cloud_security_group_repair_receipt,
    )
    expected_admin_cidr = manifest_policy_text(
        policy,
        "cloudSecurityGroupRepairReceiptExpectAdminCIDR",
        required=require_cloud_security_group_repair_receipt,
    )
    manifest_policy_bool(policy, "requireProductScenarioSuiteNoLargeGroup")
    if require_cloud_security_group and allow_temp_http_8080:
        fail("cloud_security_group_temp_http_8080_policy_invalid")
    if require_cloud_security_group and rules_max_age_seconds <= 0:
        fail("cloud_security_group_rules_max_age_policy_invalid", value=rules_max_age_seconds)
    if require_cloud_security_group and not rules_require_root_owner:
        fail("cloud_security_group_rules_root_owner_policy_missing")
    if require_cloud_security_group_repair_receipt and not require_cloud_security_group:
        fail("cloud_security_group_repair_receipt_requires_cloud_security_group_policy")
    verify_cloud_security_group_manifest(
        root,
        manifest,
        required_snapshot=require_cloud_security_group,
        required_repair_receipt=require_cloud_security_group_repair_receipt,
        expected_security_group_id=expected_security_group_id,
        expected_region_id=expected_region_id,
        expected_admin_cidr=expected_admin_cidr,
    )
    verify_profile_manifest(root, manifest, require_profile)
    verify_product_plan_manifest(root, manifest, require_product_plan)
    verify_product_campaign_manifest(root, manifest, require_product_campaign)
    verify_product_scenario_suite_manifest(root, manifest, require_product_scenario_suite)
    verify_current_readiness_manifest(root, manifest, require_current_readiness)
    verify_readme_summary(root, manifest, gate)

    records = manifest.get("files")
    if not isinstance(records, list) or not records:
        fail("files_missing")
    by_path: dict[str, dict[str, Any]] = {}
    for record in records:
        if not isinstance(record, dict):
            fail("file_record_invalid")
        name = str(record.get("path") or "")
        if not name or name in EXCLUDED or name.startswith("/") or ".." in Path(name).parts:
            fail("file_record_path_invalid", path=name or "-")
        if name in by_path:
            fail("file_record_duplicate", path=name)
        by_path[name] = record
        path = root / name
        if not path.is_file():
            fail("file_missing", path=name)
        if int(record.get("bytes") or -1) != path.stat().st_size:
            fail("file_size_mismatch", path=name)
        actual_sha = sha256_file(path)
        if str(record.get("sha256") or "") != actual_sha:
            fail("file_sha_mismatch", path=name)

    actual_payload = {relative_name(root, path) for path in iter_payload_files(root)}
    recorded_payload = set(by_path)
    missing_from_manifest = sorted(actual_payload - recorded_payload)
    extra_in_manifest = sorted(recorded_payload - actual_payload)
    if missing_from_manifest:
        fail("file_not_listed", path=missing_from_manifest[0])
    if extra_in_manifest:
        fail("listed_file_absent", path=extra_in_manifest[0])


def verify_validation_inventory_manifest(root: Path, manifest: dict[str, Any]) -> None:
    inventory_path = root / "validation-inventory.json"
    inventory_markdown_path = root / "validation-inventory.md"
    manifest_inventory = manifest.get("validationInventory") or {}
    manifest_present = bool(manifest_inventory.get("present"))
    actual_present = inventory_path.is_file()
    if manifest_present != actual_present:
        fail("validation_inventory_presence_mismatch", manifest=manifest_present, actual=actual_present)
    if not actual_present:
        fail("validation_inventory_required", path="validation-inventory.json")
    markdown_record = manifest_inventory.get("markdown") or {}
    markdown_present = bool(markdown_record.get("present"))
    actual_markdown_present = inventory_markdown_path.is_file()
    if markdown_present != actual_markdown_present:
        fail("validation_inventory_markdown_presence_mismatch", manifest=markdown_present, actual=actual_markdown_present)
    if not actual_markdown_present:
        fail("validation_inventory_markdown_required", path="validation-inventory.md")
    if str(markdown_record.get("path") or "") != "validation-inventory.md":
        fail("validation_inventory_markdown_path_mismatch", path=markdown_record.get("path") or "-")
    if int(markdown_record.get("bytes") or -1) != inventory_markdown_path.stat().st_size:
        fail("validation_inventory_markdown_size_mismatch", path="validation-inventory.md")
    actual_markdown_sha = sha256_file(inventory_markdown_path)
    if str(markdown_record.get("sha256") or "") != actual_markdown_sha:
        fail("validation_inventory_markdown_sha_mismatch", path="validation-inventory.md")
    try:
        inventory = verify_validation_inventory(inventory_path)
    except SystemExit as exc:
        fail("validation_inventory_verify_failed", detail=str(exc))
    try:
        verify_validation_inventory_markdown(inventory, inventory_markdown_path)
    except SystemExit as exc:
        fail("validation_inventory_markdown_verify_failed", detail=str(exc))

    if manifest_inventory.get("summary") != (inventory.get("summary") or {}):
        fail("validation_inventory_summary_mismatch")
    expected_required = expected_required_inventory_records()
    if manifest_inventory.get("expectedRequiredRecords") != expected_required:
        fail("validation_inventory_expected_required_records_mismatch")
    inventory_required = inventory.get("requiredRecords") or {}
    if manifest_inventory.get("requiredRecords") != inventory_required:
        fail("validation_inventory_required_records_mismatch")
    if inventory_required != expected_required:
        fail("validation_inventory_required_records_not_expected")
    actual_missing = missing_required_inventory_records(inventory)
    if manifest_inventory.get("missingRequiredRecords") != actual_missing:
        fail("validation_inventory_missing_required_records_mismatch")
    if actual_missing:
        first_group = sorted(actual_missing)[0]
        fail("validation_inventory_required_record_missing", group=first_group, record=actual_missing[first_group][0])


def verify_cloud_security_group_manifest(
    root: Path,
    manifest: dict[str, Any],
    required_snapshot: bool = False,
    required_repair_receipt: bool = False,
    expected_security_group_id: str = "",
    expected_region_id: str = "",
    expected_admin_cidr: str = "",
) -> None:
    path = root / CLOUD_SECURITY_GROUP_FILE
    receipt_path = root / CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_FILE
    record = manifest.get("cloudSecurityGroup") or {}
    manifest_present = bool(record.get("present"))
    actual_present = path.is_file()
    if manifest_present != actual_present:
        fail("cloud_security_group_presence_mismatch", manifest=manifest_present, actual=actual_present)
    if not actual_present:
        if required_snapshot:
            fail("cloud_security_group_required", path=CLOUD_SECURITY_GROUP_FILE)
        return
    if str(record.get("path") or "") != CLOUD_SECURITY_GROUP_FILE:
        fail("cloud_security_group_path_mismatch", manifest=record.get("path") or "-", actual=CLOUD_SECURITY_GROUP_FILE)
    if int(record.get("bytes") or -1) != path.stat().st_size:
        fail("cloud_security_group_size_mismatch", path=CLOUD_SECURITY_GROUP_FILE)
    actual_sha = sha256_file(path)
    if str(record.get("sha256") or "") != actual_sha:
        fail("cloud_security_group_sha_mismatch", path=CLOUD_SECURITY_GROUP_FILE)

    receipt_record = record.get("repairReceipt") or {}
    manifest_receipt_present = bool(receipt_record.get("present"))
    actual_receipt_present = receipt_path.is_file()
    if manifest_receipt_present != actual_receipt_present:
        fail("cloud_security_group_repair_receipt_presence_mismatch", manifest=manifest_receipt_present, actual=actual_receipt_present)
    if not actual_receipt_present:
        if required_repair_receipt:
            fail("cloud_security_group_repair_receipt_required", path=CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_FILE)
        return
    if str(receipt_record.get("path") or "") != CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_FILE:
        fail("cloud_security_group_repair_receipt_path_mismatch", manifest=receipt_record.get("path") or "-", actual=CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_FILE)
    if int(receipt_record.get("bytes") or -1) != receipt_path.stat().st_size:
        fail("cloud_security_group_repair_receipt_size_mismatch", path=CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_FILE)
    if str(receipt_record.get("sha256") or "") != sha256_file(receipt_path):
        fail("cloud_security_group_repair_receipt_sha_mismatch", path=CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_FILE)
    receipt = read_json(receipt_path)
    if expected_security_group_id and str(receipt.get("securityGroupId") or "") != expected_security_group_id:
        fail(
            "cloud_security_group_repair_receipt_security_group_id_mismatch",
            expected=expected_security_group_id,
            actual=receipt.get("securityGroupId") or "-",
        )
    if expected_region_id and str(receipt.get("regionId") or "") != expected_region_id:
        fail(
            "cloud_security_group_repair_receipt_region_id_mismatch",
            expected=expected_region_id,
            actual=receipt.get("regionId") or "-",
        )
    if expected_admin_cidr and str(receipt.get("adminCidr") or "") != expected_admin_cidr:
        fail(
            "cloud_security_group_repair_receipt_admin_cidr_mismatch",
            expected=expected_admin_cidr,
            actual=receipt.get("adminCidr") or "-",
        )
    required_files = set(str(item) for item in (receipt_record.get("requiredFiles") or []))
    if not CLOUD_SECURITY_GROUP_REPAIR_FILES.issubset(required_files):
        fail("cloud_security_group_repair_required_files_mismatch")
    present_files = set(str(item) for item in (receipt_record.get("presentFiles") or []))
    actual_files = {name for name in CLOUD_SECURITY_GROUP_REPAIR_FILES if (root / name).is_file()}
    if present_files != actual_files:
        fail(
            "cloud_security_group_repair_present_files_mismatch",
            manifest=",".join(sorted(present_files)) or "-",
            actual=",".join(sorted(actual_files)) or "-",
        )
    missing = sorted(CLOUD_SECURITY_GROUP_REPAIR_FILES - actual_files)
    if required_repair_receipt and missing:
        fail("cloud_security_group_repair_file_missing", path=missing[0])


def verify_profile_manifest(root: Path, manifest: dict[str, Any], required: bool = True) -> None:
    profile_run_path = root / "production-profile-run.json"
    production_profile = manifest.get("productionProfile") or {}
    manifest_present = bool(production_profile.get("present"))
    actual_present = profile_run_path.is_file()
    if manifest_present != actual_present:
        fail("production_profile_presence_mismatch", manifest=manifest_present, actual=actual_present)
    if not actual_present:
        if required:
            fail("production_profile_required", path="production-profile-run.json")
        return
    profile_run = read_json(profile_run_path)
    if str(production_profile.get("finalStatus") or "") != str(profile_run.get("finalStatus") or ""):
        fail("production_profile_status_mismatch", manifest=production_profile.get("finalStatus") or "-", actual=profile_run.get("finalStatus") or "-")
    if str(production_profile.get("blockerType") or "") != str(profile_run.get("blockerType") or ""):
        fail("production_profile_blocker_type_mismatch", manifest=production_profile.get("blockerType") or "-", actual=profile_run.get("blockerType") or "-")
    if str(profile_run.get("finalStatus") or "") in {"PASS", "NOOP"} and str(profile_run.get("blockerType") or ""):
        fail("production_profile_success_has_blocker_type", blockerType=profile_run.get("blockerType"))
    actual_probe = entrypoint_probe_summary(root)
    manifest_probe = production_profile.get("entrypointProbe") or {}
    if bool(manifest_probe.get("present")) != bool(actual_probe.get("present")):
        fail("production_profile_entrypoint_probe_presence_mismatch", manifest=manifest_probe.get("present"), actual=actual_probe.get("present"))
    if str(manifest_probe.get("diagnosis") or "") != str(actual_probe.get("diagnosis") or ""):
        fail("production_profile_entrypoint_probe_diagnosis_mismatch", manifest=manifest_probe.get("diagnosis") or "-", actual=actual_probe.get("diagnosis") or "-")
    if manifest_probe.get("failed") != actual_probe.get("failed"):
        fail("production_profile_entrypoint_probe_failed_mismatch", manifest=manifest_probe.get("failed"), actual=actual_probe.get("failed"))
    for key in ("tcpStatus", "edgeIntercept"):
        if str(manifest_probe.get(key) or "") != str(actual_probe.get(key) or ""):
            fail(
                "production_profile_entrypoint_probe_signal_mismatch",
                field=key,
                manifest=manifest_probe.get(key) or "-",
                actual=actual_probe.get(key) or "-",
            )
    for key in ("additionalProtocolHosts", "portProtocols"):
        manifest_value = manifest_probe.get(key) if isinstance(manifest_probe.get(key), list) else []
        actual_value = actual_probe.get(key) if isinstance(actual_probe.get(key), list) else []
        if manifest_value != actual_value:
            fail(
                "production_profile_entrypoint_probe_signal_mismatch",
                field=key,
                manifest=len(manifest_value),
                actual=len(actual_value),
            )
    manifest_blocker = manifest_probe.get("blocker") or {}
    actual_blocker = actual_probe.get("blocker") or {}
    for key in ("type", "severity", "preventsPerformanceEvidence", "action"):
        if manifest_blocker.get(key) != actual_blocker.get(key):
            fail(
                "production_profile_entrypoint_probe_blocker_mismatch",
                field=key,
                manifest=manifest_blocker.get(key) if manifest_blocker.get(key) != "" else "-",
                actual=actual_blocker.get(key) if actual_blocker.get(key) != "" else "-",
            )
    profile_operator_log_path = root / "production-profile-operator-network.log"
    profile_operator_json_path = root / "production-profile-operator-network.json"
    manifest_operator = production_profile.get("operatorNetwork") or {}
    actual_operator = operator_network_evidence_summary(profile_operator_log_path, profile_operator_json_path)
    for key in ("present", "failed", "failureCount"):
        if manifest_operator.get(key) != actual_operator.get(key):
            fail(
                "production_profile_operator_network_mismatch",
                field=key,
                manifest=manifest_operator.get(key),
                actual=actual_operator.get(key),
            )
    for key in ("warnings", "routeInterfaces", "routeGateways"):
        if sorted(manifest_operator.get(key) or []) != sorted(actual_operator.get(key) or []):
            fail(
                "production_profile_operator_network_mismatch",
                field=key,
                manifest=",".join(sorted(manifest_operator.get(key) or [])) or "-",
                actual=",".join(sorted(actual_operator.get(key) or [])) or "-",
            )
    if required and profile_run.get("operatorNetworkPreflight") is True:
        if not profile_operator_json_path.is_file():
            fail("production_profile_operator_network_json_required")
        if not profile_operator_log_path.is_file():
            fail("production_profile_operator_network_log_required")
        if manifest_operator.get("present") is not True:
            fail("production_profile_operator_network_log_required")
        if manifest_operator.get("failed") is not False:
            fail("production_profile_operator_network_failed")
        warnings = [str(item) for item in manifest_operator.get("warnings") or [] if str(item)]
        if warnings:
            fail("production_profile_operator_network_warning", warning=warnings[0])
    required_files = set(str(item) for item in (production_profile.get("requiredFiles") or []))
    if not PROFILE_FILES.issubset(required_files):
        missing = sorted(PROFILE_FILES - required_files)
        fail("production_profile_manifest_required_file_missing", file=missing[0])
    present_files = set(str(item) for item in (production_profile.get("presentFiles") or []))
    actual_files = {name for name in PROFILE_FILES | PROFILE_OPTIONAL_FILES if (root / name).is_file()}
    if present_files != actual_files:
        fail(
            "production_profile_present_files_mismatch",
            manifest=",".join(sorted(present_files)) or "-",
            actual=",".join(sorted(actual_files)) or "-",
        )
    missing = sorted(name for name in PROFILE_FILES if not (root / name).is_file())
    if missing:
        fail("production_profile_file_missing", file=missing[0])
    package_path = str((profile_run.get("package") or {}).get("path") or "")
    try:
        verify_profile_artifacts(argparse.Namespace(
            gate_json=root / "production-gate.json",
            profile_run_json=root / "production-profile-run.json",
            profile_plan_json=root / "production-profile-plan.json",
            profile_runbook_json=root / "production-profile-runbook.json",
            profile_runbook_md=root / "production-profile-runbook.md",
            prereq_plan_json=root / "production-profile-prereq-plan.json",
            prereq_audit_json=root / "production-profile-prereq-audit.json",
            scenario_catalog_json=root / "production-profile-scenario-catalog.json",
            expected_package_path=package_path or None,
        ))
    except SystemExit as exc:
        fail("production_profile_artifact_verify_failed", detail=str(exc))


def verify_product_profile_gate(root: Path, manifest: dict[str, Any]) -> None:
    gate_path = root / "product-profile-gate.json"
    gate_md_path = root / "product-profile-gate.md"
    if not gate_path.is_file():
        fail("product_profile_gate_missing", path="product-profile-gate.json")
    if not gate_md_path.is_file():
        fail("product_profile_gate_md_missing", path="product-profile-gate.md")
    try:
        gate = read_json(gate_path)
    except Exception as exc:
        fail("product_profile_gate_invalid_json", path="product-profile-gate.json", error=exc)
    try:
        verify_product_profile_gate_markdown(gate, gate_md_path)
    except SystemExit as exc:
        fail("product_profile_gate_markdown_mismatch", detail=str(exc))
    product_profile_gate = manifest.get("productProfileGate") or {}
    if product_profile_gate.get("present") is not True:
        fail("product_profile_gate_manifest_not_present")
    if str(product_profile_gate.get("status") or "") != str(gate.get("status") or ""):
        fail("product_profile_gate_status_mismatch", manifest=product_profile_gate.get("status") or "-", actual=gate.get("status") or "-")
    if str(gate.get("status") or "") != "PASS":
        fail("product_profile_gate_not_pass", status=gate.get("status") or "-")
    if int(product_profile_gate.get("errorCount") or 0) != int(gate.get("errorCount") or 0):
        fail("product_profile_gate_error_count_mismatch")
    if int(gate.get("errorCount") or 0) != 0:
        fail("product_profile_gate_errors", errors=gate.get("errorCount"))
    for key in ("profilesChecked", "requiredDomains", "forbiddenScenarioPrefixes"):
        manifest_values = sorted(str(item) for item in (product_profile_gate.get(key) or []) if str(item))
        gate_values = sorted(str(item) for item in (gate.get(key) or []) if str(item))
        if manifest_values != gate_values:
            fail(
                f"product_profile_gate_{key}_mismatch",
                manifest=",".join(manifest_values) or "-",
                actual=",".join(gate_values) or "-",
            )
    required_domains = [str(item) for item in (gate.get("requiredDomains") or []) if str(item)]
    if not required_domains:
        fail("product_profile_gate_required_domains_empty")
    profiles_checked = [str(item) for item in (gate.get("profilesChecked") or []) if str(item)]
    if "normal-product-baseline" not in profiles_checked:
        fail("product_profile_gate_missing_normal_product_baseline")
    if int(product_profile_gate.get("profileCount") or 0) != int(gate.get("profileCount") or 0):
        fail("product_profile_gate_profile_count_mismatch")
    manifest_profiles = {
        str(row.get("profile") or ""): row
        for row in product_profile_gate.get("profiles") or []
        if isinstance(row, dict)
    }
    gate_profiles = {
        str(row.get("profile") or ""): row
        for row in gate.get("profiles") or []
        if isinstance(row, dict)
    }
    if sorted(manifest_profiles) != sorted(gate_profiles):
        fail(
            "product_profile_gate_profiles_mismatch",
            manifest=",".join(sorted(manifest_profiles)) or "-",
            actual=",".join(sorted(gate_profiles)) or "-",
        )
    for profile, row in gate_profiles.items():
        if str(row.get("status") or "") != "PASS":
            fail("product_profile_gate_profile_not_pass", profile=profile or "-", status=row.get("status") or "-")
        missing_domains = [str(item) for item in (row.get("missingDomains") or []) if str(item)]
        if missing_domains:
            fail("product_profile_gate_profile_missing_domain", profile=profile or "-", domain=missing_domains[0])
        for key in ("largeGroupScenarioCount", "forbiddenScenarioCount", "unknownScenarioCount"):
            if int(row.get(key) or 0) != 0:
                fail(f"product_profile_gate_profile_{key}", profile=profile or "-", count=row.get(key))
        manifest_row = manifest_profiles.get(profile) or {}
        for key in ("status", "scenarioCount", "domainCount", "largeGroupScenarioCount", "forbiddenScenarioCount", "unknownScenarioCount"):
            if manifest_row.get(key) != row.get(key):
                fail(
                    f"product_profile_gate_profile_{key}_mismatch",
                    profile=profile or "-",
                    manifest=manifest_row.get(key),
                    actual=row.get(key),
                )
        manifest_missing_domains = sorted(str(item) for item in (manifest_row.get("missingDomains") or []) if str(item))
        actual_missing_domains = sorted(str(item) for item in (row.get("missingDomains") or []) if str(item))
        if manifest_missing_domains != actual_missing_domains:
            fail(
                "product_profile_gate_profile_missing_domains_mismatch",
                profile=profile or "-",
                manifest=",".join(manifest_missing_domains) or "-",
                actual=",".join(actual_missing_domains) or "-",
                )


def verify_product_campaign_audit(root: Path, manifest: dict[str, Any]) -> None:
    audit_path = root / "product-campaign-audit.json"
    audit_md_path = root / "product-campaign-audit.md"
    campaign_catalog_snapshot = root / "perf_product_campaigns.json"
    if not audit_path.is_file():
        fail("product_campaign_audit_missing", path="product-campaign-audit.json")
    if not audit_md_path.is_file():
        fail("product_campaign_audit_md_missing", path="product-campaign-audit.md")
    if not campaign_catalog_snapshot.is_file():
        fail("product_campaign_catalog_snapshot_missing", path="perf_product_campaigns.json")
    try:
        audit = read_json(audit_path)
    except Exception as exc:
        fail("product_campaign_audit_invalid_json", path="product-campaign-audit.json", error=exc)
    try:
        verify_product_campaign_audit_markdown(audit, audit_md_path)
    except SystemExit as exc:
        fail("product_campaign_audit_markdown_mismatch", detail=str(exc))
    campaign = manifest.get("productCampaign") or {}
    manifest_audit = campaign.get("audit") or {}
    if manifest_audit.get("present") is not True:
        fail("product_campaign_audit_manifest_not_present")
    if str(manifest_audit.get("status") or "") != str(audit.get("status") or ""):
        fail("product_campaign_audit_status_mismatch", manifest=manifest_audit.get("status") or "-", actual=audit.get("status") or "-")
    if str(audit.get("status") or "") != "PASS":
        fail("product_campaign_audit_not_pass", status=audit.get("status") or "-")
    for key in ("campaignCount", "errorCount", "warningCount"):
        if int(manifest_audit.get(key) or 0) != int(audit.get(key) or 0):
            fail(f"product_campaign_audit_{key}_mismatch")
    if int(audit.get("errorCount") or 0) != 0:
        fail("product_campaign_audit_errors", errors=audit.get("errorCount"))
    policies = audit.get("requiredPhasePolicies") or []
    manifest_policies = manifest_audit.get("requiredPhasePolicies") or []
    if not isinstance(policies, list) or not policies:
        fail("product_campaign_audit_required_phase_policies_missing")
    if manifest_policies != policies:
        fail("product_campaign_audit_required_phase_policies_mismatch")
    if int(manifest_audit.get("requiredPhasePolicyCount") or 0) != len(policies):
        fail("product_campaign_audit_required_phase_policy_count_mismatch")
    audit_inputs = audit.get("inputs") or {}
    manifest_inputs = manifest_audit.get("inputs") or {}
    if manifest_inputs != audit_inputs:
        fail("product_campaign_audit_inputs_mismatch")
    campaign_catalog_input_sha = str((audit_inputs.get("campaignCatalog") or {}).get("sha256") or "")
    if not campaign_catalog_input_sha:
        fail("product_campaign_audit_campaign_catalog_sha_missing")
    actual_campaign_catalog_sha = sha256_file(campaign_catalog_snapshot)
    if campaign_catalog_input_sha != actual_campaign_catalog_sha:
        fail(
            "product_campaign_audit_campaign_catalog_sha_mismatch",
            expected=campaign_catalog_input_sha,
            actual=actual_campaign_catalog_sha,
        )
    profile_catalog_input_sha = str((audit_inputs.get("profileCatalog") or {}).get("sha256") or "")
    gate_catalog_sha = str((manifest.get("profileCatalog") or {}).get("sha256") or "")
    if profile_catalog_input_sha != gate_catalog_sha:
        fail(
            "product_campaign_audit_profile_catalog_sha_mismatch",
            expected=gate_catalog_sha or "-",
            actual=profile_catalog_input_sha or "-",
        )
    for input_name in ("productPlanScript", "matrixScript"):
        if not str((audit_inputs.get(input_name) or {}).get("sha256") or ""):
            fail("product_campaign_audit_input_sha_missing", input=input_name)
    policy_by_campaign = {
        str(row.get("campaign") or ""): row
        for row in policies
        if isinstance(row, dict)
    }
    for required_campaign in ("non-large-group-release", "product-scenario-regression", "product-scenario-acceptance"):
        if required_campaign not in policy_by_campaign:
            fail("product_campaign_audit_required_policy_missing", campaign=required_campaign)
    non_large_phases = {
        str(item)
        for item in (policy_by_campaign.get("non-large-group-release") or {}).get("requiredPhases") or []
        if str(item)
    }
    for phase in ("sync-read", "direct-chat", "group-workflow", "realtime-direct"):
        if phase not in non_large_phases:
            fail("product_campaign_audit_non_large_phase_missing", phase=phase)


def verify_product_plan_manifest(root: Path, manifest: dict[str, Any], required: bool = True) -> None:
    product_run = root / "product-test-plan-run.json"
    product_plan = manifest.get("productPlan") or {}
    manifest_present = bool(product_plan.get("present"))
    actual_present = product_run.is_file()
    if manifest_present != actual_present:
        fail("product_plan_presence_mismatch", manifest=manifest_present, actual=actual_present)
    if not actual_present:
        if required:
            fail("product_plan_required", path="product-test-plan-run.json")
        return
    product_payload = read_json(product_run)
    if str(product_plan.get("finalStatus") or "") != str(product_payload.get("finalStatus") or ""):
        fail("product_plan_status_mismatch", manifest=product_plan.get("finalStatus") or "-", actual=product_payload.get("finalStatus") or "-")
    if str(product_plan.get("blockerType") or "") != str(product_payload.get("blockerType") or ""):
        fail("product_plan_blocker_type_mismatch", manifest=product_plan.get("blockerType") or "-", actual=product_payload.get("blockerType") or "-")
    if str(product_payload.get("finalStatus") or "") == "PASS" and str(product_payload.get("blockerType") or ""):
        fail("product_plan_pass_has_blocker_type", blockerType=product_payload.get("blockerType"))
    product_preview_path = root / "product-test-plan-preview.json"
    if not product_preview_path.is_file():
        fail("product_plan_preview_missing", path="product-test-plan-preview.json")
    product_preview = read_json(product_preview_path)
    product_preview_summary = product_preview.get("summary") or {}
    if int(product_plan.get("scenarioCount") or 0) != int(product_preview_summary.get("uniqueScenarioCount") or 0):
        fail(
            "product_plan_manifest_scenario_count_mismatch",
            manifest=product_plan.get("scenarioCount"),
            preview=product_preview_summary.get("uniqueScenarioCount"),
        )
    if product_plan.get("largeGroupIncluded") != product_preview_summary.get("largeGroupIncluded"):
        fail(
            "product_plan_manifest_large_group_mismatch",
            manifest=product_plan.get("largeGroupIncluded"),
            preview=product_preview_summary.get("largeGroupIncluded"),
        )
    for key in ("coveredProductDomains", "requiredProductDomains", "missingProductDomains"):
        manifest_values = sorted(str(item) for item in (product_plan.get(key) or []) if str(item))
        preview_values = sorted(str(item) for item in (product_preview_summary.get(key) or []) if str(item))
        if manifest_values != preview_values:
            fail(
                f"product_plan_manifest_{key}_mismatch",
                manifest=",".join(manifest_values) or "-",
                preview=",".join(preview_values) or "-",
            )
    if product_plan.get("requiredProductDomainsCovered") != product_preview_summary.get("requiredProductDomainsCovered"):
        fail(
            "product_plan_manifest_required_domains_covered_mismatch",
            manifest=product_plan.get("requiredProductDomainsCovered"),
            preview=product_preview_summary.get("requiredProductDomainsCovered"),
        )

    scenario_count = int(product_plan.get("scenarioCount") or 0)
    if scenario_count <= 0:
        fail("product_plan_manifest_empty", scenarioCount=scenario_count)
    if product_plan.get("largeGroupIncluded") is not False:
        fail(
            "product_plan_manifest_large_group_included",
            largeGroupIncluded=product_plan.get("largeGroupIncluded"),
        )
    covered_domains = {
        str(item)
        for item in (product_plan.get("coveredProductDomains") or [])
        if str(item)
    }
    required_domains = {
        str(item)
        for item in (product_plan.get("requiredProductDomains") or [])
        if str(item)
    }
    if not covered_domains:
        fail("product_plan_manifest_domain_count_zero")
    if not required_domains:
        fail("product_plan_manifest_required_domains_empty")
    missing_required = sorted(required_domains - covered_domains)
    if missing_required:
        fail(
            "product_plan_manifest_required_domain_missing",
            domain=missing_required[0],
        )
    missing_domains = [
        str(item)
        for item in (product_plan.get("missingProductDomains") or [])
        if str(item)
    ]
    if missing_domains:
        fail(
            "product_plan_manifest_missing_domains_nonempty",
            domain=missing_domains[0],
        )
    if product_plan.get("requiredProductDomainsCovered") is not True:
        fail(
            "product_plan_manifest_required_domains_not_covered",
            requiredProductDomainsCovered=product_plan.get("requiredProductDomainsCovered"),
        )

    required_files = set(str(item) for item in (product_plan.get("requiredFiles") or []))
    if not PRODUCT_PLAN_FILES.issubset(required_files):
        missing = sorted(PRODUCT_PLAN_FILES - required_files)
        fail("product_plan_manifest_required_file_missing", file=missing[0])
    present_files = set(str(item) for item in (product_plan.get("presentFiles") or []))
    actual_files = {name for name in PRODUCT_PLAN_FILES if (root / name).is_file()}
    if present_files != actual_files:
        fail(
            "product_plan_present_files_mismatch",
            manifest=",".join(sorted(present_files)) or "-",
            actual=",".join(sorted(actual_files)) or "-",
        )
    missing = sorted(name for name in PRODUCT_PLAN_FILES if not (root / name).is_file())
    if missing:
        fail("product_plan_file_missing", file=missing[0])
    try:
        verify_product_plan_artifacts(argparse.Namespace(
            product_run_json=root / "product-test-plan-run.json",
            plan_preview_json=root / "product-test-plan-preview.json",
            phases_tsv=root / "product-test-plan-phases.tsv",
            prereq_plan_json=root / "product-test-prereq-plan.json",
            prereq_audit_json=root / "product-test-prereq-audit.json",
            prereq_audit_md=root / "product-test-prereq-audit.md",
            scenario_catalog_json=root / "product-test-scenario-catalog.json",
            runbook_json=root / "product-test-runbook.json",
            runbook_md=root / "product-test-runbook.md",
            allow_dry_run=False,
            require_prereq=True,
            require_pass=True,
        ))
    except SystemExit as exc:
        fail("product_plan_artifact_verify_failed", detail=str(exc))


def verify_product_campaign_manifest(root: Path, manifest: dict[str, Any], required: bool = True) -> None:
    campaign_run = root / "product-campaign-run.json"
    campaign = manifest.get("productCampaign") or {}
    manifest_present = bool(campaign.get("present"))
    actual_present = campaign_run.is_file()
    if manifest_present != actual_present:
        fail("product_campaign_presence_mismatch", manifest=manifest_present, actual=actual_present)
    if not actual_present:
        if required:
            fail("product_campaign_required", path="product-campaign-run.json")
        return
    campaign_payload = read_json(campaign_run)
    if str(campaign.get("campaign") or "") != str(campaign_payload.get("campaign") or ""):
        fail("product_campaign_name_mismatch", manifest=campaign.get("campaign") or "-", actual=campaign_payload.get("campaign") or "-")
    expected_production_gate = str(campaign_payload.get("campaign") or "") in PRODUCTION_GATE_CAMPAIGNS
    if bool(campaign.get("productionGateCampaign")) != expected_production_gate:
        fail(
            "product_campaign_production_gate_mismatch",
            campaign=campaign_payload.get("campaign") or "-",
            manifest=campaign.get("productionGateCampaign"),
            actual=expected_production_gate,
        )
    if not expected_production_gate:
        fail(
            "product_campaign_not_production_gate",
            campaign=campaign_payload.get("campaign") or "-",
            allowed=",".join(sorted(PRODUCTION_GATE_CAMPAIGNS)),
        )
    if str(campaign.get("finalStatus") or "") != str(campaign_payload.get("finalStatus") or ""):
        fail("product_campaign_status_mismatch", manifest=campaign.get("finalStatus") or "-", actual=campaign_payload.get("finalStatus") or "-")
    manifest_target = campaign.get("target")
    payload_target = campaign_payload.get("target")
    if not isinstance(manifest_target, dict):
        fail("product_campaign_target_missing")
    if not isinstance(payload_target, dict):
        fail("product_campaign_payload_target_missing")
    for key in ("baseURL", "tcpHost", "tcpPort", "accountFile", "hasConversationID", "hasInternalSecret"):
        manifest_value = str(manifest_target.get(key) or "")
        payload_value = str(payload_target.get(key) or "")
        if manifest_value != payload_value:
            fail(
                "product_campaign_target_mismatch",
                field=key,
                manifest=manifest_value or "-",
                actual=payload_value or "-",
            )
    for key in ("baseURL", "tcpHost", "tcpPort"):
        if not str(manifest_target.get(key) or ""):
            fail("product_campaign_target_incomplete", field=key)
    gate = read_json(root / "production-gate.json")
    gate_target = gate.get("targetFilter") or {}
    if gate_target.get("enabled") is not True:
        fail("production_gate_target_filter_disabled")
    target_pairs = (
        ("baseURL", "baseURL"),
        ("tcpHost", "tcpHost"),
        ("tcpPort", "tcpPort"),
    )
    for campaign_key, gate_key in target_pairs:
        campaign_value = str(manifest_target.get(campaign_key) or "")
        gate_value = str(gate_target.get(gate_key) or "")
        if campaign_value != gate_value:
            fail(
                "product_campaign_gate_target_mismatch",
                field=campaign_key,
                campaign=campaign_value or "-",
                gate=gate_value or "-",
            )
    if int(campaign.get("requiredFailureCount") or 0) != int(campaign_payload.get("requiredFailureCount") or 0):
        fail("product_campaign_required_failure_count_mismatch")
    if int(campaign.get("failureCount") or 0) != int(campaign_payload.get("failureCount") or 0):
        fail("product_campaign_failure_count_mismatch")
    if int(campaign.get("attemptedStageCount") or 0) != int(campaign_payload.get("attemptedStageCount") or 0):
        fail("product_campaign_attempted_stage_count_mismatch")
    if int(campaign.get("skippedStageCount") or 0) != int(campaign_payload.get("skippedStageCount") or 0):
        fail("product_campaign_skipped_stage_count_mismatch")
    required_files = set(str(item) for item in (campaign.get("requiredFiles") or []))
    if not PRODUCT_CAMPAIGN_FILES.issubset(required_files):
        missing = sorted(PRODUCT_CAMPAIGN_FILES - required_files)
        fail("product_campaign_manifest_required_file_missing", file=missing[0])
    present_files = set(str(item) for item in (campaign.get("presentFiles") or []))
    actual_files = {name for name in PRODUCT_CAMPAIGN_FILES if (root / name).is_file()}
    if present_files != actual_files:
        fail(
            "product_campaign_present_files_mismatch",
            manifest=",".join(sorted(present_files)) or "-",
            actual=",".join(sorted(actual_files)) or "-",
        )
    missing = sorted(name for name in PRODUCT_CAMPAIGN_FILES if not (root / name).is_file())
    if missing:
        fail("product_campaign_file_missing", file=missing[0])
    try:
        verify_product_campaign_artifacts(argparse.Namespace(
            campaign_run_json=root / "product-campaign-run.json",
            runbook=root / "product-campaign-runbook.md",
            campaigns=Path(__file__).with_name("perf_product_campaigns.json"),
            allow_planned=False,
            require_pass=True,
            require_production_gate_campaign=True,
            require_portable_stage_logs=True,
        ))
    except SystemExit as exc:
        fail("product_campaign_artifact_verify_failed", detail=str(exc))


def verify_product_scenario_suite_manifest(root: Path, manifest: dict[str, Any], required: bool = False) -> None:
    suite_run = root / "product-scenario-suite-run.json"
    suite = manifest.get("productScenarioSuite") or {}
    manifest_present = bool(suite.get("present"))
    actual_present = suite_run.is_file()
    if manifest_present != actual_present:
        fail("product_scenario_suite_presence_mismatch", manifest=manifest_present, actual=actual_present)
    if not actual_present:
        if required:
            fail("product_scenario_suite_required", path="product-scenario-suite-run.json")
        return
    suite_md = root / "product-scenario-suite-run.md"
    if not suite_md.is_file():
        fail("product_scenario_suite_markdown_missing", path="product-scenario-suite-run.md")
    payload = read_json(suite_run)
    for key in ("suite", "status", "reason"):
        if str(suite.get(key) or "") != str(payload.get(key) or ""):
            fail(f"product_scenario_suite_{key}_mismatch", manifest=suite.get(key) or "-", actual=payload.get(key) or "-")
    for key in ("stageCount", "failedStageCount", "plannedStageCount"):
        if int(suite.get(key) or 0) != int(payload.get(key) or 0):
            fail(f"product_scenario_suite_{key}_mismatch", manifest=suite.get(key), actual=payload.get(key))
    coverage = suite.get("coverage") or {}
    payload_coverage = payload.get("coverageSummary") or {}
    for key in ("uniqueScenarioCount", "coverageErrorCount"):
        if int(coverage.get(key) or 0) != int(payload_coverage.get(key) or 0):
            fail(f"product_scenario_suite_coverage_{key}_mismatch", manifest=coverage.get(key), actual=payload_coverage.get(key))
    for key in ("largeGroupIncluded", "requiredProductDomainsCovered"):
        if coverage.get(key) != payload_coverage.get(key):
            fail(f"product_scenario_suite_coverage_{key}_mismatch", manifest=coverage.get(key), actual=payload_coverage.get(key))
    for key in ("coveredProductDomains", "requiredProductDomains", "missingProductDomains"):
        manifest_values = sorted(str(item) for item in (coverage.get(key) or []) if str(item))
        actual_values = sorted(str(item) for item in (payload_coverage.get(key) or []) if str(item))
        if manifest_values != actual_values:
            fail(
                f"product_scenario_suite_coverage_{key}_mismatch",
                manifest=",".join(manifest_values) or "-",
                actual=",".join(actual_values) or "-",
            )
    if str(payload.get("status") or "") != "PASS":
        fail("product_scenario_suite_not_pass", status=payload.get("status") or "-")
    if int(coverage.get("coverageErrorCount") or 0) != 0:
        fail("product_scenario_suite_coverage_errors", count=coverage.get("coverageErrorCount"))
    if int(coverage.get("uniqueScenarioCount") or 0) <= 0:
        fail("product_scenario_suite_coverage_empty")
    if not (coverage.get("coveredProductDomains") or []):
        fail("product_scenario_suite_coverage_domains_empty")
    policy = manifest.get("policy") or {}
    require_no_large_group = bool(policy.get("requireProductScenarioSuiteNoLargeGroup"))
    if require_no_large_group and coverage.get("largeGroupIncluded") is not False:
        fail("product_scenario_suite_large_group_included", largeGroupIncluded=coverage.get("largeGroupIncluded"))
    required_files = set(str(item) for item in (suite.get("requiredFiles") or []))
    if not PRODUCT_SCENARIO_SUITE_FILES.issubset(required_files):
        missing = sorted(PRODUCT_SCENARIO_SUITE_FILES - required_files)
        fail("product_scenario_suite_manifest_required_file_missing", file=missing[0])
    present_files = set(str(item) for item in (suite.get("presentFiles") or []))
    actual_files = {
        name
        for name in PRODUCT_SCENARIO_SUITE_FILES | PRODUCT_SCENARIO_SUITE_OPTIONAL_FILES
        if (root / name).is_file()
    }
    if present_files != actual_files:
        fail(
            "product_scenario_suite_present_files_mismatch",
            manifest=",".join(sorted(present_files)) or "-",
            actual=",".join(sorted(actual_files)) or "-",
        )
    missing = sorted(name for name in PRODUCT_SCENARIO_SUITE_FILES if not (root / name).is_file())
    if missing:
        fail("product_scenario_suite_file_missing", file=missing[0])
    try:
        verify_product_scenario_suite(
            payload,
            root / "product-scenario-suite-run.md",
            receipt_base=root,
            require_pass=True,
            allow_planned=False,
            require_no_large_group=require_no_large_group,
        )
    except SystemExit as exc:
        fail("product_scenario_suite_artifact_verify_failed", detail=str(exc))


def verify_current_readiness_manifest(root: Path, manifest: dict[str, Any], required: bool = False) -> None:
    readiness_path = root / "current-production-readiness.json"
    readiness = manifest.get("currentReadiness") or {}
    manifest_present = bool(readiness.get("present"))
    actual_present = readiness_path.is_file()
    if manifest_present != actual_present:
        fail("current_readiness_presence_mismatch", manifest=manifest_present, actual=actual_present)
    if not actual_present:
        if required:
            fail("current_readiness_required", path="current-production-readiness.json")
        return
    if not (root / "current-production-readiness.md").is_file():
        fail("current_readiness_md_missing", path="current-production-readiness.md")
    payload = read_json(readiness_path)
    for key in ("status", "reason"):
        if str(readiness.get(key) or "") != str(payload.get(key) or ""):
            fail(f"current_readiness_{key}_mismatch", manifest=readiness.get(key) or "-", actual=payload.get(key) or "-")
    manifest_target = readiness.get("target") or {}
    payload_target = payload.get("target") or {}
    for key in ("baseURL", "tcpHost", "tcpPort", "accountFile", "conversationIDPresent"):
        if str(manifest_target.get(key) or "") != str(payload_target.get(key) or ""):
            fail(
                "current_readiness_target_mismatch",
                field=key,
                manifest=manifest_target.get(key) if manifest_target.get(key) not in {None, ""} else "-",
                actual=payload_target.get(key) if payload_target.get(key) not in {None, ""} else "-",
            )
    requested = payload.get("requestedRuns") or {}
    manifest_requested = readiness.get("requestedRuns") or {}
    for key in ("smoke", "productScenarioSuite", "baseline", "fullAcceptance"):
        if manifest_requested.get(key) != requested.get(key):
            fail(
                "current_readiness_requested_run_mismatch",
                field=key,
                manifest=manifest_requested.get(key),
                actual=requested.get(key),
            )
    for key in ("smokeMode", "productScenarioSuiteName", "fullAcceptanceCampaign"):
        if optional_text(manifest_requested.get(key)) != optional_text(requested.get(key)):
            fail(
                "current_readiness_requested_run_mismatch",
                field=key,
                manifest=manifest_requested.get(key),
                actual=requested.get(key),
            )
    runs = payload.get("runs") or {}
    manifest_runs = readiness.get("runs") or {}
    for key in ("smokeExitCode", "suiteExitCode", "baselineExitCode", "fullAcceptanceExitCode"):
        if manifest_runs.get(key) != runs.get(key):
            fail(
                "current_readiness_run_exit_mismatch",
                field=key,
                manifest=manifest_runs.get(key),
                actual=runs.get(key),
            )
    operator_log_path = root / "current-readiness-operator-network.log"
    operator_json_path = root / "current-readiness-operator-network.json"
    manifest_operator = readiness.get("operatorNetwork") or {}
    actual_operator = operator_network_evidence_summary(operator_log_path, operator_json_path)
    evidence_policy = payload.get("evidencePolicy") if isinstance(payload.get("evidencePolicy"), dict) else {}
    manifest_policy = manifest.get("policy") if isinstance(manifest.get("policy"), dict) else {}
    operator_network_required = evidence_policy.get("operatorNetworkPreflight") is True
    policy_pairs = (
        "allowTempHTTP8080",
        "cloudSecurityGroupRulesMaxAgeSeconds",
        "cloudSecurityGroupRulesRequireRootOwner",
    )
    if manifest_policy.get("requireCloudSecurityGroup") is True:
        for key in policy_pairs:
            if manifest_policy.get(key) != evidence_policy.get(key):
                fail(
                    "current_readiness_evidence_policy_mismatch",
                    field=key,
                    manifest=manifest_policy.get(key),
                    actual=evidence_policy.get(key),
                )
    for key in ("present", "failed", "failureCount"):
        if manifest_operator.get(key) != actual_operator.get(key):
            fail(
                "current_readiness_operator_network_mismatch",
                field=key,
                manifest=manifest_operator.get(key),
                actual=actual_operator.get(key),
            )
    for key in ("warnings", "routeInterfaces", "routeGateways"):
        if sorted(manifest_operator.get(key) or []) != sorted(actual_operator.get(key) or []):
            fail(
                "current_readiness_operator_network_mismatch",
                field=key,
                manifest=",".join(sorted(manifest_operator.get(key) or [])) or "-",
                actual=",".join(sorted(actual_operator.get(key) or [])) or "-",
            )
    if payload.get("reason") == "local_operator_network_blocked":
        if not operator_json_path.is_file():
            fail("current_readiness_operator_network_json_required")
        if manifest_operator.get("present") is not True:
            fail("current_readiness_operator_network_log_required")
        if manifest_operator.get("failed") is not True:
            fail("current_readiness_operator_network_not_failed")
    if required and operator_network_required:
        if not operator_json_path.is_file():
            fail("current_readiness_operator_network_json_required")
        if manifest_operator.get("present") is not True:
            fail("current_readiness_operator_network_log_required")
        if manifest_operator.get("failed") is not False:
            fail("current_readiness_operator_network_failed")
        warnings = [str(item) for item in manifest_operator.get("warnings") or [] if str(item)]
        if warnings:
            fail("current_readiness_operator_network_warning", warning=warnings[0])
    suite_run_path = root / "product-scenario-suite-run.json"
    manifest_suite_run = readiness.get("productScenarioSuiteRun") or {}
    if manifest_suite_run.get("present") != suite_run_path.is_file():
        fail(
            "current_readiness_product_scenario_suite_presence_mismatch",
            manifest=manifest_suite_run.get("present"),
            actual=suite_run_path.is_file(),
        )
    actual_suite_run = read_json(suite_run_path) if suite_run_path.is_file() else {}
    actual_suite_coverage = actual_suite_run.get("coverageSummary") or {}
    if suite_run_path.is_file():
        for key in ("suite", "status", "stageCount", "failedStageCount", "plannedStageCount"):
            if manifest_suite_run.get(key) != actual_suite_run.get(key):
                fail(
                    "current_readiness_product_scenario_suite_run_mismatch",
                    field=key,
                    manifest=manifest_suite_run.get(key),
                    actual=actual_suite_run.get(key),
                )
        for key, actual_key in (
            ("uniqueScenarioCount", "uniqueScenarioCount"),
            ("largeGroupIncluded", "largeGroupIncluded"),
        ):
            if manifest_suite_run.get(key) != actual_suite_coverage.get(actual_key):
                fail(
                    "current_readiness_product_scenario_suite_coverage_mismatch",
                    field=key,
                    manifest=manifest_suite_run.get(key),
                    actual=actual_suite_coverage.get(actual_key),
                )
    if requested.get("productScenarioSuite") is True:
        if runs.get("suiteExitCode") != 0:
            fail("current_readiness_product_scenario_suite_not_passed", exitCode=runs.get("suiteExitCode"))
        if manifest_suite_run.get("present") is not True:
            fail("current_readiness_product_scenario_suite_run_missing")
        expected_suite = str(requested.get("productScenarioSuiteName") or "")
        actual_suite = str(manifest_suite_run.get("suite") or "")
        if not expected_suite:
            fail("current_readiness_product_scenario_suite_expected_missing")
        if actual_suite != expected_suite:
            fail(
                "current_readiness_product_scenario_suite_name_mismatch",
                expected=expected_suite,
                actual=actual_suite or "-",
            )
        if manifest_suite_run.get("status") != "PASS":
            fail("current_readiness_product_scenario_suite_status_invalid", status=manifest_suite_run.get("status") or "-")
        if int(manifest_suite_run.get("uniqueScenarioCount") or 0) <= 0:
            fail("current_readiness_product_scenario_suite_empty")
        policy = manifest.get("policy") or {}
        if bool(policy.get("requireProductScenarioSuiteNoLargeGroup")) and manifest_suite_run.get("largeGroupIncluded") is not False:
            fail(
                "current_readiness_product_scenario_suite_large_group_included",
                largeGroupIncluded=manifest_suite_run.get("largeGroupIncluded"),
            )
    full_run_path = root / "current-readiness-full-acceptance-run.json"
    manifest_full_run = readiness.get("fullAcceptanceRun") or {}
    if manifest_full_run.get("present") != full_run_path.is_file():
        fail(
            "current_readiness_full_acceptance_run_presence_mismatch",
            manifest=manifest_full_run.get("present"),
            actual=full_run_path.is_file(),
        )
    actual_full_run = read_json(full_run_path) if full_run_path.is_file() else {}
    if full_run_path.is_file():
        for key in (
            "campaign",
            "execute",
            "finalStatus",
            "failureCount",
            "requiredFailureCount",
            "attemptedStageCount",
            "skippedStageCount",
        ):
            if manifest_full_run.get(key) != actual_full_run.get(key):
                fail(
                    "current_readiness_full_acceptance_run_mismatch",
                    field=key,
                    manifest=manifest_full_run.get(key),
                    actual=actual_full_run.get(key),
                )
    if required and str(payload.get("status") or "") != "PASS":
        fail("current_readiness_not_pass", status=payload.get("status") or "-")
    if required:
        policy = manifest.get("policy") or {}
        required_run_keys = ["smoke", "baseline", "fullAcceptance"]
        if bool(policy.get("requireProductScenarioSuiteArtifacts")):
            required_run_keys.insert(1, "productScenarioSuite")
        for key in required_run_keys:
            if requested.get(key) is not True:
                fail(
                    "current_readiness_required_run_missing",
                    field=key,
                    value=requested.get(key),
                )
        if not str(requested.get("fullAcceptanceCampaign") or ""):
            fail("current_readiness_full_acceptance_campaign_missing")
        if manifest_full_run.get("present") is not True:
            fail("current_readiness_full_acceptance_run_missing")
        expected_campaign = str(requested.get("fullAcceptanceCampaign") or "")
        actual_campaign = str(manifest_full_run.get("campaign") or "")
        if actual_campaign != expected_campaign:
            fail(
                "current_readiness_full_acceptance_campaign_mismatch",
                expected=expected_campaign,
                actual=actual_campaign or "-",
            )
        if manifest_full_run.get("finalStatus") != "PASS":
            fail("current_readiness_full_acceptance_status_invalid", status=manifest_full_run.get("finalStatus") or "-")
        if manifest_full_run.get("execute") is False:
            fail("current_readiness_full_acceptance_not_executed")
        if manifest_full_run.get("requiredFailureCount") != 0:
            fail("current_readiness_full_acceptance_required_failures", count=manifest_full_run.get("requiredFailureCount"))
        if manifest_full_run.get("failureCount") != 0:
            fail("current_readiness_full_acceptance_failures", count=manifest_full_run.get("failureCount"))
        try:
            attempted_count = int(manifest_full_run.get("attemptedStageCount"))
        except Exception:
            fail("current_readiness_full_acceptance_attempted_invalid", count=manifest_full_run.get("attemptedStageCount"))
        if attempted_count <= 0:
            fail("current_readiness_full_acceptance_not_attempted", count=attempted_count)
        if manifest_full_run.get("skippedStageCount") != 0:
            fail("current_readiness_full_acceptance_skipped", count=manifest_full_run.get("skippedStageCount"))
        expected_exit_codes = {
            "smokeExitCode": runs.get("smokeExitCode"),
            "baselineExitCode": runs.get("baselineExitCode"),
            "fullAcceptanceExitCode": runs.get("fullAcceptanceExitCode"),
        }
        if requested.get("productScenarioSuite") is True or bool(policy.get("requireProductScenarioSuiteArtifacts")):
            expected_exit_codes["suiteExitCode"] = runs.get("suiteExitCode")
        for key, value in expected_exit_codes.items():
            if value != 0:
                fail(
                    "current_readiness_required_run_not_pass",
                    field=key,
                    value=value,
                )
    required_files = set(str(item) for item in (readiness.get("requiredFiles") or []))
    if not CURRENT_READINESS_FILES.issubset(required_files):
        missing = sorted(CURRENT_READINESS_FILES - required_files)
        fail("current_readiness_manifest_required_file_missing", file=missing[0])
    present_files = set(str(item) for item in (readiness.get("presentFiles") or []))
    actual_files = {
        name
        for name in CURRENT_READINESS_FILES | CURRENT_READINESS_OPTIONAL_FILES
        if (root / name).is_file()
    }
    if present_files != actual_files:
        fail(
            "current_readiness_present_files_mismatch",
            manifest=",".join(sorted(present_files)) or "-",
            actual=",".join(sorted(actual_files)) or "-",
        )
    if required:
        required_runtime_files = {
            "current-readiness-entrypoint-probe.json",
            "current-readiness-normal-product-smoke.log",
            "current-readiness-normal-product-baseline.log",
            "current-readiness-production-full-acceptance.log",
            "current-readiness-full-acceptance-run.json",
            "current-readiness-full-acceptance-runbook.md",
            "current-production-dashboard.json",
            "current-production-state-summary.json",
            "current-production-state-summary.csv",
        }
        missing_runtime_files = sorted(name for name in required_runtime_files if name not in actual_files)
        if missing_runtime_files:
            fail("current_readiness_required_artifact_missing", file=missing_runtime_files[0])
    try:
        verify_current_production_readiness(argparse.Namespace(
            readiness_json=readiness_path,
            dashboard_json=root / "current-production-dashboard.json" if (root / "current-production-dashboard.json").is_file() else None,
            state_json=root / "current-production-state-summary.json" if (root / "current-production-state-summary.json").is_file() else None,
            probe_json=None,
        ))
    except SystemExit as exc:
        fail("current_readiness_artifact_verify_failed", detail=str(exc))


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate or verify a production evidence package manifest.")
    parser.add_argument("--dir", type=Path)
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        run_self_test()
        return 0
    if args.dir is None:
        parser.error("--dir is required unless --self-test is used")
    root = args.dir.resolve()
    if args.write:
        payload = build_manifest(root)
        (root / MANIFEST_NAME).write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
        print(f"evidence_manifest result=pass action=write path={root / MANIFEST_NAME}")
        return 0
    if args.verify:
        verify_manifest(root)
        print(f"evidence_manifest result=pass action=verify path={root / MANIFEST_NAME}")
        return 0
    parser.error("one of --write or --verify is required")


if __name__ == "__main__":
    raise SystemExit(main())
