#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Any

from perf_report import CATEGORY_OPTIMIZATION_HINTS


def read_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text())
    except Exception as exc:
        raise SystemExit(f"Failed to read JSON {path}: {exc}") from exc


def is_entrypoint(row: dict[str, Any]) -> bool:
    blob = " ".join(
        str(row.get(key) or "")
        for key in ["scenario", "category", "latestReason", "optimizationHint"]
    )
    return (
        is_local_network_entrypoint(row)
        or "HTTP login preflight failed" in blob
        or "local_network_proxy_http_403_intercept" in blob
        or "uniform_empty_403" in blob
        or "HTTP 403" in blob
        or "entrypoint/deployment" in blob
        or "entrypoint probe" in blob
    )


def is_local_network_entrypoint(row: dict[str, Any]) -> bool:
    blob = " ".join(
        str(row.get(key) or "")
        for key in ["scenario", "category", "latestReason", "optimizationHint"]
    )
    return (
        "local_network_proxy_http_403_intercept" in blob
        or "disable_local_proxy_or_test_from_clean_network" in blob
        or "local route or proxy" in blob
        or "route/proxy is intercepting" in blob
    )


def is_prerequisite(row: dict[str, Any]) -> bool:
    blob = " ".join(
        str(row.get(key) or "")
        for key in ["scenario", "category", "latestReason", "optimizationHint"]
    )
    return "Scenario requirement preflight failed" in blob or str(row.get("scenario")) == "preflight-scenario-requirements"


def scenario_tier(name: str) -> str:
    if name.endswith("-smoke"):
        return "smoke"
    if name.endswith("-baseline"):
        return "baseline"
    if name.endswith("-capacity"):
        return "capacity"
    return "custom"


def command_for(row: dict[str, Any]) -> str:
    name = str(row.get("scenario") or "")
    status = str(row.get("latestStatus") or "")
    if is_prerequisite(row):
        return "Fix ACCOUNT_FILE size/path, IM_CONVERSATION_ID, or selected scenario inputs before running any matrix."
    if is_local_network_entrypoint(row):
        return "Disable the local TUN/proxy or rerun http_entrypoint_probe.sh from a clean network before changing the server."
    if is_entrypoint(row):
        return "Run http_entrypoint_probe.sh and fix BASE_URL/proxy/firewall/service binding before running any matrix."
    if status == "NEVER_RUN":
        return f'SCENARIOS="{name}" ./run_perf_scenarios.sh'
    if status == "UNKNOWN":
        return f'Rerun SCENARIOS="{name}" without PERF_DRY_RUN and inspect stdout/k6-summary/TCP JSONL artifacts.'
    if status == "FAIL":
        return str(row.get("optimizationHint") or CATEGORY_OPTIMIZATION_HINTS.get(str(row.get("category") or ""), "Inspect raw metrics and optimize the scenario category."))
    return "No action required."


def priority_for(row: dict[str, Any]) -> tuple[str, str]:
    status = str(row.get("latestStatus") or "")
    name = str(row.get("scenario") or "")
    tier = scenario_tier(name)
    if is_prerequisite(row) and status == "FAIL":
        return "P0", "prerequisite-blocker"
    if is_entrypoint(row) and status == "FAIL":
        return "P0", "entrypoint-blocker"
    if status == "FAIL":
        return "P1", "optimize-failed-scenario"
    if status == "UNKNOWN":
        return "P2", "rerun-missing-artifacts"
    if status == "NEVER_RUN" and tier == "smoke":
        return "P2", "run-untested-smoke"
    if status == "NEVER_RUN" and tier == "custom":
        return "P2", "run-untested-custom"
    if status == "NEVER_RUN":
        return "P3", f"run-untested-{tier}"
    return "P4", "complete"


def build_actions(status_payload: dict[str, Any], include_pass: bool = False) -> list[dict[str, Any]]:
    actions: list[dict[str, Any]] = []
    for row in status_payload.get("scenarios") or []:
        status = str(row.get("latestStatus") or "")
        if status == "PASS" and not include_pass:
            continue
        priority, action_type = priority_for(row)
        if priority == "P4" and not include_pass:
            continue
        actions.append({
            "priority": priority,
            "actionType": action_type,
            "scenario": str(row.get("scenario") or ""),
            "category": str(row.get("category") or ""),
            "latestStatus": status,
            "runCount": int(row.get("runCount") or 0),
            "latestRunID": str(row.get("latestRunID") or ""),
            "latestRunDir": str(row.get("latestRunDir") or ""),
            "latestMtime": float(row.get("latestMtime") or 0),
            "latestBaseURL": str(row.get("latestBaseURL") or ""),
            "latestTCPHost": str(row.get("latestTCPHost") or ""),
            "latestTCPPort": str(row.get("latestTCPPort") or ""),
            "reason": str(row.get("latestReason") or row.get("optimizationHint") or ""),
            "action": command_for(row),
        })
    priority_rank = {"P0": 0, "P1": 1, "P2": 2, "P3": 3, "P4": 4}
    return sorted(
        actions,
        key=lambda item: (
            priority_rank.get(item["priority"], 9),
            item["actionType"],
            item["category"],
            item["scenario"],
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


def build_markdown(status_path: Path, actions: list[dict[str, Any]], limit: int | None) -> str:
    priority_counts: dict[str, int] = {}
    category_counts: dict[str, int] = {}
    for action in actions:
        priority = str(action["priority"])
        category = str(action["category"] or "unknown")
        priority_counts[priority] = priority_counts.get(priority, 0) + 1
        category_counts[category] = category_counts.get(category, 0) + 1

    priority_rows = [["Priority", "Actions"]]
    for priority in ["P0", "P1", "P2", "P3", "P4"]:
        if priority in priority_counts:
            priority_rows.append([priority, str(priority_counts[priority])])

    category_rows = [["Category", "Actions"]]
    for category, count in sorted(category_counts.items(), key=lambda item: (-item[1], item[0])):
        category_rows.append([f"`{category}`", str(count)])

    display = actions[:limit] if limit is not None else actions
    action_rows = [["Priority", "Type", "Scenario", "Category", "Status", "Runs", "Action"]]
    for action in display:
        action_rows.append([
            str(action["priority"]),
            str(action["actionType"]),
            f"`{action['scenario']}`",
            f"`{action['category'] or '-'}`",
            str(action["latestStatus"]),
            str(action["runCount"]),
            str(action["action"])[:180],
        ])

    count_line = f"- actions: `{len(actions)}`"
    if limit is not None:
        count_line = f"- actions: `{len(display)}` displayed of `{len(actions)}` total"
    return "\n".join([
        "# Performance Next Actions",
        "",
        f"- scenarioStatus: `{status_path}`",
        count_line,
        "",
        "## Priority Summary",
        "",
        markdown_table(priority_rows) if len(priority_rows) > 1 else "No open actions.",
        "",
        "## Category Summary",
        "",
        markdown_table(category_rows) if len(category_rows) > 1 else "No open categories.",
        "",
        "## Action Queue",
        "",
        markdown_table(action_rows) if actions else "No open actions.",
        "",
    ])


def write_csv(path: Path, actions: list[dict[str, Any]]) -> None:
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=[
                "priority",
                "actionType",
                "scenario",
                "category",
                "latestStatus",
                "runCount",
                "latestRunID",
                "latestRunDir",
                "latestMtime",
                "latestBaseURL",
                "latestTCPHost",
                "latestTCPPort",
                "reason",
                "action",
            ],
        )
        writer.writeheader()
        for action in actions:
            writer.writerow(action)


def main() -> int:
    parser = argparse.ArgumentParser(description="Build a cross-scenario performance next-action queue from scenario-status JSON.")
    parser.add_argument("--scenario-status", required=True, help="Path to perf_scenario_status.py JSON output.")
    parser.add_argument("--limit", type=int, help="Only display the first N actions.")
    parser.add_argument("--include-pass", action="store_true", help="Include PASS scenarios as P4 complete actions.")
    parser.add_argument("--output", help="Write Markdown action queue.")
    parser.add_argument("--json-output", help="Write machine-readable action queue.")
    parser.add_argument("--csv-output", help="Write action queue CSV.")
    args = parser.parse_args()
    if args.limit is not None and args.limit <= 0:
        parser.error("--limit must be greater than 0")

    status_path = Path(args.scenario_status)
    status_payload = read_json(status_path)
    actions = build_actions(status_payload, include_pass=args.include_pass)
    markdown = build_markdown(status_path, actions, args.limit)
    payload = {
        "scenarioStatus": str(status_path),
        "actionCount": len(actions),
        "priorityCounts": {
            priority: sum(1 for action in actions if action["priority"] == priority)
            for priority in ["P0", "P1", "P2", "P3", "P4"]
        },
        "actions": actions,
    }
    if args.output:
        Path(args.output).write_text(markdown)
    else:
        print(markdown)
    if args.json_output:
        Path(args.json_output).write_text(json.dumps(payload, indent=2, sort_keys=True))
    if args.csv_output:
        write_csv(Path(args.csv_output), actions)
    return 1 if payload["priorityCounts"].get("P0", 0) or payload["priorityCounts"].get("P1", 0) else 0


if __name__ == "__main__":
    raise SystemExit(main())
