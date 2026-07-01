#!/usr/bin/env python3
from __future__ import annotations

import argparse
import time
import json
import shlex
from pathlib import Path
from typing import Any


PRIORITY_RANK = {"P0": 0, "P1": 1, "P2": 2, "P3": 3, "P4": 4}
TIER_RANK = {
    "smoke": 0,
    "custom": 1,
    "online": 1,
    "multi-device": 1,
    "pair-delivery": 1,
    "large-group": 1,
    "baseline": 2,
    "capacity": 3,
}


def read_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text())
    except Exception as exc:
        raise SystemExit(f"Failed to read JSON {path}: {exc}") from exc


def shell_assign(name: str, value: str) -> str:
    return f"{name}={shlex.quote(value)}"


def shell_secret_assign(name: str, value: str) -> str:
    if not value:
        return ""
    return f"{name}=${{{name}:?set-{name}}}"


def scenario_tier(name: str) -> str:
    if name.endswith("-smoke"):
        return "smoke"
    if name.endswith("-baseline"):
        return "baseline"
    if name.endswith("-capacity"):
        return "capacity"
    if name.startswith("online-idle-"):
        return "online"
    if name.startswith("multi-device-"):
        return "multi-device"
    if name.startswith("pair-delivery-"):
        return "pair-delivery"
    if name.startswith("large-group-"):
        return "large-group"
    return "custom"


def scenario_load_rank(name: str) -> tuple[int, int, str]:
    if name.startswith("online-idle-"):
        try:
            return int(name.removeprefix("online-idle-")), 0, name
        except ValueError:
            return 999_999, 0, name
    if name.startswith("multi-device-online-"):
        raw = name.removeprefix("multi-device-online-")
        try:
            users, devices = raw.split("x", 1)
            return int(users) * int(devices), 0, name
        except ValueError:
            return 999_999, 0, name
    if name.startswith("multi-device-delivery-"):
        raw = name.removeprefix("multi-device-delivery-")
        try:
            users, devices, rate = raw.split("-", 2)
            return int(users.split("x", 1)[0]) * int(devices), int(rate), name
        except ValueError:
            return 999_999, 999_999, name
    if name.startswith("pair-delivery-"):
        raw = name.removeprefix("pair-delivery-")
        try:
            connections, rate = raw.split("-", 1)
            return int(connections), int(rate), name
        except ValueError:
            return 999_999, 999_999, name
    if name.startswith("large-group-"):
        raw = name.removeprefix("large-group-")
        try:
            users, rate = raw.split("-", 1)
            return int(users), int(rate), name
        except ValueError:
            return 999_999, 999_999, name
    return 0, 0, name


def selectable_action(action: dict[str, Any], include_p3: bool, include_capacity: bool, include_auth_confirm: bool) -> bool:
    priority = str(action.get("priority") or "")
    action_type = str(action.get("actionType") or "")
    scenario = str(action.get("scenario") or "")
    if action_type == "entrypoint-blocker":
        return False
    if priority not in {"P1", "P2", "P3"}:
        return False
    if priority == "P3" and not include_p3:
        return False
    if scenario_tier(scenario) == "capacity" and not include_capacity:
        return False
    if scenario.startswith("account-lifecycle-confirm-") and not include_auth_confirm:
        return False
    return bool(scenario)


def sorted_actions(actions: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted(
        actions,
        key=lambda action: (
            PRIORITY_RANK.get(str(action.get("priority") or ""), 9),
            TIER_RANK.get(scenario_tier(str(action.get("scenario") or "")), 9),
            scenario_load_rank(str(action.get("scenario") or "")),
        ),
    )


def build_probe_command(base_url: str, account_file: str) -> str:
    parts: list[str] = []
    if base_url:
        parts.append(shell_assign("BASE_URL", base_url))
    if account_file:
        parts.append(shell_assign("ACCOUNT_FILE", account_file))
    parts.extend(["PROBE_FAIL_ON_ENTRYPOINT_ERROR=true", "./http_entrypoint_probe.sh"])
    return " ".join(parts)


def build_run_command(args: argparse.Namespace, domain: str, scenarios: list[str]) -> str:
    run_id = args.run_id_prefix
    if run_id:
        run_id = f"{run_id}-{domain}"
    else:
        run_id = f"domain-{domain}"
    parts = [
        shell_assign("RUN_ID", run_id),
        shell_assign("SCENARIOS", " ".join(scenarios)),
    ]
    for name, value in [
        ("BASE_URL", args.base_url),
        ("TCP_HOST", args.tcp_host),
        ("TCP_PORT", args.tcp_port),
        ("ACCOUNT_FILE", args.account_file),
        ("IM_CONVERSATION_ID", args.conversation_id),
    ]:
        if value:
            parts.append(shell_assign(name, value))
    if args.internal_secret:
        parts.append(shell_secret_assign("IM_INTERNAL_SECRET", args.internal_secret))
    parts.extend([
        "PERF_PREFLIGHT=true",
        "PERF_GLOBAL_STATUS=true",
        "./run_perf_scenarios.sh",
    ])
    return " ".join(parts)


def blocker_target_mismatch(blocker: dict[str, Any], args: argparse.Namespace) -> str:
    latest_base_url = str(blocker.get("latestBaseURL") or "")
    latest_tcp_host = str(blocker.get("latestTCPHost") or "")
    latest_tcp_port = str(blocker.get("latestTCPPort") or "")
    if latest_base_url and args.base_url and latest_base_url != args.base_url:
        return f"latestBaseURL={latest_base_url} plannedBaseURL={args.base_url}"
    if latest_tcp_host and args.tcp_host and latest_tcp_host != args.tcp_host:
        return f"latestTCPHost={latest_tcp_host} plannedTCPHost={args.tcp_host}"
    if latest_tcp_port and args.tcp_port and latest_tcp_port != args.tcp_port:
        return f"latestTCPPort={latest_tcp_port} plannedTCPPort={args.tcp_port}"
    return ""


def active_global_blockers(
    blockers: list[dict[str, Any]],
    args: argparse.Namespace,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    now = time.time()
    active: list[dict[str, Any]] = []
    stale: list[dict[str, Any]] = []
    for blocker in blockers:
        latest_mtime = float(blocker.get("latestMtime") or 0)
        age_seconds = None if latest_mtime <= 0 else max(0, int(now - latest_mtime))
        enriched = dict(blocker)
        enriched["latestAgeSeconds"] = age_seconds
        target_reason = blocker_target_mismatch(blocker, args) if args.ignore_blockers_for_different_target else ""
        if target_reason:
            enriched["staleReason"] = f"latest entrypoint blocker target differs from current plan: {target_reason}"
            stale.append(enriched)
        elif (
            args.blocker_max_age_seconds > 0
            and latest_mtime > 0
            and age_seconds is not None
            and age_seconds > args.blocker_max_age_seconds
        ):
            enriched["staleReason"] = f"latest entrypoint blocker is older than {args.blocker_max_age_seconds}s"
            stale.append(enriched)
        else:
            active.append(enriched)
    return active, stale


def wanted_domain(domain: str, selected_domains: set[str]) -> bool:
    return not selected_domains or domain in selected_domains


def build_plan(args: argparse.Namespace, backlog: dict[str, Any]) -> dict[str, Any]:
    all_global_blockers = list(backlog.get("globalBlockers") or [])
    global_blockers, stale_global_blockers = active_global_blockers(all_global_blockers, args)
    target = {
        "baseURL": args.base_url,
        "tcpHost": args.tcp_host,
        "tcpPort": args.tcp_port,
        "accountFile": args.account_file,
        "conversationID": args.conversation_id,
        "hasInternalSecret": bool(args.internal_secret),
    }

    if global_blockers and not args.ignore_blockers:
        return {
            "status": "BLOCKED_BY_P0",
            "reason": "Entrypoint or deployment blockers exist; do not run domain batches until they are fixed.",
            "target": target,
            "probeCommand": build_probe_command(args.base_url, args.account_file),
            "domainPlans": [],
            "globalBlockers": global_blockers,
            "staleGlobalBlockers": stale_global_blockers,
            "blockerMaxAgeSeconds": args.blocker_max_age_seconds,
            "ignoreBlockersForDifferentTarget": bool(args.ignore_blockers_for_different_target),
        }

    selected_domains = set(args.domain or [])
    domain_plans: list[dict[str, Any]] = []
    for domain_row in backlog.get("domains") or []:
        domain = str(domain_row.get("domain") or "")
        if domain == "preflight" or not wanted_domain(domain, selected_domains):
            continue
        actions = [
            action for action in sorted_actions(list(domain_row.get("actions") or []))
            if selectable_action(
                action,
                include_p3=args.include_p3,
                include_capacity=args.include_capacity,
                include_auth_confirm=args.include_auth_confirm,
            )
        ]
        actions = actions[: args.max_scenarios_per_domain]
        scenarios = [str(action.get("scenario") or "") for action in actions if action.get("scenario")]
        if not scenarios:
            continue
        domain_plans.append({
            "domain": domain,
            "topPriority": str(domain_row.get("topPriority") or ""),
            "hint": str(domain_row.get("hint") or ""),
            "selectedScenarios": scenarios,
            "selectedActions": actions,
            "runCommand": build_run_command(args, domain, scenarios),
        })
        if len(domain_plans) >= args.max_domains:
            break

    return {
        "status": "READY" if domain_plans else "NO_SCENARIOS",
        "reason": "Run one domain batch at a time, then refresh scenario-status, next-actions, catalog, and domain-backlog.",
        "target": target,
        "probeCommand": build_probe_command(args.base_url, args.account_file),
        "domainPlans": domain_plans,
        "globalBlockers": global_blockers,
        "staleGlobalBlockers": stale_global_blockers,
        "blockerMaxAgeSeconds": args.blocker_max_age_seconds,
        "ignoreBlockersForDifferentTarget": bool(args.ignore_blockers_for_different_target),
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


def build_markdown(plan: dict[str, Any], backlog_path: Path) -> str:
    target = plan.get("target") or {}
    lines = [
        "# Performance Domain Run Plan",
        "",
        f"- domainBacklog: `{backlog_path}`",
        f"- status: `{plan['status']}`",
        f"- reason: {plan['reason']}",
        f"- baseURL: `{target.get('baseURL') or '-'}`",
        f"- tcpHost: `{target.get('tcpHost') or '-'}`",
        f"- accountFile: `{target.get('accountFile') or '-'}`",
        "",
        "## Preflight",
        "",
        "```bash",
        str(plan.get("probeCommand") or ""),
        "```",
        "",
    ]

    blockers = plan.get("globalBlockers") or []
    if blockers:
        rows = [["Priority", "Scenario", "Category", "Action"]]
        for item in blockers:
            rows.append([
                str(item.get("priority") or ""),
                f"`{item.get('scenario') or ''}`",
                f"`{item.get('category') or ''}`",
                str(item.get("action") or item.get("reason") or "")[:180],
            ])
        lines.extend(["## Global Blockers", "", markdown_table(rows), ""])

    stale_blockers = plan.get("staleGlobalBlockers") or []
    if stale_blockers:
        rows = [["Priority", "Scenario", "Latest Run", "Age Seconds", "Reason"]]
        for item in stale_blockers:
            rows.append([
                str(item.get("priority") or ""),
                f"`{item.get('scenario') or ''}`",
                f"`{item.get('latestRunID') or ''}`",
                str(item.get("latestAgeSeconds") if item.get("latestAgeSeconds") is not None else "-"),
                str(item.get("staleReason") or ""),
            ])
        lines.extend(["## Stale Global Blockers Ignored", "", markdown_table(rows), ""])

    domain_plans = plan.get("domainPlans") or []
    if not domain_plans:
        lines.extend(["## Domain Batches", "", "No domain batch selected.", ""])
        return "\n".join(lines)

    summary_rows = [["Domain", "Top", "Scenarios", "Optimization Focus"]]
    for item in domain_plans:
        summary_rows.append([
            str(item["domain"]),
            str(item["topPriority"]),
            ", ".join(f"`{scenario}`" for scenario in item["selectedScenarios"]),
            str(item.get("hint") or "")[:180],
        ])
    lines.extend(["## Domain Batches", "", markdown_table(summary_rows), ""])

    for item in domain_plans:
        lines.extend([
            f"## Run {item['domain']}",
            "",
            "```bash",
            str(item["runCommand"]),
            "```",
            "",
        ])
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate domain-scoped performance run batches from domain-backlog JSON.")
    parser.add_argument("--domain-backlog", required=True, help="Path to perf_domain_backlog.py JSON output.")
    parser.add_argument("--domain", action="append", help="Only plan this domain. May be repeated.")
    parser.add_argument("--max-domains", type=int, default=3)
    parser.add_argument("--max-scenarios-per-domain", type=int, default=5)
    parser.add_argument("--include-p3", action="store_true", help="Include never-run baseline/capacity P3 scenarios.")
    parser.add_argument("--include-capacity", action="store_true", help="Allow capacity scenarios in selected batches.")
    parser.add_argument("--include-auth-confirm", action="store_true", help="Allow account lifecycle confirm scenarios that require an auth email code source.")
    parser.add_argument("--ignore-blockers", action="store_true", help="Generate domain batches even when P0 blockers exist.")
    parser.add_argument("--blocker-max-age-seconds", type=int, default=0, help="Ignore P0 entrypoint blockers older than this age. Default 0 keeps all blockers active.")
    parser.add_argument("--ignore-blockers-for-different-target", action="store_true", help="Ignore P0 entrypoint blockers whose recorded target differs from the planned target. Ignored blockers remain in staleGlobalBlockers.")
    parser.add_argument("--run-id-prefix", default="planned-domain")
    parser.add_argument("--base-url", default="")
    parser.add_argument("--tcp-host", default="")
    parser.add_argument("--tcp-port", default="")
    parser.add_argument("--account-file", default="")
    parser.add_argument("--conversation-id", default="")
    parser.add_argument("--internal-secret", default="")
    parser.add_argument("--output")
    parser.add_argument("--json-output")
    args = parser.parse_args()
    if args.max_domains <= 0:
        parser.error("--max-domains must be greater than 0")
    if args.max_scenarios_per_domain <= 0:
        parser.error("--max-scenarios-per-domain must be greater than 0")
    if args.blocker_max_age_seconds < 0:
        parser.error("--blocker-max-age-seconds must be greater than or equal to 0")

    backlog_path = Path(args.domain_backlog)
    plan = build_plan(args, read_json(backlog_path))
    markdown = build_markdown(plan, backlog_path)
    if args.output:
        Path(args.output).write_text(markdown)
    else:
        print(markdown)
    if args.json_output:
        Path(args.json_output).write_text(json.dumps(plan, indent=2, sort_keys=True))
    return 1 if plan["status"] == "BLOCKED_BY_P0" else 0


if __name__ == "__main__":
    raise SystemExit(main())
