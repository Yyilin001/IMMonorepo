#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shlex
from pathlib import Path
from typing import Any

from perf_scenario_catalog import domain_for


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
    for prefix in ("online-idle-",):
        if name.startswith(prefix):
            try:
                return int(name.removeprefix(prefix)), 0, name
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
            users_devices, rate = raw.rsplit("-", 1)
            users, devices = users_devices.split("x", 1)
            return int(users) * int(devices), int(rate), name
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


def build_probe_command(base_url: str, account_file: str) -> str:
    parts: list[str] = []
    if base_url:
        parts.append(shell_assign("BASE_URL", base_url))
    if account_file:
        parts.append(shell_assign("ACCOUNT_FILE", account_file))
    parts.extend(["PROBE_FAIL_ON_ENTRYPOINT_ERROR=true", "./http_entrypoint_probe.sh"])
    return " ".join(parts)


def build_run_command(args: argparse.Namespace, domain: str, scenarios: list[str]) -> str:
    run_id = f"{args.run_id_prefix}-{domain}" if args.run_id_prefix else f"slo-domain-{domain}"
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
        "PERF_SLO=true",
        "PERF_GLOBAL_STATUS=true",
        "./run_perf_scenarios.sh",
    ])
    return " ".join(parts)


def selectable(row: dict[str, Any], include_baseline: bool, include_capacity: bool) -> bool:
    status = str(row.get("latestSLOStatus") or "")
    if status == "PASS":
        return False
    tier = scenario_tier(str(row.get("scenario") or ""))
    if tier == "capacity" and not include_capacity:
        return False
    if tier == "baseline" and not include_baseline:
        return False
    return True


def sorted_scenarios(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    status_rank = {"FAIL": 0, "UNKNOWN": 1, "NEVER_RUN": 2, "PASS": 3}
    return sorted(rows, key=lambda row: (
        status_rank.get(str(row.get("latestSLOStatus") or ""), 9),
        TIER_RANK.get(scenario_tier(str(row.get("scenario") or "")), 9),
        scenario_load_rank(str(row.get("scenario") or "")),
        str(row.get("scenario") or ""),
    ))


def grouped_matrix_scenarios(slo_status: dict[str, Any]) -> dict[str, list[dict[str, Any]]]:
    grouped: dict[str, list[dict[str, Any]]] = {}
    for row in slo_status.get("scenarios") or []:
        if not row.get("isMatrixScenario"):
            continue
        domain = domain_for(str(row.get("category") or ""), str(row.get("scenario") or ""))
        grouped.setdefault(domain, []).append(row)
    return grouped


def build_plan(args: argparse.Namespace, slo_status: dict[str, Any], scorecard: dict[str, Any]) -> dict[str, Any]:
    extra_counts = (scorecard.get("summary") or {}).get("extraSLOStatusCounts") or slo_status.get("extraSLOStatusCounts") or {}
    target = {
        "baseURL": args.base_url,
        "tcpHost": args.tcp_host,
        "tcpPort": args.tcp_port,
        "accountFile": args.account_file,
        "conversationID": args.conversation_id,
        "hasInternalSecret": bool(args.internal_secret),
    }
    probe_command = build_probe_command(args.base_url, args.account_file)
    if int(extra_counts.get("FAIL") or 0) > 0 and not args.ignore_extra_fail:
        return {
            "status": "BLOCKED_BY_EXTRA_SLO",
            "reason": "Preflight or extra SLO failures exist; fix the entrypoint before running domain batches.",
            "target": target,
            "probeCommand": probe_command,
            "domainPlans": [],
            "extraSLOStatusCounts": extra_counts,
        }

    selected_domains = set(args.domain or [])
    grouped = grouped_matrix_scenarios(slo_status)
    scorecard_domains = scorecard.get("domains") or []
    if not scorecard_domains:
        scorecard_domains = [{"domain": domain, "readiness": ""} for domain in sorted(grouped)]

    domain_plans: list[dict[str, Any]] = []
    for domain_row in scorecard_domains:
        domain = str(domain_row.get("domain") or "")
        if selected_domains and domain not in selected_domains:
            continue
        candidates = [
            row for row in sorted_scenarios(grouped.get(domain, []))
            if selectable(row, args.include_baseline, args.include_capacity)
        ]
        candidates = candidates[: args.max_scenarios_per_domain]
        scenarios = [str(row.get("scenario") or "") for row in candidates if row.get("scenario")]
        if not scenarios:
            continue
        domain_plans.append({
            "domain": domain,
            "readiness": str(domain_row.get("readiness") or ""),
            "reason": str(domain_row.get("reason") or ""),
            "selectedScenarios": scenarios,
            "selectedSLORows": candidates,
            "runCommand": build_run_command(args, domain, scenarios),
        })
        if len(domain_plans) >= args.max_domains:
            break

    return {
        "status": "READY" if domain_plans else "NO_SCENARIOS",
        "reason": "Run one SLO domain batch at a time, then refresh SLO status and domain scorecards.",
        "target": target,
        "probeCommand": probe_command,
        "domainPlans": domain_plans,
        "extraSLOStatusCounts": extra_counts,
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


def build_markdown(plan: dict[str, Any], slo_status_path: Path) -> str:
    target = plan.get("target") or {}
    extra = plan.get("extraSLOStatusCounts") or {}
    lines = [
        "# Performance SLO Domain Run Plan",
        "",
        f"- sloStatus: `{slo_status_path}`",
        f"- status: `{plan['status']}`",
        f"- reason: {plan['reason']}",
        f"- baseURL: `{target.get('baseURL') or '-'}`",
        f"- tcpHost: `{target.get('tcpHost') or '-'}`",
        f"- accountFile: `{target.get('accountFile') or '-'}`",
        f"- extra SLO FAIL/UNKNOWN/NEVER/PASS: `{extra.get('FAIL', 0)}/{extra.get('UNKNOWN', 0)}/{extra.get('NEVER_RUN', 0)}/{extra.get('PASS', 0)}`",
        "",
        "## Preflight",
        "",
        "```bash",
        str(plan.get("probeCommand") or ""),
        "```",
        "",
    ]
    domain_plans = plan.get("domainPlans") or []
    if not domain_plans:
        lines.extend(["## Domain Batches", "", "No SLO domain batch selected.", ""])
        return "\n".join(lines)

    rows = [["Domain", "Readiness", "Scenarios", "Reason"]]
    for item in domain_plans:
        rows.append([
            str(item.get("domain") or ""),
            str(item.get("readiness") or ""),
            ", ".join(f"`{scenario}`" for scenario in item.get("selectedScenarios") or []),
            str(item.get("reason") or "")[:180],
        ])
    lines.extend(["## Domain Batches", "", markdown_table(rows), ""])
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
    parser = argparse.ArgumentParser(description="Generate domain-scoped run batches from SLO status and SLO domain scorecard.")
    parser.add_argument("--slo-status-json", required=True)
    parser.add_argument("--slo-domain-scorecard-json")
    parser.add_argument("--domain", action="append", help="Only plan this domain. May be repeated.")
    parser.add_argument("--max-domains", type=int, default=3)
    parser.add_argument("--max-scenarios-per-domain", type=int, default=5)
    parser.add_argument("--include-baseline", action="store_true")
    parser.add_argument("--include-capacity", action="store_true")
    parser.add_argument("--ignore-extra-fail", action="store_true")
    parser.add_argument("--run-id-prefix", default="planned-slo-domain")
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

    slo_status_path = Path(args.slo_status_json)
    scorecard = read_json(Path(args.slo_domain_scorecard_json)) if args.slo_domain_scorecard_json else {}
    plan = build_plan(args, read_json(slo_status_path), scorecard)
    markdown = build_markdown(plan, slo_status_path)
    if args.output:
        Path(args.output).write_text(markdown)
    else:
        print(markdown)
    if args.json_output:
        Path(args.json_output).write_text(json.dumps(plan, indent=2, sort_keys=True))
    return 1 if plan["status"] == "BLOCKED_BY_EXTRA_SLO" else 0


if __name__ == "__main__":
    raise SystemExit(main())
