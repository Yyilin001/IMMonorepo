#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shlex
import tempfile
from pathlib import Path
from typing import Any

from perf_product_test_plan_runbook import verify_markdown as verify_product_runbook_markdown


def read_json(path: Path) -> dict[str, Any]:
    try:
        with path.open(encoding="utf-8") as handle:
            return json.load(handle)
    except Exception as exc:
        raise SystemExit(f"product_plan_artifacts result=fail reason=json_read_failed path={path} error={exc}") from exc


def fail(reason: str, **fields: Any) -> None:
    details = " ".join(f"{key}={value}" for key, value in fields.items())
    message = f"product_plan_artifacts result=fail reason={reason}"
    if details:
        message = f"{message} {details}"
    raise SystemExit(message)


def bool_enabled(value: Any) -> bool:
    return str(value).lower() in {"1", "true", "yes", "on"}


def resolve_artifact_path(run_json: Path, explicit: Path | None, recorded: str) -> Path:
    if explicit is not None:
        return explicit
    if not recorded:
        fail("artifact_path_missing")
    path = Path(recorded)
    if not path.is_absolute():
        path = run_json.parent / path
    return path


def require_file(path: Path, reason: str) -> None:
    if not path.exists():
        fail(reason, path=path)


def require_nonempty_file(path: Path, reason: str) -> None:
    require_file(path, reason)
    if not path.read_text(encoding="utf-8", errors="replace").strip():
        fail(f"{reason}_empty", path=path)


def sorted_strings(values: Any) -> list[str]:
    return sorted(str(item) for item in (values or []) if str(item))


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


def require_secret_redacted(command: str, phase: str) -> None:
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
    fail("phase_command_secret_not_redacted", phase=phase or "-", value=value[:8])


def require_entrypoint_recovery(runbook_payload: dict[str, Any]) -> None:
    if str(runbook_payload.get("status") or "") != "BLOCKED":
        fail("entrypoint_failed_runbook_not_blocked", status=runbook_payload.get("status") or "-")
    entrypoint = runbook_payload.get("entrypoint") or {}
    recovery = entrypoint.get("recovery") or {}
    if recovery.get("needed") is not True:
        fail("entrypoint_failed_recovery_missing")
    diagnosis = str(recovery.get("diagnosis") or "")
    if not diagnosis or diagnosis == "ok":
        fail("entrypoint_failed_recovery_diagnosis_invalid", diagnosis=diagnosis or "-")
    blocker = recovery.get("blocker") or {}
    if blocker.get("type") != "entrypoint":
        fail("entrypoint_failed_recovery_blocker_type_invalid", blockerType=blocker.get("type") or "-")
    if blocker.get("severity") != "P0":
        fail("entrypoint_failed_recovery_blocker_severity_invalid", severity=blocker.get("severity") or "-")
    if blocker.get("preventsPerformanceEvidence") is not True:
        fail("entrypoint_failed_recovery_blocker_not_preventing_performance")
    if not str(blocker.get("action") or ""):
        fail("entrypoint_failed_recovery_blocker_action_missing")
    blocker_action = str(blocker.get("action") or "")
    commands = recovery.get("commands") or []
    command_text = "\n".join(str(row.get("command") or "") for row in commands if isinstance(row, dict))
    if blocker_action in {"disable_local_proxy_or_test_from_clean_network", "repair_entrypoint_probe"}:
        expected_commands = ["http_entrypoint_probe.sh"]
        forbidden_commands = ["23_repair_node_access.sh", "21_render_node_access_rescue_command.sh"]
    elif blocker_action == "cloud_console_rescue_required":
        expected_commands = [
            "75_entrypoint_diagnose.sh",
            "23_repair_node_access.sh",
            "64_repair_http_entrypoint.sh",
            "21_render_node_access_rescue_command.sh",
        ]
        forbidden_commands = []
    else:
        expected_commands = [
            "75_entrypoint_diagnose.sh",
            "23_repair_node_access.sh",
            "64_repair_http_entrypoint.sh",
        ]
        forbidden_commands = []
    for expected in expected_commands:
        if expected not in command_text:
            fail("entrypoint_failed_recovery_command_missing", command=expected)
    for forbidden in forbidden_commands:
        if forbidden in command_text:
            fail("entrypoint_failed_recovery_command_forbidden", command=forbidden)


def verify_phase_status_tsv(path: Path, phases: list[Any]) -> None:
    require_file(path, "phase_status_tsv_missing")
    rows: list[dict[str, str]] = []
    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), start=1):
        if not raw_line.strip():
            continue
        parts = raw_line.split("\t")
        if len(parts) != 6:
            fail("phase_status_tsv_row_invalid", path=path, line=line_number, columns=len(parts))
        phase, kind, run_id, status, reason, command = parts
        rows.append({
            "phase": phase,
            "kind": kind,
            "runID": run_id,
            "status": status,
            "reason": reason,
            "command": command,
        })
    if len(rows) != len(phases):
        fail("phase_status_tsv_count_mismatch", path=path, tsv=len(rows), run=len(phases))
    for index, (row, phase_record) in enumerate(zip(rows, phases), start=1):
        if not isinstance(phase_record, dict):
            fail("phase_status_run_record_invalid", index=index)
        for key in ("phase", "kind", "runID", "status", "reason", "command"):
            expected = str(phase_record.get(key) or "")
            actual = row.get(key) or ""
            if actual != expected:
                fail(
                    "phase_status_tsv_mismatch",
                    path=path,
                    index=index,
                    field=key,
                    tsv=actual or "-",
                    run=expected or "-",
                )


def verify_scenario_catalog(path: Path, selected: list[str]) -> None:
    require_file(path, "scenario_catalog_missing")
    catalog = read_json(path)
    scenarios = catalog.get("scenarios")
    if not isinstance(scenarios, list):
        fail("scenario_catalog_scenarios_invalid", path=path)
    summary = catalog.get("summary") or {}
    recorded_count = int(summary.get("scenarioCount") or 0)
    if recorded_count != len(scenarios):
        fail("scenario_catalog_count_mismatch", path=path, recorded=recorded_count, actual=len(scenarios))
    catalog_names = {
        str(row.get("scenario") or "")
        for row in scenarios
        if isinstance(row, dict) and str(row.get("scenario") or "")
    }
    missing = sorted(name for name in selected if name not in catalog_names)
    if missing:
        fail("scenario_catalog_selected_missing", path=path, scenario=missing[0])


def verify_plan_preview(path: Path, requested_phases: list[str], selected: list[str]) -> dict[str, Any]:
    require_file(path, "plan_preview_json_missing")
    preview = read_json(path)
    if preview.get("schemaVersion") != 1:
        fail("plan_preview_schema_version_invalid", value=preview.get("schemaVersion"))
    preview_phases = [str(item) for item in (preview.get("requestedPhases") or []) if str(item)]
    if preview_phases != requested_phases:
        fail("plan_preview_phase_mismatch", run=" ".join(requested_phases), preview=" ".join(preview_phases))
    phase_rows = preview.get("phases") or []
    if not isinstance(phase_rows, list):
        fail("plan_preview_phases_invalid")
    row_names = [str(row.get("phase") or "") for row in phase_rows if isinstance(row, dict)]
    if row_names != requested_phases:
        fail("plan_preview_phase_rows_mismatch", run=" ".join(requested_phases), preview=" ".join(row_names))
    preview_selected = sorted_strings(preview.get("selectedScenarios"))
    if any(phase != "entrypoint" for phase in requested_phases) and not preview_selected:
        fail("plan_preview_selected_scenarios_missing")
    if selected and preview_selected != selected:
        fail("plan_preview_selected_scenario_mismatch", preview=len(preview_selected), prereq=len(selected))
    summary = preview.get("summary") or {}
    if int(summary.get("uniqueScenarioCount") or 0) != len(preview_selected):
        fail("plan_preview_unique_count_mismatch", summary=summary.get("uniqueScenarioCount"), actual=len(preview_selected))
    covered_domains = sorted_strings(summary.get("coveredProductDomains"))
    required_domains = sorted_strings(summary.get("requiredProductDomains"))
    missing_domains = sorted_strings(summary.get("missingProductDomains"))
    if not isinstance(summary.get("coveredProductDomains"), list):
        fail("plan_preview_covered_domains_invalid")
    if not isinstance(summary.get("requiredProductDomains"), list):
        fail("plan_preview_required_domains_invalid")
    if not isinstance(summary.get("missingProductDomains"), list):
        fail("plan_preview_missing_domains_invalid")
    expected_missing = sorted(domain for domain in required_domains if domain not in set(covered_domains))
    if missing_domains != expected_missing:
        fail(
            "plan_preview_missing_domains_mismatch",
            expected=",".join(expected_missing) or "-",
            actual=",".join(missing_domains) or "-",
        )
    required_covered = summary.get("requiredProductDomainsCovered")
    if not isinstance(required_covered, bool):
        fail("plan_preview_required_domains_covered_invalid", value=required_covered)
    if required_covered != (not expected_missing):
        fail(
            "plan_preview_required_domains_covered_mismatch",
            expected=str(not expected_missing).lower(),
            actual=str(required_covered).lower(),
        )
    return preview


def verify(args: argparse.Namespace) -> None:
    run_json = args.product_run_json
    product_run = read_json(run_json)

    if product_run.get("schemaVersion") != 1:
        fail("run_schema_version_invalid", value=product_run.get("schemaVersion"))

    final_status = str(product_run.get("finalStatus") or "")
    if final_status not in {"PASS", "FAIL"}:
        fail("run_status_invalid", status=final_status or "-")
    if bool(getattr(args, "require_pass", False)) and final_status != "PASS":
        fail("product_plan_not_pass", status=final_status or "-", runReason=str(product_run.get("reason") or "-"))
    if bool(product_run.get("dryRun")) and not args.allow_dry_run:
        fail("run_is_dry_run")

    requested_phases = [str(item) for item in (product_run.get("requestedPhases") or []) if str(item)]
    if not requested_phases:
        fail("requested_phases_missing")

    phases = product_run.get("phases") or []
    if not isinstance(phases, list):
        fail("phases_not_array")

    reason = str(product_run.get("reason") or "")
    if final_status == "FAIL" and not reason:
        fail("failed_run_reason_missing")
    if final_status == "PASS" and reason:
        fail("passed_run_has_reason", reason=reason)
    blocker_type = str(product_run.get("blockerType") or "")
    if final_status == "FAIL" and not blocker_type:
        fail("failed_run_blocker_type_missing")
    if final_status == "PASS" and blocker_type:
        fail("passed_run_has_blocker_type", blockerType=blocker_type)
    if reason == "prereq_gate_failed" and blocker_type != "prerequisites":
        fail("prereq_failed_blocker_type_mismatch", blockerType=blocker_type or "-")
    if reason == "entrypoint_failed" and blocker_type != "entrypoint":
        fail("entrypoint_failed_blocker_type_mismatch", blockerType=blocker_type or "-")
    if reason == "operator_network_failed" and blocker_type != "operator-network":
        fail("operator_network_failed_blocker_type_mismatch", blockerType=blocker_type or "-")

    prereq = product_run.get("prereq") or {}
    prereq_enabled = bool_enabled(prereq.get("enabled"))
    prereq_ran = bool_enabled(prereq.get("ran", prereq_enabled))
    selected: list[str] = []
    if prereq_enabled and prereq_ran:
        prereq_plan_json = resolve_artifact_path(run_json, args.prereq_plan_json, str(prereq.get("plan") or ""))
        prereq_audit_json = resolve_artifact_path(run_json, args.prereq_audit_json, str(prereq.get("auditJSON") or ""))
        require_file(prereq_plan_json, "prereq_plan_missing")
        require_file(prereq_audit_json, "prereq_audit_missing")
        prereq_plan = read_json(prereq_plan_json)
        prereq_audit = read_json(prereq_audit_json)

        prereq_phases = [str(item) for item in (prereq_plan.get("requestedPhases") or []) if str(item)]
        if prereq_phases != requested_phases:
            fail("prereq_phase_mismatch", run=" ".join(requested_phases), prereq=" ".join(prereq_phases))

        selected = sorted_strings(prereq_plan.get("selectedScenarios"))
        audit_scenarios = sorted_strings(row.get("scenario") for row in (prereq_audit.get("scenarios") or []))
        if any(phase != "entrypoint" for phase in requested_phases) and not selected:
            fail("prereq_selected_scenarios_missing")
        if selected and selected != audit_scenarios:
            fail("prereq_audit_scenario_mismatch", selected=len(selected), audit=len(audit_scenarios))

        summary = prereq_audit.get("summary") or {}
        missing_required = int(summary.get("missingRequiredCount") or 0)
        audit_status = str(summary.get("overallStatus") or "")
        if final_status == "PASS":
            if audit_status == "BLOCKED" or missing_required:
                fail("passed_run_prereq_blocked", status=audit_status or "-", missingRequired=missing_required)
        if reason == "prereq_gate_failed" and missing_required <= 0:
            fail("prereq_failed_without_missing_required")
        if args.prereq_audit_md is not None:
            require_nonempty_file(args.prereq_audit_md, "prereq_audit_markdown_missing")
    elif prereq_enabled:
        if reason not in {"entrypoint_failed", "operator_network_failed"}:
            fail("prereq_not_run")
    else:
        if args.require_prereq:
            fail("prereq_disabled")

    plan_preview = product_run.get("planPreview") or {}
    plan_preview_json = resolve_artifact_path(run_json, args.plan_preview_json, str(plan_preview.get("json") or ""))
    preview_payload = verify_plan_preview(plan_preview_json, requested_phases, selected)
    if bool(plan_preview.get("exists")) is not True:
        fail("plan_preview_recorded_missing")

    runbook = product_run.get("runbook") or {}
    runbook_json = resolve_artifact_path(run_json, args.runbook_json, str(runbook.get("json") or "")) if runbook else None
    if runbook_json is not None:
        require_file(runbook_json, "runbook_json_missing")
        runbook_payload = read_json(runbook_json)
        if args.runbook_md is not None:
            try:
                verify_product_runbook_markdown(runbook_payload, args.runbook_md)
            except SystemExit as exc:
                fail("runbook_markdown_mismatch", detail=str(exc))
        runbook_run = runbook_payload.get("productRun") or {}
        if str(runbook_run.get("finalStatus") or "") != final_status:
            fail("runbook_status_mismatch", run=final_status or "-", runbook=runbook_run.get("finalStatus") or "-")
        if bool(runbook_run.get("dryRun")) != bool(product_run.get("dryRun")):
            fail("runbook_dry_run_mismatch")
        if str(runbook_run.get("blockerType") or "") != blocker_type:
            fail(
                "runbook_blocker_type_mismatch",
                run=blocker_type or "-",
                runbook=runbook_run.get("blockerType") or "-",
            )
        runbook_plan = runbook_payload.get("plan") or {}
        if [str(item) for item in (runbook_plan.get("requestedPhases") or []) if str(item)] != requested_phases:
            fail("runbook_phase_mismatch")
        runbook_preview = runbook_plan.get("preview") or {}
        preview_summary = preview_payload.get("summary") or {}
        if int(runbook_preview.get("uniqueScenarioCount") or 0) != int(preview_summary.get("uniqueScenarioCount") or 0):
            fail("runbook_plan_preview_count_mismatch")
        if sorted_strings(runbook_preview.get("coveredProductDomains")) != sorted_strings(preview_summary.get("coveredProductDomains")):
            fail("runbook_plan_preview_domain_mismatch")
        if bool(runbook_preview.get("requiredProductDomainsCovered")) != bool(preview_summary.get("requiredProductDomainsCovered")):
            fail("runbook_plan_preview_domain_coverage_mismatch")
        evidence_policy = runbook_payload.get("evidencePolicy") or {}
        if evidence_policy.get("classification") != "diagnostic-product-plan":
            fail(
                "runbook_evidence_policy_classification_invalid",
                value=evidence_policy.get("classification") or "-",
            )
        if evidence_policy.get("requiresCurrentReadiness") is not False:
            fail(
                "runbook_evidence_policy_current_readiness_invalid",
                value=evidence_policy.get("requiresCurrentReadiness"),
            )
        final_acceptance_command = str(evidence_policy.get("finalAcceptanceCommand") or "")
        required_acceptance_parts = (
            "run_current_production_readiness.sh",
            "CURRENT_PRODUCTION_REQUIRE_PACKAGEABLE_EVIDENCE=true",
            "CURRENT_PRODUCTION_RUN_BASELINE=true",
            "CURRENT_PRODUCTION_RUN_SCENARIO_SUITE=true",
            "CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE=true",
        )
        if any(part not in final_acceptance_command for part in required_acceptance_parts):
            fail("runbook_evidence_policy_final_acceptance_command_invalid")
        verify_command = str(((runbook_payload.get("commands") or {}).get("verify")) or "")
        if "perf_product_plan_artifacts_verify.py" not in verify_command:
            fail("runbook_verify_command_missing")
        if reason == "entrypoint_failed":
            require_entrypoint_recovery(runbook_payload)
    elif reason == "entrypoint_failed":
        fail("entrypoint_failed_runbook_missing")

    phase_names = [str(row.get("phase") or "") for row in phases]
    expected_phase_records = requested_phases + ["full-profile"]
    if phase_names and phase_names[0] == "operator-network":
        expected_phase_records = ["operator-network"] + expected_phase_records
    if final_status == "PASS":
        expected = expected_phase_records
        if phase_names != expected:
            fail("phase_order_mismatch", expected=" ".join(expected), actual=" ".join(phase_names))
        if any(str(row.get("status") or "") == "FAIL" for row in phases):
            fail("passed_run_has_failed_phase")
        run_full_profile = bool(product_run.get("runFullProfile"))
        full_profile = phases[-1] if phases else {}
        if str(full_profile.get("phase") or "") != "full-profile":
            fail("full_profile_phase_missing")
        full_status = str(full_profile.get("status") or "")
        if run_full_profile and full_status != "PASS":
            fail("full_profile_enabled_not_pass", status=full_status or "-")
        if not run_full_profile and full_status != "SKIPPED":
            fail("full_profile_disabled_not_skipped", status=full_status or "-")
    elif reason == "prereq_gate_failed" and phases:
        allowed = [["entrypoint"], ["operator-network", "entrypoint"]]
        if phase_names not in allowed:
            fail("prereq_failed_has_phase_records", count=len(phases))
        entrypoint_phase = phases[-1] if phases else {}
        if str(entrypoint_phase.get("status") or "") == "FAIL":
            fail("prereq_failed_after_failed_entrypoint")
    elif reason == "entrypoint_failed":
        allowed = [["entrypoint"], ["operator-network", "entrypoint"]]
        if phase_names not in allowed:
            fail("entrypoint_failed_phase_count_invalid", count=len(phases))
        entrypoint_phase = phases[-1] if phases else {}
        if str(entrypoint_phase.get("phase") or "") != "entrypoint":
            fail("entrypoint_failed_phase_missing")
        if str(entrypoint_phase.get("kind") or "") != "entrypoint-probe":
            fail("entrypoint_failed_phase_kind_invalid", kind=entrypoint_phase.get("kind") or "-")
        if str(entrypoint_phase.get("status") or "") != "FAIL":
            fail("entrypoint_failed_phase_status_invalid", status=entrypoint_phase.get("status") or "-")
    elif reason == "operator_network_failed":
        if phase_names != ["operator-network"]:
            fail("operator_network_failed_phase_count_invalid", count=len(phases))
        operator_phase = phases[0] if phases else {}
        if str(operator_phase.get("kind") or "") != "operator-network":
            fail("operator_network_failed_phase_kind_invalid", kind=operator_phase.get("kind") or "-")
        if str(operator_phase.get("status") or "") != "FAIL":
            fail("operator_network_failed_phase_status_invalid", status=operator_phase.get("status") or "-")

    for index, row in enumerate(phases):
        phase = str(row.get("phase") or "")
        kind = str(row.get("kind") or "")
        status = str(row.get("status") or "")
        command = str(row.get("command") or "")
        if phase not in requested_phases + ["full-profile", "operator-network"]:
            fail("unexpected_phase_record", phase=phase or "-", index=index)
        if not kind:
            fail("phase_kind_missing", phase=phase or "-", index=index)
        if status not in {"PASS", "FAIL", "SKIPPED", "DRY_RUN"}:
            fail("phase_status_invalid", phase=phase or "-", status=status or "-")
        if not command:
            fail("phase_command_missing", phase=phase or "-", index=index)
        require_secret_redacted(command, phase)
        if phase == "entrypoint" and kind != "entrypoint-probe":
            fail("entrypoint_phase_kind_invalid", kind=kind)
        if phase == "full-profile" and kind != "production-profile":
            fail("full_profile_phase_kind_invalid", kind=kind)
        if phase == "operator-network" and kind != "operator-network":
            fail("operator_network_phase_kind_invalid", kind=kind)
        if phase not in {"entrypoint", "full-profile", "operator-network"} and kind != "scenario-groups":
            fail("scenario_phase_kind_invalid", phase=phase, kind=kind)

    if args.phases_tsv is not None:
        verify_phase_status_tsv(args.phases_tsv, phases)
    if args.scenario_catalog_json is not None:
        verify_scenario_catalog(args.scenario_catalog_json, selected)

    print(
        "product_plan_artifacts result=pass "
        f"status={final_status} phases={len(phases)} requested={len(requested_phases)} "
        f"prereq={'enabled' if prereq_enabled else 'disabled'}"
    )


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")


def base_self_test_payloads(root: Path) -> dict[str, Path]:
    preview_path = root / "product-test-plan-preview.json"
    run_path = root / "product-test-plan-run.json"
    phases_path = root / "product-test-plan-phases.tsv"
    catalog_path = root / "product-test-scenario-catalog.json"
    entrypoint_command = "BASE_URL=https://chat.example.com ./http_entrypoint_probe.sh"
    profile_command = "PERF_PRODUCTION_GATE_PROFILE=normal-product-baseline ./run_production_profile.sh"
    target = {
        "baseURL": "https://chat.example.com",
        "tcpHost": "tcp.chat.example.com",
        "tcpPort": "9000",
        "accountFile": "/tmp/self-test-accounts.csv",
        "conversationID": "",
    }
    write_json(
        preview_path,
        {
            "schemaVersion": 1,
            "plan": "self-test",
            "requestedPhases": ["entrypoint"],
            "target": target,
            "summary": {
                "phaseCount": 1,
                "scenarioPhaseCount": 0,
                "uniqueScenarioCount": 0,
                "largeGroupIncluded": False,
                "coveredProductDomains": [],
                "requiredProductDomains": ["direct-chat"],
                "missingProductDomains": ["direct-chat"],
                "requiredProductDomainsCovered": False,
            },
            "selectedScenarios": [],
            "phases": [
                {
                    "phase": "entrypoint",
                    "kind": "entrypoint",
                    "groups": [],
                    "runner": "http_entrypoint_probe.sh",
                    "scenarioCount": 0,
                    "firstScenario": "",
                    "sampleScenarios": [],
                    "scenarios": [],
                }
            ],
        },
    )
    write_json(
        run_path,
        {
            "schemaVersion": 1,
            "plan": "self-test",
            "requestedPhases": ["entrypoint"],
            "runFullProfile": False,
            "fullProfile": "normal-product-baseline",
            "runIDPrefix": "product-plan-self-test",
            "finalStatus": "PASS",
            "reason": "",
            "dryRun": False,
            "target": target,
            "prereq": {
                "enabled": False,
            },
            "planPreview": {
                "json": str(preview_path),
                "exists": True,
            },
            "phases": [
                {
                    "phase": "entrypoint",
                    "kind": "entrypoint-probe",
                    "runID": "product-plan-self-test-entrypoint",
                    "status": "PASS",
                    "reason": "",
                    "command": entrypoint_command,
                    "runDir": str(root / "entrypoint"),
                },
                {
                    "phase": "full-profile",
                    "kind": "production-profile",
                    "runID": "product-plan-self-test-full-profile",
                    "status": "SKIPPED",
                    "reason": "disabled",
                    "command": profile_command,
                    "runDir": str(root / "full-profile"),
                },
            ],
        },
    )
    phases_path.write_text(
        "\n".join(
            [
                f"entrypoint\tentrypoint-probe\tproduct-plan-self-test-entrypoint\tPASS\t\t{entrypoint_command}",
                f"full-profile\tproduction-profile\tproduct-plan-self-test-full-profile\tSKIPPED\tdisabled\t{profile_command}",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    write_json(
        catalog_path,
        {
            "summary": {"scenarioCount": 0},
            "scenarios": [],
        },
    )
    return {
        "run": run_path,
        "preview": preview_path,
        "phases": phases_path,
        "catalog": catalog_path,
    }


def self_test_args(paths: dict[str, Path], *, phases_tsv: Path | None = None, run_json: Path | None = None) -> argparse.Namespace:
    return argparse.Namespace(
        product_run_json=run_json or paths["run"],
        prereq_plan_json=None,
        prereq_audit_json=None,
        prereq_audit_md=None,
        phases_tsv=paths["phases"] if phases_tsv is None else phases_tsv,
        scenario_catalog_json=paths["catalog"],
        plan_preview_json=paths["preview"],
        runbook_json=None,
        runbook_md=None,
        allow_dry_run=False,
        require_prereq=False,
        require_pass=True,
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
        paths = base_self_test_payloads(root)
        verify(self_test_args(paths))

        bad_tsv = root / "product-test-plan-phases-bad.tsv"
        bad_tsv.write_text(
            "entrypoint\tentrypoint-probe\tproduct-plan-self-test-entrypoint\tPASS\t\twrong-command\n"
            "full-profile\tproduction-profile\tproduct-plan-self-test-full-profile\tSKIPPED\tdisabled\t"
            "PERF_PRODUCTION_GATE_PROFILE=normal-product-baseline ./run_production_profile.sh\n",
            encoding="utf-8",
        )
        expect_self_test_failure(
            "self_test_phase_status_tsv_mismatch",
            lambda: verify(self_test_args(paths, phases_tsv=bad_tsv)),
            "phase_status_tsv_mismatch",
        )

        bad_preview = read_json(paths["preview"])
        bad_preview["summary"]["uniqueScenarioCount"] = 1
        bad_preview_path = root / "product-test-plan-preview-bad.json"
        write_json(bad_preview_path, bad_preview)
        bad_preview_paths = dict(paths)
        bad_preview_paths["preview"] = bad_preview_path
        expect_self_test_failure(
            "self_test_plan_preview_unique_count_mismatch",
            lambda: verify(self_test_args(bad_preview_paths)),
            "plan_preview_unique_count_mismatch",
        )

        bad_run = read_json(paths["run"])
        bad_run["phases"][0]["command"] = "IM_INTERNAL_SECRET=plain-text-secret ./http_entrypoint_probe.sh"
        bad_run_path = root / "product-test-plan-run-secret.json"
        write_json(bad_run_path, bad_run)
        expect_self_test_failure(
            "self_test_phase_command_secret_not_redacted",
            lambda: verify(self_test_args(paths, phases_tsv=None, run_json=bad_run_path)),
            "phase_command_secret_not_redacted",
        )
    print("product_plan_artifacts_self_test result=pass")


def main() -> None:
    parser = argparse.ArgumentParser(description="Verify product test plan receipt and prerequisite artifacts.")
    parser.add_argument("--product-run-json", type=Path)
    parser.add_argument("--prereq-plan-json", type=Path)
    parser.add_argument("--prereq-audit-json", type=Path)
    parser.add_argument("--prereq-audit-md", type=Path)
    parser.add_argument("--phases-tsv", type=Path)
    parser.add_argument("--scenario-catalog-json", type=Path)
    parser.add_argument("--plan-preview-json", type=Path)
    parser.add_argument("--runbook-json", type=Path)
    parser.add_argument("--runbook-md", type=Path)
    parser.add_argument("--allow-dry-run", action="store_true")
    parser.add_argument("--require-prereq", action="store_true")
    parser.add_argument("--require-pass", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        run_self_test()
        return
    if args.product_run_json is None:
        parser.error("--product-run-json is required unless --self-test is used")
    verify(args)


if __name__ == "__main__":
    main()
