#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Any


STATUS_RANK = {
    "PASS": 0,
    "UNKNOWN": 1,
    "FAIL": 2,
}


def read_report(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text())
    except Exception as exc:
        raise SystemExit(f"Failed to read report JSON {path}: {exc}") from exc


def numeric(value: Any) -> float | None:
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def format_number(value: float | None, suffix: str = "") -> str:
    if value is None:
        return "-"
    if value.is_integer():
        return f"{int(value)}{suffix}"
    return f"{value:.3f}{suffix}"


def format_delta(value: float | None, suffix: str = "") -> str:
    if value is None:
        return "-"
    sign = "+" if value > 0 else ""
    if value.is_integer():
        return f"{sign}{int(value)}{suffix}"
    return f"{sign}{value:.3f}{suffix}"


def percent(value: float | None) -> str:
    if value is None:
        return "-"
    return f"{value * 100:.2f}%"


def primary_p99_ms(record: dict[str, Any]) -> float | None:
    k6 = record.get("k6") or {}
    p99_values = [
        value
        for key, value in k6.items()
        if key.startswith("im_") and key.endswith(".p(99)") and numeric(value) is not None
    ]
    if p99_values:
        return max(numeric(value) or 0.0 for value in p99_values)
    tcp = record.get("tcp") or {}
    for key in ("deliveryP99Ms", "heartbeatP99Ms"):
        value = numeric(tcp.get(key))
        if value is not None:
            return value
    return numeric(k6.get("httpReqDurationP99"))


def http_failure_rate(record: dict[str, Any]) -> float | None:
    return numeric((record.get("k6") or {}).get("httpReqFailedRate"))


def by_name(report: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {
        str(item.get("name")): item
        for item in report.get("scenarios") or []
        if item.get("name")
    }


def classify(base: dict[str, Any] | None, current: dict[str, Any] | None, p99_regression_ratio: float) -> str:
    if base is None:
        if str((current or {}).get("status", "UNKNOWN")) == "FAIL":
            return "REGRESSION"
        return "ADDED"
    if current is None:
        if str((base or {}).get("status", "UNKNOWN")) == "FAIL":
            return "IMPROVEMENT"
        return "REMOVED"
    base_status = str(base.get("status", "UNKNOWN"))
    current_status = str(current.get("status", "UNKNOWN"))
    if STATUS_RANK.get(current_status, 1) > STATUS_RANK.get(base_status, 1):
        return "REGRESSION"
    if STATUS_RANK.get(current_status, 1) < STATUS_RANK.get(base_status, 1):
        return "IMPROVEMENT"

    base_p99 = primary_p99_ms(base)
    current_p99 = primary_p99_ms(current)
    if base_p99 is not None and current_p99 is not None and base_p99 > 0:
        ratio = (current_p99 - base_p99) / base_p99
        if ratio >= p99_regression_ratio:
            return "REGRESSION"
        if ratio <= -p99_regression_ratio:
            return "IMPROVEMENT"

    base_http = http_failure_rate(base)
    current_http = http_failure_rate(current)
    if base_http is not None and current_http is not None:
        if current_http > base_http:
            return "REGRESSION"
        if current_http < base_http:
            return "IMPROVEMENT"

    return "UNCHANGED"


def markdown_table(rows: list[list[str]]) -> str:
    if not rows:
        return ""
    output = [
        "| " + " | ".join(rows[0]) + " |",
        "| " + " | ".join(["---"] * len(rows[0])) + " |",
    ]
    for row in rows[1:]:
        output.append("| " + " | ".join(row) + " |")
    return "\n".join(output)


def compare_reports(base: dict[str, Any], current: dict[str, Any], p99_regression_ratio: float) -> list[dict[str, Any]]:
    base_items = by_name(base)
    current_items = by_name(current)
    names = sorted(set(base_items) | set(current_items))
    comparisons: list[dict[str, Any]] = []
    for name in names:
        old = base_items.get(name)
        new = current_items.get(name)
        old_p99 = primary_p99_ms(old) if old else None
        new_p99 = primary_p99_ms(new) if new else None
        old_http = http_failure_rate(old) if old else None
        new_http = http_failure_rate(new) if new else None
        comparisons.append({
            "name": name,
            "category": (new or old or {}).get("category", "-"),
            "classification": classify(old, new, p99_regression_ratio),
            "oldStatus": (old or {}).get("status", "-"),
            "newStatus": (new or {}).get("status", "-"),
            "oldPrimaryP99Ms": old_p99,
            "newPrimaryP99Ms": new_p99,
            "primaryP99DeltaMs": (new_p99 - old_p99) if old_p99 is not None and new_p99 is not None else None,
            "oldHttpFailureRate": old_http,
            "newHttpFailureRate": new_http,
            "httpFailureRateDelta": (new_http - old_http) if old_http is not None and new_http is not None else None,
            "newReasons": "; ".join((new or {}).get("reasons") or []),
            "optimizationHint": (new or {}).get("optimizationHint") or "",
        })
    return comparisons


def main() -> int:
    parser = argparse.ArgumentParser(description="Compare two performance report.json files.")
    parser.add_argument("--base", required=True, help="Baseline report.json")
    parser.add_argument("--current", required=True, help="Current report.json")
    parser.add_argument("--output", help="Markdown output path")
    parser.add_argument("--csv-output", help="CSV output path")
    parser.add_argument("--p99-regression-ratio", type=float, default=0.10)
    args = parser.parse_args()

    base_path = Path(args.base)
    current_path = Path(args.current)
    base = read_report(base_path)
    current = read_report(current_path)
    comparisons = compare_reports(base, current, args.p99_regression_ratio)
    regression_count = sum(1 for item in comparisons if item["classification"] == "REGRESSION")
    improvement_count = sum(1 for item in comparisons if item["classification"] == "IMPROVEMENT")

    rows = [[
        "Scenario",
        "Category",
        "Class",
        "Status",
        "Primary P99",
        "HTTP Fail",
        "Notes",
    ]]
    for item in comparisons:
        rows.append([
            str(item["name"]),
            str(item["category"]),
            str(item["classification"]),
            f"{item['oldStatus']} -> {item['newStatus']}",
            (
                f"{format_number(item['oldPrimaryP99Ms'], 'ms')} -> "
                f"{format_number(item['newPrimaryP99Ms'], 'ms')} "
                f"({format_delta(item['primaryP99DeltaMs'], 'ms')})"
            ),
            (
                f"{percent(item['oldHttpFailureRate'])} -> "
                f"{percent(item['newHttpFailureRate'])} "
                f"({format_delta(item['httpFailureRateDelta'])})"
            ),
            item["newReasons"] or item["optimizationHint"] or "-",
        ])

    report = "\n".join([
        "# Performance Compare Report",
        "",
        f"- base: `{base_path}`",
        f"- current: `{current_path}`",
        f"- scenarios: `{len(comparisons)}`",
        f"- regressions: `{regression_count}`",
        f"- improvements: `{improvement_count}`",
        "",
        markdown_table(rows),
        "",
    ])
    if args.output:
        Path(args.output).write_text(report)
    if args.csv_output:
        with Path(args.csv_output).open("w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(comparisons[0].keys()) if comparisons else ["name"])
            writer.writeheader()
            for item in comparisons:
                writer.writerow(item)
    print(report)
    return 1 if regression_count > 0 else 0


if __name__ == "__main__":
    raise SystemExit(main())
