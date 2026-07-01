#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from perf_production_next_step import (
    build_current_production_readiness_command,
    build_production_acceptance_command,
    build_production_profile_command,
    failed_production_gate_scenarios,
)


def read_json(path: Path | None) -> dict[str, Any]:
    if path is None:
        return {}
    try:
        return json.loads(path.read_text())
    except Exception as exc:
        raise SystemExit(f"Failed to read JSON {path}: {exc}") from exc


def add_check(checks: list[dict[str, Any]], name: str, passed: bool, detail: str, severity: str = "FAIL") -> None:
    checks.append({
        "name": name,
        "status": "PASS" if passed else severity,
        "passed": passed,
        "detail": detail,
    })


def build_gate(args: argparse.Namespace) -> dict[str, Any]:
    coverage = read_json(Path(args.coverage_json) if args.coverage_json else None)
    route = read_json(Path(args.route_audit_json) if args.route_audit_json else None)
    matrix = read_json(Path(args.matrix_audit_json) if args.matrix_audit_json else None)
    scorecard = read_json(Path(args.domain_scorecard_json) if args.domain_scorecard_json else None)
    prereq = read_json(Path(args.prereq_audit_json) if args.prereq_audit_json else None)
    slo_status = read_json(Path(args.slo_status_json) if args.slo_status_json else None)
    slo_domain_scorecard = read_json(Path(args.slo_domain_scorecard_json) if args.slo_domain_scorecard_json else None)
    production_gate = read_json(Path(args.production_gate_json) if args.production_gate_json else None)
    run_plan = read_json(Path(args.run_plan_json) if args.run_plan_json else None)

    checks: list[dict[str, Any]] = []
    if coverage:
        missing = int(coverage.get("uncoveredCriticalEndpointCount") or 0)
        add_check(
            checks,
            "critical-coverage",
            missing == 0,
            f"coveredCritical={coverage.get('coveredCriticalEndpointCount')}/{coverage.get('criticalEndpointCount')} missing={missing}",
        )
    if route:
        missing_routes = int(route.get("missingManifestRouteCount") or 0)
        orphan_routes = int(route.get("orphanCoverageEndpointCount") or 0)
        add_check(
            checks,
            "route-audit",
            missing_routes == 0 and orphan_routes == 0,
            f"missingManifest={missing_routes} orphanCoverage={orphan_routes}",
        )
    if matrix:
        errors = int(matrix.get("errorCount") or 0)
        add_check(
            checks,
            "matrix-audit",
            errors == 0,
            f"scenarios={matrix.get('listedScenarioCount')} errors={errors} warnings={matrix.get('warningCount')}",
        )
    if prereq:
        status = str((prereq.get("summary") or {}).get("overallStatus") or "UNKNOWN")
        allowed = {"READY"}
        if args.allow_no_planned_scenarios:
            allowed.add("NO_PLANNED_SCENARIOS")
        add_check(
            checks,
            "prerequisites",
            status in allowed,
            f"status={status} missingRequired={(prereq.get('summary') or {}).get('missingRequiredCount')} missingRecommended={(prereq.get('summary') or {}).get('missingRecommendedCount')}",
        )
    if scorecard:
        summary = scorecard.get("summary") or {}
        status = str(summary.get("overallStatus") or "UNKNOWN")
        allowed_statuses = {"READY"}
        if args.allow_runtime_evidence_gap:
            allowed_statuses.add("NEEDS_RUNTIME_EVIDENCE")
        if args.allow_baseline_capacity_gap:
            allowed_statuses.add("NEEDS_BASELINE_CAPACITY")
        if args.allow_entrypoint_blocker:
            allowed_statuses.add("BLOCKED_BY_P0")
        add_check(
            checks,
            "domain-scorecard",
            status in allowed_statuses,
            f"status={status} domains={summary.get('domainCount')} globalBlockers={summary.get('globalBlockerCount')} openActions={summary.get('openActionCount')}",
        )
    if slo_status:
        matrix_counts = slo_status.get("latestSLOStatusCounts") or {}
        extra_counts = slo_status.get("extraSLOStatusCounts") or {}
        matrix_fail = int(matrix_counts.get("FAIL") or 0)
        matrix_unknown = int(matrix_counts.get("UNKNOWN") or 0)
        matrix_never = int(matrix_counts.get("NEVER_RUN") or 0)
        extra_fail = int(extra_counts.get("FAIL") or 0)
        passed = (
            matrix_fail == 0
            and (matrix_unknown == 0 or args.allow_slo_runtime_evidence_gap)
            and (matrix_never == 0 or args.allow_slo_never_run_gap)
            and (extra_fail == 0 or args.allow_extra_slo_failure)
        )
        add_check(
            checks,
            "slo-status",
            passed,
            (
                f"matrix PASS/FAIL/UNKNOWN/NEVER="
                f"{matrix_counts.get('PASS', 0)}/{matrix_fail}/{matrix_unknown}/{matrix_never} "
                f"extra FAIL/UNKNOWN/NEVER/PASS="
                f"{extra_fail}/{extra_counts.get('UNKNOWN', 0)}/{extra_counts.get('NEVER_RUN', 0)}/{extra_counts.get('PASS', 0)}"
            ),
        )
    if slo_domain_scorecard:
        summary = slo_domain_scorecard.get("summary") or {}
        status = str(summary.get("overallStatus") or "UNKNOWN")
        allowed_statuses = {"READY"}
        if args.allow_slo_runtime_evidence_gap:
            allowed_statuses.add("NEEDS_RUNTIME_EVIDENCE")
        if args.allow_slo_never_run_gap:
            allowed_statuses.add("NEEDS_RUN")
        if args.allow_extra_slo_failure:
            allowed_statuses.add("BLOCKED_BY_EXTRA_SLO")
        add_check(
            checks,
            "slo-domain-scorecard",
            status in allowed_statuses,
            f"status={status} domains={summary.get('domainCount')} readinessCounts={summary.get('readinessCounts')}",
        )
    if production_gate:
        summary = production_gate.get("summary") or {}
        status = str(production_gate.get("status") or "UNKNOWN")
        failure_kind_counts = summary.get("failureKindCounts") or {}
        failure_kind_text = ",".join(
            f"{kind}={count}" for kind, count in sorted(failure_kind_counts.items())
        ) or "-"
        add_check(
            checks,
            "production-gate",
            status == "PASS" or args.allow_production_gate_failure,
            (
                f"status={status} profile={production_gate.get('profile')} "
                f"required={summary.get('requiredScenarioCount')} "
                f"passed={summary.get('passedScenarioCount')} "
                f"failed={summary.get('failedScenarioCount')} "
                f"missing={summary.get('missingScenarioCount')} "
                f"failureKinds={failure_kind_text}"
            ),
        )

    if not checks:
        add_check(checks, "input", False, "No gate input JSON files were provided.")

    failed = [item for item in checks if item["status"] == "FAIL"]
    warnings = [item for item in checks if item["status"] == "WARN"]
    next_command = ""
    production_gate_failed_scenarios: list[dict[str, Any]] = []
    current_readiness_command = ""
    production_profile_command = ""
    production_acceptance_command = ""
    production_action_commands: list[dict[str, str]] = []
    if production_gate:
        production_gate_failed_scenarios = failed_production_gate_scenarios(production_gate)
        current_readiness_command = build_current_production_readiness_command(args, run_plan)
        production_profile_command = build_production_profile_command(args, production_gate, run_plan)
        production_acceptance_command = build_production_acceptance_command(args, production_gate, run_plan)
        production_action_commands = [
            {"role": role, "command": command}
            for role, command in [
                ("production-profile", production_profile_command),
                ("current-production-readiness", current_readiness_command),
                ("production-acceptance", production_acceptance_command),
            ]
            if command
        ]
        if str(production_gate.get("status") or "") == "FAIL" and production_profile_command:
            next_command = production_profile_command

    return {
        "status": "PASS" if not failed else "FAIL",
        "failureCount": len(failed),
        "warningCount": len(warnings),
        "checks": checks,
        "nextCommand": next_command,
        "currentProductionReadinessCommand": current_readiness_command,
        "productionProfileCommand": production_profile_command,
        "productionAcceptanceCommand": production_acceptance_command,
        "productionEvidenceActionCommands": production_action_commands,
        "productionGateFailedScenarios": production_gate_failed_scenarios,
    }


def build_text(payload: dict[str, Any]) -> str:
    lines = [
        f"Performance readiness gate: {payload['status']}",
        f"failures={payload['failureCount']} warnings={payload['warningCount']}",
    ]
    for item in payload["checks"]:
        lines.append(f"{item['status']} {item['name']}: {item['detail']}")
    if payload.get("nextCommand"):
        lines.append(f"nextCommand={payload['nextCommand']}")
    for item in payload.get("productionEvidenceActionCommands") or []:
        lines.append(f"productionEvidenceCommand[{item.get('role')}]={item.get('command')}")
    if payload.get("productionGateFailedScenarios"):
        scenarios = ",".join(str(row.get("scenario") or "") for row in payload["productionGateFailedScenarios"])
        lines.append(f"productionGateFailedScenarios={scenarios}")
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Gate global performance readiness from audits, prerequisites, and domain scorecard.")
    parser.add_argument("--coverage-json")
    parser.add_argument("--route-audit-json")
    parser.add_argument("--matrix-audit-json")
    parser.add_argument("--domain-scorecard-json")
    parser.add_argument("--prereq-audit-json")
    parser.add_argument("--slo-status-json")
    parser.add_argument("--slo-domain-scorecard-json")
    parser.add_argument("--production-gate-json")
    parser.add_argument("--run-plan-json")
    parser.add_argument("--base-url")
    parser.add_argument("--tcp-host")
    parser.add_argument("--tcp-port")
    parser.add_argument("--account-file")
    parser.add_argument("--conversation-id")
    parser.add_argument("--require-internal-secret", action="store_true")
    parser.add_argument("--allow-entrypoint-blocker", action="store_true")
    parser.add_argument("--allow-runtime-evidence-gap", action="store_true")
    parser.add_argument("--allow-baseline-capacity-gap", action="store_true")
    parser.add_argument("--allow-no-planned-scenarios", action="store_true")
    parser.add_argument("--allow-slo-runtime-evidence-gap", action="store_true")
    parser.add_argument("--allow-slo-never-run-gap", action="store_true")
    parser.add_argument("--allow-extra-slo-failure", action="store_true")
    parser.add_argument("--allow-production-gate-failure", action="store_true")
    parser.add_argument("--output", help="Write human-readable gate output.")
    parser.add_argument("--json-output", help="Write machine-readable gate output.")
    args = parser.parse_args()

    payload = build_gate(args)
    text = build_text(payload)
    if args.output:
        Path(args.output).write_text(text)
    else:
        print(text, end="")
    if args.json_output:
        Path(args.json_output).write_text(json.dumps(payload, indent=2, sort_keys=True))
    return 1 if payload["status"] != "PASS" else 0


if __name__ == "__main__":
    raise SystemExit(main())
