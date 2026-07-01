#!/usr/bin/env python3
from __future__ import annotations

import shlex
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

LOAD_TEST_DIR = Path(__file__).resolve().parent
ZERO_CONVERSATION_ID = "00000000-0000-0000-0000-000000000000"


def shell_assign(name: str, value: str) -> str:
    return f"{name}={shlex.quote(value)}"


def shell_secret_assign(name: str) -> str:
    return f"{name}=${{{name}:?set-{name}}}"


def shell_required_value_assign(name: str, source_name: str) -> str:
    return f"{name}=${{{source_name}:?set-{source_name}}}"


def shell_required_assign(name: str) -> str:
    return f"{name}=${{{name}:?set-{name}}}"


def shell_required_value(name: str) -> str:
    return f"${{{name}:?set-{name}}}"


def production_gate_result_root(args: Any) -> str:
    if not bool(getattr(args, "absolute_result_root_command", False)):
        return "results/production-acceptance"
    value = str(getattr(args, "production_gate_json", "") or "")
    if not value:
        return ""
    try:
        return str(Path(value).resolve().parent)
    except Exception:
        return ""


def portable_loadtest_path(value: str) -> str:
    if not value:
        return ""
    try:
        path = Path(value).expanduser().resolve()
        return str(path.relative_to(LOAD_TEST_DIR))
    except Exception:
        return value


def is_placeholder_host(value: str) -> bool:
    host = value.strip().lower().strip("[]")
    return (
        not host
        or host in {
            "localhost",
            "127.0.0.1",
            "::1",
            "0.0.0.0",
            "im.example.com",
            "example.com",
            "example.net",
            "example.org",
            "yourdomain.com",
        }
        or host.endswith((
            ".example",
            ".example.com",
            ".example.net",
            ".example.org",
            ".yourdomain.com",
            ".test",
            ".invalid",
        ))
    )


def is_placeholder_base_url(value: str) -> bool:
    text = value.strip()
    if not text:
        return True
    parsed = urlparse(text)
    return parsed.scheme not in {"http", "https"} or is_placeholder_host(parsed.hostname or "")


def is_placeholder_account_file(value: str) -> bool:
    text = portable_loadtest_path(value).strip()
    return (
        not text
        or text in {"accounts/load-1000.csv", "../accounts/load-1000.csv"}
        or text.endswith("/accounts/load-1000.csv")
    )


def is_placeholder_conversation_id(value: str) -> bool:
    text = value.strip().lower()
    return not text or text == ZERO_CONVERSATION_ID


def production_profile_target_assign(name: str, value: str, required_name: str, placeholder: bool) -> str:
    if not placeholder and value:
        return shell_assign(name, value)
    return shell_required_value_assign(name, required_name)


def build_production_profile_command(args: Any, production_gate: dict[str, Any], run_plan: dict[str, Any]) -> str:
    profile = str(production_gate.get("profile") or "")
    if not profile:
        return ""
    requirements = production_gate.get("requirements") or {}
    target = run_plan.get("target") if isinstance(run_plan.get("target"), dict) else {}
    parts: list[str] = []
    result_root = production_gate_result_root(args)
    if result_root:
        parts.append(shell_assign("RESULT_ROOT", result_root))
    parts.append(shell_assign("PERF_PRODUCTION_GATE_PROFILE", profile))
    parts.append(shell_assign("PERF_PRODUCTION_GATE_MAX_AGE_SECONDS", str(requirements.get("maxEvidenceAgeSeconds", 0))))
    parts.append("PERF_STATUS_FILTER_TARGET=true")
    overrides = {
        "baseURL": str(getattr(args, "base_url", "") or ""),
        "tcpHost": str(getattr(args, "tcp_host", "") or ""),
        "tcpPort": str(getattr(args, "tcp_port", "") or ""),
        "accountFile": portable_loadtest_path(str(getattr(args, "account_file", "") or "")),
        "conversationID": str(getattr(args, "conversation_id", "") or ""),
    }
    base_url = overrides.get("baseURL") or str(target.get("baseURL") or "")
    tcp_host = overrides.get("tcpHost") or str(target.get("tcpHost") or "")
    tcp_port = overrides.get("tcpPort") or str(target.get("tcpPort") or "")
    account_file = overrides.get("accountFile") or str(target.get("accountFile") or "")
    conversation_id = overrides.get("conversationID") or str(target.get("conversationID") or "")
    account_file = portable_loadtest_path(account_file)
    parts.extend([
        production_profile_target_assign(
            "BASE_URL",
            base_url,
            "PRODUCTION_PROFILE_BASE_URL",
            is_placeholder_base_url(base_url),
        ),
        production_profile_target_assign(
            "TCP_HOST",
            tcp_host,
            "PRODUCTION_PROFILE_TCP_HOST",
            is_placeholder_host(tcp_host),
        ),
        production_profile_target_assign(
            "TCP_PORT",
            tcp_port,
            "PRODUCTION_PROFILE_TCP_PORT",
            not tcp_port.strip(),
        ),
        production_profile_target_assign(
            "ACCOUNT_FILE",
            account_file,
            "PRODUCTION_PROFILE_ACCOUNT_FILE",
            is_placeholder_account_file(account_file),
        ),
        production_profile_target_assign(
            "IM_CONVERSATION_ID",
            conversation_id,
            "PRODUCTION_PROFILE_CONVERSATION_ID",
            is_placeholder_conversation_id(conversation_id),
        ),
    ])
    if bool(getattr(args, "require_internal_secret", False)) or bool(target.get("hasInternalSecret")):
        parts.append(shell_secret_assign("IM_INTERNAL_SECRET"))
    parts.extend([
        "PRODUCTION_PROFILE_REQUIRE_CLOUD_SECURITY_GROUP=true",
        "PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS=86400",
        "PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080=false",
        shell_required_assign("PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_FILE"),
        shell_required_assign("PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON"),
        shell_required_assign("PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID"),
        shell_required_assign("PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID"),
        shell_required_assign("PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR"),
    ])
    parts.append("./run_production_profile.sh")
    return f"(cd IMServer/LoadTests && {' '.join(parts)})"


def build_production_acceptance_command(args: Any, production_gate: dict[str, Any], run_plan: dict[str, Any]) -> str:
    parts: list[str] = []
    result_root = production_gate_result_root(args)
    if result_root:
        parts.append(shell_assign("PRODUCTION_ACCEPTANCE_RESULT_ROOT", result_root))
    parts.append(shell_assign("PRODUCTION_ACCEPTANCE_LEVEL", "full"))
    parts.append("PRODUCTION_ACCEPTANCE_PACKAGE_EVIDENCE=true")
    parts.append(shell_assign("PRODUCTION_ACCEPTANCE_RECEIPT_MAX_AGE_SECONDS", "86400"))
    parts.append(shell_assign("PRODUCTION_ACCEPTANCE_RECEIPT_MAX_FUTURE_SKEW_SECONDS", "300"))
    parts.append(shell_assign("PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS", "86400"))
    parts.append(f"BASE_URL={shell_required_value('PRODUCTION_ACCEPTANCE_BASE_URL')}")
    parts.append(f"TCP_HOST={shell_required_value('PRODUCTION_ACCEPTANCE_TCP_HOST')}")
    parts.append(f"TCP_PORT={shell_required_value('PRODUCTION_ACCEPTANCE_TCP_PORT')}")
    parts.append(f"ACCOUNT_FILE={shell_required_value('PRODUCTION_ACCEPTANCE_ACCOUNT_FILE')}")
    parts.append(f"IM_CONVERSATION_ID={shell_required_value('PRODUCTION_ACCEPTANCE_CONVERSATION_ID')}")
    parts.extend([
        shell_required_assign("IM_INTERNAL_SECRET"),
        shell_required_assign("PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_RULES_FILE"),
        shell_required_assign("PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON"),
        shell_required_assign("PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID"),
        shell_required_assign("PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID"),
        shell_required_assign("PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR"),
    ])
    parts.append("./run_production_acceptance.sh")
    return f"(cd IMServer/LoadTests && {' '.join(parts)})"


def build_current_production_readiness_command(args: Any, run_plan: dict[str, Any]) -> str:
    target = run_plan.get("target") if isinstance(run_plan.get("target"), dict) else {}
    result_root = production_gate_result_root(args)
    parts: list[str] = []
    if result_root:
        parts.append(shell_assign("RESULT_ROOT", result_root))
    parts.extend([
        "CURRENT_PRODUCTION_RUN_SMOKE=true",
        "CURRENT_PRODUCTION_RUN_SCENARIO_SUITE=true",
        "CURRENT_PRODUCTION_RUN_BASELINE=false",
        "CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE=false",
        "CURRENT_PRODUCTION_REQUIRE_PACKAGEABLE_EVIDENCE=true",
        "CURRENT_PRODUCTION_OPERATOR_NETWORK_PREFLIGHT=true",
        "CURRENT_PRODUCTION_FAIL_ON_OPERATOR_NETWORK=true",
    ])
    overrides = {
        "baseURL": str(getattr(args, "base_url", "") or ""),
        "tcpHost": str(getattr(args, "tcp_host", "") or ""),
        "tcpPort": str(getattr(args, "tcp_port", "") or ""),
        "accountFile": portable_loadtest_path(str(getattr(args, "account_file", "") or "")),
        "conversationID": str(getattr(args, "conversation_id", "") or ""),
    }
    base_url = overrides.get("baseURL") or str(target.get("baseURL") or "")
    tcp_host = overrides.get("tcpHost") or str(target.get("tcpHost") or "")
    tcp_port = overrides.get("tcpPort") or str(target.get("tcpPort") or "")
    account_file = portable_loadtest_path(overrides.get("accountFile") or str(target.get("accountFile") or ""))
    conversation_id = overrides.get("conversationID") or str(target.get("conversationID") or "")
    parts.extend([
        production_profile_target_assign(
            "BASE_URL",
            base_url,
            "CURRENT_PRODUCTION_BASE_URL",
            is_placeholder_base_url(base_url),
        ),
        production_profile_target_assign(
            "TCP_HOST",
            tcp_host,
            "CURRENT_PRODUCTION_TCP_HOST",
            is_placeholder_host(tcp_host),
        ),
        production_profile_target_assign(
            "TCP_PORT",
            tcp_port,
            "CURRENT_PRODUCTION_TCP_PORT",
            not tcp_port.strip(),
        ),
        production_profile_target_assign(
            "ACCOUNT_FILE",
            account_file,
            "CURRENT_PRODUCTION_ACCOUNT_FILE",
            is_placeholder_account_file(account_file),
        ),
        production_profile_target_assign(
            "IM_CONVERSATION_ID",
            conversation_id,
            "CURRENT_PRODUCTION_CONVERSATION_ID",
            is_placeholder_conversation_id(conversation_id),
        ),
    ])
    if bool(getattr(args, "require_internal_secret", False)) or bool(target.get("hasInternalSecret")):
        parts.append(shell_secret_assign("IM_INTERNAL_SECRET"))
    parts.extend([
        "CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080=false",
        "CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS=86400",
        "CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS=86400",
        shell_required_assign("CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_FILE"),
        shell_required_assign("CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON"),
        shell_required_assign("CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID"),
        shell_required_assign("CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID"),
        shell_required_assign("CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_ADMIN_CIDR"),
    ])
    parts.append("./run_current_production_readiness.sh")
    return f"(cd IMServer/LoadTests && {' '.join(parts)})"


def blocker_command_role(code: str, source: str = "") -> str:
    if source == "current-production-readiness":
        return "current-production-readiness"
    if source == "production-acceptance":
        return "production-acceptance"
    if source == "production-gate":
        return "production-profile"
    if code.startswith("production_acceptance_") or code in {
        "operator_network_preflight_policy_missing",
        "cloud_security_group_repair_receipt_policy_missing",
        "cloud_security_group_repair_receipt_missing",
        "cloud_security_group_repair_receipt_expected_security_group_missing",
        "cloud_security_group_repair_receipt_expected_region_missing",
        "cloud_security_group_repair_receipt_expected_admin_cidr_missing",
    }:
        return "production-acceptance"
    if code.startswith("public_") or code.startswith("operator_network_") or code in {
        "current_production_readiness_missing",
        "current_production_readiness_not_pass",
    }:
        return "current-production-readiness"
    return "production-profile"


def attach_production_evidence_commands(
    blockers: list[dict[str, str]],
    *,
    current_readiness_command: str,
    production_profile_command: str,
    production_acceptance_command: str,
) -> list[dict[str, str]]:
    commands_by_role = {
        "current-production-readiness": current_readiness_command,
        "production-profile": production_profile_command,
        "production-acceptance": production_acceptance_command,
    }
    enriched: list[dict[str, str]] = []
    for blocker in blockers:
        row = dict(blocker)
        role = blocker_command_role(str(row.get("code") or ""), str(row.get("source") or ""))
        command = commands_by_role.get(role, "")
        if command:
            row["commandRole"] = role
            row["command"] = command
        enriched.append(row)
    return enriched


def unique_production_evidence_action_commands(blockers: list[dict[str, str]]) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    seen: set[str] = set()
    for blocker in blockers:
        command = str(blocker.get("command") or "")
        if not command or command in seen:
            continue
        seen.add(command)
        rows.append({
            "role": str(blocker.get("commandRole") or ""),
            "command": command,
        })
    return rows


def failed_production_gate_scenarios(production_gate: dict[str, Any]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for raw_row in production_gate.get("requiredScenarios") or []:
        if not isinstance(raw_row, dict) or bool(raw_row.get("passed")):
            continue
        rows.append({
            "scenario": str(raw_row.get("scenario") or ""),
            "category": str(raw_row.get("category") or ""),
            "failureKind": str(raw_row.get("failureKind") or ""),
            "latestSLOStatus": str(raw_row.get("latestSLOStatus") or ""),
            "latestScenarioStatus": str(raw_row.get("latestScenarioStatus") or ""),
            "reason": str(raw_row.get("reason") or ""),
            "runCount": int(raw_row.get("runCount") or 0),
            "latestRunID": str(raw_row.get("latestRunID") or ""),
        })
    return rows


def failed_production_gate_scenario_names(production_gate: dict[str, Any]) -> list[str]:
    return [row["scenario"] for row in failed_production_gate_scenarios(production_gate) if row.get("scenario")]
