#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Any


DOMAIN_HINTS = {
    "preflight": "Fix HTTP entrypoint, service binding, reverse proxy, WAF, firewall, or wrong process before trusting any runtime result.",
    "auth-session": "Optimize login/session DB paths, token refresh, device-session indexes, push-token writes, and session kick fanout.",
    "client-sync": "Optimize conversation list/changes, domain-events catch-up, client-health aggregation, timeline pagination indexes, and cold-start read batching.",
    "message-workflow": "Optimize command write path, timeline/since reads, summary projection, read state, search visibility, forwarding, and message governance side effects.",
    "group-lifecycle": "Optimize membership mutations, member list/search indexes, invite flows, role changes, cache invalidation, and group metadata/preferences writes.",
    "social-profile": "Optimize contacts/changes, contact-request transitions, profile propagation, and direct-peer summary updates.",
    "safety-moderation": "Optimize block/report writes, admin report list/review indexes, and internal moderation query filters.",
    "media-file": "Optimize upload/download IO, chunk commit, media asset lookup, local/object-storage latency, and payload size limits.",
    "ai-stream": "Optimize stream start/cancel, snapshot polling, realtime stream-signal relay, and partial message persistence.",
    "tcp-realtime": "Optimize gateway connection lifecycle, auth timeout/ramp, heartbeat pressure, route lookup, TCP send queue, and load-generator pressure.",
    "hot-large-group": "Optimize hot conversation limiter, owner-delivery writes, relay payload size, fanout batch size, compact hints, timeline pull, and Kafka lag.",
    "other": "Inspect raw scenario output and add a domain-specific hint once this path becomes a capacity target.",
}

PRIORITY_RANK = {"P0": 0, "P1": 1, "P2": 2, "P3": 3, "P4": 4}


def read_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text())
    except Exception as exc:
        raise SystemExit(f"Failed to read JSON {path}: {exc}") from exc


def action_domain(action: dict[str, Any], scenario_domains: dict[str, str]) -> str:
    scenario = str(action.get("scenario") or "")
    if scenario in scenario_domains:
        return scenario_domains[scenario]
    category = str(action.get("category") or "")
    if category == "preflight" or scenario.startswith("entrypoint") or scenario.startswith("preflight"):
        return "preflight"
    return "other"


def sort_actions(actions: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted(
        actions,
        key=lambda item: (
            PRIORITY_RANK.get(str(item.get("priority") or ""), 9),
            str(item.get("actionType") or ""),
            str(item.get("scenario") or ""),
        ),
    )


def build_backlog(catalog: dict[str, Any], next_actions: dict[str, Any]) -> dict[str, Any]:
    scenario_domains = {
        str(row.get("scenario") or ""): str(row.get("domain") or "other")
        for row in catalog.get("scenarios") or []
        if row.get("scenario")
    }

    domain_rows: dict[str, dict[str, Any]] = {}
    for row in catalog.get("domains") or []:
        domain = str(row.get("domain") or "other")
        domain_rows[domain] = {
            "domain": domain,
            "scenarioCount": int(row.get("scenarioCount") or 0),
            "familyCount": int(row.get("familyCount") or 0),
            "profiles": list(row.get("profiles") or []),
            "fail": int(row.get("fail") or 0),
            "unknown": int(row.get("unknown") or 0),
            "neverRun": int(row.get("neverRun") or 0),
            "pass": int(row.get("pass") or 0),
            "noResult": int(row.get("noResult") or 0),
            "priorityCounts": {priority: 0 for priority in ["P0", "P1", "P2", "P3", "P4"]},
            "actions": [],
            "hint": DOMAIN_HINTS.get(domain, DOMAIN_HINTS["other"]),
        }

    for action in next_actions.get("actions") or []:
        domain = action_domain(action, scenario_domains)
        row = domain_rows.setdefault(domain, {
            "domain": domain,
            "scenarioCount": 0,
            "familyCount": 0,
            "profiles": [],
            "fail": 0,
            "unknown": 0,
            "neverRun": 0,
            "pass": 0,
            "noResult": 0,
            "priorityCounts": {priority: 0 for priority in ["P0", "P1", "P2", "P3", "P4"]},
            "actions": [],
            "hint": DOMAIN_HINTS.get(domain, DOMAIN_HINTS["other"]),
        })
        priority = str(action.get("priority") or "P4")
        row["priorityCounts"][priority] = int(row["priorityCounts"].get(priority, 0)) + 1
        row["actions"].append(action)

    backlog_rows: list[dict[str, Any]] = []
    for row in domain_rows.values():
        actions = sort_actions(row["actions"])
        row["actions"] = actions
        row["openActionCount"] = len(actions)
        top_priority = "-"
        for priority in ["P0", "P1", "P2", "P3", "P4"]:
            if int(row["priorityCounts"].get(priority, 0)) > 0:
                top_priority = priority
                break
        row["topPriority"] = top_priority
        row["nextAction"] = str(actions[0].get("action") or "") if actions else "No open action."
        backlog_rows.append(row)

    backlog_rows.sort(
        key=lambda row: (
            PRIORITY_RANK.get(str(row["topPriority"]), 9),
            -int(row["priorityCounts"].get("P1", 0)),
            -int(row["priorityCounts"].get("P2", 0)),
            -int(row["priorityCounts"].get("P3", 0)),
            -int(row["scenarioCount"]),
            str(row["domain"]),
        )
    )

    global_blockers = [
        action for action in next_actions.get("actions") or []
        if str(action.get("priority") or "") == "P0"
    ]

    summary = {
        "domainCount": len(backlog_rows),
        "openActionCount": sum(int(row["openActionCount"]) for row in backlog_rows),
        "globalBlockerCount": len(global_blockers),
        "priorityCounts": {
            priority: sum(int(row["priorityCounts"].get(priority, 0)) for row in backlog_rows)
            for priority in ["P0", "P1", "P2", "P3", "P4"]
        },
        "scenarioCount": int((catalog.get("summary") or {}).get("scenarioCount") or 0),
    }

    return {
        "summary": summary,
        "globalBlockers": sort_actions(global_blockers),
        "domains": backlog_rows,
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


def build_markdown(catalog_path: Path, next_actions_path: Path, payload: dict[str, Any], action_limit: int) -> str:
    summary = payload["summary"]
    priority_counts = summary["priorityCounts"]

    domain_rows = [["Domain", "Top", "Open", "P0", "P1", "P2", "P3", "Scenarios", "FAIL/UNKNOWN/NEVER", "Next Action"]]
    for row in payload["domains"]:
        domain_rows.append([
            str(row["domain"]),
            str(row["topPriority"]),
            str(row["openActionCount"]),
            str(row["priorityCounts"].get("P0", 0)),
            str(row["priorityCounts"].get("P1", 0)),
            str(row["priorityCounts"].get("P2", 0)),
            str(row["priorityCounts"].get("P3", 0)),
            str(row["scenarioCount"]),
            f"{row['fail']}/{row['unknown']}/{row['neverRun']}",
            str(row["nextAction"])[:180],
        ])

    action_rows = [["Priority", "Domain", "Scenario", "Status", "Type", "Action"]]
    all_actions: list[tuple[str, dict[str, Any]]] = []
    for row in payload["domains"]:
        for action in row["actions"]:
            all_actions.append((str(row["domain"]), action))
    all_actions.sort(key=lambda item: (
        PRIORITY_RANK.get(str(item[1].get("priority") or ""), 9),
        str(item[0]),
        str(item[1].get("scenario") or ""),
    ))
    for domain, action in all_actions[:action_limit]:
        action_rows.append([
            str(action.get("priority") or ""),
            domain,
            f"`{action.get('scenario') or ''}`",
            str(action.get("latestStatus") or ""),
            str(action.get("actionType") or ""),
            str(action.get("action") or "")[:180],
        ])

    hint_rows = [["Domain", "Optimization Focus"]]
    for row in payload["domains"]:
        if row["openActionCount"] <= 0:
            continue
        hint_rows.append([str(row["domain"]), str(row["hint"])])

    blocker_lines: list[str] = []
    if payload["globalBlockers"]:
        blocker_lines.extend([
            "## Global Blockers",
            "",
            "These must be fixed before runtime performance conclusions are valid:",
            "",
        ])
        for action in payload["globalBlockers"]:
            blocker_lines.append(f"- `{action.get('scenario')}`: {action.get('action')}")
        blocker_lines.append("")

    return "\n".join([
        "# Performance Domain Backlog",
        "",
        f"- scenarioCatalog: `{catalog_path}`",
        f"- nextActions: `{next_actions_path}`",
        f"- scenarios: `{summary['scenarioCount']}`",
        f"- domains: `{summary['domainCount']}`",
        f"- open actions: `{summary['openActionCount']}`",
        f"- global blockers: `{summary['globalBlockerCount']}`",
        f"- priorities: `P0={priority_counts['P0']} P1={priority_counts['P1']} P2={priority_counts['P2']} P3={priority_counts['P3']} P4={priority_counts['P4']}`",
        "",
        *blocker_lines,
        "## Domain Queue",
        "",
        markdown_table(domain_rows),
        "",
        "## Optimization Focus",
        "",
        markdown_table(hint_rows) if len(hint_rows) > 1 else "No open optimization focus.",
        "",
        "## Top Actions",
        "",
        markdown_table(action_rows) if len(action_rows) > 1 else "No open actions.",
        "",
    ])


def write_csv(path: Path, payload: dict[str, Any]) -> None:
    fieldnames = [
        "domain",
        "topPriority",
        "openActionCount",
        "scenarioCount",
        "familyCount",
        "fail",
        "unknown",
        "neverRun",
        "pass",
        "P0",
        "P1",
        "P2",
        "P3",
        "P4",
        "nextAction",
        "hint",
    ]
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in payload["domains"]:
            writer.writerow({
                "domain": row["domain"],
                "topPriority": row["topPriority"],
                "openActionCount": row["openActionCount"],
                "scenarioCount": row["scenarioCount"],
                "familyCount": row["familyCount"],
                "fail": row["fail"],
                "unknown": row["unknown"],
                "neverRun": row["neverRun"],
                "pass": row["pass"],
                "P0": row["priorityCounts"].get("P0", 0),
                "P1": row["priorityCounts"].get("P1", 0),
                "P2": row["priorityCounts"].get("P2", 0),
                "P3": row["priorityCounts"].get("P3", 0),
                "P4": row["priorityCounts"].get("P4", 0),
                "nextAction": row["nextAction"],
                "hint": row["hint"],
            })


def main() -> int:
    parser = argparse.ArgumentParser(description="Aggregate performance next actions by product domain for optimization planning.")
    parser.add_argument("--scenario-catalog", required=True, help="Path to perf_scenario_catalog.py JSON output.")
    parser.add_argument("--next-actions", required=True, help="Path to perf_next_actions.py JSON output.")
    parser.add_argument("--action-limit", type=int, default=40, help="Number of actions to display in Markdown.")
    parser.add_argument("--output", help="Write Markdown domain backlog.")
    parser.add_argument("--json-output", help="Write machine-readable domain backlog.")
    parser.add_argument("--csv-output", help="Write domain backlog CSV.")
    args = parser.parse_args()
    if args.action_limit <= 0:
        parser.error("--action-limit must be greater than 0")

    catalog_path = Path(args.scenario_catalog)
    next_actions_path = Path(args.next_actions)
    payload = build_backlog(read_json(catalog_path), read_json(next_actions_path))
    markdown = build_markdown(catalog_path, next_actions_path, payload, args.action_limit)

    if args.output:
        Path(args.output).write_text(markdown)
    else:
        print(markdown)
    if args.json_output:
        Path(args.json_output).write_text(json.dumps(payload, indent=2, sort_keys=True))
    if args.csv_output:
        write_csv(Path(args.csv_output), payload)
    return 1 if payload["summary"]["globalBlockerCount"] > 0 or payload["summary"]["priorityCounts"]["P1"] > 0 else 0


if __name__ == "__main__":
    raise SystemExit(main())
