#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Any

from perf_matrix_audit import list_output_scenarios, parse_k6_scenarios, read_text


def read_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text())
    except Exception:
        return {}


def runner_scenario_metadata(matrix_script: Path | None) -> dict[str, dict[str, str]]:
    if matrix_script is None:
        return {}
    text = read_text(matrix_script)
    metadata = {
        record.name: {
            "category": record.category,
            "target": record.target,
        }
        for record in parse_k6_scenarios(text)
    }
    _, listed = list_output_scenarios(matrix_script)
    for name in listed:
        metadata.setdefault(name, {"category": infer_category(name), "target": ""})
    return metadata


def infer_category(name: str) -> str:
    if name.startswith("online-idle-"):
        return "tcp-online"
    if name.startswith("reconnect-"):
        return "tcp-reconnect"
    if name.startswith("multi-device-online-"):
        return "tcp-multi-device-online"
    if name.startswith("multi-device-delivery-"):
        return "tcp-multi-device-delivery"
    if name.startswith("pair-delivery-"):
        return "tcp-pair-delivery"
    if name.startswith("large-group-"):
        return "tcp-large-group"
    return ""


def scenario_sort_key(row: dict[str, Any]) -> tuple[int, str, str]:
    status_rank = {"FAIL": 0, "UNKNOWN": 1, "NEVER_RUN": 2, "PASS": 3}
    return (
        status_rank.get(str(row.get("latestSLOStatus")), 9),
        0 if row.get("isMatrixScenario") else 1,
        str(row.get("category") or ""),
        str(row.get("scenario") or ""),
    )


def compact_reason(row: dict[str, Any]) -> str:
    violations = row.get("violations") or []
    if violations:
        return "; ".join(str(item) for item in violations[:3])
    missing = row.get("missing") or []
    if missing:
        return "; ".join(str(item) for item in missing[:3])
    return str(row.get("action") or "")


def target_matches(run_target: dict[str, Any], args: argparse.Namespace) -> bool:
    if not bool(getattr(args, "filter_target", False)):
        return True
    checks = [
        ("baseURL", getattr(args, "base_url", "")),
        ("tcpHost", getattr(args, "tcp_host", "")),
        ("tcpPort", getattr(args, "tcp_port", "")),
    ]
    for field, expected in checks:
        if not expected:
            continue
        actual = str(run_target.get(field) or "")
        if actual != str(expected):
            return False
    return True


def collect_slo_status(
    results_dir: Path,
    matrix_script: Path | None = None,
    args: argparse.Namespace | None = None,
) -> list[dict[str, Any]]:
    records: dict[str, dict[str, Any]] = {}
    for name, metadata in runner_scenario_metadata(matrix_script).items():
        records[name] = {
            "scenario": name,
            "category": metadata.get("category", ""),
            "target": metadata.get("target", ""),
            "isMatrixScenario": True,
            "runCount": 0,
            "sloPassCount": 0,
            "sloFailCount": 0,
            "sloUnknownCount": 0,
            "latestRunID": "",
            "latestRunDir": "",
            "latestMtime": 0.0,
            "latestBaseURL": "",
            "latestTCPHost": "",
            "latestTCPPort": "",
            "latestSLOStatus": "NEVER_RUN",
            "latestScenarioStatus": "NEVER_RUN",
            "latestPolicy": "",
            "latestReason": "no slo.json found for this scenario",
            "latestAction": "Run this scenario and generate slo.json before treating it as covered.",
            "latestHTTPP99Ms": None,
            "latestDeliveryP99Ms": None,
        }

    for slo_path in sorted(results_dir.glob("*/slo.json")):
        payload = read_json(slo_path)
        if not payload:
            continue
        run_dir = slo_path.parent
        run_mtime = slo_path.stat().st_mtime
        run_id = run_dir.name
        payload_target = payload.get("target") or {}
        for scenario in payload.get("scenarios") or []:
            name = str(scenario.get("scenario") or "")
            if not name:
                continue
            scenario_target = scenario.get("runTarget") or payload_target
            if args is not None and not target_matches(scenario_target, args):
                continue
            status = str(scenario.get("sloStatus") or "UNKNOWN")
            row = records.setdefault(name, {
                "scenario": name,
                "category": str(scenario.get("category") or ""),
                "target": str(scenario.get("target") or ""),
                "isMatrixScenario": False,
                "runCount": 0,
                "sloPassCount": 0,
                "sloFailCount": 0,
                "sloUnknownCount": 0,
                "latestRunID": "",
                "latestRunDir": "",
                "latestMtime": 0.0,
                "latestBaseURL": "",
                "latestTCPHost": "",
                "latestTCPPort": "",
                "latestSLOStatus": "UNKNOWN",
                "latestScenarioStatus": "UNKNOWN",
                "latestPolicy": "",
                "latestReason": "",
                "latestAction": "",
                "latestHTTPP99Ms": None,
                "latestDeliveryP99Ms": None,
            })
            row["runCount"] += 1
            if status == "PASS":
                row["sloPassCount"] += 1
            elif status == "FAIL":
                row["sloFailCount"] += 1
            else:
                row["sloUnknownCount"] += 1

            if run_mtime >= float(row["latestMtime"] or 0):
                row.update({
                    "category": str(scenario.get("category") or row["category"]),
                    "target": str(scenario.get("target") or row["target"]),
                    "latestRunID": run_id,
                    "latestRunDir": str(run_dir),
                    "latestMtime": run_mtime,
                    "latestBaseURL": str(scenario_target.get("baseURL") or payload_target.get("baseURL") or ""),
                    "latestTCPHost": str(scenario_target.get("tcpHost") or payload_target.get("tcpHost") or ""),
                    "latestTCPPort": str(scenario_target.get("tcpPort") or payload_target.get("tcpPort") or ""),
                    "latestSLOStatus": status,
                    "latestScenarioStatus": str(scenario.get("scenarioStatus") or "UNKNOWN"),
                    "latestPolicy": str(scenario.get("policy") or ""),
                    "latestReason": compact_reason(scenario),
                    "latestAction": str(scenario.get("action") or ""),
                    "latestHTTPP99Ms": scenario.get("httpP99Ms"),
                    "latestDeliveryP99Ms": scenario.get("deliveryP99Ms"),
                })
    return sorted(records.values(), key=scenario_sort_key)


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


def format_ms(value: Any) -> str:
    if value is None:
        return "-"
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return str(value)
    if parsed.is_integer():
        return f"{int(parsed)}ms"
    return f"{parsed:.1f}ms"


def build_markdown(rows: list[dict[str, Any]], results_dir: Path, limit: int | None) -> str:
    matrix_rows = [row for row in rows if row.get("isMatrixScenario")]
    extra_rows = [row for row in rows if not row.get("isMatrixScenario")]
    status_counts = {
        status: sum(1 for row in matrix_rows if row["latestSLOStatus"] == status)
        for status in ["FAIL", "UNKNOWN", "NEVER_RUN", "PASS"]
    }
    extra_counts = {
        status: sum(1 for row in extra_rows if row["latestSLOStatus"] == status)
        for status in ["FAIL", "UNKNOWN", "NEVER_RUN", "PASS"]
    }
    status_table = [["Latest SLO", "Scenarios"]]
    for status in ["FAIL", "UNKNOWN", "NEVER_RUN", "PASS"]:
        status_table.append([f"`{status}`", str(status_counts.get(status, 0))])
    if extra_rows:
        status_table.append(["`EXTRA_FAIL/UNKNOWN/NEVER/PASS`", f"{extra_counts.get('FAIL', 0)}/{extra_counts.get('UNKNOWN', 0)}/{extra_counts.get('NEVER_RUN', 0)}/{extra_counts.get('PASS', 0)}"])

    category_totals: dict[str, dict[str, int]] = {}
    for row in rows:
        category = str(row.get("category") or "unknown")
        if not row.get("isMatrixScenario"):
            category = f"extra:{category}"
        status = str(row.get("latestSLOStatus") or "UNKNOWN")
        bucket = category_totals.setdefault(category, {"FAIL": 0, "UNKNOWN": 0, "NEVER_RUN": 0, "PASS": 0})
        bucket[status if status in bucket else "UNKNOWN"] += 1
    category_table = [["Category", "FAIL", "UNKNOWN", "NEVER_RUN", "PASS", "Total"]]
    for category, counts in sorted(
        category_totals.items(),
        key=lambda item: (-(item[1]["FAIL"] + item[1]["UNKNOWN"] + item[1]["NEVER_RUN"]), item[0]),
    ):
        total = counts["FAIL"] + counts["UNKNOWN"] + counts["NEVER_RUN"] + counts["PASS"]
        category_table.append([
            category,
            str(counts["FAIL"]),
            str(counts["UNKNOWN"]),
            str(counts["NEVER_RUN"]),
            str(counts["PASS"]),
            str(total),
        ])

    display_rows = rows[:limit] if limit is not None else rows
    scenario_table = [["Scenario", "Scope", "Category", "SLO", "Runs", "PASS/FAIL/UNKNOWN", "Latest Run", "HTTP P99", "Delivery P99", "Reason"]]
    for row in display_rows:
        scenario_table.append([
            str(row["scenario"]),
            "matrix" if row.get("isMatrixScenario") else "extra",
            str(row["category"] or "-"),
            str(row["latestSLOStatus"]),
            str(row["runCount"]),
            f"{row['sloPassCount']}/{row['sloFailCount']}/{row['sloUnknownCount']}",
            str(row["latestRunID"] or "-"),
            format_ms(row.get("latestHTTPP99Ms")),
            format_ms(row.get("latestDeliveryP99Ms")),
            str(row["latestReason"] or row["latestAction"] or "-")[:160],
        ])

    display_line = f"- matrix scenarios: `{len(matrix_rows)}`"
    if extra_rows:
        display_line += f"\n- extra observed scenarios: `{len(extra_rows)}`"
    if limit is not None:
        display_line = f"- scenarios: `{len(display_rows)}` displayed of `{len(rows)}` total\n- matrix scenarios: `{len(matrix_rows)}`"
        if extra_rows:
            display_line += f"\n- extra observed scenarios: `{len(extra_rows)}`"
    return "\n".join([
        "# Performance SLO Status",
        "",
        f"- resultsDir: `{results_dir}`",
        display_line,
        "",
        "## Latest SLO Summary",
        "",
        markdown_table(status_table),
        "",
        "## Category Summary",
        "",
        markdown_table(category_table),
        "",
        "## Scenarios",
        "",
        markdown_table(scenario_table),
        "",
    ])


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    fieldnames = [
        "scenario",
        "category",
        "target",
        "isMatrixScenario",
        "runCount",
        "sloPassCount",
        "sloFailCount",
        "sloUnknownCount",
        "latestRunID",
        "latestRunDir",
        "latestMtime",
        "latestBaseURL",
        "latestTCPHost",
        "latestTCPPort",
        "latestSLOStatus",
        "latestScenarioStatus",
        "latestPolicy",
        "latestReason",
        "latestAction",
        "latestHTTPP99Ms",
        "latestDeliveryP99Ms",
    ]
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def main() -> int:
    parser = argparse.ArgumentParser(description="Summarize latest SLO status per performance scenario across local runs.")
    parser.add_argument("--results-dir", default="results")
    parser.add_argument("--limit", type=int, help="Only display the first N scenarios after SLO/category sorting.")
    parser.add_argument("--matrix-script", help="Optional run_perf_scenarios.sh path; listed scenarios with no slo.json become NEVER_RUN.")
    parser.add_argument("--filter-target", action="store_true", help="Only count SLO reports/scenarios whose recorded target matches the supplied base/tcp target.")
    parser.add_argument("--base-url", default="")
    parser.add_argument("--tcp-host", default="")
    parser.add_argument("--tcp-port", default="")
    parser.add_argument("--output", help="Write Markdown SLO status report.")
    parser.add_argument("--json-output", help="Write machine-readable SLO status report.")
    parser.add_argument("--csv-output", help="Write flat SLO status CSV.")
    args = parser.parse_args()
    if args.limit is not None and args.limit <= 0:
        parser.error("--limit must be greater than 0")

    results_dir = Path(args.results_dir)
    matrix_script = Path(args.matrix_script).resolve() if args.matrix_script else None
    rows = collect_slo_status(results_dir, matrix_script=matrix_script, args=args)
    matrix_rows = [row for row in rows if row.get("isMatrixScenario")]
    extra_rows = [row for row in rows if not row.get("isMatrixScenario")]
    payload = {
        "resultsDir": str(results_dir),
        "targetFilter": {
            "enabled": bool(args.filter_target),
            "baseURL": args.base_url,
            "tcpHost": args.tcp_host,
            "tcpPort": args.tcp_port,
        },
        "scenarioCount": len(rows),
        "matrixScenarioCount": len(matrix_rows),
        "extraScenarioCount": len(extra_rows),
        "latestSLOStatusCounts": {
            status: sum(1 for row in matrix_rows if row["latestSLOStatus"] == status)
            for status in ["FAIL", "UNKNOWN", "NEVER_RUN", "PASS"]
        },
        "extraSLOStatusCounts": {
            status: sum(1 for row in extra_rows if row["latestSLOStatus"] == status)
            for status in ["FAIL", "UNKNOWN", "NEVER_RUN", "PASS"]
        },
        "scenarios": rows,
    }
    markdown = build_markdown(rows, results_dir, args.limit)
    if args.output:
        Path(args.output).write_text(markdown)
    else:
        print(markdown)
    if args.json_output:
        Path(args.json_output).write_text(json.dumps(payload, indent=2, sort_keys=True))
    if args.csv_output:
        write_csv(Path(args.csv_output), rows)
    return 1 if payload["latestSLOStatusCounts"]["FAIL"] > 0 else 0


if __name__ == "__main__":
    raise SystemExit(main())
