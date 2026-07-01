#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Any


def read_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text())
    except Exception:
        return {}


def scenario_status_counts(report: dict[str, Any]) -> dict[str, int]:
    counts = {"PASS": 0, "FAIL": 0, "UNKNOWN": 0}
    for scenario in report.get("scenarios") or []:
        status = str(scenario.get("status", "UNKNOWN"))
        counts[status] = counts.get(status, 0) + 1
    return counts


def has_entrypoint_failure(report: dict[str, Any]) -> bool:
    for scenario in report.get("scenarios") or []:
        category = str(scenario.get("category", ""))
        reasons = " ".join(str(item) for item in scenario.get("reasons") or [])
        diagnostics = " ".join(str(item) for item in scenario.get("diagnostics") or [])
        hint = str(scenario.get("optimizationHint") or "")
        if category == "preflight" and str(scenario.get("status")) == "FAIL":
            return True
        if "local_network_proxy_http_403_intercept" in reasons or "local_network_proxy_http_403_intercept" in diagnostics:
            return True
        if "uniform_empty_403" in reasons or "uniform_empty_403" in diagnostics:
            return True
        if "HTTP 403" in reasons or "status=403" in reasons or "HTTP 403" in diagnostics:
            return True
        if "entrypoint/deployment" in hint:
            return True
    return False


def primary_failed_categories(report: dict[str, Any]) -> list[str]:
    categories = []
    for item in report.get("categorySummary") or []:
        if int(item.get("fail") or 0) > 0:
            categories.append(str(item.get("category")))
    return sorted(set(categories))


def category_counts(report: dict[str, Any]) -> dict[str, dict[str, int]]:
    counts: dict[str, dict[str, int]] = {}
    summary = report.get("categorySummary") or []
    for item in summary:
        category = str(item.get("category") or "unknown")
        counts[category] = {
            "PASS": int(item.get("pass") or 0),
            "FAIL": int(item.get("fail") or 0),
            "UNKNOWN": int(item.get("unknown") or 0),
        }
    if counts:
        return counts

    for scenario in report.get("scenarios") or []:
        category = str(scenario.get("category") or "unknown")
        status = str(scenario.get("status") or "UNKNOWN")
        bucket = counts.setdefault(category, {"PASS": 0, "FAIL": 0, "UNKNOWN": 0})
        bucket[status if status in bucket else "UNKNOWN"] += 1
    return counts


def evidence_summary(run_dir: Path, report: dict[str, Any]) -> dict[str, Any]:
    evidence = read_json(run_dir / "evidence.json")
    if evidence:
        return {
            "evidenceOutcome": str(evidence.get("outcome") or "UNKNOWN"),
            "openIssueCount": int(evidence.get("openIssueCount") or 0),
            "priorityCounts": ",".join(
                f"{key}:{value}"
                for key, value in sorted((evidence.get("priorityCounts") or {}).items())
            ),
        }
    if has_entrypoint_failure(report):
        return {
            "evidenceOutcome": "BLOCKED_ENTRYPOINT",
            "openIssueCount": 1,
            "priorityCounts": "P0:1",
        }
    if int(report.get("failed") or 0) > 0:
        failed_count = int(report.get("failed") or 0)
        return {
            "evidenceOutcome": "NEEDS_OPTIMIZATION",
            "openIssueCount": failed_count,
            "priorityCounts": f"P1:{failed_count}",
        }
    if int(report.get("unknown") or 0) > 0:
        unknown_count = int(report.get("unknown") or 0)
        return {
            "evidenceOutcome": "INCOMPLETE_ARTIFACTS",
            "openIssueCount": unknown_count,
            "priorityCounts": f"P2:{unknown_count}",
        }
    return {
        "evidenceOutcome": "PASS",
        "openIssueCount": 0,
        "priorityCounts": "",
    }


def collect_history(results_dir: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for report_path in sorted(results_dir.glob("*/report.json")):
        report = read_json(report_path)
        if not report:
            continue
        counts = scenario_status_counts(report)
        run_id = report_path.parent.name
        row = {
            "runID": run_id,
            "runDir": str(report_path.parent),
            "mtime": report_path.stat().st_mtime,
            "scenarioCount": int(report.get("scenarioCount") or len(report.get("scenarios") or [])),
            "pass": counts.get("PASS", 0),
            "fail": int(report.get("failed") if report.get("failed") is not None else counts.get("FAIL", 0)),
            "unknown": int(report.get("unknown") if report.get("unknown") is not None else counts.get("UNKNOWN", 0)),
            "entrypointFailure": has_entrypoint_failure(report),
            "failedCategories": ",".join(primary_failed_categories(report)),
            "categoryCounts": category_counts(report),
        }
        row.update(evidence_summary(report_path.parent, report))
        rows.append(row)
    return rows


def sort_rows(rows: list[dict[str, Any]], latest_first: bool) -> list[dict[str, Any]]:
    return sorted(rows, key=lambda row: (float(row.get("mtime") or 0), str(row.get("runID") or "")), reverse=latest_first)


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


def build_category_summary(rows: list[dict[str, Any]]) -> list[list[str]]:
    totals: dict[str, dict[str, int]] = {}
    for row in rows:
        for category, counts in (row.get("categoryCounts") or {}).items():
            bucket = totals.setdefault(str(category), {"PASS": 0, "FAIL": 0, "UNKNOWN": 0})
            bucket["PASS"] += int(counts.get("PASS") or 0)
            bucket["FAIL"] += int(counts.get("FAIL") or 0)
            bucket["UNKNOWN"] += int(counts.get("UNKNOWN") or 0)

    table = [["Category", "PASS", "FAIL", "UNKNOWN", "Total"]]
    for category, counts in sorted(
        totals.items(),
        key=lambda item: (-(item[1]["FAIL"] + item[1]["UNKNOWN"]), item[0]),
    ):
        total = counts["PASS"] + counts["FAIL"] + counts["UNKNOWN"]
        table.append([
            str(category),
            str(counts["PASS"]),
            str(counts["FAIL"]),
            str(counts["UNKNOWN"]),
            str(total),
        ])
    return table


def build_markdown(rows: list[dict[str, Any]], results_dir: Path, total_rows: int, limit: int | None) -> str:
    table = [[
        "Run",
        "Scenarios",
        "PASS",
        "FAIL",
        "UNKNOWN",
        "Entrypoint",
        "Outcome",
        "Issues",
        "Priorities",
        "Failed Categories",
    ]]
    for row in rows:
        table.append([
            str(row["runID"]),
            str(row["scenarioCount"]),
            str(row["pass"]),
            str(row["fail"]),
            str(row["unknown"]),
            "FAIL" if row["entrypointFailure"] else "-",
            str(row["evidenceOutcome"]),
            str(row["openIssueCount"]),
            str(row["priorityCounts"] or "-"),
            str(row["failedCategories"] or "-"),
        ])
    outcome_counts: dict[str, int] = {}
    for row in rows:
        outcome = str(row["evidenceOutcome"])
        outcome_counts[outcome] = outcome_counts.get(outcome, 0) + 1
    outcome_rows = [["Outcome", "Runs"]]
    for outcome, count in sorted(outcome_counts.items()):
        outcome_rows.append([f"`{outcome}`", str(count)])
    category_rows = build_category_summary(rows)
    run_count_line = f"- runs: `{len(rows)}`"
    if limit is not None:
        run_count_line = f"- runs: `{len(rows)}` displayed of `{total_rows}` total"
    return "\n".join([
        "# Performance History",
        "",
        f"- resultsDir: `{results_dir}`",
        run_count_line,
        f"- order: `latest-first`",
        "",
        "## Outcome Summary",
        "",
        markdown_table(outcome_rows),
        "",
        "## Category Summary",
        "",
        markdown_table(category_rows),
        "",
        "## Runs",
        "",
        markdown_table(table),
        "",
    ])


def main() -> int:
    parser = argparse.ArgumentParser(description="Summarize all report.json files under a results directory.")
    parser.add_argument("--results-dir", default="results")
    parser.add_argument("--limit", type=int, help="Only display the most recent N runs.")
    parser.add_argument("--oldest-first", action="store_true", help="Display oldest runs first instead of latest first.")
    parser.add_argument("--output")
    parser.add_argument("--csv-output")
    args = parser.parse_args()
    if args.limit is not None and args.limit <= 0:
        parser.error("--limit must be greater than 0")

    results_dir = Path(args.results_dir)
    all_rows = sort_rows(collect_history(results_dir), latest_first=not args.oldest_first)
    rows = all_rows[: args.limit] if args.limit is not None else all_rows
    report = build_markdown(rows, results_dir, total_rows=len(all_rows), limit=args.limit)
    if args.output:
        Path(args.output).write_text(report)
    if args.csv_output:
        with Path(args.csv_output).open("w", newline="") as handle:
            writer = csv.DictWriter(
                handle,
                fieldnames=[
                    "runID",
                    "runDir",
                    "mtime",
                    "scenarioCount",
                    "pass",
                    "fail",
                    "unknown",
                    "entrypointFailure",
                    "evidenceOutcome",
                    "openIssueCount",
                    "priorityCounts",
                    "failedCategories",
                ],
            )
            writer.writeheader()
            for row in rows:
                csv_row = dict(row)
                csv_row.pop("categoryCounts", None)
                writer.writerow(csv_row)
    print(report)
    return 1 if any(row["fail"] for row in rows) else 0


if __name__ == "__main__":
    raise SystemExit(main())
