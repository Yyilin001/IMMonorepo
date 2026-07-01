#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path
from typing import Any

from perf_matrix_audit import list_output_scenarios


VALID_RUNNERS = {"campaign", "product-plan", "production-profile", "scenario-group", "scenario"}
REQUIRED_PHASE_POLICIES: dict[str, dict[str, set[str]]] = {
    "non-large-group-release": {
        "non-large-missing-phases": {
            "real-world-smoke",
            "daily-core",
            "daily-traffic",
            "account-security",
            "sync-read",
            "direct-chat",
            "group-workflow",
            "contacts-social",
            "media-ai-admin",
            "reliability-recovery",
            "lifecycle-governance",
            "message-spike",
            "realtime-direct",
            "group-delivery",
        },
    },
    "product-scenario-regression": {
        "scenario-regression-missing-phases": {
            "account-security-baseline",
            "sync-read-baseline",
            "direct-chat-baseline",
            "message-spike-baseline",
            "group-workflow-baseline",
            "group-delivery-baseline",
            "contacts-social-baseline",
            "lifecycle-governance-baseline",
            "media-ai-admin-baseline",
            "reliability-recovery-baseline",
            "realtime-direct-baseline",
        },
    },
    "product-scenario-acceptance": {
        "scenario-acceptance-missing-phases": {
            "real-world-baseline",
            "daily-core",
            "daily-traffic",
            "account-security-baseline",
            "sync-read-baseline",
            "direct-chat-baseline",
            "message-spike-baseline",
            "group-workflow-baseline",
            "group-delivery-baseline",
            "contacts-social-baseline",
            "media-ai-admin-baseline",
            "lifecycle-governance-baseline",
            "reliability-recovery-baseline",
            "realtime-direct-baseline",
        },
    },
}


def read_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise SystemExit(f"Failed to read JSON {path}: {exc}") from exc


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def input_metadata(path: Path) -> dict[str, Any]:
    return {
        "path": str(path),
        "sha256": sha256_file(path),
    }


def issue(kind: str, severity: str, campaign: str, stage: str, detail: str) -> dict[str, str]:
    return {
        "kind": kind,
        "severity": severity,
        "campaign": campaign,
        "stage": stage,
        "detail": detail,
    }


def read_product_phases(script: Path) -> set[str]:
    proc = subprocess.run(
        [str(script), "--list-phases"],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    phases: set[str] = set()
    in_available = False
    for raw in proc.stdout.splitlines():
        line = raw.rstrip()
        if line.startswith("Available phases:"):
            in_available = True
            continue
        if not in_available or not line.startswith("  "):
            continue
        parts = line.strip().split(None, 1)
        if parts:
            phases.add(parts[0])
    return phases


def read_profiles(path: Path) -> set[str]:
    payload = read_json(path)
    profiles = payload.get("profiles") or {}
    return {str(name) for name in profiles}


def stage_list(value: Any, key: str) -> list[str]:
    items = value.get(key) if isinstance(value, dict) else None
    if items is None:
        return []
    if not isinstance(items, list):
        return []
    return [str(item) for item in items if str(item)]


def bool_catalog(value: Any, default: bool) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.lower() in {"1", "true", "yes", "on"}
    return bool(value)


def require_phases(
    issues: list[dict[str, str]],
    campaign: str,
    product_phases: set[str],
    required_phases: set[str],
    kind: str,
) -> None:
    missing_phases = sorted(required_phases - product_phases)
    if missing_phases:
        issues.append(issue(
            kind,
            "error",
            campaign,
            "-",
            f"{campaign} is missing required phases: {', '.join(missing_phases)}",
        ))


def required_phase_policy_rows() -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for campaign, policies in sorted(REQUIRED_PHASE_POLICIES.items()):
        for kind, phases in sorted(policies.items()):
            rows.append({
                "campaign": campaign,
                "issueKind": kind,
                "phaseCount": len(phases),
                "requiredPhases": sorted(phases),
            })
    return rows


def audit(campaign_path: Path, product_plan_script: Path, profile_catalog: Path, matrix_script: Path) -> dict[str, Any]:
    payload = read_json(campaign_path)
    phases = read_product_phases(product_plan_script)
    profiles = read_profiles(profile_catalog)
    groups, scenarios = list_output_scenarios(matrix_script)
    group_set = set(groups)
    scenario_set = set(scenarios)
    issues: list[dict[str, str]] = []
    campaign_rows: list[dict[str, Any]] = []

    if int(payload.get("schemaVersion") or 0) != 1:
        issues.append(issue("schema", "error", "-", "-", "schemaVersion must be 1."))

    campaigns = payload.get("campaigns")
    if not isinstance(campaigns, dict) or not campaigns:
        issues.append(issue("campaigns", "error", "-", "-", "campaigns must be a non-empty object."))
        campaigns = {}

    for campaign, body in sorted(campaigns.items()):
        stages = body.get("stages") if isinstance(body, dict) else None
        if not isinstance(stages, list) or not stages:
            issues.append(issue("empty-campaign", "error", campaign, "-", "campaign must contain at least one stage."))
            campaign_rows.append({"campaign": campaign, "stageCount": 0, "requiredCount": 0, "largeGroupStages": 0, "productPlanStages": 0})
            continue

        stage_ids: set[str] = set()
        required_count = 0
        large_group_stages = 0
        large_group_stage_indices: list[int] = []
        product_plan_stages = 0
        profile_stages = 0
        non_large_product_stages = 0
        campaign_refs: set[str] = set()
        product_phases: set[str] = set()
        profile_refs: set[str] = set()
        non_large_release_index: int | None = None
        non_large_release_required = False
        large_group_required_count = 0
        scenario_group_refs: set[str] = set()
        package_profile_stage_ids: list[str] = []
        package_product_plan_stage_ids: list[str] = []

        for index, stage in enumerate(stages, start=1):
            if not isinstance(stage, dict):
                issues.append(issue("stage-type", "error", campaign, str(index), "stage must be an object."))
                continue
            stage_id = str(stage.get("id") or f"stage-{index}")
            runner = str(stage.get("runner") or "")
            if stage_id in stage_ids:
                issues.append(issue("duplicate-stage", "error", campaign, stage_id, "stage id appears more than once."))
            stage_ids.add(stage_id)
            if runner not in VALID_RUNNERS:
                issues.append(issue("unknown-runner", "error", campaign, stage_id, f"unsupported runner: {runner or '-'}"))
                continue
            if bool(stage.get("required")):
                required_count += 1
            if bool(stage.get("packageEvidenceProfile")):
                package_profile_stage_ids.append(stage_id)
                if runner != "production-profile":
                    issues.append(issue("package-profile-runner-invalid", "error", campaign, stage_id, "packageEvidenceProfile can only be set on production-profile stages."))
            if bool(stage.get("packageEvidenceProductPlan")):
                package_product_plan_stage_ids.append(stage_id)
                if runner != "product-plan":
                    issues.append(issue("package-product-plan-runner-invalid", "error", campaign, stage_id, "packageEvidenceProductPlan can only be set on product-plan stages."))

            if runner == "campaign":
                ref = str(stage.get("campaign") or "")
                campaign_refs.add(ref)
                if ref == "non-large-group-release":
                    non_large_release_index = index
                    non_large_release_required = bool(stage.get("required"))
                if ref not in campaigns:
                    issues.append(issue("unknown-campaign", "error", campaign, stage_id, f"referenced campaign is not defined: {ref or '-'}"))

            if runner == "product-plan":
                product_plan_stages += 1
                stage_phases = stage_list(stage, "phases")
                if not stage_phases:
                    issues.append(issue("missing-phases", "error", campaign, stage_id, "product-plan stage must define phases."))
                for phase in stage_phases:
                    product_phases.add(phase)
                    if phase not in phases:
                        issues.append(issue("unknown-phase", "error", campaign, stage_id, f"phase is not listed by run_product_test_plan.sh: {phase}"))
                if stage_phases and all("large-group" not in phase for phase in stage_phases):
                    non_large_product_stages += 1

            if runner == "production-profile":
                profile_stages += 1
                profile = str(stage.get("profile") or "")
                profile_refs.add(profile)
                if profile not in profiles:
                    issues.append(issue("unknown-profile", "error", campaign, stage_id, f"profile is not in perf_production_profiles.json: {profile or '-'}"))
                if profile in {"normal-product-baseline", "normal-product-capacity", "product-breadth-baseline", "im-scenario-breadth-baseline", "non-large-group-baseline"}:
                    non_large_product_stages += 1

            if runner == "scenario-group":
                stage_groups = stage_list(stage, "scenarioGroups")
                if not stage_groups:
                    issues.append(issue("missing-scenario-groups", "error", campaign, stage_id, "scenario-group stage must define scenarioGroups."))
                for group in stage_groups:
                    scenario_group_refs.add(group)
                    if group not in group_set:
                        issues.append(issue("unknown-scenario-group", "error", campaign, stage_id, f"group is not listed by run_perf_scenarios.sh: {group}"))
                    if group == "large-group":
                        large_group_stages += 1
                        large_group_stage_indices.append(index)
                        if bool(stage.get("required")):
                            large_group_required_count += 1
                        if not bool(stage.get("isolated")):
                            issues.append(issue("large-group-not-isolated", "error", campaign, stage_id, "large-group scenario-group stages must set isolated=true."))

            if runner == "scenario":
                stage_scenarios = stage_list(stage, "scenarios")
                if not stage_scenarios:
                    issues.append(issue("missing-scenarios", "error", campaign, stage_id, "scenario stage must define scenarios."))
                for scenario in stage_scenarios:
                    if scenario not in scenario_set:
                        issues.append(issue("unknown-scenario", "error", campaign, stage_id, f"scenario is not listed by run_perf_scenarios.sh: {scenario}"))
                    if scenario.startswith("large-group-"):
                        large_group_stages += 1
                        large_group_stage_indices.append(index)
                        if bool(stage.get("required")):
                            large_group_required_count += 1
                        if not bool(stage.get("isolated")):
                            issues.append(issue("large-group-not-isolated", "error", campaign, stage_id, "large-group scenario stages must set isolated=true."))

        if campaign == "non-large-group-release" and large_group_stages:
            issues.append(issue("non-large-includes-large-group", "error", campaign, "-", "non-large-group-release must not include large-group stages."))
        if campaign == "non-large-group-release" and required_count != len(stages):
            issues.append(issue("non-large-stage-optional", "error", campaign, "-", "all non-large-group-release stages must be required."))
        if campaign == "non-large-group-release" and non_large_product_stages < 4:
            issues.append(issue("insufficient-product-breadth", "error", campaign, "-", "non-large-group-release must include multiple non-large product stages."))
        if campaign == "non-large-group-release" and "normal-product-baseline" not in profile_refs:
            issues.append(issue("non-large-missing-profile", "error", campaign, "-", "non-large-group-release must include the aggregate normal-product-baseline production profile."))
        if campaign == "product-scenario-regression" and large_group_stages:
            issues.append(issue("scenario-regression-includes-large-group", "error", campaign, "-", "product-scenario-regression must not include large-group stages."))
        if campaign == "product-scenario-regression" and product_plan_stages < 7:
            issues.append(issue("scenario-regression-insufficient-domains", "error", campaign, "-", "product-scenario-regression must keep separate product-plan stages for the main product domains."))
        if campaign == "product-scenario-regression" and required_count < 8:
            issues.append(issue("scenario-regression-stage-optional", "error", campaign, "-", "product-scenario-regression domain stages must be required; only the final aggregate profile may be optional."))
        if campaign == "product-scenario-regression" and bool_catalog(body.get("stopOnFailure"), True):
            issues.append(issue("scenario-regression-stop-on-failure", "error", campaign, "-", "product-scenario-regression must set stopOnFailure=false so later product domains still run after an early required failure."))
        if campaign == "product-scenario-regression" and "normal-product-baseline" not in profile_refs:
            issues.append(issue("scenario-regression-missing-profile", "error", campaign, "-", "product-scenario-regression must keep the optional aggregate normal-product-baseline profile for post-domain confirmation."))
        if campaign == "product-scenario-acceptance" and large_group_stages:
            issues.append(issue("scenario-acceptance-includes-large-group", "error", campaign, "-", "product-scenario-acceptance must not include isolated large-group stages."))
        if campaign == "product-scenario-acceptance" and required_count != len(stages):
            issues.append(issue("scenario-acceptance-stage-optional", "error", campaign, "-", "all product-scenario-acceptance stages must be required."))
        if campaign == "product-scenario-acceptance" and bool_catalog(body.get("stopOnFailure"), True):
            issues.append(issue("scenario-acceptance-stop-on-failure", "error", campaign, "-", "product-scenario-acceptance must set stopOnFailure=false so all product domains still report evidence after an early failure."))
        if campaign == "product-scenario-acceptance" and product_plan_stages < 8:
            issues.append(issue("scenario-acceptance-insufficient-domains", "error", campaign, "-", "product-scenario-acceptance must keep separate product-plan stages for daily, account/sync, message, group, social/media/governance, and realtime/recovery domains."))
        if campaign == "product-scenario-acceptance" and "normal-product-baseline" not in profile_refs:
            issues.append(issue("scenario-acceptance-missing-profile", "error", campaign, "-", "product-scenario-acceptance must include the aggregate normal-product-baseline production profile."))
        for kind, required_phases in (REQUIRED_PHASE_POLICIES.get(campaign) or {}).items():
            require_phases(issues, campaign, product_phases, required_phases, kind)
        if campaign == "production-acceptance" and large_group_stages == 0:
            issues.append(issue("missing-large-group-stage", "error", campaign, "-", "production-acceptance must include an isolated large-group stage."))
        if campaign == "production-acceptance" and large_group_stages != large_group_required_count:
            issues.append(issue("large-group-stage-optional", "error", campaign, "-", "production-acceptance large-group stages must be required."))
        if campaign == "production-acceptance" and "non-large-group-release" not in campaign_refs:
            issues.append(issue("missing-non-large-prereq", "error", campaign, "-", "production-acceptance must reference non-large-group-release before large-group stress."))
        if campaign == "production-acceptance" and non_large_release_index is not None and not non_large_release_required:
            issues.append(issue("non-large-prereq-optional", "error", campaign, "-", "production-acceptance non-large-group-release prerequisite must be required."))
        if campaign == "production-acceptance" and non_large_release_index is not None:
            if any(index < non_large_release_index for index in large_group_stage_indices):
                issues.append(issue("large-group-before-non-large", "error", campaign, "-", "production-acceptance must run non-large-group-release before large-group stress."))
        if campaign == "production-full-acceptance":
            if required_count != len(stages):
                issues.append(issue("full-acceptance-stage-optional", "error", campaign, "-", "all production-full-acceptance stages must be required."))
            if product_plan_stages < 1:
                issues.append(issue("full-acceptance-missing-product-plan", "error", campaign, "-", "production-full-acceptance must include a product-plan stage so final evidence has packageable product-plan artifacts."))
            if "normal-product-baseline" not in product_phases:
                issues.append(issue("full-acceptance-missing-product-plan-phase", "error", campaign, "-", "production-full-acceptance product-plan stage must include normal-product-baseline."))
            required_groups = {"normal-product-smoke", "message-workflow-baseline", "realtime-direct-baseline", "group-delivery-capacity", "large-group"}
            missing_groups = sorted(required_groups - scenario_group_refs)
            if missing_groups:
                issues.append(issue("full-acceptance-missing-groups", "error", campaign, "-", f"production-full-acceptance is missing required scenario groups: {', '.join(missing_groups)}"))
            required_profiles = {"normal-product-baseline", "normal-product-capacity"}
            missing_profiles = sorted(required_profiles - profile_refs)
            if missing_profiles:
                issues.append(issue("full-acceptance-missing-profiles", "error", campaign, "-", f"production-full-acceptance is missing required profiles: {', '.join(missing_profiles)}"))
            if large_group_stages != 1:
                issues.append(issue("full-acceptance-large-group-count", "error", campaign, "-", "production-full-acceptance must contain exactly one isolated large-group stage."))
            if large_group_stages != large_group_required_count:
                issues.append(issue("full-acceptance-large-group-optional", "error", campaign, "-", "production-full-acceptance large-group stage must be required."))
            if large_group_stage_indices and max(large_group_stage_indices) != len(stages):
                issues.append(issue("full-acceptance-large-group-not-last", "error", campaign, "-", "production-full-acceptance must run large-group stress last."))
            if package_profile_stage_ids != ["normal-product-baseline"]:
                issues.append(issue("full-acceptance-package-profile-stage", "error", campaign, "-", f"production-full-acceptance must package profile evidence from normal-product-baseline, got: {', '.join(package_profile_stage_ids) or '-'}"))
            if package_product_plan_stage_ids != ["normal-product-plan"]:
                issues.append(issue("full-acceptance-package-product-plan-stage", "error", campaign, "-", f"production-full-acceptance must package product-plan evidence from normal-product-plan, got: {', '.join(package_product_plan_stage_ids) or '-'}"))

        campaign_rows.append({
            "campaign": campaign,
            "stageCount": len(stages),
            "requiredCount": required_count,
            "largeGroupStages": large_group_stages,
            "productPlanStages": product_plan_stages,
            "profileStages": profile_stages,
            "packageProfileStages": len(package_profile_stage_ids),
            "packageProductPlanStages": len(package_product_plan_stage_ids),
            "requiredPhasePolicyCount": len(REQUIRED_PHASE_POLICIES.get(campaign) or {}),
        })

    error_count = sum(1 for item in issues if item["severity"] == "error")
    warning_count = sum(1 for item in issues if item["severity"] == "warning")
    return {
        "status": "PASS" if error_count == 0 else "FAIL",
        "campaignCatalog": str(campaign_path),
        "productPlanScript": str(product_plan_script),
        "profileCatalog": str(profile_catalog),
        "matrixScript": str(matrix_script),
        "inputs": {
            "campaignCatalog": input_metadata(campaign_path),
            "productPlanScript": input_metadata(product_plan_script),
            "profileCatalog": input_metadata(profile_catalog),
            "matrixScript": input_metadata(matrix_script),
        },
        "phaseCount": len(phases),
        "profileCount": len(profiles),
        "scenarioGroupCount": len(groups),
        "scenarioCount": len(scenarios),
        "campaignCount": len(campaign_rows),
        "requiredPhasePolicies": required_phase_policy_rows(),
        "errorCount": error_count,
        "warningCount": warning_count,
        "campaigns": campaign_rows,
        "issues": issues,
    }


def markdown_table(rows: list[list[str]]) -> str:
    if not rows:
        return ""
    lines = [
        "| " + " | ".join(rows[0]) + " |",
        "| " + " | ".join(["---"] * len(rows[0])) + " |",
    ]
    for row in rows[1:]:
        lines.append("| " + " | ".join(cell.replace("\n", " ") for cell in row) + " |")
    return "\n".join(lines)


def build_markdown(payload: dict[str, Any]) -> str:
    input_rows = [["Input", "Path", "SHA256"]]
    for name, record in sorted((payload.get("inputs") or {}).items()):
        input_rows.append([
            name,
            f"`{record.get('path') or '-'}`",
            f"`{record.get('sha256') or '-'}`",
        ])

    campaign_rows = [["Campaign", "Stages", "Required", "Large Group", "Product Plan", "Profiles", "Phase Policies"]]
    for row in payload["campaigns"]:
        campaign_rows.append([
            f"`{row['campaign']}`",
            str(row["stageCount"]),
            str(row["requiredCount"]),
            str(row["largeGroupStages"]),
            str(row["productPlanStages"]),
            str(row["profileStages"]),
            str(row.get("requiredPhasePolicyCount", 0)),
        ])

    policy_rows = [["Campaign", "Issue Kind", "Required Phases"]]
    for row in payload.get("requiredPhasePolicies") or []:
        policy_rows.append([
            f"`{row['campaign']}`",
            f"`{row['issueKind']}`",
            ", ".join(f"`{phase}`" for phase in row.get("requiredPhases") or []),
        ])

    issue_rows = [["Severity", "Kind", "Campaign", "Stage", "Detail"]]
    for row in payload["issues"]:
        issue_rows.append([
            row["severity"],
            row["kind"],
            f"`{row['campaign']}`",
            f"`{row['stage']}`",
            row["detail"],
        ])

    return "\n".join([
        "# Product Performance Campaign Audit",
        "",
        f"- status: `{payload['status']}`",
        f"- campaigns: `{payload['campaignCount']}`",
        f"- product phases: `{payload['phaseCount']}`",
        f"- production profiles: `{payload['profileCount']}`",
        f"- scenario groups/scenarios: `{payload['scenarioGroupCount']}/{payload['scenarioCount']}`",
        f"- errors/warnings: `{payload['errorCount']}/{payload['warningCount']}`",
        "",
        "## Inputs",
        "",
        markdown_table(input_rows),
        "",
        "## Campaigns",
        "",
        markdown_table(campaign_rows),
        "",
        "## Required Phase Policies",
        "",
        markdown_table(policy_rows),
        "",
        "## Issues",
        "",
        markdown_table(issue_rows) if payload["issues"] else "No product campaign catalog issues found.",
        "",
    ])


def verify_payload(payload: dict[str, Any]) -> None:
    if not isinstance(payload, dict):
        raise SystemExit("product_campaign_audit_verify result=fail reason=json_not_object")
    if payload.get("status") not in {"PASS", "FAIL"}:
        raise SystemExit("product_campaign_audit_verify result=fail reason=status")

    campaigns = payload.get("campaigns")
    if not isinstance(campaigns, list):
        raise SystemExit("product_campaign_audit_verify result=fail reason=campaigns_not_list")
    if int(payload.get("campaignCount") or 0) != len(campaigns):
        raise SystemExit("product_campaign_audit_verify result=fail reason=campaign_count_mismatch")

    issues = payload.get("issues")
    if not isinstance(issues, list):
        raise SystemExit("product_campaign_audit_verify result=fail reason=issues_not_list")
    error_count = sum(1 for row in issues if isinstance(row, dict) and row.get("severity") == "error")
    warning_count = sum(1 for row in issues if isinstance(row, dict) and row.get("severity") == "warning")
    if int(payload.get("errorCount") or 0) != error_count:
        raise SystemExit("product_campaign_audit_verify result=fail reason=error_count_mismatch")
    if int(payload.get("warningCount") or 0) != warning_count:
        raise SystemExit("product_campaign_audit_verify result=fail reason=warning_count_mismatch")
    if (payload.get("status") == "PASS") != (error_count == 0):
        raise SystemExit("product_campaign_audit_verify result=fail reason=status_count_mismatch")

    inputs = payload.get("inputs")
    if not isinstance(inputs, dict) or not inputs:
        raise SystemExit("product_campaign_audit_verify result=fail reason=inputs_missing")
    for name in ("campaignCatalog", "productPlanScript", "profileCatalog", "matrixScript"):
        record = inputs.get(name)
        if not isinstance(record, dict):
            raise SystemExit(f"product_campaign_audit_verify result=fail reason=input_missing input={name}")
        if not str(record.get("path") or ""):
            raise SystemExit(f"product_campaign_audit_verify result=fail reason=input_path_missing input={name}")
        sha = str(record.get("sha256") or "")
        if len(sha) != 64 or any(ch not in "0123456789abcdef" for ch in sha):
            raise SystemExit(f"product_campaign_audit_verify result=fail reason=input_sha_invalid input={name}")

    policies = payload.get("requiredPhasePolicies")
    if not isinstance(policies, list):
        raise SystemExit("product_campaign_audit_verify result=fail reason=required_phase_policies_not_list")
    seen_campaigns: set[str] = set()
    for row in campaigns:
        if not isinstance(row, dict):
            raise SystemExit("product_campaign_audit_verify result=fail reason=campaign_row_not_object")
        campaign = str(row.get("campaign") or "")
        if not campaign:
            raise SystemExit("product_campaign_audit_verify result=fail reason=campaign_name_missing")
        if campaign in seen_campaigns:
            raise SystemExit(f"product_campaign_audit_verify result=fail reason=duplicate_campaign campaign={campaign}")
        seen_campaigns.add(campaign)
        for key in (
            "stageCount",
            "requiredCount",
            "largeGroupStages",
            "productPlanStages",
            "profileStages",
            "requiredPhasePolicyCount",
        ):
            value = row.get(key)
            if not isinstance(value, int) or value < 0:
                raise SystemExit(f"product_campaign_audit_verify result=fail reason=campaign_{key} campaign={campaign}")

    for row in policies:
        if not isinstance(row, dict):
            raise SystemExit("product_campaign_audit_verify result=fail reason=required_phase_policy_row_not_object")
        campaign = str(row.get("campaign") or "")
        issue_kind = str(row.get("issueKind") or "")
        phases = row.get("requiredPhases")
        if not campaign or not issue_kind or not isinstance(phases, list) or not phases:
            raise SystemExit(f"product_campaign_audit_verify result=fail reason=required_phase_policy_invalid campaign={campaign or '-'}")
        if int(row.get("phaseCount") or 0) != len(phases):
            raise SystemExit(f"product_campaign_audit_verify result=fail reason=required_phase_policy_count_mismatch campaign={campaign}")


def verify_markdown(payload: dict[str, Any], markdown_path: Path) -> None:
    verify_payload(payload)
    if not markdown_path.is_file():
        raise SystemExit(f"product_campaign_audit_verify result=fail reason=markdown_missing path={markdown_path}")
    expected = build_markdown(payload)
    actual = markdown_path.read_text(encoding="utf-8")
    if actual != expected:
        raise SystemExit(f"product_campaign_audit_verify result=fail reason=markdown_mismatch path={markdown_path}")


def write_self_test_product_plan_script(path: Path) -> None:
    phases = sorted({
        phase
        for policies in REQUIRED_PHASE_POLICIES.values()
        for required_phases in policies.values()
        for phase in required_phases
    } | {"entrypoint", "normal-product-baseline"})
    lines = [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        'if [[ "${1:-}" == "--list-phases" ]]; then',
        '  echo "Available phases:"',
        *(f'  echo "  {phase} self-test"' for phase in phases),
        "  exit 0",
        "fi",
        "exit 0",
        "",
    ]
    path.write_text("\n".join(lines), encoding="utf-8")
    path.chmod(0o755)


def write_self_test_matrix_script(path: Path) -> None:
    lines = [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        'if [[ "${1:-}" == "--list" ]]; then',
        '  echo "Available scenario groups:"',
        '  echo "large-group"',
        '  echo "normal-product-smoke"',
        '  echo "Available scenarios:"',
        '  echo "large-group-1000-10"',
        '  echo "login-smoke"',
        "  exit 0",
        "fi",
        "exit 0",
        "",
    ]
    path.write_text("\n".join(lines), encoding="utf-8")
    path.chmod(0o755)


def base_self_test_campaign() -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "campaigns": {
            "non-large-group-release": {
                "description": "Self-test non-large release campaign.",
                "stages": [
                    {
                        "id": "real-world-smoke",
                        "runner": "product-plan",
                        "phases": ["real-world-smoke", "daily-core", "daily-traffic"],
                        "required": True,
                    },
                    {
                        "id": "workflow-domains",
                        "runner": "product-plan",
                        "phases": ["account-security", "sync-read", "direct-chat", "group-workflow"],
                        "required": True,
                    },
                    {
                        "id": "social-media",
                        "runner": "product-plan",
                        "phases": ["contacts-social", "media-ai-admin", "lifecycle-governance"],
                        "required": True,
                    },
                    {
                        "id": "realtime-recovery",
                        "runner": "product-plan",
                        "phases": ["message-spike", "realtime-direct", "group-delivery", "reliability-recovery"],
                        "required": True,
                    },
                    {
                        "id": "normal-product-baseline",
                        "runner": "production-profile",
                        "profile": "normal-product-baseline",
                        "required": True,
                    },
                ],
            }
        },
    }


def self_test_paths(root: Path) -> tuple[Path, Path, Path, Path]:
    campaigns = root / "perf_product_campaigns.json"
    product_plan = root / "run_product_test_plan.sh"
    profiles = root / "perf_production_profiles.json"
    matrix = root / "run_perf_scenarios.sh"
    write_json(campaigns, base_self_test_campaign())
    write_self_test_product_plan_script(product_plan)
    write_json(profiles, {"schemaVersion": 1, "profiles": {"normal-product-baseline": ["login-smoke"]}})
    write_self_test_matrix_script(matrix)
    return campaigns, product_plan, profiles, matrix


def expect_self_test_issue(payload: dict[str, Any], kind: str, label: str) -> None:
    kinds = {str(row.get("kind") or "") for row in payload.get("issues") or [] if isinstance(row, dict)}
    if payload.get("status") != "FAIL" or kind not in kinds:
        raise SystemExit(f"product_campaign_audit_self_test result=fail reason={label} status={payload.get('status')} kinds={sorted(kinds)}")


def expect_self_test_verify_failure(func: Any, label: str, expected: str) -> None:
    try:
        func()
    except SystemExit as exc:
        message = str(exc)
        if expected not in message:
            raise SystemExit(f"product_campaign_audit_self_test result=fail reason={label}_wrong_error error={message}") from exc
        return
    raise SystemExit(f"product_campaign_audit_self_test result=fail reason={label}_passed")


def run_self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="product-campaign-audit-self-test-") as raw_root:
        root = Path(raw_root)
        campaigns, product_plan, profiles, matrix = self_test_paths(root)
        payload = audit(campaigns, product_plan, profiles, matrix)
        if payload.get("status") != "PASS":
            raise SystemExit(f"product_campaign_audit_self_test result=fail reason=good_campaign_failed issues={payload.get('issues')}")
        verify_payload(payload)
        policies = payload.get("requiredPhasePolicies") or []
        if len(policies) < len(REQUIRED_PHASE_POLICIES):
            raise SystemExit("product_campaign_audit_self_test result=fail reason=required_phase_policies_missing")
        markdown_path = root / "product-campaign-audit.md"
        markdown_path.write_text(build_markdown(payload), encoding="utf-8")
        verify_markdown(payload, markdown_path)

        bad_md = root / "product-campaign-audit-bad.md"
        bad_md.write_text(markdown_path.read_text(encoding="utf-8").replace("- status: `PASS`", "- auditStatus: `PASS`"), encoding="utf-8")
        expect_self_test_verify_failure(
            lambda: verify_markdown(payload, bad_md),
            "self_test_markdown_mismatch",
            "markdown_mismatch",
        )

        missing_phase = base_self_test_campaign()
        stages = missing_phase["campaigns"]["non-large-group-release"]["stages"]
        stages[1]["phases"] = [phase for phase in stages[1]["phases"] if phase != "sync-read"]
        missing_phase_path = root / "missing-phase-campaigns.json"
        write_json(missing_phase_path, missing_phase)
        expect_self_test_issue(
            audit(missing_phase_path, product_plan, profiles, matrix),
            "non-large-missing-phases",
            "self_test_non_large_missing_phase_rejected",
        )

        large_group = base_self_test_campaign()
        large_group["campaigns"]["non-large-group-release"]["stages"].append({
            "id": "large-group",
            "runner": "scenario-group",
            "scenarioGroups": ["large-group"],
            "required": True,
            "isolated": True,
        })
        large_group_path = root / "large-group-campaigns.json"
        write_json(large_group_path, large_group)
        expect_self_test_issue(
            audit(large_group_path, product_plan, profiles, matrix),
            "non-large-includes-large-group",
            "self_test_non_large_large_group_rejected",
        )

        unknown_phase = base_self_test_campaign()
        unknown_phase["campaigns"]["non-large-group-release"]["stages"][0]["phases"].append("missing-phase")
        unknown_phase_path = root / "unknown-phase-campaigns.json"
        write_json(unknown_phase_path, unknown_phase)
        expect_self_test_issue(
            audit(unknown_phase_path, product_plan, profiles, matrix),
            "unknown-phase",
            "self_test_unknown_phase_rejected",
        )

    print("product_campaign_audit_self_test result=pass")


def write_csv(path: Path, rows: list[dict[str, str]]) -> None:
    fieldnames = ["severity", "kind", "campaign", "stage", "detail"]
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow({key: row.get(key, "") for key in fieldnames})


def main() -> int:
    parser = argparse.ArgumentParser(description="Audit product performance campaign definitions.")
    parser.add_argument("--campaigns", default=str(Path(__file__).with_name("perf_product_campaigns.json")))
    parser.add_argument("--product-plan-script", default=str(Path(__file__).with_name("run_product_test_plan.sh")))
    parser.add_argument("--profile-catalog", default=str(Path(__file__).with_name("perf_production_profiles.json")))
    parser.add_argument("--matrix-script", default=str(Path(__file__).with_name("run_perf_scenarios.sh")))
    parser.add_argument("--output")
    parser.add_argument("--json-output")
    parser.add_argument("--csv-output")
    parser.add_argument("--verify-json")
    parser.add_argument("--verify-md")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--strict", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        run_self_test()
        return 0

    if args.verify_json:
        payload = read_json(Path(args.verify_json))
        verify_payload(payload)
        if args.verify_md:
            verify_markdown(payload, Path(args.verify_md))
        return 1 if args.strict and payload["status"] != "PASS" else 0
    if args.verify_md:
        parser.error("--verify-md requires --verify-json")

    payload = audit(
        Path(args.campaigns),
        Path(args.product_plan_script),
        Path(args.profile_catalog),
        Path(args.matrix_script),
    )
    markdown = build_markdown(payload)
    if args.output:
        Path(args.output).write_text(markdown, encoding="utf-8")
    else:
        print(markdown)
    if args.json_output:
        Path(args.json_output).write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    if args.csv_output:
        write_csv(Path(args.csv_output), payload["issues"])
    if args.output:
        verify_markdown(payload, Path(args.output))
    return 1 if args.strict and payload["status"] != "PASS" else 0


if __name__ == "__main__":
    raise SystemExit(main())
