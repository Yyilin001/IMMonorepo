#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Any

from perf_production_next_step import (
    build_current_production_readiness_command,
    build_production_acceptance_command,
    build_production_profile_command,
    failed_production_gate_scenario_names,
)


DOMAIN_CODE_AREAS = {
    "preflight": [
        "deploy/ubuntu/75_entrypoint_diagnose.sh",
        "deploy/ubuntu/nginx/imserver.conf",
        "deploy/ubuntu/70_status.sh",
        "IMServer/LoadTests/http_entrypoint_probe.sh",
    ],
    "auth-session": [
        "IMServer/Sources/IMServer/Auth",
        "IMServer/LoadTests/k6/http-auth-login.js",
        "IMServer/LoadTests/k6/http-auth-session-device.js",
        "IMServer/LoadTests/k6/http-auth-session-management.js",
        "IMServer/LoadTests/k6/http-auth-token-rotation.js",
        "IMServer/LoadTests/k6/http-auth-failure-recovery.js",
        "IMServer/LoadTests/k6/http-push-token-lifecycle.js",
    ],
    "client-sync": [
        "IMServer/Sources/IMServer/Conversation",
        "IMServer/LoadTests/k6/http-client-sync-mix.js",
        "IMServer/LoadTests/k6/http-user-journey-mix.js",
        "IMServer/LoadTests/k6/http-mixed-workload.js",
        "IMServer/LoadTests/k6/http-offline-catchup.js",
        "IMServer/LoadTests/k6/http-inbox-fanout-sync.js",
        "IMServer/LoadTests/k6/http-multi-device-sync.js",
        "IMServer/LoadTests/k6/http-cold-start-sync.js",
        "IMServer/LoadTests/k6/http-domain-events-sync.js",
        "IMServer/LoadTests/k6/http-timeline-history-scroll.js",
    ],
    "message-workflow": [
        "IMServer/Sources/IMServer/Conversation",
        "IMServer/LoadTests/k6/http-message-convergence.js",
        "IMServer/LoadTests/k6/http-direct-message-lifecycle.js",
        "IMServer/LoadTests/k6/http-conversation-governance-sync.js",
        "IMServer/LoadTests/k6/http-conversation-preferences-sync.js",
        "IMServer/LoadTests/k6/http-conversation-visibility-sync.js",
        "IMServer/LoadTests/k6/http-read-state-sync.js",
    ],
    "group-lifecycle": [
        "IMServer/Sources/IMServer/Conversation",
        "IMServer/LoadTests/k6/http-group-admin-sync.js",
        "IMServer/LoadTests/k6/http-group-membership-lifecycle.js",
        "IMServer/LoadTests/k6/http-group-invite-sync.js",
    ],
    "social-profile": [
        "IMServer/Sources/IMServer/User",
        "IMServer/Sources/IMServer/Contact",
        "IMServer/LoadTests/k6/http-contact-sync.js",
        "IMServer/LoadTests/k6/http-profile-sync.js",
    ],
    "safety-moderation": [
        "IMServer/Sources/IMServer/Safety",
        "IMServer/LoadTests/k6/http-safety-block-sync.js",
        "IMServer/LoadTests/k6/http-safety-block-enforcement.js",
        "IMServer/LoadTests/k6/http-access-control-enforcement.js",
        "IMServer/LoadTests/k6/http-admin-report-moderation.js",
    ],
    "media-file": [
        "IMServer/Sources/IMServer/Media",
        "IMServer/LoadTests/k6/http-media-file-sync.js",
        "IMServer/LoadTests/k6/http-media-failure-recovery.js",
    ],
    "ai-stream": [
        "IMServer/Sources/IMServer/Conversation",
        "IMServer/LoadTests/k6/http-ai-stream-sync.js",
    ],
    "tcp-realtime": [
        "IMServer/Sources/IMServer/Gateway",
        "IMServer/LoadTests/TCPDriver",
        "IMServer/LoadTests/tcp_capacity_ladder.sh",
        "IMServer/LoadTests/tcp_message_send_ladder.sh",
    ],
    "hot-large-group": [
        "IMServer/Sources/IMServer/Conversation",
        "IMServer/Sources/IMServer/Gateway",
        "IMServer/LoadTests/k6/http-hot-conversation-write.js",
        "IMServer/LoadTests/tcp_message_send_ladder.sh",
    ],
}

DOMAIN_METRICS = {
    "preflight": ["HTTP status", "response headers", "listener process", "nginx access rules", "systemd/docker state"],
    "auth-session": ["http_req_failed", "auth latency p99", "DB session query latency", "Redis/cache hit rate"],
    "client-sync": ["journey total/read/write p99", "conversation list p99", "changes p99", "domain-events p99", "timeline/since p99"],
    "message-workflow": ["send accept p99", "timeline visibility p99", "summary visibility p99", "projection lag"],
    "group-lifecycle": ["member mutation p99", "member list p99", "cache invalidation count", "changes propagation lag"],
    "social-profile": ["contact changes p99", "profile propagation p99", "request transition errors"],
    "safety-moderation": ["block/report write p99", "admin report list p99", "internal route failure rate"],
    "media-file": ["upload p99", "download p99", "chunk complete p99", "storage IO latency"],
    "ai-stream": ["stream start p99", "snapshot p99", "cancel p99", "stream-signal relay errors"],
    "tcp-realtime": ["connection success", "auth timeout", "heartbeat p99", "delivery success", "TCP send completion p99"],
    "hot-large-group": ["ack p99", "delivery p99", "Kafka lag", "relay payload size", "owner-delivery batch latency"],
}

CATEGORY_DOMAIN = {
    "preflight": "preflight",
    "http-login": "auth-session",
    "http-account-lifecycle": "auth-session",
    "http-auth-session": "auth-session",
    "http-auth-session-management": "auth-session",
    "http-auth-token-rotation": "auth-session",
    "http-auth-failure-recovery": "auth-session",
    "http-push-token": "auth-session",
    "http-client-health": "client-sync",
    "http-client-sync-mix": "client-sync",
    "http-user-journey": "client-sync",
    "http-mixed-workload": "client-sync",
    "http-offline-catchup": "client-sync",
    "http-inbox-fanout": "client-sync",
    "http-multi-device-sync": "client-sync",
    "http-cold-start": "client-sync",
    "http-timeline-pagination": "client-sync",
    "http-timeline-history-scroll": "client-sync",
    "http-domain-events": "client-sync",
    "http-read-state": "message-workflow",
    "http-direct-message-lifecycle": "message-workflow",
    "http-search-sync": "message-workflow",
    "http-convergence": "message-workflow",
    "http-direct-convergence": "message-workflow",
    "http-governance": "message-workflow",
    "http-conversation-preferences": "message-workflow",
    "http-conversation-visibility": "message-workflow",
    "http-message-forward": "message-workflow",
    "http-group-admin": "group-lifecycle",
    "http-group-membership": "group-lifecycle",
    "http-group-invite": "group-lifecycle",
    "http-small-group": "group-lifecycle",
    "http-contact-request": "social-profile",
    "http-contact-sync": "social-profile",
    "http-profile-sync": "social-profile",
    "http-safety-block": "safety-moderation",
    "http-safety-block-enforcement": "safety-moderation",
    "http-access-control-enforcement": "safety-moderation",
    "http-admin-report": "safety-moderation",
    "http-media-file": "media-file",
    "http-media-failure-recovery": "media-file",
    "http-ai-stream": "ai-stream",
    "http-hot-write": "hot-large-group",
    "tcp-online": "tcp-realtime",
    "tcp-reconnect": "tcp-realtime",
    "tcp-multi-device-online": "tcp-realtime",
    "tcp-multi-device-delivery": "tcp-realtime",
    "tcp-pair-delivery": "tcp-realtime",
    "tcp-large-group": "hot-large-group",
}


def read_json(path: Path | None) -> dict[str, Any]:
    if path is None:
        return {}
    try:
        return json.loads(path.read_text())
    except Exception:
        return {}


def domain_for_action(action: dict[str, Any], backlog: dict[str, Any]) -> str:
    scenario = str(action.get("scenario") or "")
    for row in backlog.get("domains") or []:
        for item in row.get("actions") or []:
            if str(item.get("scenario") or "") == scenario:
                return str(row.get("domain") or "other")
    if str(action.get("category") or "") == "preflight":
        return "preflight"
    category_domain = CATEGORY_DOMAIN.get(str(action.get("category") or ""))
    if category_domain:
        return category_domain
    return "other"


def commands_for(domain: str, action: dict[str, Any], dashboard: dict[str, Any], run_plan: dict[str, Any], domain_run_plan: dict[str, Any]) -> list[str]:
    commands: list[str] = []
    if domain == "preflight":
        command = dashboard.get("nextCommand") or run_plan.get("probeCommand") or domain_run_plan.get("probeCommand")
        if command:
            commands.append(str(command))
        commands.append("HTTP_PORT=80 PUBLIC_BASE_URL=http://<server-public-ip> bash deploy/ubuntu/75_entrypoint_diagnose.sh")
        return commands

    scenario = str(action.get("scenario") or "")
    if scenario:
        commands.append(f'SCENARIOS="{scenario}" PERF_PREFLIGHT=true ./run_perf_scenarios.sh')
    for item in domain_run_plan.get("domainPlans") or []:
        if str(item.get("domain") or "") == domain and item.get("runCommand"):
            commands.append(str(item["runCommand"]))
            break
    commands.append("python3 perf_dashboard.py --help")
    return list(dict.fromkeys(commands))


def build_work_items(args: argparse.Namespace) -> dict[str, Any]:
    dashboard = read_json(Path(args.dashboard_json) if args.dashboard_json else None)
    backlog = read_json(Path(args.domain_backlog_json) if args.domain_backlog_json else None)
    run_plan = read_json(Path(args.run_plan_json) if args.run_plan_json else None)
    domain_run_plan = read_json(Path(args.domain_run_plan_json) if args.domain_run_plan_json else None)
    prereq = read_json(Path(args.prereq_audit_json) if args.prereq_audit_json else None)
    readiness = read_json(Path(args.readiness_gate_json) if args.readiness_gate_json else None)
    slo_status = read_json(Path(args.slo_status_json) if args.slo_status_json else None)
    production_gate = read_json(Path(args.production_gate_json) if args.production_gate_json else None)

    actions: list[dict[str, Any]] = []
    for row in backlog.get("domains") or []:
        for action in row.get("actions") or []:
            actions.append(action)
    existing = {str(action.get("scenario") or "") for action in actions}
    for row in slo_status.get("scenarios") or []:
        scenario = str(row.get("scenario") or "")
        if str(row.get("latestSLOStatus") or "") != "FAIL" or not scenario or scenario in existing:
            continue
        actions.append({
            "priority": "P1",
            "category": str(row.get("category") or ""),
            "scenario": scenario,
            "actionType": "slo-violation",
            "reason": str(row.get("latestReason") or "latest SLO status is FAIL"),
            "action": str(row.get("latestAction") or "Optimize this scenario until SLO status is PASS, then rerun the same scenario."),
        })
        existing.add(scenario)
    for row in production_gate.get("requiredScenarios") or []:
        scenario = str(row.get("scenario") or "")
        if bool(row.get("passed")) or not scenario or scenario in existing:
            continue
        latest_status = str(row.get("latestSLOStatus") or "")
        priority = "P1" if latest_status == "FAIL" else "P2"
        actions.append({
            "priority": priority,
            "category": str(row.get("category") or "production-gate"),
            "scenario": scenario,
            "actionType": "production-gate-required",
            "reason": str(row.get("reason") or f"production gate requires latest SLO PASS, current={latest_status or 'UNKNOWN'}"),
            "action": f'Run or fix required production scenario `{scenario}` until production gate profile `{production_gate.get("profile")}` passes.',
        })
        existing.add(scenario)
    rank = {"P0": 0, "P1": 1, "P2": 2, "P3": 3, "P4": 4}
    actions.sort(key=lambda item: (
        rank.get(str(item.get("priority") or ""), 9),
        str(item.get("category") or ""),
        str(item.get("scenario") or ""),
    ))

    work_items: list[dict[str, Any]] = []
    production_gate_failed = failed_production_gate_scenario_names(production_gate)
    current_readiness_command = build_current_production_readiness_command(args, run_plan)
    production_profile_command = build_production_profile_command(args, production_gate, run_plan)
    production_acceptance_command = build_production_acceptance_command(args, production_gate, run_plan)
    if str(production_gate.get("status") or "") == "FAIL" and production_gate_failed:
        profile = str(production_gate.get("profile") or "")
        failure_kinds = (production_gate.get("summary") or {}).get("failureKindCounts") or {}
        failure_text = ", ".join(f"{key}={value}" for key, value in sorted(failure_kinds.items())) or "missing production evidence"
        work_items.append({
            "id": "W001",
            "priority": "P1",
            "domain": "production-gate",
            "scenario": profile,
            "actionType": "production-profile-evidence",
            "objective": "Collect fresh PASS evidence for the selected production profile before optimizing lower-priority scenarios.",
            "currentAction": f"Run production profile `{profile}` until production gate passes.",
            "reason": f"production gate failed: {failure_text}",
            "codeAreas": [
                "IMServer/LoadTests/run_production_profile.sh",
                "IMServer/LoadTests/perf_production_gate.py",
                "IMServer/LoadTests/package_production_evidence.sh",
            ],
            "metrics": [
                "production gate required/passed/failed",
                "latest SLO status per required scenario",
                "evidence age",
                "run artifact verification",
            ],
            "commands": [
                command
                for command in [
                    production_profile_command,
                    current_readiness_command,
                    production_acceptance_command,
                    "python3 perf_dashboard.py --help",
                ]
                if command
            ],
            "requiredScenarios": production_gate_failed,
        })

    remaining_limit = max(0, args.limit - len(work_items))
    for action in actions[:remaining_limit]:
        item_index = len(work_items) + 1
        domain = domain_for_action(action, backlog)
        priority = str(action.get("priority") or "")
        action_type = str(action.get("actionType") or "")
        scenario = str(action.get("scenario") or "")
        if priority == "P0":
            objective = "Restore the HTTP entrypoint before any runtime performance conclusions."
        elif priority == "P1":
            objective = "Optimize the failing scenario path and rerun the same scenario."
        elif priority == "P2":
            objective = "Collect real runtime evidence for this scenario or fix missing artifacts."
        else:
            objective = "Expand evidence beyond smoke by running baseline/capacity scenarios."

        work_items.append({
            "id": f"W{item_index:03d}",
            "priority": priority,
            "domain": domain,
            "scenario": scenario,
            "actionType": action_type,
            "objective": objective,
            "currentAction": str(action.get("action") or ""),
            "reason": str(action.get("reason") or ""),
            "codeAreas": DOMAIN_CODE_AREAS.get(domain, []),
            "metrics": DOMAIN_METRICS.get(domain, []),
            "commands": commands_for(domain, action, dashboard, run_plan, domain_run_plan),
        })

    return {
        "summary": {
            "itemCount": len(work_items),
            "readinessGate": (readiness or {}).get("status"),
            "prereqStatus": ((prereq or {}).get("summary") or {}).get("overallStatus"),
            "dashboardReadiness": ((dashboard or {}).get("summary") or {}).get("readinessGate"),
            "globalBlockerCount": ((backlog or {}).get("summary") or {}).get("globalBlockerCount"),
            "productionEvidenceActionCommands": [
                role
                for role, command in [
                    ("production-profile", production_profile_command),
                    ("current-production-readiness", current_readiness_command),
                    ("production-acceptance", production_acceptance_command),
                ]
                if command
            ],
        },
        "workItems": work_items,
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


def build_markdown(payload: dict[str, Any]) -> str:
    summary = payload["summary"]
    rows = [["ID", "Priority", "Domain", "Scenario", "Objective"]]
    for item in payload["workItems"]:
        rows.append([
            item["id"],
            item["priority"],
            item["domain"],
            f"`{item['scenario']}`",
            item["objective"],
        ])

    lines = [
        "# Performance Optimization Playbook",
        "",
        f"- work items: `{summary['itemCount']}`",
        f"- readiness gate: `{summary.get('readinessGate')}`",
        f"- prereq status: `{summary.get('prereqStatus')}`",
        f"- global blockers: `{summary.get('globalBlockerCount')}`",
        "",
        "## Queue",
        "",
        markdown_table(rows) if len(rows) > 1 else "No open work items.",
        "",
    ]

    for item in payload["workItems"]:
        lines.extend([
            f"## {item['id']} {item['domain']} {item['scenario']}",
            "",
            f"- priority: `{item['priority']}`",
            f"- type: `{item['actionType']}`",
            f"- objective: {item['objective']}",
            f"- reason: {item['reason'] or '-'}",
            f"- current action: {item['currentAction'] or '-'}",
            "",
            "Code areas:",
            "",
        ])
        for path in item["codeAreas"]:
            lines.append(f"- `{path}`")
        if not item["codeAreas"]:
            lines.append("- Add a domain mapping when this becomes a recurring target.")
        lines.extend(["", "Metrics to inspect:", ""])
        for metric in item["metrics"]:
            lines.append(f"- {metric}")
        if not item["metrics"]:
            lines.append("- Raw report reasons and service logs.")
        required_scenarios = item.get("requiredScenarios") or []
        if required_scenarios:
            lines.extend(["", "Required scenarios:", ""])
            for scenario in required_scenarios:
                lines.append(f"- `{scenario}`")
        lines.extend(["", "Commands:", ""])
        for command in item["commands"]:
            lines.extend(["```bash", command, "```", ""])
    return "\n".join(lines)


def write_csv(path: Path, items: list[dict[str, Any]]) -> None:
    fieldnames = ["id", "priority", "domain", "scenario", "actionType", "objective", "reason", "currentAction", "codeAreas", "metrics", "commands"]
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for item in items:
            writer.writerow({
                **{key: item.get(key) for key in fieldnames if key not in {"codeAreas", "metrics", "commands"}},
                "codeAreas": ",".join(item.get("codeAreas") or []),
                "metrics": ",".join(item.get("metrics") or []),
                "commands": " | ".join(item.get("commands") or []),
            })


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate actionable optimization work items from performance dashboard and backlog.")
    parser.add_argument("--dashboard-json")
    parser.add_argument("--domain-backlog-json", required=True)
    parser.add_argument("--run-plan-json")
    parser.add_argument("--domain-run-plan-json")
    parser.add_argument("--prereq-audit-json")
    parser.add_argument("--readiness-gate-json")
    parser.add_argument("--slo-status-json")
    parser.add_argument("--production-gate-json")
    parser.add_argument("--base-url")
    parser.add_argument("--tcp-host")
    parser.add_argument("--tcp-port")
    parser.add_argument("--account-file")
    parser.add_argument("--conversation-id")
    parser.add_argument("--require-internal-secret", action="store_true")
    parser.add_argument("--limit", type=int, default=12)
    parser.add_argument("--output")
    parser.add_argument("--json-output")
    parser.add_argument("--csv-output")
    args = parser.parse_args()
    if args.limit <= 0:
        parser.error("--limit must be greater than 0")

    payload = build_work_items(args)
    markdown = build_markdown(payload)
    if args.output:
        Path(args.output).write_text(markdown)
    else:
        print(markdown)
    if args.json_output:
        Path(args.json_output).write_text(json.dumps(payload, indent=2, sort_keys=True))
    if args.csv_output:
        write_csv(Path(args.csv_output), payload["workItems"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
