#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shlex
from pathlib import Path
from typing import Any


def read_json(path: Path | None) -> dict[str, Any]:
    if path is None or not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise SystemExit(f"Failed to read JSON {path}: {exc}") from exc


def shell_assign(name: str, value: str) -> str:
    return f"{name}={shlex.quote(value)}"


def shell_secret_assign(name: str, value: str) -> str:
    if not value:
        return ""
    return f"{name}=${{{name}:?set-{name}}}"


def shell_required_assign(name: str) -> str:
    return f"{name}=${{{name}:?set-{name}}}"


def shell_flag(name: str, value: bool) -> str:
    return shell_assign(name, "true" if value else "false")


def build_env(args: argparse.Namespace) -> list[str]:
    env: list[str] = [
        shell_assign("RESULT_ROOT", args.result_root),
        shell_assign("PERF_PRODUCTION_GATE_PROFILE", args.profile),
        shell_assign("PERF_PRODUCTION_GATE_MAX_AGE_SECONDS", str(args.max_age_seconds)),
        shell_assign("PRODUCTION_PROFILE_BATCH_SIZE", str(args.batch_size)),
        shell_flag("PRODUCTION_PROFILE_RESUME_PASS", args.resume_fresh_pass),
        shell_flag("PRODUCTION_PROFILE_PACKAGE", args.package),
        shell_flag("PRODUCTION_PROFILE_STOP_ON_FAILURE", args.stop_on_failure),
        shell_flag("PRODUCTION_PROFILE_PREFLIGHT", args.preflight),
        shell_flag("PRODUCTION_PROFILE_PREREQ_GATE", args.prereq_gate),
        shell_flag("PRODUCTION_PROFILE_ENTRYPOINT_PROBE", args.entrypoint_probe),
        shell_flag("PRODUCTION_PROFILE_REQUIRE_PRODUCT_PLAN_ARTIFACTS", args.require_product_plan_artifacts),
        shell_flag("PERF_STATUS_FILTER_TARGET", args.status_filter_target),
    ]
    optional = [
        ("BASE_URL", args.base_url),
        ("TCP_HOST", args.tcp_host),
        ("TCP_PORT", args.tcp_port),
        ("ACCOUNT_FILE", args.account_file),
        ("IM_CONVERSATION_ID", args.conversation_id),
        ("IM_AUTH_EMAIL_WEBHOOK_SINK_URL", args.auth_email_webhook_url),
        ("IM_ACCOUNT_VERIFICATION_CODE", args.verification_code),
        ("IM_ACCOUNT_PASSWORD_RESET_CODE", args.password_reset_code),
    ]
    for name, value in optional:
        if value:
            env.append(shell_assign(name, value))
    if args.internal_secret:
        env.append(shell_secret_assign("IM_INTERNAL_SECRET", args.internal_secret))
    if args.run_id_prefix:
        env.append(shell_assign("PRODUCTION_PROFILE_RUN_ID_PREFIX", args.run_id_prefix))
    if args.package:
        env.extend([
            "PRODUCTION_PROFILE_REQUIRE_CLOUD_SECURITY_GROUP=true",
            "PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS=86400",
            "PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080=false",
            shell_required_assign("PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_FILE"),
            shell_required_assign("PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON"),
            shell_required_assign("PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID"),
            shell_required_assign("PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID"),
            shell_required_assign("PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR"),
        ])
    return env


def build_profile_command(args: argparse.Namespace) -> str:
    return " ".join([*build_env(args), "./run_production_profile.sh"])


def build_batch_command(args: argparse.Namespace, batch: dict[str, Any]) -> str:
    index = int(batch.get("index") or 0)
    run_id = f"{args.run_id_prefix}-batch{index:02d}" if args.run_id_prefix else f"production-{args.profile}-batch{index:02d}"
    scenarios = " ".join(str(item) for item in (batch.get("scenarios") or []) if item)
    parts = [
        shell_assign("RUN_ID", run_id),
        shell_assign("RESULT_ROOT", args.result_root),
        shell_assign("SCENARIOS", scenarios),
        shell_assign("PERF_PRODUCTION_GATE_PROFILE", args.profile),
        shell_assign("PERF_PRODUCTION_GATE_MAX_AGE_SECONDS", str(args.max_age_seconds)),
        shell_flag("PERF_PREFLIGHT", args.preflight),
        "PERF_PRODUCTION_GATE=true",
        "PERF_GLOBAL_STATUS=true",
        "PERF_SLO=true",
        "PERF_RUN_PLAN=true",
        shell_flag("STOP_ON_FAILURE", args.stop_on_failure),
        shell_flag("PERF_STATUS_FILTER_TARGET", args.status_filter_target),
    ]
    optional = [
        ("BASE_URL", args.base_url),
        ("TCP_HOST", args.tcp_host),
        ("TCP_PORT", args.tcp_port),
        ("ACCOUNT_FILE", args.account_file),
        ("IM_CONVERSATION_ID", args.conversation_id),
    ]
    for name, value in optional:
        if value:
            parts.append(shell_assign(name, value))
    if args.internal_secret:
        parts.append(shell_secret_assign("IM_INTERNAL_SECRET", args.internal_secret))
    parts.append("./run_perf_scenarios.sh")
    return " ".join(parts)


def build_package_command(args: argparse.Namespace) -> str:
    parts = [
        shell_assign("RESULT_ROOT", args.result_root),
        shell_assign("PERF_PRODUCTION_GATE_JSON", str(Path(args.result_root) / "production-gate.json")),
        shell_assign("PERF_PRODUCTION_GATE_PROFILE", args.profile),
        shell_assign("PERF_PRODUCTION_GATE_MAX_AGE_SECONDS", str(args.max_age_seconds)),
        shell_assign("PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS", "false"),
    ]
    if args.package:
        parts.extend([
            "PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP=true",
            "PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS=86400",
            "PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080=false",
            shell_required_assign("PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_FILE"),
            shell_required_assign("PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON"),
            shell_required_assign("PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID"),
            shell_required_assign("PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID"),
            shell_required_assign("PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR"),
        ])
    parts.append("./package_production_evidence.sh")
    return " ".join(parts)


def profile_probe_path(args: argparse.Namespace, profile_run: dict[str, Any]) -> Path | None:
    probe_artifacts = profile_run.get("entrypointProbeArtifacts") or {}
    value = str(probe_artifacts.get("json") or "")
    if not value:
        return None
    path = Path(value)
    if not path.is_absolute() and args.profile_run:
        path = Path(args.profile_run).parent / path
    return path


def read_entrypoint_probe(args: argparse.Namespace, profile_run: dict[str, Any]) -> dict[str, Any]:
    path = profile_probe_path(args, profile_run)
    probe = read_json(path) if path is not None else {}
    blocker = probe.get("blocker") if isinstance(probe.get("blocker"), dict) else {}
    signals = probe.get("signals") if isinstance(probe.get("signals"), dict) else {}
    return {
        "probeJSON": str(path or ""),
        "failed": bool(probe.get("failed")),
        "diagnosis": str(probe.get("diagnosis") or ""),
        "detail": str(probe.get("detail") or ""),
        "blocker": blocker,
        "signals": signals,
    }


def build_runbook(args: argparse.Namespace) -> dict[str, Any]:
    plan = read_json(Path(args.plan))
    prereq_audit = read_json(Path(args.prereq_audit) if args.prereq_audit else None)
    profile_run = read_json(Path(args.profile_run) if args.profile_run else None)
    prereq_summary = prereq_audit.get("summary") or {}
    entrypoint = read_entrypoint_probe(args, profile_run)
    batches = list(plan.get("batches") or [])
    batch_commands = [
        {
            "index": int(batch.get("index") or index + 1),
            "scenarios": [str(item) for item in (batch.get("scenarios") or []) if item],
            "command": build_batch_command(args, batch),
        }
        for index, batch in enumerate(batches)
    ]
    missing_required = int(prereq_summary.get("missingRequiredCount") or 0)
    profile_reason = str(profile_run.get("reason") or "")
    if prereq_summary.get("overallStatus") == "BLOCKED" or missing_required > 0:
        status = "BLOCKED"
        reason = "Required prerequisites are missing; do not run the profile until they are fixed."
    elif profile_reason == "entrypoint_probe_failed" or entrypoint.get("failed"):
        status = "BLOCKED"
        blocker = entrypoint.get("blocker") or {}
        blocker_reason = str(blocker.get("reason") or "")
        reason = blocker_reason or str(entrypoint.get("detail") or "") or "HTTP entrypoint failed; repair exposure before running scenarios."
    elif not batches:
        status = "NOOP"
        reason = "All required scenarios already have fresh PASS evidence for this profile."
    else:
        status = "READY"
        reason = "Run the profile command, or run the listed batch commands in order for manual recovery."

    return {
        "schemaVersion": 1,
        "status": status,
        "reason": reason,
        "profile": args.profile,
        "resultRoot": args.result_root,
        "plan": {
            "path": args.plan,
            "profileScenarioCount": int(plan.get("profileScenarioCount") or 0),
            "selectedScenarioCount": int(plan.get("selectedScenarioCount") or 0),
            "skippedFreshPassCount": int(plan.get("skippedFreshPassCount") or 0),
            "batchCount": int(plan.get("batchCount") or len(batches)),
            "batchSize": int(plan.get("batchSize") or args.batch_size),
            "resumeFreshPass": bool(plan.get("resumeFreshPass") if "resumeFreshPass" in plan else args.resume_fresh_pass),
            "maxAgeSeconds": int(plan.get("maxAgeSeconds") or args.max_age_seconds),
            "statusFilterTarget": bool(args.status_filter_target),
            "entrypointProbe": bool(args.entrypoint_probe),
            "requireProductPlanArtifacts": bool(args.require_product_plan_artifacts),
        },
        "target": {
            "baseURL": args.base_url,
            "tcpHost": args.tcp_host,
            "tcpPort": args.tcp_port,
            "accountFile": args.account_file,
            "hasConversationID": bool(args.conversation_id),
            "hasInternalSecret": bool(args.internal_secret),
            "hasAuthEmailCodeSource": bool(args.auth_email_webhook_url or args.verification_code or args.password_reset_code),
        },
        "prereq": {
            "auditPath": args.prereq_audit,
            "status": prereq_summary.get("overallStatus") or "-",
            "missingRequiredCount": missing_required,
            "missingRecommendedCount": int(prereq_summary.get("missingRecommendedCount") or 0),
            "accountRows": int(prereq_summary.get("accountRows") or 0),
        },
        "entrypoint": entrypoint,
        "profileRun": {
            "path": args.profile_run,
            "finalStatus": profile_run.get("finalStatus") or "-",
            "reason": profile_run.get("reason") or "",
            "blockerType": profile_run.get("blockerType") or "",
            "dryRun": bool(profile_run.get("dryRun")),
            "batchCount": len(profile_run.get("batches") or []),
        },
        "commands": {
            "profile": build_profile_command(args),
            "package": build_package_command(args),
            "batches": batch_commands,
        },
        "evidencePolicy": {
            "classification": "diagnostic-production-profile",
            "requiresCurrentReadiness": False,
            "finalAcceptanceCommand": "CURRENT_PRODUCTION_REQUIRE_PACKAGEABLE_EVIDENCE=true CURRENT_PRODUCTION_RUN_BASELINE=true CURRENT_PRODUCTION_RUN_SCENARIO_SUITE=true CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE=true ./run_current_production_readiness.sh",
        },
        "evidence": {
            "productionGate": str(Path(args.result_root) / "production-gate.json"),
            "productionProfileRun": str(Path(args.result_root) / "production-profile-run.json"),
            "productionProfilePlan": str(Path(args.result_root) / "production-profile-plan.json"),
            "productionProfileRunbook": str(Path(args.result_root) / "production-profile-runbook.md"),
            "productionEvidenceDir": str(Path(args.result_root) / "production-evidence"),
        },
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
    plan = payload["plan"]
    target = payload["target"]
    prereq = payload["prereq"]
    entrypoint = payload.get("entrypoint") or {}
    entrypoint_blocker = entrypoint.get("blocker") or {}
    profile_run = payload["profileRun"]
    evidence = payload["evidence"]
    evidence_policy = payload["evidencePolicy"]
    batch_rows = [["Batch", "Scenarios", "Command"]]
    for batch in payload["commands"]["batches"]:
        batch_rows.append([
            str(batch["index"]),
            ", ".join(f"`{item}`" for item in batch["scenarios"]) or "-",
            f"`{batch['command']}`",
        ])
    return "\n".join([
        "# Production Profile Runbook",
        "",
        f"- status: `{payload['status']}`",
        f"- reason: {payload['reason']}",
        f"- profile: `{payload['profile']}`",
        f"- resultRoot: `{payload['resultRoot']}`",
        f"- profile scenarios: `{plan['profileScenarioCount']}`",
        f"- selected/skipped/batches: `{plan['selectedScenarioCount']}/{plan['skippedFreshPassCount']}/{plan['batchCount']}`",
        f"- statusFilterTarget: `{plan['statusFilterTarget']}`",
        f"- entrypointProbe: `{plan['entrypointProbe']}`",
        f"- entrypointDiagnosis: `{entrypoint.get('diagnosis') or '-'}`",
        f"- entrypointBlocker: `{entrypoint_blocker.get('type') or '-'}/{entrypoint_blocker.get('severity') or '-'}` preventsPerformanceEvidence=`{entrypoint_blocker.get('preventsPerformanceEvidence') if entrypoint_blocker else '-'}` action=`{entrypoint_blocker.get('action') or '-'}`",
        f"- requireProductPlanArtifacts: `{plan['requireProductPlanArtifacts']}`",
        f"- prereq status: `{prereq['status']}`",
        f"- missing required/recommended: `{prereq['missingRequiredCount']}/{prereq['missingRecommendedCount']}`",
        f"- account rows: `{prereq['accountRows']}`",
        f"- last run status: `{profile_run['finalStatus']}`",
        f"- blockerType: `{profile_run.get('blockerType') or '-'}`",
        f"- baseURL: `{target['baseURL'] or '-'}`",
        f"- tcpHost: `{target['tcpHost'] or '-'}`",
        f"- accountFile: `{target['accountFile'] or '-'}`",
        f"- hasConversationID: `{target['hasConversationID']}`",
        f"- hasInternalSecret: `{target['hasInternalSecret']}`",
        "",
        "## Preferred Command",
        "",
        "```bash",
        payload["commands"]["profile"],
        "```",
        "",
        "## Manual Batch Commands",
        "",
        markdown_table(batch_rows) if payload["commands"]["batches"] else "No batch commands are required.",
        "",
        "## Package Evidence",
        "",
        "Run this only after the selected profile gate passes. This command creates a diagnostic profile package, not final production acceptance evidence, because it explicitly does not require current readiness/full acceptance artifacts:",
        "",
        "```bash",
        payload["commands"]["package"],
        "```",
        "",
        "## Evidence Policy",
        "",
        f"- classification: `{evidence_policy['classification']}`",
        f"- requiresCurrentReadiness: `{evidence_policy['requiresCurrentReadiness']}`",
        f"- finalAcceptanceCommand: `{evidence_policy['finalAcceptanceCommand']}`",
        "",
        "## Expected Evidence",
        "",
        f"- productionGate: `{evidence['productionGate']}`",
        f"- productionProfileRun: `{evidence['productionProfileRun']}`",
        f"- productionProfilePlan: `{evidence['productionProfilePlan']}`",
        f"- productionProfileRunbook: `{evidence['productionProfileRunbook']}`",
        f"- productionEvidenceDir: `{evidence['productionEvidenceDir']}`",
        "",
    ])


def verify_payload(payload: dict[str, Any]) -> None:
    if not isinstance(payload, dict):
        raise SystemExit("production_profile_runbook_verify result=fail reason=json_not_object")
    if payload.get("schemaVersion") != 1:
        raise SystemExit("production_profile_runbook_verify result=fail reason=schema_version")
    if payload.get("status") not in {"READY", "BLOCKED", "NOOP"}:
        raise SystemExit("production_profile_runbook_verify result=fail reason=status")
    for key in ("reason", "profile", "resultRoot"):
        if not str(payload.get(key) or ""):
            raise SystemExit(f"production_profile_runbook_verify result=fail reason={key}_missing")
    for key in ("plan", "target", "prereq", "profileRun", "commands", "evidencePolicy", "evidence"):
        if not isinstance(payload.get(key), dict):
            raise SystemExit(f"production_profile_runbook_verify result=fail reason={key}_missing")

    plan = payload["plan"]
    for key in ("profileScenarioCount", "selectedScenarioCount", "skippedFreshPassCount", "batchCount", "batchSize", "maxAgeSeconds"):
        value = plan.get(key)
        if not isinstance(value, int) or value < 0:
            raise SystemExit(f"production_profile_runbook_verify result=fail reason=plan_{key}")
    commands = payload["commands"]
    for key in ("profile", "package"):
        if not str(commands.get(key) or ""):
            raise SystemExit(f"production_profile_runbook_verify result=fail reason=command_{key}_missing")
    batches = commands.get("batches")
    if not isinstance(batches, list):
        raise SystemExit("production_profile_runbook_verify result=fail reason=command_batches_not_list")
    if payload["status"] == "READY" and len(batches) != plan["batchCount"]:
        raise SystemExit("production_profile_runbook_verify result=fail reason=batch_count_mismatch")
    seen_batches: set[int] = set()
    for row in batches:
        if not isinstance(row, dict):
            raise SystemExit("production_profile_runbook_verify result=fail reason=batch_row_not_object")
        index = row.get("index")
        if not isinstance(index, int) or index <= 0:
            raise SystemExit("production_profile_runbook_verify result=fail reason=batch_index")
        if index in seen_batches:
            raise SystemExit(f"production_profile_runbook_verify result=fail reason=duplicate_batch index={index}")
        seen_batches.add(index)
        if not isinstance(row.get("scenarios"), list):
            raise SystemExit(f"production_profile_runbook_verify result=fail reason=batch_scenarios index={index}")
        if not str(row.get("command") or ""):
            raise SystemExit(f"production_profile_runbook_verify result=fail reason=batch_command_missing index={index}")

    evidence_policy = payload["evidencePolicy"]
    if evidence_policy.get("classification") != "diagnostic-production-profile":
        raise SystemExit("production_profile_runbook_verify result=fail reason=evidence_policy_classification")
    if evidence_policy.get("requiresCurrentReadiness") is not False:
        raise SystemExit("production_profile_runbook_verify result=fail reason=evidence_policy_current_readiness")
    if "run_current_production_readiness.sh" not in str(evidence_policy.get("finalAcceptanceCommand") or ""):
        raise SystemExit("production_profile_runbook_verify result=fail reason=evidence_policy_final_acceptance")


def verify_markdown(payload: dict[str, Any], markdown_path: Path) -> None:
    verify_payload(payload)
    if not markdown_path.is_file():
        raise SystemExit(f"production_profile_runbook_verify result=fail reason=markdown_missing path={markdown_path}")
    expected = build_markdown(payload)
    actual = markdown_path.read_text(encoding="utf-8")
    if actual != expected:
        raise SystemExit(f"production_profile_runbook_verify result=fail reason=markdown_mismatch path={markdown_path}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate a production profile runbook with exact run and evidence commands.")
    parser.add_argument("--plan")
    parser.add_argument("--prereq-audit", default="")
    parser.add_argument("--profile-run", default="")
    parser.add_argument("--profile")
    parser.add_argument("--result-root")
    parser.add_argument("--run-id-prefix", default="")
    parser.add_argument("--batch-size", type=int, default=6)
    parser.add_argument("--resume-fresh-pass", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--package", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--stop-on-failure", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--preflight", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--prereq-gate", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--entrypoint-probe", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--require-product-plan-artifacts", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--status-filter-target", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--max-age-seconds", type=int, default=604800)
    parser.add_argument("--base-url", default="")
    parser.add_argument("--tcp-host", default="")
    parser.add_argument("--tcp-port", default="")
    parser.add_argument("--account-file", default="")
    parser.add_argument("--conversation-id", default="")
    parser.add_argument("--internal-secret", default="")
    parser.add_argument("--auth-email-webhook-url", default="")
    parser.add_argument("--verification-code", default="")
    parser.add_argument("--password-reset-code", default="")
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

    for name in ("plan", "profile", "result_root"):
        if not getattr(args, name):
            parser.error(f"--{name.replace('_', '-')} is required unless --verify-json is used")
    if args.batch_size <= 0:
        parser.error("--batch-size must be greater than 0")
    if args.max_age_seconds < 0:
        parser.error("--max-age-seconds must be >= 0")

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
