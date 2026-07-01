#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Any

from perf_scenario_catalog import domain_for


def read_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text())
    except Exception as exc:
        raise SystemExit(f"Failed to read JSON {path}: {exc}") from exc


def readiness_for(row: dict[str, Any]) -> tuple[str, str]:
    if int(row.get("fail") or 0) > 0:
        return "NEEDS_SLO_OPTIMIZATION", "At least one scenario is failing its SLO; optimize the slowest failing path before expanding load."
    if int(row.get("unknown") or 0) > 0:
        return "NEEDS_RUNTIME_EVIDENCE", "At least one scenario ran without parseable SLO evidence; rerun or fix artifacts."
    if int(row.get("neverRun") or 0) > 0:
        return "NEEDS_RUN", "SLO evidence is missing for one or more scenarios; run smoke first, then baseline/capacity."
    if int(row.get("pass") or 0) > 0:
        return "READY", "All represented SLO scenarios in this domain are passing."
    return "NO_SCENARIOS", "No matrix scenarios are mapped to this domain."


def overall_status(rows: list[dict[str, Any]], extra_fail: int) -> str:
    if extra_fail > 0:
        return "BLOCKED_BY_EXTRA_SLO"
    order = ["NEEDS_SLO_OPTIMIZATION", "NEEDS_RUNTIME_EVIDENCE", "NEEDS_RUN", "NO_SCENARIOS"]
    statuses = {str(row.get("readiness") or "") for row in rows}
    for status in order:
        if status in statuses:
            return status
    return "READY"


def build_scorecard(slo_status: dict[str, Any]) -> dict[str, Any]:
    domains: dict[str, dict[str, Any]] = {}
    extra_rows: list[dict[str, Any]] = []

    for scenario in slo_status.get("scenarios") or []:
        is_matrix = bool(scenario.get("isMatrixScenario"))
        category = str(scenario.get("category") or "")
        name = str(scenario.get("scenario") or "")
        status = str(scenario.get("latestSLOStatus") or "UNKNOWN")
        if not is_matrix:
            extra_rows.append(scenario)
            continue
        domain = domain_for(category, name)
        row = domains.setdefault(domain, {
            "domain": domain,
            "scenarioCount": 0,
            "pass": 0,
            "fail": 0,
            "unknown": 0,
            "neverRun": 0,
            "sampleScenarios": [],
        })
        row["scenarioCount"] += 1
        if status == "PASS":
            row["pass"] += 1
        elif status == "FAIL":
            row["fail"] += 1
        elif status == "NEVER_RUN":
            row["neverRun"] += 1
        else:
            row["unknown"] += 1
        if status != "PASS" and len(row["sampleScenarios"]) < 5:
            row["sampleScenarios"].append({
                "scenario": name,
                "status": status,
                "reason": str(scenario.get("latestReason") or scenario.get("latestAction") or ""),
            })

    rows = []
    for row in domains.values():
        readiness, reason = readiness_for(row)
        row["readiness"] = readiness
        row["reason"] = reason
        rows.append(row)

    rows.sort(key=lambda item: (
        {
            "NEEDS_SLO_OPTIMIZATION": 0,
            "NEEDS_RUNTIME_EVIDENCE": 1,
            "NEEDS_RUN": 2,
            "NO_SCENARIOS": 3,
            "READY": 4,
        }.get(str(item["readiness"]), 9),
        -int(item["fail"]),
        -int(item["unknown"]),
        -int(item["neverRun"]),
        str(item["domain"]),
    ))

    readiness_counts: dict[str, int] = {}
    for row in rows:
        readiness_counts[row["readiness"]] = readiness_counts.get(row["readiness"], 0) + 1

    extra_counts = {
        "FAIL": sum(1 for row in extra_rows if row.get("latestSLOStatus") == "FAIL"),
        "UNKNOWN": sum(1 for row in extra_rows if row.get("latestSLOStatus") == "UNKNOWN"),
        "NEVER_RUN": sum(1 for row in extra_rows if row.get("latestSLOStatus") == "NEVER_RUN"),
        "PASS": sum(1 for row in extra_rows if row.get("latestSLOStatus") == "PASS"),
    }

    return {
        "summary": {
            "overallStatus": overall_status(rows, extra_counts["FAIL"]),
            "domainCount": len(rows),
            "matrixScenarioCount": int(slo_status.get("matrixScenarioCount") or 0),
            "extraScenarioCount": int(slo_status.get("extraScenarioCount") or 0),
            "matrixSLOStatusCounts": slo_status.get("latestSLOStatusCounts") or {},
            "extraSLOStatusCounts": extra_counts,
            "readinessCounts": readiness_counts,
        },
        "domains": rows,
        "extraScenarios": extra_rows,
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


def build_markdown(slo_status_path: Path, payload: dict[str, Any]) -> str:
    summary = payload["summary"]
    matrix_counts = summary["matrixSLOStatusCounts"]
    extra_counts = summary["extraSLOStatusCounts"]
    readiness_rows = [["Readiness", "Domains"]]
    for status, count in sorted(summary["readinessCounts"].items()):
        readiness_rows.append([status, str(count)])

    domain_rows = [["Domain", "Readiness", "Scenarios", "PASS/FAIL/UNKNOWN/NEVER", "Reason", "Samples"]]
    for row in payload["domains"]:
        samples = ", ".join(f"{item['scenario']}:{item['status']}" for item in row.get("sampleScenarios") or [])
        domain_rows.append([
            str(row["domain"]),
            str(row["readiness"]),
            str(row["scenarioCount"]),
            f"{row['pass']}/{row['fail']}/{row['unknown']}/{row['neverRun']}",
            str(row["reason"])[:160],
            samples[:180] or "-",
        ])

    extra_rows = [["Scenario", "Category", "SLO", "Reason"]]
    for row in payload.get("extraScenarios") or []:
        extra_rows.append([
            str(row.get("scenario") or ""),
            str(row.get("category") or ""),
            str(row.get("latestSLOStatus") or ""),
            str(row.get("latestReason") or row.get("latestAction") or "")[:180],
        ])

    return "\n".join([
        "# Performance SLO Domain Scorecard",
        "",
        f"- sloStatus: `{slo_status_path}`",
        f"- overallStatus: `{summary['overallStatus']}`",
        f"- domains: `{summary['domainCount']}`",
        f"- matrix scenarios: `{summary['matrixScenarioCount']}`",
        f"- matrix SLO PASS/FAIL/UNKNOWN/NEVER: `{matrix_counts.get('PASS', 0)}/{matrix_counts.get('FAIL', 0)}/{matrix_counts.get('UNKNOWN', 0)}/{matrix_counts.get('NEVER_RUN', 0)}`",
        f"- extra SLO FAIL/UNKNOWN/NEVER/PASS: `{extra_counts.get('FAIL', 0)}/{extra_counts.get('UNKNOWN', 0)}/{extra_counts.get('NEVER_RUN', 0)}/{extra_counts.get('PASS', 0)}`",
        "",
        "## Readiness Summary",
        "",
        markdown_table(readiness_rows),
        "",
        "## Domains",
        "",
        markdown_table(domain_rows),
        "",
        "## Extra Scenarios",
        "",
        markdown_table(extra_rows) if len(extra_rows) > 1 else "No extra observed SLO scenarios.",
        "",
    ])


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    fieldnames = ["domain", "readiness", "reason", "scenarioCount", "pass", "fail", "unknown", "neverRun", "sampleScenarios"]
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow({
                "domain": row.get("domain"),
                "readiness": row.get("readiness"),
                "reason": row.get("reason"),
                "scenarioCount": row.get("scenarioCount"),
                "pass": row.get("pass"),
                "fail": row.get("fail"),
                "unknown": row.get("unknown"),
                "neverRun": row.get("neverRun"),
                "sampleScenarios": "; ".join(f"{item['scenario']}:{item['status']}" for item in row.get("sampleScenarios") or []),
            })


def main() -> int:
    parser = argparse.ArgumentParser(description="Build a domain-level SLO scorecard from perf_slo_status.py output.")
    parser.add_argument("--slo-status-json", required=True)
    parser.add_argument("--output")
    parser.add_argument("--json-output")
    parser.add_argument("--csv-output")
    parser.add_argument("--strict", action="store_true", help="Exit non-zero unless overallStatus is READY.")
    args = parser.parse_args()

    slo_status_path = Path(args.slo_status_json)
    payload = build_scorecard(read_json(slo_status_path))
    markdown = build_markdown(slo_status_path, payload)
    if args.output:
        Path(args.output).write_text(markdown)
    else:
        print(markdown)
    if args.json_output:
        Path(args.json_output).write_text(json.dumps(payload, indent=2, sort_keys=True))
    if args.csv_output:
        write_csv(Path(args.csv_output), payload["domains"])
    if args.strict and payload["summary"]["overallStatus"] != "READY":
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
