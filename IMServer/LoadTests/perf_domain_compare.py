#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Any

from perf_compare import compare_reports, format_delta, format_number, percent, read_report


def read_json(path: Path | None) -> dict[str, Any]:
    if path is None:
        return {}
    try:
        return json.loads(path.read_text())
    except Exception as exc:
        raise SystemExit(f"Failed to read JSON {path}: {exc}") from exc


def catalog_domains(catalog: dict[str, Any]) -> dict[str, str]:
    return {
        str(row.get("scenario") or ""): str(row.get("domain") or "other")
        for row in catalog.get("scenarios") or []
        if row.get("scenario")
    }


def fallback_domain(category: str, name: str) -> str:
    value = f"{category} {name}"
    if "preflight" in value or "entrypoint" in value:
        return "preflight"
    if "large-group" in value or "hot-write" in value:
        return "hot-large-group"
    if "tcp-" in value or "online" in value or "delivery" in value:
        return "tcp-realtime"
    if "auth" in value or "login" in value or "account" in value or "session" in value:
        return "auth-session"
    if "client" in value or "timeline" in value or "cold-start" in value or "domain-events" in value:
        return "client-sync"
    if "group" in value:
        return "group-lifecycle"
    if "contact" in value or "profile" in value:
        return "social-profile"
    if "safety" in value or "admin-report" in value:
        return "safety-moderation"
    if "media" in value or "file" in value:
        return "media-file"
    if "ai-stream" in value:
        return "ai-stream"
    if "governance" in value or "forward" in value or "read-state" in value or "search" in value or "convergence" in value or "small-group" in value:
        return "message-workflow"
    return "other"


def classify_domain(row: dict[str, Any]) -> str:
    if int(row["regressions"]) > 0:
        return "REGRESSION"
    if int(row["improvements"]) > 0:
        return "IMPROVEMENT"
    if int(row["added"]) > 0 or int(row["removed"]) > 0:
        return "CHANGED_SCOPE"
    return "UNCHANGED"


def aggregate(comparisons: list[dict[str, Any]], domains: dict[str, str]) -> list[dict[str, Any]]:
    rows: dict[str, dict[str, Any]] = {}
    for item in comparisons:
        name = str(item.get("name") or "")
        category = str(item.get("category") or "")
        domain = domains.get(name) or fallback_domain(category, name)
        bucket = rows.setdefault(domain, {
            "domain": domain,
            "scenarioCount": 0,
            "regressions": 0,
            "improvements": 0,
            "unchanged": 0,
            "added": 0,
            "removed": 0,
            "changedScope": 0,
            "p99DeltaCount": 0,
            "p99DeltaSumMs": 0.0,
            "p99DeltaMaxMs": None,
            "httpFailureDeltaCount": 0,
            "httpFailureDeltaSum": 0.0,
            "scenarios": [],
        })
        bucket["scenarioCount"] += 1
        classification = str(item.get("classification") or "UNCHANGED")
        if classification == "REGRESSION":
            bucket["regressions"] += 1
        elif classification == "IMPROVEMENT":
            bucket["improvements"] += 1
        elif classification == "ADDED":
            bucket["added"] += 1
            bucket["changedScope"] += 1
        elif classification == "REMOVED":
            bucket["removed"] += 1
            bucket["changedScope"] += 1
        else:
            bucket["unchanged"] += 1

        delta = item.get("primaryP99DeltaMs")
        if delta is not None:
            delta_float = float(delta)
            bucket["p99DeltaCount"] += 1
            bucket["p99DeltaSumMs"] += delta_float
            if bucket["p99DeltaMaxMs"] is None or delta_float > float(bucket["p99DeltaMaxMs"]):
                bucket["p99DeltaMaxMs"] = delta_float

        http_delta = item.get("httpFailureRateDelta")
        if http_delta is not None:
            bucket["httpFailureDeltaCount"] += 1
            bucket["httpFailureDeltaSum"] += float(http_delta)

        bucket["scenarios"].append(item)

    output = []
    for row in rows.values():
        row["classification"] = classify_domain(row)
        row["avgP99DeltaMs"] = (
            row["p99DeltaSumMs"] / row["p99DeltaCount"]
            if row["p99DeltaCount"] else None
        )
        row["avgHttpFailureRateDelta"] = (
            row["httpFailureDeltaSum"] / row["httpFailureDeltaCount"]
            if row["httpFailureDeltaCount"] else None
        )
        row["scenarios"] = sorted(
            row["scenarios"],
            key=lambda item: (
                {"REGRESSION": 0, "IMPROVEMENT": 1, "ADDED": 2, "REMOVED": 3, "UNCHANGED": 4}.get(str(item.get("classification")), 9),
                str(item.get("name") or ""),
            ),
        )
        output.append(row)
    return sorted(
        output,
        key=lambda row: (
            {"REGRESSION": 0, "IMPROVEMENT": 1, "CHANGED_SCOPE": 2, "UNCHANGED": 3}.get(str(row["classification"]), 9),
            -int(row["regressions"]),
            -int(row["improvements"]),
            str(row["domain"]),
        ),
    )


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


def build_markdown(base_path: Path, current_path: Path, catalog_path: Path | None, domain_rows: list[dict[str, Any]], comparisons: list[dict[str, Any]]) -> str:
    regression_count = sum(int(row["regressions"]) for row in domain_rows)
    improvement_count = sum(int(row["improvements"]) for row in domain_rows)
    domain_regression_count = sum(1 for row in domain_rows if row["classification"] == "REGRESSION")
    domain_improvement_count = sum(1 for row in domain_rows if row["classification"] == "IMPROVEMENT")

    summary_rows = [["Domain", "Class", "Scenarios", "Reg", "Imp", "Added/Removed", "Avg P99 Delta", "Max P99 Delta", "Avg HTTP Fail Delta"]]
    for row in domain_rows:
        summary_rows.append([
            str(row["domain"]),
            str(row["classification"]),
            str(row["scenarioCount"]),
            str(row["regressions"]),
            str(row["improvements"]),
            f"{row['added']}/{row['removed']}",
            format_delta(row["avgP99DeltaMs"], "ms"),
            format_delta(row["p99DeltaMaxMs"], "ms"),
            percent(row["avgHttpFailureRateDelta"]),
        ])

    scenario_rows = [["Domain", "Scenario", "Class", "Status", "Primary P99", "HTTP Fail", "Notes"]]
    for row in domain_rows:
        for item in row["scenarios"][:10]:
            scenario_rows.append([
                str(row["domain"]),
                f"`{item['name']}`",
                str(item["classification"]),
                f"{item['oldStatus']} -> {item['newStatus']}",
                f"{format_number(item['oldPrimaryP99Ms'], 'ms')} -> {format_number(item['newPrimaryP99Ms'], 'ms')} ({format_delta(item['primaryP99DeltaMs'], 'ms')})",
                f"{percent(item['oldHttpFailureRate'])} -> {percent(item['newHttpFailureRate'])} ({format_delta(item['httpFailureRateDelta'])})",
                str(item["newReasons"] or item["optimizationHint"] or "-")[:160],
            ])

    return "\n".join([
        "# Performance Domain Compare",
        "",
        f"- base: `{base_path}`",
        f"- current: `{current_path}`",
        f"- scenarioCatalog: `{catalog_path or '-'}`",
        f"- domains: `{len(domain_rows)}`",
        f"- scenarios: `{len(comparisons)}`",
        f"- domain regressions: `{domain_regression_count}`",
        f"- domain improvements: `{domain_improvement_count}`",
        f"- scenario regressions: `{regression_count}`",
        f"- scenario improvements: `{improvement_count}`",
        "",
        "## Domain Summary",
        "",
        markdown_table(summary_rows),
        "",
        "## Scenario Detail",
        "",
        markdown_table(scenario_rows),
        "",
    ])


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    fieldnames = [
        "domain",
        "classification",
        "scenarioCount",
        "regressions",
        "improvements",
        "unchanged",
        "added",
        "removed",
        "avgP99DeltaMs",
        "p99DeltaMaxMs",
        "avgHttpFailureRateDelta",
    ]
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow({key: row.get(key) for key in fieldnames})


def main() -> int:
    parser = argparse.ArgumentParser(description="Compare two performance runs and aggregate changes by product domain.")
    parser.add_argument("--base", required=True, help="Baseline report.json")
    parser.add_argument("--current", required=True, help="Current report.json")
    parser.add_argument("--scenario-catalog", help="Optional perf_scenario_catalog.py JSON output for scenario-to-domain mapping.")
    parser.add_argument("--p99-regression-ratio", type=float, default=0.10)
    parser.add_argument("--output", help="Markdown output path")
    parser.add_argument("--json-output", help="Machine-readable JSON output path")
    parser.add_argument("--csv-output", help="Domain summary CSV output path")
    args = parser.parse_args()

    base_path = Path(args.base)
    current_path = Path(args.current)
    catalog_path = Path(args.scenario_catalog) if args.scenario_catalog else None
    comparisons = compare_reports(read_report(base_path), read_report(current_path), args.p99_regression_ratio)
    domain_rows = aggregate(comparisons, catalog_domains(read_json(catalog_path)))
    markdown = build_markdown(base_path, current_path, catalog_path, domain_rows, comparisons)
    payload = {
        "base": str(base_path),
        "current": str(current_path),
        "scenarioCatalog": str(catalog_path) if catalog_path else "",
        "domainCount": len(domain_rows),
        "scenarioCount": len(comparisons),
        "domainRegressionCount": sum(1 for row in domain_rows if row["classification"] == "REGRESSION"),
        "domainImprovementCount": sum(1 for row in domain_rows if row["classification"] == "IMPROVEMENT"),
        "scenarioRegressionCount": sum(int(row["regressions"]) for row in domain_rows),
        "scenarioImprovementCount": sum(int(row["improvements"]) for row in domain_rows),
        "domains": domain_rows,
        "comparisons": comparisons,
    }
    if args.output:
        Path(args.output).write_text(markdown)
    else:
        print(markdown)
    if args.json_output:
        Path(args.json_output).write_text(json.dumps(payload, indent=2, sort_keys=True))
    if args.csv_output:
        write_csv(Path(args.csv_output), domain_rows)
    return 1 if payload["domainRegressionCount"] > 0 else 0


if __name__ == "__main__":
    raise SystemExit(main())
