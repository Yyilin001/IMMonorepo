#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shlex
import tempfile
from pathlib import Path
from typing import Any


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
    return "custom"


def selectable_action(action: dict[str, Any], include_non_smoke: bool) -> bool:
    priority = str(action.get("priority") or "")
    action_type = str(action.get("actionType") or "")
    scenario = str(action.get("scenario") or "")
    if priority not in {"P1", "P2"}:
        return False
    if action_type == "entrypoint-blocker":
        return False
    tier = scenario_tier(scenario)
    return include_non_smoke or tier in {"smoke", "custom"}


def build_probe_command(base_url: str, account_file: str) -> str:
    parts = []
    if base_url:
        parts.append(shell_assign("BASE_URL", base_url))
    if account_file:
        parts.append(shell_assign("ACCOUNT_FILE", account_file))
    parts.append("PROBE_FAIL_ON_ENTRYPOINT_ERROR=true")
    parts.append("./http_entrypoint_probe.sh")
    return " ".join(parts)


def build_run_command(args: argparse.Namespace, scenarios: list[str]) -> str:
    parts = [
        shell_assign("RUN_ID", args.run_id),
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


def build_plan(args: argparse.Namespace, actions_payload: dict[str, Any]) -> dict[str, Any]:
    actions = list(actions_payload.get("actions") or [])
    blockers = [item for item in actions if item.get("priority") == "P0"]
    target = {
        "baseURL": args.base_url,
        "tcpHost": args.tcp_host,
        "tcpPort": args.tcp_port,
        "accountFile": args.account_file,
        "conversationID": args.conversation_id,
        "hasInternalSecret": bool(args.internal_secret),
    }
    if blockers and not args.ignore_blockers:
        return {
            "status": "BLOCKED_BY_P0",
            "reason": "Entrypoint or deployment blockers exist; do not run the matrix until they are fixed.",
            "target": target,
            "probeCommand": build_probe_command(args.base_url, args.account_file),
            "selectedScenarios": [],
            "runCommand": "",
            "blockers": blockers,
        }

    selected = [
        item for item in actions
        if selectable_action(item, include_non_smoke=args.include_non_smoke)
    ]
    selected = selected[: args.max_scenarios]
    scenarios = [str(item.get("scenario") or "") for item in selected if item.get("scenario")]
    return {
        "status": "READY" if scenarios else "NO_SCENARIOS",
        "reason": "Run the selected scenarios, then inspect refreshed scenario-status and next-actions.",
        "target": target,
        "probeCommand": build_probe_command(args.base_url, args.account_file),
        "selectedScenarios": scenarios,
        "runCommand": build_run_command(args, scenarios) if scenarios else "",
        "blockers": blockers,
        "selectedActions": selected,
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


def build_markdown(plan: dict[str, Any], next_actions_path: Path) -> str:
    lines = [
        "# Performance Run Plan",
        "",
        f"- nextActions: `{next_actions_path}`",
        f"- status: `{plan['status']}`",
        f"- reason: {plan['reason']}",
        f"- baseURL: `{(plan.get('target') or {}).get('baseURL') or '-'}`",
        f"- tcpHost: `{(plan.get('target') or {}).get('tcpHost') or '-'}`",
        f"- accountFile: `{(plan.get('target') or {}).get('accountFile') or '-'}`",
        "",
        "## Preflight",
        "",
        "```bash",
        str(plan.get("probeCommand") or ""),
        "```",
        "",
    ]
    blockers = plan.get("blockers") or []
    if blockers:
        rows = [["Priority", "Scenario", "Category", "Reason"]]
        for item in blockers:
            rows.append([
                str(item.get("priority") or ""),
                f"`{item.get('scenario') or ''}`",
                f"`{item.get('category') or ''}`",
                str(item.get("reason") or item.get("action") or "")[:180],
            ])
        lines.extend(["## Blockers", "", markdown_table(rows), ""])

    scenarios = plan.get("selectedScenarios") or []
    if scenarios:
        rows = [["Scenario"]]
        rows.extend([[f"`{item}`"] for item in scenarios])
        lines.extend([
            "## Selected Scenarios",
            "",
            markdown_table(rows),
            "",
            "## Run Command",
            "",
            "```bash",
            str(plan.get("runCommand") or ""),
            "```",
            "",
        ])
    else:
        lines.extend(["## Run Command", "", "No matrix command selected.", ""])
    return "\n".join(lines)


def verify_plan(plan: dict[str, Any]) -> None:
    if not isinstance(plan, dict):
        raise SystemExit("run_plan_verify result=fail reason=plan_not_object")
    status = str(plan.get("status") or "")
    if status not in {"BLOCKED_BY_P0", "READY", "NO_SCENARIOS"}:
        raise SystemExit(f"run_plan_verify result=fail reason=invalid_status status={status or '-'}")
    target = plan.get("target")
    if not isinstance(target, dict):
        raise SystemExit("run_plan_verify result=fail reason=target_not_object")
    if not isinstance(target.get("hasInternalSecret"), bool):
        raise SystemExit("run_plan_verify result=fail reason=has_internal_secret_not_bool")
    blockers = plan.get("blockers")
    if not isinstance(blockers, list):
        raise SystemExit("run_plan_verify result=fail reason=blockers_not_list")
    selected_scenarios = plan.get("selectedScenarios")
    if not isinstance(selected_scenarios, list):
        raise SystemExit("run_plan_verify result=fail reason=selected_scenarios_not_list")
    if len(selected_scenarios) != len(set(str(item) for item in selected_scenarios)):
        raise SystemExit("run_plan_verify result=fail reason=duplicate_selected_scenario")
    run_command = str(plan.get("runCommand") or "")
    probe_command = str(plan.get("probeCommand") or "")
    if not probe_command:
        raise SystemExit("run_plan_verify result=fail reason=probe_command_missing")
    if status == "BLOCKED_BY_P0":
        if not blockers:
            raise SystemExit("run_plan_verify result=fail reason=blocked_without_blockers")
        if selected_scenarios or run_command:
            raise SystemExit("run_plan_verify result=fail reason=blocked_has_matrix_command")
    if status == "READY":
        if not selected_scenarios or not run_command:
            raise SystemExit("run_plan_verify result=fail reason=ready_without_run_command")
        for scenario in selected_scenarios:
            if str(scenario) not in run_command:
                raise SystemExit(f"run_plan_verify result=fail reason=scenario_missing_from_command scenario={scenario}")
    if status == "NO_SCENARIOS":
        if selected_scenarios or run_command:
            raise SystemExit("run_plan_verify result=fail reason=no_scenarios_has_command")
    if target.get("hasInternalSecret") and run_command:
        if "IM_INTERNAL_SECRET=${IM_INTERNAL_SECRET:?set-IM_INTERNAL_SECRET}" not in run_command:
            raise SystemExit("run_plan_verify result=fail reason=secret_env_reference_missing")
        forbidden = str(target.get("internalSecret") or "")
        if forbidden and forbidden in run_command:
            raise SystemExit("run_plan_verify result=fail reason=secret_plaintext_leak")


def verify_markdown(expected_markdown: str, markdown_path: Path) -> None:
    if not markdown_path.is_file():
        raise SystemExit(f"run_plan_verify result=fail reason=markdown_missing path={markdown_path}")
    actual = markdown_path.read_text(encoding="utf-8")
    if actual != expected_markdown:
        raise SystemExit(f"run_plan_verify result=fail reason=markdown_mismatch path={markdown_path}")


def self_test_args(**overrides: Any) -> argparse.Namespace:
    values = {
        "ignore_blockers": False,
        "include_non_smoke": False,
        "max_scenarios": 10,
        "run_id": "self-test-run",
        "base_url": "https://prod.example.com",
        "tcp_host": "tcp.prod.example.com",
        "tcp_port": "9000",
        "account_file": "accounts.csv",
        "conversation_id": "conv-1",
        "internal_secret": "",
    }
    values.update(overrides)
    return argparse.Namespace(**values)


def expect_system_exit(label: str, fn: Any) -> None:
    try:
        fn()
    except SystemExit:
        print(label)
        return
    raise SystemExit(f"run_plan_self_test result=fail reason={label}_not_rejected")


def run_self_test() -> None:
    payload = {
        "actions": [
            {"priority": "P0", "actionType": "entrypoint-blocker", "scenario": "entrypoint-probe", "category": "preflight", "reason": "gateway down"},
            {"priority": "P1", "actionType": "run-scenario", "scenario": "login-smoke", "category": "http-auth"},
            {"priority": "P2", "actionType": "run-scenario", "scenario": "sync-baseline", "category": "http-sync"},
            {"priority": "P3", "actionType": "run-scenario", "scenario": "large-group-capacity", "category": "tcp-large-group"},
        ]
    }
    blocked = build_plan(self_test_args(), payload)
    verify_plan(blocked)
    if blocked["status"] != "BLOCKED_BY_P0" or blocked["runCommand"]:
        raise SystemExit("run_plan_self_test result=fail reason=blocked_plan")
    verify_plan(build_plan(self_test_args(internal_secret="blocked-secret"), payload))
    print("self_test_p0_blocks_matrix")

    ready = build_plan(self_test_args(ignore_blockers=True, internal_secret="super-secret"), payload)
    verify_plan(ready)
    if ready["status"] != "READY" or ready["selectedScenarios"] != ["login-smoke"]:
        raise SystemExit("run_plan_self_test result=fail reason=smoke_selection")
    if "super-secret" in ready["runCommand"]:
        raise SystemExit("run_plan_self_test result=fail reason=secret_plaintext")
    print("self_test_smoke_selection_ready")
    print("self_test_secret_redacted")

    non_smoke = build_plan(self_test_args(ignore_blockers=True, include_non_smoke=True, max_scenarios=2), payload)
    verify_plan(non_smoke)
    if non_smoke["selectedScenarios"] != ["login-smoke", "sync-baseline"]:
        raise SystemExit("run_plan_self_test result=fail reason=non_smoke_selection")
    print("self_test_include_non_smoke_selection")

    no_scenarios = build_plan(self_test_args(), {"actions": [{"priority": "P3", "scenario": "ignored-smoke"}]})
    verify_plan(no_scenarios)
    if no_scenarios["status"] != "NO_SCENARIOS":
        raise SystemExit("run_plan_self_test result=fail reason=no_scenarios")
    print("self_test_no_scenarios")

    with tempfile.TemporaryDirectory(prefix="run-plan-self-test-") as tmp:
        markdown_path = Path(tmp) / "run-plan.md"
        markdown = build_markdown(ready, Path("next-actions.json"))
        markdown_path.write_text(markdown + "\nextra drift\n", encoding="utf-8")
        expect_system_exit("self_test_markdown_mismatch_rejected", lambda: verify_markdown(markdown, markdown_path))

    bad_plan = dict(ready)
    bad_plan["selectedScenarios"] = [*ready["selectedScenarios"], ready["selectedScenarios"][0]]
    expect_system_exit("self_test_duplicate_selection_rejected", lambda: verify_plan(bad_plan))

    print("run_plan_self_test result=pass")


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate the next safe performance run command from next-actions JSON.")
    parser.add_argument("--next-actions", help="Path to perf_next_actions.py JSON output.")
    parser.add_argument("--max-scenarios", type=int, default=10)
    parser.add_argument("--include-non-smoke", action="store_true", help="Allow baseline/capacity P2 actions in the selected matrix batch.")
    parser.add_argument("--ignore-blockers", action="store_true", help="Generate a matrix command even when P0 actions exist.")
    parser.add_argument("--run-id", default="planned-run")
    parser.add_argument("--base-url", default="")
    parser.add_argument("--tcp-host", default="")
    parser.add_argument("--tcp-port", default="")
    parser.add_argument("--account-file", default="")
    parser.add_argument("--conversation-id", default="")
    parser.add_argument("--internal-secret", default="")
    parser.add_argument("--output")
    parser.add_argument("--json-output")
    parser.add_argument("--self-test", action="store_true", help="Run internal run-plan verifier fixtures.")
    args = parser.parse_args()

    if args.self_test:
        run_self_test()
        return 0

    if not args.next_actions:
        parser.error("--next-actions is required unless --self-test is used")

    if args.max_scenarios <= 0:
        parser.error("--max-scenarios must be greater than 0")

    next_actions_path = Path(args.next_actions)
    payload = read_json(next_actions_path)
    plan = build_plan(args, payload)
    verify_plan(plan)
    markdown = build_markdown(plan, next_actions_path)
    if args.output:
        Path(args.output).write_text(markdown, encoding="utf-8")
        verify_markdown(markdown, Path(args.output))
    else:
        print(markdown)
    if args.json_output:
        Path(args.json_output).write_text(json.dumps(plan, indent=2, sort_keys=True), encoding="utf-8")
    return 1 if plan["status"] == "BLOCKED_BY_P0" else 0


if __name__ == "__main__":
    raise SystemExit(main())
