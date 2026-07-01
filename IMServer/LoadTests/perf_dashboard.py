#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from perf_entrypoint_rescue import entrypoint_rescue_failed, entrypoint_rescue_next_command
from perf_production_next_step import (
    attach_production_evidence_commands,
    build_current_production_readiness_command,
    build_production_acceptance_command,
    build_production_profile_command,
    failed_production_gate_scenarios,
    unique_production_evidence_action_commands,
)
from perf_state_summary import (
    current_readiness_summary as rich_current_readiness_summary,
    production_acceptance_summary,
    production_evidence_blockers,
)


def read_json(path: Path | None) -> dict[str, Any]:
    if path is None:
        return {}
    try:
        return json.loads(path.read_text())
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


def current_readiness_summary(path: str | None) -> dict[str, Any]:
    if not path:
        return {}
    receipt_path = Path(path).expanduser()
    receipt = read_json(receipt_path)
    if not receipt:
        return {}
    requested = receipt.get("requestedRuns") or {}
    runs = receipt.get("runs") or {}
    artifacts = receipt.get("artifacts") or {}
    suite_run: dict[str, Any] = {}
    suite_run_path = artifact_path(receipt_path, artifacts.get("productScenarioSuiteRunJSON"))
    if suite_run_path is not None:
        suite_run = read_json(suite_run_path)
    full_run: dict[str, Any] = {}
    full_run_path = artifact_path(receipt_path, artifacts.get("fullAcceptanceRunJSON"))
    if full_run_path is not None:
        full_run = read_json(full_run_path)
    suite_coverage = suite_run.get("coverageSummary") or {}

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


def build_dashboard(args: argparse.Namespace) -> dict[str, Any]:
    scenario_status = read_json(Path(args.scenario_status_json) if args.scenario_status_json else None)
    slo_status = read_json(Path(args.slo_status_json) if args.slo_status_json else None)
    slo_domain_scorecard = read_json(Path(args.slo_domain_scorecard_json) if args.slo_domain_scorecard_json else None)
    next_actions = read_json(Path(args.next_actions_json) if args.next_actions_json else None)
    catalog = read_json(Path(args.scenario_catalog_json) if args.scenario_catalog_json else None)
    backlog = read_json(Path(args.domain_backlog_json) if args.domain_backlog_json else None)
    run_plan = read_json(Path(args.run_plan_json) if args.run_plan_json else None)
    domain_run_plan = read_json(Path(args.domain_run_plan_json) if args.domain_run_plan_json else None)
    slo_domain_run_plan = read_json(Path(args.slo_domain_run_plan_json) if args.slo_domain_run_plan_json else None)
    scorecard = read_json(Path(args.domain_scorecard_json) if args.domain_scorecard_json else None)
    prereq = read_json(Path(args.prereq_audit_json) if args.prereq_audit_json else None)
    readiness = read_json(Path(args.readiness_gate_json) if args.readiness_gate_json else None)
    production_gate = read_json(Path(args.production_gate_json) if args.production_gate_json else None)
    entrypoint_rescue = read_kv(args.entrypoint_rescue_summary)
    current_readiness = current_readiness_summary(args.current_readiness_json)

    score_summary = scorecard.get("summary") or {}
    readiness_status = str(readiness.get("status") or "UNKNOWN")
    overall_status = str(score_summary.get("overallStatus") or "UNKNOWN")
    run_plan_status = str(run_plan.get("status") or "UNKNOWN")
    domain_run_plan_status = str(domain_run_plan.get("status") or "UNKNOWN")
    slo_domain_run_plan_status = str(slo_domain_run_plan.get("status") or "UNKNOWN")
    production_gate_summary = production_gate.get("summary") or {}
    production_gate_status = str(production_gate.get("status") or "UNKNOWN")
    production_gate_requirements = production_gate.get("requirements") or {}
    current_readiness_command = build_current_production_readiness_command(args, run_plan)
    production_profile_command = build_production_profile_command(args, production_gate, run_plan)
    production_acceptance_command = build_production_acceptance_command(args, production_gate, run_plan)
    production_gate_failed_scenarios = failed_production_gate_scenarios(production_gate)
    rich_current_readiness = rich_current_readiness_summary(args.current_readiness_json)
    production_acceptance = production_acceptance_summary(args.production_acceptance_json)
    production_acceptance_requested = bool(args.production_acceptance_json) or production_gate_status == "FAIL"
    production_blockers = production_evidence_blockers(
        production_gate_status,
        production_gate_summary,
        rich_current_readiness,
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

    blockers = []
    blockers.extend(run_plan.get("blockers") or [])
    blockers.extend(domain_run_plan.get("globalBlockers") or [])
    unique_blockers: dict[str, dict[str, Any]] = {}
    for blocker in blockers:
        unique_blockers[str(blocker.get("scenario") or blocker.get("action") or len(unique_blockers))] = blocker

    next_command = ""
    if entrypoint_rescue_blocked:
        next_command = entrypoint_rescue_command or str(run_plan.get("probeCommand") or "")
    elif run_plan.get("probeCommand") and run_plan_status == "BLOCKED_BY_P0":
        next_command = str(run_plan.get("probeCommand") or "")
    elif domain_run_plan.get("probeCommand") and domain_run_plan_status == "BLOCKED_BY_P0":
        next_command = str(domain_run_plan.get("probeCommand") or "")
    elif production_gate_status == "FAIL" and production_profile_command:
        next_command = production_profile_command
    elif domain_run_plan.get("domainPlans"):
        next_command = str((domain_run_plan.get("domainPlans") or [{}])[0].get("runCommand") or "")
    elif slo_domain_run_plan.get("probeCommand") and slo_domain_run_plan_status == "BLOCKED_BY_EXTRA_SLO":
        next_command = str(slo_domain_run_plan.get("probeCommand") or "")
    elif slo_domain_run_plan.get("domainPlans"):
        next_command = str((slo_domain_run_plan.get("domainPlans") or [{}])[0].get("runCommand") or "")
    elif run_plan.get("runCommand"):
        next_command = str(run_plan.get("runCommand") or "")

    payload = {
        "summary": {
            "readinessGate": readiness_status,
            "domainScorecard": overall_status,
            "runPlan": run_plan_status,
            "domainRunPlan": domain_run_plan_status,
            "sloDomainRunPlan": slo_domain_run_plan_status,
            "scenarioStatusCounts": scenario_status.get("latestStatusCounts") or {},
            "sloStatusCounts": slo_status.get("latestSLOStatusCounts") or {},
            "extraSLOStatusCounts": slo_status.get("extraSLOStatusCounts") or {},
            "sloMatrixScenarioCount": slo_status.get("matrixScenarioCount"),
            "sloExtraScenarioCount": slo_status.get("extraScenarioCount"),
            "sloDomainScorecard": (slo_domain_scorecard.get("summary") or {}).get("overallStatus"),
            "sloDomainReadinessCounts": (slo_domain_scorecard.get("summary") or {}).get("readinessCounts") or {},
            "productionGate": production_gate_status,
            "productionGateProfile": production_gate.get("profile"),
            "productionGateRequired": production_gate_summary.get("requiredScenarioCount"),
            "productionGatePassed": production_gate_summary.get("passedScenarioCount"),
            "productionGateFailed": production_gate_summary.get("failedScenarioCount"),
            "productionGateMissing": production_gate_summary.get("missingScenarioCount"),
            "productionGateFailureKinds": production_gate_summary.get("failureKindCounts") or {},
            "productionGateMaxEvidenceAgeSeconds": production_gate_requirements.get("maxEvidenceAgeSeconds"),
            "productionGateEvidenceOldestAgeSeconds": production_gate_summary.get("evidenceOldestAgeSeconds"),
            "productionGateEvidenceNewestAgeSeconds": production_gate_summary.get("evidenceNewestAgeSeconds"),
            "productionGateEvidenceStaleCount": production_gate_summary.get("evidenceStaleCount") or 0,
            "productionGateEvidenceTimeInFutureCount": production_gate_summary.get("evidenceTimeInFutureCount") or 0,
            "productionGateMissingEvidenceTimeCount": production_gate_summary.get("missingEvidenceTimeCount") or 0,
            "productionEvidenceBlockerCount": len(production_blockers),
            "productionEvidenceBlockers": [str(row.get("code") or "") for row in production_blockers],
            "productionEvidenceActionCommands": [str(row.get("role") or "") for row in production_action_commands],
            "entrypointRescueBlocked": entrypoint_rescue_blocked,
            "entrypointRescueStatus": entrypoint_rescue.get("status") or "",
            "entrypointRescueAction": entrypoint_rescue.get("rescuePlanAction") or "",
            "entrypointRescueDiagnosis": entrypoint_rescue.get("entrypointDiagnosis") or "",
            "entrypointRescueDetail": entrypoint_rescue.get("entrypointDetail") or "",
            "entrypointRescueCommand": entrypoint_rescue_command,
            "priorityCounts": next_actions.get("priorityCounts") or {},
            "scenarioCount": (catalog.get("summary") or {}).get("scenarioCount") or scenario_status.get("scenarioCount"),
            "domainCount": (catalog.get("summary") or {}).get("domainCount") or score_summary.get("domainCount"),
            "maturityGapCount": (catalog.get("summary") or {}).get("maturityGapCount"),
            "globalBlockerCount": (backlog.get("summary") or {}).get("globalBlockerCount") or score_summary.get("globalBlockerCount"),
            "prereqStatus": (prereq.get("summary") or {}).get("overallStatus"),
            "readinessFailures": readiness.get("failureCount"),
            **current_readiness,
        },
        "blockers": list(unique_blockers.values()),
        "domains": scorecard.get("domains") or [],
        "topActions": top_actions(next_actions.get("actions") or [], args.action_limit),
        "productionGateFailedScenarios": production_gate_failed_scenarios,
        "productionEvidenceBlockers": production_blockers,
        "productionEvidenceActionCommands": production_action_commands,
        "currentProductionReadinessCommand": current_readiness_command,
        "productionProfileCommand": production_profile_command,
        "productionAcceptanceCommand": production_acceptance_command,
        "nextCommand": next_command,
        "links": {
            "scenarioStatus": args.scenario_status_json,
            "sloStatus": args.slo_status_json,
            "sloDomainScorecard": args.slo_domain_scorecard_json,
            "sloDomainRunPlan": args.slo_domain_run_plan_json,
            "nextActions": args.next_actions_json,
            "scenarioCatalog": args.scenario_catalog_json,
            "domainBacklog": args.domain_backlog_json,
            "runPlan": args.run_plan_json,
            "domainRunPlan": args.domain_run_plan_json,
            "domainScorecard": args.domain_scorecard_json,
            "prereqAudit": args.prereq_audit_json,
            "readinessGate": args.readiness_gate_json,
            "productionGate": args.production_gate_json,
            "entrypointRescueSummary": args.entrypoint_rescue_summary,
            "currentReadiness": args.current_readiness_json,
        },
    }
    return payload


def build_markdown(payload: dict[str, Any]) -> str:
    summary = payload["summary"]
    status_rows = [
        ["Signal", "Value"],
        ["Readiness gate", f"`{summary.get('readinessGate')}`"],
        ["Current readiness", f"`{summary.get('currentReadinessStatus') or '-'}` reason=`{summary.get('currentReadinessReason') or '-'}`"],
        ["Current readiness requested S/PS/B/F", f"`{summary.get('currentReadinessRequestedSmoke') if summary.get('currentReadinessRequestedSmoke') is not None else '-'}`/`{summary.get('currentReadinessRequestedProductScenarioSuite') if summary.get('currentReadinessRequestedProductScenarioSuite') is not None else '-'}`/`{summary.get('currentReadinessRequestedBaseline') if summary.get('currentReadinessRequestedBaseline') is not None else '-'}`/`{summary.get('currentReadinessRequestedFullAcceptance') if summary.get('currentReadinessRequestedFullAcceptance') is not None else '-'}`"],
        ["Current readiness exits S/PS/B/F", f"`{summary.get('currentReadinessSmokeExitCode') if summary.get('currentReadinessSmokeExitCode') is not None else '-'}`/`{summary.get('currentReadinessProductScenarioSuiteExitCode') if summary.get('currentReadinessProductScenarioSuiteExitCode') is not None else '-'}`/`{summary.get('currentReadinessBaselineExitCode') if summary.get('currentReadinessBaselineExitCode') is not None else '-'}`/`{summary.get('currentReadinessFullAcceptanceExitCode') if summary.get('currentReadinessFullAcceptanceExitCode') is not None else '-'}`"],
        ["Current product scenario suite", f"expected=`{summary.get('currentReadinessProductScenarioSuiteExpected') or '-'}` actual=`{summary.get('currentReadinessProductScenarioSuite') or '-'}` status=`{summary.get('currentReadinessProductScenarioSuiteStatus') or '-'}` stages failed/planned=`{summary.get('currentReadinessProductScenarioSuiteFailedStages') if summary.get('currentReadinessProductScenarioSuiteFailedStages') is not None else '-'}`/`{summary.get('currentReadinessProductScenarioSuitePlannedStages') if summary.get('currentReadinessProductScenarioSuitePlannedStages') is not None else '-'}` of `{summary.get('currentReadinessProductScenarioSuiteStageCount') if summary.get('currentReadinessProductScenarioSuiteStageCount') is not None else '-'}` scenarios=`{summary.get('currentReadinessProductScenarioSuiteScenarios') if summary.get('currentReadinessProductScenarioSuiteScenarios') is not None else '-'}` productPlanStages=`{summary.get('currentReadinessProductScenarioSuiteProductPlanStages') if summary.get('currentReadinessProductScenarioSuiteProductPlanStages') is not None else '-'}` largeGroup=`{summary.get('currentReadinessProductScenarioSuiteLargeGroupIncluded') if summary.get('currentReadinessProductScenarioSuiteLargeGroupIncluded') is not None else '-'}`"],
        ["Current full acceptance", f"expected=`{summary.get('currentReadinessFullAcceptanceExpectedCampaign') or '-'}` actual=`{summary.get('currentReadinessFullAcceptanceCampaign') or '-'}` status=`{summary.get('currentReadinessFullAcceptanceStatus') or '-'}` failures=`{summary.get('currentReadinessFullAcceptanceFailures') if summary.get('currentReadinessFullAcceptanceFailures') is not None else '-'}`/`{summary.get('currentReadinessFullAcceptanceRequiredFailures') if summary.get('currentReadinessFullAcceptanceRequiredFailures') is not None else '-'}` attempted/skipped=`{summary.get('currentReadinessFullAcceptanceAttempted') if summary.get('currentReadinessFullAcceptanceAttempted') is not None else '-'}`/`{summary.get('currentReadinessFullAcceptanceSkipped') if summary.get('currentReadinessFullAcceptanceSkipped') is not None else '-'}`"],
        ["Production gate", f"`{summary.get('productionGate')}` profile=`{summary.get('productionGateProfile')}`"],
        ["Production evidence age", f"oldest/newest/max=`{summary.get('productionGateEvidenceOldestAgeSeconds') if summary.get('productionGateEvidenceOldestAgeSeconds') is not None else '-'}`/`{summary.get('productionGateEvidenceNewestAgeSeconds') if summary.get('productionGateEvidenceNewestAgeSeconds') is not None else '-'}`/`{summary.get('productionGateMaxEvidenceAgeSeconds') if summary.get('productionGateMaxEvidenceAgeSeconds') is not None else '-'}` seconds"],
        ["Entrypoint rescue", f"`{summary.get('entrypointRescueStatus') or '-'}` diagnosis=`{summary.get('entrypointRescueDiagnosis') or '-'}` action=`{summary.get('entrypointRescueAction') or '-'}`"],
        ["Domain scorecard", f"`{summary.get('domainScorecard')}`"],
        ["SLO domain scorecard", f"`{summary.get('sloDomainScorecard')}`"],
        ["Run plan", f"`{summary.get('runPlan')}`"],
        ["Domain run plan", f"`{summary.get('domainRunPlan')}`"],
        ["SLO domain run plan", f"`{summary.get('sloDomainRunPlan')}`"],
        ["Prerequisites", f"`{summary.get('prereqStatus')}`"],
        ["Scenarios", f"`{summary.get('scenarioCount')}`"],
        ["Domains", f"`{summary.get('domainCount')}`"],
        ["Maturity gaps", f"`{summary.get('maturityGapCount')}`"],
        ["Global blockers", f"`{summary.get('globalBlockerCount')}`"],
        ["Production required PASS/FAIL/MISSING", f"`{summary.get('productionGatePassed')}/{summary.get('productionGateFailed')}/{summary.get('productionGateMissing')}` of `{summary.get('productionGateRequired')}`"],
    ]

    scenario_counts = summary.get("scenarioStatusCounts") or {}
    slo_counts = summary.get("sloStatusCounts") or {}
    extra_slo_counts = summary.get("extraSLOStatusCounts") or {}
    slo_domain_readiness = summary.get("sloDomainReadinessCounts") or {}
    priority_counts = summary.get("priorityCounts") or {}
    production_failure_kinds = summary.get("productionGateFailureKinds") or {}
    production_failure_text = ", ".join(
        f"{kind}={count}" for kind, count in sorted(production_failure_kinds.items())
    ) or "-"
    production_blocker_text = ", ".join(str(code) for code in summary.get("productionEvidenceBlockers") or []) or "-"
    count_rows = [
        ["Count", "Value"],
        ["Scenario PASS/FAIL/UNKNOWN/NEVER", f"{scenario_counts.get('PASS', 0)}/{scenario_counts.get('FAIL', 0)}/{scenario_counts.get('UNKNOWN', 0)}/{scenario_counts.get('NEVER_RUN', 0)}"],
        ["Matrix SLO PASS/FAIL/UNKNOWN/NEVER", f"{slo_counts.get('PASS', 0)}/{slo_counts.get('FAIL', 0)}/{slo_counts.get('UNKNOWN', 0)}/{slo_counts.get('NEVER_RUN', 0)}"],
        ["Extra SLO FAIL/UNKNOWN/NEVER/PASS", f"{extra_slo_counts.get('FAIL', 0)}/{extra_slo_counts.get('UNKNOWN', 0)}/{extra_slo_counts.get('NEVER_RUN', 0)}/{extra_slo_counts.get('PASS', 0)}"],
        ["SLO domains READY/OPT/EVIDENCE/RUN", f"{slo_domain_readiness.get('READY', 0)}/{slo_domain_readiness.get('NEEDS_SLO_OPTIMIZATION', 0)}/{slo_domain_readiness.get('NEEDS_RUNTIME_EVIDENCE', 0)}/{slo_domain_readiness.get('NEEDS_RUN', 0)}"],
        ["Production gate failure kinds", production_failure_text],
        ["Production evidence blockers", f"{summary.get('productionEvidenceBlockerCount', 0)} {production_blocker_text}"],
        ["Production evidence stale/future/missing-time", f"{summary.get('productionGateEvidenceStaleCount', 0)}/{summary.get('productionGateEvidenceTimeInFutureCount', 0)}/{summary.get('productionGateMissingEvidenceTimeCount', 0)}"],
        ["Actions P0/P1/P2/P3", f"{priority_counts.get('P0', 0)}/{priority_counts.get('P1', 0)}/{priority_counts.get('P2', 0)}/{priority_counts.get('P3', 0)}"],
    ]

    blocker_rows = [["Scenario", "Priority", "Action"]]
    for item in payload.get("blockers") or []:
        blocker_rows.append([
            f"`{item.get('scenario') or '-'}`",
            str(item.get("priority") or "-"),
            str(item.get("action") or item.get("reason") or "")[:180],
        ])

    domain_rows = [["Domain", "Readiness", "Local", "Scenarios", "PASS/FAIL/UNKNOWN/NEVER", "Next"]]
    for row in (payload.get("domains") or [])[:12]:
        next_step = str(row.get("runCommand") or row.get("nextAction") or row.get("reason") or "")
        domain_rows.append([
            str(row.get("domain") or ""),
            str(row.get("readiness") or ""),
            str(row.get("localReadiness") or ""),
            str(row.get("scenarioCount") or 0),
            f"{row.get('pass', 0)}/{row.get('fail', 0)}/{row.get('unknown', 0)}/{row.get('neverRun', 0)}",
            next_step[:180],
        ])

    action_rows = [["Priority", "Scenario", "Category", "Action"]]
    for item in payload.get("topActions") or []:
        action_rows.append([
            str(item.get("priority") or ""),
            f"`{item.get('scenario') or ''}`",
            f"`{item.get('category') or ''}`",
            str(item.get("action") or "")[:180],
        ])

    production_rows = [["Scenario", "Category", "Failure", "SLO", "Reason"]]
    for item in payload.get("productionGateFailedScenarios") or []:
        production_rows.append([
            f"`{item.get('scenario') or ''}`",
            f"`{item.get('category') or ''}`",
            str(item.get("failureKind") or ""),
            str(item.get("latestSLOStatus") or ""),
            str(item.get("reason") or "")[:160],
        ])

    production_blocker_rows = [["Code", "Severity", "Source", "Reason", "Action", "Command Role"]]
    for item in payload.get("productionEvidenceBlockers") or []:
        production_blocker_rows.append([
            f"`{item.get('code') or ''}`",
            str(item.get("severity") or ""),
            str(item.get("source") or ""),
            str(item.get("reason") or "")[:160],
            str(item.get("action") or "")[:180],
            f"`{item.get('commandRole') or '-'}`",
        ])

    lines = [
        "# Performance Dashboard",
        "",
        "## Status",
        "",
        markdown_table(status_rows),
        "",
        "## Counts",
        "",
        markdown_table(count_rows),
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
            markdown_table(production_rows),
            "",
        ])
    if len(production_blocker_rows) > 1:
        lines.extend([
            "## Production Evidence Blockers",
            "",
            markdown_table(production_blocker_rows),
            "",
        ])
    if payload.get("productionEvidenceActionCommands"):
        lines.extend([
            "## Production Evidence Commands",
            "",
        ])
        for item in payload.get("productionEvidenceActionCommands") or []:
            lines.extend([
                f"### {item.get('role') or 'production-evidence'}",
                "",
                "```bash",
                str(item.get("command") or ""),
                "```",
                "",
            ])
    if len(blocker_rows) > 1:
        lines.extend(["## Blockers", "", markdown_table(blocker_rows), ""])
    lines.extend([
        "## Domains",
        "",
        markdown_table(domain_rows) if len(domain_rows) > 1 else "No domain scorecard data.",
        "",
        "## Top Actions",
        "",
        markdown_table(action_rows) if len(action_rows) > 1 else "No open actions.",
        "",
        "## Source Files",
        "",
    ])
    for name, path in payload.get("links", {}).items():
        if path:
            lines.append(f"- {name}: `{path}`")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Build a single dashboard from performance status, plans, gates, and domain reports.")
    parser.add_argument("--scenario-status-json")
    parser.add_argument("--slo-status-json")
    parser.add_argument("--slo-domain-scorecard-json")
    parser.add_argument("--next-actions-json")
    parser.add_argument("--scenario-catalog-json")
    parser.add_argument("--domain-backlog-json")
    parser.add_argument("--run-plan-json")
    parser.add_argument("--domain-run-plan-json")
    parser.add_argument("--slo-domain-run-plan-json")
    parser.add_argument("--domain-scorecard-json")
    parser.add_argument("--prereq-audit-json")
    parser.add_argument("--readiness-gate-json")
    parser.add_argument("--production-gate-json")
    parser.add_argument("--entrypoint-rescue-summary")
    parser.add_argument("--current-readiness-json")
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
    args = parser.parse_args()
    if args.action_limit <= 0:
        parser.error("--action-limit must be greater than 0")

    payload = build_dashboard(args)
    markdown = build_markdown(payload)
    if args.output:
        Path(args.output).write_text(markdown)
    else:
        print(markdown)
    if args.json_output:
        Path(args.json_output).write_text(json.dumps(payload, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
