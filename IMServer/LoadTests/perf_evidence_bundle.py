#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from perf_triage import triage_records


def read_json(path: Path | None) -> dict[str, Any]:
    if path is None:
        return {}
    try:
        return json.loads(path.read_text())
    except Exception as exc:
        raise SystemExit(f"Failed to read JSON {path}: {exc}") from exc


def bool_status(value: bool) -> str:
    return "PASS" if value else "FAIL"


def has_entrypoint_issue(issues: list[dict[str, Any]]) -> bool:
    return any(item.get("issueType") == "entrypoint" for item in issues)


def has_prerequisite_issue(issues: list[dict[str, Any]]) -> bool:
    return any(item.get("issueType") == "prerequisites" for item in issues)


def issue_priority_counts(issues: list[dict[str, Any]]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for issue in issues:
        priority = str(issue.get("priority", "P?"))
        counts[priority] = counts.get(priority, 0) + 1
    return counts


def derive_outcome(
    report: dict[str, Any],
    issues: list[dict[str, Any]],
    coverage: dict[str, Any],
    route_audit: dict[str, Any],
    matrix_audit: dict[str, Any],
) -> tuple[str, str]:
    coverage_ok = not coverage or int(coverage.get("uncoveredCriticalEndpointCount") or 0) == 0
    route_ok = not route_audit or (
        int(route_audit.get("missingManifestRouteCount") or 0) == 0
        and int(route_audit.get("orphanCoverageEndpointCount") or 0) == 0
    )
    matrix_ok = not matrix_audit or int(matrix_audit.get("errorCount") or 0) == 0
    if not coverage_ok:
        return "AUDIT_FAILED", "Critical endpoint coverage has gaps; add scenarios or explicitly downgrade scope before trusting runtime numbers."
    if not route_ok:
        return "AUDIT_FAILED", "Server route inventory and performance coverage manifest are out of sync."
    if not matrix_ok:
        return "AUDIT_FAILED", "Scenario matrix is inconsistent; fix runner/list/group/script references before running capacity tests."
    if has_prerequisite_issue(issues):
        return "BLOCKED_PREREQUISITES", "Local scenario prerequisites are missing; fix ACCOUNT_FILE, IM_CONVERSATION_ID, or selected scenario inputs before running the matrix."
    if has_entrypoint_issue(issues):
        return "BLOCKED_ENTRYPOINT", "HTTP entrypoint is failing before reliable performance data can be collected."
    if int(report.get("failed") or 0) > 0:
        return "NEEDS_OPTIMIZATION", "One or more scenarios failed; use the priority queue to choose the next code/config optimization."
    if int(report.get("unknown") or 0) > 0:
        return "INCOMPLETE_ARTIFACTS", "One or more scenarios produced no parseable artifacts; rerun or inspect scenario stdout."
    if issues:
        return "NEEDS_TRIAGE", "Open triage issues remain even though the report did not count them as failed."
    return "PASS", "Coverage, audits, and runtime report are clean for this run."


def markdown_table(rows: list[list[str]]) -> str:
    if not rows:
        return ""
    lines = [
        "| " + " | ".join(rows[0]) + " |",
        "| " + " | ".join(["---"] * len(rows[0])) + " |",
    ]
    for row in rows[1:]:
        lines.append("| " + " | ".join(row) + " |")
    return "\n".join(lines)


def build_bundle(
    report_path: Path,
    report: dict[str, Any],
    issues: list[dict[str, Any]],
    coverage: dict[str, Any],
    route_audit: dict[str, Any],
    matrix_audit: dict[str, Any],
) -> tuple[str, dict[str, Any]]:
    outcome, recommendation = derive_outcome(report, issues, coverage, route_audit, matrix_audit)
    priorities = issue_priority_counts(issues)
    coverage_summary = {
        "endpointCount": coverage.get("endpointCount"),
        "criticalEndpointCount": coverage.get("criticalEndpointCount"),
        "coveredCriticalEndpointCount": coverage.get("coveredCriticalEndpointCount"),
        "uncoveredCriticalEndpointCount": coverage.get("uncoveredCriticalEndpointCount"),
        "uncoveredOptionalEndpointCount": coverage.get("uncoveredOptionalEndpointCount"),
    } if coverage else {}
    route_summary = {
        "sourceRouteCount": route_audit.get("sourceRouteCount"),
        "missingManifestRouteCount": route_audit.get("missingManifestRouteCount"),
        "orphanCoverageEndpointCount": route_audit.get("orphanCoverageEndpointCount"),
        "ignoredSourceRouteCount": route_audit.get("ignoredSourceRouteCount"),
    } if route_audit else {}
    matrix_summary = {
        "listedScenarioCount": matrix_audit.get("listedScenarioCount"),
        "caseScenarioCount": matrix_audit.get("caseScenarioCount"),
        "k6ScenarioCount": matrix_audit.get("k6ScenarioCount"),
        "errorCount": matrix_audit.get("errorCount"),
        "warningCount": matrix_audit.get("warningCount"),
    } if matrix_audit else {}

    gate_rows = [["Check", "Status", "Detail"]]
    gate_rows.append([
        "Runtime report",
        bool_status(int(report.get("failed") or 0) == 0 and int(report.get("unknown") or 0) == 0),
        f"scenarios={report.get('scenarioCount', len(report.get('scenarios') or []))}, failed={report.get('failed', 0)}, unknown={report.get('unknown', 0)}",
    ])
    if coverage:
        gate_rows.append([
            "Coverage",
            bool_status(int(coverage.get("uncoveredCriticalEndpointCount") or 0) == 0),
            f"critical={coverage.get('coveredCriticalEndpointCount')}/{coverage.get('criticalEndpointCount')}, optionalGaps={coverage.get('uncoveredOptionalEndpointCount')}",
        ])
    if route_audit:
        gate_rows.append([
            "Route audit",
            bool_status(int(route_audit.get("missingManifestRouteCount") or 0) == 0 and int(route_audit.get("orphanCoverageEndpointCount") or 0) == 0),
            f"source={route_audit.get('sourceRouteCount')}, missing={route_audit.get('missingManifestRouteCount')}, orphan={route_audit.get('orphanCoverageEndpointCount')}",
        ])
    if matrix_audit:
        gate_rows.append([
            "Matrix audit",
            bool_status(int(matrix_audit.get("errorCount") or 0) == 0),
            f"scenarios={matrix_audit.get('listedScenarioCount')}, errors={matrix_audit.get('errorCount')}, warnings={matrix_audit.get('warningCount')}",
        ])

    issue_rows = [["Priority", "Scenario", "Category", "Issue", "Action"]]
    for issue in issues[:20]:
        issue_rows.append([
            str(issue.get("priority", "")),
            f"`{issue.get('name', '')}`",
            f"`{issue.get('category', '')}`",
            str(issue.get("issueType", "")),
            str(issue.get("action", "")),
        ])

    markdown = "\n".join([
        "# Performance Evidence Bundle",
        "",
        f"- report: `{report_path}`",
        f"- outcome: `{outcome}`",
        f"- recommendation: {recommendation}",
        f"- open issues: `{len(issues)}`",
        f"- priority counts: `{json.dumps(priorities, sort_keys=True)}`",
        "",
        "## Gates",
        "",
        markdown_table(gate_rows),
        "",
        "## Priority Queue",
        "",
        markdown_table(issue_rows) if issues else "No open issues.",
        "",
    ])
    payload = {
        "report": str(report_path),
        "outcome": outcome,
        "recommendation": recommendation,
        "openIssueCount": len(issues),
        "priorityCounts": priorities,
        "runtime": {
            "scenarioCount": report.get("scenarioCount", len(report.get("scenarios") or [])),
            "failed": report.get("failed", 0),
            "unknown": report.get("unknown", 0),
        },
        "coverage": coverage_summary,
        "routeAudit": route_summary,
        "matrixAudit": matrix_summary,
        "issues": issues,
    }
    return markdown, payload


def main() -> int:
    parser = argparse.ArgumentParser(description="Build a single evidence bundle from performance report, triage, and audit JSON files.")
    parser.add_argument("--report", required=True, help="Path to run report.json.")
    parser.add_argument("--triage-json", help="Optional precomputed triage.json. If omitted, triage is derived from report.json.")
    parser.add_argument("--coverage-json", help="Optional perf_coverage.py JSON output.")
    parser.add_argument("--route-audit-json", help="Optional perf_route_audit.py JSON output.")
    parser.add_argument("--matrix-audit-json", help="Optional perf_matrix_audit.py JSON output.")
    parser.add_argument("--output", help="Write Markdown evidence bundle.")
    parser.add_argument("--json-output", help="Write machine-readable evidence bundle JSON.")
    parser.add_argument("--strict", action="store_true", help="Exit non-zero unless outcome is PASS.")
    args = parser.parse_args()

    report_path = Path(args.report)
    report = read_json(report_path)
    if args.triage_json:
        triage = read_json(Path(args.triage_json))
        issues = list(triage.get("issues") or [])
    else:
        issues = triage_records(report)
    coverage = read_json(Path(args.coverage_json)) if args.coverage_json else {}
    route_audit = read_json(Path(args.route_audit_json)) if args.route_audit_json else {}
    matrix_audit = read_json(Path(args.matrix_audit_json)) if args.matrix_audit_json else {}

    markdown, payload = build_bundle(report_path, report, issues, coverage, route_audit, matrix_audit)
    if args.output:
        Path(args.output).write_text(markdown)
    else:
        print(markdown)
    if args.json_output:
        Path(args.json_output).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    if args.strict and payload["outcome"] != "PASS":
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
