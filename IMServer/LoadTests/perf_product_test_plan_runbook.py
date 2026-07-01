#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shlex
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


def read_json(path: Path | None) -> dict[str, Any]:
    if path is None or not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise SystemExit(f"Failed to read JSON {path}: {exc}") from exc


def shell_assign(name: str, value: str) -> str:
    return f"{name}={shlex.quote(value)}"


def shell_secret_assign(name: str) -> str:
    return f"{name}=${{{name}:?set-{name}}}"


def shell_flag(name: str, enabled: bool) -> str:
    return shell_assign(name, "true" if enabled else "false")


def needs_internal_secret(run: dict[str, Any]) -> bool:
    target = run.get("target") or {}
    if bool(target.get("hasInternalSecret") or run.get("hasInternalSecret")):
        return True
    for phase in run.get("phases") or []:
        command = str((phase or {}).get("command") or "")
        if "IM_INTERNAL_SECRET=" in command or "IM_INTERNAL_SHARED_SECRET=" in command:
            return True
    return bool(run.get("runFullProfile"))


def build_plan_command(args: argparse.Namespace, run: dict[str, Any]) -> str:
    target = run.get("target") or {}
    parts = [
        shell_assign("RESULT_ROOT", args.result_root),
        shell_assign("PRODUCT_TEST_PLAN", str(run.get("plan") or "non-large-group")),
        shell_assign("PRODUCT_TEST_PHASES", " ".join(str(item) for item in (run.get("requestedPhases") or []) if item)),
        shell_flag("PRODUCT_TEST_RUN_FULL_PROFILE", bool(run.get("runFullProfile"))),
        shell_assign("PRODUCT_TEST_FULL_PROFILE", str(run.get("fullProfile") or "normal-product-baseline")),
        shell_flag("PRODUCT_TEST_PREREQ_GATE", bool((run.get("prereq") or {}).get("enabled"))),
        shell_flag("PERF_STATUS_FILTER_TARGET", bool(run.get("statusFilterTarget"))),
        shell_flag("PERF_DRY_RUN", bool(run.get("dryRun"))),
    ]
    optional = [
        ("BASE_URL", target.get("baseURL") or ""),
        ("TCP_HOST", target.get("tcpHost") or ""),
        ("TCP_PORT", target.get("tcpPort") or ""),
        ("ACCOUNT_FILE", target.get("accountFile") or ""),
        ("IM_CONVERSATION_ID", target.get("conversationID") or ""),
    ]
    for name, value in optional:
        if value:
            parts.append(shell_assign(name, str(value)))
    if needs_internal_secret(run):
        parts.append(shell_secret_assign("IM_INTERNAL_SECRET"))
    parts.append("./run_product_test_plan.sh")
    return " ".join(parts)


def build_verify_command(args: argparse.Namespace, run: dict[str, Any]) -> str:
    parts = [
        "python3 perf_product_plan_artifacts_verify.py",
        "--product-run-json",
        shlex.quote(args.product_run_json),
    ]
    if bool(run.get("dryRun")):
        parts.append("--allow-dry-run")
    if (run.get("prereq") or {}).get("enabled"):
        parts.append("--require-prereq")
    return " ".join(parts)


def shell_command(parts: list[str]) -> str:
    return " ".join(parts)


def find_phase(phases: list[dict[str, Any]], phase_name: str) -> dict[str, Any]:
    for phase in phases:
        if str(phase.get("phase") or "") == phase_name:
            return phase
    return {}


def entrypoint_probe_path(run_path: Path, phase: dict[str, Any]) -> Path | None:
    run_dir = str(phase.get("runDir") or "")
    if not run_dir:
        return None
    path = Path(run_dir)
    if not path.is_absolute():
        path = run_path.parent / path
    return path / "entrypoint-probe.json"


def build_local_network_commands(public_base: str, account_file: str) -> list[dict[str, str]]:
    host = urlparse(public_base).hostname or "<server-public-ip>"
    probe_parts = [
        shell_assign("BASE_URL", public_base),
        shell_assign("PROBE_LOCAL_NETWORK_CHECK", "true"),
    ]
    if account_file:
        probe_parts.append(shell_assign("ACCOUNT_FILE", account_file))
    probe_parts.append("./http_entrypoint_probe.sh")
    return [
        {
            "name": "check-local-route",
            "when": "Run this on the workstation or load generator that produced the probe.",
            "command": shell_command([
                "route",
                "-n",
                "get",
                shlex.quote(host),
                "2>/dev/null",
                "||",
                "ip",
                "route",
                "get",
                shlex.quote(host),
            ]),
        },
        {
            "name": "rerun-entrypoint-probe-clean-network",
            "when": "After disabling local TUN/proxy or switching to a clean network path.",
            "command": shell_command(probe_parts),
        },
    ]


def build_server_repair_commands(public_base: str, include_cloud_console: bool) -> list[dict[str, str]]:
    commands = [
        {
            "name": "server-diagnose",
            "when": "SSH or cloud console shell is available on the target host.",
            "command": shell_command([
                f"PUBLIC_BASE_URL={shlex.quote(public_base)}",
                "bash deploy/ubuntu/75_entrypoint_diagnose.sh",
            ]),
        },
        {
            "name": "repair-node-access",
            "when": "The target host has the current repository checkout.",
            "command": shell_command([
                f"PUBLIC_BASE_URL={shlex.quote(public_base)}",
                "bash deploy/ubuntu/23_repair_node_access.sh",
            ]),
        },
        {
            "name": "repair-http-entrypoint-only",
            "when": "SSH works and only public HTTP/8080 is unhealthy.",
            "command": shell_command([
                f"PUBLIC_BASE_URL={shlex.quote(public_base)}",
                "bash deploy/ubuntu/64_repair_http_entrypoint.sh",
            ]),
        },
    ]
    if include_cloud_console:
        commands.append({
            "name": "render-cloud-console-rescue",
            "when": "SSH closes or the target host does not have the current checkout; paste the rendered script into the cloud console.",
            "command": shell_command([
                "SSH_AUTHORIZED_KEY='<paste-public-key>'",
                f"PUBLIC_BASE_URL={shlex.quote(public_base)}",
                "deploy/ubuntu/21_render_node_access_rescue_command.sh",
                "> /tmp/im-node-access-rescue-command.sh",
            ]),
        })
    return commands


def build_entrypoint_recovery(run_path: Path, run: dict[str, Any], phases: list[dict[str, Any]]) -> dict[str, Any]:
    entrypoint_phase = find_phase(phases, "entrypoint")
    probe_json_path = entrypoint_probe_path(run_path, entrypoint_phase)
    probe = read_json(probe_json_path) if probe_json_path is not None else {}
    diagnosis = str(probe.get("diagnosis") or "")
    failed = bool(probe.get("failed"))
    target = run.get("target") or {}
    base_url = str((probe.get("baseURL") or target.get("baseURL") or "")).rstrip("/")
    signals = probe.get("signals") or {}
    blocker = probe.get("blocker") if isinstance(probe.get("blocker"), dict) else {}
    blocker_action = str(blocker.get("action") or "")
    commands: list[dict[str, str]] = []

    if not failed and diagnosis not in {"", "ok"}:
        failed = True

    if not failed and str(entrypoint_phase.get("status") or "") != "FAIL":
        return {
            "needed": False,
            "reason": "",
            "probeJSON": str(probe_json_path or ""),
            "diagnosis": diagnosis or "not_failed",
            "detail": str(probe.get("detail") or ""),
            "blocker": blocker,
            "signals": signals,
            "commands": commands,
        }

    public_base = base_url or "http://<server-public-ip>"
    if blocker_action == "disable_local_proxy_or_test_from_clean_network":
        commands = build_local_network_commands(public_base, str(target.get("accountFile") or ""))
    elif blocker_action == "repair_entrypoint_probe":
        commands = build_local_network_commands(public_base, str(target.get("accountFile") or ""))
    else:
        commands = build_server_repair_commands(public_base, include_cloud_console=blocker_action == "cloud_console_rescue_required")

    if diagnosis == "local_network_proxy_http_403_intercept":
        reason = "The workstation or load generator route/proxy intercepted the probe; disable local TUN/proxy or rerun from a clean network before changing the server."
    elif diagnosis in {"public_listener_not_imserver_nginx", "uniform_empty_403"}:
        reason = "Public HTTP is blocked before the IM API; repair Nginx/cloud listener before any performance run."
    elif diagnosis == "network_or_timeout":
        reason = "Network path timed out or failed; verify DNS, security group, firewall, and listener binding."
    elif diagnosis == "health_unavailable":
        reason = "HTTP reaches something, but /health is not healthy; diagnose gateway/upstream routing."
    elif diagnosis == "login_forbidden":
        reason = "HTTP health may be reachable, but login is forbidden; check auth middleware, account state, and access control."
    else:
        reason = str(probe.get("detail") or entrypoint_phase.get("reason") or "Entrypoint phase failed.")

    return {
        "needed": True,
        "reason": reason,
        "probeJSON": str(probe_json_path or ""),
        "diagnosis": diagnosis or "missing_probe_json",
        "detail": str(probe.get("detail") or ""),
        "blocker": blocker,
        "signals": signals,
        "commands": commands,
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


def build_runbook(args: argparse.Namespace) -> dict[str, Any]:
    run_path = Path(args.product_run_json)
    run = read_json(run_path)
    prereq = run.get("prereq") or {}
    plan_preview = run.get("planPreview") or {}
    prereq_audit_value = args.prereq_audit_json or prereq.get("auditJSON") or ""
    prereq_audit = read_json(Path(prereq_audit_value) if prereq_audit_value else None)
    plan_preview_value = str(plan_preview.get("json") or "")
    plan_preview_path = Path(plan_preview_value) if plan_preview_value else None
    if plan_preview_path is not None and not plan_preview_path.is_absolute():
        plan_preview_path = run_path.parent / plan_preview_path
    plan_preview_payload = read_json(plan_preview_path)
    plan_preview_summary = plan_preview_payload.get("summary") or {}
    prereq_summary = prereq_audit.get("summary") or {}
    phases = list(run.get("phases") or [])
    final_status = str(run.get("finalStatus") or "UNKNOWN")
    reason = str(run.get("reason") or "")
    entrypoint_recovery = build_entrypoint_recovery(run_path, run, phases)

    if final_status == "PASS":
        status = "READY"
        summary_reason = "Product test plan phases completed; verify artifacts before using the run as evidence."
    elif reason == "entrypoint_failed":
        status = "BLOCKED"
        summary_reason = entrypoint_recovery.get("reason") or "HTTP entrypoint failed; repair exposure before running scenarios."
    elif reason == "prereq_gate_failed":
        status = "BLOCKED"
        summary_reason = "Required prerequisites are missing; fix the prereq audit before touching the target server."
    else:
        status = "FAILED"
        summary_reason = reason or "Product test plan failed; inspect phase records."

    return {
        "schemaVersion": 1,
        "status": status,
        "reason": summary_reason,
        "productRun": {
            "path": args.product_run_json,
            "finalStatus": final_status,
            "reason": reason,
            "blockerType": str(run.get("blockerType") or ""),
            "dryRun": bool(run.get("dryRun")),
            "statusFilterTarget": bool(run.get("statusFilterTarget")),
            "runIDPrefix": run.get("runIDPrefix") or "",
        },
        "plan": {
            "name": run.get("plan") or "",
            "preset": run.get("preset") or "",
            "requestedPhases": [str(item) for item in (run.get("requestedPhases") or []) if item],
            "runFullProfile": bool(run.get("runFullProfile")),
            "fullProfile": run.get("fullProfile") or "",
            "previewJSON": plan_preview_value,
            "preview": {
                "exists": bool(plan_preview.get("exists")),
                "phaseCount": int(plan_preview_summary.get("phaseCount") or 0),
                "uniqueScenarioCount": int(plan_preview_summary.get("uniqueScenarioCount") or 0),
                "largeGroupIncluded": bool(plan_preview_summary.get("largeGroupIncluded")),
                "coveredProductDomains": [
                    str(item)
                    for item in (plan_preview_summary.get("coveredProductDomains") or [])
                    if str(item)
                ],
                "requiredProductDomains": [
                    str(item)
                    for item in (plan_preview_summary.get("requiredProductDomains") or [])
                    if str(item)
                ],
                "missingProductDomains": [
                    str(item)
                    for item in (plan_preview_summary.get("missingProductDomains") or [])
                    if str(item)
                ],
                "requiredProductDomainsCovered": bool(plan_preview_summary.get("requiredProductDomainsCovered")),
            },
        },
        "target": run.get("target") or {},
        "prereq": {
            "enabled": bool(prereq.get("enabled")),
            "ran": bool(prereq.get("ran")),
            "plan": prereq.get("plan") or "",
            "auditJSON": prereq.get("auditJSON") or "",
            "auditMarkdown": prereq.get("auditMarkdown") or "",
            "status": prereq_summary.get("overallStatus") or ("NOT_RUN" if not bool(prereq.get("ran")) else "-"),
            "missingRequiredCount": int(prereq_summary.get("missingRequiredCount") or 0),
            "missingRecommendedCount": int(prereq_summary.get("missingRecommendedCount") or 0),
            "accountRows": int(prereq_summary.get("accountRows") or 0),
        },
        "entrypoint": {
            "required": bool((run.get("entrypoint") or {}).get("required")),
            "recovery": entrypoint_recovery,
        },
        "phases": [
            {
                "phase": str(row.get("phase") or ""),
                "kind": str(row.get("kind") or ""),
                "status": str(row.get("status") or ""),
                "reason": str(row.get("reason") or ""),
                "runID": str(row.get("runID") or ""),
                "runDir": str(row.get("runDir") or ""),
                "command": str(row.get("command") or ""),
            }
            for row in phases
        ],
        "commands": {
            "rerun": build_plan_command(args, run),
            "verify": build_verify_command(args, run),
        },
        "evidencePolicy": {
            "classification": "diagnostic-product-plan",
            "requiresCurrentReadiness": False,
            "finalAcceptanceCommand": "CURRENT_PRODUCTION_REQUIRE_PACKAGEABLE_EVIDENCE=true CURRENT_PRODUCTION_RUN_BASELINE=true CURRENT_PRODUCTION_RUN_SCENARIO_SUITE=true CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE=true ./run_current_production_readiness.sh",
        },
        "artifacts": {
            "productRun": args.product_run_json,
            "runbookJSON": args.json_output or "",
            "runbookMarkdown": args.output or "",
            "prereqPlan": prereq.get("plan") or "",
            "prereqAuditJSON": prereq.get("auditJSON") or "",
            "prereqAuditMarkdown": prereq.get("auditMarkdown") or "",
            "planPreviewJSON": plan_preview_value,
        },
    }


def build_markdown(payload: dict[str, Any]) -> str:
    product_run = payload["productRun"]
    plan = payload["plan"]
    target = payload["target"]
    prereq = payload["prereq"]
    entrypoint = payload["entrypoint"]
    recovery = entrypoint.get("recovery") or {}
    evidence_policy = payload["evidencePolicy"]
    phase_rows = [["Phase", "Kind", "Status", "Reason", "Run Dir", "Command"]]
    for phase in payload["phases"]:
        phase_rows.append([
            f"`{phase['phase']}`",
            f"`{phase['kind']}`",
            f"`{phase['status']}`",
            phase["reason"] or "-",
            f"`{phase['runDir']}`" if phase["runDir"] else "-",
            f"`{phase['command']}`",
        ])
    lines = [
        "# Product Test Plan Runbook",
        "",
        f"- status: `{payload['status']}`",
        f"- reason: {payload['reason']}",
        f"- plan: `{plan['name']}`",
        f"- preset: `{plan['preset'] or '-'}`",
        f"- requested phases: `{' '.join(plan['requestedPhases'])}`",
        f"- full profile: `{plan['fullProfile']}` enabled=`{plan['runFullProfile']}`",
        f"- plan preview: `{plan['previewJSON'] or '-'}` scenarios=`{plan['preview']['uniqueScenarioCount']}` largeGroupIncluded=`{plan['preview']['largeGroupIncluded']}` domainCount=`{len(plan['preview']['coveredProductDomains'])}` requiredDomainsCovered=`{plan['preview']['requiredProductDomainsCovered']}`",
        f"- product domains: `{', '.join(plan['preview']['coveredProductDomains']) or '-'}`",
        f"- missing product domains: `{', '.join(plan['preview']['missingProductDomains']) or '-'}`",
        f"- final status: `{product_run['finalStatus']}`",
        f"- blockerType: `{product_run.get('blockerType') or '-'}`",
        f"- dryRun: `{product_run['dryRun']}`",
        f"- statusFilterTarget: `{product_run['statusFilterTarget']}`",
        f"- entrypointRequired: `{entrypoint['required']}`",
        f"- runIDPrefix: `{product_run['runIDPrefix']}`",
        f"- baseURL: `{target.get('baseURL') or '-'}`",
        f"- tcpHost: `{target.get('tcpHost') or '-'}`",
        f"- accountFile: `{target.get('accountFile') or '-'}`",
        f"- hasConversationID: `{bool(target.get('conversationID'))}`",
        f"- prereq status: `{prereq['status']}`",
        f"- prereq ran: `{prereq['ran']}`",
        f"- missing required/recommended: `{prereq['missingRequiredCount']}/{prereq['missingRecommendedCount']}`",
        f"- account rows: `{prereq['accountRows']}`",
        "",
        "## Rerun Command",
        "",
        "```bash",
        payload["commands"]["rerun"],
        "```",
        "",
        "## Verify Receipt",
        "",
        "```bash",
        payload["commands"]["verify"],
        "```",
        "",
        "## Evidence Policy",
        "",
        f"- classification: `{evidence_policy['classification']}`",
        f"- requiresCurrentReadiness: `{evidence_policy['requiresCurrentReadiness']}`",
        f"- finalAcceptanceCommand: `{evidence_policy['finalAcceptanceCommand']}`",
        "",
        "This product-plan runbook is for domain diagnostics and staged product validation. A final production evidence package must include current readiness with smoke, product scenario suite, baseline, and full acceptance all requested and passing.",
        "",
        "## Phase Records",
        "",
        markdown_table(phase_rows) if payload["phases"] else "No phase ran before the plan failed.",
        "",
    ]
    if recovery.get("needed"):
        command_rows = [["Name", "When", "Command"]]
        for command in recovery.get("commands") or []:
            command_rows.append([
                f"`{command.get('name') or '-'}`",
                str(command.get("when") or "-"),
                f"`{command.get('command') or ''}`",
            ])
        signals = recovery.get("signals") or {}
        blocker = recovery.get("blocker") or {}
        lines.extend([
            "## Entrypoint Recovery",
            "",
            f"- diagnosis: `{recovery.get('diagnosis') or '-'}`",
            f"- reason: {recovery.get('reason') or '-'}",
            f"- blocker: `{blocker.get('type') or '-'}/{blocker.get('severity') or '-'}` preventsPerformanceEvidence=`{blocker.get('preventsPerformanceEvidence') if blocker else '-'}` action=`{blocker.get('action') or '-'}`",
            f"- probeJSON: `{recovery.get('probeJSON') or '-'}`",
            f"- nginxHealthStatus: `{signals.get('nginxHealthStatus') or '-'}`",
            f"- healthStatus: `{signals.get('healthStatus') or '-'}`",
            f"- loginStatus: `{signals.get('loginStatus') or '-'}`",
            f"- tcpStatus: `{signals.get('tcpStatus') or '-'}`",
            "",
            markdown_table(command_rows),
            "",
        ])
    lines.extend([
        "## Artifacts",
        "",
        f"- productRun: `{payload['artifacts']['productRun']}`",
        f"- prereqPlan: `{payload['artifacts']['prereqPlan'] or '-'}`",
        f"- prereqAuditJSON: `{payload['artifacts']['prereqAuditJSON'] or '-'}`",
        f"- prereqAuditMarkdown: `{payload['artifacts']['prereqAuditMarkdown'] or '-'}`",
        f"- planPreviewJSON: `{payload['artifacts']['planPreviewJSON'] or '-'}`",
        f"- runbookJSON: `{payload['artifacts']['runbookJSON'] or '-'}`",
        f"- runbookMarkdown: `{payload['artifacts']['runbookMarkdown'] or '-'}`",
        "",
    ])
    return "\n".join(lines)


def verify_payload(payload: dict[str, Any]) -> None:
    if not isinstance(payload, dict):
        raise SystemExit("product_test_runbook_verify result=fail reason=json_not_object")
    if payload.get("schemaVersion") != 1:
        raise SystemExit("product_test_runbook_verify result=fail reason=schema_version")
    if payload.get("status") not in {"READY", "BLOCKED", "FAILED"}:
        raise SystemExit("product_test_runbook_verify result=fail reason=status")
    if not str(payload.get("reason") or ""):
        raise SystemExit("product_test_runbook_verify result=fail reason=reason_missing")
    for key in ("productRun", "plan", "target", "prereq", "entrypoint", "commands", "evidencePolicy", "artifacts"):
        if not isinstance(payload.get(key), dict):
            raise SystemExit(f"product_test_runbook_verify result=fail reason={key}_missing")
    phases = payload.get("phases")
    if not isinstance(phases, list):
        raise SystemExit("product_test_runbook_verify result=fail reason=phases_not_list")

    product_run = payload["productRun"]
    if product_run.get("finalStatus") not in {"PASS", "FAIL", "UNKNOWN"}:
        raise SystemExit("product_test_runbook_verify result=fail reason=product_run_final_status")
    plan = payload["plan"]
    requested_phases = plan.get("requestedPhases")
    if not isinstance(requested_phases, list):
        raise SystemExit("product_test_runbook_verify result=fail reason=requested_phases_not_list")
    preview = plan.get("preview")
    if not isinstance(preview, dict):
        raise SystemExit("product_test_runbook_verify result=fail reason=plan_preview_missing")
    for key in ("phaseCount", "uniqueScenarioCount"):
        value = preview.get(key)
        if not isinstance(value, int) or value < 0:
            raise SystemExit(f"product_test_runbook_verify result=fail reason=preview_{key}")
    for key in ("coveredProductDomains", "requiredProductDomains", "missingProductDomains"):
        if not isinstance(preview.get(key), list):
            raise SystemExit(f"product_test_runbook_verify result=fail reason=preview_{key}_not_list")
    if not isinstance(preview.get("requiredProductDomainsCovered"), bool):
        raise SystemExit("product_test_runbook_verify result=fail reason=preview_required_domains_covered")

    commands = payload["commands"]
    for key in ("rerun", "verify"):
        if not str(commands.get(key) or ""):
            raise SystemExit(f"product_test_runbook_verify result=fail reason=command_{key}_missing")
    if "run_product_test_plan.sh" not in str(commands.get("rerun") or ""):
        raise SystemExit("product_test_runbook_verify result=fail reason=rerun_command_invalid")
    if "perf_product_plan_artifacts_verify.py" not in str(commands.get("verify") or ""):
        raise SystemExit("product_test_runbook_verify result=fail reason=verify_command_invalid")

    evidence_policy = payload["evidencePolicy"]
    if evidence_policy.get("classification") != "diagnostic-product-plan":
        raise SystemExit("product_test_runbook_verify result=fail reason=evidence_policy_classification")
    if evidence_policy.get("requiresCurrentReadiness") is not False:
        raise SystemExit("product_test_runbook_verify result=fail reason=evidence_policy_current_readiness")
    if "run_current_production_readiness.sh" not in str(evidence_policy.get("finalAcceptanceCommand") or ""):
        raise SystemExit("product_test_runbook_verify result=fail reason=evidence_policy_final_acceptance")


def verify_markdown(payload: dict[str, Any], markdown_path: Path) -> None:
    verify_payload(payload)
    if not markdown_path.is_file():
        raise SystemExit(f"product_test_runbook_verify result=fail reason=markdown_missing path={markdown_path}")
    expected = build_markdown(payload)
    actual = markdown_path.read_text(encoding="utf-8")
    if actual != expected:
        raise SystemExit(f"product_test_runbook_verify result=fail reason=markdown_mismatch path={markdown_path}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate an operator runbook for a product test plan run.")
    parser.add_argument("--product-run-json")
    parser.add_argument("--prereq-audit-json", default="")
    parser.add_argument("--result-root")
    parser.add_argument("--output")
    parser.add_argument("--json-output")
    parser.add_argument("--verify-json")
    parser.add_argument("--verify-md")
    args = parser.parse_args()

    if args.verify_json:
        payload = read_json(Path(args.verify_json))
        verify_payload(payload)
        if args.verify_md:
            verify_markdown(payload, Path(args.verify_md))
        return 0
    if args.verify_md:
        parser.error("--verify-md requires --verify-json")
    for name in ("product_run_json", "result_root"):
        if not getattr(args, name):
            parser.error(f"--{name.replace('_', '-')} is required unless --verify-json is used")

    payload = build_runbook(args)
    markdown = build_markdown(payload)
    if args.output:
        Path(args.output).write_text(markdown, encoding="utf-8")
    else:
        print(markdown)
    if args.json_output:
        Path(args.json_output).write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    if args.output:
        verify_markdown(payload, Path(args.output))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
