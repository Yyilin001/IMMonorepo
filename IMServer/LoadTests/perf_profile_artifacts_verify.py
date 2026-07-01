#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ipaddress
import json
import re
import shlex
import sys
import tempfile
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from perf_production_profile_runbook import verify_markdown as verify_profile_runbook_markdown


def read_json(path: Path) -> dict[str, Any]:
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def fail(reason: str, **fields: Any) -> None:
    details = " ".join(f"{key}={value}" for key, value in fields.items())
    message = f"profile_artifacts result=fail reason={reason}"
    if details:
        message = f"{message} {details}"
    raise SystemExit(message)


def require_int(value: Any, field: str) -> int:
    if value is None:
        fail("profile_run_missing_count", field=field)
    try:
        return int(value)
    except (TypeError, ValueError):
        fail("profile_run_invalid_count", field=field, value=value)


ASSIGNMENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")


def command_assignment(command: str, name: str) -> str | None:
    try:
        parts = shlex.split(command)
    except ValueError as exc:
        fail("profile_runbook_batch_command_parse_error", error=str(exc))
    prefix = f"{name}="
    for part in parts:
        if part.startswith(prefix):
            return part[len(prefix):]
        if not ASSIGNMENT_RE.match(part):
            break
    return None


def command_scenarios(command: str, batch: int) -> list[str]:
    value = command_assignment(command, "SCENARIOS")
    if value is None:
        fail("profile_runbook_batch_command_scenarios_missing", batch=batch)
    return [item for item in value.split() if item]


def require_command_assignment(command: str, name: str, expected: str, reason: str, **fields: Any) -> None:
    actual = command_assignment(command, name)
    if actual != expected:
        fail(reason, expected=expected or "-", actual=actual or "-", **fields)


def require_required_env_assignment(command: str, name: str, reason: str) -> None:
    expected = f"${{{name}:?set-{name}}}"
    require_command_assignment(command, name, expected, reason)


def normalize_target_value(value: Any) -> str:
    return str(value or "").strip()


def require_matching_target(gate_target: dict[str, Any], runbook_target: dict[str, Any]) -> None:
    if not runbook_target:
        return
    for key in ("baseURL", "tcpHost", "tcpPort"):
        gate_value = normalize_target_value(gate_target.get(key))
        runbook_value = normalize_target_value(runbook_target.get(key))
        if gate_value and runbook_value and gate_value != runbook_value:
            fail(
                "production_gate_target_mismatch",
                field=key,
                gate=gate_value,
                runbook=runbook_value,
            )


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
    if value.endswith(("example.com", "example.test", "example.org", ".invalid")):
        return "placeholder"
    return ""


def require_public_target(target: dict[str, Any], context: str) -> None:
    base_url = normalize_target_value(target.get("baseURL"))
    tcp_host = normalize_target_value(target.get("tcpHost"))
    parsed = urlparse(base_url)
    if parsed.scheme != "https":
        fail(f"{context}_base_url_https_required", baseURL=base_url or "-")
    base_host = parsed.hostname or ""
    base_reason = public_host_reason(base_host)
    if base_reason:
        fail(f"{context}_base_url_domain_required", host=base_host or "-", hostReason=base_reason)
    tcp_reason = public_host_reason(tcp_host)
    if tcp_reason:
        fail(f"{context}_tcp_host_domain_required", tcpHost=tcp_host or "-", hostReason=tcp_reason)


def require_failed_probe_blocker(probe_json: dict[str, Any]) -> None:
    blocker = probe_json.get("blocker") or {}
    if blocker.get("type") != "entrypoint":
        fail("profile_entrypoint_probe_blocker_type_invalid", blockerType=blocker.get("type") or "-")
    if blocker.get("severity") != "P0":
        fail("profile_entrypoint_probe_blocker_severity_invalid", severity=blocker.get("severity") or "-")
    if blocker.get("preventsPerformanceEvidence") is not True:
        fail("profile_entrypoint_probe_blocker_not_preventing_performance")
    if not str(blocker.get("action") or ""):
        fail("profile_entrypoint_probe_blocker_action_missing")


def verify(args: argparse.Namespace) -> None:
    gate = read_json(args.gate_json)
    profile_run = read_json(args.profile_run_json)
    profile_plan = read_json(args.profile_plan_json)
    profile_runbook = read_json(args.profile_runbook_json) if args.profile_runbook_json is not None else {}
    if args.profile_runbook_md is not None:
        if not profile_runbook:
            fail("profile_runbook_json_required_for_markdown")
        try:
            verify_profile_runbook_markdown(profile_runbook, args.profile_runbook_md)
        except SystemExit as exc:
            fail("profile_runbook_markdown_mismatch", detail=str(exc))
    prereq_plan = read_json(args.prereq_plan_json)
    prereq_audit = read_json(args.prereq_audit_json)
    scenario_catalog = read_json(args.scenario_catalog_json)

    gate_profile = str(gate.get("profile") or "")
    run_profile = str(profile_run.get("profile") or "")
    run_status = str(profile_run.get("finalStatus") or "")
    run_blocker_type = str(profile_run.get("blockerType") or "")
    run_plan = profile_run.get("plan") or {}
    run_package = profile_run.get("package") or {}
    plan_profile = str(profile_plan.get("profile") or "")
    runbook_profile = str(profile_runbook.get("profile") or "")
    prereq_profile = str(prereq_plan.get("profile") or "")
    required = [
        str(row.get("scenario") or "")
        for row in gate.get("requiredScenarios") or []
        if row.get("scenario")
    ]
    required_set = set(required)
    gate_target_filter = gate.get("targetFilter") or {}

    if run_profile != gate_profile:
        fail("profile_run_mismatch", gateProfile=gate_profile or "-", runProfile=run_profile or "-")
    if run_status not in {"PASS", "NOOP"}:
        fail("profile_run_status_invalid", status=run_status or "-")
    if run_blocker_type:
        fail("profile_run_success_has_blocker_type", blockerType=run_blocker_type)
    if bool(profile_run.get("dryRun")):
        fail("profile_run_is_dry_run")
    if profile_run.get("statusFilterTarget") is not True:
        fail("profile_run_status_filter_disabled")
    if profile_run.get("entrypointProbe") is not True:
        fail("profile_entrypoint_probe_disabled")
    probe_artifacts = profile_run.get("entrypointProbeArtifacts") or {}
    for kind, expected_name in [
        ("log", "production-profile-entrypoint-probe.log"),
        ("json", "production-profile-entrypoint-probe.json"),
    ]:
        artifact_path = str(probe_artifacts.get(kind) or "")
        if not artifact_path:
            fail("profile_entrypoint_probe_artifact_missing", kind=kind)
        packaged_path = args.profile_run_json.parent / expected_name
        if not packaged_path.is_file():
            fail("profile_entrypoint_probe_packaged_artifact_missing", kind=kind, path=expected_name)
    probe_json = read_json(args.profile_run_json.parent / "production-profile-entrypoint-probe.json")
    if probe_json.get("failed") is True:
        require_failed_probe_blocker(probe_json)
        fail(
            "profile_entrypoint_probe_failed",
            diagnosis=probe_json.get("diagnosis") or "-",
            blockerAction=(probe_json.get("blocker") or {}).get("action") or "-",
        )
    if gate_target_filter.get("enabled") is not True:
        fail("production_gate_target_filter_disabled")
    require_public_target(gate_target_filter, "production_gate_target")
    probe_base_url = normalize_target_value(probe_json.get("baseURL"))
    gate_base_url = normalize_target_value(gate_target_filter.get("baseURL"))
    if probe_base_url and probe_base_url != gate_base_url:
        fail("profile_entrypoint_probe_target_mismatch", field="baseURL", gate=gate_base_url or "-", probe=probe_base_url)
    if str(run_package.get("status") or "") != "PACKAGED":
        fail("profile_run_package_status_invalid", status=run_package.get("status") or "-")
    package_path = str(run_package.get("path") or "")
    package_file_name = str(run_package.get("fileName") or "")
    if not package_path:
        fail("profile_run_package_path_missing")
    if not package_path.endswith(".tar.gz"):
        fail("profile_run_package_path_invalid", path=package_path)
    if not package_file_name:
        fail("profile_run_package_file_name_missing")
    if Path(package_path).name != package_file_name:
        fail("profile_run_package_file_name_mismatch", path=package_path, fileName=package_file_name)
    if args.expected_package_path is not None and package_path != str(args.expected_package_path):
        fail("profile_run_package_path_mismatch", expected=args.expected_package_path, actual=package_path)

    run_plan_profile = str(run_plan.get("profile") or "")
    if run_plan_profile and run_plan_profile != gate_profile:
        fail(
            "profile_run_plan_mismatch",
            gateProfile=gate_profile or "-",
            runPlanProfile=run_plan_profile or "-",
        )
    run_profile_count = require_int(run_plan.get("profileScenarioCount"), "profileScenarioCount")
    if run_profile_count != len(required):
        fail(
            "profile_run_scenario_count_mismatch",
            gateRequired=len(required),
            runPlanCount=run_profile_count,
        )
    run_selected_count = require_int(run_plan.get("selectedScenarioCount"), "selectedScenarioCount")
    run_skipped_count = require_int(run_plan.get("skippedFreshPassCount"), "skippedFreshPassCount")
    if run_selected_count < 0 or run_skipped_count < 0 or run_selected_count + run_skipped_count != len(required):
        fail(
            "profile_run_selection_count_mismatch",
            selected=run_selected_count,
            skipped=run_skipped_count,
            required=len(required),
        )

    if plan_profile != gate_profile:
        fail("profile_plan_mismatch", gateProfile=gate_profile or "-", planProfile=plan_profile or "-")
    runbook_batch_scenarios_all: list[str] = []
    runbook_batches_by_index: dict[int, list[str]] = {}
    if profile_runbook:
        if runbook_profile != gate_profile:
            fail("profile_runbook_mismatch", gateProfile=gate_profile or "-", runbookProfile=runbook_profile or "-")
        runbook_plan = profile_runbook.get("plan") or {}
        runbook_target = profile_runbook.get("target") or {}
        require_matching_target(gate_target_filter, runbook_target)
        runbook_evidence_policy = profile_runbook.get("evidencePolicy") or {}
        if runbook_evidence_policy.get("classification") != "diagnostic-production-profile":
            fail(
                "profile_runbook_evidence_policy_classification_invalid",
                value=runbook_evidence_policy.get("classification") or "-",
            )
        if runbook_evidence_policy.get("requiresCurrentReadiness") is not False:
            fail(
                "profile_runbook_evidence_policy_current_readiness_invalid",
                value=runbook_evidence_policy.get("requiresCurrentReadiness"),
            )
        final_acceptance_command = str(runbook_evidence_policy.get("finalAcceptanceCommand") or "")
        required_acceptance_parts = (
            "run_current_production_readiness.sh",
            "CURRENT_PRODUCTION_REQUIRE_PACKAGEABLE_EVIDENCE=true",
            "CURRENT_PRODUCTION_RUN_BASELINE=true",
            "CURRENT_PRODUCTION_RUN_SCENARIO_SUITE=true",
            "CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE=true",
        )
        if any(part not in final_acceptance_command for part in required_acceptance_parts):
            fail("profile_runbook_evidence_policy_final_acceptance_command_invalid")
        runbook_prereq = profile_runbook.get("prereq") or {}
        runbook_profile_run = profile_runbook.get("profileRun") or {}
        if str(runbook_profile_run.get("blockerType") or "") != run_blocker_type:
            fail(
                "profile_runbook_blocker_type_mismatch",
                run=run_blocker_type or "-",
                runbook=runbook_profile_run.get("blockerType") or "-",
            )
        runbook_commands = profile_runbook.get("commands") or {}
        runbook_status = str(profile_runbook.get("status") or "")
        if run_status == "NOOP":
            expected_runbook_status = "NOOP"
        else:
            expected_runbook_status = "READY"
        if runbook_status != expected_runbook_status:
            fail("profile_runbook_status_mismatch", expected=expected_runbook_status, actual=runbook_status or "-")
        runbook_profile_count = require_int(runbook_plan.get("profileScenarioCount"), "runbook.profileScenarioCount")
        if runbook_profile_count != len(required):
            fail(
                "profile_runbook_scenario_count_mismatch",
                gateRequired=len(required),
                runbookCount=runbook_profile_count,
            )
        runbook_selected_count = require_int(runbook_plan.get("selectedScenarioCount"), "runbook.selectedScenarioCount")
        if runbook_selected_count != run_selected_count:
            fail(
                "profile_runbook_selected_count_mismatch",
                runSelected=run_selected_count,
                runbookSelected=runbook_selected_count,
            )
        runbook_skipped_count = require_int(runbook_plan.get("skippedFreshPassCount"), "runbook.skippedFreshPassCount")
        if runbook_skipped_count != run_skipped_count:
            fail(
                "profile_runbook_skipped_count_mismatch",
                runSkipped=run_skipped_count,
                runbookSkipped=runbook_skipped_count,
            )
        runbook_batch_count = require_int(runbook_plan.get("batchCount"), "runbook.batchCount")
        command_batches = runbook_commands.get("batches") or []
        if runbook_batch_count != len(command_batches):
            fail(
                "profile_runbook_batch_count_mismatch",
                runbookBatchCount=runbook_batch_count,
                commandBatchCount=len(command_batches),
            )
        if run_status != "NOOP" and runbook_batch_count != len(profile_run.get("batches") or []):
            fail(
                "profile_runbook_run_batch_count_mismatch",
                runBatches=len(profile_run.get("batches") or []),
                runbookBatches=runbook_batch_count,
            )
        if not isinstance(command_batches, list):
            fail("profile_runbook_batches_invalid", type=type(command_batches).__name__)
        for raw_batch in command_batches:
            if not isinstance(raw_batch, dict):
                fail("profile_runbook_batch_invalid", type=type(raw_batch).__name__)
            batch_index = require_int(raw_batch.get("index"), "runbook.batch.index")
            if batch_index in runbook_batches_by_index:
                fail("profile_runbook_duplicate_batch_index", batch=batch_index)
            batch_command = str(raw_batch.get("command") or "")
            if not batch_command:
                fail("profile_runbook_batch_command_missing", batch=batch_index)
            if "./run_perf_scenarios.sh" not in batch_command:
                fail("profile_runbook_batch_command_invalid", batch=batch_index)
            require_command_assignment(
                batch_command,
                "PERF_PRODUCTION_GATE_PROFILE",
                gate_profile,
                "profile_runbook_batch_command_profile_mismatch",
                batch=batch_index,
            )
            require_command_assignment(
                batch_command,
                "PERF_PRODUCTION_GATE",
                "true",
                "profile_runbook_batch_command_gate_disabled",
                batch=batch_index,
            )
            require_command_assignment(
                batch_command,
                "PERF_STATUS_FILTER_TARGET",
                "true",
                "profile_runbook_batch_command_status_filter_disabled",
                batch=batch_index,
            )
            batch_scenarios = [str(item) for item in raw_batch.get("scenarios") or [] if item]
            parsed_command_scenarios = command_scenarios(batch_command, batch_index)
            if sorted(parsed_command_scenarios) != sorted(batch_scenarios):
                missing = sorted(set(batch_scenarios) - set(parsed_command_scenarios))
                extra = sorted(set(parsed_command_scenarios) - set(batch_scenarios))
                fail(
                    "profile_runbook_batch_command_scenarios_mismatch",
                    batch=batch_index,
                    missing=missing[:1],
                    extra=extra[:1],
                )
            unknown_runbook_batch = [item for item in batch_scenarios if item not in required_set]
            if unknown_runbook_batch:
                fail("profile_runbook_unknown_scenario", batch=batch_index, scenario=unknown_runbook_batch[0])
            runbook_batches_by_index[batch_index] = batch_scenarios
            runbook_batch_scenarios_all.extend(batch_scenarios)
        if int(runbook_prereq.get("missingRequiredCount") or 0) != 0:
            fail("profile_runbook_prereq_blocked", missingRequired=runbook_prereq.get("missingRequiredCount"))
        profile_command = str(runbook_commands.get("profile") or "")
        package_command = str(runbook_commands.get("package") or "")
        if "./run_production_profile.sh" not in profile_command:
            fail("profile_runbook_profile_command_missing")
        require_command_assignment(
            profile_command,
            "PERF_PRODUCTION_GATE_PROFILE",
            gate_profile,
            "profile_runbook_profile_command_profile_mismatch",
        )
        require_command_assignment(
            profile_command,
            "PERF_STATUS_FILTER_TARGET",
            "true",
            "profile_runbook_profile_command_status_filter_disabled",
        )
        require_command_assignment(
            profile_command,
            "PRODUCTION_PROFILE_REQUIRE_CLOUD_SECURITY_GROUP",
            "true",
            "profile_runbook_profile_command_cloud_security_group_not_required",
        )
        require_command_assignment(
            profile_command,
            "PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS",
            "86400",
            "profile_runbook_profile_command_cloud_security_group_max_age_missing",
        )
        require_command_assignment(
            profile_command,
            "PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080",
            "false",
            "profile_runbook_profile_command_temp_http_8080_not_disabled",
        )
        for env_name, reason in (
            ("PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_FILE", "profile_runbook_profile_command_cloud_security_group_rules_file_missing"),
            ("PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON", "profile_runbook_profile_command_cloud_security_group_repair_receipt_missing"),
            ("PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID", "profile_runbook_profile_command_cloud_security_group_id_missing"),
            ("PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID", "profile_runbook_profile_command_cloud_security_group_region_missing"),
            ("PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR", "profile_runbook_profile_command_cloud_security_group_admin_cidr_missing"),
        ):
            require_required_env_assignment(profile_command, env_name, reason)
        if "./package_production_evidence.sh" not in package_command:
            fail("profile_runbook_package_command_missing")
        require_command_assignment(
            package_command,
            "PERF_PRODUCTION_GATE_PROFILE",
            gate_profile,
            "profile_runbook_package_command_profile_mismatch",
        )
        if command_assignment(package_command, "PERF_PRODUCTION_GATE_JSON") is None:
            fail("profile_runbook_package_command_gate_json_missing")
        require_command_assignment(
            package_command,
            "PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS",
            "false",
            "profile_runbook_package_command_current_readiness_not_diagnostic",
        )
        require_command_assignment(
            package_command,
            "PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP",
            "true",
            "profile_runbook_package_command_cloud_security_group_not_required",
        )
        require_command_assignment(
            package_command,
            "PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS",
            "86400",
            "profile_runbook_package_command_cloud_security_group_max_age_missing",
        )
        require_command_assignment(
            package_command,
            "PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080",
            "false",
            "profile_runbook_package_command_temp_http_8080_not_disabled",
        )
        for env_name, reason in (
            ("PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_FILE", "profile_runbook_package_command_cloud_security_group_rules_file_missing"),
            ("PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON", "profile_runbook_package_command_cloud_security_group_repair_receipt_missing"),
            ("PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID", "profile_runbook_package_command_cloud_security_group_id_missing"),
            ("PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID", "profile_runbook_package_command_cloud_security_group_region_missing"),
            ("PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR", "profile_runbook_package_command_cloud_security_group_admin_cidr_missing"),
        ):
            require_required_env_assignment(package_command, env_name, reason)
    if prereq_profile and prereq_profile != gate_profile:
        fail(
            "profile_prereq_plan_mismatch",
            gateProfile=gate_profile or "-",
            prereqProfile=prereq_profile or "-",
        )

    profile_count = profile_plan.get("profileScenarioCount")
    if profile_count is not None and int(profile_count) != len(required):
        fail("profile_scenario_count_mismatch", gateRequired=len(required), planCount=profile_count)

    selected = [str(item) for item in prereq_plan.get("selectedScenarios") or [] if item]
    if len(selected) != run_selected_count:
        fail("profile_prereq_selected_count_mismatch", prereqSelected=len(selected), runSelected=run_selected_count)
    unknown_selected = [item for item in selected if item not in required_set]
    if unknown_selected:
        fail("profile_prereq_unknown_scenario", scenario=unknown_selected[0])

    batch_scenarios_all: list[str] = []
    run_batches_by_index: dict[int, list[str]] = {}
    for batch in profile_run.get("batches") or []:
        batch_index = require_int(batch.get("index"), "profileRun.batch.index")
        if batch_index in run_batches_by_index:
            fail("profile_run_duplicate_batch_index", batch=batch_index)
        batch_status = str(batch.get("status") or "")
        if batch_status != "PASS":
            fail("profile_run_batch_not_pass", batch=batch_index, status=batch_status or "-")
        batch_scenarios = [str(item) for item in batch.get("scenarios") or [] if item]
        unknown_batch = [item for item in batch_scenarios if item not in required_set]
        if unknown_batch:
            fail("profile_run_unknown_scenario", scenario=unknown_batch[0])
        if not str(batch.get("runID") or ""):
            fail("profile_run_batch_missing_run_id", batch=batch_index)
        run_batches_by_index[batch_index] = batch_scenarios
        batch_scenarios_all.extend(batch_scenarios)

    if run_status == "NOOP":
        if selected or batch_scenarios_all:
            fail("profile_noop_has_selected_or_batches", selected=len(selected), batchScenarios=len(batch_scenarios_all))
    else:
        if not selected:
            fail("profile_pass_has_no_selected_scenarios")
        if sorted(batch_scenarios_all) != sorted(selected):
            missing = sorted(set(selected) - set(batch_scenarios_all))
            extra = sorted(set(batch_scenarios_all) - set(selected))
            fail("profile_run_batch_selection_mismatch", missing=missing[:1], extra=extra[:1])
        if profile_runbook:
            if sorted(runbook_batch_scenarios_all) != sorted(selected):
                missing = sorted(set(selected) - set(runbook_batch_scenarios_all))
                extra = sorted(set(runbook_batch_scenarios_all) - set(selected))
                fail("profile_runbook_selection_mismatch", missing=missing[:1], extra=extra[:1])
            if sorted(runbook_batch_scenarios_all) != sorted(batch_scenarios_all):
                missing = sorted(set(batch_scenarios_all) - set(runbook_batch_scenarios_all))
                extra = sorted(set(runbook_batch_scenarios_all) - set(batch_scenarios_all))
                fail("profile_runbook_batch_selection_mismatch", missing=missing[:1], extra=extra[:1])
            if set(runbook_batches_by_index) != set(run_batches_by_index):
                missing = sorted(set(run_batches_by_index) - set(runbook_batches_by_index))
                extra = sorted(set(runbook_batches_by_index) - set(run_batches_by_index))
                fail("profile_runbook_batch_index_mismatch", missing=missing[:1], extra=extra[:1])
            for batch_index, batch_scenarios in run_batches_by_index.items():
                runbook_scenarios = runbook_batches_by_index.get(batch_index, [])
                if sorted(runbook_scenarios) != sorted(batch_scenarios):
                    missing = sorted(set(batch_scenarios) - set(runbook_scenarios))
                    extra = sorted(set(runbook_scenarios) - set(batch_scenarios))
                    fail(
                        "profile_runbook_batch_scenarios_mismatch",
                        batch=batch_index,
                        missing=missing[:1],
                        extra=extra[:1],
                    )

    prereq_summary = prereq_audit.get("summary") or {}
    if prereq_summary.get("overallStatus") == "BLOCKED":
        fail("profile_prereq_blocked", missingRequired=prereq_summary.get("missingRequiredCount"))

    audit_scenarios = [
        str(row.get("scenario") or "")
        for row in prereq_audit.get("scenarios") or []
        if row.get("scenario")
    ]
    unknown_audit = [item for item in audit_scenarios if item not in required_set]
    if unknown_audit:
        fail("profile_prereq_audit_unknown_scenario", scenario=unknown_audit[0])

    catalog_scenarios = {
        str(row.get("scenario") or "")
        for row in scenario_catalog.get("scenarios") or []
        if row.get("scenario")
    }
    missing_catalog = [item for item in selected if item and item not in catalog_scenarios]
    if missing_catalog:
        fail("profile_catalog_missing_selected_scenario", scenario=missing_catalog[0])


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")


def base_self_test_profile(root: Path) -> dict[str, Path]:
    profile = "normal-product-baseline"
    scenario = "login-smoke"
    package_path = root / "production-evidence.tar.gz"
    package_path.write_bytes(b"fixture")
    (root / "production-profile-entrypoint-probe.log").write_text("probe ok\n", encoding="utf-8")
    write_json(
        root / "production-profile-entrypoint-probe.json",
        {
            "failed": False,
            "baseURL": "https://chat.example.internal",
        },
    )
    gate_path = root / "production-gate.json"
    run_path = root / "production-profile-run.json"
    plan_path = root / "production-profile-plan.json"
    prereq_plan_path = root / "production-profile-prereq-plan.json"
    prereq_audit_path = root / "production-profile-prereq-audit.json"
    catalog_path = root / "production-profile-scenario-catalog.json"
    target = {
        "enabled": True,
        "baseURL": "https://chat.example.internal",
        "tcpHost": "tcp.chat.example.internal",
        "tcpPort": "9000",
    }
    write_json(
        gate_path,
        {
            "profile": profile,
            "targetFilter": target,
            "requiredScenarios": [
                {"scenario": scenario},
            ],
        },
    )
    write_json(
        run_path,
        {
            "profile": profile,
            "finalStatus": "PASS",
            "blockerType": "",
            "dryRun": False,
            "statusFilterTarget": True,
            "entrypointProbe": True,
            "entrypointProbeArtifacts": {
                "log": "production-profile-entrypoint-probe.log",
                "json": "production-profile-entrypoint-probe.json",
            },
            "package": {
                "status": "PACKAGED",
                "path": str(package_path),
                "fileName": package_path.name,
            },
            "plan": {
                "profile": profile,
                "profileScenarioCount": 1,
                "selectedScenarioCount": 1,
                "skippedFreshPassCount": 0,
            },
            "batches": [
                {
                    "index": 1,
                    "status": "PASS",
                    "scenarios": [scenario],
                    "runID": "profile-self-test-batch-1",
                },
            ],
        },
    )
    write_json(
        plan_path,
        {
            "profile": profile,
            "profileScenarioCount": 1,
        },
    )
    write_json(
        prereq_plan_path,
        {
            "profile": profile,
            "selectedScenarios": [scenario],
        },
    )
    write_json(
        prereq_audit_path,
        {
            "summary": {
                "overallStatus": "READY",
                "missingRequiredCount": 0,
            },
            "scenarios": [
                {"scenario": scenario},
            ],
        },
    )
    write_json(
        catalog_path,
        {
            "summary": {"scenarioCount": 1},
            "scenarios": [
                {"scenario": scenario},
            ],
        },
    )
    return {
        "gate": gate_path,
        "run": run_path,
        "plan": plan_path,
        "prereqPlan": prereq_plan_path,
        "prereqAudit": prereq_audit_path,
        "catalog": catalog_path,
        "package": package_path,
    }


def self_test_args(paths: dict[str, Path], *, gate: Path | None = None, run: Path | None = None, catalog: Path | None = None) -> argparse.Namespace:
    return argparse.Namespace(
        gate_json=gate or paths["gate"],
        profile_run_json=run or paths["run"],
        profile_plan_json=paths["plan"],
        profile_runbook_json=None,
        profile_runbook_md=None,
        prereq_plan_json=paths["prereqPlan"],
        prereq_audit_json=paths["prereqAudit"],
        scenario_catalog_json=catalog or paths["catalog"],
        expected_package_path=None,
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
        paths = base_self_test_profile(root)
        verify(self_test_args(paths))

        bad_gate = read_json(paths["gate"])
        bad_gate["targetFilter"]["baseURL"] = "http://127.0.0.1:8080"
        bad_gate_path = root / "production-gate-local-target.json"
        write_json(bad_gate_path, bad_gate)
        expect_self_test_failure(
            "self_test_production_gate_target_public_required",
            lambda: verify(self_test_args(paths, gate=bad_gate_path)),
            "production_gate_target_base_url_https_required",
        )

        bad_run = read_json(paths["run"])
        bad_run["batches"][0]["scenarios"] = []
        bad_run_path = root / "production-profile-run-bad-batches.json"
        write_json(bad_run_path, bad_run)
        expect_self_test_failure(
            "self_test_profile_run_batch_selection_mismatch",
            lambda: verify(self_test_args(paths, run=bad_run_path)),
            "profile_run_batch_selection_mismatch",
        )

        bad_catalog = {
            "summary": {"scenarioCount": 0},
            "scenarios": [],
        }
        bad_catalog_path = root / "production-profile-scenario-catalog-empty.json"
        write_json(bad_catalog_path, bad_catalog)
        expect_self_test_failure(
            "self_test_profile_catalog_missing_selected_scenario",
            lambda: verify(self_test_args(paths, catalog=bad_catalog_path)),
            "profile_catalog_missing_selected_scenario",
        )
    print("profile_artifacts_self_test result=pass")


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify production profile run/plan/prereq evidence consistency.")
    parser.add_argument("--gate-json", type=Path)
    parser.add_argument("--profile-run-json", type=Path)
    parser.add_argument("--profile-plan-json", type=Path)
    parser.add_argument("--profile-runbook-json", type=Path)
    parser.add_argument("--profile-runbook-md", type=Path)
    parser.add_argument("--prereq-plan-json", type=Path)
    parser.add_argument("--prereq-audit-json", type=Path)
    parser.add_argument("--scenario-catalog-json", type=Path)
    parser.add_argument("--expected-package-path")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        run_self_test()
        return 0
    required_args = [
        ("--gate-json", args.gate_json),
        ("--profile-run-json", args.profile_run_json),
        ("--profile-plan-json", args.profile_plan_json),
        ("--prereq-plan-json", args.prereq_plan_json),
        ("--prereq-audit-json", args.prereq_audit_json),
        ("--scenario-catalog-json", args.scenario_catalog_json),
    ]
    missing = [name for name, value in required_args if value is None]
    if missing:
        parser.error(f"{', '.join(missing)} required unless --self-test is used")
    verify(args)
    print(f"profile_artifacts result=pass gate={args.gate_json} profileRun={args.profile_run_json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
