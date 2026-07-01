#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Any


INTERNAL_SECRET_FAMILIES = {
    "admin-report",
    "cold-start",
    "conversation-convergence",
    "direct-convergence",
    "domain-events",
    "governance",
    "hot-write",
    "message-forward",
    "read-state",
    "search-sync",
    "small-group",
    "timeline-pagination",
}

ACCOUNT_FILE_RECOMMENDED_DOMAINS = {
    "auth-session",
    "client-sync",
    "group-lifecycle",
    "message-workflow",
    "social-profile",
    "safety-moderation",
    "media-file",
    "ai-stream",
}

MULTI_ACCOUNT_FAMILIES = {
    "contact-request",
    "contact-sync",
    "group-admin",
    "group-invite",
    "group-membership",
    "message-forward",
    "profile-sync",
    "safety-block",
}


def read_json(path: Path | None) -> dict[str, Any]:
    if path is None:
        return {}
    try:
        return json.loads(path.read_text())
    except Exception as exc:
        raise SystemExit(f"Failed to read JSON {path}: {exc}") from exc


def usable_account_rows(path: str) -> int:
    if not path:
        return 0
    account_path = Path(path)
    if not account_path.exists():
        return 0
    count = 0
    for raw_line in account_path.read_text(errors="replace").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        parts = [part.strip() for part in line.split(",")]
        if len(parts) >= 2 and parts[0] and parts[1]:
            count += 1
    return count


def scenario_to_catalog(catalog: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {
        str(row.get("scenario") or ""): row
        for row in catalog.get("scenarios") or []
        if row.get("scenario")
    }


def planned_scenarios(plan: dict[str, Any]) -> set[str]:
    scenarios: set[str] = set()
    for domain_plan in plan.get("domainPlans") or []:
        for scenario in domain_plan.get("selectedScenarios") or []:
            scenarios.add(str(scenario))
    for scenario in plan.get("selectedScenarios") or []:
        scenarios.add(str(scenario))
    return scenarios


def scenario_family(name: str, catalog_row: dict[str, Any] | None = None) -> str:
    if catalog_row and catalog_row.get("family"):
        return str(catalog_row["family"])
    for suffix in ["-smoke", "-baseline", "-capacity"]:
        if name.endswith(suffix):
            return name[: -len(suffix)]
    if name.startswith("online-idle-"):
        return "online-idle"
    if name.startswith("multi-device-online-"):
        return "multi-device-online"
    if name.startswith("multi-device-delivery-"):
        return "multi-device-delivery"
    if name.startswith("pair-delivery-"):
        return "pair-delivery"
    if name.startswith("large-group-"):
        return "large-group"
    return name


def required_checks_for(name: str, row: dict[str, Any] | None) -> list[str]:
    family = scenario_family(name, row)
    checks: list[str] = []
    if name.startswith(("online-idle-", "multi-device-online-", "reconnect-soak-", "reconnect-drill-")):
        checks.append("account_file")
    if name.startswith(("multi-device-delivery-", "pair-delivery-", "group-delivery-", "large-group-", "online-chat-mix-", "direct-burst-")):
        checks.extend(["account_file", "conversation_id"])
    if family in INTERNAL_SECRET_FAMILIES:
        checks.append("internal_secret")
    if family == "account-lifecycle-confirm":
        checks.append("auth_email_code_source")
    return sorted(set(checks))


def recommended_checks_for(name: str, row: dict[str, Any] | None) -> list[str]:
    family = scenario_family(name, row)
    domain = str((row or {}).get("domain") or "")
    checks: list[str] = []
    if domain in ACCOUNT_FILE_RECOMMENDED_DOMAINS:
        checks.append("account_file")
    if family in MULTI_ACCOUNT_FAMILIES:
        checks.append("multi_account_file")
    if family in {"client-sync-mix", "hot-write", "small-group", "timeline-pagination", "domain-events", "read-state", "search-sync"}:
        checks.append("conversation_id")
    return sorted(set(checks) - set(required_checks_for(name, row)))


def check_available(check: str, args: argparse.Namespace, account_rows: int) -> tuple[bool, str]:
    if check == "account_file":
        if args.account_file and account_rows > 0:
            return True, f"ACCOUNT_FILE has {account_rows} usable rows"
        if args.account_file:
            return False, f"ACCOUNT_FILE is missing or empty: {args.account_file}"
        return False, "ACCOUNT_FILE is not set"
    if check == "multi_account_file":
        if args.account_file and account_rows >= args.min_multi_account_rows:
            return True, f"ACCOUNT_FILE has {account_rows} usable rows"
        if args.account_file:
            return False, f"ACCOUNT_FILE needs >= {args.min_multi_account_rows} usable rows; found {account_rows}"
        return False, "ACCOUNT_FILE is not set"
    if check == "conversation_id":
        return (bool(args.conversation_id), "IM_CONVERSATION_ID is set" if args.conversation_id else "IM_CONVERSATION_ID is not set")
    if check == "internal_secret":
        return (bool(args.internal_secret), "IM_INTERNAL_SECRET is set" if args.internal_secret else "IM_INTERNAL_SECRET is not set")
    if check == "auth_email_code_source":
        ok = bool(args.auth_email_webhook_url or args.verification_code or args.password_reset_code)
        detail = "auth code source is set" if ok else "Set IM_AUTH_EMAIL_WEBHOOK_SINK_URL or fixed verification/reset code envs"
        return ok, detail
    return False, f"Unknown check {check}"


def build_audit(args: argparse.Namespace, catalog: dict[str, Any], domain_plan: dict[str, Any], has_domain_plan: bool) -> dict[str, Any]:
    catalog_by_scenario = scenario_to_catalog(catalog)
    selected = planned_scenarios(domain_plan)
    if not selected and not has_domain_plan:
        selected = set(catalog_by_scenario)
    account_rows = usable_account_rows(args.account_file)

    scenario_rows: list[dict[str, Any]] = []
    missing_required_total = 0
    missing_recommended_total = 0
    for name in sorted(selected):
        row = catalog_by_scenario.get(name)
        required = required_checks_for(name, row)
        recommended = recommended_checks_for(name, row)
        missing_required: list[str] = []
        missing_recommended: list[str] = []
        details: list[str] = []
        for check in required:
            ok, detail = check_available(check, args, account_rows)
            details.append(f"{check}: {detail}")
            if not ok:
                missing_required.append(check)
        for check in recommended:
            ok, detail = check_available(check, args, account_rows)
            details.append(f"{check}: {detail}")
            if not ok:
                missing_recommended.append(check)
        missing_required_total += len(missing_required)
        missing_recommended_total += len(missing_recommended)
        status = "READY"
        if missing_required:
            status = "BLOCKED"
        elif missing_recommended:
            status = "WARN"
        scenario_rows.append({
            "scenario": name,
            "domain": str((row or {}).get("domain") or ""),
            "family": scenario_family(name, row),
            "status": status,
            "required": required,
            "recommended": recommended,
            "missingRequired": missing_required,
            "missingRecommended": missing_recommended,
            "details": details,
        })

    status_counts = {
        status: sum(1 for row in scenario_rows if row["status"] == status)
        for status in ["BLOCKED", "WARN", "READY"]
    }
    if not scenario_rows:
        overall = "NO_PLANNED_SCENARIOS"
    else:
        overall = "BLOCKED" if status_counts["BLOCKED"] else "WARN" if status_counts["WARN"] else "READY"
    return {
        "summary": {
            "overallStatus": overall,
            "scenarioCount": len(scenario_rows),
            "accountRows": account_rows,
            "missingRequiredCount": missing_required_total,
            "missingRecommendedCount": missing_recommended_total,
            "statusCounts": status_counts,
            "target": {
                "baseURL": args.base_url,
                "tcpHost": args.tcp_host,
                "tcpPort": args.tcp_port,
                "accountFile": args.account_file,
                "hasConversationID": bool(args.conversation_id),
                "hasInternalSecret": bool(args.internal_secret),
                "hasAuthEmailCodeSource": bool(args.auth_email_webhook_url or args.verification_code or args.password_reset_code),
            },
        },
        "scenarios": scenario_rows,
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


def build_markdown(catalog_path: Path, plan_path: Path | None, payload: dict[str, Any]) -> str:
    summary = payload["summary"]
    target = summary["target"]
    rows = [["Scenario", "Domain", "Status", "Missing Required", "Missing Recommended"]]
    for row in payload["scenarios"]:
        rows.append([
            f"`{row['scenario']}`",
            str(row["domain"] or "-"),
            str(row["status"]),
            ", ".join(row["missingRequired"]) or "-",
            ", ".join(row["missingRecommended"]) or "-",
        ])
    return "\n".join([
        "# Performance Prerequisite Audit",
        "",
        f"- scenarioCatalog: `{catalog_path}`",
        f"- domainRunPlan: `{plan_path or '-'}`",
        f"- overallStatus: `{summary['overallStatus']}`",
        f"- scenarios: `{summary['scenarioCount']}`",
        f"- account rows: `{summary['accountRows']}`",
        f"- missing required: `{summary['missingRequiredCount']}`",
        f"- missing recommended: `{summary['missingRecommendedCount']}`",
        f"- baseURL: `{target['baseURL'] or '-'}`",
        f"- tcpHost: `{target['tcpHost'] or '-'}`",
        f"- accountFile: `{target['accountFile'] or '-'}`",
        f"- hasConversationID: `{target['hasConversationID']}`",
        f"- hasInternalSecret: `{target['hasInternalSecret']}`",
        f"- hasAuthEmailCodeSource: `{target['hasAuthEmailCodeSource']}`",
        "",
        "## Scenarios",
        "",
        markdown_table(rows),
        "",
    ])


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=[
                "scenario",
                "domain",
                "family",
                "status",
                "required",
                "recommended",
                "missingRequired",
                "missingRecommended",
                "details",
            ],
        )
        writer.writeheader()
        for row in rows:
            writer.writerow({
                "scenario": row["scenario"],
                "domain": row["domain"],
                "family": row["family"],
                "status": row["status"],
                "required": ",".join(row["required"]),
                "recommended": ",".join(row["recommended"]),
                "missingRequired": ",".join(row["missingRequired"]),
                "missingRecommended": ",".join(row["missingRecommended"]),
                "details": " | ".join(row["details"]),
            })


def main() -> int:
    parser = argparse.ArgumentParser(description="Audit target prerequisites before running planned performance scenarios.")
    parser.add_argument("--scenario-catalog", required=True, help="Path to perf_scenario_catalog.py JSON output.")
    parser.add_argument("--domain-run-plan", help="Optional perf_domain_run_plan.py JSON output; when omitted, audit every scenario in the catalog.")
    parser.add_argument("--base-url", default="")
    parser.add_argument("--tcp-host", default="")
    parser.add_argument("--tcp-port", default="")
    parser.add_argument("--account-file", default="")
    parser.add_argument("--conversation-id", default="")
    parser.add_argument("--internal-secret", default="")
    parser.add_argument("--auth-email-webhook-url", default="")
    parser.add_argument("--verification-code", default="")
    parser.add_argument("--password-reset-code", default="")
    parser.add_argument("--min-multi-account-rows", type=int, default=4)
    parser.add_argument("--output")
    parser.add_argument("--json-output")
    parser.add_argument("--csv-output")
    parser.add_argument("--strict", action="store_true", help="Exit non-zero when required prerequisites are missing.")
    args = parser.parse_args()
    if args.min_multi_account_rows <= 0:
        parser.error("--min-multi-account-rows must be greater than 0")

    catalog_path = Path(args.scenario_catalog)
    plan_path = Path(args.domain_run_plan) if args.domain_run_plan else None
    payload = build_audit(args, read_json(catalog_path), read_json(plan_path), has_domain_plan=plan_path is not None)
    markdown = build_markdown(catalog_path, plan_path, payload)
    if args.output:
        Path(args.output).write_text(markdown)
    else:
        print(markdown)
    if args.json_output:
        Path(args.json_output).write_text(json.dumps(payload, indent=2, sort_keys=True))
    if args.csv_output:
        write_csv(Path(args.csv_output), payload["scenarios"])
    return 1 if args.strict and payload["summary"]["overallStatus"] == "BLOCKED" else 0


if __name__ == "__main__":
    raise SystemExit(main())
