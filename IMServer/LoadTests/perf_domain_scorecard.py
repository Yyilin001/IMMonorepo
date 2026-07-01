#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Any


def read_json(path: Path | None) -> dict[str, Any]:
    if path is None:
        return {}
    try:
        return json.loads(path.read_text())
    except Exception as exc:
        raise SystemExit(f"Failed to read JSON {path}: {exc}") from exc


def domain_run_commands(plan: dict[str, Any]) -> dict[str, str]:
    commands: dict[str, str] = {}
    for item in plan.get("domainPlans") or []:
        domain = str(item.get("domain") or "")
        command = str(item.get("runCommand") or "")
        if domain and command:
            commands[domain] = command
    return commands


def local_readiness(row: dict[str, Any]) -> tuple[str, str]:
    counts = row.get("priorityCounts") or {}
    if int(counts.get("P1") or 0) > 0 or int(row.get("fail") or 0) > 0:
        return "NEEDS_OPTIMIZATION", "One or more scenarios failed; optimize this domain before expanding load."
    if int(counts.get("P2") or 0) > 0:
        return "NEEDS_RUNTIME_EVIDENCE", "Smoke/custom scenarios still need real, parseable runtime evidence."
    if int(counts.get("P3") or 0) > 0:
        return "NEEDS_BASELINE_CAPACITY", "Smoke evidence is not enough yet; run baseline/capacity scenarios for this domain."
    if int(row.get("openActionCount") or 0) > 0:
        return "NEEDS_TRIAGE", "Open actions remain; inspect domain-backlog for the next step."
    if int(row.get("scenarioCount") or 0) == 0:
        return "NO_SCENARIOS", "No scenarios are mapped to this domain."
    return "READY", "No open actions remain for this domain."


def effective_readiness(local: str, global_blockers: int) -> str:
    if global_blockers > 0 and local != "NO_SCENARIOS":
        return "BLOCKED_BY_GLOBAL_P0"
    return local


def overall_status(rows: list[dict[str, Any]], global_blockers: int) -> str:
    if global_blockers > 0:
        return "BLOCKED_BY_P0"
    order = [
        "NEEDS_OPTIMIZATION",
        "NEEDS_RUNTIME_EVIDENCE",
        "NEEDS_BASELINE_CAPACITY",
        "NEEDS_TRIAGE",
        "NO_SCENARIOS",
    ]
    statuses = {str(row.get("localReadiness") or "") for row in rows}
    for status in order:
        if status in statuses:
            return status
    return "READY"


def build_scorecard(backlog: dict[str, Any], run_plan: dict[str, Any]) -> dict[str, Any]:
    summary = backlog.get("summary") or {}
    global_blockers = int(summary.get("globalBlockerCount") or 0)
    commands = domain_run_commands(run_plan)
    rows: list[dict[str, Any]] = []

    for row in backlog.get("domains") or []:
        domain = str(row.get("domain") or "")
        if domain == "preflight":
            continue
        local, reason = local_readiness(row)
        effective = effective_readiness(local, global_blockers)
        counts = row.get("priorityCounts") or {}
        rows.append({
            "domain": domain,
            "readiness": effective,
            "localReadiness": local,
            "reason": reason,
            "scenarioCount": int(row.get("scenarioCount") or 0),
            "familyCount": int(row.get("familyCount") or 0),
            "pass": int(row.get("pass") or 0),
            "fail": int(row.get("fail") or 0),
            "unknown": int(row.get("unknown") or 0),
            "neverRun": int(row.get("neverRun") or 0),
            "openActionCount": int(row.get("openActionCount") or 0),
            "P0": int(counts.get("P0") or 0),
            "P1": int(counts.get("P1") or 0),
            "P2": int(counts.get("P2") or 0),
            "P3": int(counts.get("P3") or 0),
            "P4": int(counts.get("P4") or 0),
            "optimizationFocus": str(row.get("hint") or ""),
            "nextAction": str(row.get("nextAction") or ""),
            "runCommand": commands.get(domain, ""),
        })

    rows.sort(key=lambda item: (
        {
            "BLOCKED_BY_GLOBAL_P0": 0,
            "NEEDS_OPTIMIZATION": 1,
            "NEEDS_RUNTIME_EVIDENCE": 2,
            "NEEDS_BASELINE_CAPACITY": 3,
            "NEEDS_TRIAGE": 4,
            "NO_SCENARIOS": 5,
            "READY": 6,
        }.get(str(item["readiness"]), 9),
        -int(item["openActionCount"]),
        str(item["domain"]),
    ))

    status = overall_status(rows, global_blockers)
    readiness_counts: dict[str, int] = {}
    local_counts: dict[str, int] = {}
    for row in rows:
        readiness_counts[row["readiness"]] = readiness_counts.get(row["readiness"], 0) + 1
        local_counts[row["localReadiness"]] = local_counts.get(row["localReadiness"], 0) + 1

    return {
        "summary": {
            "overallStatus": status,
            "domainCount": len(rows),
            "scenarioCount": int(summary.get("scenarioCount") or 0),
            "globalBlockerCount": global_blockers,
            "openActionCount": int(summary.get("openActionCount") or 0),
            "priorityCounts": summary.get("priorityCounts") or {},
            "readinessCounts": readiness_counts,
            "localReadinessCounts": local_counts,
            "hasDomainRunCommands": bool(commands),
        },
        "globalBlockers": list(backlog.get("globalBlockers") or []),
        "domains": rows,
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


def build_markdown(backlog_path: Path, run_plan_path: Path | None, payload: dict[str, Any]) -> str:
    summary = payload["summary"]
    priority = summary["priorityCounts"]
    readiness_rows = [["Readiness", "Domains"]]
    for status, count in sorted(summary["readinessCounts"].items()):
        readiness_rows.append([status, str(count)])

    domain_rows = [["Domain", "Readiness", "Local", "Scenarios", "PASS/FAIL/UNKNOWN/NEVER", "P1/P2/P3", "Next"]]
    for row in payload["domains"]:
        next_step = row["runCommand"] or row["nextAction"] or row["reason"]
        domain_rows.append([
            str(row["domain"]),
            str(row["readiness"]),
            str(row["localReadiness"]),
            str(row["scenarioCount"]),
            f"{row['pass']}/{row['fail']}/{row['unknown']}/{row['neverRun']}",
            f"{row['P1']}/{row['P2']}/{row['P3']}",
            str(next_step)[:180],
        ])

    blocker_lines: list[str] = []
    if payload["globalBlockers"]:
        blocker_lines.extend([
            "## Global Blockers",
            "",
            "These block all runtime readiness conclusions:",
            "",
        ])
        for item in payload["globalBlockers"]:
            blocker_lines.append(f"- `{item.get('scenario')}`: {item.get('action') or item.get('reason')}")
        blocker_lines.append("")

    return "\n".join([
        "# Performance Domain Scorecard",
        "",
        f"- domainBacklog: `{backlog_path}`",
        f"- domainRunPlan: `{run_plan_path or '-'}`",
        f"- overallStatus: `{summary['overallStatus']}`",
        f"- domains: `{summary['domainCount']}`",
        f"- scenarios: `{summary['scenarioCount']}`",
        f"- global blockers: `{summary['globalBlockerCount']}`",
        f"- open actions: `{summary['openActionCount']}`",
        f"- priorities: `P0={priority.get('P0', 0)} P1={priority.get('P1', 0)} P2={priority.get('P2', 0)} P3={priority.get('P3', 0)}`",
        f"- has domain run commands: `{summary['hasDomainRunCommands']}`",
        "",
        *blocker_lines,
        "## Readiness Summary",
        "",
        markdown_table(readiness_rows),
        "",
        "## Domains",
        "",
        markdown_table(domain_rows),
        "",
    ])


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    fieldnames = [
        "domain",
        "readiness",
        "localReadiness",
        "reason",
        "scenarioCount",
        "familyCount",
        "pass",
        "fail",
        "unknown",
        "neverRun",
        "openActionCount",
        "P0",
        "P1",
        "P2",
        "P3",
        "P4",
        "optimizationFocus",
        "nextAction",
        "runCommand",
    ]
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def main() -> int:
    parser = argparse.ArgumentParser(description="Build a domain readiness scorecard from performance domain backlog and run plan.")
    parser.add_argument("--domain-backlog", required=True, help="Path to perf_domain_backlog.py JSON output.")
    parser.add_argument("--domain-run-plan", help="Optional perf_domain_run_plan.py JSON output.")
    parser.add_argument("--output", help="Write Markdown scorecard.")
    parser.add_argument("--json-output", help="Write machine-readable scorecard.")
    parser.add_argument("--csv-output", help="Write scorecard CSV.")
    parser.add_argument("--strict", action="store_true", help="Exit non-zero unless overallStatus is READY.")
    args = parser.parse_args()

    backlog_path = Path(args.domain_backlog)
    run_plan_path = Path(args.domain_run_plan) if args.domain_run_plan else None
    payload = build_scorecard(read_json(backlog_path), read_json(run_plan_path))
    markdown = build_markdown(backlog_path, run_plan_path, payload)

    if args.output:
        Path(args.output).write_text(markdown)
    else:
        print(markdown)
    if args.json_output:
        Path(args.json_output).write_text(json.dumps(payload, indent=2, sort_keys=True))
    if args.csv_output:
        write_csv(Path(args.csv_output), payload["domains"])
    return 1 if args.strict and payload["summary"]["overallStatus"] != "READY" else 0


if __name__ == "__main__":
    raise SystemExit(main())
