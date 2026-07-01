#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ipaddress
import json
import shlex
import sys
import tempfile
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
from run_product_campaign import build_runbook

PRODUCTION_GATE_CAMPAIGNS = {"non-large-group-release", "production-acceptance", "production-full-acceptance"}

PROFILE_EVIDENCE_FILES = {
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
    "production-profile-scenario-catalog.json",
}

PRODUCT_PLAN_EVIDENCE_FILES = {
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

REQUIRED_PRODUCT_DOMAINS = {
    "account-security",
    "sync-read",
    "direct-chat",
    "group-workflow",
    "contacts-social",
    "media-ai-admin",
    "reliability-recovery",
    "realtime-direct",
}


def read_json(path: Path) -> dict[str, Any]:
    try:
        with path.open(encoding="utf-8") as handle:
            return json.load(handle)
    except Exception as exc:
        raise SystemExit(f"product_campaign_artifacts result=fail reason=json_read_failed path={path} error={exc}") from exc


def fail(reason: str, **fields: Any) -> None:
    details = " ".join(f"{key}={value}" for key, value in fields.items())
    message = f"product_campaign_artifacts result=fail reason={reason}"
    if details:
        message = f"{message} {details}"
    raise SystemExit(message)


def require_file(path: Path, reason: str) -> None:
    if not path.is_file():
        fail(reason, path=path)


def require_dir(path: Path, reason: str) -> None:
    if not path.is_dir():
        fail(reason, path=path)


def resolve_artifact_path(run_json: Path, raw: str) -> Path:
    path = Path(raw).expanduser()
    if not path.is_absolute():
        path = run_json.parent / path
    return path


def command_assignment(command: str, name: str) -> str | None:
    try:
        parts = shlex.split(command)
    except ValueError:
        return None
    prefix = f"{name}="
    for part in parts:
        if part.startswith(prefix):
            return part[len(prefix):]
    return None


def require_secret_redacted(command: str, stage: str) -> None:
    value = command_assignment(command, "IM_INTERNAL_SECRET")
    allowed = {
        "",
        "<redacted>",
        "<set-in-shell-when-required>",
        "${IM_INTERNAL_SECRET:?set-IM_INTERNAL_SECRET}",
        "${IM_INTERNAL_SHARED_SECRET:-${IM_INTERNAL_SECRET:?set-IM_INTERNAL_SECRET}}",
    }
    if value is None or value in allowed:
        return
    fail("stage_command_secret_not_redacted", stage=stage or "-", value=value[:8])


def require_campaign_target(payload: dict[str, Any], *, require_complete: bool) -> dict[str, str]:
    target = payload.get("target")
    if not isinstance(target, dict):
        if require_complete:
            fail("campaign_target_missing")
        return {}
    result = {
        "BASE_URL": str(target.get("baseURL") or ""),
        "TCP_HOST": str(target.get("tcpHost") or ""),
        "TCP_PORT": str(target.get("tcpPort") or ""),
    }
    if require_complete:
        missing = [name for name, value in result.items() if not value]
        if missing:
            fail("campaign_target_incomplete", fields=",".join(missing))
    return result


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
    if value.endswith(("example.com", "example.net", "example.org", ".test", ".invalid")):
        return "placeholder"
    return ""


def require_public_campaign_target(target: dict[str, str]) -> None:
    base_url = str(target.get("BASE_URL") or "")
    parsed = urlparse(base_url)
    if parsed.scheme != "https":
        fail("campaign_target_base_url_https_required", baseURL=base_url or "<empty>")
    base_host = parsed.hostname or ""
    base_reason = public_host_reason(base_host)
    if base_reason:
        fail("campaign_target_base_url_domain_required", host=base_host or "<none>", hostReason=base_reason)
    tcp_host = str(target.get("TCP_HOST") or "")
    tcp_reason = public_host_reason(tcp_host)
    if tcp_reason:
        fail("campaign_target_tcp_host_domain_required", tcpHost=tcp_host or "<none>", hostReason=tcp_reason)
    tcp_port = str(target.get("TCP_PORT") or "")
    if not tcp_port.isdigit() or int(tcp_port) <= 0:
        fail("campaign_target_tcp_port_invalid", tcpPort=tcp_port or "<empty>")


def require_stage_target_matches(command: str, stage: str, target: dict[str, str], *, require_complete: bool) -> None:
    for name, expected in target.items():
        if not expected:
            continue
        actual = command_assignment(command, name)
        if actual is None:
            if require_complete:
                fail("stage_command_target_missing", stage=stage or "-", field=name)
            continue
        if actual != expected:
            fail("stage_command_target_mismatch", stage=stage or "-", field=name, expected=expected, actual=actual)


def int_field(payload: dict[str, Any], key: str) -> int:
    try:
        return int(payload.get(key))
    except Exception:
        fail("run_count_field_invalid", field=key, value=payload.get(key))


def require_product_plan_preview_evidence(evidence_dir: Path, campaign: str) -> None:
    preview_path = evidence_dir / "product-test-plan-preview.json"
    require_file(preview_path, "materialized_product_plan_preview_missing")
    preview = read_json(preview_path)
    summary = preview.get("summary") or {}
    try:
        scenario_count = int(summary.get("uniqueScenarioCount") or 0)
    except Exception:
        fail("materialized_product_plan_scenario_count_invalid", campaign=campaign, value=summary.get("uniqueScenarioCount"))
    if scenario_count <= 0:
        fail("materialized_product_plan_empty", campaign=campaign)
    if summary.get("largeGroupIncluded") is not False:
        fail("materialized_product_plan_includes_large_group", campaign=campaign, value=summary.get("largeGroupIncluded"))
    covered = {str(item) for item in (summary.get("coveredProductDomains") or []) if str(item)}
    missing = {str(item) for item in (summary.get("missingProductDomains") or []) if str(item)}
    if summary.get("requiredProductDomainsCovered") is not True:
        fail("materialized_product_plan_required_domains_not_covered", campaign=campaign)
    missing_required = sorted(REQUIRED_PRODUCT_DOMAINS - covered)
    if missing_required:
        fail("materialized_product_plan_domain_missing", campaign=campaign, domains=",".join(missing_required))
    if missing:
        fail("materialized_product_plan_missing_domains_nonempty", campaign=campaign, domains=",".join(sorted(missing)))


def require_production_acceptance_runtime_order(payload: dict[str, Any]) -> None:
    stages = payload.get("stages") or []
    non_large_index: int | None = None
    large_group_indices: list[int] = []
    for index, row in enumerate(stages, start=1):
        if not isinstance(row, dict):
            continue
        stage_id = str(row.get("id") or "")
        runner = str(row.get("runner") or "")
        command = str(row.get("command") or "")
        if stage_id == "non-large-group-release" and runner == "campaign":
            non_large_index = index
            if str(row.get("status") or "") != "PASS":
                fail("production_acceptance_non_large_not_pass", status=row.get("status") or "-")
        if "SCENARIO_GROUPS=large-group" in command or stage_id.startswith("large-group"):
            large_group_indices.append(index)
            if row.get("isolated") is not True:
                fail("production_acceptance_large_group_not_isolated", stage=stage_id or "-")
            if str(row.get("status") or "") != "PASS":
                fail("production_acceptance_large_group_not_pass", stage=stage_id or "-", status=row.get("status") or "-")
    if non_large_index is None:
        fail("production_acceptance_non_large_stage_missing")
    if not large_group_indices:
        fail("production_acceptance_large_group_stage_missing")
    if any(index < non_large_index for index in large_group_indices):
        fail("production_acceptance_large_group_before_non_large")


def require_production_full_acceptance_runtime_order(payload: dict[str, Any]) -> None:
    stages = payload.get("stages") or []
    required_pass_stages = {
        "normal-product-smoke",
        "normal-product-plan",
        "normal-product-baseline",
        "normal-product-capacity",
        "message-realtime-capacity",
        "large-group-isolated",
    }
    seen: set[str] = set()
    large_group_indices: list[int] = []
    for index, row in enumerate(stages, start=1):
        if not isinstance(row, dict):
            continue
        stage_id = str(row.get("id") or "")
        seen.add(stage_id)
        if stage_id in required_pass_stages and str(row.get("status") or "") != "PASS":
            fail("production_full_acceptance_stage_not_pass", stage=stage_id or "-", status=row.get("status") or "-")
        command = str(row.get("command") or "")
        if stage_id == "large-group-isolated" or "SCENARIO_GROUPS=large-group" in command:
            large_group_indices.append(index)
            if row.get("isolated") is not True:
                fail("production_full_acceptance_large_group_not_isolated", stage=stage_id or "-")
    missing = sorted(required_pass_stages - seen)
    if missing:
        fail("production_full_acceptance_stage_missing", stages=",".join(missing))
    if len(large_group_indices) != 1:
        fail("production_full_acceptance_large_group_count", count=len(large_group_indices))
    if large_group_indices and large_group_indices[0] != len(stages):
        fail("production_full_acceptance_large_group_not_last")


def expected_packaged_stage_ids(campaign: str, catalog_path: Path) -> tuple[str, str]:
    catalog = read_json(catalog_path)
    campaigns = catalog.get("campaigns") or {}
    expected_campaign = campaigns.get(campaign)
    if not isinstance(expected_campaign, dict):
        fail("campaign_catalog_missing_campaign", campaign=campaign, catalog=catalog_path)
    profile_ids: list[str] = []
    product_plan_ids: list[str] = []
    for row in expected_campaign.get("stages") or []:
        if not isinstance(row, dict):
            continue
        stage_id = str(row.get("id") or "")
        if row.get("packageEvidenceProfile") is True:
            profile_ids.append(stage_id)
        if row.get("packageEvidenceProductPlan") is True:
            product_plan_ids.append(stage_id)
    if len(profile_ids) > 1:
        fail("campaign_package_profile_stage_ambiguous", campaign=campaign, stages=",".join(profile_ids))
    if len(product_plan_ids) > 1:
        fail("campaign_package_product_plan_stage_ambiguous", campaign=campaign, stages=",".join(product_plan_ids))
    return (profile_ids[0] if profile_ids else "", product_plan_ids[0] if product_plan_ids else "")


def require_materialized_evidence(payload: dict[str, Any], campaign: str, evidence_dir: Path, catalog_path: Path) -> None:
    if campaign not in PRODUCTION_GATE_CAMPAIGNS:
        return
    evidence_root = payload.get("evidenceRoot")
    if not isinstance(evidence_root, dict):
        fail("materialized_evidence_missing", campaign=campaign)
    if evidence_root.get("enabled") is False:
        fail("materialized_evidence_disabled", campaign=campaign)
    missing = evidence_root.get("missing") or []
    if missing:
        fail("materialized_evidence_incomplete", campaign=campaign, missing=",".join(str(item) for item in missing))
    if not str(evidence_root.get("profileSourceDir") or ""):
        fail("materialized_profile_source_missing", campaign=campaign)
    if not str(evidence_root.get("productPlanSourceDir") or ""):
        fail("materialized_product_plan_source_missing", campaign=campaign)
    expected_profile_stage, expected_product_plan_stage = expected_packaged_stage_ids(campaign, catalog_path)
    if expected_profile_stage and str(evidence_root.get("profileStageID") or "") != expected_profile_stage:
        fail(
            "materialized_profile_stage_mismatch",
            campaign=campaign,
            expected=expected_profile_stage,
            actual=evidence_root.get("profileStageID") or "-",
        )
    if expected_product_plan_stage and str(evidence_root.get("productPlanStageID") or "") != expected_product_plan_stage:
        fail(
            "materialized_product_plan_stage_mismatch",
            campaign=campaign,
            expected=expected_product_plan_stage,
            actual=evidence_root.get("productPlanStageID") or "-",
        )
    profile_files = {str(item) for item in (evidence_root.get("profileFilesCopied") or [])}
    missing_profile = sorted(PROFILE_EVIDENCE_FILES - profile_files)
    if missing_profile:
        fail("materialized_profile_files_missing", campaign=campaign, files=",".join(missing_profile))
    missing_profile_paths = sorted(name for name in PROFILE_EVIDENCE_FILES if not (evidence_dir / name).is_file())
    if missing_profile_paths:
        fail("materialized_profile_root_files_missing", campaign=campaign, files=",".join(missing_profile_paths))
    product_plan_files = {str(item) for item in (evidence_root.get("productPlanFilesCopied") or [])}
    missing_product_plan = sorted(PRODUCT_PLAN_EVIDENCE_FILES - product_plan_files)
    if missing_product_plan:
        fail("materialized_product_plan_files_missing", campaign=campaign, files=",".join(missing_product_plan))
    missing_product_plan_paths = sorted(name for name in PRODUCT_PLAN_EVIDENCE_FILES if not (evidence_dir / name).is_file())
    if missing_product_plan_paths:
        fail("materialized_product_plan_root_files_missing", campaign=campaign, files=",".join(missing_product_plan_paths))
    require_product_plan_preview_evidence(evidence_dir, campaign)


def require_catalog_alignment(payload: dict[str, Any], campaign: str, catalog_path: Path) -> None:
    if campaign not in PRODUCTION_GATE_CAMPAIGNS:
        return
    catalog = read_json(catalog_path)
    campaigns = catalog.get("campaigns") or {}
    expected_campaign = campaigns.get(campaign)
    if not isinstance(expected_campaign, dict):
        fail("campaign_catalog_missing_campaign", campaign=campaign, catalog=catalog_path)
    expected_stages = expected_campaign.get("stages") or []
    if not isinstance(expected_stages, list) or not expected_stages:
        fail("campaign_catalog_empty", campaign=campaign, catalog=catalog_path)
    actual_stages = payload.get("stages") or []
    expected_ids = [str(row.get("id") or "") for row in expected_stages if isinstance(row, dict)]
    actual_ids = [str(row.get("id") or "") for row in actual_stages if isinstance(row, dict)]
    if actual_ids != expected_ids:
        fail("campaign_stage_sequence_mismatch", campaign=campaign, expected=",".join(expected_ids), actual=",".join(actual_ids))
    for expected, actual in zip(expected_stages, actual_stages):
        if not isinstance(expected, dict) or not isinstance(actual, dict):
            fail("campaign_stage_record_invalid", campaign=campaign)
        stage_id = str(expected.get("id") or "")
        for key in ("runner", "required", "isolated"):
            expected_value = expected.get(key)
            actual_value = actual.get(key)
            if key == "isolated" and expected_value is None and actual_value in {None, False}:
                continue
            if expected_value != actual_value:
                fail("campaign_stage_catalog_mismatch", campaign=campaign, stage=stage_id, field=key, expected=expected_value, actual=actual_value)
        for key in ("packageEvidenceProfile", "packageEvidenceProductPlan"):
            expected_value = bool(expected.get(key))
            actual_value = bool(actual.get(key))
            if expected_value != actual_value:
                fail("campaign_stage_catalog_mismatch", campaign=campaign, stage=stage_id, field=key, expected=expected_value, actual=actual_value)


def stage_run_dir(run_json: Path, row: dict[str, Any]) -> Path:
    raw = str(row.get("runDir") or "")
    if not raw:
        fail("stage_run_dir_missing", stage=row.get("id") or "-")
    path = Path(raw)
    if not path.is_absolute():
        path = run_json.parent / path
    return path


def require_rescue_artifact(run_json: Path, row: dict[str, Any]) -> dict[str, str] | None:
    rescue = row.get("rescueArtifact")
    if rescue is None or rescue == "":
        return None
    stage = str(row.get("id") or "-")
    if not isinstance(rescue, dict):
        fail("rescue_artifact_invalid", stage=stage)
    if str(rescue.get("status") or "") != "PASS":
        fail("rescue_artifact_status_invalid", stage=stage, status=rescue.get("status") or "-")
    required_fields = ("rescuePlanAction", "entrypointDiagnosis", "dir", "summary", "verifyScript")
    for field in required_fields:
        if not str(rescue.get(field) or ""):
            fail("rescue_artifact_field_missing", stage=stage, field=field)

    artifact_dir = resolve_artifact_path(run_json, str(rescue.get("dir") or ""))
    require_dir(artifact_dir, "rescue_artifact_dir_missing")
    summary_path = resolve_artifact_path(run_json, str(rescue.get("summary") or ""))
    require_file(summary_path, "rescue_artifact_summary_missing")
    verify_script = resolve_artifact_path(run_json, str(rescue.get("verifyScript") or ""))
    require_file(verify_script, "rescue_artifact_verify_missing")

    tarball = str(rescue.get("tarball") or "")
    if tarball:
        require_file(resolve_artifact_path(run_json, tarball), "rescue_artifact_tarball_missing")
    package_verify = str(rescue.get("packageVerifyScript") or "")
    if package_verify:
        require_file(resolve_artifact_path(run_json, package_verify), "rescue_artifact_package_verify_missing")

    return {
        "stage": stage,
        "action": str(rescue.get("rescuePlanAction") or ""),
        "diagnosis": str(rescue.get("entrypointDiagnosis") or ""),
        "dir": str(rescue.get("dir") or ""),
        "tarball": tarball,
    }


def require_portable_stage_log(run_json: Path, row: dict[str, Any]) -> None:
    stage = str(row.get("id") or "-")
    raw_run_dir = str(row.get("runDir") or "")
    raw_log = str(row.get("log") or "")
    if raw_run_dir != ".":
        fail("stage_run_dir_not_portable", stage=stage, runDir=raw_run_dir or "-")
    if not raw_log:
        fail("stage_log_missing", stage=stage)
    log_path = Path(raw_log)
    if log_path.is_absolute() or ".." in log_path.parts or len(log_path.parts) != 1:
        fail("stage_log_not_portable", stage=stage, log=raw_log)
    if not log_path.name.startswith("product-campaign-stage-") or log_path.suffix != ".log":
        fail("stage_log_not_materialized", stage=stage, log=raw_log)
    require_file(run_json.parent / log_path.name, "stage_log_missing")


def verify(args: argparse.Namespace) -> None:
    run_json: Path = args.campaign_run_json
    payload = read_json(run_json)

    if payload.get("schemaVersion") != 1:
        fail("run_schema_version_invalid", value=payload.get("schemaVersion"))
    campaign = str(payload.get("campaign") or "")
    if not campaign:
        fail("campaign_missing")
    if getattr(args, "require_production_gate_campaign", False) and campaign not in PRODUCTION_GATE_CAMPAIGNS:
        fail(
            "campaign_not_production_gate",
            campaign=campaign,
            allowed=",".join(sorted(PRODUCTION_GATE_CAMPAIGNS)),
        )
    final_status = str(payload.get("finalStatus") or "")
    allowed_status = {"PLANNED", "PASS", "FAIL", "PASS_WITH_OPTIONAL_FAILURES"}
    if final_status not in allowed_status:
        fail("run_status_invalid", status=final_status or "-")
    if args.require_pass and final_status != "PASS":
        fail("campaign_not_pass", status=final_status or "-")
    if args.require_pass and not bool(payload.get("execute")):
        fail("campaign_not_executed")
    if final_status == "PLANNED" and not args.allow_planned:
        fail("campaign_is_planned")
    if bool(payload.get("execute")) and final_status == "PLANNED":
        fail("executed_campaign_planned")
    if final_status == "PASS" and int(payload.get("requiredFailureCount") or 0) != 0:
        fail("passed_campaign_has_required_failures", count=payload.get("requiredFailureCount"))
    target = require_campaign_target(payload, require_complete=bool(args.require_pass))
    if args.require_pass and args.require_production_gate_campaign:
        require_public_campaign_target(target)
    if args.require_pass and final_status == "PASS":
        campaigns_path = getattr(args, "campaigns", Path(__file__).with_name("perf_product_campaigns.json"))
        require_catalog_alignment(payload, campaign, campaigns_path)
        if campaign == "production-acceptance":
            require_production_acceptance_runtime_order(payload)
        if campaign == "production-full-acceptance":
            require_production_full_acceptance_runtime_order(payload)
        require_materialized_evidence(payload, campaign, run_json.parent, campaigns_path)

    stages = payload.get("stages") or []
    if not isinstance(stages, list) or not stages:
        fail("stages_missing")
    if int_field(payload, "stageCount") != len(stages):
        fail("stage_count_mismatch", recorded=payload.get("stageCount"), actual=len(stages))

    required_count = 0
    failed_count = 0
    required_failed_count = 0
    attempted_count = 0
    skipped_count = 0
    rescue_rows: list[dict[str, str]] = []
    for index, row in enumerate(stages, start=1):
        if not isinstance(row, dict):
            fail("stage_record_invalid", index=index)
        stage_id = str(row.get("id") or "")
        runner = str(row.get("runner") or "")
        status = str(row.get("status") or "")
        command = str(row.get("command") or "")
        required = bool(row.get("required"))
        if required:
            required_count += 1
        if status == "FAIL":
            failed_count += 1
            if required:
                required_failed_count += 1
        if status in {"PASS", "FAIL"}:
            attempted_count += 1
        if status == "SKIPPED":
            skipped_count += 1
        if not stage_id:
            fail("stage_id_missing", index=index)
        if runner not in {"campaign", "product-plan", "production-profile", "scenario-group", "scenario"}:
            fail("stage_runner_invalid", stage=stage_id or "-", runner=runner or "-")
        if status not in {"PLANNED", "PASS", "FAIL", "SKIPPED"}:
            fail("stage_status_invalid", stage=stage_id or "-", status=status or "-")
        if not command:
            fail("stage_command_missing", stage=stage_id or "-")
        require_secret_redacted(command, stage_id)
        require_stage_target_matches(command, stage_id, target, require_complete=bool(args.require_pass))
        if final_status == "PASS" and required and status != "PASS":
            fail("required_stage_not_pass", stage=stage_id, status=status or "-")
        if final_status == "PLANNED" and status != "PLANNED":
            fail("planned_campaign_has_runtime_stage", stage=stage_id, status=status or "-")
        if status == "SKIPPED" and str(row.get("skipReason") or "") != "stopped_after_required_failure":
            fail("skipped_stage_reason_invalid", stage=stage_id, reason=row.get("skipReason") or "-")
        if status == "SKIPPED" and row.get("returnCode") is not None:
            fail("skipped_stage_return_code_present", stage=stage_id)
        if status == "SKIPPED" and not bool(payload.get("execute")):
            fail("planned_campaign_has_skipped_stage", stage=stage_id)
        if runner == "scenario-group" and "SCENARIO_GROUPS=large-group" in command and not bool(row.get("isolated")):
            fail("large_group_stage_not_isolated", stage=stage_id)
        rescue_row = require_rescue_artifact(run_json, row)
        if rescue_row is not None:
            rescue_rows.append(rescue_row)
        if bool(payload.get("execute")) and status in {"PASS", "FAIL"}:
            if getattr(args, "require_portable_stage_logs", False):
                require_portable_stage_log(run_json, row)
            run_dir = stage_run_dir(run_json, row)
            require_dir(run_dir, "stage_run_dir_missing")
            log_path = Path(str(row.get("log") or ""))
            if not str(log_path):
                fail("stage_log_missing", stage=stage_id)
            if not log_path.is_absolute():
                log_path = run_json.parent / log_path
            require_file(log_path, "stage_log_missing")
            if run_dir not in [log_path, *log_path.parents]:
                fail("stage_log_outside_run_dir", stage=stage_id, log=log_path, runDir=run_dir)
            if status == "PASS" and row.get("returnCode") != 0:
                fail("passed_stage_return_code_invalid", stage=stage_id, returnCode=row.get("returnCode"))
            if status == "FAIL" and row.get("returnCode") in {None, 0}:
                fail("failed_stage_return_code_invalid", stage=stage_id, returnCode=row.get("returnCode"))

    if required_count <= 0:
        fail("required_stage_missing")
    if int_field(payload, "failureCount") != failed_count:
        fail("failure_count_mismatch", recorded=payload.get("failureCount"), actual=failed_count)
    if int_field(payload, "requiredFailureCount") != required_failed_count:
        fail("required_failure_count_mismatch", recorded=payload.get("requiredFailureCount"), actual=required_failed_count)
    if int_field(payload, "attemptedStageCount") != attempted_count:
        fail("attempted_stage_count_mismatch", recorded=payload.get("attemptedStageCount"), actual=attempted_count)
    if int_field(payload, "skippedStageCount") != skipped_count:
        fail("skipped_stage_count_mismatch", recorded=payload.get("skippedStageCount"), actual=skipped_count)
    if final_status == "PASS" and (failed_count != 0 or skipped_count != 0):
        fail("passed_campaign_has_failed_or_skipped_stages", failures=failed_count, skipped=skipped_count)
    if final_status == "PASS_WITH_OPTIONAL_FAILURES" and required_failed_count != 0:
        fail("optional_failure_status_has_required_failures", requiredFailures=required_failed_count)
    if final_status == "FAIL" and failed_count == 0:
        fail("failed_campaign_without_failed_stage")

    runbook = args.runbook
    if runbook is not None:
        require_file(runbook, "runbook_missing")
        text = runbook.read_text(encoding="utf-8", errors="replace")
        if campaign not in text:
            fail("runbook_campaign_missing", campaign=campaign)
        if str(payload.get("resultDir") or "") not in text:
            fail("runbook_result_dir_missing")
        if "Secret values are represented as shell placeholders" not in text:
            fail("runbook_redaction_note_missing")
        if args.require_pass:
            for value in target.values():
                if value and value not in text:
                    fail("runbook_target_missing", value=value)
        if rescue_rows:
            if "## Entrypoint Rescue" not in text:
                fail("runbook_rescue_section_missing")
            for rescue in rescue_rows:
                for field in ("stage", "action", "diagnosis", "dir"):
                    value = rescue.get(field) or ""
                    if value and value not in text:
                        fail("runbook_rescue_field_missing", field=field, value=value)
                tarball = rescue.get("tarball") or ""
                if tarball and tarball not in text:
                    fail("runbook_rescue_field_missing", field="tarball", value=tarball)
        expected = build_runbook(payload)
        if text != expected:
            fail("runbook_markdown_mismatch", runbook=runbook)

    print(
        "product_campaign_artifacts result=pass "
        f"campaign={campaign} status={final_status} stages={len(stages)} required={required_count}"
    )


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")


def base_self_test_campaign(root: Path) -> tuple[Path, dict[str, Any]]:
    stage_dir = root / "stage-product-plan"
    stage_dir.mkdir(parents=True)
    log_path = stage_dir / "product-campaign-stage-product-plan.log"
    log_path.write_text("stage passed\n", encoding="utf-8")
    target = {
        "baseURL": "https://chat.example.internal",
        "tcpHost": "tcp.chat.example.internal",
        "tcpPort": "9000",
    }
    command = (
        "BASE_URL=https://chat.example.internal "
        "TCP_HOST=tcp.chat.example.internal "
        "TCP_PORT=9000 "
        "./run_product_test_plan.sh"
    )
    payload = {
        "schemaVersion": 1,
        "campaign": "self-test-campaign",
        "finalStatus": "PASS",
        "execute": True,
        "target": target,
        "resultDir": str(root),
        "stageCount": 1,
        "failureCount": 0,
        "requiredFailureCount": 0,
        "attemptedStageCount": 1,
        "skippedStageCount": 0,
        "stages": [
            {
                "id": "product-plan",
                "runner": "product-plan",
                "required": True,
                "isolated": False,
                "status": "PASS",
                "command": command,
                "runDir": str(stage_dir),
                "log": str(log_path),
                "returnCode": 0,
            }
        ],
    }
    run_path = root / "product-campaign-run.json"
    write_json(run_path, payload)
    return run_path, payload


def self_test_args(run_path: Path) -> argparse.Namespace:
    return argparse.Namespace(
        campaign_run_json=run_path,
        runbook=None,
        campaigns=Path(__file__).with_name("perf_product_campaigns.json"),
        allow_planned=False,
        require_pass=True,
        require_production_gate_campaign=False,
        require_portable_stage_logs=False,
    )


def expect_self_test_failure(label: str, action: Any, expected_reason: str) -> None:
    try:
        action()
    except SystemExit as exc:
        message = str(exc)
        if expected_reason not in message:
            raise SystemExit(f"{label}_wrong_failure reason={message}") from exc
        return
    raise SystemExit(f"{label}_did_not_fail")


def run_self_test() -> None:
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        run_path, payload = base_self_test_campaign(root)
        verify(self_test_args(run_path))

        bad_count = json.loads(json.dumps(payload))
        bad_count["stageCount"] = 2
        bad_count_path = root / "product-campaign-run-bad-count.json"
        write_json(bad_count_path, bad_count)
        expect_self_test_failure(
            "self_test_stage_count_mismatch",
            lambda: verify(self_test_args(bad_count_path)),
            "stage_count_mismatch",
        )

        bad_secret = json.loads(json.dumps(payload))
        bad_secret["stages"][0]["command"] = (
            "IM_INTERNAL_SECRET=plain-text-secret "
            "BASE_URL=https://chat.example.internal "
            "TCP_HOST=tcp.chat.example.internal "
            "TCP_PORT=9000 "
            "./run_product_test_plan.sh"
        )
        bad_secret_path = root / "product-campaign-run-secret.json"
        write_json(bad_secret_path, bad_secret)
        expect_self_test_failure(
            "self_test_stage_command_secret_not_redacted",
            lambda: verify(self_test_args(bad_secret_path)),
            "stage_command_secret_not_redacted",
        )

        bad_large_group = json.loads(json.dumps(payload))
        bad_large_group["stages"][0]["id"] = "large-group"
        bad_large_group["stages"][0]["runner"] = "scenario-group"
        bad_large_group["stages"][0]["isolated"] = False
        bad_large_group["stages"][0]["command"] = (
            "BASE_URL=https://chat.example.internal "
            "TCP_HOST=tcp.chat.example.internal "
            "TCP_PORT=9000 "
            "SCENARIO_GROUPS=large-group ./run_perf_scenarios.sh"
        )
        bad_large_group_path = root / "product-campaign-run-large-group.json"
        write_json(bad_large_group_path, bad_large_group)
        expect_self_test_failure(
            "self_test_large_group_stage_not_isolated",
            lambda: verify(self_test_args(bad_large_group_path)),
            "large_group_stage_not_isolated",
        )
    print("product_campaign_artifacts_self_test result=pass")


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify product campaign run artifacts.")
    parser.add_argument("--campaign-run-json", type=Path)
    parser.add_argument("--runbook", type=Path)
    parser.add_argument("--campaigns", type=Path, default=Path(__file__).with_name("perf_product_campaigns.json"))
    parser.add_argument("--allow-planned", action="store_true")
    parser.add_argument("--require-pass", action="store_true")
    parser.add_argument("--require-production-gate-campaign", action="store_true")
    parser.add_argument("--require-portable-stage-logs", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        run_self_test()
        return 0
    if args.campaign_run_json is None:
        parser.error("--campaign-run-json is required unless --self-test is used")
    verify(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
