#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from perf_report import CATEGORY_OPTIMIZATION_HINTS


@dataclass(frozen=True)
class SLOPolicy:
    name: str
    max_http_failure_rate: float | None = None
    max_checks_failure_count: int | None = 0
    max_http_p99_ms: float | None = None
    max_im_metric_p99_ms: float | None = None
    min_connection_success_rate: float | None = None
    min_ack_success_rate: float | None = None
    min_delivery_success_rate: float | None = None
    min_heartbeat_ack_rate: float | None = None
    max_heartbeat_p99_ms: float | None = None
    max_delivery_p99_ms: float | None = None
    max_lag_clear_after_send_seconds: float | None = None


DEFAULT_HTTP_POLICY = SLOPolicy(
    name="http-default",
    max_http_failure_rate=0.005,
    max_http_p99_ms=3000,
    max_im_metric_p99_ms=3000,
)

POLICIES: dict[str, SLOPolicy] = {
    "preflight": SLOPolicy(name="preflight", max_http_failure_rate=0, max_http_p99_ms=1000, max_im_metric_p99_ms=1000),
    "http-login": SLOPolicy(name="http-login", max_http_failure_rate=0.001, max_http_p99_ms=1000, max_im_metric_p99_ms=1000),
    "http-account-lifecycle": SLOPolicy(name="http-account-lifecycle", max_http_failure_rate=0.005, max_http_p99_ms=2500, max_im_metric_p99_ms=2500),
    "http-auth-session": SLOPolicy(name="http-auth-session", max_http_failure_rate=0.002, max_http_p99_ms=1200, max_im_metric_p99_ms=1200),
    "http-auth-session-management": SLOPolicy(name="http-auth-session-management", max_http_failure_rate=0.002, max_http_p99_ms=1500, max_im_metric_p99_ms=1500),
    "http-auth-token-rotation": SLOPolicy(name="http-auth-token-rotation", max_http_failure_rate=0.002, max_http_p99_ms=1200, max_im_metric_p99_ms=1200),
    "http-auth-failure-recovery": SLOPolicy(name="http-auth-failure-recovery", max_http_failure_rate=0.005, max_http_p99_ms=1200, max_im_metric_p99_ms=1200),
    "http-push-token": SLOPolicy(name="http-push-token", max_http_failure_rate=0.002, max_http_p99_ms=1200, max_im_metric_p99_ms=1200),
    "http-client-health": SLOPolicy(name="http-client-health", max_http_failure_rate=0.005, max_http_p99_ms=1200, max_im_metric_p99_ms=1200),
    "http-client-sync-mix": SLOPolicy(name="http-client-sync-mix", max_http_failure_rate=0.005, max_http_p99_ms=2500, max_im_metric_p99_ms=2500),
    "http-user-journey": SLOPolicy(name="http-user-journey", max_http_failure_rate=0.005, max_http_p99_ms=3500, max_im_metric_p99_ms=3500),
    "http-mixed-workload": SLOPolicy(name="http-mixed-workload", max_http_failure_rate=0.005, max_http_p99_ms=3500, max_im_metric_p99_ms=3500),
    "http-offline-catchup": SLOPolicy(name="http-offline-catchup", max_http_failure_rate=0.005, max_http_p99_ms=5000, max_im_metric_p99_ms=5000),
    "http-inbox-fanout": SLOPolicy(name="http-inbox-fanout", max_http_failure_rate=0.005, max_http_p99_ms=5000, max_im_metric_p99_ms=5000),
    "http-multi-device-sync": SLOPolicy(name="http-multi-device-sync", max_http_failure_rate=0.005, max_http_p99_ms=4000, max_im_metric_p99_ms=4000),
    "http-cold-start": SLOPolicy(name="http-cold-start", max_http_failure_rate=0.005, max_http_p99_ms=3000, max_im_metric_p99_ms=3000),
    "http-timeline-pagination": SLOPolicy(name="http-timeline-pagination", max_http_failure_rate=0.005, max_http_p99_ms=2500, max_im_metric_p99_ms=2500),
    "http-timeline-history-scroll": SLOPolicy(name="http-timeline-history-scroll", max_http_failure_rate=0.005, max_http_p99_ms=2500, max_im_metric_p99_ms=2500),
    "http-domain-events": SLOPolicy(name="http-domain-events", max_http_failure_rate=0.005, max_http_p99_ms=2500, max_im_metric_p99_ms=2500),
    "http-read-state": SLOPolicy(name="http-read-state", max_http_failure_rate=0.005, max_http_p99_ms=1800, max_im_metric_p99_ms=1800),
    "http-direct-message-lifecycle": SLOPolicy(name="http-direct-message-lifecycle", max_http_failure_rate=0.005, max_http_p99_ms=3000, max_im_metric_p99_ms=3000),
    "http-search-sync": SLOPolicy(name="http-search-sync", max_http_failure_rate=0.005, max_http_p99_ms=3000, max_im_metric_p99_ms=3000),
    "http-group-admin": SLOPolicy(name="http-group-admin", max_http_failure_rate=0.005, max_http_p99_ms=2500, max_im_metric_p99_ms=2500),
    "http-group-membership": SLOPolicy(name="http-group-membership", max_http_failure_rate=0.005, max_http_p99_ms=2500, max_im_metric_p99_ms=2500),
    "http-group-invite": SLOPolicy(name="http-group-invite", max_http_failure_rate=0.005, max_http_p99_ms=2500, max_im_metric_p99_ms=2500),
    "http-governance": SLOPolicy(name="http-governance", max_http_failure_rate=0.005, max_http_p99_ms=2500, max_im_metric_p99_ms=2500),
    "http-conversation-preferences": SLOPolicy(name="http-conversation-preferences", max_http_failure_rate=0.005, max_http_p99_ms=2500, max_im_metric_p99_ms=2500),
    "http-conversation-visibility": SLOPolicy(name="http-conversation-visibility", max_http_failure_rate=0.005, max_http_p99_ms=3500, max_im_metric_p99_ms=3500),
    "http-message-forward": SLOPolicy(name="http-message-forward", max_http_failure_rate=0.005, max_http_p99_ms=3000, max_im_metric_p99_ms=3000),
    "http-ai-stream": SLOPolicy(name="http-ai-stream", max_http_failure_rate=0.01, max_http_p99_ms=5000, max_im_metric_p99_ms=5000),
    "http-contact-request": SLOPolicy(name="http-contact-request", max_http_failure_rate=0.005, max_http_p99_ms=2000, max_im_metric_p99_ms=2000),
    "http-contact-sync": SLOPolicy(name="http-contact-sync", max_http_failure_rate=0.005, max_http_p99_ms=2500, max_im_metric_p99_ms=2500),
    "http-profile-sync": SLOPolicy(name="http-profile-sync", max_http_failure_rate=0.005, max_http_p99_ms=2500, max_im_metric_p99_ms=2500),
    "http-safety-block": SLOPolicy(name="http-safety-block", max_http_failure_rate=0.005, max_http_p99_ms=2000, max_im_metric_p99_ms=2000),
    "http-safety-block-enforcement": SLOPolicy(name="http-safety-block-enforcement", max_http_failure_rate=0.005, max_http_p99_ms=2500, max_im_metric_p99_ms=2500),
    "http-access-control-enforcement": SLOPolicy(name="http-access-control-enforcement", max_http_failure_rate=0.005, max_http_p99_ms=2500, max_im_metric_p99_ms=2500),
    "http-admin-report": SLOPolicy(name="http-admin-report", max_http_failure_rate=0.005, max_http_p99_ms=2500, max_im_metric_p99_ms=2500),
    "http-media-file": SLOPolicy(name="http-media-file", max_http_failure_rate=0.01, max_http_p99_ms=5000, max_im_metric_p99_ms=5000),
    "http-media-failure-recovery": SLOPolicy(name="http-media-failure-recovery", max_http_failure_rate=0.02, max_http_p99_ms=3000, max_im_metric_p99_ms=3000),
    "http-convergence": SLOPolicy(name="http-convergence", max_http_failure_rate=0.005, max_http_p99_ms=2500, max_im_metric_p99_ms=2500),
    "http-direct-convergence": SLOPolicy(name="http-direct-convergence", max_http_failure_rate=0.005, max_http_p99_ms=2500, max_im_metric_p99_ms=2500),
    "http-small-group": SLOPolicy(name="http-small-group", max_http_failure_rate=0.005, max_http_p99_ms=2500, max_im_metric_p99_ms=2500),
    "http-hot-write": SLOPolicy(name="http-hot-write", max_http_failure_rate=0.005, max_http_p99_ms=2000, max_im_metric_p99_ms=2000),
    "tcp-online": SLOPolicy(
        name="tcp-online",
        min_connection_success_rate=0.999,
        min_heartbeat_ack_rate=0.999,
        max_heartbeat_p99_ms=10000,
    ),
    "tcp-reconnect": SLOPolicy(
        name="tcp-reconnect",
        min_connection_success_rate=0.999,
        min_heartbeat_ack_rate=0.999,
        max_heartbeat_p99_ms=10000,
    ),
    "tcp-multi-device-online": SLOPolicy(
        name="tcp-multi-device-online",
        min_connection_success_rate=0.999,
        min_heartbeat_ack_rate=0.999,
        max_heartbeat_p99_ms=10000,
    ),
    "tcp-multi-device-delivery": SLOPolicy(
        name="tcp-multi-device-delivery",
        min_connection_success_rate=0.999,
        min_ack_success_rate=0.999,
        min_delivery_success_rate=0.999,
        min_heartbeat_ack_rate=0.999,
        max_heartbeat_p99_ms=10000,
        max_delivery_p99_ms=3000,
        max_lag_clear_after_send_seconds=15,
    ),
    "tcp-pair-delivery": SLOPolicy(
        name="tcp-pair-delivery",
        min_connection_success_rate=0.999,
        min_ack_success_rate=0.999,
        min_delivery_success_rate=0.999,
        min_heartbeat_ack_rate=0.999,
        max_heartbeat_p99_ms=10000,
        max_delivery_p99_ms=3000,
        max_lag_clear_after_send_seconds=15,
    ),
    "tcp-large-group": SLOPolicy(
        name="tcp-large-group",
        min_connection_success_rate=0.999,
        min_ack_success_rate=0.999,
        min_delivery_success_rate=0.999,
        min_heartbeat_ack_rate=0.999,
        max_heartbeat_p99_ms=10000,
        max_delivery_p99_ms=5000,
        max_lag_clear_after_send_seconds=30,
    ),
}


def read_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text())
    except Exception as exc:
        raise SystemExit(f"Failed to read JSON {path}: {exc}") from exc


def numeric(value: Any) -> float | None:
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def percent(value: float | None) -> str:
    if value is None:
        return "-"
    return f"{value * 100:.3f}%"


def ms(value: float | None) -> str:
    if value is None:
        return "-"
    if value.is_integer():
        return f"{int(value)}ms"
    return f"{value:.1f}ms"


def seconds(value: float | None) -> str:
    if value is None:
        return "-"
    if value.is_integer():
        return f"{int(value)}s"
    return f"{value:.1f}s"


def policy_for(category: str) -> SLOPolicy:
    return POLICIES.get(category, DEFAULT_HTTP_POLICY if category.startswith("http-") else SLOPolicy(name="generic"))


def add_violation(violations: list[str], label: str, actual: float | None, operator: str, expected: float | None, unit: str = "") -> None:
    if actual is None or expected is None:
        return
    if operator == "<=" and actual > expected:
        violations.append(f"{label} {format_value(actual, unit)} > {format_value(expected, unit)}")
    elif operator == ">=" and actual < expected:
        violations.append(f"{label} {format_value(actual, unit)} < {format_value(expected, unit)}")


def format_value(value: float, unit: str) -> str:
    if unit == "%":
        return percent(value)
    if unit == "ms":
        return ms(value)
    if unit == "s":
        return seconds(value)
    if value.is_integer():
        return str(int(value))
    return f"{value:.3f}"


def im_metric_p99_values(k6: dict[str, Any]) -> list[tuple[str, float]]:
    values: list[tuple[str, float]] = []
    for key, value in k6.items():
        if not key.startswith("im_") or not key.endswith(".p(99)"):
            continue
        parsed = numeric(value)
        if parsed is not None:
            values.append((key, parsed))
    return sorted(values, key=lambda item: item[1], reverse=True)


def scenario_action(category: str, violations: list[str], scenario_status: str) -> str:
    if scenario_status == "UNKNOWN":
        return "Rerun this scenario without PERF_DRY_RUN and verify k6-summary.json or TCP JSONL artifacts are present."
    if category == "preflight" or any("entrypoint" in item.lower() or "403" in item for item in violations):
        return "Fix the HTTP entrypoint before treating any scenario result as a performance signal."
    return CATEGORY_OPTIMIZATION_HINTS.get(category, "Inspect the scenario stdout, service metrics, and matching code path before tuning.")


def evaluate_scenario(scenario: dict[str, Any]) -> dict[str, Any]:
    category = str(scenario.get("category") or "")
    status = str(scenario.get("status") or "UNKNOWN")
    policy = policy_for(category)
    k6 = scenario.get("k6") or {}
    tcp = scenario.get("tcp") or {}
    violations: list[str] = []
    missing: list[str] = []

    if status == "UNKNOWN":
        missing.append("no runtime evidence")
    if status == "FAIL":
        for reason in scenario.get("reasons") or []:
            violations.append(str(reason))

    add_violation(violations, "http failure rate", numeric(k6.get("httpReqFailedRate")), "<=", policy.max_http_failure_rate, "%")
    add_violation(violations, "http p99", numeric(k6.get("httpReqDurationP99")), "<=", policy.max_http_p99_ms, "ms")
    add_violation(violations, "connection success", numeric(tcp.get("connectionSuccessRate")), ">=", policy.min_connection_success_rate, "%")
    add_violation(violations, "ack success", numeric(tcp.get("ackSuccessRate")), ">=", policy.min_ack_success_rate, "%")
    add_violation(violations, "delivery success", numeric(tcp.get("deliverySuccessRate")), ">=", policy.min_delivery_success_rate, "%")
    add_violation(violations, "heartbeat ack", numeric(tcp.get("heartbeatAckRate")), ">=", policy.min_heartbeat_ack_rate, "%")
    add_violation(violations, "heartbeat p99", numeric(tcp.get("heartbeatP99Ms")), "<=", policy.max_heartbeat_p99_ms, "ms")
    add_violation(violations, "delivery p99", numeric(tcp.get("deliveryP99Ms")), "<=", policy.max_delivery_p99_ms, "ms")
    add_violation(violations, "lag clear", numeric(scenario.get("lagClearAfterSendSeconds")), "<=", policy.max_lag_clear_after_send_seconds, "s")

    checks_fails = numeric(k6.get("checksFails"))
    if policy.max_checks_failure_count is not None and checks_fails is not None and checks_fails > policy.max_checks_failure_count:
        violations.append(f"k6 checks failed {format_value(checks_fails, '')} > {policy.max_checks_failure_count}")
    for name, value in im_metric_p99_values(k6):
        if policy.max_im_metric_p99_ms is not None and value > policy.max_im_metric_p99_ms:
            violations.append(f"{name} {ms(value)} > {ms(policy.max_im_metric_p99_ms)}")

    if missing:
        slo_status = "UNKNOWN"
    elif violations:
        slo_status = "FAIL"
    else:
        slo_status = "PASS"

    slowest_im = im_metric_p99_values(k6)[:3]
    return {
        "scenario": str(scenario.get("name") or ""),
        "category": category,
        "target": str(scenario.get("target") or ""),
        "runTarget": scenario.get("runTarget") or {},
        "scenarioStatus": status,
        "sloStatus": slo_status,
        "policy": policy.name,
        "violations": violations,
        "missing": missing,
        "action": scenario_action(category, violations, status) if slo_status != "PASS" else "",
        "httpFailureRate": numeric(k6.get("httpReqFailedRate")),
        "httpP99Ms": numeric(k6.get("httpReqDurationP99")),
        "connectionSuccessRate": numeric(tcp.get("connectionSuccessRate")),
        "ackSuccessRate": numeric(tcp.get("ackSuccessRate")),
        "deliverySuccessRate": numeric(tcp.get("deliverySuccessRate")),
        "heartbeatAckRate": numeric(tcp.get("heartbeatAckRate")),
        "heartbeatP99Ms": numeric(tcp.get("heartbeatP99Ms")),
        "deliveryP99Ms": numeric(tcp.get("deliveryP99Ms")),
        "lagClearAfterSendSeconds": numeric(scenario.get("lagClearAfterSendSeconds")),
        "slowestImP99": [{"metric": name, "p99Ms": value} for name, value in slowest_im],
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


def build_report(report_path: Path, report: dict[str, Any]) -> dict[str, Any]:
    scenarios = [evaluate_scenario(item) for item in report.get("scenarios") or []]
    counts = {"PASS": 0, "FAIL": 0, "UNKNOWN": 0}
    category_counts: dict[str, dict[str, int]] = {}
    for item in scenarios:
        status = str(item["sloStatus"])
        counts[status] = counts.get(status, 0) + 1
        bucket = category_counts.setdefault(str(item["category"]), {"PASS": 0, "FAIL": 0, "UNKNOWN": 0, "total": 0})
        bucket[status] = bucket.get(status, 0) + 1
        bucket["total"] += 1
    return {
        "report": str(report_path),
        "target": report.get("target") or {},
        "summary": {
            "scenarioCount": len(scenarios),
            "pass": counts.get("PASS", 0),
            "fail": counts.get("FAIL", 0),
            "unknown": counts.get("UNKNOWN", 0),
            "status": "FAIL" if counts.get("FAIL", 0) else ("UNKNOWN" if counts.get("UNKNOWN", 0) else "PASS"),
        },
        "categoryCounts": category_counts,
        "scenarios": sorted(scenarios, key=lambda item: ({"FAIL": 0, "UNKNOWN": 1, "PASS": 2}.get(str(item["sloStatus"]), 9), str(item["category"]), str(item["scenario"]))),
    }


def build_markdown(payload: dict[str, Any]) -> str:
    summary = payload["summary"]
    category_rows = [["Category", "PASS", "FAIL", "UNKNOWN", "Total"]]
    for category, counts in sorted(payload["categoryCounts"].items()):
        category_rows.append([
            f"`{category}`",
            str(counts.get("PASS", 0)),
            str(counts.get("FAIL", 0)),
            str(counts.get("UNKNOWN", 0)),
            str(counts.get("total", 0)),
        ])

    scenario_rows = [["Scenario", "Category", "SLO", "Policy", "HTTP P99", "Delivery P99", "Reason"]]
    for item in payload["scenarios"][:50]:
        reasons = item["violations"] or item["missing"] or []
        scenario_rows.append([
            f"`{item['scenario']}`",
            f"`{item['category']}`",
            str(item["sloStatus"]),
            f"`{item['policy']}`",
            ms(item.get("httpP99Ms")),
            ms(item.get("deliveryP99Ms")),
            "; ".join(str(reason) for reason in reasons[:3]) or "-",
        ])

    action_rows = [["Priority", "Scenario", "Action"]]
    for item in payload["scenarios"]:
        if item["sloStatus"] == "PASS":
            continue
        priority = "P1" if item["sloStatus"] == "FAIL" else "P2"
        action_rows.append([priority, f"`{item['scenario']}`", str(item["action"])])

    return "\n".join([
        "# Performance SLO Report",
        "",
        f"- report: `{payload['report']}`",
        f"- status: `{summary['status']}`",
        f"- scenarios: `{summary['scenarioCount']}`",
        f"- pass/fail/unknown: `{summary['pass']}/{summary['fail']}/{summary['unknown']}`",
        "",
        "## Category Summary",
        "",
        markdown_table(category_rows),
        "",
        "## Scenario SLO",
        "",
        markdown_table(scenario_rows),
        "",
        "## Actions",
        "",
        markdown_table(action_rows) if len(action_rows) > 1 else "No SLO actions.",
        "",
    ])


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    fieldnames = [
        "scenario",
        "category",
        "target",
        "runTarget",
        "scenarioStatus",
        "sloStatus",
        "policy",
        "httpFailureRate",
        "httpP99Ms",
        "connectionSuccessRate",
        "ackSuccessRate",
        "deliverySuccessRate",
        "heartbeatAckRate",
        "heartbeatP99Ms",
        "deliveryP99Ms",
        "lagClearAfterSendSeconds",
        "violations",
        "missing",
        "action",
    ]
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow({
                key: (
                    "; ".join(str(item) for item in row.get(key, []))
                    if key in {"violations", "missing"}
                    else row.get(key)
                )
                for key in fieldnames
            })


def main() -> int:
    parser = argparse.ArgumentParser(description="Evaluate performance report.json against default IM SLO policies.")
    parser.add_argument("--report", required=True, help="Path to report.json.")
    parser.add_argument("--output", help="Write Markdown SLO report.")
    parser.add_argument("--json-output", help="Write machine-readable SLO report.")
    parser.add_argument("--csv-output", help="Write flat scenario SLO CSV.")
    parser.add_argument("--strict", action="store_true", help="Exit non-zero when any SLO fails or lacks runtime evidence.")
    args = parser.parse_args()

    report_path = Path(args.report)
    payload = build_report(report_path, read_json(report_path))
    markdown = build_markdown(payload)
    if args.output:
        Path(args.output).write_text(markdown)
    else:
        print(markdown)
    if args.json_output:
        Path(args.json_output).write_text(json.dumps(payload, indent=2, sort_keys=True))
    if args.csv_output:
        write_csv(Path(args.csv_output), payload["scenarios"])
    if args.strict and payload["summary"]["status"] != "PASS":
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
