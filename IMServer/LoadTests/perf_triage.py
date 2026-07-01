#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Any

from perf_report import CATEGORY_OPTIMIZATION_HINTS


def read_report(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text())
    except Exception as exc:
        raise SystemExit(f"Failed to read report JSON {path}: {exc}") from exc


def text_blob(scenario: dict[str, Any]) -> str:
    fields = [
        scenario.get("category"),
        scenario.get("status"),
        scenario.get("optimizationHint"),
        *(scenario.get("reasons") or []),
        *(scenario.get("diagnostics") or []),
    ]
    return " ".join(str(item) for item in fields if item is not None)


def is_entrypoint_failure(scenario: dict[str, Any]) -> bool:
    blob = text_blob(scenario)
    return (
        "local_network_proxy_http_403_intercept" in blob
        or "uniform_empty_403" in blob
        or "HTTP 403" in blob
        or "status=403" in blob
        or "entrypoint/deployment" in blob
        or "HTTP login preflight failed" in blob
    )


def classify_issue(scenario: dict[str, Any]) -> str:
    blob = text_blob(scenario)
    tcp = scenario.get("tcp") or {}
    k6 = scenario.get("k6") or {}
    if "Scenario requirement preflight failed" in blob:
        return "prerequisites"
    if is_entrypoint_failure(scenario):
        return "entrypoint"
    if "no parseable result artifacts" in blob:
        return "missing-artifacts"
    if "threshold" in blob or k6.get("thresholdFailures"):
        return "k6-threshold"
    if tcp.get("connectionSuccessRate") is not None and float(tcp.get("connectionSuccessRate") or 0) < 0.999:
        return "tcp-connect"
    if tcp.get("ackSuccessRate") is not None and float(tcp.get("ackSuccessRate") or 0) < 0.999:
        return "tcp-ack"
    if tcp.get("deliverySuccessRate") is not None and float(tcp.get("deliverySuccessRate") or 0) < 0.999:
        return "tcp-delivery"
    if tcp.get("heartbeatAckRate") is not None and float(tcp.get("heartbeatAckRate") or 0) < 0.999:
        return "tcp-heartbeat"
    if tcp.get("deliveryP99Ms") is not None:
        return "tcp-latency"
    if k6:
        return "http-latency-or-errors"
    return "unknown"


def priority_for(scenario: dict[str, Any], issue_type: str) -> str:
    status = str(scenario.get("status", "UNKNOWN"))
    if issue_type in {"entrypoint", "prerequisites"}:
        return "P0"
    if status == "FAIL":
        return "P1"
    if status == "UNKNOWN":
        return "P2"
    return "P3"


def action_for(scenario: dict[str, Any], issue_type: str) -> str:
    category = str(scenario.get("category") or "")
    if issue_type == "prerequisites":
        return "Fix ACCOUNT_FILE size/path, IM_CONVERSATION_ID, or other selected scenario inputs before running the matrix."
    if issue_type == "entrypoint":
        blob = text_blob(scenario)
        if "local_network_proxy_http_403_intercept" in blob or "route/proxy is intercepting" in blob:
            return "Disable the local TUN/proxy or rerun http_entrypoint_probe.sh from a clean network before changing server-side routing."
        return "Fix BASE_URL, reverse proxy/WAF/firewall/IP allowlist, service binding, or wrong process on the port before running capacity tests."
    existing = scenario.get("optimizationHint")
    if existing:
        return str(existing)
    if issue_type == "missing-artifacts":
        return "Rerun without PERF_DRY_RUN, confirm k6/TCPDriver executed, and check stdout.log plus k6-summary.json or TCP JSONL artifacts."
    if issue_type == "tcp-connect":
        return "Tune gateway listen backlog, kernel TCP backlog, auth timeout, load-generator ramp/concurrency, and login-cache prewarm."
    if issue_type == "tcp-ack":
        return "Optimize command-api write path, hot conversation limiter, sequence allocation, Kafka/outbox publish, and command API latency."
    if issue_type == "tcp-delivery":
        return "Optimize realtime route lookup, gateway fanout, TCP write pressure, owner delivery, relay batch size, and client catch-up."
    if issue_type == "tcp-heartbeat":
        return "Check gateway event loop pressure, heartbeat interval, client load-generator pressure, and TCP send queue backpressure."
    if issue_type == "k6-threshold":
        return CATEGORY_OPTIMIZATION_HINTS.get(category, "Inspect failed k6 threshold metrics and the scenario-specific endpoint path.")
    return CATEGORY_OPTIMIZATION_HINTS.get(category, "Inspect report reasons, raw scenario stdout, service metrics, and matching code path before tuning.")


def compact_metric_summary(scenario: dict[str, Any]) -> str:
    parts: list[str] = []
    for item in scenario.get("p99") or []:
        parts.append(str(item))
    tcp = scenario.get("tcp") or {}
    for key, label in [
        ("connectionSuccessRate", "conn"),
        ("ackSuccessRate", "ack"),
        ("deliverySuccessRate", "delivery"),
        ("heartbeatAckRate", "heartbeat"),
    ]:
        value = tcp.get(key)
        if value is not None:
            try:
                parts.append(f"{label}={float(value) * 100:.2f}%")
            except (TypeError, ValueError):
                parts.append(f"{label}={value}")
    k6 = scenario.get("k6") or {}
    if k6.get("httpReqFailedRate") is not None:
        try:
            parts.append(f"http_failed={float(k6['httpReqFailedRate']) * 100:.2f}%")
        except (TypeError, ValueError):
            parts.append(f"http_failed={k6['httpReqFailedRate']}")
    if scenario.get("lagClearAfterSendSeconds") is not None:
        parts.append(f"lag_clear={scenario['lagClearAfterSendSeconds']}s")
    return "; ".join(parts) if parts else "-"


def triage_records(report: dict[str, Any]) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for scenario in report.get("scenarios") or []:
        status = str(scenario.get("status", "UNKNOWN"))
        if status == "PASS":
            continue
        issue_type = classify_issue(scenario)
        records.append({
            "priority": priority_for(scenario, issue_type),
            "name": str(scenario.get("name", "")),
            "category": str(scenario.get("category", "")),
            "status": status,
            "issueType": issue_type,
            "metrics": compact_metric_summary(scenario),
            "reasons": "; ".join(str(item) for item in scenario.get("reasons") or []),
            "action": action_for(scenario, issue_type),
        })
    priority_rank = {"P0": 0, "P1": 1, "P2": 2, "P3": 3}
    return sorted(records, key=lambda item: (priority_rank.get(item["priority"], 9), item["category"], item["name"]))


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


def build_markdown(report_path: Path, report: dict[str, Any], records: list[dict[str, Any]]) -> str:
    rows = [["Priority", "Scenario", "Category", "Status", "Issue", "Metrics", "Action"]]
    for record in records:
        rows.append([
            record["priority"],
            f"`{record['name']}`",
            f"`{record['category']}`",
            record["status"],
            record["issueType"],
            record["metrics"],
            record["action"],
        ])
    category_counts: dict[str, int] = {}
    for record in records:
        category_counts[record["category"]] = category_counts.get(record["category"], 0) + 1
    category_rows = [["Category", "Open Issues"]]
    for category, count in sorted(category_counts.items()):
        category_rows.append([f"`{category}`", str(count)])
    return "\n".join([
        "# Performance Triage",
        "",
        f"- report: `{report_path}`",
        f"- scenarios: `{report.get('scenarioCount', len(report.get('scenarios') or []))}`",
        f"- failed: `{report.get('failed', 0)}`",
        f"- unknown: `{report.get('unknown', 0)}`",
        f"- open issues: `{len(records)}`",
        "",
        "## Priority Queue",
        "",
        markdown_table(rows) if records else "No failed or unknown scenarios.",
        "",
        "## Category Counts",
        "",
        markdown_table(category_rows) if records else "No failed or unknown categories.",
        "",
    ])


def write_csv(path: Path, records: list[dict[str, Any]]) -> None:
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=["priority", "name", "category", "status", "issueType", "metrics", "reasons", "action"],
        )
        writer.writeheader()
        for record in records:
            writer.writerow(record)


def main() -> int:
    parser = argparse.ArgumentParser(description="Create an action-oriented triage report from performance report.json.")
    parser.add_argument("--report", required=True, help="Path to report.json")
    parser.add_argument("--output", help="Write Markdown triage report.")
    parser.add_argument("--json-output", help="Write machine-readable triage JSON.")
    parser.add_argument("--csv-output", help="Write triage CSV.")
    parser.add_argument("--strict", action="store_true", help="Exit non-zero when any open issue exists.")
    args = parser.parse_args()

    report_path = Path(args.report)
    report = read_report(report_path)
    records = triage_records(report)
    markdown = build_markdown(report_path, report, records)
    if args.output:
        Path(args.output).write_text(markdown)
    else:
        print(markdown)
    if args.json_output:
        Path(args.json_output).write_text(json.dumps({
            "report": str(report_path),
            "openIssueCount": len(records),
            "issues": records,
        }, indent=2, sort_keys=True) + "\n")
    if args.csv_output:
        write_csv(Path(args.csv_output), records)
    if args.strict and records:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
