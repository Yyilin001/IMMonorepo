#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any

import production_completion_status
import verify_production_completion_status


DEFAULT_STATUS_JSON = "IMServer/LoadTests/results/production-completion-status/latest.json"
DEFAULT_MARKDOWN_OUTPUT = "IMServer/LoadTests/results/production-completion-status/evidence-recovery-plan.md"
DEFAULT_JSON_OUTPUT = "IMServer/LoadTests/results/production-completion-status/evidence-recovery-plan.json"
DEFAULT_SCRIPT_OUTPUT = "IMServer/LoadTests/results/production-completion-status/evidence-recovery-run.sh"
EXPECTED_KIND = "imserver-production-evidence-recovery-plan"
EXPECTED_SOURCE_KIND = "imserver-production-completion-status"


def fail(reason: str, **fields: Any) -> None:
    detail = " ".join(f"{key}={value}" for key, value in fields.items())
    message = f"production_evidence_recovery_plan result=fail reason={reason}"
    if detail:
        message = f"{message} {detail}"
    raise SystemExit(message)


def read_json(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception as error:
        fail("invalid_json", path=path, error=error)
    if not isinstance(payload, dict):
        fail("json_root_not_object", path=path)
    return payload


def completion_verify_args(repo_root: Path, *, max_age_seconds: int) -> argparse.Namespace:
    return argparse.Namespace(
        expect_repo_root=str(repo_root),
        max_age_seconds=max_age_seconds,
        max_future_skew_seconds=300,
        require_local_complete=False,
        require_live_evidence_complete=False,
        require_production_ready=False,
    )


def verify_completion_status(path: Path, repo_root: Path, *, max_age_seconds: int) -> dict[str, Any]:
    args = completion_verify_args(repo_root, max_age_seconds=max_age_seconds)
    return verify_production_completion_status.verify_status_report(path, args)


def require_int(payload: dict[str, Any], field: str) -> int:
    value = payload.get(field)
    if not isinstance(value, int) or isinstance(value, bool):
        fail("field_invalid", field=field, value=payload.get(field))
    return value


def require_list(payload: dict[str, Any], field: str) -> list[dict[str, Any]]:
    value = payload.get(field)
    if not isinstance(value, list):
        fail("field_invalid", field=field)
    rows: list[dict[str, Any]] = []
    for index, item in enumerate(value):
        if not isinstance(item, dict):
            fail("row_invalid", field=field, index=index)
        rows.append(item)
    return rows


def status_summary(status: dict[str, Any]) -> dict[str, Any]:
    summary = status.get("summary")
    if not isinstance(summary, dict):
        fail("completion_summary_invalid")
    return {
        "status": str(status.get("status") or ""),
        "localCompletionPercent": require_int(status, "localCompletionPercent"),
        "liveEvidenceCompletionPercent": require_int(status, "liveEvidenceCompletionPercent"),
        "productionCompletionPercent": require_int(status, "productionCompletionPercent"),
        "localPassed": require_int(summary, "localPassed"),
        "localTotal": require_int(summary, "localTotal"),
        "liveEvidencePassed": require_int(summary, "liveEvidencePassed"),
        "liveEvidenceTotal": require_int(summary, "liveEvidenceTotal"),
        "missingCount": require_int(summary, "missingCount"),
        "evidenceRecoveryPlanCount": require_int(summary, "evidenceRecoveryPlanCount"),
    }


def production_target_from_status(status: dict[str, Any]) -> dict[str, Any]:
    target = status.get("productionTarget")
    if not isinstance(target, dict):
        fail("production_target_missing")
    missing_env = target.get("missingEnv")
    if (
        not isinstance(target.get("baseURL"), str)
        or not isinstance(target.get("tcpHost"), str)
        or not isinstance(target.get("tcpPort"), str)
        or not isinstance(missing_env, list)
        or not all(isinstance(item, str) for item in missing_env)
    ):
        fail("production_target_missing_env_invalid")
    return {
        "baseURL": target["baseURL"],
        "tcpHost": target["tcpHost"],
        "tcpPort": target["tcpPort"],
        "missingEnv": list(missing_env),
    }


def production_claim_from_status(status: dict[str, Any]) -> dict[str, Any]:
    claim = status.get("productionClaim")
    if not isinstance(claim, dict):
        fail("production_claim_missing")
    blockers = claim.get("blockers")
    if not isinstance(blockers, list) or not all(isinstance(item, str) for item in blockers):
        fail("production_claim_blockers_invalid")
    required_evidence = claim.get("requiredEvidence")
    if not isinstance(required_evidence, list) or not all(isinstance(item, str) for item in required_evidence):
        fail("production_claim_required_evidence_invalid")
    actual_required_evidence = list(required_evidence)
    expected_required_evidence = list(production_completion_status.EVIDENCE_CONTRACTS)
    if actual_required_evidence != expected_required_evidence:
        fail(
            "production_claim_required_evidence_mismatch",
            expected=",".join(expected_required_evidence),
            actual=",".join(actual_required_evidence) or "-",
        )
    bool_fields = (
        "productionReady",
        "claimAllowed",
        "localEngineeringComplete",
        "liveEvidenceComplete",
        "targetComplete",
        "finalAssertionPassed",
        "finalAssertionArchivePassed",
        "finalAssertionClaimVerified",
        "finalAssertionArchiveClaimVerified",
    )
    if any(not isinstance(claim.get(field), bool) for field in bool_fields):
        fail("production_claim_field_invalid")
    if not isinstance(claim.get("claimLevel"), str) or not isinstance(claim.get("basis"), str):
        fail("production_claim_field_invalid")
    return {
        **{field: claim[field] for field in bool_fields},
        "claimLevel": claim["claimLevel"],
        "basis": claim["basis"],
        "requiredEvidence": actual_required_evidence,
        "blockers": list(blockers),
    }


def ready_to_claim_production(summary: dict[str, Any], missing: list[dict[str, Any]], claim: dict[str, Any]) -> bool:
    return (
        summary["status"] == "ready"
        and not missing
        and claim["productionReady"] is True
        and claim["claimAllowed"] is True
        and claim["finalAssertionClaimVerified"] is True
        and claim["finalAssertionArchiveClaimVerified"] is True
        and not claim["blockers"]
    )


def build_plan(status: dict[str, Any], *, status_json: Path, allow_local_incomplete: bool) -> dict[str, Any]:
    if status.get("kind") != EXPECTED_SOURCE_KIND:
        fail("completion_kind_mismatch", actual=status.get("kind") or "-")
    summary = status_summary(status)
    claim = production_claim_from_status(status)
    if summary["localPassed"] != summary["localTotal"] and not allow_local_incomplete:
        fail(
            "local_engineering_incomplete",
            localPassed=summary["localPassed"],
            localTotal=summary["localTotal"],
        )
    missing = require_list(status, "missing")
    local_missing = [item for item in missing if item.get("scope") == "local"]
    evidence_missing = [item for item in missing if item.get("scope") == "evidence"]
    recovery_steps = require_list(status, "evidenceRecoveryPlan")
    ready_to_claim = ready_to_claim_production(summary, missing, claim)
    payload: dict[str, Any] = {
        "kind": EXPECTED_KIND,
        "schemaVersion": 1,
        "generatedAtEpoch": int(time.time()),
        "sourceStatusJson": str(status_json),
        "sourceStatusGeneratedAtEpoch": require_int(status, "generatedAtEpoch"),
        "sourceStatus": summary["status"],
        "productionTarget": production_target_from_status(status),
        "productionClaim": claim,
        "readinessTiers": readiness_tiers_from_status(status),
        "readyToClaimProduction": ready_to_claim,
        "localEngineeringComplete": summary["localPassed"] == summary["localTotal"],
        "summary": summary,
        "localMissing": local_missing,
        "evidenceMissing": evidence_missing,
        "steps": recovery_steps,
        "finalVerificationCommands": [
            "make production-completion-status",
            "make verify-production-completion-status",
            "make verify-production-ready-assertion",
            "make verify-production-ready-archive",
        ],
    }
    payload["operatorEnvironmentTemplate"] = operator_environment_template(payload)
    payload["oneShotRecoveryCommands"] = one_shot_recovery_commands(payload)
    verify_plan(payload, status)
    return payload


def readiness_tiers_from_status(status: dict[str, Any]) -> dict[str, Any]:
    tiers = status.get("readinessTiers")
    if not isinstance(tiers, dict):
        fail("readiness_tiers_missing")
    required = {"localEngineering", "liveProductionEvidence", "productionReady"}
    actual = {str(item) for item in tiers}
    if actual != required:
        fail("readiness_tiers_mismatch", expected=",".join(sorted(required)), actual=",".join(sorted(actual)))
    return json.loads(json.dumps(tiers))


def expected_evidence_order() -> list[str]:
    return list(production_completion_status.EVIDENCE_CONTRACTS)


ENV_EXAMPLES = {
    "BASE_URL": "https://<production-base-url>",
    "TCP_HOST": "<production-tcp-host>",
    "TCP_PORT": "9000",
    "PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON": "IMServer/LoadTests/results/deploy-readiness/deploy-readiness.json",
    "CURRENT_PRODUCTION_READINESS_JSON": "IMServer/LoadTests/results/current-production-readiness/current-production-readiness.json",
    "CURRENT_PRODUCTION_READINESS_DASHBOARD_JSON": "IMServer/LoadTests/results/current-production-readiness/dashboard.json",
    "CURRENT_PRODUCTION_READINESS_STATE_JSON": "IMServer/LoadTests/results/current-production-readiness/state.json",
    "CURRENT_PRODUCTION_READINESS_PROBE_JSON": "IMServer/LoadTests/results/current-production-readiness/probe.json",
    "CURRENT_PRODUCTION_READINESS_EVIDENCE_DIR": "IMServer/LoadTests/results/current-production-readiness/evidence",
    "PRODUCTION_ACCEPTANCE_RECEIPT_JSON": "IMServer/LoadTests/results/production-acceptance/production-acceptance.json",
    "PRODUCTION_EVIDENCE_PACKAGE": "IMServer/LoadTests/results/production-acceptance/production-evidence.tar.gz",
    "PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON": "IMServer/reports/latest-production-smoke.json",
    "PRODUCTION_READY_ASSERTION_JSON": "IMServer/LoadTests/results/production-ready/latest.json",
    "PRODUCTION_READY_ASSERTION_ARCHIVE_FILE": "IMServer/LoadTests/results/production-ready/archive/production-ready-assertion.tar.gz",
}


def required_environment_names(steps: list[dict[str, Any]]) -> list[str]:
    names: list[str] = []
    seen: set[str] = set()
    for step in steps:
        required_env = step.get("requiredEnv")
        if not isinstance(required_env, list):
            continue
        for value in required_env:
            name = str(value)
            if name and name not in seen:
                seen.add(name)
                names.append(name)
    return names


def operator_environment_template(plan: dict[str, Any]) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    target = plan.get("productionTarget") if isinstance(plan.get("productionTarget"), dict) else {}
    target_examples = {
        "BASE_URL": str(target.get("baseURL") or ""),
        "TCP_HOST": str(target.get("tcpHost") or ""),
        "TCP_PORT": str(target.get("tcpPort") or ""),
    }
    for name in required_environment_names(require_list(plan, "steps")):
        rows.append({
            "name": name,
            "example": target_examples.get(name) or ENV_EXAMPLES.get(name, f"<{name.lower()}>"),
        })
    return rows


def one_shot_recovery_commands(plan: dict[str, Any]) -> list[str]:
    commands = ["set -euo pipefail"]
    for step in require_list(plan, "steps"):
        item = str(step.get("item") or "")
        commands.append(f"# {item}")
        commands.append(str(step.get("runCommand") or ""))
        commands.append(str(step.get("verifyCommand") or ""))
    commands.append("# final-verification")
    for command in plan.get("finalVerificationCommands") or []:
        commands.append(str(command))
    return commands


def verify_operator_environment_template(plan: dict[str, Any], steps: list[dict[str, Any]]) -> None:
    template = plan.get("operatorEnvironmentTemplate")
    if not isinstance(template, list):
        fail("operator_env_template_missing")
    required = required_environment_names(steps)
    actual: list[str] = []
    seen: set[str] = set()
    for index, row in enumerate(template):
        if not isinstance(row, dict):
            fail("operator_env_template_row_invalid", index=index)
        name = str(row.get("name") or "")
        example = str(row.get("example") or "")
        if not name:
            fail("operator_env_template_name_missing", index=index)
        if name in seen:
            fail("operator_env_template_duplicate", name=name)
        seen.add(name)
        actual.append(name)
        if not example:
            fail("operator_env_template_example_missing", name=name)
        if "/Users/" in example or "/var/folders/" in example:
            fail("operator_env_template_host_path", name=name)
    if actual != required:
        fail("operator_env_template_mismatch", expected=",".join(required), actual=",".join(actual))


def verify_one_shot_recovery_commands(plan: dict[str, Any], steps: list[dict[str, Any]]) -> None:
    commands = plan.get("oneShotRecoveryCommands")
    if not isinstance(commands, list) or not commands:
        fail("one_shot_recovery_commands_missing")
    expected = one_shot_recovery_commands(plan)
    actual = [str(command) for command in commands]
    if actual != expected:
        fail("one_shot_recovery_commands_mismatch")


def verify_shell_script_syntax(script_path: Path) -> None:
    completed = subprocess.run(
        ["bash", "-n", str(script_path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout or "").strip().replace("\n", " ")
        fail("plan_script_syntax_invalid", path=script_path, detail=detail or "-")


def verify_plan(plan: dict[str, Any], status: dict[str, Any]) -> None:
    if plan.get("kind") != EXPECTED_KIND:
        fail("plan_kind_mismatch", actual=plan.get("kind") or "-")
    if int(plan.get("schemaVersion") or 0) != 1:
        fail("plan_schema_version_mismatch", actual=plan.get("schemaVersion") or "-")
    summary = plan.get("summary")
    if not isinstance(summary, dict):
        fail("plan_summary_invalid")
    if str(plan.get("sourceStatus") or "") != str(status.get("status") or ""):
        fail("source_status_mismatch")
    expected_target = production_target_from_status(status)
    actual_target = plan.get("productionTarget")
    if actual_target != expected_target:
        fail("production_target_mismatch")
    expected_claim = production_claim_from_status(status)
    actual_claim = plan.get("productionClaim")
    if actual_claim != expected_claim:
        fail("production_claim_mismatch")
    expected_tiers = readiness_tiers_from_status(status)
    actual_tiers = plan.get("readinessTiers")
    if actual_tiers != expected_tiers:
        fail("readiness_tiers_mismatch")
    missing = require_list(status, "missing")
    evidence_missing = [item for item in missing if item.get("scope") == "evidence"]
    local_missing = [item for item in missing if item.get("scope") == "local"]
    actual_local_missing = plan.get("localMissing")
    if not isinstance(actual_local_missing, list):
        fail("local_missing_invalid")
    if len(actual_local_missing) != len(local_missing):
        fail("local_missing_count_mismatch", expected=len(local_missing), actual=len(actual_local_missing))
    for index, (actual, expected) in enumerate(zip(actual_local_missing, local_missing)):
        if actual != expected:
            fail(
                "local_missing_mismatch",
                index=index,
                expected=str(expected.get("item") or "-") if isinstance(expected, dict) else "-",
                actual=str(actual.get("item") or "-") if isinstance(actual, dict) else "-",
            )
    steps = require_list(plan, "steps")
    if len(steps) != len(evidence_missing):
        fail("step_count_mismatch", expected=len(evidence_missing), actual=len(steps))
    if bool(plan.get("localEngineeringComplete")) == bool(local_missing):
        fail("local_complete_flag_mismatch")
    expected_ready_to_claim = ready_to_claim_production(status_summary(status), missing, expected_claim)
    if bool(plan.get("readyToClaimProduction")) != expected_ready_to_claim:
        fail("ready_flag_mismatch")
    seen: set[str] = set()
    actual_order: list[str] = []
    expected_contracts = production_completion_status.EVIDENCE_CONTRACTS
    expected_missing_reasons = {
        str(item.get("item") or ""): str(item.get("reason") or "")
        for item in evidence_missing
    }
    for index, step in enumerate(steps):
        item = str(step.get("item") or "")
        if not item:
            fail("step_item_missing", index=index)
        if item in seen:
            fail("step_duplicate", item=item)
        seen.add(item)
        actual_order.append(item)
        contract = expected_contracts.get(item)
        if contract is None:
            fail("step_contract_missing", item=item)
        required_env = step.get("requiredEnv")
        if not isinstance(required_env, list) or [str(value) for value in required_env] != list(contract["requiredEnv"]):
            fail("step_required_env_mismatch", item=item)
        if str(step.get("runCommand") or "") != str(contract["runCommand"]):
            fail("step_run_command_mismatch", item=item)
        if str(step.get("verifyCommand") or "") != str(contract["verifyCommand"]):
            fail("step_verify_command_mismatch", item=item)
        reason = str(step.get("reason") or "")
        if not reason:
            fail("step_reason_missing", item=item)
        if reason != expected_missing_reasons.get(item, ""):
            fail("step_reason_mismatch", item=item)
    expected_order = [item for item in expected_evidence_order() if item in expected_missing_reasons]
    if actual_order != expected_order:
        fail("step_order_mismatch", expected=",".join(expected_order), actual=",".join(actual_order))
    if "final-assertion-archive" in actual_order and actual_order[-1] != "final-assertion-archive":
        fail("final_archive_not_last")
    commands = plan.get("finalVerificationCommands")
    if not isinstance(commands, list) or not commands:
        fail("final_commands_missing")
    required_commands = {
        "make production-completion-status",
        "make verify-production-completion-status",
    }
    if not required_commands.issubset({str(command) for command in commands}):
        fail("final_commands_incomplete")
    verify_operator_environment_template(plan, steps)
    verify_one_shot_recovery_commands(plan, steps)


def require_fresh_plan(plan: dict[str, Any], *, max_age_seconds: int, max_future_skew_seconds: int) -> None:
    if max_age_seconds <= 0:
        fail("max_age_invalid", value=max_age_seconds)
    if max_future_skew_seconds < 0:
        fail("max_future_skew_invalid", value=max_future_skew_seconds)
    generated_at = require_int(plan, "generatedAtEpoch")
    now = int(time.time())
    future_skew = generated_at - now
    if future_skew > max_future_skew_seconds:
        fail("plan_generated_at_in_future", skewSeconds=future_skew, maxFutureSkewSeconds=max_future_skew_seconds)
    age = now - generated_at
    if age > max_age_seconds:
        fail("plan_stale", ageSeconds=age, maxAgeSeconds=max_age_seconds)


def verify_recovery_artifacts(
    *,
    plan_json_path: Path,
    markdown_path: Path,
    script_path: Path | None,
    status: dict[str, Any],
    max_age_seconds: int,
    max_future_skew_seconds: int,
) -> dict[str, Any]:
    if not plan_json_path.is_file():
        fail("plan_json_missing", path=plan_json_path)
    if not markdown_path.is_file():
        fail("plan_markdown_missing", path=markdown_path)
    plan = read_json(plan_json_path)
    verify_plan(plan, status)
    require_fresh_plan(plan, max_age_seconds=max_age_seconds, max_future_skew_seconds=max_future_skew_seconds)
    source_generated_at = require_int(status, "generatedAtEpoch")
    plan_source_generated_at = require_int(plan, "sourceStatusGeneratedAtEpoch")
    if plan_source_generated_at != source_generated_at:
        fail("source_status_generation_mismatch", expected=source_generated_at, actual=plan_source_generated_at)
    if require_int(plan, "generatedAtEpoch") < source_generated_at:
        fail("plan_older_than_source_status")
    expected_markdown = render_markdown(plan)
    actual_markdown = markdown_path.read_text(encoding="utf-8")
    if actual_markdown != expected_markdown:
        fail("plan_markdown_mismatch", path=markdown_path)
    if script_path is not None:
        if not script_path.is_file():
            fail("plan_script_missing", path=script_path)
        expected_script = render_shell_script(plan)
        actual_script = script_path.read_text(encoding="utf-8")
        if actual_script != expected_script:
            fail("plan_script_mismatch", path=script_path)
        if script_path.stat().st_mode & 0o111 == 0:
            fail("plan_script_not_executable", path=script_path)
        verify_shell_script_syntax(script_path)
    return plan


def render_shell_script(plan: dict[str, Any]) -> str:
    target = plan.get("productionTarget") if isinstance(plan.get("productionTarget"), dict) else {}
    expected_base_url = shlex.quote(str(target.get("baseURL") or ""))
    expected_tcp_host = shlex.quote(str(target.get("tcpHost") or ""))
    expected_tcp_port = shlex.quote(str(target.get("tcpPort") or ""))
    lines = [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        "trap 'status=$?; echo \"production evidence recovery failed: line=$LINENO status=$status\" >&2; exit $status' ERR",
        "",
        "IMSERVER_REPO_ROOT=\"${IMSERVER_REPO_ROOT:-$(pwd)}\"",
        "PRODUCTION_TARGET_POLICY=\"${PRODUCTION_TARGET_POLICY:-IMServer/LoadTests/production_target_policy.py}\"",
        f"EXPECTED_BASE_URL={expected_base_url}",
        f"EXPECTED_TCP_HOST={expected_tcp_host}",
        f"EXPECTED_TCP_PORT={expected_tcp_port}",
        "cd \"$IMSERVER_REPO_ROOT\"",
        "if [[ ! -f Makefile || ! -d IMServer/LoadTests ]]; then",
        "  echo \"production evidence recovery must run from IMMonorepo root or with IMSERVER_REPO_ROOT set\" >&2",
        "  exit 2",
        "fi",
        "",
        "require_recovery_env() {",
        "  local name=\"$1\"",
        "  local value=\"${!name:-}\"",
        "  if [[ -z \"$value\" ]]; then",
        "    echo \"missing required production evidence env: $name\" >&2",
        "    exit 2",
        "  fi",
        "  if [[ \"$value\" == *\"<\"* || \"$value\" == *\">\"* ]]; then",
        "    echo \"placeholder production evidence env is not allowed: $name=$value\" >&2",
        "    exit 2",
        "  fi",
        "}",
        "",
        "require_https_url() {",
        "  local name=\"$1\"",
        "  local value=\"${!name:-}\"",
        "  if [[ \"$value\" != https://* ]]; then",
        "    echo \"production evidence env must use https URL: $name\" >&2",
        "    exit 2",
        "  fi",
        "  case \"$value\" in",
        "    *localhost*|*127.0.0.1*|*0.0.0.0*|*'[::1]'*)",
        "      echo \"production evidence env must not point at a local address: $name\" >&2",
        "      exit 2",
        "      ;;",
        "  esac",
        "}",
        "",
        "require_tcp_host() {",
        "  local name=\"$1\"",
        "  local value=\"${!name:-}\"",
        "  if [[ \"$value\" == http://* || \"$value\" == https://* ]]; then",
        "    echo \"production evidence env TCP host must be a host, not a URL: $name\" >&2",
        "    exit 2",
        "  fi",
        "  case \"$value\" in",
        "    localhost|127.*|0.0.0.0|::1|'[::1]')",
        "      echo \"production evidence env TCP host must not be local or wildcard: $name\" >&2",
        "      exit 2",
        "      ;;",
        "  esac",
        "}",
        "",
        "require_tcp_port() {",
        "  local name=\"$1\"",
        "  local value=\"${!name:-}\"",
        "  if [[ ! \"$value\" =~ ^[0-9]+$ ]] || (( value < 1 || value > 65535 )); then",
        "    echo \"production evidence env TCP port must be 1..65535: $name\" >&2",
        "    exit 2",
        "  fi",
        "}",
        "",
        "require_expected_env_value() {",
        "  local name=\"$1\"",
        "  local expected=\"$2\"",
        "  local value=\"${!name:-}\"",
        "  if [[ -n \"$expected\" && \"$value\" != \"$expected\" ]]; then",
        "    echo \"production evidence env target mismatch: $name expected=$expected actual=$value\" >&2",
        "    exit 2",
        "  fi",
        "}",
        "",
        "require_public_target_policy() {",
        "  if [[ ! -f \"$PRODUCTION_TARGET_POLICY\" ]]; then",
        "    echo \"production evidence target policy missing: $PRODUCTION_TARGET_POLICY\" >&2",
        "    exit 2",
        "  fi",
        "  python3 \"$PRODUCTION_TARGET_POLICY\" \\",
        "    --base-url \"$BASE_URL\" \\",
        "    --tcp-host \"$TCP_HOST\" \\",
        "    --tcp-port \"$TCP_PORT\" \\",
        "    --result-prefix production_evidence_recovery_target",
        "}",
        "",
    ]
    for row in plan.get("operatorEnvironmentTemplate") or []:
        lines.append(f"require_recovery_env \"{row['name']}\"")
    lines.extend([
        "",
        "require_https_url \"BASE_URL\"",
        "require_tcp_host \"TCP_HOST\"",
        "require_tcp_port \"TCP_PORT\"",
        "require_expected_env_value \"BASE_URL\" \"$EXPECTED_BASE_URL\"",
        "require_expected_env_value \"TCP_HOST\" \"$EXPECTED_TCP_HOST\"",
        "require_expected_env_value \"TCP_PORT\" \"$EXPECTED_TCP_PORT\"",
        "require_public_target_policy",
        "if [[ \"${PRODUCTION_EVIDENCE_RECOVERY_VALIDATE_ONLY:-false}\" == \"true\" ]]; then",
        "  echo \"production evidence recovery validation passed\"",
        "  exit 0",
        "fi",
        "",
        "echo \"production evidence recovery started: repo=$IMSERVER_REPO_ROOT\"",
    ])
    for command in plan.get("oneShotRecoveryCommands") or []:
        command_text = str(command)
        if command_text == "set -euo pipefail":
            continue
        if command_text.startswith("# "):
            lines.extend(["", command_text, f"echo {shlex.quote('==> ' + command_text[2:].strip())}"])
            continue
        lines.append(command_text)
    lines.append("echo \"production evidence recovery completed\"")
    lines.append("")
    return "\n".join(lines)


def local_missing_diagnostic_suffix(item: dict[str, Any]) -> str:
    details = [
        f"`{field}={item[field]}`"
        for field in ("field", "expected", "actual", "value", "ageSeconds")
        if field in item
    ]
    return f" ({', '.join(details)})" if details else ""


def render_markdown(plan: dict[str, Any]) -> str:
    summary = plan["summary"]
    target = plan.get("productionTarget") if isinstance(plan.get("productionTarget"), dict) else {}
    claim = plan.get("productionClaim") if isinstance(plan.get("productionClaim"), dict) else {}
    tiers = plan.get("readinessTiers") if isinstance(plan.get("readinessTiers"), dict) else {}
    local_tier = tiers.get("localEngineering") if isinstance(tiers.get("localEngineering"), dict) else {}
    live_tier = tiers.get("liveProductionEvidence") if isinstance(tiers.get("liveProductionEvidence"), dict) else {}
    production_tier = tiers.get("productionReady") if isinstance(tiers.get("productionReady"), dict) else {}
    missing_target = ", ".join(f"`{item}`" for item in target.get("missingEnv") or []) or "None"
    claim_blockers = ", ".join(f"`{item}`" for item in claim.get("blockers") or []) or "None"
    lines = [
        "# Production Evidence Recovery Plan",
        "",
        f"- sourceStatus: `{plan['sourceStatus']}`",
        f"- productionReadyClaimAllowed: `{bool(claim.get('claimAllowed'))}`",
        f"- productionReadyClaimLevel: `{claim.get('claimLevel') or 'not-production-ready'}`",
        f"- productionReadyFinalAssertionClaimVerified: `{bool(claim.get('finalAssertionClaimVerified'))}`",
        f"- productionReadyFinalAssertionArchiveClaimVerified: `{bool(claim.get('finalAssertionArchiveClaimVerified'))}`",
        f"- productionReadyClaimBlockers: {claim_blockers}",
        f"- localEngineering: `{summary['localPassed']}/{summary['localTotal']}` (`{summary['localCompletionPercent']}%`)",
        f"- liveEvidence: `{summary['liveEvidencePassed']}/{summary['liveEvidenceTotal']}` (`{summary['liveEvidenceCompletionPercent']}%`)",
        f"- productionCompletion: `{summary['productionCompletionPercent']}%`",
        f"- localEngineeringTier: `{local_tier.get('status') or '-'}` / `{local_tier.get('claim') or '-'}`",
        f"- liveProductionEvidenceTier: `{live_tier.get('status') or '-'}` / `{live_tier.get('claim') or '-'}`",
        f"- productionReadyTier: `{production_tier.get('status') or '-'}` / `{production_tier.get('claim') or '-'}`",
        f"- targetBaseURL: `{target.get('baseURL') or '-'}`",
        f"- targetTCP: `{target.get('tcpHost') or '-'}:{target.get('tcpPort') or '-'}`",
        f"- targetMissingEnv: {missing_target}",
        f"- readyToClaimProduction: `{plan['readyToClaimProduction']}`",
        "",
        "Do not claim production readiness until every step below is complete, claimAllowed is true, and the final assertion plus archive production claims verify.",
        "",
    ]
    local_missing = plan.get("localMissing") or []
    if local_missing:
        lines.extend([
            "## Local Gate First",
            "",
            "Live evidence recovery is blocked until the local production gate is complete.",
            "",
        ])
        for item in local_missing:
            name = str(item.get("item") or "-")
            reason = str(item.get("reason") or "-")
            path = str(item.get("path") or "")
            detail = f"- `{name}`: `{reason}`"
            if path:
                detail = f"{detail} (`{path}`)"
            detail = f"{detail}{local_missing_diagnostic_suffix(item)}"
            lines.append(detail)
        if any(str(item.get("reason") or "") == "production_static_gate_git_dirty" for item in local_missing):
            lines.extend([
                "",
                "Commit or remove local changes, then rerun `make validate-production-static` to regenerate a clean production static receipt.",
            ])
        else:
            lines.extend([
                "",
                "Run `make validate-production-static` and regenerate `make production-completion-status` before collecting live evidence.",
            ])
        lines.append("")
    steps = plan.get("steps") or []
    if not steps:
        lines.extend([
            "## Live Evidence",
            "",
            "No missing live evidence steps were reported by the source completion status.",
            "",
        ])
    else:
        lines.extend(["## Live Evidence Steps", ""])
        for index, step in enumerate(steps, start=1):
            required_env = " ".join(f"${name}" for name in step["requiredEnv"])
            lines.extend([
                f"### {index}. {step['item']}",
                "",
                f"- reason: `{step['reason']}`",
                f"- requiredEnv: `{required_env}`",
                f"- run: `{step['runCommand']}`",
                f"- verify: `{step['verifyCommand']}`",
                "",
            ])
    env_template = plan.get("operatorEnvironmentTemplate") or []
    lines.extend(["## Operator Environment Template", "", "```sh"])
    for row in env_template:
        lines.append(f"export {row['name']}=\"{row['example']}\"")
    lines.extend(["```", ""])
    lines.extend(["## One-shot Recovery Sequence", "", "```sh"])
    for command in plan.get("oneShotRecoveryCommands") or []:
        lines.append(str(command))
    lines.extend(["```", ""])
    lines.extend([
        "## Executable Recovery Script",
        "",
        "The generated `evidence-recovery-run.sh` script is derived from this plan, refuses empty or placeholder environment values, and runs the same ordered commands.",
        "Set `PRODUCTION_EVIDENCE_RECOVERY_VALIDATE_ONLY=true` to validate required environment variables and the shared public production target policy without running any recovery commands.",
        "",
    ])
    lines.extend(["## Final Verification", ""])
    for command in plan["finalVerificationCommands"]:
        lines.append(f"- `{command}`")
    lines.append("")
    return "\n".join(lines)


def write_text(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(value, encoding="utf-8")
    tmp.replace(path)


def write_json(path: Path, payload: dict[str, Any]) -> None:
    write_text(path, json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n")


def write_script(path: Path, payload: dict[str, Any]) -> None:
    write_text(path, render_shell_script(payload))
    path.chmod(path.stat().st_mode | 0o755)


def expect_exit(label: str, fn: Any) -> None:
    try:
        fn()
    except SystemExit:
        print(label)
        return
    fail("self_test_expected_failure_missing", label=label)


def recovery_validate_only_env(plan: dict[str, Any], repo_root: Path, **overrides: str) -> dict[str, str]:
    env = os.environ.copy()
    env["IMSERVER_REPO_ROOT"] = str(repo_root)
    env["PRODUCTION_TARGET_POLICY"] = str(Path(__file__).resolve().with_name("production_target_policy.py"))
    env["PRODUCTION_EVIDENCE_RECOVERY_VALIDATE_ONLY"] = "true"
    for row in plan.get("operatorEnvironmentTemplate") or []:
        env[str(row["name"])] = str(row["example"])
    env.update(overrides)
    return env


def run_recovery_validate_only(script_path: Path, plan: dict[str, Any], repo_root: Path, **overrides: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(script_path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=recovery_validate_only_env(plan, repo_root, **overrides),
    )


def refresh_status_readiness_tiers(status: dict[str, Any]) -> None:
    summary = status.get("summary") or {}
    claim = status.get("productionClaim") or {}
    status["readinessTiers"] = production_completion_status.readiness_tiers(
        ready=bool(claim.get("productionReady")),
        claim=claim,
        local_pass=int(summary.get("localPassed", 0)),
        local_total=int(summary.get("localTotal", 0)),
        evidence_pass=int(summary.get("liveEvidencePassed", 0)),
        evidence_total=int(summary.get("liveEvidenceTotal", 0)),
        local_completion=int(status.get("localCompletionPercent", 0)),
        live_completion=int(status.get("liveEvidenceCompletionPercent", 0)),
        production_completion=int(status.get("productionCompletionPercent", 0)),
    )


def run_self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="production-evidence-recovery-plan-") as tmp:
        root = Path(tmp)
        (root / "Makefile").write_text("self-test:\n\t@true\n", encoding="utf-8")
        (root / "IMServer" / "LoadTests").mkdir(parents=True, exist_ok=True)
        status_path = root / "completion.json"
        incomplete = verify_production_completion_status.valid_report(ready=False)
        incomplete["repoRoot"] = str(root)
        write_json(status_path, incomplete)
        verified = verify_completion_status(status_path, root, max_age_seconds=3600)
        plan = build_plan(verified, status_json=status_path, allow_local_incomplete=False)
        verify_plan(plan, verified)
        if plan.get("productionTarget") != incomplete.get("productionTarget"):
            fail("self_test_production_target_not_copied")
        markdown = render_markdown(plan)
        plan_json_path = root / "plan.json"
        plan_md_path = root / "plan.md"
        plan_script_path = root / "plan.sh"
        write_json(plan_json_path, plan)
        write_text(plan_md_path, markdown)
        write_script(plan_script_path, plan)
        verify_recovery_artifacts(
            plan_json_path=plan_json_path,
            markdown_path=plan_md_path,
            script_path=plan_script_path,
            status=verified,
            max_age_seconds=3600,
            max_future_skew_seconds=300,
        )
        if "make assert-production-ready" not in markdown or "final-assertion-archive" not in markdown:
            fail("self_test_markdown_missing_recovery_detail")
        if "productionReadyClaimAllowed: `False`" not in markdown:
            fail("self_test_markdown_missing_claim_allowed")
        if "productionReadyFinalAssertionClaimVerified: `False`" not in markdown:
            fail("self_test_markdown_missing_final_assertion_claim")
        if "productionReadyFinalAssertionArchiveClaimVerified: `False`" not in markdown:
            fail("self_test_markdown_missing_final_archive_claim")
        if "claimAllowed is true" not in markdown or "final assertion plus archive production claims verify" not in markdown:
            fail("self_test_markdown_missing_claim_guard")
        if "## Operator Environment Template" not in markdown or "export BASE_URL=" not in markdown:
            fail("self_test_operator_env_template_missing")
        if "## One-shot Recovery Sequence" not in markdown or "set -euo pipefail" not in markdown:
            fail("self_test_one_shot_recovery_missing")
        script = plan_script_path.read_text(encoding="utf-8")
        if "require_recovery_env \"BASE_URL\"" not in script or "placeholder production evidence env is not allowed" not in script:
            fail("self_test_recovery_script_missing_guard")
        if "require_https_url \"BASE_URL\"" not in script or "require_tcp_port \"TCP_PORT\"" not in script:
            fail("self_test_recovery_script_missing_target_validation")
        if (
            "PRODUCTION_TARGET_POLICY=\"${PRODUCTION_TARGET_POLICY:-IMServer/LoadTests/production_target_policy.py}\"" not in script
            or "require_public_target_policy()" not in script
            or "--result-prefix production_evidence_recovery_target" not in script
        ):
            fail("self_test_recovery_script_missing_public_target_policy")
        valid_policy_run = run_recovery_validate_only(
            plan_script_path,
            plan,
            root,
            BASE_URL="https://chat.myim-prod.com",
            TCP_HOST="tcp.myim-prod.com",
            TCP_PORT="9000",
        )
        if valid_policy_run.returncode != 0 or "production evidence recovery validation passed" not in valid_policy_run.stdout:
            fail(
                "self_test_recovery_validate_only_valid_target_failed",
                stdout=valid_policy_run.stdout.strip() or "-",
                stderr=valid_policy_run.stderr.strip() or "-",
                status=valid_policy_run.returncode,
            )
        placeholder_policy_run = run_recovery_validate_only(
            plan_script_path,
            plan,
            root,
            BASE_URL="https://chat.yourdomain.com",
            TCP_HOST="tcp.yourdomain.com",
            TCP_PORT="9000",
        )
        placeholder_policy_output = f"{placeholder_policy_run.stdout}\n{placeholder_policy_run.stderr}"
        if placeholder_policy_run.returncode == 0:
            fail("self_test_recovery_validate_only_placeholder_target_passed")
        if "production_evidence_recovery_target result=fail" not in placeholder_policy_output or "hostReason=placeholder" not in placeholder_policy_output:
            fail(
                "self_test_recovery_validate_only_placeholder_reason_missing",
                stdout=placeholder_policy_run.stdout.strip() or "-",
                stderr=placeholder_policy_run.stderr.strip() or "-",
            )
        if "PRODUCTION_EVIDENCE_RECOVERY_VALIDATE_ONLY" not in script or "production evidence recovery validation passed" not in script:
            fail("self_test_recovery_script_missing_validate_only")
        if "production evidence recovery started" not in script or "production evidence recovery failed: line=" not in script:
            fail("self_test_recovery_script_missing_progress_logs")
        if "make package-production-ready-assertion" not in script:
            fail("self_test_recovery_script_missing_command")
        if len(plan["steps"]) != len(production_completion_status.EVIDENCE_CONTRACTS):
            fail("self_test_step_count_mismatch")
        if plan["steps"][0]["item"] != "deploy-readiness":
            fail("self_test_first_step_mismatch")
        if plan["steps"][-1]["item"] != "final-assertion-archive":
            fail("self_test_final_archive_not_last")
        print("self_test_incomplete_status_plan")

        target_bound = verify_production_completion_status.valid_report(ready=False)
        target_bound["repoRoot"] = str(root)
        target_bound["productionTarget"] = {
            "baseURL": "https://chat.myim-prod.com",
            "tcpHost": "tcp.myim-prod.com",
            "tcpPort": "9000",
            "missingEnv": [],
        }
        target_bound["productionClaim"]["targetComplete"] = True
        target_bound["productionClaim"]["blockers"] = [
            blocker
            for blocker in target_bound["productionClaim"]["blockers"]
            if blocker != "production-target-incomplete"
        ]
        refresh_status_readiness_tiers(target_bound)
        target_bound_path = root / "target-bound.json"
        write_json(target_bound_path, target_bound)
        target_bound_verified = verify_completion_status(target_bound_path, root, max_age_seconds=3600)
        target_bound_plan = build_plan(target_bound_verified, status_json=target_bound_path, allow_local_incomplete=False)
        target_env_examples = {
            row["name"]: row["example"]
            for row in target_bound_plan["operatorEnvironmentTemplate"]
            if row["name"] in {"BASE_URL", "TCP_HOST", "TCP_PORT"}
        }
        if target_env_examples != {
            "BASE_URL": "https://chat.myim-prod.com",
            "TCP_HOST": "tcp.myim-prod.com",
            "TCP_PORT": "9000",
        }:
            fail("self_test_target_env_template_mismatch")
        target_bound_markdown = render_markdown(target_bound_plan)
        if "targetBaseURL: `https://chat.myim-prod.com`" not in target_bound_markdown or "targetTCP: `tcp.myim-prod.com:9000`" not in target_bound_markdown:
            fail("self_test_target_markdown_missing")
        target_bound_script = render_shell_script(target_bound_plan)
        if "EXPECTED_BASE_URL=https://chat.myim-prod.com" not in target_bound_script:
            fail("self_test_expected_base_url_missing")
        if "EXPECTED_TCP_HOST=tcp.myim-prod.com" not in target_bound_script or "EXPECTED_TCP_PORT=9000" not in target_bound_script:
            fail("self_test_expected_tcp_target_missing")
        if "production evidence env target mismatch" not in target_bound_script:
            fail("self_test_target_mismatch_guard_missing")
        target_bound_script_path = root / "target-bound-plan.sh"
        write_script(target_bound_script_path, target_bound_plan)
        valid_bound_target_run = run_recovery_validate_only(target_bound_script_path, target_bound_plan, root)
        if valid_bound_target_run.returncode != 0 or "production evidence recovery validation passed" not in valid_bound_target_run.stdout:
            fail(
                "self_test_recovery_validate_only_bound_target_failed",
                stdout=valid_bound_target_run.stdout.strip() or "-",
                stderr=valid_bound_target_run.stderr.strip() or "-",
                status=valid_bound_target_run.returncode,
            )
        mismatched_bound_target_run = run_recovery_validate_only(
            target_bound_script_path,
            target_bound_plan,
            root,
            BASE_URL="https://other.myim-prod.com",
        )
        mismatched_bound_target_output = f"{mismatched_bound_target_run.stdout}\n{mismatched_bound_target_run.stderr}"
        if mismatched_bound_target_run.returncode == 0:
            fail("self_test_recovery_validate_only_bound_target_mismatch_passed")
        if "production evidence env target mismatch: BASE_URL" not in mismatched_bound_target_output:
            fail(
                "self_test_recovery_validate_only_bound_target_mismatch_reason_missing",
                stdout=mismatched_bound_target_run.stdout.strip() or "-",
                stderr=mismatched_bound_target_run.stderr.strip() or "-",
            )
        print("self_test_target_bound_plan")

        ready = verify_production_completion_status.valid_report(ready=True)
        ready["repoRoot"] = str(root)
        ready_path = root / "ready.json"
        write_json(ready_path, ready)
        ready_verified = verify_completion_status(ready_path, root, max_age_seconds=3600)
        ready_plan = build_plan(ready_verified, status_json=ready_path, allow_local_incomplete=False)
        if ready_plan["steps"] or not ready_plan["readyToClaimProduction"]:
            fail("self_test_ready_status_plan_mismatch")
        if ready_plan.get("productionClaim") != production_claim_from_status(ready_verified):
            fail("self_test_ready_production_claim_not_copied")
        ready_markdown = render_markdown(ready_plan)
        if "productionReadyClaimAllowed: `True`" not in ready_markdown:
            fail("self_test_ready_markdown_missing_claim_allowed")
        if "productionReadyFinalAssertionClaimVerified: `True`" not in ready_markdown:
            fail("self_test_ready_markdown_missing_final_assertion_claim")
        print("self_test_ready_status_plan")

        duplicate = json.loads(json.dumps(plan))
        duplicate["steps"].append(duplicate["steps"][0])
        expect_exit("self_test_duplicate_step_rejected", lambda: verify_plan(duplicate, verified))

        target_mismatch = json.loads(json.dumps(plan))
        target_mismatch["productionTarget"]["tcpHost"] = "other.myim-prod.com"
        expect_exit("self_test_production_target_mismatch_rejected", lambda: verify_plan(target_mismatch, verified))

        target_type_mismatch_status = json.loads(json.dumps(verified))
        target_type_mismatch_status["productionTarget"]["tcpPort"] = 9000
        expect_exit(
            "self_test_production_target_type_rejected",
            lambda: build_plan(target_type_mismatch_status, status_json=status_path, allow_local_incomplete=False),
        )

        claim_mismatch = json.loads(json.dumps(plan))
        claim_mismatch["productionClaim"]["claimAllowed"] = True
        expect_exit("self_test_production_claim_mismatch_rejected", lambda: verify_plan(claim_mismatch, verified))

        claim_type_mismatch_status = json.loads(json.dumps(verified))
        claim_type_mismatch_status["productionClaim"]["claimAllowed"] = "false"
        expect_exit(
            "self_test_production_claim_type_rejected",
            lambda: build_plan(claim_type_mismatch_status, status_json=status_path, allow_local_incomplete=False),
        )

        summary_count_type_mismatch_status = json.loads(json.dumps(verified))
        summary_count_type_mismatch_status["summary"]["localPassed"] = "64"
        expect_exit(
            "self_test_summary_count_type_rejected",
            lambda: build_plan(summary_count_type_mismatch_status, status_json=status_path, allow_local_incomplete=False),
        )

        completion_percent_type_mismatch_status = json.loads(json.dumps(verified))
        completion_percent_type_mismatch_status["productionCompletionPercent"] = "75"
        expect_exit(
            "self_test_completion_percent_type_rejected",
            lambda: build_plan(completion_percent_type_mismatch_status, status_json=status_path, allow_local_incomplete=False),
        )

        readiness_tiers_mismatch = json.loads(json.dumps(plan))
        readiness_tiers_mismatch["readinessTiers"]["productionReady"]["status"] = "ready"
        expect_exit(
            "self_test_readiness_tiers_mismatch_rejected",
            lambda: verify_plan(readiness_tiers_mismatch, verified),
        )

        missing_required_evidence_status = json.loads(json.dumps(verified))
        del missing_required_evidence_status["productionClaim"]["requiredEvidence"]
        expect_exit(
            "self_test_production_claim_required_evidence_rejected",
            lambda: build_plan(missing_required_evidence_status, status_json=status_path, allow_local_incomplete=False),
        )

        mismatched_required_evidence_status = json.loads(json.dumps(verified))
        mismatched_required_evidence_status["productionClaim"]["requiredEvidence"] = list(reversed(
            mismatched_required_evidence_status["productionClaim"]["requiredEvidence"]
        ))
        expect_exit(
            "self_test_production_claim_required_evidence_mismatch_rejected",
            lambda: build_plan(mismatched_required_evidence_status, status_json=status_path, allow_local_incomplete=False),
        )

        missing_verify = json.loads(json.dumps(plan))
        missing_verify["steps"][0]["verifyCommand"] = ""
        expect_exit("self_test_missing_verify_rejected", lambda: verify_plan(missing_verify, verified))

        missing_env_template = json.loads(json.dumps(plan))
        missing_env_template["operatorEnvironmentTemplate"] = missing_env_template["operatorEnvironmentTemplate"][1:]
        expect_exit(
            "self_test_missing_operator_env_template_rejected",
            lambda: verify_plan(missing_env_template, verified),
        )

        reordered_one_shot = json.loads(json.dumps(plan))
        reordered_one_shot["oneShotRecoveryCommands"][1], reordered_one_shot["oneShotRecoveryCommands"][2] = (
            reordered_one_shot["oneShotRecoveryCommands"][2],
            reordered_one_shot["oneShotRecoveryCommands"][1],
        )
        expect_exit(
            "self_test_reordered_one_shot_recovery_rejected",
            lambda: verify_plan(reordered_one_shot, verified),
        )

        markdown_mismatch_path = root / "plan-mismatch.md"
        write_text(markdown_mismatch_path, markdown + "\nextra\n")
        expect_exit(
            "self_test_artifact_markdown_mismatch_rejected",
            lambda: verify_recovery_artifacts(
                plan_json_path=plan_json_path,
                markdown_path=markdown_mismatch_path,
                script_path=plan_script_path,
                status=verified,
                max_age_seconds=3600,
                max_future_skew_seconds=300,
            ),
        )
        script_mismatch_path = root / "plan-mismatch.sh"
        write_text(script_mismatch_path, render_shell_script(plan) + "\n# drift\n")
        script_mismatch_path.chmod(0o755)
        expect_exit(
            "self_test_artifact_script_mismatch_rejected",
            lambda: verify_recovery_artifacts(
                plan_json_path=plan_json_path,
                markdown_path=plan_md_path,
                script_path=script_mismatch_path,
                status=verified,
                max_age_seconds=3600,
                max_future_skew_seconds=300,
            ),
        )
        non_executable_script = root / "plan-not-executable.sh"
        write_text(non_executable_script, render_shell_script(plan))
        non_executable_script.chmod(0o644)
        expect_exit(
            "self_test_artifact_script_not_executable_rejected",
            lambda: verify_recovery_artifacts(
                plan_json_path=plan_json_path,
                markdown_path=plan_md_path,
                script_path=non_executable_script,
                status=verified,
                max_age_seconds=3600,
                max_future_skew_seconds=300,
            ),
        )
        invalid_syntax_script = root / "plan-invalid-syntax.sh"
        write_text(invalid_syntax_script, "#!/usr/bin/env bash\nif true; then\n")
        invalid_syntax_script.chmod(0o755)
        expect_exit(
            "self_test_artifact_script_syntax_rejected",
            lambda: verify_shell_script_syntax(invalid_syntax_script),
        )

        local_incomplete = verify_production_completion_status.valid_report(ready=False)
        local_incomplete["repoRoot"] = str(root)
        local_incomplete["localChecks"][0]["status"] = "fail"
        local_incomplete["localChecks"][0]["reason"] = "missing_marker"
        local_incomplete["missing"].append({
            "scope": "local",
            "item": local_incomplete["localChecks"][0]["item"],
            "reason": "missing_marker",
            "path": "",
        })
        local_incomplete["summary"]["localPassed"] -= 1
        local_incomplete["summary"]["localMissingCount"] += 1
        local_incomplete["summary"]["missingCount"] += 1
        local_incomplete["localCompletionPercent"] = verify_production_completion_status.percent(
            local_incomplete["summary"]["localPassed"],
            local_incomplete["summary"]["localTotal"],
        )
        local_incomplete["productionClaim"]["localEngineeringComplete"] = False
        if "local-engineering-incomplete" not in local_incomplete["productionClaim"]["blockers"]:
            local_incomplete["productionClaim"]["blockers"].insert(0, "local-engineering-incomplete")
        local_incomplete["productionCompletionPercent"] = round(
            (
                local_incomplete["localCompletionPercent"] * verify_production_completion_status.EXPECTED_LOCAL_ENGINEERING_WEIGHT
                + local_incomplete["liveEvidenceCompletionPercent"] * verify_production_completion_status.EXPECTED_LIVE_PRODUCTION_EVIDENCE_WEIGHT
            )
            / 100
        )
        refresh_status_readiness_tiers(local_incomplete)
        local_incomplete_path = root / "local-incomplete.json"
        write_json(local_incomplete_path, local_incomplete)
        local_incomplete_verified = verify_completion_status(local_incomplete_path, root, max_age_seconds=3600)
        expect_exit(
            "self_test_local_incomplete_rejected",
            lambda: build_plan(local_incomplete_verified, status_json=local_incomplete_path, allow_local_incomplete=False),
        )
        local_allowed_plan = build_plan(local_incomplete_verified, status_json=local_incomplete_path, allow_local_incomplete=True)
        local_allowed_markdown = render_markdown(local_allowed_plan)
        if "Live evidence recovery is blocked until the local production gate is complete." not in local_allowed_markdown:
            fail("self_test_local_gate_blocker_markdown_missing")
        if "`missing_marker`" not in local_allowed_markdown:
            fail("self_test_local_missing_reason_markdown_missing")
        missing_local_plan = json.loads(json.dumps(local_allowed_plan))
        missing_local_plan["localMissing"] = []
        expect_exit(
            "self_test_missing_local_missing_rejected",
            lambda: verify_plan(missing_local_plan, local_incomplete_verified),
        )

        dirty_static_status = verify_production_completion_status.valid_report(ready=False)
        dirty_static_status["repoRoot"] = str(root)
        for row in dirty_static_status["localChecks"]:
            if row["item"] == "local-static-gate-receipt":
                row["status"] = "fail"
                row["reason"] = "production_static_gate_git_dirty"
                row["path"] = str(root / "IMServer/LoadTests/results/production-static/latest.json")
                row["field"] = "dirtyCount"
                row["expected"] = 242
                row["actual"] = 241
                break
        else:
            fail("self_test_dirty_static_local_row_missing")
        dirty_static_status["missing"].append({
            "scope": "local",
            "item": "local-static-gate-receipt",
            "reason": "production_static_gate_git_dirty",
            "path": str(root / "IMServer/LoadTests/results/production-static/latest.json"),
            "field": "dirtyCount",
            "expected": 242,
            "actual": 241,
        })
        dirty_static_status["summary"]["localPassed"] -= 1
        dirty_static_status["summary"]["localMissingCount"] += 1
        dirty_static_status["summary"]["missingCount"] += 1
        dirty_static_status["localCompletionPercent"] = verify_production_completion_status.percent(
            dirty_static_status["summary"]["localPassed"],
            dirty_static_status["summary"]["localTotal"],
        )
        dirty_static_status["productionClaim"]["localEngineeringComplete"] = False
        if "local-engineering-incomplete" not in dirty_static_status["productionClaim"]["blockers"]:
            dirty_static_status["productionClaim"]["blockers"].insert(0, "local-engineering-incomplete")
        dirty_static_status["productionCompletionPercent"] = round(
            (
                dirty_static_status["localCompletionPercent"] * verify_production_completion_status.EXPECTED_LOCAL_ENGINEERING_WEIGHT
                + dirty_static_status["liveEvidenceCompletionPercent"] * verify_production_completion_status.EXPECTED_LIVE_PRODUCTION_EVIDENCE_WEIGHT
            )
            / 100
        )
        dirty_static_status["nextActions"] = production_completion_status.next_actions(dirty_static_status["missing"])
        refresh_status_readiness_tiers(dirty_static_status)
        dirty_static_path = root / "dirty-static-gate.json"
        write_json(dirty_static_path, dirty_static_status)
        dirty_static_verified = verify_completion_status(dirty_static_path, root, max_age_seconds=3600)
        dirty_static_plan = build_plan(dirty_static_verified, status_json=dirty_static_path, allow_local_incomplete=True)
        dirty_static_markdown = render_markdown(dirty_static_plan)
        if "Commit or remove local changes, then rerun `make validate-production-static`" not in dirty_static_markdown:
            fail("self_test_dirty_static_gate_markdown_missing")
        if "`field=dirtyCount`" not in dirty_static_markdown or "`expected=242`" not in dirty_static_markdown or "`actual=241`" not in dirty_static_markdown:
            fail("self_test_dirty_static_gate_diagnostic_markdown_missing")
        mismatched_local_plan = json.loads(json.dumps(dirty_static_plan))
        mismatched_local_plan["localMissing"][0]["actual"] = 240
        expect_exit(
            "self_test_mismatched_local_missing_rejected",
            lambda: verify_plan(mismatched_local_plan, dirty_static_verified),
        )

    print("production_evidence_recovery_plan_self_test result=pass")


def main() -> int:
    parser = argparse.ArgumentParser(description="Render the ordered live production evidence recovery plan.")
    parser.add_argument("--status-json", default=DEFAULT_STATUS_JSON)
    parser.add_argument("--output", default=DEFAULT_MARKDOWN_OUTPUT)
    parser.add_argument("--json-output", default=DEFAULT_JSON_OUTPUT)
    parser.add_argument("--script-output", default=DEFAULT_SCRIPT_OUTPUT)
    parser.add_argument("--repo-root", default=str(Path(__file__).resolve().parents[2]))
    parser.add_argument("--max-age-seconds", type=int, default=24 * 60 * 60)
    parser.add_argument("--max-future-skew-seconds", type=int, default=300)
    parser.add_argument("--allow-local-incomplete", action="store_true")
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        run_self_test()
        return 0

    repo_root = Path(args.repo_root).expanduser().resolve()
    status_path = (repo_root / args.status_json).resolve() if not Path(args.status_json).is_absolute() else Path(args.status_json)
    markdown_path = (repo_root / args.output).resolve() if not Path(args.output).is_absolute() else Path(args.output)
    json_path = (repo_root / args.json_output).resolve() if not Path(args.json_output).is_absolute() else Path(args.json_output)
    script_path = (repo_root / args.script_output).resolve() if not Path(args.script_output).is_absolute() else Path(args.script_output)
    status = verify_completion_status(status_path, repo_root, max_age_seconds=args.max_age_seconds)
    if args.verify:
        plan = verify_recovery_artifacts(
            plan_json_path=json_path,
            markdown_path=markdown_path,
            script_path=script_path,
            status=status,
            max_age_seconds=args.max_age_seconds,
            max_future_skew_seconds=args.max_future_skew_seconds,
        )
        print(
            "production_evidence_recovery_plan_verify result=pass "
            f"steps={len(plan['steps'])} readyToClaimProduction={plan['readyToClaimProduction']} "
            f"markdown={markdown_path} json={json_path}"
        )
        return 0
    plan = build_plan(status, status_json=status_path, allow_local_incomplete=args.allow_local_incomplete)
    write_json(json_path, plan)
    write_text(markdown_path, render_markdown(plan))
    write_script(script_path, plan)
    print(
        "production_evidence_recovery_plan result=pass "
        f"steps={len(plan['steps'])} readyToClaimProduction={plan['readyToClaimProduction']} "
        f"markdown={markdown_path} json={json_path}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
