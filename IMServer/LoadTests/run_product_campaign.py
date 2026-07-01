#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
import time
import tempfile
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


SCRIPT_DIR = Path(__file__).resolve().parent

PROFILE_EVIDENCE_FILES = [
    "production-gate.json",
    "production-profile-run.json",
    "production-profile-plan.json",
    "production-profile-entrypoint-probe.log",
    "production-profile-entrypoint-probe.json",
    "production-profile-runbook.json",
    "production-profile-runbook.md",
    "production-profile-prereq-plan.json",
    "production-profile-prereq-audit.json",
    "production-profile-prereq-audit.md",
    "production-profile-scenario-catalog.json",
]

PRODUCT_PLAN_EVIDENCE_FILES = [
    "product-test-plan-run.json",
    "product-test-plan-preview.json",
    "product-test-plan-phases.tsv",
    "product-test-prereq-plan.json",
    "product-test-prereq-audit.json",
    "product-test-prereq-audit.md",
    "product-test-scenario-catalog.json",
    "product-test-runbook.json",
    "product-test-runbook.md",
]


def bool_env(name: str, default: bool = False) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    return value.lower() in {"1", "true", "yes", "on"}


def bool_catalog(value: Any, default: bool) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.lower() in {"1", "true", "yes", "on"}
    return bool(value)


def read_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise SystemExit(f"product_campaign result=fail reason=read_json_failed path={path} error={exc}") from exc


def slug(value: str) -> str:
    return "".join(ch if ch.isalnum() or ch in {"-", "_"} else "-" for ch in value).strip("-") or "stage"


def quote_command(parts: list[str]) -> str:
    return " ".join(shlex.quote(part) for part in parts)


def newest_complete_artifact_dir(root: Path, required_files: list[str]) -> Path | None:
    candidates: list[tuple[float, Path]] = []
    for path in root.rglob(required_files[0]):
        directory = path.parent
        if directory == root:
            continue
        if all((directory / name).is_file() for name in required_files):
            newest = max((directory / name).stat().st_mtime for name in required_files)
            candidates.append((newest, directory))
    if not candidates:
        return None
    candidates.sort(key=lambda item: (item[0], str(item[1])))
    return candidates[-1][1]


def is_complete_artifact_dir(directory: Path, required_files: list[str]) -> bool:
    return all((directory / name).is_file() for name in required_files)


def stage_dir_from_record(row: dict[str, Any]) -> Path:
    return Path(str(row.get("runDir") or "")).expanduser()


def stage_id_for_dir(records: list[dict[str, Any]] | None, directory: Path) -> str:
    if records is None:
        return ""
    resolved = directory.resolve()
    for row in records:
        try:
            if stage_dir_from_record(row).resolve() == resolved:
                return str(row.get("id") or "")
        except Exception:
            continue
    return ""


def marked_complete_artifact_dir(
    records: list[dict[str, Any]] | None,
    marker: str,
    required_files: list[str],
) -> tuple[Path | None, str]:
    if records is None:
        return None, ""
    marked = [row for row in records if row.get(marker) is True]
    if not marked:
        return None, ""
    for row in marked:
        if str(row.get("status") or "") != "PASS":
            continue
        directory = stage_dir_from_record(row)
        if directory and is_complete_artifact_dir(directory, required_files):
            return directory, str(row.get("id") or "")
    return None, str(marked[0].get("id") or "")


def copy_evidence_files(source: Path, target: Path, files: list[str]) -> list[str]:
    copied: list[str] = []
    for name in files:
        src = source / name
        if src.is_file():
            shutil.copy2(src, target / name)
            copied.append(name)
    return copied


def materialize_evidence_root(result_dir: Path, records: list[dict[str, Any]] | None = None) -> dict[str, Any]:
    result: dict[str, Any] = {
        "enabled": True,
        "profileStageID": "",
        "profileSourceDir": "",
        "productPlanStageID": "",
        "productPlanSourceDir": "",
        "profileFilesCopied": [],
        "productPlanFilesCopied": [],
    }
    profile_dir, profile_stage_id = marked_complete_artifact_dir(records, "packageEvidenceProfile", PROFILE_EVIDENCE_FILES)
    if profile_dir is None and not profile_stage_id:
        profile_dir = newest_complete_artifact_dir(result_dir, PROFILE_EVIDENCE_FILES)
        if profile_dir is not None:
            profile_stage_id = stage_id_for_dir(records, profile_dir)
    if profile_dir is not None:
        result["profileStageID"] = profile_stage_id
        result["profileSourceDir"] = str(profile_dir)
        result["profileFilesCopied"] = copy_evidence_files(profile_dir, result_dir, PROFILE_EVIDENCE_FILES)
    elif profile_stage_id:
        result["profileStageID"] = profile_stage_id

    product_plan_dir, product_plan_stage_id = marked_complete_artifact_dir(records, "packageEvidenceProductPlan", PRODUCT_PLAN_EVIDENCE_FILES)
    if product_plan_dir is None and not product_plan_stage_id:
        product_plan_dir = newest_complete_artifact_dir(result_dir, PRODUCT_PLAN_EVIDENCE_FILES)
        if product_plan_dir is not None:
            product_plan_stage_id = stage_id_for_dir(records, product_plan_dir)
    if product_plan_dir is not None:
        result["productPlanStageID"] = product_plan_stage_id
        result["productPlanSourceDir"] = str(product_plan_dir)
        result["productPlanFilesCopied"] = copy_evidence_files(product_plan_dir, result_dir, PRODUCT_PLAN_EVIDENCE_FILES)
    elif product_plan_stage_id:
        result["productPlanStageID"] = product_plan_stage_id
    return result


def materialized_evidence_missing(evidence_root: dict[str, Any]) -> list[str]:
    missing: list[str] = []
    if not evidence_root.get("profileSourceDir"):
        missing.append("profileSourceDir")
    if len(evidence_root.get("profileFilesCopied") or []) != len(PROFILE_EVIDENCE_FILES):
        missing.append("profileFiles")
    if not evidence_root.get("productPlanSourceDir"):
        missing.append("productPlanSourceDir")
    if len(evidence_root.get("productPlanFilesCopied") or []) != len(PRODUCT_PLAN_EVIDENCE_FILES):
        missing.append("productPlanFiles")
    return missing


def enforce_materialized_evidence_requirement(
    payload: dict[str, Any],
    *,
    execute: bool,
    should_materialize: bool,
    require_materialized: bool,
) -> None:
    if not execute or payload.get("finalStatus") != "PASS" or not require_materialized:
        return
    evidence_root = payload.setdefault("evidenceRoot", {})
    if should_materialize:
        missing_materialized = materialized_evidence_missing(evidence_root)
    else:
        missing_materialized = ["evidenceRootDisabled"]
    if not missing_materialized:
        return
    payload["finalStatus"] = "FAIL"
    payload["failureCount"] = int(payload.get("failureCount") or 0) + 1
    payload["requiredFailureCount"] = int(payload.get("requiredFailureCount") or 0) + 1
    payload["reason"] = "materialized_evidence_missing"
    evidence_root["missing"] = missing_materialized


def redacted_env_assignments(assignments: dict[str, str], include_secret_placeholders: bool = True) -> list[str]:
    result: list[str] = []
    for key in sorted(assignments):
        value = assignments[key]
        if key in {"IM_INTERNAL_SECRET", "IM_PASSWORD"}:
            if include_secret_placeholders:
                result.append(f"{key}=${{{key}:?set-{key}}}")
            continue
        if key == "IM_INTERNAL_SHARED_SECRET":
            if include_secret_placeholders:
                result.append(f"{key}=${{{key}:-${{IM_INTERNAL_SECRET:?set-IM_INTERNAL_SECRET}}}}")
            continue
        if key == "SSH_AUTHORIZED_KEY":
            if include_secret_placeholders:
                result.append(f"{key}=${{{key}:-<authorized-public-key>}}")
            continue
        result.append(f"{key}={value}")
    return result


def command_string(assignments: dict[str, str], argv: list[str]) -> str:
    return quote_command(["env", *redacted_env_assignments(assignments), *argv])


def host_from_url(value: str) -> str:
    try:
        return urlparse(value).hostname or ""
    except Exception:
        return ""


def common_runtime_assignments() -> dict[str, str]:
    keys = [
        "BASE_URL",
        "TCP_HOST",
        "TCP_PORT",
        "ACCOUNT_FILE",
        "IM_CONVERSATION_ID",
        "IM_INTERNAL_SECRET",
        "IM_INTERNAL_SHARED_SECRET",
        "IM_EMAIL",
        "IM_PASSWORD",
        "PERF_DRY_RUN",
        "PERF_STATUS_FILTER_TARGET",
        "SSH_PRIVATE_KEY_PATH",
        "SSH_AUTHORIZED_KEY",
    ]
    assignments = {key: value for key in keys if (value := os.environ.get(key))}
    if not assignments.get("TCP_HOST") and assignments.get("BASE_URL"):
        tcp_host = host_from_url(assignments["BASE_URL"])
        if tcp_host:
            assignments["TCP_HOST"] = tcp_host
    if assignments.get("TCP_HOST") and not assignments.get("TCP_PORT"):
        assignments["TCP_PORT"] = "9000"
    return assignments


def target_context(assignments: dict[str, str]) -> dict[str, str]:
    return {
        "baseURL": assignments.get("BASE_URL", ""),
        "tcpHost": assignments.get("TCP_HOST", ""),
        "tcpPort": assignments.get("TCP_PORT", ""),
        "accountFile": assignments.get("ACCOUNT_FILE", ""),
        "hasConversationID": str(bool(assignments.get("IM_CONVERSATION_ID"))).lower(),
        "hasInternalSecret": str(bool(assignments.get("IM_INTERNAL_SECRET") or assignments.get("IM_INTERNAL_SHARED_SECRET"))).lower(),
    }


def read_key_values(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if "=" not in raw:
            continue
        key, value = raw.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def parse_rescue_artifact_dir(log_text: str) -> str:
    for raw in log_text.splitlines():
        if "entrypoint_rescue_artifact=pass" not in raw and "node_access_rescue_artifact result=pass" not in raw:
            continue
        for item in raw.split():
            if item.startswith("dir="):
                return item.split("=", 1)[1]
    return ""


def collect_stage_rescue_artifact(stage_dir: Path) -> dict[str, Any]:
    log_path = stage_dir / "entrypoint-rescue-artifact.log"
    if not log_path.is_file():
        return {}
    log_text = log_path.read_text(encoding="utf-8", errors="replace")
    artifact_dir_raw = parse_rescue_artifact_dir(log_text)
    artifact_dir = Path(artifact_dir_raw).expanduser().resolve() if artifact_dir_raw else Path()
    summary_path = artifact_dir / "summary.txt" if artifact_dir_raw else Path()
    summary = read_key_values(summary_path)
    tarball_path = Path(f"{artifact_dir}.tar.gz") if artifact_dir_raw else Path()
    verify_path = artifact_dir / "verify-artifact.sh" if artifact_dir_raw else Path()
    package_verify_path = Path(f"{artifact_dir}.tar.gz.verify.sh") if artifact_dir_raw else Path()
    return {
        "status": "PASS" if summary and summary.get("rescuePlanAction") else "UNKNOWN",
        "log": str(log_path),
        "dir": str(artifact_dir) if artifact_dir_raw else "",
        "tarball": str(tarball_path) if tarball_path.is_file() else "",
        "summary": str(summary_path) if summary_path.is_file() else "",
        "verifyScript": str(verify_path) if verify_path.is_file() else "",
        "packageVerifyScript": str(package_verify_path) if package_verify_path.is_file() else "",
        "rescuePlanAction": summary.get("rescuePlanAction", ""),
        "entrypointDiagnosis": summary.get("entrypointDiagnosis", ""),
        "entrypointFailed": summary.get("entrypointFailed", ""),
        "sshStatus": summary.get("sshStatus", ""),
        "imTcpStatus": summary.get("imTcpStatus", ""),
    }


def run_command(assignments: dict[str, str], argv: list[str], log_path: Path) -> int:
    env = os.environ.copy()
    env.update(assignments)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w", encoding="utf-8") as handle:
        proc = subprocess.run(argv, cwd=SCRIPT_DIR, env=env, stdout=handle, stderr=subprocess.STDOUT)
    return proc.returncode


def load_campaign(catalog: dict[str, Any], name: str) -> dict[str, Any]:
    campaigns = catalog.get("campaigns") or {}
    campaign = campaigns.get(name)
    if not isinstance(campaign, dict):
        raise SystemExit(f"product_campaign result=fail reason=unknown_campaign campaign={name}")
    return campaign


def campaign_stop_on_failure(campaign: dict[str, Any], *, cli_no_stop: bool) -> bool:
    if cli_no_stop:
        return False
    if "PRODUCT_CAMPAIGN_STOP_ON_FAILURE" in os.environ:
        return bool_env("PRODUCT_CAMPAIGN_STOP_ON_FAILURE", True)
    return bool_catalog(campaign.get("stopOnFailure"), True)


def product_plan_command(stage: dict[str, Any], stage_dir: Path, run_id: str) -> tuple[dict[str, str], list[str]]:
    phases = " ".join(str(item) for item in (stage.get("phases") or []) if str(item))
    rescue_artifact_dir = Path(
        os.environ.get(
            "PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT_DIR",
            str(stage_dir / "current-node-access-rescue"),
        )
    ).expanduser().resolve()
    assignments = {
        "RESULT_ROOT": str(stage_dir),
        "PRODUCT_TEST_PLAN": str(stage.get("id") or "campaign-stage"),
        "PRODUCT_TEST_PHASES": phases,
        "PRODUCT_TEST_RUN_ID_PREFIX": run_id,
        "PRODUCT_TEST_PACKAGE_EVIDENCE": os.environ.get("PRODUCT_TEST_PACKAGE_EVIDENCE", "false"),
        "PRODUCT_TEST_PLAN_JSON": str(stage_dir / "product-test-plan-run.json"),
        "PRODUCT_TEST_PLAN_PREVIEW_JSON": str(stage_dir / "product-test-plan-preview.json"),
        "PRODUCT_TEST_STATUS_TSV": str(stage_dir / "product-test-plan-phases.tsv"),
        "PRODUCT_TEST_PREREQ_PLAN_JSON": str(stage_dir / "product-test-prereq-plan.json"),
        "PRODUCT_TEST_PREREQ_AUDIT_JSON": str(stage_dir / "product-test-prereq-audit.json"),
        "PRODUCT_TEST_PREREQ_AUDIT_MD": str(stage_dir / "product-test-prereq-audit.md"),
        "PRODUCT_TEST_SCENARIO_CATALOG_JSON": str(stage_dir / "product-test-scenario-catalog.json"),
        "PRODUCT_TEST_RUNBOOK_JSON": str(stage_dir / "product-test-runbook.json"),
        "PRODUCT_TEST_RUNBOOK_MD": str(stage_dir / "product-test-runbook.md"),
        "PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT": os.environ.get(
            "PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT",
            "true",
        ),
        "PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT_DIR": os.environ.get(
            "PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT_DIR",
            str(rescue_artifact_dir),
        )
        if os.environ.get("PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT_DIR")
        else str(rescue_artifact_dir),
        "PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT_PACKAGE": os.environ.get(
            "PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT_PACKAGE",
            "true",
        ),
    }
    return assignments, [str(SCRIPT_DIR / "run_product_test_plan.sh")]


def production_profile_command(stage: dict[str, Any], stage_dir: Path, run_id: str) -> tuple[dict[str, str], list[str]]:
    profile = str(stage.get("profile") or "")
    assignments = {
        "RESULT_ROOT": str(stage_dir),
        "PERF_PRODUCTION_GATE_PROFILE": profile,
        "PRODUCTION_PROFILE_RUN_ID_PREFIX": run_id,
        "PRODUCTION_PROFILE_REQUIRE_PRODUCT_PLAN_ARTIFACTS": os.environ.get(
            "PRODUCTION_PROFILE_REQUIRE_PRODUCT_PLAN_ARTIFACTS",
            "false",
        ),
        "PRODUCTION_PROFILE_PLAN_JSON": str(stage_dir / "production-profile-plan.json"),
        "PRODUCTION_PROFILE_PREREQ_PLAN_JSON": str(stage_dir / "production-profile-prereq-plan.json"),
        "PRODUCTION_PROFILE_SCENARIO_CATALOG_JSON": str(stage_dir / "production-profile-scenario-catalog.json"),
        "PRODUCTION_PROFILE_PREREQ_AUDIT_JSON": str(stage_dir / "production-profile-prereq-audit.json"),
        "PRODUCTION_PROFILE_PREREQ_AUDIT_MD": str(stage_dir / "production-profile-prereq-audit.md"),
        "PRODUCTION_PROFILE_ENTRYPOINT_PROBE_LOG": str(stage_dir / "production-profile-entrypoint-probe.log"),
        "PRODUCTION_PROFILE_ENTRYPOINT_PROBE_JSON": str(stage_dir / "production-profile-entrypoint-probe.json"),
        "PRODUCTION_PROFILE_RUNBOOK_JSON": str(stage_dir / "production-profile-runbook.json"),
        "PRODUCTION_PROFILE_RUNBOOK_MD": str(stage_dir / "production-profile-runbook.md"),
        "PRODUCTION_PROFILE_RUN_JSON": str(stage_dir / "production-profile-run.json"),
        "PRODUCTION_PROFILE_BATCH_STATUS_TSV": str(stage_dir / "production-profile-batches.tsv"),
    }
    return assignments, [str(SCRIPT_DIR / "run_production_profile.sh")]


def scenario_group_command(stage: dict[str, Any], stage_dir: Path, run_id: str) -> tuple[dict[str, str], list[str]]:
    groups = " ".join(str(item) for item in (stage.get("scenarioGroups") or []) if str(item))
    assignments = {
        "RESULT_ROOT": str(stage_dir),
        "RUN_ID": run_id,
        "SCENARIO_GROUPS": groups,
        "STOP_ON_FAILURE": os.environ.get("STOP_ON_FAILURE", "true"),
    }
    return assignments, [str(SCRIPT_DIR / "run_perf_scenarios.sh")]


def scenario_command(stage: dict[str, Any], stage_dir: Path, run_id: str) -> tuple[dict[str, str], list[str]]:
    scenarios = " ".join(str(item) for item in (stage.get("scenarios") or []) if str(item))
    assignments = {
        "RESULT_ROOT": str(stage_dir),
        "RUN_ID": run_id,
        "SCENARIOS": scenarios,
        "STOP_ON_FAILURE": os.environ.get("STOP_ON_FAILURE", "true"),
    }
    return assignments, [str(SCRIPT_DIR / "run_perf_scenarios.sh")]


def campaign_command(stage: dict[str, Any], stage_dir: Path, run_id: str, execute: bool) -> tuple[dict[str, str], list[str]]:
    campaign = str(stage.get("campaign") or "")
    assignments = {
        "RESULT_ROOT": str(stage_dir),
    }
    argv = [
        sys.executable,
        str(SCRIPT_DIR / "run_product_campaign.py"),
        "--campaign",
        campaign,
        "--result-dir",
        str(stage_dir),
        "--run-id-prefix",
        run_id,
    ]
    if execute:
        argv.append("--execute")
    if not bool_env("PRODUCT_CAMPAIGN_STOP_ON_FAILURE", True):
        argv.append("--no-stop-on-failure")
    return assignments, argv


def build_stage_command(
    stage: dict[str, Any],
    stage_dir: Path,
    run_id: str,
    execute: bool,
) -> tuple[dict[str, str], list[str]]:
    runner = str(stage.get("runner") or "")
    if runner == "product-plan":
        assignments, argv = product_plan_command(stage, stage_dir, run_id)
    elif runner == "production-profile":
        assignments, argv = production_profile_command(stage, stage_dir, run_id)
    elif runner == "scenario-group":
        assignments, argv = scenario_group_command(stage, stage_dir, run_id)
    elif runner == "scenario":
        assignments, argv = scenario_command(stage, stage_dir, run_id)
    elif runner == "campaign":
        assignments, argv = campaign_command(stage, stage_dir, run_id, execute)
    else:
        raise SystemExit(f"product_campaign result=fail reason=unsupported_runner runner={runner}")
    merged = common_runtime_assignments()
    merged.update(assignments)
    return merged, argv


def stage_record(
    *,
    index: int,
    stage_id: str,
    runner: str,
    required: bool,
    isolated: bool,
    status: str,
    return_code: int | None,
    stage_dir: Path,
    log_path: Path | None,
    command: str,
    evidence: str,
    package_evidence_profile: bool = False,
    package_evidence_product_plan: bool = False,
    skip_reason: str = "",
    rescue_artifact: dict[str, Any] | None = None,
) -> dict[str, Any]:
    record = {
        "index": index,
        "id": stage_id,
        "runner": runner,
        "required": required,
        "isolated": isolated,
        "status": status,
        "returnCode": return_code,
        "runDir": str(stage_dir),
        "log": str(log_path) if log_path is not None else "",
        "command": command,
        "evidence": evidence,
        "packageEvidenceProfile": package_evidence_profile,
        "packageEvidenceProductPlan": package_evidence_product_plan,
        "skipReason": skip_reason,
    }
    if rescue_artifact:
        record["rescueArtifact"] = rescue_artifact
    return record


def build_runbook(payload: dict[str, Any]) -> str:
    lines = [
        "# Product Campaign Runbook",
        "",
        f"- campaign: `{payload['campaign']}`",
        f"- status: `{payload['finalStatus']}`",
        f"- mode: `{'execute' if payload['execute'] else 'plan'}`",
        f"- resultDir: `{payload['resultDir']}`",
        f"- stopOnFailure: `{payload['stopOnFailure']}`",
        f"- attemptedStageCount: `{payload.get('attemptedStageCount', 0)}`",
        f"- skippedStageCount: `{payload.get('skippedStageCount', 0)}`",
        f"- failureCount: `{payload.get('failureCount', 0)}`",
        f"- requiredFailureCount: `{payload.get('requiredFailureCount', 0)}`",
        "",
        "## Target",
        "",
    ]
    target = payload.get("target") or {}
    if target:
        lines.extend([
            f"- baseURL: `{target.get('baseURL') or '-'}`",
            f"- tcpHost: `{target.get('tcpHost') or '-'}`",
            f"- tcpPort: `{target.get('tcpPort') or '-'}`",
            f"- accountFile: `{target.get('accountFile') or '-'}`",
            f"- hasConversationID: `{target.get('hasConversationID') or 'false'}`",
            f"- hasInternalSecret: `{target.get('hasInternalSecret') or 'false'}`",
            "",
        ])
    else:
        lines.extend([
            "- No runtime target environment was provided.",
            "",
        ])
    rescue_rows = [
        (row, row.get("rescueArtifact") or {})
        for row in payload.get("stages", [])
        if row.get("rescueArtifact")
    ]
    if rescue_rows:
        lines.extend([
            "## Entrypoint Rescue",
            "",
            "| Stage | Action | Diagnosis | Dir | Tarball |",
            "| --- | --- | --- | --- | --- |",
        ])
        for row, rescue in rescue_rows:
            lines.append(
                "| "
                + " | ".join([
                    f"`{row.get('id')}`",
                    f"`{rescue.get('rescuePlanAction') or '-'}`",
                    f"`{rescue.get('entrypointDiagnosis') or '-'}`",
                    f"`{rescue.get('dir') or '-'}`",
                    f"`{rescue.get('tarball') or '-'}`",
                ])
                + " |"
            )
        lines.append("")
    lines.extend([
        "## Stages",
        "",
        "| Stage | Runner | Required | Status | Skip Reason | Command |",
        "| --- | --- | --- | --- | --- | --- |",
    ])
    for row in payload["stages"]:
        lines.append(
            "| "
            + " | ".join(
                [
                    f"`{row['id']}`",
                    f"`{row['runner']}`",
                    f"`{row['required']}`",
                    f"`{row['status']}`",
                    f"`{row.get('skipReason') or '-'}`",
                    f"`{row['command']}`",
                ]
            )
            + " |"
        )
    lines.extend([
        "",
        "## Evidence Root",
        "",
    ])
    evidence_root = payload.get("evidenceRoot") or {}
    if evidence_root:
        lines.extend([
            f"- profileSourceDir: `{evidence_root.get('profileSourceDir') or ''}`",
            f"- profileStageID: `{evidence_root.get('profileStageID') or ''}`",
            f"- productPlanSourceDir: `{evidence_root.get('productPlanSourceDir') or ''}`",
            f"- productPlanStageID: `{evidence_root.get('productPlanStageID') or ''}`",
            f"- profileFilesCopied: `{len(evidence_root.get('profileFilesCopied') or [])}`",
            f"- productPlanFilesCopied: `{len(evidence_root.get('productPlanFilesCopied') or [])}`",
            f"- missing: `{', '.join(evidence_root.get('missing') or []) or '-'}`",
            "",
        ])
    else:
        lines.extend([
            "- No root evidence artifacts were materialized.",
            "",
        ])
    lines.extend([
        "",
        "## Notes",
        "",
        "- Commands are redacted. Secret values are represented as shell placeholders.",
        "- A `PLANNED` receipt is a command plan, not runtime evidence.",
        "- Production evidence requires `--execute` and PASS receipts for required stages.",
        "",
    ])
    return "\n".join(lines)


def run_materialize_self_test() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        profile_dir = root / "01-profile"
        product_dir = root / "02-product"
        newer_profile_dir = root / "03-profile-newer"
        newer_product_dir = root / "04-product-newer"
        profile_dir.mkdir()
        product_dir.mkdir()
        newer_profile_dir.mkdir()
        newer_product_dir.mkdir()
        for name in PROFILE_EVIDENCE_FILES:
            (profile_dir / name).write_text(f"profile {name}\n", encoding="utf-8")
            (newer_profile_dir / name).write_text(f"newer profile {name}\n", encoding="utf-8")
        for name in PRODUCT_PLAN_EVIDENCE_FILES:
            (product_dir / name).write_text(f"product {name}\n", encoding="utf-8")
            (newer_product_dir / name).write_text(f"newer product {name}\n", encoding="utf-8")
        records = [
            {
                "id": "packaged-profile",
                "status": "PASS",
                "runDir": str(profile_dir),
                "packageEvidenceProfile": True,
            },
            {
                "id": "packaged-product-plan",
                "status": "PASS",
                "runDir": str(product_dir),
                "packageEvidenceProductPlan": True,
            },
        ]
        result = materialize_evidence_root(root, records)
        if not result["profileSourceDir"] or not result["productPlanSourceDir"]:
            raise SystemExit("product_campaign_materialize_self_test result=fail reason=source_missing")
        if result.get("profileStageID") != "packaged-profile" or result.get("productPlanStageID") != "packaged-product-plan":
            raise SystemExit(f"product_campaign_materialize_self_test result=fail reason=stage_id_mismatch result={result}")
        profile_probe = (root / PROFILE_EVIDENCE_FILES[0]).read_text(encoding="utf-8")
        product_probe = (root / PRODUCT_PLAN_EVIDENCE_FILES[0]).read_text(encoding="utf-8")
        if profile_probe.startswith("newer ") or product_probe.startswith("newer "):
            raise SystemExit("product_campaign_materialize_self_test result=fail reason=marked_stage_not_preferred")
        for name in PROFILE_EVIDENCE_FILES + PRODUCT_PLAN_EVIDENCE_FILES:
            if not (root / name).is_file():
                raise SystemExit(f"product_campaign_materialize_self_test result=fail reason=file_missing file={name}")
        if materialized_evidence_missing(result):
            raise SystemExit("product_campaign_materialize_self_test result=fail reason=unexpected_missing_complete_artifacts")
        incomplete_root = root / "incomplete"
        incomplete_root.mkdir()
        incomplete = materialize_evidence_root(incomplete_root)
        missing = set(materialized_evidence_missing(incomplete))
        if missing != {"profileSourceDir", "profileFiles", "productPlanSourceDir", "productPlanFiles"}:
            raise SystemExit(f"product_campaign_materialize_self_test result=fail reason=missing_detection_failed missing={sorted(missing)}")
        pass_payload = {"finalStatus": "PASS", "failureCount": 0, "requiredFailureCount": 0, "evidenceRoot": dict(result)}
        enforce_materialized_evidence_requirement(
            pass_payload,
            execute=True,
            should_materialize=True,
            require_materialized=True,
        )
        if pass_payload.get("finalStatus") != "PASS":
            raise SystemExit("product_campaign_materialize_self_test result=fail reason=complete_evidence_rejected")
        missing_payload = {"finalStatus": "PASS", "failureCount": 0, "requiredFailureCount": 0, "evidenceRoot": dict(incomplete)}
        enforce_materialized_evidence_requirement(
            missing_payload,
            execute=True,
            should_materialize=True,
            require_materialized=True,
        )
        if missing_payload.get("finalStatus") != "FAIL" or missing_payload.get("reason") != "materialized_evidence_missing":
            raise SystemExit("product_campaign_materialize_self_test result=fail reason=missing_evidence_not_rejected")
        disabled_payload = {"finalStatus": "PASS", "failureCount": 0, "requiredFailureCount": 0, "evidenceRoot": {"enabled": False}}
        enforce_materialized_evidence_requirement(
            disabled_payload,
            execute=True,
            should_materialize=False,
            require_materialized=True,
        )
        if disabled_payload.get("finalStatus") != "FAIL" or (disabled_payload.get("evidenceRoot") or {}).get("missing") != ["evidenceRootDisabled"]:
            raise SystemExit("product_campaign_materialize_self_test result=fail reason=disabled_evidence_not_rejected")
        print("product_campaign_materialize_self_test result=pass")


def run_execution_self_test() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        catalog_path = root / "campaigns.json"
        catalog_path.write_text(json.dumps({
            "schemaVersion": 1,
            "campaigns": {
                "fail-fast": {
                    "stages": [
                        {
                            "id": "bad-first",
                            "runner": "scenario",
                            "scenarios": ["definitely-not-a-scenario"],
                            "required": True,
                        },
                        {
                            "id": "bad-second",
                            "runner": "scenario",
                            "scenarios": ["also-not-a-scenario"],
                            "required": True,
                        },
                    ],
                },
                "continue-after-failure": {
                    "stopOnFailure": False,
                    "stages": [
                        {
                            "id": "bad-first",
                            "runner": "scenario",
                            "scenarios": ["definitely-not-a-scenario"],
                            "required": True,
                        },
                        {
                            "id": "bad-second",
                            "runner": "scenario",
                            "scenarios": ["also-not-a-scenario"],
                            "required": True,
                        },
                    ],
                },
            },
        }, indent=2), encoding="utf-8")

        saved_target_env = {
            key: os.environ.get(key)
            for key in (
                "BASE_URL",
                "TCP_HOST",
                "TCP_PORT",
                "PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT",
                "PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT_DIR",
                "PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT_PACKAGE",
                "SSH_PRIVATE_KEY_PATH",
                "SSH_AUTHORIZED_KEY",
            )
        }
        try:
            os.environ["BASE_URL"] = "http://203.0.113.10:8080"
            os.environ.pop("TCP_HOST", None)
            os.environ.pop("TCP_PORT", None)
            os.environ["PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT"] = "true"
            os.environ["PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT_DIR"] = str(root / "campaign-rescue")
            os.environ["PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT_PACKAGE"] = "true"
            os.environ["SSH_PRIVATE_KEY_PATH"] = "/tmp/self-test-key.pem"
            os.environ["SSH_AUTHORIZED_KEY"] = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakePublicKeyForSelfTest product-campaign-self-test"
            derived_assignments = common_runtime_assignments()
            if derived_assignments.get("TCP_HOST") != "203.0.113.10" or derived_assignments.get("TCP_PORT") != "9000":
                raise SystemExit(
                    "product_campaign_execution_self_test result=fail "
                    f"reason=derived_target_mismatch assignments={derived_assignments}"
                )
            derived_assignments, derived_argv = build_stage_command(
                {"id": "derived", "runner": "scenario", "scenarios": ["login-smoke"]},
                root / "derived",
                "self-test-derived",
                False,
            )
            derived_command = command_string(derived_assignments, derived_argv)
            if "TCP_HOST=203.0.113.10" not in derived_command or "TCP_PORT=9000" not in derived_command:
                raise SystemExit(
                    "product_campaign_execution_self_test result=fail "
                    f"reason=derived_target_missing_from_command command={derived_command}"
                )
            product_assignments, product_argv = build_stage_command(
                {"id": "product", "runner": "product-plan", "phases": ["entrypoint"]},
                root / "product",
                "self-test-product",
                False,
            )
            product_command = command_string(product_assignments, product_argv)
            if product_assignments.get("PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT") != "true":
                raise SystemExit("product_campaign_execution_self_test result=fail reason=product_rescue_toggle_missing")
            if product_assignments.get("PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT_DIR") != str(root / "campaign-rescue"):
                raise SystemExit("product_campaign_execution_self_test result=fail reason=product_rescue_dir_missing")
            if product_assignments.get("PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT_PACKAGE") != "true":
                raise SystemExit("product_campaign_execution_self_test result=fail reason=product_rescue_package_missing")
            if product_assignments.get("SSH_PRIVATE_KEY_PATH") != "/tmp/self-test-key.pem":
                raise SystemExit("product_campaign_execution_self_test result=fail reason=ssh_private_key_path_missing")
            if product_assignments.get("SSH_AUTHORIZED_KEY") is None:
                raise SystemExit("product_campaign_execution_self_test result=fail reason=ssh_authorized_key_missing")
            if "PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT_DIR=" not in product_command:
                raise SystemExit(
                    "product_campaign_execution_self_test result=fail "
                    f"reason=product_rescue_dir_missing_from_command command={product_command}"
                )
            if "AAAAC3NzaC1lZDI1NTE5AAAAIFakePublicKeyForSelfTest" in product_command:
                raise SystemExit("product_campaign_execution_self_test result=fail reason=ssh_authorized_key_not_redacted")
            if "SSH_AUTHORIZED_KEY=${SSH_AUTHORIZED_KEY:-<authorized-public-key>}" not in product_command:
                raise SystemExit(
                    "product_campaign_execution_self_test result=fail "
                    f"reason=ssh_authorized_key_placeholder_missing command={product_command}"
                )
        finally:
            for key, value in saved_target_env.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value

        rescue_stage_dir = root / "rescue-stage"
        rescue_stage_dir.mkdir()
        rescue_dir = root / "rescue-artifact"
        rescue_dir.mkdir()
        (rescue_stage_dir / "entrypoint-rescue-artifact.log").write_text(
            f"product_test_plan entrypoint_rescue_artifact=pass dir={rescue_dir}\n",
            encoding="utf-8",
        )
        (rescue_dir / "summary.txt").write_text(
            "\n".join([
                "rescuePlanAction=cloud_console_rescue_required",
                "entrypointDiagnosis=cloud_edge_http_403_intercept",
                "entrypointFailed=True",
                "sshStatus=http_403_intercepted",
                "imTcpStatus=http_403_intercepted",
            ])
            + "\n",
            encoding="utf-8",
        )
        (rescue_dir / "verify-artifact.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
        Path(f"{rescue_dir}.tar.gz").write_text("fake tarball\n", encoding="utf-8")
        Path(f"{rescue_dir}.tar.gz.verify.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
        rescue_artifact = collect_stage_rescue_artifact(rescue_stage_dir)
        if rescue_artifact.get("rescuePlanAction") != "cloud_console_rescue_required":
            raise SystemExit(
                "product_campaign_execution_self_test result=fail "
                f"reason=rescue_artifact_not_collected artifact={rescue_artifact}"
            )
        rescue_payload = {
            "campaign": "rescue-self-test",
            "finalStatus": "FAIL",
            "execute": True,
            "resultDir": str(root),
            "stopOnFailure": True,
            "stages": [
                stage_record(
                    index=1,
                    stage_id="entrypoint",
                    runner="product-plan",
                    required=True,
                    isolated=False,
                    status="FAIL",
                    return_code=1,
                    stage_dir=rescue_stage_dir,
                    log_path=rescue_stage_dir / "stage.log",
                    command="fake",
                    evidence="entrypoint rescue",
                    rescue_artifact=rescue_artifact,
                )
            ],
        }
        rescue_runbook = build_runbook(rescue_payload)
        if "## Entrypoint Rescue" not in rescue_runbook or "cloud_console_rescue_required" not in rescue_runbook:
            raise SystemExit("product_campaign_execution_self_test result=fail reason=rescue_runbook_section_missing")

        fail_fast = run_campaign(
            catalog_path=catalog_path,
            campaign_name="fail-fast",
            result_dir=root / "fail-fast",
            run_id_prefix="self-test-fail-fast",
            execute=True,
            stop_on_failure=True,
        )
        if fail_fast.get("finalStatus") != "FAIL":
            raise SystemExit("product_campaign_execution_self_test result=fail reason=fail_fast_status_not_fail")
        if fail_fast.get("stageCount") != 2 or fail_fast.get("attemptedStageCount") != 1 or fail_fast.get("skippedStageCount") != 1:
            raise SystemExit(f"product_campaign_execution_self_test result=fail reason=fail_fast_counts payload={fail_fast}")
        stages = fail_fast.get("stages") or []
        if stages[0].get("status") != "FAIL" or stages[1].get("status") != "SKIPPED":
            raise SystemExit(f"product_campaign_execution_self_test result=fail reason=fail_fast_stage_statuses stages={stages}")
        if stages[1].get("skipReason") != "stopped_after_required_failure":
            raise SystemExit("product_campaign_execution_self_test result=fail reason=skip_reason_missing")

        continue_run = run_campaign(
            catalog_path=catalog_path,
            campaign_name="continue-after-failure",
            result_dir=root / "continue",
            run_id_prefix="self-test-continue",
            execute=True,
            stop_on_failure=False,
        )
        if continue_run.get("finalStatus") != "FAIL":
            raise SystemExit("product_campaign_execution_self_test result=fail reason=continue_status_not_fail")
        if continue_run.get("stageCount") != 2 or continue_run.get("attemptedStageCount") != 2 or continue_run.get("skippedStageCount") != 0:
            raise SystemExit(f"product_campaign_execution_self_test result=fail reason=continue_counts payload={continue_run}")
        if [row.get("status") for row in continue_run.get("stages") or []] != ["FAIL", "FAIL"]:
            raise SystemExit(f"product_campaign_execution_self_test result=fail reason=continue_stage_statuses stages={continue_run.get('stages')}")
        print("product_campaign_execution_self_test result=pass")


def run_campaign(
    catalog_path: Path,
    campaign_name: str,
    result_dir: Path,
    run_id_prefix: str,
    execute: bool,
    stop_on_failure: bool,
) -> dict[str, Any]:
    catalog = read_json(catalog_path)
    campaign = load_campaign(catalog, campaign_name)
    stages = campaign.get("stages") or []
    if not isinstance(stages, list) or not stages:
        raise SystemExit(f"product_campaign result=fail reason=empty_campaign campaign={campaign_name}")

    result_dir.mkdir(parents=True, exist_ok=True)
    records: list[dict[str, Any]] = []
    final_status = "PASS" if execute else "PLANNED"
    failure_count = 0
    required_failure_count = 0

    for index, stage in enumerate(stages, start=1):
        if not isinstance(stage, dict):
            raise SystemExit(f"product_campaign result=fail reason=invalid_stage campaign={campaign_name} index={index}")
        stage_id = slug(str(stage.get("id") or f"stage-{index}"))
        runner = str(stage.get("runner") or "")
        required = bool(stage.get("required"))
        stage_dir = result_dir / f"{index:02d}-{stage_id}"
        run_id = f"{run_id_prefix}-{index:02d}-{stage_id}"
        assignments, argv = build_stage_command(stage, stage_dir, run_id, execute)
        command = command_string(assignments, argv)
        log_path = stage_dir / "stage.log"
        status = "PLANNED"
        return_code: int | None = None

        if execute:
            print(f"product_campaign stage=start id={stage_id} runner={runner} required={required}")
            return_code = run_command(assignments, argv, log_path)
            status = "PASS" if return_code == 0 else "FAIL"
            print(f"product_campaign stage={status.lower()} id={stage_id} returnCode={return_code} log={log_path}")
            rescue_artifact = collect_stage_rescue_artifact(stage_dir)
            if return_code != 0:
                failure_count += 1
                if required:
                    required_failure_count += 1
                if required and stop_on_failure:
                    records.append(stage_record(
                        index=index,
                        stage_id=stage_id,
                        runner=runner,
                        required=required,
                        isolated=bool(stage.get("isolated")),
                        status=status,
                        return_code=return_code,
                        stage_dir=stage_dir,
                        log_path=log_path,
                        command=command,
                        evidence=str(stage.get("evidence") or ""),
                        package_evidence_profile=bool(stage.get("packageEvidenceProfile")),
                        package_evidence_product_plan=bool(stage.get("packageEvidenceProductPlan")),
                        rescue_artifact=rescue_artifact,
                    ))
                    for skipped_index, skipped_stage in enumerate(stages[index:], start=index + 1):
                        if not isinstance(skipped_stage, dict):
                            raise SystemExit(f"product_campaign result=fail reason=invalid_stage campaign={campaign_name} index={skipped_index}")
                        skipped_stage_id = slug(str(skipped_stage.get("id") or f"stage-{skipped_index}"))
                        skipped_runner = str(skipped_stage.get("runner") or "")
                        skipped_required = bool(skipped_stage.get("required"))
                        skipped_stage_dir = result_dir / f"{skipped_index:02d}-{skipped_stage_id}"
                        skipped_run_id = f"{run_id_prefix}-{skipped_index:02d}-{skipped_stage_id}"
                        skipped_assignments, skipped_argv = build_stage_command(skipped_stage, skipped_stage_dir, skipped_run_id, execute)
                        skipped_command = command_string(skipped_assignments, skipped_argv)
                        records.append(stage_record(
                            index=skipped_index,
                            stage_id=skipped_stage_id,
                            runner=skipped_runner,
                            required=skipped_required,
                            isolated=bool(skipped_stage.get("isolated")),
                            status="SKIPPED",
                            return_code=None,
                            stage_dir=skipped_stage_dir,
                            log_path=None,
                            command=skipped_command,
                            evidence=str(skipped_stage.get("evidence") or ""),
                            package_evidence_profile=bool(skipped_stage.get("packageEvidenceProfile")),
                            package_evidence_product_plan=bool(skipped_stage.get("packageEvidenceProductPlan")),
                            skip_reason="stopped_after_required_failure",
                        ))
                    final_status = "FAIL"
                    break

        records.append(stage_record(
            index=index,
            stage_id=stage_id,
            runner=runner,
            required=required,
            isolated=bool(stage.get("isolated")),
            status=status,
            return_code=return_code,
            stage_dir=stage_dir,
            log_path=log_path if execute else None,
            command=command,
            evidence=str(stage.get("evidence") or ""),
            package_evidence_profile=bool(stage.get("packageEvidenceProfile")),
            package_evidence_product_plan=bool(stage.get("packageEvidenceProductPlan")),
            rescue_artifact=collect_stage_rescue_artifact(stage_dir) if execute else None,
        ))

    if execute:
        if required_failure_count > 0:
            final_status = "FAIL"
        elif failure_count > 0:
            final_status = "PASS_WITH_OPTIONAL_FAILURES"
        else:
            final_status = "PASS"

    return {
        "schemaVersion": 1,
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "campaign": campaign_name,
        "description": str(campaign.get("description") or ""),
        "campaignCatalog": str(catalog_path),
        "execute": execute,
        "stopOnFailure": stop_on_failure,
        "resultDir": str(result_dir),
        "runIDPrefix": run_id_prefix,
        "finalStatus": final_status,
        "failureCount": failure_count,
        "requiredFailureCount": required_failure_count,
        "attemptedStageCount": sum(1 for row in records if row.get("status") in {"PASS", "FAIL"}),
        "skippedStageCount": sum(1 for row in records if row.get("status") == "SKIPPED"),
        "stageCount": len(records),
        "stages": records,
    }


def main() -> int:
    if bool_env("PRODUCT_CAMPAIGN_MATERIALIZE_SELF_TEST", False):
        run_materialize_self_test()
        return 0
    if bool_env("PRODUCT_CAMPAIGN_EXECUTION_SELF_TEST", False):
        run_execution_self_test()
        return 0

    parser = argparse.ArgumentParser(description="Plan or execute product performance campaigns.")
    parser.add_argument("--campaigns", default=str(SCRIPT_DIR / "perf_product_campaigns.json"))
    parser.add_argument("--campaign", default=os.environ.get("PRODUCT_CAMPAIGN", "non-large-group-release"))
    parser.add_argument("--result-dir")
    parser.add_argument("--run-id-prefix")
    parser.add_argument("--json-output")
    parser.add_argument("--runbook-output")
    parser.add_argument("--execute", action="store_true", default=bool_env("PRODUCT_CAMPAIGN_EXECUTE", False))
    parser.add_argument(
        "--no-materialize-evidence-root",
        action="store_true",
        help="Do not copy packageable profile/product-plan artifacts from stage directories to the campaign result root.",
    )
    parser.add_argument(
        "--require-materialized-evidence",
        action="store_true",
        default=False,
        help="Fail an executed PASS campaign if packageable profile/product-plan artifacts cannot be materialized.",
    )
    parser.add_argument("--no-stop-on-failure", action="store_true")
    parser.add_argument("--list-campaigns", action="store_true")
    args = parser.parse_args()

    catalog_path = Path(args.campaigns).resolve()
    catalog = read_json(catalog_path)
    if args.list_campaigns:
        for name in sorted((catalog.get("campaigns") or {})):
            print(name)
        return 0

    result_root = Path(os.environ.get("RESULT_ROOT", str(SCRIPT_DIR / "results"))).expanduser().resolve()
    timestamp = time.strftime("%Y%m%d-%H%M%S", time.localtime())
    result_dir = Path(args.result_dir).expanduser().resolve() if args.result_dir else result_root / f"product-campaign-{slug(args.campaign)}-{timestamp}"
    run_id_prefix = args.run_id_prefix or f"campaign-{slug(args.campaign)}-{timestamp}"
    selected_campaign = load_campaign(catalog, args.campaign)
    stop_on_failure = campaign_stop_on_failure(selected_campaign, cli_no_stop=args.no_stop_on_failure)

    payload = run_campaign(
        catalog_path=catalog_path,
        campaign_name=args.campaign,
        result_dir=result_dir,
        run_id_prefix=run_id_prefix,
        execute=args.execute,
        stop_on_failure=stop_on_failure,
    )
    payload["target"] = target_context(common_runtime_assignments())

    should_materialize = args.execute and not args.no_materialize_evidence_root and bool_env("PRODUCT_CAMPAIGN_MATERIALIZE_EVIDENCE_ROOT", True)
    if should_materialize:
        payload["evidenceRoot"] = materialize_evidence_root(result_dir, payload.get("stages") or [])
    else:
        payload["evidenceRoot"] = {"enabled": False}

    default_require_materialized = args.campaign in {
        "non-large-group-release",
        "production-acceptance",
        "production-full-acceptance",
    }
    require_materialized = args.require_materialized_evidence or bool_env(
        "PRODUCT_CAMPAIGN_REQUIRE_MATERIALIZED_EVIDENCE",
        default_require_materialized,
    )
    enforce_materialized_evidence_requirement(
        payload,
        execute=args.execute,
        should_materialize=should_materialize,
        require_materialized=require_materialized,
    )

    json_output = Path(args.json_output).expanduser().resolve() if args.json_output else result_dir / "product-campaign-run.json"
    runbook_output = Path(args.runbook_output).expanduser().resolve() if args.runbook_output else result_dir / "product-campaign-runbook.md"
    json_output.parent.mkdir(parents=True, exist_ok=True)
    json_output.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    runbook_output.write_text(build_runbook(payload), encoding="utf-8")
    print(f"product_campaign result={payload['finalStatus']} campaign={payload['campaign']} execute={payload['execute']} json={json_output} runbook={runbook_output}")
    return 1 if payload["finalStatus"] == "FAIL" else 0


if __name__ == "__main__":
    raise SystemExit(main())
