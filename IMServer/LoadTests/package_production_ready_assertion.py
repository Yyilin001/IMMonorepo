#!/usr/bin/env python3
from __future__ import annotations

import argparse
import calendar
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path
from typing import Any

from perf_forbidden_artifacts import is_forbidden_runtime_artifact
import verify_production_ready_assertion as assertion_verify

REQUIRED_ARTIFACTS = assertion_verify.REQUIRED_ARTIFACTS
REQUIRED_ARCHIVE_FILES = (
    "production-ready-assertion.json",
    "production-ready-archive-manifest.json",
    "README.md",
    "SHA256SUMS",
)
REQUIRED_ARCHIVE_README_PHRASES = (
    "--require-static-gate-support-root",
    "artifacts/productionStaticGateReceipt/support/",
    "do not rely on original host paths",
)
STATIC_GATE_SUPPORT_ARTIFACTS = (
    ("completionStatus", ("completionStatus", "path")),
    ("completionStatusMarkdown", ("completionStatus", "markdownPath")),
    ("recoveryPlan", ("recoveryPlan", "path")),
    ("recoveryPlanMarkdown", ("recoveryPlan", "markdownPath")),
    ("recoveryPlanScript", ("recoveryPlan", "scriptPath")),
)
FORBIDDEN_MANIFEST_HOST_PATH_FIELDS = {"sourcePath", "sourceReceipt", "archiveFile"}
ARCHIVE_STATIC_GATE_REPO_ROOT = "/imserver-production-ready-archive/repo"
FORBIDDEN_ARCHIVE_MARKDOWN_PATH_MARKERS = ("/Users/", "/var/folders/", "/private/var/", "/tmp/", "\\Users\\")
SENSITIVE_BEARER_OUTPUT_PATTERN = re.compile(r"(?i)(\bAuthorization\b\s*(?::|=|\s+)\s*Bearer\s+)([^\s|,;]+)")
SENSITIVE_VERIFIER_OUTPUT_PATTERN = re.compile(
    r"(?i)([\"']?\b[A-Z0-9_]*(?:PASSWORD|PASSWD|SECRET|TOKEN|AUTHORIZATION|COOKIE|JWT|API[_-]?KEY)[A-Z0-9_-]*\b[\"']?\s*(?::|=|\s+)\s*)"
    r"([\"']?)([^\s|,;}\"']+)(\2)"
)
MAX_ARCHIVE_MEMBER_BYTES = 512 * 1024 * 1024
MAX_ARCHIVE_TOTAL_BYTES = 2 * 1024 * 1024 * 1024


def fail(reason: str, detail: str = "") -> None:
    suffix = f" {detail}" if detail else ""
    raise SystemExit(f"production_ready_assertion_package result=fail reason={reason}{suffix}")


def verifier_output(completed: subprocess.CompletedProcess[str]) -> str:
    output = "\n".join(part for part in (completed.stdout, completed.stderr) if part)
    output = output.strip().replace("\n", " | ")
    output = SENSITIVE_BEARER_OUTPUT_PATTERN.sub(lambda match: f"{match.group(1)}<redacted>", output)
    output = SENSITIVE_VERIFIER_OUTPUT_PATTERN.sub(lambda match: f"{match.group(1)}{match.group(2)}<redacted>{match.group(4)}", output)
    return output[:4000] if output else "-"


def run_verifier_command(command: list[str], reason: str) -> None:
    completed = subprocess.run(
        command,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if completed.returncode != 0:
        fail(reason, f"exit={completed.returncode} verifierOutput={verifier_output(completed)}")


def load_json(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        fail("invalid_json", f"path={path} detail={exc}")
    if not isinstance(payload, dict):
        fail("json_not_object", f"path={path}")
    return payload


def sha256_file(path: Path) -> tuple[int, str]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            size += len(chunk)
            digest.update(chunk)
    return size, digest.hexdigest()


def require_json_int(payload: dict[str, Any], field: str, reason: str, detail: str = "") -> int:
    value = payload.get(field)
    if not isinstance(value, int) or isinstance(value, bool):
        suffix = f"{detail} " if detail else ""
        fail(reason, f"{suffix}field={field} value={value}")
    return value


def record_file(path: Path, relative_path: Path) -> dict[str, Any]:
    size, digest = sha256_file(path)
    return {
        "path": relative_path.as_posix(),
        "fileName": path.name,
        "bytes": size,
        "sha256": digest,
    }


def safe_file_name(value: str, fallback: str) -> str:
    candidate = Path(str(value or "")).name.strip()
    if not candidate or candidate in {".", ".."}:
        candidate = fallback
    return candidate


def looks_like_host_path(value: str) -> bool:
    text = value.strip()
    return text.startswith("/") or text.startswith("~/") or re.match(r"^[A-Za-z]:[\\/]", text) is not None


def replace_string_value(value: Any, old: str, new: str) -> Any:
    if not old:
        return value
    if isinstance(value, dict):
        return {key: replace_string_value(child, old, new) for key, child in value.items()}
    if isinstance(value, list):
        return [replace_string_value(child, old, new) for child in value]
    if isinstance(value, str):
        return value.replace(old, new)
    return value


def verify_manifest_has_no_host_paths(value: Any, location: str = "$") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            field = str(key)
            child_location = f"{location}.{field}"
            if field in FORBIDDEN_MANIFEST_HOST_PATH_FIELDS:
                fail("archive_manifest_host_path_field", f"field={child_location}")
            verify_manifest_has_no_host_paths(child, child_location)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            verify_manifest_has_no_host_paths(child, f"{location}[{index}]")
    elif isinstance(value, str) and looks_like_host_path(value):
        fail("archive_manifest_host_path_value", f"field={location}")


def require_manifest_file_name(manifest: dict[str, Any], field: str) -> str:
    value = str(manifest.get(field) or "")
    path = Path(value)
    if not value:
        fail("archive_manifest_file_name_missing", f"field={field}")
    if looks_like_host_path(value) or "/" in value or "\\" in value or path.name != value or value in {".", ".."}:
        fail("archive_manifest_file_name_invalid", f"field={field} value={value or '-'}")
    return value


def require_manifest_generated_at(manifest: dict[str, Any], max_future_skew_seconds: int) -> int:
    generated_at_epoch = require_json_int(manifest, "generatedAtEpoch", "archive_manifest_generated_at_epoch_invalid")
    if generated_at_epoch <= 0:
        fail("archive_manifest_generated_at_epoch_invalid", f"value={generated_at_epoch}")
    now = int(time.time())
    if generated_at_epoch > now + max_future_skew_seconds:
        fail("archive_manifest_generated_at_future", f"generatedAtEpoch={generated_at_epoch} now={now}")
    generated_at = str(manifest.get("generatedAt") or "")
    try:
        parsed_epoch = int(calendar.timegm(time.strptime(generated_at, "%Y-%m-%dT%H:%M:%SZ")))
    except Exception:
        fail("archive_manifest_generated_at_invalid", f"value={generated_at or '-'}")
    if abs(parsed_epoch - generated_at_epoch) > 1:
        fail(
            "archive_manifest_generated_at_mismatch",
            f"generatedAt={generated_at} generatedAtEpoch={generated_at_epoch}",
        )
    return generated_at_epoch


def require_manifest_not_before_assertion(manifest_epoch: int, assertion_payload: dict[str, Any]) -> None:
    assertion_epoch = require_json_int(assertion_payload, "generatedAtEpoch", "archive_assertion_generated_at_epoch_invalid")
    if assertion_epoch <= 0:
        fail("archive_assertion_generated_at_epoch_invalid", f"value={assertion_epoch}")
    if assertion_epoch > manifest_epoch + 1:
        fail(
            "archive_manifest_before_assertion",
            f"manifestGeneratedAtEpoch={manifest_epoch} assertionGeneratedAtEpoch={assertion_epoch}",
        )


def nested_value(payload: dict[str, Any], keys: tuple[str, str]) -> str:
    parent = payload.get(keys[0])
    if not isinstance(parent, dict):
        fail("static_gate_support_binding_missing", f"field={keys[0]}")
    value = str(parent.get(keys[1]) or "")
    if not value:
        fail("static_gate_support_binding_missing", f"field={keys[0]}.{keys[1]}")
    return value


def copy_static_gate_support_files(static_gate_path: Path, stage_dir: Path) -> dict[str, Any]:
    payload = load_json(static_gate_path)
    copied_paths: dict[str, Path] = {}
    support_dir = stage_dir / "artifacts" / "productionStaticGateReceipt" / "support"
    for field, keys in STATIC_GATE_SUPPORT_ARTIFACTS:
        source = Path(nested_value(payload, keys)).expanduser()
        if not source.is_file():
            fail("static_gate_support_file_missing", f"field={field} path={source}")
        target_dir = support_dir / field
        target_dir.mkdir(parents=True, exist_ok=True)
        target = target_dir / safe_file_name(source.name, f"{field}.json")
        shutil.copyfile(source, target)
        if field == "recoveryPlanScript":
            target.chmod(0o755)
        copied_paths[field] = target
    rewrite_static_gate_support_files_for_archive(copied_paths, stage_dir)
    support: dict[str, Any] = {}
    for field, target in copied_paths.items():
        support[field] = record_file(target, target.relative_to(stage_dir))
    return support


def rewrite_static_gate_support_files_for_archive(copied_paths: dict[str, Path], stage_dir: Path) -> None:
    completion_path = copied_paths.get("completionStatus")
    completion_markdown_path = copied_paths.get("completionStatusMarkdown")
    recovery_plan_path = copied_paths.get("recoveryPlan")
    if completion_path is None or completion_markdown_path is None or recovery_plan_path is None:
        fail("static_gate_support_rewrite_missing")
    completion = load_json(completion_path)
    original_repo_root = str(completion.get("repoRoot") or "")
    completion = replace_string_value(completion, original_repo_root, ARCHIVE_STATIC_GATE_REPO_ROOT)
    completion["repoRoot"] = ARCHIVE_STATIC_GATE_REPO_ROOT
    completion_path.write_text(json.dumps(completion, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    completion_markdown = completion_markdown_path.read_text(encoding="utf-8")
    if original_repo_root:
        completion_markdown = completion_markdown.replace(original_repo_root, ARCHIVE_STATIC_GATE_REPO_ROOT)
    completion_markdown_path.write_text(completion_markdown, encoding="utf-8")

    recovery_plan = load_json(recovery_plan_path)
    recovery_plan["sourceStatusJson"] = completion_path.relative_to(stage_dir).as_posix()
    recovery_plan_path.write_text(json.dumps(recovery_plan, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def rewrite_static_gate_receipt_for_archive(static_gate_target: Path, support_artifacts: dict[str, Any]) -> None:
    payload = load_json(static_gate_target)
    completion = payload.get("completionStatus")
    recovery_plan = payload.get("recoveryPlan")
    if not isinstance(completion, dict):
        fail("static_gate_completion_status_missing", f"path={static_gate_target}")
    if not isinstance(recovery_plan, dict):
        fail("static_gate_recovery_plan_missing", f"path={static_gate_target}")
    payload["repoRoot"] = ARCHIVE_STATIC_GATE_REPO_ROOT
    completion["repoRoot"] = ARCHIVE_STATIC_GATE_REPO_ROOT
    completion["path"] = str(support_artifacts["completionStatus"]["path"])
    completion["sha256"] = str(support_artifacts["completionStatus"]["sha256"])
    completion["markdownPath"] = str(support_artifacts["completionStatusMarkdown"]["path"])
    completion["markdownSha256"] = str(support_artifacts["completionStatusMarkdown"]["sha256"])
    recovery_plan["path"] = str(support_artifacts["recoveryPlan"]["path"])
    recovery_plan["sha256"] = str(support_artifacts["recoveryPlan"]["sha256"])
    recovery_plan["markdownPath"] = str(support_artifacts["recoveryPlanMarkdown"]["path"])
    recovery_plan["markdownSha256"] = str(support_artifacts["recoveryPlanMarkdown"]["sha256"])
    recovery_plan["scriptPath"] = str(support_artifacts["recoveryPlanScript"]["path"])
    recovery_plan["scriptSha256"] = str(support_artifacts["recoveryPlanScript"]["sha256"])
    recovery_plan["sourceStatusJson"] = str(support_artifacts["completionStatus"]["path"])
    static_gate_target.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def verify_archived_static_gate_receipt_support_paths(static_gate_path: Path, support_artifacts: dict[str, Any]) -> None:
    payload = load_json(static_gate_path)
    if str(payload.get("repoRoot") or "") != ARCHIVE_STATIC_GATE_REPO_ROOT:
        fail("archive_static_gate_repo_root_mismatch", f"path={static_gate_path}")
    completion_payload = payload.get("completionStatus")
    completion_target = archived_static_gate_target(completion_payload, "staticGateReceipt.completionStatus")
    completion_claim = verify_archived_static_gate_claim(completion_payload, "staticGateReceipt.completionStatus")
    completion_tiers = verify_archived_static_gate_readiness_tiers(completion_payload, "staticGateReceipt.completionStatus")
    recovery_payload = payload.get("recoveryPlan")
    recovery_target = archived_static_gate_target(recovery_payload, "staticGateReceipt.recoveryPlan")
    if recovery_target != completion_target:
        fail("archive_static_gate_recovery_target_mismatch", "field=recoveryPlan.productionTarget")
    recovery_claim = archived_static_gate_claim(recovery_payload, "staticGateReceipt.recoveryPlan")
    if recovery_claim != completion_claim:
        fail("archive_static_gate_recovery_claim_mismatch", "field=recoveryPlan.productionClaim")
    recovery_tiers = archived_static_gate_readiness_tiers(recovery_payload, "staticGateReceipt.recoveryPlan")
    if recovery_tiers != completion_tiers:
        fail("archive_static_gate_recovery_readiness_tiers_mismatch", "field=recoveryPlan.readinessTiers")
    checks = (
        ("completionStatus", "path", "sha256", "completionStatus"),
        ("completionStatus", "markdownPath", "markdownSha256", "completionStatusMarkdown"),
        ("recoveryPlan", "path", "sha256", "recoveryPlan"),
        ("recoveryPlan", "markdownPath", "markdownSha256", "recoveryPlanMarkdown"),
        ("recoveryPlan", "scriptPath", "scriptSha256", "recoveryPlanScript"),
        ("recoveryPlan", "sourceStatusJson", "", "completionStatus"),
    )
    for section, field, sha_field, support_field in checks:
        section_payload = payload.get(section)
        if not isinstance(section_payload, dict):
            fail("archive_static_gate_section_missing", f"field={section}")
        actual = str(section_payload.get(field) or "")
        expected_record = support_artifacts.get(support_field)
        if not isinstance(expected_record, dict):
            fail("archive_static_gate_support_record_missing", f"field={support_field}")
        expected = str(expected_record.get("path") or "")
        if looks_like_host_path(actual):
            fail("archive_static_gate_host_path", f"field={section}.{field}")
        if actual != expected:
            fail("archive_static_gate_support_path_mismatch", f"field={section}.{field} expected={expected or '-'} actual={actual or '-'}")
        if sha_field:
            actual_sha = str(section_payload.get(sha_field) or "")
            expected_sha = str(expected_record.get("sha256") or "")
            if actual_sha != expected_sha:
                fail(
                    "archive_static_gate_support_sha_mismatch",
                    f"field={section}.{sha_field} expected={expected_sha or '-'} actual={actual_sha or '-'}",
                )
    completion = payload.get("completionStatus")
    if not isinstance(completion, dict) or str(completion.get("repoRoot") or "") != ARCHIVE_STATIC_GATE_REPO_ROOT:
        fail("archive_static_gate_completion_repo_root_mismatch", f"path={static_gate_path}")
    archive_root = static_gate_path.parents[2] if len(static_gate_path.parents) >= 3 else static_gate_path.parent
    support_completion_record = support_artifacts.get("completionStatus")
    if isinstance(support_completion_record, dict):
        support_completion_path = archive_root / str(support_completion_record.get("path") or "")
        if support_completion_path.is_file():
            support_completion = load_json(support_completion_path)
            if support_completion.get("readinessTiers") != completion.get("readinessTiers"):
                fail("archive_static_gate_readiness_tiers_mismatch", "field=completionStatus.readinessTiers")


def archived_static_gate_target(value: Any, location: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail("archive_static_gate_target_missing", f"field={location}")
    target = value.get("productionTarget")
    if not isinstance(target, dict):
        fail("archive_static_gate_target_missing", f"field={location}.productionTarget")
    missing_env = target.get("missingEnv")
    if not isinstance(missing_env, list) or not all(isinstance(item, str) for item in missing_env):
        fail("archive_static_gate_target_mismatch", f"field={location}.productionTarget.missingEnv")
    for field in ("baseURL", "tcpHost", "tcpPort"):
        if not isinstance(target.get(field), str):
            fail("archive_static_gate_target_mismatch", f"field={location}.productionTarget.{field}")
    return {
        "baseURL": target["baseURL"],
        "tcpHost": target["tcpHost"],
        "tcpPort": target["tcpPort"],
        "missingEnv": list(missing_env),
    }


def archived_static_gate_claim(value: Any, location: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail("archive_static_gate_claim_missing", f"field={location}")
    claim = value.get("productionClaim")
    if not isinstance(claim, dict):
        fail("archive_static_gate_claim_missing", f"field={location}.productionClaim")
    required_evidence = claim.get("requiredEvidence")
    blockers = claim.get("blockers")
    if (
        not isinstance(required_evidence, list)
        or not all(isinstance(item, str) for item in required_evidence)
        or not isinstance(blockers, list)
        or not all(isinstance(item, str) for item in blockers)
        or not isinstance(claim.get("claimLevel"), str)
        or not isinstance(claim.get("basis"), str)
    ):
        fail("archive_static_gate_claim_mismatch", f"field={location}.productionClaim")
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
    for field in bool_fields:
        if not isinstance(claim.get(field), bool):
            fail("archive_static_gate_claim_mismatch", f"field={location}.productionClaim.{field}")
    return {
        **{field: claim[field] for field in bool_fields},
        "claimLevel": claim["claimLevel"],
        "basis": claim["basis"],
        "requiredEvidence": list(required_evidence),
        "blockers": list(blockers),
    }


def verify_archived_static_gate_claim(value: Any, location: str) -> dict[str, Any]:
    claim = archived_static_gate_claim(value, location)
    if claim.get("productionReady") is True or claim.get("claimAllowed") is True:
        fail("archive_static_gate_claim_mismatch", f"field={location}.productionClaim")
    if str(claim.get("claimLevel") or "") != "not-production-ready":
        fail("archive_static_gate_claim_mismatch", f"field={location}.productionClaim.claimLevel")
    if str(claim.get("basis") or "") != "local-engineering-or-partial-evidence-only":
        fail("archive_static_gate_claim_mismatch", f"field={location}.productionClaim.basis")
    return claim


def archived_static_gate_readiness_tiers(value: Any, location: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail("archive_static_gate_readiness_tiers_missing", f"field={location}")
    tiers = value.get("readinessTiers")
    if not isinstance(tiers, dict):
        fail("archive_static_gate_readiness_tiers_missing", f"field={location}.readinessTiers")
    local_tier = tiers.get("localEngineering")
    live_tier = tiers.get("liveProductionEvidence")
    production_tier = tiers.get("productionReady")
    if not isinstance(local_tier, dict) or not isinstance(live_tier, dict) or not isinstance(production_tier, dict):
        fail("archive_static_gate_readiness_tiers_missing", f"field={location}.readinessTiers")
    if sorted(str(item) for item in tiers) != ["liveProductionEvidence", "localEngineering", "productionReady"]:
        fail("archive_static_gate_readiness_tiers_mismatch", f"field={location}.readinessTiers")
    local_tier_fields = {"status", "percent", "passed", "total", "claim"}
    production_tier_fields = {"status", "percent", "claimAllowed", "targetComplete", "blockingReasons", "claim"}
    if set(str(item) for item in local_tier) != local_tier_fields:
        fail("archive_static_gate_readiness_tiers_mismatch", f"field={location}.readinessTiers.localEngineering")
    if set(str(item) for item in live_tier) != local_tier_fields:
        fail("archive_static_gate_readiness_tiers_mismatch", f"field={location}.readinessTiers.liveProductionEvidence")
    if set(str(item) for item in production_tier) != production_tier_fields:
        fail("archive_static_gate_readiness_tiers_mismatch", f"field={location}.readinessTiers.productionReady")
    for tier_name, tier in (("localEngineering", local_tier), ("liveProductionEvidence", live_tier)):
        if not isinstance(tier.get("status"), str):
            fail("archive_static_gate_readiness_tiers_mismatch", f"field={location}.readinessTiers.{tier_name}.status")
        for field in ("percent", "passed", "total"):
            raw_value = tier.get(field)
            if not isinstance(raw_value, int) or isinstance(raw_value, bool):
                fail("archive_static_gate_readiness_tiers_mismatch", f"field={location}.readinessTiers.{tier_name}.{field}")
        if not isinstance(tier.get("claim"), str):
            fail("archive_static_gate_readiness_tiers_mismatch", f"field={location}.readinessTiers.{tier_name}.claim")
    if not isinstance(production_tier.get("status"), str):
        fail("archive_static_gate_readiness_tiers_mismatch", f"field={location}.readinessTiers.productionReady.status")
    production_percent = production_tier.get("percent")
    if not isinstance(production_percent, int) or isinstance(production_percent, bool):
        fail("archive_static_gate_readiness_tiers_mismatch", f"field={location}.readinessTiers.productionReady.percent")
    for field in ("claimAllowed", "targetComplete"):
        if not isinstance(production_tier.get(field), bool):
            fail("archive_static_gate_readiness_tiers_mismatch", f"field={location}.readinessTiers.productionReady.{field}")
    blocking_reasons = production_tier.get("blockingReasons")
    if not isinstance(blocking_reasons, list) or not all(isinstance(item, str) for item in blocking_reasons):
        fail("archive_static_gate_readiness_tiers_mismatch", f"field={location}.readinessTiers.productionReady.blockingReasons")
    if not isinstance(production_tier.get("claim"), str):
        fail("archive_static_gate_readiness_tiers_mismatch", f"field={location}.readinessTiers.productionReady.claim")
    try:
        normalized: dict[str, Any] = {
            "localEngineering": {
                "status": str(local_tier.get("status") or ""),
                "percent": int(local_tier.get("percent", -1)),
                "passed": int(local_tier.get("passed", -1)),
                "total": int(local_tier.get("total", -1)),
                "claim": str(local_tier.get("claim") or ""),
            },
            "liveProductionEvidence": {
                "status": str(live_tier.get("status") or ""),
                "percent": int(live_tier.get("percent", -1)),
                "passed": int(live_tier.get("passed", -1)),
                "total": int(live_tier.get("total", -1)),
                "claim": str(live_tier.get("claim") or ""),
            },
            "productionReady": {
                "status": str(production_tier.get("status") or ""),
                "percent": int(production_tier.get("percent", -1)),
                "claimAllowed": bool(production_tier.get("claimAllowed")),
                "targetComplete": bool(production_tier.get("targetComplete")),
                "blockingReasons": [str(item) for item in production_tier.get("blockingReasons", [])],
                "claim": str(production_tier.get("claim") or ""),
            },
        }
    except Exception:
        fail("archive_static_gate_readiness_tiers_mismatch", f"field={location}.readinessTiers")
    if not isinstance(production_tier.get("blockingReasons"), list):
        fail("archive_static_gate_readiness_tiers_mismatch", f"field={location}.readinessTiers.productionReady.blockingReasons")
    return normalized


def verify_archived_static_gate_readiness_tiers(value: Any, location: str) -> dict[str, Any]:
    normalized = archived_static_gate_readiness_tiers(value, location)
    if not isinstance(value, dict):
        fail("archive_static_gate_readiness_tiers_missing", f"field={location}")
    local_tier = normalized["localEngineering"]
    live_tier = normalized["liveProductionEvidence"]
    production_tier = normalized["productionReady"]
    expected_percents = (
        ("localEngineering", local_tier, "localCompletionPercent"),
        ("liveProductionEvidence", live_tier, "liveEvidenceCompletionPercent"),
        ("productionReady", production_tier, "productionCompletionPercent"),
    )
    for tier_name, tier, completion_field in expected_percents:
        try:
            tier_percent = int(tier.get("percent", -1))
            completion_percent = int(value.get(completion_field, -1))
        except Exception:
            fail("archive_static_gate_readiness_tiers_mismatch", f"field={location}.readinessTiers.{tier_name}.percent")
        if tier_percent != completion_percent:
            fail("archive_static_gate_readiness_tiers_mismatch", f"field={location}.readinessTiers.{tier_name}.percent")
    if str(local_tier.get("status") or "") != "complete" or int(local_tier.get("percent", -1)) != 100:
        fail("archive_static_gate_readiness_tiers_mismatch", f"field={location}.readinessTiers.localEngineering")
    if str(local_tier.get("claim") or "") != "local-engineering-complete":
        fail("archive_static_gate_readiness_tiers_mismatch", f"field={location}.readinessTiers.localEngineering.claim")
    if production_tier.get("claimAllowed") is True:
        fail("archive_static_gate_readiness_tiers_mismatch", f"field={location}.readinessTiers.productionReady.claimAllowed")
    if str(production_tier.get("status") or "") == "ready":
        fail("archive_static_gate_readiness_tiers_mismatch", f"field={location}.readinessTiers.productionReady.status")
    if str(production_tier.get("claim") or "") == "production-ready":
        fail("archive_static_gate_readiness_tiers_mismatch", f"field={location}.readinessTiers.productionReady.claim")
    blockers = production_tier.get("blockingReasons")
    if not isinstance(blockers, list) or not blockers:
        fail("archive_static_gate_readiness_tiers_mismatch", f"field={location}.readinessTiers.productionReady.blockingReasons")
    return normalized


def verify_archived_static_gate_support_payloads(root: Path, support_artifacts: dict[str, Any]) -> None:
    completion_record = support_artifacts.get("completionStatus")
    completion_markdown_record = support_artifacts.get("completionStatusMarkdown")
    recovery_record = support_artifacts.get("recoveryPlan")
    recovery_markdown_record = support_artifacts.get("recoveryPlanMarkdown")
    recovery_script_record = support_artifacts.get("recoveryPlanScript")
    if (
        not isinstance(completion_record, dict)
        or not isinstance(completion_markdown_record, dict)
        or not isinstance(recovery_record, dict)
        or not isinstance(recovery_markdown_record, dict)
        or not isinstance(recovery_script_record, dict)
    ):
        fail("archive_static_gate_support_payload_record_missing")
    completion_rel = str(completion_record.get("path") or "")
    completion_markdown_rel = str(completion_markdown_record.get("path") or "")
    recovery_rel = str(recovery_record.get("path") or "")
    recovery_markdown_rel = str(recovery_markdown_record.get("path") or "")
    recovery_script_rel = str(recovery_script_record.get("path") or "")
    completion = load_json(root / completion_rel)
    completion_markdown = (root / completion_markdown_rel).read_text(encoding="utf-8")
    recovery_plan = load_json(root / recovery_rel)
    recovery_markdown = (root / recovery_markdown_rel).read_text(encoding="utf-8")
    recovery_script = (root / recovery_script_rel).read_text(encoding="utf-8")
    completion_repo_root = str(completion.get("repoRoot") or "")
    if looks_like_host_path(completion_repo_root) and completion_repo_root != ARCHIVE_STATIC_GATE_REPO_ROOT:
        fail("archive_static_gate_support_host_path", "field=completionStatus.repoRoot")
    if completion_repo_root != ARCHIVE_STATIC_GATE_REPO_ROOT:
        fail("archive_static_gate_support_repo_root_mismatch", f"actual={completion_repo_root or '-'}")
    completion_target = archived_static_gate_target(completion, "support.completionStatus")
    completion_claim = verify_archived_static_gate_claim(completion, "support.completionStatus")
    completion_tiers = verify_archived_static_gate_readiness_tiers(completion, "support.completionStatus")
    recovery_target = archived_static_gate_target(recovery_plan, "support.recoveryPlan")
    if recovery_target != completion_target:
        fail("archive_static_gate_recovery_target_mismatch", "field=support.recoveryPlan.productionTarget")
    recovery_claim = archived_static_gate_claim(recovery_plan, "support.recoveryPlan")
    if recovery_claim != completion_claim:
        fail("archive_static_gate_recovery_claim_mismatch", "field=support.recoveryPlan.productionClaim")
    recovery_tiers = archived_static_gate_readiness_tiers(recovery_plan, "support.recoveryPlan")
    if recovery_tiers != completion_tiers:
        fail("archive_static_gate_recovery_readiness_tiers_mismatch", "field=support.recoveryPlan.readinessTiers")
    if ARCHIVE_STATIC_GATE_REPO_ROOT not in completion_markdown:
        fail("archive_static_gate_support_markdown_repo_root_missing")
    for marker in FORBIDDEN_ARCHIVE_MARKDOWN_PATH_MARKERS:
        if marker in completion_markdown:
            fail("archive_static_gate_support_markdown_host_path", f"marker={marker}")
        if marker in recovery_markdown:
            fail("archive_static_gate_support_text_host_path", f"field=recoveryPlanMarkdown marker={marker}")
        if marker in recovery_script:
            fail("archive_static_gate_support_text_host_path", f"field=recoveryPlanScript marker={marker}")
    source_status_json = str(recovery_plan.get("sourceStatusJson") or "")
    if looks_like_host_path(source_status_json):
        fail("archive_static_gate_support_host_path", "field=recoveryPlan.sourceStatusJson")
    if source_status_json != completion_rel:
        fail("archive_static_gate_support_source_status_mismatch", f"expected={completion_rel} actual={source_status_json or '-'}")


def verify_source_receipt(args: argparse.Namespace) -> None:
    command = [
        sys.executable,
        str(Path(__file__).with_name("verify_production_ready_assertion.py")),
        "--receipt-json",
        str(args.receipt_json),
        "--require-pass",
        "--require-artifacts-exist",
        "--max-age-seconds",
        str(args.max_age_seconds),
        "--max-future-skew-seconds",
        str(args.max_future_skew_seconds),
    ]
    if args.expect_base_url:
        command.extend(["--expect-base-url", args.expect_base_url])
    if args.expect_tcp_host:
        command.extend(["--expect-tcp-host", args.expect_tcp_host])
    if args.expect_tcp_port:
        command.extend(["--expect-tcp-port", str(args.expect_tcp_port)])
    for artifact_root in args.artifact_root or []:
        command.extend(["--artifact-root", artifact_root])
    run_verifier_command(command, "source_receipt_verify_failed")


def copy_artifacts(receipt: dict[str, Any], stage_dir: Path, artifact_roots: list[str]) -> dict[str, Any]:
    source_artifacts = receipt.get("artifacts")
    if not isinstance(source_artifacts, dict):
        fail("receipt_artifacts_missing")

    copied: dict[str, Any] = {}
    artifact_dir = stage_dir / "artifacts"
    for key in REQUIRED_ARTIFACTS:
        record = source_artifacts.get(key)
        if not isinstance(record, dict):
            fail("receipt_artifact_missing", f"field={key}")
        source = assertion_verify.resolve_artifact_path(record, key, artifact_roots)
        expected_bytes = require_json_int(record, "bytes", "source_artifact_bytes_invalid", f"field={key}")
        expected_sha = str(record.get("sha256") or "")
        actual_bytes, actual_sha = sha256_file(source)
        if actual_bytes != expected_bytes:
            fail("source_artifact_bytes_mismatch", f"field={key} expected={expected_bytes} actual={actual_bytes}")
        if actual_sha != expected_sha:
            fail("source_artifact_sha256_mismatch", f"field={key}")

        file_name = safe_file_name(str(record.get("fileName") or source.name), f"{key}.artifact")
        target_dir = artifact_dir / key
        target_dir.mkdir(parents=True, exist_ok=True)
        target = target_dir / file_name
        shutil.copyfile(source, target)
        if key == "productionStaticGateReceipt":
            support_artifacts = copy_static_gate_support_files(source, stage_dir)
            rewrite_static_gate_receipt_for_archive(target, support_artifacts)
            copied[key] = record_file(target, target.relative_to(stage_dir))
            copied[key]["supportArtifacts"] = support_artifacts
        else:
            copied[key] = record_file(target, target.relative_to(stage_dir))
    return copied


def archived_assertion_payload(receipt: dict[str, Any], copied_artifacts: dict[str, Any]) -> dict[str, Any]:
    payload = json.loads(json.dumps(receipt))
    payload["artifacts"] = copied_artifacts
    return payload


def verify_archived_assertion_has_no_host_paths(root: Path) -> None:
    assertion_path = root / "production-ready-assertion.json"
    payload = load_json(assertion_path)
    artifacts = payload.get("artifacts")
    if not isinstance(artifacts, dict):
        fail("archive_assertion_artifacts_missing")
    for key in REQUIRED_ARTIFACTS:
        record = artifacts.get(key)
        if not isinstance(record, dict):
            fail("archive_assertion_artifact_missing", f"field={key}")
        rel = str(record.get("path") or "")
        if looks_like_host_path(rel):
            fail("archive_assertion_host_path", f"field=artifacts.{key}.path")
        if not rel.startswith(f"artifacts/{key}/"):
            fail("archive_assertion_artifact_path_invalid", f"field={key} path={rel or '-'}")


def write_readme(stage_dir: Path, receipt: dict[str, Any], archive_name: str) -> None:
    target = receipt.get("target") or {}
    lines = [
        "# IMServer Production-Ready Assertion Archive",
        "",
        "This archive is self-contained evidence for one successful final production-ready assertion.",
        "",
        f"- status: `{receipt.get('status') or '-'}`",
        f"- baseURL: `{target.get('baseURL') or '-'}`",
        f"- tcpHost: `{target.get('tcpHost') or '-'}`",
        f"- tcpPort: `{target.get('tcpPort') or '-'}`",
        f"- archive: `{archive_name}`",
        "",
        "Verify after extraction:",
        "",
        "```sh",
        "python3 IMServer/LoadTests/verify_production_ready_assertion.py \\",
        "  --receipt-json production-ready-assertion.json \\",
        "  --artifact-root artifacts \\",
        "  --require-pass \\",
        "  --require-artifacts-exist \\",
        "  --require-static-gate-support-root",
        "```",
        "",
        "The archive must be verified against its copied static gate support files under",
        "`artifacts/productionStaticGateReceipt/support/`; do not rely on original host paths.",
        "",
    ]
    (stage_dir / "README.md").write_text("\n".join(lines), encoding="utf-8")


def write_sha256sums(stage_dir: Path) -> None:
    rows: list[str] = []
    for path in sorted(stage_dir.rglob("*")):
        if not path.is_file() or path.name == "SHA256SUMS":
            continue
        size, digest = sha256_file(path)
        rel = path.relative_to(stage_dir).as_posix()
        rows.append(f"{digest}  {rel}")
    (stage_dir / "SHA256SUMS").write_text("\n".join(rows) + "\n", encoding="utf-8")


def create_archive(stage_dir: Path, archive_path: Path) -> None:
    archive_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = archive_path.with_suffix(archive_path.suffix + ".tmp")
    with tarfile.open(tmp_path, "w:gz") as archive:
        for path in sorted(stage_dir.rglob("*")):
            if path.is_file():
                archive.add(path, arcname=path.relative_to(stage_dir).as_posix())
    os.replace(tmp_path, archive_path)


def forbidden_runtime_artifact_name(name: str) -> bool:
    return is_forbidden_runtime_artifact(name)


def validate_archive_member(member: tarfile.TarInfo, max_member_bytes: int = MAX_ARCHIVE_MEMBER_BYTES) -> str:
    name = str(member.name or "")
    path = Path(name)
    if not name or name.startswith("/") or path.is_absolute():
        fail("archive_member_path_unsafe", f"name={name or '-'}")
    if "\\" in name or any(part in {"", ".", ".."} for part in path.parts):
        fail("archive_member_path_unsafe", f"name={name}")
    if forbidden_runtime_artifact_name(name):
        fail("archive_member_forbidden_artifact", f"name={name}")
    if not member.isfile():
        fail("archive_member_not_file", f"name={name}")
    if member.size < 0:
        fail("archive_member_size_invalid", f"name={name} size={member.size}")
    if member.size > max_member_bytes:
        fail("archive_member_too_large", f"name={name} size={member.size} max={max_member_bytes}")
    return path.as_posix()


def safe_extract_archive(
    archive_path: Path,
    extract_dir: Path,
    max_member_bytes: int = MAX_ARCHIVE_MEMBER_BYTES,
    max_total_bytes: int = MAX_ARCHIVE_TOTAL_BYTES,
) -> list[str]:
    names: list[str] = []
    seen: set[str] = set()
    total_bytes = 0
    root = extract_dir.resolve()
    try:
        with tarfile.open(archive_path, "r:gz") as archive:
            for member in archive.getmembers():
                name = validate_archive_member(member, max_member_bytes=max_member_bytes)
                if name in seen:
                    fail("archive_member_duplicate", f"name={name}")
                seen.add(name)
                total_bytes += member.size
                if total_bytes > max_total_bytes:
                    fail("archive_total_too_large", f"size={total_bytes} max={max_total_bytes}")
                target = (root / name).resolve()
                if root not in target.parents:
                    fail("archive_member_path_unsafe", f"name={name}")
                target.parent.mkdir(parents=True, exist_ok=True)
                source = archive.extractfile(member)
                if source is None:
                    fail("archive_member_read_failed", f"name={name}")
                with source, target.open("wb") as output:
                    shutil.copyfileobj(source, output)
                target.chmod(member.mode & 0o777)
                names.append(name)
    except tarfile.TarError as exc:
        fail("archive_invalid", f"path={archive_path} detail={exc}")
    return names


def verify_sha256sums(root: Path, member_names: list[str]) -> None:
    checksums_path = root / "SHA256SUMS"
    if not checksums_path.is_file():
        fail("archive_sha256sums_missing")
    expected_members = sorted(name for name in member_names if name != "SHA256SUMS")
    seen: set[str] = set()
    for lineno, line in enumerate(checksums_path.read_text(encoding="utf-8").splitlines(), start=1):
        if not line.strip():
            continue
        if "  " not in line:
            fail("archive_sha256sums_line_invalid", f"line={lineno}")
        digest, name = line.split("  ", 1)
        path = Path(name)
        if len(digest) != 64 or any(ch not in "0123456789abcdef" for ch in digest.lower()):
            fail("archive_sha256sums_digest_invalid", f"line={lineno}")
        if not name or name.startswith("/") or path.is_absolute() or "\\" in name or any(part in {"", ".", ".."} for part in path.parts):
            fail("archive_sha256sums_path_unsafe", f"line={lineno} path={name or '-'}")
        if name in seen:
            fail("archive_sha256sums_duplicate", f"path={name}")
        seen.add(name)
        target = root / name
        if not target.is_file():
            fail("archive_sha256sums_file_missing", f"path={name}")
        _, actual = sha256_file(target)
        if actual != digest:
            fail("archive_sha256sums_mismatch", f"path={name}")
    missing = sorted(set(expected_members) - seen)
    extra = sorted(seen - set(expected_members))
    if missing:
        fail("archive_sha256sums_member_missing", f"path={missing[0]}")
    if extra:
        fail("archive_sha256sums_member_extra", f"path={extra[0]}")


def verify_manifest(root: Path, archive_path: Path, max_future_skew_seconds: int) -> dict[str, Any]:
    manifest_path = root / "production-ready-archive-manifest.json"
    manifest = load_json(manifest_path)
    verify_manifest_has_no_host_paths(manifest)
    if manifest.get("kind") != "imserver-production-ready-assertion-archive":
        fail("archive_manifest_kind_mismatch", f"actual={manifest.get('kind') or '-'}")
    schema_version = require_json_int(manifest, "schemaVersion", "archive_manifest_schema_version")
    if schema_version != 1:
        fail("archive_manifest_schema_version", f"actual={schema_version}")
    if manifest.get("status") != "packaged":
        fail("archive_manifest_status_mismatch", f"actual={manifest.get('status') or '-'}")
    require_manifest_file_name(manifest, "sourceReceiptFileName")
    require_manifest_file_name(manifest, "archiveName")
    manifest_epoch = require_manifest_generated_at(manifest, max_future_skew_seconds)
    assertion = manifest.get("assertion")
    if not isinstance(assertion, dict) or assertion.get("path") != "production-ready-assertion.json":
        fail("archive_manifest_assertion_record_invalid")
    assertion_path = root / "production-ready-assertion.json"
    actual_bytes, actual_sha = sha256_file(assertion_path)
    if require_json_int(assertion, "bytes", "archive_manifest_assertion_bytes_invalid") != actual_bytes:
        fail("archive_manifest_assertion_bytes_mismatch")
    if str(assertion.get("sha256") or "") != actual_sha:
        fail("archive_manifest_assertion_sha256_mismatch")
    readme = manifest.get("readme")
    if not isinstance(readme, dict) or readme.get("path") != "README.md":
        fail("archive_manifest_readme_record_invalid")
    readme_path = root / "README.md"
    readme_bytes, readme_sha = sha256_file(readme_path)
    if require_json_int(readme, "bytes", "archive_manifest_readme_bytes_invalid") != readme_bytes:
        fail("archive_manifest_readme_bytes_mismatch")
    if str(readme.get("sha256") or "") != readme_sha:
        fail("archive_manifest_readme_sha256_mismatch")
    assertion_payload = load_json(assertion_path)
    require_manifest_not_before_assertion(manifest_epoch, assertion_payload)
    assertion_target = assertion_payload.get("target") or {}
    manifest_target = manifest.get("target") or {}
    if not isinstance(assertion_target, dict) or not isinstance(manifest_target, dict):
        fail("archive_manifest_target_invalid")
    for field in ("baseURL", "tcpHost", "tcpPort"):
        expected = str(assertion_target.get(field) or "")
        actual = str(manifest_target.get(field) or "")
        if actual != expected:
            fail("archive_manifest_target_mismatch", f"field={field} expected={expected or '-'} actual={actual or '-'}")
    assertion_claim = assertion_payload.get("productionClaim")
    manifest_claim = manifest.get("productionClaim")
    if not isinstance(assertion_claim, dict) or not isinstance(manifest_claim, dict):
        fail("archive_manifest_production_claim_missing")
    if manifest_claim != assertion_claim:
        fail("archive_manifest_production_claim_mismatch")
    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, dict):
        fail("archive_manifest_artifacts_missing")
    assertion_artifacts = assertion_payload.get("artifacts")
    if not isinstance(assertion_artifacts, dict):
        fail("archive_assertion_artifacts_missing")
    expected_artifact_keys = set(REQUIRED_ARTIFACTS)
    manifest_artifact_keys = {str(item) for item in artifacts}
    assertion_artifact_keys = {str(item) for item in assertion_artifacts}
    if manifest_artifact_keys != expected_artifact_keys:
        missing = sorted(expected_artifact_keys - manifest_artifact_keys)
        extra = sorted(manifest_artifact_keys - expected_artifact_keys)
        fail("archive_manifest_artifacts_key_mismatch", f"missing={missing[0] if missing else '-'} extra={extra[0] if extra else '-'}")
    if assertion_artifact_keys != expected_artifact_keys:
        missing = sorted(expected_artifact_keys - assertion_artifact_keys)
        extra = sorted(assertion_artifact_keys - expected_artifact_keys)
        fail("archive_assertion_artifacts_key_mismatch", f"missing={missing[0] if missing else '-'} extra={extra[0] if extra else '-'}")
    declared_files: set[str] = {"production-ready-assertion.json", "README.md"}
    for key in REQUIRED_ARTIFACTS:
        record = artifacts.get(key)
        if not isinstance(record, dict):
            fail("archive_manifest_artifact_missing", f"field={key}")
        assertion_record = assertion_artifacts.get(key)
        if not isinstance(assertion_record, dict):
            fail("archive_assertion_artifact_missing", f"field={key}")
        if record != assertion_record:
            fail("archive_manifest_assertion_artifact_mismatch", f"field={key}")
        rel = str(record.get("path") or "")
        if not rel.startswith(f"artifacts/{key}/"):
            fail("archive_manifest_artifact_path_invalid", f"field={key} path={rel or '-'}")
        path = root / rel
        if not path.is_file():
            fail("archive_manifest_artifact_file_missing", f"field={key} path={rel}")
        actual_bytes, actual_sha = sha256_file(path)
        if require_json_int(record, "bytes", "archive_manifest_artifact_bytes_invalid", f"field={key}") != actual_bytes:
            fail("archive_manifest_artifact_bytes_mismatch", f"field={key}")
        if str(record.get("sha256") or "") != actual_sha:
            fail("archive_manifest_artifact_sha256_mismatch", f"field={key}")
        declared_files.add(rel)
        if key == "productionStaticGateReceipt":
            support_artifacts = record.get("supportArtifacts")
            if not isinstance(support_artifacts, dict):
                fail("archive_manifest_static_gate_support_missing")
            for field, _ in STATIC_GATE_SUPPORT_ARTIFACTS:
                support_record = support_artifacts.get(field)
                if not isinstance(support_record, dict):
                    fail("archive_manifest_static_gate_support_record_missing", f"field={field}")
                support_rel = str(support_record.get("path") or "")
                expected_prefix = f"artifacts/{key}/support/{field}/"
                if not support_rel.startswith(expected_prefix):
                    fail("archive_manifest_static_gate_support_path_invalid", f"field={field} path={support_rel or '-'}")
                support_path = root / support_rel
                if not support_path.is_file():
                    fail("archive_manifest_static_gate_support_file_missing", f"field={field} path={support_rel}")
                support_bytes, support_sha = sha256_file(support_path)
                if require_json_int(
                    support_record,
                    "bytes",
                    "archive_manifest_static_gate_support_bytes_invalid",
                    f"field={field}",
                ) != support_bytes:
                    fail("archive_manifest_static_gate_support_bytes_mismatch", f"field={field}")
                if str(support_record.get("sha256") or "") != support_sha:
                    fail("archive_manifest_static_gate_support_sha256_mismatch", f"field={field}")
                declared_files.add(support_rel)
            verify_archived_static_gate_support_payloads(root, support_artifacts)
            verify_archived_static_gate_receipt_support_paths(path, support_artifacts)
    manifest["__declaredFiles"] = sorted(declared_files)
    return manifest


def verify_archive_manifest_file_set(manifest: dict[str, Any], member_names: list[str]) -> None:
    declared = set(manifest.get("__declaredFiles") or [])
    actual = set(member_names) - {"SHA256SUMS", "production-ready-archive-manifest.json"}
    missing = sorted(declared - actual)
    extra = sorted(actual - declared)
    if missing:
        fail("archive_manifest_file_missing", f"path={missing[0]}")
    if extra:
        fail("archive_manifest_file_extra", f"path={extra[0]}")


def verify_archive_readme(root: Path, manifest: dict[str, Any]) -> None:
    readme_path = root / "README.md"
    if not readme_path.is_file():
        fail("archive_readme_missing")
    text = readme_path.read_text(encoding="utf-8")
    for phrase in REQUIRED_ARCHIVE_README_PHRASES:
        if phrase not in text:
            fail("archive_readme_phrase_missing", f"phrase={phrase}")
    assertion_payload = load_json(root / "production-ready-assertion.json")
    target = manifest.get("target")
    if not isinstance(target, dict):
        fail("archive_readme_target_missing")
    expected_lines = (
        f"- status: `{assertion_payload.get('status') or '-'}`",
        f"- baseURL: `{target.get('baseURL') or '-'}`",
        f"- tcpHost: `{target.get('tcpHost') or '-'}`",
        f"- tcpPort: `{target.get('tcpPort') or '-'}`",
        f"- archive: `{manifest.get('archiveName') or '-'}`",
    )
    for line in expected_lines:
        if line not in text:
            fail("archive_readme_field_mismatch", f"expected={line}")


def verify_archive(args: argparse.Namespace) -> None:
    archive_path = Path(args.archive_file).expanduser().resolve() if args.archive_file else Path()
    if not archive_path.is_file():
        fail("archive_missing", f"path={archive_path}")
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "archive"
        root.mkdir()
        member_names = safe_extract_archive(archive_path, root)
        for name in REQUIRED_ARCHIVE_FILES:
            if name not in member_names:
                fail("archive_required_member_missing", f"path={name}")
        verify_sha256sums(root, member_names)
        verify_archived_assertion_has_no_host_paths(root)
        manifest = verify_manifest(root, archive_path, args.max_future_skew_seconds)
        verify_archive_readme(root, manifest)
        verify_archive_manifest_file_set(manifest, member_names)
        command = [
            sys.executable,
            str(Path(__file__).with_name("verify_production_ready_assertion.py")),
            "--receipt-json",
            str(root / "production-ready-assertion.json"),
            "--artifact-root",
            str(root / "artifacts"),
            "--require-pass",
            "--require-artifacts-exist",
            "--require-static-gate-support-root",
            "--max-age-seconds",
            str(args.max_age_seconds),
            "--max-future-skew-seconds",
            str(args.max_future_skew_seconds),
        ]
        if args.expect_base_url:
            command.extend(["--expect-base-url", args.expect_base_url])
        if args.expect_tcp_host:
            command.extend(["--expect-tcp-host", args.expect_tcp_host])
        if args.expect_tcp_port:
            command.extend(["--expect-tcp-port", str(args.expect_tcp_port)])
        run_verifier_command(command, "archive_assertion_verify_failed")
    print(f"production_ready_assertion_archive_verify result=pass archive={archive_path}")


def package_assertion(args: argparse.Namespace) -> tuple[Path, Path]:
    receipt_path = Path(args.receipt_json).expanduser().resolve()
    if not receipt_path.is_file():
        fail("receipt_missing", f"path={receipt_path}")
    verify_source_receipt(args)

    receipt = load_json(receipt_path)
    output_dir = Path(args.output_dir).expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    archive_path = Path(args.archive_file).expanduser().resolve() if args.archive_file else output_dir / f"production-ready-assertion-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}.tar.gz"

    stage_dir = output_dir / "latest"
    if stage_dir.exists():
        shutil.rmtree(stage_dir)
    stage_dir.mkdir(parents=True)

    copied_artifacts = copy_artifacts(receipt, stage_dir, args.artifact_root or [])
    (stage_dir / "production-ready-assertion.json").write_text(
        json.dumps(archived_assertion_payload(receipt, copied_artifacts), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    manifest = {
        "schemaVersion": 1,
        "kind": "imserver-production-ready-assertion-archive",
        "status": "packaged",
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "generatedAtEpoch": int(time.time()),
        "sourceReceiptFileName": receipt_path.name,
        "archiveName": archive_path.name,
        "target": receipt.get("target") or {},
        "productionClaim": receipt.get("productionClaim") or {},
        "assertion": record_file(stage_dir / "production-ready-assertion.json", Path("production-ready-assertion.json")),
        "artifacts": copied_artifacts,
    }
    write_readme(stage_dir, receipt, archive_path.name)
    manifest["readme"] = record_file(stage_dir / "README.md", Path("README.md"))
    (stage_dir / "production-ready-archive-manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    write_sha256sums(stage_dir)
    create_archive(stage_dir, archive_path)
    verify_archive_args = argparse.Namespace(
        archive_file=str(archive_path),
        expect_base_url=args.expect_base_url,
        expect_tcp_host=args.expect_tcp_host,
        expect_tcp_port=args.expect_tcp_port,
        max_age_seconds=args.max_age_seconds,
        max_future_skew_seconds=args.max_future_skew_seconds,
    )
    verify_archive(verify_archive_args)

    verify_command = [
        sys.executable,
        str(Path(__file__).with_name("verify_production_ready_assertion.py")),
        "--receipt-json",
        str(stage_dir / "production-ready-assertion.json"),
        "--artifact-root",
        str(stage_dir / "artifacts"),
        "--require-pass",
        "--require-artifacts-exist",
        "--require-static-gate-support-root",
        "--max-age-seconds",
        str(args.max_age_seconds),
        "--max-future-skew-seconds",
        str(args.max_future_skew_seconds),
    ]
    run_verifier_command(verify_command, "packaged_assertion_verify_failed")
    return stage_dir, archive_path


def run_self_test() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        source = root / "source"
        source.mkdir()
        assertion_verify.init_self_test_git_repo(source)
        artifacts: dict[str, Any] = {}
        package_path = source / "productionEvidencePackage.tar.gz"
        assertion_verify.valid_production_evidence_package(package_path)
        for key in REQUIRED_ARTIFACTS:
            path = source / f"{key}.json"
            if key == "deployReadinessReceipt":
                path.write_text(
                    json.dumps(assertion_verify.valid_deploy_readiness_payload(), indent=2, sort_keys=True) + "\n",
                    encoding="utf-8",
                )
            elif key == "topologySmokeReceipt":
                path.write_text(
                    json.dumps(assertion_verify.valid_topology_smoke_payload(source), indent=2, sort_keys=True) + "\n",
                    encoding="utf-8",
                )
            elif key == "productionStaticGateReceipt":
                path.write_text(
                    json.dumps(assertion_verify.valid_static_gate_payload(source), indent=2, sort_keys=True) + "\n",
                    encoding="utf-8",
                )
            elif key == "currentProductionReadinessJSON":
                path.write_text(
                    json.dumps(assertion_verify.valid_current_readiness_payload(), indent=2, sort_keys=True) + "\n",
                    encoding="utf-8",
                )
            elif key == "productionAcceptanceReceiptJSON":
                path.write_text(
                    json.dumps(assertion_verify.valid_production_acceptance_payload(package_path), indent=2, sort_keys=True) + "\n",
                    encoding="utf-8",
                )
            elif key == "productionEvidencePackage":
                path = package_path
            else:
                path.write_text(f"{key}\n", encoding="utf-8")
            size, digest = sha256_file(path)
            artifacts[key] = {"path": str(path), "fileName": path.name, "bytes": size, "sha256": digest}
        receipt = {
            "schemaVersion": 1,
            "kind": "imserver-production-ready-assertion",
            "status": "pass",
            "generatedAtEpoch": int(time.time()),
            "target": {
                "baseURL": "https://chat.myim-prod.com",
                "tcpHost": "tcp.myim-prod.com",
                "tcpPort": "9000",
            },
            "productionClaim": assertion_verify.final_production_claim(),
            "policy": {key: True for key in assertion_verify.REQUIRED_POLICY_TRUE},
            "artifacts": artifacts,
        }
        receipt_path = root / "production-ready-assertion.json"
        receipt_path.write_text(json.dumps(receipt, indent=2, sort_keys=True), encoding="utf-8")
        output_dir = root / "out"
        archive_file = root / "ready.tar.gz"
        command = [
            sys.executable,
            __file__,
            "--receipt-json",
            str(receipt_path),
            "--output-dir",
            str(output_dir),
            "--archive-file",
            str(archive_file),
            "--expect-base-url",
            "https://chat.myim-prod.com",
            "--expect-tcp-host",
            "tcp.myim-prod.com",
            "--expect-tcp-port",
            "9000",
        ]
        subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
        bad_source_receipt = json.loads(json.dumps(receipt))
        bad_source_receipt["target"]["baseURL"] = "https://wrong.myim-prod.com"
        bad_source_receipt_path = root / "bad-source-receipt.json"
        bad_source_receipt_path.write_text(json.dumps(bad_source_receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        completed = subprocess.run(
            [
                sys.executable,
                __file__,
                "--receipt-json",
                str(bad_source_receipt_path),
                "--output-dir",
                str(root / "bad-source-out"),
                "--archive-file",
                str(root / "bad-source.tar.gz"),
                "--expect-base-url",
                "https://chat.myim-prod.com",
                "--expect-tcp-host",
                "tcp.myim-prod.com",
                "--expect-tcp-port",
                "9000",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_source_receipt_package_passed")
        combined_output = f"{completed.stdout}\n{completed.stderr}"
        if "source_receipt_verify_failed" not in combined_output or "target_mismatch" not in combined_output:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_source_receipt_verifier_output_missing")
        redacted = verifier_output(
            subprocess.CompletedProcess(
                args=["self-test"],
                returncode=2,
                stdout="target_mismatch JWT_SECRET=topsecret IM_INTERNAL_SHARED_SECRET:abc123 DATABASE_PASSWORD = spaced-secret",
                stderr='Authorization BearerToken Authorization: Bearer live-bearer-token DATABASE_PASSWORD=p@ssw0rd API_KEY:live-key {"apiKey":"json-key","refresh_token":"json-token"}',
            )
        )
        if "target_mismatch" not in redacted:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=redacted_output_lost_reason")
        for leaked in ("topsecret", "abc123", "p@ssw0rd", "live-key", "BearerToken", "live-bearer-token", "spaced-secret", "json-key", "json-token"):
            if leaked in redacted:
                raise SystemExit("production_ready_assertion_package_self_test result=fail reason=verifier_output_secret_leaked")
        if redacted.count("<redacted>") < 8:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=verifier_output_redaction_missing")
        stage = output_dir / "latest"
        if not archive_file.is_file():
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=archive_missing")
        if not (stage / "SHA256SUMS").is_file():
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=sha256sums_missing")

        def assert_archive_rejected(
            *,
            archive_stem: str,
            expected_reason: str,
            pass_reason: str,
            reason_missing: str,
            mutate,
        ) -> None:
            bad_dir = root / archive_stem
            shutil.copytree(stage, bad_dir)
            mutate(bad_dir)
            write_sha256sums(bad_dir)
            bad_archive = root / f"{archive_stem}.tar.gz"
            create_archive(bad_dir, bad_archive)
            completed = subprocess.run(
                [sys.executable, __file__, "--verify-archive", "--archive-file", str(bad_archive)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            if completed.returncode == 0:
                raise SystemExit(f"production_ready_assertion_package_self_test result=fail reason={pass_reason}")
            if expected_reason not in completed.stderr and expected_reason not in completed.stdout:
                raise SystemExit(f"production_ready_assertion_package_self_test result=fail reason={reason_missing}")

        def assert_manifest_has_no_forbidden_keys(value: Any) -> None:
            if isinstance(value, dict):
                for field, child in value.items():
                    if field in FORBIDDEN_MANIFEST_HOST_PATH_FIELDS:
                        raise SystemExit(
                            "production_ready_assertion_package_self_test result=fail "
                            f"reason=manifest_host_path_leak field={field}"
                        )
                    assert_manifest_has_no_forbidden_keys(child)
            elif isinstance(value, list):
                for child in value:
                    assert_manifest_has_no_forbidden_keys(child)

        manifest_payload = load_json(stage / "production-ready-archive-manifest.json")
        assert_manifest_has_no_forbidden_keys(manifest_payload)
        archived_assertion = load_json(stage / "production-ready-assertion.json")
        if manifest_payload.get("productionClaim") != archived_assertion.get("productionClaim"):
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=manifest_claim_mismatch")
        if manifest_payload.get("productionClaim") != assertion_verify.final_production_claim():
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=manifest_claim_invalid")
        archived_artifacts = archived_assertion.get("artifacts")
        if not isinstance(archived_artifacts, dict):
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=archived_assertion_artifacts_missing")
        for key in REQUIRED_ARTIFACTS:
            archived_record = archived_artifacts.get(key)
            if not isinstance(archived_record, dict):
                raise SystemExit(f"production_ready_assertion_package_self_test result=fail reason=archived_assertion_artifact_missing field={key}")
            archived_path = str(archived_record.get("path") or "")
            if looks_like_host_path(archived_path) or not archived_path.startswith(f"artifacts/{key}/"):
                raise SystemExit(
                    "production_ready_assertion_package_self_test result=fail "
                    f"reason=archived_assertion_path_not_portable field={key} path={archived_path or '-'}"
                )
        readme_text = (stage / "README.md").read_text(encoding="utf-8")
        for phrase in REQUIRED_ARCHIVE_README_PHRASES:
            if phrase not in readme_text:
                raise SystemExit(
                    "production_ready_assertion_package_self_test result=fail "
                    f"reason=archive_readme_phrase_missing phrase={phrase}"
                )
        for key in REQUIRED_ARTIFACTS:
            file_name = str(artifacts[key]["fileName"])
            if not (stage / "artifacts" / key / file_name).is_file():
                raise SystemExit(f"production_ready_assertion_package_self_test result=fail reason=artifact_missing field={key}")
        for field, _ in STATIC_GATE_SUPPORT_ARTIFACTS:
            support_dir = stage / "artifacts" / "productionStaticGateReceipt" / "support" / field
            if not support_dir.is_dir() or not any(path.is_file() for path in support_dir.iterdir()):
                raise SystemExit(
                    "production_ready_assertion_package_self_test result=fail "
                    f"reason=static_gate_support_missing field={field}"
                )
        static_gate_record = archived_artifacts.get("productionStaticGateReceipt")
        if not isinstance(static_gate_record, dict):
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=static_gate_record_missing")
        static_gate_support = static_gate_record.get("supportArtifacts")
        if not isinstance(static_gate_support, dict):
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=static_gate_support_record_missing")
        static_gate_payload = load_json(stage / str(static_gate_record.get("path") or ""))
        expected_static_gate_paths = {
            ("completionStatus", "path"): str(static_gate_support["completionStatus"]["path"]),
            ("completionStatus", "markdownPath"): str(static_gate_support["completionStatusMarkdown"]["path"]),
            ("recoveryPlan", "path"): str(static_gate_support["recoveryPlan"]["path"]),
            ("recoveryPlan", "markdownPath"): str(static_gate_support["recoveryPlanMarkdown"]["path"]),
            ("recoveryPlan", "scriptPath"): str(static_gate_support["recoveryPlanScript"]["path"]),
        }
        for (section, field), expected in expected_static_gate_paths.items():
            actual = str((static_gate_payload.get(section) or {}).get(field) or "")
            if actual != expected or looks_like_host_path(actual):
                raise SystemExit(
                    "production_ready_assertion_package_self_test result=fail "
                    f"reason=static_gate_path_not_portable field={section}.{field} expected={expected} actual={actual or '-'}"
                )
        support_completion_payload = load_json(stage / str(static_gate_support["completionStatus"]["path"]))
        support_completion_markdown = (stage / str(static_gate_support["completionStatusMarkdown"]["path"])).read_text(encoding="utf-8")
        support_recovery_payload = load_json(stage / str(static_gate_support["recoveryPlan"]["path"]))
        if str(support_completion_payload.get("repoRoot") or "") != ARCHIVE_STATIC_GATE_REPO_ROOT:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=support_completion_repo_root_not_portable")
        support_completion_json = json.dumps(support_completion_payload, sort_keys=True)
        if str(source) in support_completion_json or ARCHIVE_STATIC_GATE_REPO_ROOT not in support_completion_json:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=support_completion_json_not_portable")
        if str(source) in support_completion_markdown or ARCHIVE_STATIC_GATE_REPO_ROOT not in support_completion_markdown:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=support_completion_markdown_not_portable")
        if str(support_recovery_payload.get("sourceStatusJson") or "") != str(static_gate_support["completionStatus"]["path"]):
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=support_recovery_source_status_not_portable")
        shutil.rmtree(source)
        subprocess.run(
            [
                sys.executable,
                str(Path(__file__).with_name("verify_production_ready_assertion.py")),
                "--receipt-json",
                str(stage / "production-ready-assertion.json"),
                "--artifact-root",
                str(stage / "artifacts"),
                "--require-pass",
                "--require-artifacts-exist",
                "--require-static-gate-support-root",
            ],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        extract = root / "extract"
        extract.mkdir()
        safe_extract_archive(archive_file, extract)
        subprocess.run(
            [
                sys.executable,
                str(Path(__file__).with_name("verify_production_ready_assertion.py")),
                "--receipt-json",
                str(extract / "production-ready-assertion.json"),
                "--artifact-root",
                str(extract / "artifacts"),
                "--require-pass",
                "--require-artifacts-exist",
                "--require-static-gate-support-root",
            ],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        subprocess.run(
            [
                sys.executable,
                __file__,
                "--verify-archive",
                "--archive-file",
                str(archive_file),
                "--expect-base-url",
                "https://chat.myim-prod.com",
                "--expect-tcp-host",
                "tcp.myim-prod.com",
                "--expect-tcp-port",
                "9000",
            ],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        bad_target_dir = root / "bad-target-manifest"
        shutil.copytree(stage, bad_target_dir)
        bad_target_manifest = bad_target_dir / "production-ready-archive-manifest.json"
        bad_target_payload = load_json(bad_target_manifest)
        bad_target_payload.setdefault("target", {})["tcpHost"] = "other.myim-prod.com"
        bad_target_manifest.write_text(json.dumps(bad_target_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        write_sha256sums(bad_target_dir)
        bad_target_archive = root / "bad-target-manifest.tar.gz"
        create_archive(bad_target_dir, bad_target_archive)
        completed = subprocess.run(
            [sys.executable, __file__, "--verify-archive", "--archive-file", str(bad_target_archive)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_target_manifest_archive_passed")
        if "archive_manifest_target_mismatch" not in completed.stderr and "archive_manifest_target_mismatch" not in completed.stdout:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_target_manifest_archive_reason_missing")

        bad_claim_manifest_dir = root / "bad-claim-manifest"
        shutil.copytree(stage, bad_claim_manifest_dir)
        bad_claim_manifest = bad_claim_manifest_dir / "production-ready-archive-manifest.json"
        bad_claim_payload = load_json(bad_claim_manifest)
        bad_claim_payload.setdefault("productionClaim", {})["claimAllowed"] = False
        bad_claim_manifest.write_text(json.dumps(bad_claim_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        write_sha256sums(bad_claim_manifest_dir)
        bad_claim_archive = root / "bad-claim-manifest.tar.gz"
        create_archive(bad_claim_manifest_dir, bad_claim_archive)
        completed = subprocess.run(
            [sys.executable, __file__, "--verify-archive", "--archive-file", str(bad_claim_archive)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_claim_manifest_archive_passed")
        if "archive_manifest_production_claim_mismatch" not in completed.stderr and "archive_manifest_production_claim_mismatch" not in completed.stdout:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_claim_manifest_archive_reason_missing")

        bad_manifest_artifact_dir = root / "bad-manifest-artifact"
        shutil.copytree(stage, bad_manifest_artifact_dir)
        bad_manifest_artifact_manifest = bad_manifest_artifact_dir / "production-ready-archive-manifest.json"
        bad_manifest_artifact_payload = load_json(bad_manifest_artifact_manifest)
        bad_manifest_artifact_payload["artifacts"]["productionEvidencePackage"]["sha256"] = "0" * 64
        bad_manifest_artifact_manifest.write_text(json.dumps(bad_manifest_artifact_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        write_sha256sums(bad_manifest_artifact_dir)
        bad_manifest_artifact_archive = root / "bad-manifest-artifact.tar.gz"
        create_archive(bad_manifest_artifact_dir, bad_manifest_artifact_archive)
        completed = subprocess.run(
            [sys.executable, __file__, "--verify-archive", "--archive-file", str(bad_manifest_artifact_archive)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_manifest_artifact_archive_passed")
        if "archive_manifest_assertion_artifact_mismatch" not in completed.stderr and "archive_manifest_assertion_artifact_mismatch" not in completed.stdout:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_manifest_artifact_archive_reason_missing")

        bad_extra_artifact_key_dir = root / "bad-extra-artifact-key"
        shutil.copytree(stage, bad_extra_artifact_key_dir)
        bad_extra_artifact_file = bad_extra_artifact_key_dir / "unused-extra-artifact.json"
        bad_extra_artifact_file.write_text("{}\n", encoding="utf-8")
        extra_artifact_record = record_file(bad_extra_artifact_file, bad_extra_artifact_file.relative_to(bad_extra_artifact_key_dir))
        bad_extra_artifact_assertion = bad_extra_artifact_key_dir / "production-ready-assertion.json"
        bad_extra_artifact_assertion_payload = load_json(bad_extra_artifact_assertion)
        bad_extra_artifact_assertion_payload["artifacts"]["unusedExtraArtifact"] = extra_artifact_record
        bad_extra_artifact_assertion.write_text(
            json.dumps(bad_extra_artifact_assertion_payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        bad_extra_artifact_manifest = bad_extra_artifact_key_dir / "production-ready-archive-manifest.json"
        bad_extra_artifact_manifest_payload = load_json(bad_extra_artifact_manifest)
        bad_extra_artifact_manifest_payload["assertion"] = record_file(bad_extra_artifact_assertion, Path("production-ready-assertion.json"))
        bad_extra_artifact_manifest_payload["artifacts"]["unusedExtraArtifact"] = extra_artifact_record
        bad_extra_artifact_manifest.write_text(json.dumps(bad_extra_artifact_manifest_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        write_sha256sums(bad_extra_artifact_key_dir)
        bad_extra_artifact_key_archive = root / "bad-extra-artifact-key.tar.gz"
        create_archive(bad_extra_artifact_key_dir, bad_extra_artifact_key_archive)
        completed = subprocess.run(
            [sys.executable, __file__, "--verify-archive", "--archive-file", str(bad_extra_artifact_key_archive)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_extra_artifact_key_archive_passed")
        if "archive_manifest_artifacts_key_mismatch" not in completed.stderr and "archive_manifest_artifacts_key_mismatch" not in completed.stdout:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_extra_artifact_key_archive_reason_missing")

        bad_static_claim_dir = root / "bad-static-claim"
        shutil.copytree(stage, bad_static_claim_dir)
        bad_static_claim_manifest = bad_static_claim_dir / "production-ready-archive-manifest.json"
        bad_static_claim_manifest_payload = load_json(bad_static_claim_manifest)
        bad_static_claim_support_record = bad_static_claim_manifest_payload["artifacts"]["productionStaticGateReceipt"]["supportArtifacts"]["completionStatus"]
        bad_static_claim_completion = bad_static_claim_dir / str(bad_static_claim_support_record["path"])
        bad_static_claim_completion_payload = load_json(bad_static_claim_completion)
        bad_static_claim_completion_payload["productionClaim"]["claimAllowed"] = True
        bad_static_claim_completion_payload["productionClaim"]["productionReady"] = True
        bad_static_claim_completion_payload["productionClaim"]["claimLevel"] = "production-ready"
        bad_static_claim_completion_payload["productionClaim"]["basis"] = "verified-live-production-evidence"
        bad_static_claim_completion.write_text(
            json.dumps(bad_static_claim_completion_payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        bad_static_claim_manifest_payload["artifacts"]["productionStaticGateReceipt"]["supportArtifacts"]["completionStatus"] = record_file(
            bad_static_claim_completion,
            bad_static_claim_completion.relative_to(bad_static_claim_dir),
        )
        bad_static_claim_manifest.write_text(json.dumps(bad_static_claim_manifest_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        write_sha256sums(bad_static_claim_dir)
        bad_static_claim_archive = root / "bad-static-claim.tar.gz"
        create_archive(bad_static_claim_dir, bad_static_claim_archive)
        completed = subprocess.run(
            [sys.executable, __file__, "--verify-archive", "--archive-file", str(bad_static_claim_archive)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_static_claim_archive_passed")
        if "archive_manifest_assertion_artifact_mismatch" not in completed.stderr and "archive_manifest_assertion_artifact_mismatch" not in completed.stdout:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_static_claim_archive_reason_missing")

        bad_static_tiers_dir = root / "bad-static-readiness-tiers"
        shutil.copytree(stage, bad_static_tiers_dir)
        bad_static_tiers_manifest = bad_static_tiers_dir / "production-ready-archive-manifest.json"
        bad_static_tiers_manifest_payload = load_json(bad_static_tiers_manifest)
        bad_static_tiers_support_record = bad_static_tiers_manifest_payload["artifacts"]["productionStaticGateReceipt"]["supportArtifacts"]["completionStatus"]
        bad_static_tiers_completion = bad_static_tiers_dir / str(bad_static_tiers_support_record["path"])
        bad_static_tiers_completion_payload = load_json(bad_static_tiers_completion)
        bad_static_tiers_completion_payload["readinessTiers"]["productionReady"]["status"] = "ready"
        bad_static_tiers_completion_payload["readinessTiers"]["productionReady"]["claimAllowed"] = True
        bad_static_tiers_completion_payload["readinessTiers"]["productionReady"]["claim"] = "production-ready"
        bad_static_tiers_completion.write_text(
            json.dumps(bad_static_tiers_completion_payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        bad_static_tiers_manifest_payload["artifacts"]["productionStaticGateReceipt"]["supportArtifacts"]["completionStatus"] = record_file(
            bad_static_tiers_completion,
            bad_static_tiers_completion.relative_to(bad_static_tiers_dir),
        )
        bad_static_tiers_manifest.write_text(json.dumps(bad_static_tiers_manifest_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        write_sha256sums(bad_static_tiers_dir)
        bad_static_tiers_archive = root / "bad-static-readiness-tiers.tar.gz"
        create_archive(bad_static_tiers_dir, bad_static_tiers_archive)
        completed = subprocess.run(
            [sys.executable, __file__, "--verify-archive", "--archive-file", str(bad_static_tiers_archive)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_static_readiness_tiers_archive_passed")
        if "archive_manifest_assertion_artifact_mismatch" not in completed.stderr and "archive_manifest_assertion_artifact_mismatch" not in completed.stdout:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_static_readiness_tiers_archive_reason_missing")

        def archive_with_tampered_static_recovery_plan(name: str, mutate: Any) -> subprocess.CompletedProcess[str]:
            tampered_dir = root / name
            shutil.copytree(stage, tampered_dir)
            assertion_path = tampered_dir / "production-ready-assertion.json"
            assertion_payload = load_json(assertion_path)
            static_gate_record = assertion_payload["artifacts"]["productionStaticGateReceipt"]
            static_gate_support = static_gate_record["supportArtifacts"]
            recovery_record = static_gate_support["recoveryPlan"]
            recovery_path = tampered_dir / str(recovery_record["path"])
            recovery_payload = load_json(recovery_path)
            mutate(recovery_payload)
            recovery_path.write_text(json.dumps(recovery_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            static_gate_support["recoveryPlan"] = record_file(recovery_path, recovery_path.relative_to(tampered_dir))
            static_gate_path = tampered_dir / str(static_gate_record["path"])
            static_gate_payload = load_json(static_gate_path)
            static_gate_payload["recoveryPlan"]["path"] = static_gate_support["recoveryPlan"]["path"]
            static_gate_payload["recoveryPlan"]["sha256"] = static_gate_support["recoveryPlan"]["sha256"]
            static_gate_path.write_text(json.dumps(static_gate_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            updated_static_gate_record = record_file(static_gate_path, static_gate_path.relative_to(tampered_dir))
            updated_static_gate_record["supportArtifacts"] = static_gate_support
            assertion_payload["artifacts"]["productionStaticGateReceipt"] = updated_static_gate_record
            assertion_path.write_text(json.dumps(assertion_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            manifest_path = tampered_dir / "production-ready-archive-manifest.json"
            manifest_payload = load_json(manifest_path)
            manifest_payload["assertion"] = record_file(assertion_path, Path("production-ready-assertion.json"))
            manifest_payload["artifacts"]["productionStaticGateReceipt"] = updated_static_gate_record
            manifest_path.write_text(json.dumps(manifest_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            write_sha256sums(tampered_dir)
            archive_path = root / f"{name}.tar.gz"
            create_archive(tampered_dir, archive_path)
            return subprocess.run(
                [sys.executable, __file__, "--verify-archive", "--archive-file", str(archive_path)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

        completed = archive_with_tampered_static_recovery_plan(
            "bad-static-recovery-target",
            lambda payload: payload["productionTarget"].__setitem__("tcpHost", "other.myim-prod.com"),
        )
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_static_recovery_target_archive_passed")
        if "archive_static_gate_recovery_target_mismatch" not in completed.stderr and "archive_static_gate_recovery_target_mismatch" not in completed.stdout:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_static_recovery_target_archive_reason_missing")

        completed = archive_with_tampered_static_recovery_plan(
            "bad-static-recovery-target-type",
            lambda payload: payload["productionTarget"].__setitem__("tcpPort", 9000),
        )
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_static_recovery_target_type_archive_passed")
        if "archive_static_gate_target_mismatch" not in completed.stderr and "archive_static_gate_target_mismatch" not in completed.stdout:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_static_recovery_target_type_archive_reason_missing")

        completed = archive_with_tampered_static_recovery_plan(
            "bad-static-recovery-claim",
            lambda payload: payload["productionClaim"].__setitem__("finalAssertionArchiveClaimVerified", True),
        )
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_static_recovery_claim_archive_passed")
        if "archive_static_gate_recovery_claim_mismatch" not in completed.stderr and "archive_static_gate_recovery_claim_mismatch" not in completed.stdout:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_static_recovery_claim_archive_reason_missing")

        completed = archive_with_tampered_static_recovery_plan(
            "bad-static-recovery-claim-type",
            lambda payload: payload["productionClaim"].__setitem__("finalAssertionArchiveClaimVerified", "false"),
        )
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_static_recovery_claim_type_archive_passed")
        if "archive_static_gate_claim_mismatch" not in completed.stderr and "archive_static_gate_claim_mismatch" not in completed.stdout:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_static_recovery_claim_type_archive_reason_missing")

        completed = archive_with_tampered_static_recovery_plan(
            "bad-static-recovery-readiness-tiers-extra-field",
            lambda payload: payload["readinessTiers"]["localEngineering"].__setitem__("note", "do not trust me"),
        )
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_static_recovery_readiness_tiers_extra_field_archive_passed")
        if "archive_static_gate_readiness_tiers_mismatch" not in completed.stderr and "archive_static_gate_readiness_tiers_mismatch" not in completed.stdout:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_static_recovery_readiness_tiers_extra_field_archive_reason_missing")

        completed = archive_with_tampered_static_recovery_plan(
            "bad-static-recovery-readiness-tiers-type",
            lambda payload: payload["readinessTiers"]["productionReady"].__setitem__("claimAllowed", "false"),
        )
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_static_recovery_readiness_tiers_type_archive_passed")
        if "archive_static_gate_readiness_tiers_mismatch" not in completed.stderr and "archive_static_gate_readiness_tiers_mismatch" not in completed.stdout:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_static_recovery_readiness_tiers_type_archive_reason_missing")

        bad_static_recovery_tiers_dir = root / "bad-static-recovery-readiness-tiers"
        shutil.copytree(stage, bad_static_recovery_tiers_dir)
        bad_static_recovery_tiers_assertion = bad_static_recovery_tiers_dir / "production-ready-assertion.json"
        bad_static_recovery_tiers_assertion_payload = load_json(bad_static_recovery_tiers_assertion)
        bad_static_recovery_tiers_record = bad_static_recovery_tiers_assertion_payload["artifacts"]["productionStaticGateReceipt"]
        bad_static_recovery_tiers_support = bad_static_recovery_tiers_record["supportArtifacts"]
        bad_static_recovery_tiers_recovery_record = bad_static_recovery_tiers_support["recoveryPlan"]
        bad_static_recovery_tiers_recovery = bad_static_recovery_tiers_dir / str(bad_static_recovery_tiers_recovery_record["path"])
        bad_static_recovery_tiers_recovery_payload = load_json(bad_static_recovery_tiers_recovery)
        bad_static_recovery_tiers_recovery_payload["readinessTiers"]["productionReady"]["status"] = "ready"
        bad_static_recovery_tiers_recovery_payload["readinessTiers"]["productionReady"]["claimAllowed"] = True
        bad_static_recovery_tiers_recovery_payload["readinessTiers"]["productionReady"]["claim"] = "production-ready"
        bad_static_recovery_tiers_recovery.write_text(
            json.dumps(bad_static_recovery_tiers_recovery_payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        bad_static_recovery_tiers_support["recoveryPlan"] = record_file(
            bad_static_recovery_tiers_recovery,
            bad_static_recovery_tiers_recovery.relative_to(bad_static_recovery_tiers_dir),
        )
        bad_static_recovery_tiers_static_gate = bad_static_recovery_tiers_dir / str(bad_static_recovery_tiers_record["path"])
        bad_static_recovery_tiers_static_gate_payload = load_json(bad_static_recovery_tiers_static_gate)
        bad_static_recovery_tiers_static_gate_payload["recoveryPlan"]["sha256"] = bad_static_recovery_tiers_support["recoveryPlan"]["sha256"]
        bad_static_recovery_tiers_static_gate_payload["recoveryPlan"]["path"] = bad_static_recovery_tiers_support["recoveryPlan"]["path"]
        bad_static_recovery_tiers_static_gate.write_text(
            json.dumps(bad_static_recovery_tiers_static_gate_payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        updated_bad_static_recovery_tiers_record = record_file(
            bad_static_recovery_tiers_static_gate,
            bad_static_recovery_tiers_static_gate.relative_to(bad_static_recovery_tiers_dir),
        )
        updated_bad_static_recovery_tiers_record["supportArtifacts"] = bad_static_recovery_tiers_support
        bad_static_recovery_tiers_assertion_payload["artifacts"]["productionStaticGateReceipt"] = updated_bad_static_recovery_tiers_record
        bad_static_recovery_tiers_assertion.write_text(
            json.dumps(bad_static_recovery_tiers_assertion_payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        bad_static_recovery_tiers_manifest = bad_static_recovery_tiers_dir / "production-ready-archive-manifest.json"
        bad_static_recovery_tiers_manifest_payload = load_json(bad_static_recovery_tiers_manifest)
        bad_static_recovery_tiers_manifest_payload["assertion"] = record_file(
            bad_static_recovery_tiers_assertion,
            Path("production-ready-assertion.json"),
        )
        bad_static_recovery_tiers_manifest_payload["artifacts"]["productionStaticGateReceipt"] = updated_bad_static_recovery_tiers_record
        bad_static_recovery_tiers_manifest.write_text(
            json.dumps(bad_static_recovery_tiers_manifest_payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        write_sha256sums(bad_static_recovery_tiers_dir)
        bad_static_recovery_tiers_archive = root / "bad-static-recovery-readiness-tiers.tar.gz"
        create_archive(bad_static_recovery_tiers_dir, bad_static_recovery_tiers_archive)
        completed = subprocess.run(
            [sys.executable, __file__, "--verify-archive", "--archive-file", str(bad_static_recovery_tiers_archive)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_static_recovery_readiness_tiers_archive_passed")
        if "archive_static_gate_recovery_readiness_tiers_mismatch" not in completed.stderr and "archive_static_gate_recovery_readiness_tiers_mismatch" not in completed.stdout:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_static_recovery_readiness_tiers_archive_reason_missing")

        bad_checksum_dir = root / "bad-checksum"
        shutil.copytree(stage, bad_checksum_dir)
        (bad_checksum_dir / "README.md").write_text("tampered\n", encoding="utf-8")
        bad_checksum_archive = root / "bad-checksum.tar.gz"
        create_archive(bad_checksum_dir, bad_checksum_archive)
        completed = subprocess.run(
            [sys.executable, __file__, "--verify-archive", "--archive-file", str(bad_checksum_archive)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_checksum_archive_passed")
        if "archive_sha256sums_mismatch" not in completed.stderr and "archive_sha256sums_mismatch" not in completed.stdout:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_checksum_archive_reason_missing")

        bad_readme_dir = root / "bad-readme"
        shutil.copytree(stage, bad_readme_dir)
        bad_readme_path = bad_readme_dir / "README.md"
        bad_readme_path.write_text("# Weak archive instructions\n", encoding="utf-8")
        bad_readme_manifest = bad_readme_dir / "production-ready-archive-manifest.json"
        bad_readme_payload = load_json(bad_readme_manifest)
        bad_readme_payload["readme"] = record_file(bad_readme_path, Path("README.md"))
        bad_readme_manifest.write_text(json.dumps(bad_readme_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        write_sha256sums(bad_readme_dir)
        bad_readme_archive = root / "bad-readme.tar.gz"
        create_archive(bad_readme_dir, bad_readme_archive)
        completed = subprocess.run(
            [sys.executable, __file__, "--verify-archive", "--archive-file", str(bad_readme_archive)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_readme_archive_passed")
        if "archive_readme_phrase_missing" not in completed.stderr and "archive_readme_phrase_missing" not in completed.stdout:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_readme_archive_reason_missing")

        bad_readme_target_dir = root / "bad-readme-target"
        shutil.copytree(stage, bad_readme_target_dir)
        bad_readme_target_path = bad_readme_target_dir / "README.md"
        bad_readme_target_text = bad_readme_target_path.read_text(encoding="utf-8")
        bad_readme_target_text = bad_readme_target_text.replace(
            "- baseURL: `https://chat.myim-prod.com`",
            "- baseURL: `https://wrong.myim-prod.com`",
        )
        bad_readme_target_path.write_text(bad_readme_target_text, encoding="utf-8")
        bad_readme_target_manifest = bad_readme_target_dir / "production-ready-archive-manifest.json"
        bad_readme_target_manifest_payload = load_json(bad_readme_target_manifest)
        bad_readme_target_manifest_payload["readme"] = record_file(bad_readme_target_path, Path("README.md"))
        bad_readme_target_manifest.write_text(json.dumps(bad_readme_target_manifest_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        write_sha256sums(bad_readme_target_dir)
        bad_readme_target_archive = root / "bad-readme-target.tar.gz"
        create_archive(bad_readme_target_dir, bad_readme_target_archive)
        completed = subprocess.run(
            [sys.executable, __file__, "--verify-archive", "--archive-file", str(bad_readme_target_archive)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_readme_target_archive_passed")
        if "archive_readme_field_mismatch" not in completed.stderr and "archive_readme_field_mismatch" not in completed.stdout:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_readme_target_archive_reason_missing")

        bad_assertion_host_path_dir = root / "bad-assertion-host-path"
        shutil.copytree(stage, bad_assertion_host_path_dir)
        bad_assertion_path = bad_assertion_host_path_dir / "production-ready-assertion.json"
        bad_assertion_payload = load_json(bad_assertion_path)
        bad_assertion_payload["artifacts"]["topologySmokeReceipt"]["path"] = "/Users/build/topology-smoke.json"
        bad_assertion_path.write_text(json.dumps(bad_assertion_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        bad_assertion_manifest = bad_assertion_host_path_dir / "production-ready-archive-manifest.json"
        bad_assertion_manifest_payload = load_json(bad_assertion_manifest)
        bad_assertion_manifest_payload["assertion"] = record_file(bad_assertion_path, Path("production-ready-assertion.json"))
        bad_assertion_manifest.write_text(json.dumps(bad_assertion_manifest_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        write_sha256sums(bad_assertion_host_path_dir)
        bad_assertion_host_path_archive = root / "bad-assertion-host-path.tar.gz"
        create_archive(bad_assertion_host_path_dir, bad_assertion_host_path_archive)
        completed = subprocess.run(
            [sys.executable, __file__, "--verify-archive", "--archive-file", str(bad_assertion_host_path_archive)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_assertion_host_path_archive_passed")
        if "archive_assertion_host_path" not in completed.stderr and "archive_assertion_host_path" not in completed.stdout:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_assertion_host_path_archive_reason_missing")

        bad_static_gate_host_path_dir = root / "bad-static-gate-host-path"
        shutil.copytree(stage, bad_static_gate_host_path_dir)
        bad_static_gate_assertion = bad_static_gate_host_path_dir / "production-ready-assertion.json"
        bad_static_gate_assertion_payload = load_json(bad_static_gate_assertion)
        bad_static_gate_record = bad_static_gate_assertion_payload["artifacts"]["productionStaticGateReceipt"]
        bad_static_gate_path = bad_static_gate_host_path_dir / str(bad_static_gate_record["path"])
        bad_static_gate_payload = load_json(bad_static_gate_path)
        bad_static_gate_payload["completionStatus"]["path"] = "/Users/build/production-completion-status.json"
        bad_static_gate_path.write_text(json.dumps(bad_static_gate_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        updated_static_gate_record = record_file(bad_static_gate_path, bad_static_gate_path.relative_to(bad_static_gate_host_path_dir))
        updated_static_gate_record["supportArtifacts"] = bad_static_gate_record["supportArtifacts"]
        bad_static_gate_assertion_payload["artifacts"]["productionStaticGateReceipt"] = updated_static_gate_record
        bad_static_gate_assertion.write_text(json.dumps(bad_static_gate_assertion_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        bad_static_gate_manifest = bad_static_gate_host_path_dir / "production-ready-archive-manifest.json"
        bad_static_gate_manifest_payload = load_json(bad_static_gate_manifest)
        bad_static_gate_manifest_payload["assertion"] = record_file(bad_static_gate_assertion, Path("production-ready-assertion.json"))
        bad_static_gate_manifest_payload["artifacts"]["productionStaticGateReceipt"] = updated_static_gate_record
        bad_static_gate_manifest.write_text(json.dumps(bad_static_gate_manifest_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        write_sha256sums(bad_static_gate_host_path_dir)
        bad_static_gate_host_path_archive = root / "bad-static-gate-host-path.tar.gz"
        create_archive(bad_static_gate_host_path_dir, bad_static_gate_host_path_archive)
        completed = subprocess.run(
            [sys.executable, __file__, "--verify-archive", "--archive-file", str(bad_static_gate_host_path_archive)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_static_gate_host_path_archive_passed")
        if "archive_static_gate_host_path" not in completed.stderr and "archive_static_gate_host_path" not in completed.stdout:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_static_gate_host_path_archive_reason_missing")

        bad_static_gate_sha_dir = root / "bad-static-gate-sha"
        shutil.copytree(stage, bad_static_gate_sha_dir)
        bad_static_gate_sha_assertion = bad_static_gate_sha_dir / "production-ready-assertion.json"
        bad_static_gate_sha_assertion_payload = load_json(bad_static_gate_sha_assertion)
        bad_static_gate_sha_record = bad_static_gate_sha_assertion_payload["artifacts"]["productionStaticGateReceipt"]
        bad_static_gate_sha_path = bad_static_gate_sha_dir / str(bad_static_gate_sha_record["path"])
        bad_static_gate_sha_payload = load_json(bad_static_gate_sha_path)
        bad_static_gate_sha_payload["recoveryPlan"]["scriptSha256"] = "0" * 64
        bad_static_gate_sha_path.write_text(json.dumps(bad_static_gate_sha_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        updated_bad_static_gate_sha_record = record_file(
            bad_static_gate_sha_path,
            bad_static_gate_sha_path.relative_to(bad_static_gate_sha_dir),
        )
        updated_bad_static_gate_sha_record["supportArtifacts"] = bad_static_gate_sha_record["supportArtifacts"]
        bad_static_gate_sha_assertion_payload["artifacts"]["productionStaticGateReceipt"] = updated_bad_static_gate_sha_record
        bad_static_gate_sha_assertion.write_text(
            json.dumps(bad_static_gate_sha_assertion_payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        bad_static_gate_sha_manifest = bad_static_gate_sha_dir / "production-ready-archive-manifest.json"
        bad_static_gate_sha_manifest_payload = load_json(bad_static_gate_sha_manifest)
        bad_static_gate_sha_manifest_payload["assertion"] = record_file(
            bad_static_gate_sha_assertion,
            Path("production-ready-assertion.json"),
        )
        bad_static_gate_sha_manifest_payload["artifacts"]["productionStaticGateReceipt"] = updated_bad_static_gate_sha_record
        bad_static_gate_sha_manifest.write_text(
            json.dumps(bad_static_gate_sha_manifest_payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        write_sha256sums(bad_static_gate_sha_dir)
        bad_static_gate_sha_archive = root / "bad-static-gate-sha.tar.gz"
        create_archive(bad_static_gate_sha_dir, bad_static_gate_sha_archive)
        completed = subprocess.run(
            [sys.executable, __file__, "--verify-archive", "--archive-file", str(bad_static_gate_sha_archive)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_static_gate_sha_archive_passed")
        if "archive_static_gate_support_sha_mismatch" not in completed.stderr and "archive_static_gate_support_sha_mismatch" not in completed.stdout:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_static_gate_sha_archive_reason_missing")

        bad_static_support_host_path_dir = root / "bad-static-support-host-path"
        shutil.copytree(stage, bad_static_support_host_path_dir)
        bad_static_support_assertion = bad_static_support_host_path_dir / "production-ready-assertion.json"
        bad_static_support_assertion_payload = load_json(bad_static_support_assertion)
        bad_static_support_record = bad_static_support_assertion_payload["artifacts"]["productionStaticGateReceipt"]
        bad_static_support_completion_record = bad_static_support_record["supportArtifacts"]["completionStatus"]
        bad_static_support_completion = bad_static_support_host_path_dir / str(bad_static_support_completion_record["path"])
        bad_static_support_completion_payload = load_json(bad_static_support_completion)
        bad_static_support_completion_payload["repoRoot"] = "/Users/build/IMMonorepo"
        bad_static_support_completion.write_text(
            json.dumps(bad_static_support_completion_payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        bad_static_support_completion_record = record_file(
            bad_static_support_completion,
            bad_static_support_completion.relative_to(bad_static_support_host_path_dir),
        )
        bad_static_support_record["supportArtifacts"]["completionStatus"] = bad_static_support_completion_record
        bad_static_support_path = bad_static_support_host_path_dir / str(bad_static_support_record["path"])
        bad_static_support_payload = load_json(bad_static_support_path)
        bad_static_support_payload["completionStatus"]["sha256"] = bad_static_support_completion_record["sha256"]
        bad_static_support_path.write_text(
            json.dumps(bad_static_support_payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        updated_bad_static_support_record = record_file(
            bad_static_support_path,
            bad_static_support_path.relative_to(bad_static_support_host_path_dir),
        )
        updated_bad_static_support_record["supportArtifacts"] = bad_static_support_record["supportArtifacts"]
        bad_static_support_assertion_payload["artifacts"]["productionStaticGateReceipt"] = updated_bad_static_support_record
        bad_static_support_assertion.write_text(
            json.dumps(bad_static_support_assertion_payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        bad_static_support_manifest = bad_static_support_host_path_dir / "production-ready-archive-manifest.json"
        bad_static_support_manifest_payload = load_json(bad_static_support_manifest)
        bad_static_support_manifest_payload["assertion"] = record_file(
            bad_static_support_assertion,
            Path("production-ready-assertion.json"),
        )
        bad_static_support_manifest_payload["artifacts"]["productionStaticGateReceipt"] = updated_bad_static_support_record
        bad_static_support_manifest.write_text(
            json.dumps(bad_static_support_manifest_payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        write_sha256sums(bad_static_support_host_path_dir)
        bad_static_support_host_path_archive = root / "bad-static-support-host-path.tar.gz"
        create_archive(bad_static_support_host_path_dir, bad_static_support_host_path_archive)
        completed = subprocess.run(
            [sys.executable, __file__, "--verify-archive", "--archive-file", str(bad_static_support_host_path_archive)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_static_support_host_path_archive_passed")
        if "archive_static_gate_support_host_path" not in completed.stderr and "archive_static_gate_support_host_path" not in completed.stdout:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_static_support_host_path_archive_reason_missing")

        bad_static_support_markdown_host_path_dir = root / "bad-static-support-markdown-host-path"
        shutil.copytree(stage, bad_static_support_markdown_host_path_dir)
        bad_static_support_markdown_assertion = bad_static_support_markdown_host_path_dir / "production-ready-assertion.json"
        bad_static_support_markdown_assertion_payload = load_json(bad_static_support_markdown_assertion)
        bad_static_support_markdown_record = bad_static_support_markdown_assertion_payload["artifacts"]["productionStaticGateReceipt"]
        bad_static_support_completion_markdown_record = bad_static_support_markdown_record["supportArtifacts"]["completionStatusMarkdown"]
        bad_static_support_completion_markdown = bad_static_support_markdown_host_path_dir / str(bad_static_support_completion_markdown_record["path"])
        bad_static_support_completion_markdown.write_text(
            "# Static Gate Completion Status\n"
            f"- repoRoot: `{ARCHIVE_STATIC_GATE_REPO_ROOT}`\n"
            "- sourceRepoRoot: `/Users/build/IMMonorepo`\n",
            encoding="utf-8",
        )
        updated_bad_static_support_completion_markdown_record = record_file(
            bad_static_support_completion_markdown,
            bad_static_support_completion_markdown.relative_to(bad_static_support_markdown_host_path_dir),
        )
        bad_static_support_markdown_record["supportArtifacts"]["completionStatusMarkdown"] = updated_bad_static_support_completion_markdown_record
        bad_static_support_markdown_path = bad_static_support_markdown_host_path_dir / str(bad_static_support_markdown_record["path"])
        bad_static_support_markdown_payload = load_json(bad_static_support_markdown_path)
        bad_static_support_markdown_payload["completionStatus"]["markdownSha256"] = updated_bad_static_support_completion_markdown_record["sha256"]
        bad_static_support_markdown_path.write_text(
            json.dumps(bad_static_support_markdown_payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        updated_bad_static_support_markdown_record = record_file(
            bad_static_support_markdown_path,
            bad_static_support_markdown_path.relative_to(bad_static_support_markdown_host_path_dir),
        )
        updated_bad_static_support_markdown_record["supportArtifacts"] = bad_static_support_markdown_record["supportArtifacts"]
        bad_static_support_markdown_assertion_payload["artifacts"]["productionStaticGateReceipt"] = updated_bad_static_support_markdown_record
        bad_static_support_markdown_assertion.write_text(
            json.dumps(bad_static_support_markdown_assertion_payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        bad_static_support_markdown_manifest = bad_static_support_markdown_host_path_dir / "production-ready-archive-manifest.json"
        bad_static_support_markdown_manifest_payload = load_json(bad_static_support_markdown_manifest)
        bad_static_support_markdown_manifest_payload["assertion"] = record_file(
            bad_static_support_markdown_assertion,
            bad_static_support_markdown_assertion.relative_to(bad_static_support_markdown_host_path_dir),
        )
        bad_static_support_markdown_manifest_payload["artifacts"]["productionStaticGateReceipt"] = updated_bad_static_support_markdown_record
        bad_static_support_markdown_manifest.write_text(
            json.dumps(bad_static_support_markdown_manifest_payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        write_sha256sums(bad_static_support_markdown_host_path_dir)
        bad_static_support_markdown_host_path_archive = root / "bad-static-support-markdown-host-path.tar.gz"
        create_archive(bad_static_support_markdown_host_path_dir, bad_static_support_markdown_host_path_archive)
        completed = subprocess.run(
            [sys.executable, __file__, "--verify-archive", "--archive-file", str(bad_static_support_markdown_host_path_archive)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_static_support_markdown_host_path_archive_passed")
        if "archive_static_gate_support_markdown_host_path" not in completed.stderr and "archive_static_gate_support_markdown_host_path" not in completed.stdout:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_static_support_markdown_host_path_archive_reason_missing")

        def assert_bad_static_support_text_host_path_rejected(
            *,
            support_field: str,
            receipt_section: str,
            receipt_sha_field: str,
            content: str,
            archive_stem: str,
            pass_reason: str,
            reason_missing: str,
        ) -> None:
            bad_dir = root / archive_stem
            shutil.copytree(stage, bad_dir)
            assertion_path = bad_dir / "production-ready-assertion.json"
            assertion_payload = load_json(assertion_path)
            static_record = assertion_payload["artifacts"]["productionStaticGateReceipt"]
            support_record = static_record["supportArtifacts"][support_field]
            support_path = bad_dir / str(support_record["path"])
            support_path.write_text(content, encoding="utf-8")
            updated_support_record = record_file(support_path, support_path.relative_to(bad_dir))
            static_record["supportArtifacts"][support_field] = updated_support_record
            static_gate_path = bad_dir / str(static_record["path"])
            static_gate_payload = load_json(static_gate_path)
            static_gate_payload[receipt_section][receipt_sha_field] = updated_support_record["sha256"]
            static_gate_path.write_text(
                json.dumps(static_gate_payload, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            updated_static_record = record_file(static_gate_path, static_gate_path.relative_to(bad_dir))
            updated_static_record["supportArtifacts"] = static_record["supportArtifacts"]
            assertion_payload["artifacts"]["productionStaticGateReceipt"] = updated_static_record
            assertion_path.write_text(
                json.dumps(assertion_payload, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            manifest_path = bad_dir / "production-ready-archive-manifest.json"
            manifest_payload = load_json(manifest_path)
            manifest_payload["assertion"] = record_file(assertion_path, assertion_path.relative_to(bad_dir))
            manifest_payload["artifacts"]["productionStaticGateReceipt"] = updated_static_record
            manifest_path.write_text(
                json.dumps(manifest_payload, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            write_sha256sums(bad_dir)
            bad_archive = root / f"{archive_stem}.tar.gz"
            create_archive(bad_dir, bad_archive)
            completed = subprocess.run(
                [sys.executable, __file__, "--verify-archive", "--archive-file", str(bad_archive)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            if completed.returncode == 0:
                raise SystemExit(f"production_ready_assertion_package_self_test result=fail reason={pass_reason}")
            if "archive_static_gate_support_text_host_path" not in completed.stderr and "archive_static_gate_support_text_host_path" not in completed.stdout:
                raise SystemExit(f"production_ready_assertion_package_self_test result=fail reason={reason_missing}")

        assert_bad_static_support_text_host_path_rejected(
            support_field="recoveryPlanMarkdown",
            receipt_section="recoveryPlan",
            receipt_sha_field="markdownSha256",
            content="# Recovery Plan\n- sourceRepoRoot: `/Users/build/IMMonorepo`\n",
            archive_stem="bad-static-support-recovery-markdown-host-path",
            pass_reason="bad_static_support_recovery_markdown_host_path_archive_passed",
            reason_missing="bad_static_support_recovery_markdown_host_path_archive_reason_missing",
        )
        assert_bad_static_support_text_host_path_rejected(
            support_field="recoveryPlanScript",
            receipt_section="recoveryPlan",
            receipt_sha_field="scriptSha256",
            content="#!/usr/bin/env bash\nset -euo pipefail\ncd /Users/build/IMMonorepo\n",
            archive_stem="bad-static-support-recovery-script-host-path",
            pass_reason="bad_static_support_recovery_script_host_path_archive_passed",
            reason_missing="bad_static_support_recovery_script_host_path_archive_reason_missing",
        )

        bad_host_path_dir = root / "bad-host-path-manifest"
        shutil.copytree(stage, bad_host_path_dir)
        bad_host_path_manifest = bad_host_path_dir / "production-ready-archive-manifest.json"
        bad_host_path_payload = load_json(bad_host_path_manifest)
        bad_host_path_payload["sourceReceipt"] = "/Users/build/production-ready-assertion.json"
        bad_host_path_manifest.write_text(json.dumps(bad_host_path_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        write_sha256sums(bad_host_path_dir)
        bad_host_path_archive = root / "bad-host-path-manifest.tar.gz"
        create_archive(bad_host_path_dir, bad_host_path_archive)
        completed = subprocess.run(
            [sys.executable, __file__, "--verify-archive", "--archive-file", str(bad_host_path_archive)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_host_path_archive_passed")
        if "archive_manifest_host_path_field" not in completed.stderr and "archive_manifest_host_path_field" not in completed.stdout:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_host_path_archive_reason_missing")

        bad_source_receipt_name_dir = root / "bad-source-receipt-file-name"
        shutil.copytree(stage, bad_source_receipt_name_dir)
        bad_source_receipt_name_manifest = bad_source_receipt_name_dir / "production-ready-archive-manifest.json"
        bad_source_receipt_name_payload = load_json(bad_source_receipt_name_manifest)
        bad_source_receipt_name_payload["sourceReceiptFileName"] = "../production-ready-assertion.json"
        bad_source_receipt_name_manifest.write_text(json.dumps(bad_source_receipt_name_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        write_sha256sums(bad_source_receipt_name_dir)
        bad_source_receipt_name_archive = root / "bad-source-receipt-file-name.tar.gz"
        create_archive(bad_source_receipt_name_dir, bad_source_receipt_name_archive)
        completed = subprocess.run(
            [sys.executable, __file__, "--verify-archive", "--archive-file", str(bad_source_receipt_name_archive)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_source_receipt_file_name_archive_passed")
        if "archive_manifest_file_name_invalid" not in completed.stderr and "archive_manifest_file_name_invalid" not in completed.stdout:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_source_receipt_file_name_archive_reason_missing")

        bad_archive_name_dir = root / "bad-archive-name"
        shutil.copytree(stage, bad_archive_name_dir)
        bad_archive_name_manifest = bad_archive_name_dir / "production-ready-archive-manifest.json"
        bad_archive_name_payload = load_json(bad_archive_name_manifest)
        bad_archive_name_payload["archiveName"] = "../production-ready-assertion.tar.gz"
        bad_archive_name_manifest.write_text(json.dumps(bad_archive_name_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        write_sha256sums(bad_archive_name_dir)
        bad_archive_name_archive = root / "bad-archive-name.tar.gz"
        create_archive(bad_archive_name_dir, bad_archive_name_archive)
        completed = subprocess.run(
            [sys.executable, __file__, "--verify-archive", "--archive-file", str(bad_archive_name_archive)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_archive_name_archive_passed")
        if "archive_manifest_file_name_invalid" not in completed.stderr and "archive_manifest_file_name_invalid" not in completed.stdout:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_archive_name_archive_reason_missing")

        def mutate_manifest_schema_string(bad_dir: Path) -> None:
            manifest_path = bad_dir / "production-ready-archive-manifest.json"
            payload = load_json(manifest_path)
            payload["schemaVersion"] = "1"
            manifest_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")

        assert_archive_rejected(
            archive_stem="bad-manifest-schema-string",
            expected_reason="archive_manifest_schema_version",
            pass_reason="bad_manifest_schema_string_archive_passed",
            reason_missing="bad_manifest_schema_string_archive_reason_missing",
            mutate=mutate_manifest_schema_string,
        )

        def mutate_manifest_generated_at_string(bad_dir: Path) -> None:
            manifest_path = bad_dir / "production-ready-archive-manifest.json"
            payload = load_json(manifest_path)
            payload["generatedAtEpoch"] = str(payload["generatedAtEpoch"])
            manifest_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")

        assert_archive_rejected(
            archive_stem="bad-manifest-generated-at-string",
            expected_reason="archive_manifest_generated_at_epoch_invalid",
            pass_reason="bad_manifest_generated_at_string_archive_passed",
            reason_missing="bad_manifest_generated_at_string_archive_reason_missing",
            mutate=mutate_manifest_generated_at_string,
        )

        def mutate_assertion_generated_at_string(bad_dir: Path) -> None:
            assertion_path = bad_dir / "production-ready-assertion.json"
            assertion_payload = load_json(assertion_path)
            assertion_payload["generatedAtEpoch"] = str(assertion_payload["generatedAtEpoch"])
            assertion_path.write_text(json.dumps(assertion_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            manifest_path = bad_dir / "production-ready-archive-manifest.json"
            manifest_payload = load_json(manifest_path)
            manifest_payload["assertion"] = record_file(assertion_path, assertion_path.relative_to(bad_dir))
            manifest_path.write_text(json.dumps(manifest_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")

        assert_archive_rejected(
            archive_stem="bad-assertion-generated-at-string",
            expected_reason="archive_assertion_generated_at_epoch_invalid",
            pass_reason="bad_assertion_generated_at_string_archive_passed",
            reason_missing="bad_assertion_generated_at_string_archive_reason_missing",
            mutate=mutate_assertion_generated_at_string,
        )

        def mutate_manifest_assertion_bytes_string(bad_dir: Path) -> None:
            manifest_path = bad_dir / "production-ready-archive-manifest.json"
            payload = load_json(manifest_path)
            payload["assertion"]["bytes"] = str(payload["assertion"]["bytes"])
            manifest_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")

        assert_archive_rejected(
            archive_stem="bad-manifest-assertion-bytes-string",
            expected_reason="archive_manifest_assertion_bytes_invalid",
            pass_reason="bad_manifest_assertion_bytes_string_archive_passed",
            reason_missing="bad_manifest_assertion_bytes_string_archive_reason_missing",
            mutate=mutate_manifest_assertion_bytes_string,
        )

        def mutate_manifest_artifact_bytes_string(bad_dir: Path) -> None:
            assertion_path = bad_dir / "production-ready-assertion.json"
            assertion_payload = load_json(assertion_path)
            artifact_record = assertion_payload["artifacts"]["deployReadinessReceipt"]
            artifact_record["bytes"] = str(artifact_record["bytes"])
            assertion_path.write_text(json.dumps(assertion_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            manifest_path = bad_dir / "production-ready-archive-manifest.json"
            manifest_payload = load_json(manifest_path)
            manifest_payload["assertion"] = record_file(assertion_path, assertion_path.relative_to(bad_dir))
            manifest_payload["artifacts"]["deployReadinessReceipt"]["bytes"] = artifact_record["bytes"]
            manifest_path.write_text(json.dumps(manifest_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")

        assert_archive_rejected(
            archive_stem="bad-manifest-artifact-bytes-string",
            expected_reason="archive_manifest_artifact_bytes_invalid",
            pass_reason="bad_manifest_artifact_bytes_string_archive_passed",
            reason_missing="bad_manifest_artifact_bytes_string_archive_reason_missing",
            mutate=mutate_manifest_artifact_bytes_string,
        )

        def mutate_static_support_bytes_string(bad_dir: Path) -> None:
            assertion_path = bad_dir / "production-ready-assertion.json"
            assertion_payload = load_json(assertion_path)
            static_record = assertion_payload["artifacts"]["productionStaticGateReceipt"]
            support_record = static_record["supportArtifacts"]["recoveryPlanMarkdown"]
            support_record["bytes"] = str(support_record["bytes"])
            assertion_path.write_text(json.dumps(assertion_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            manifest_path = bad_dir / "production-ready-archive-manifest.json"
            manifest_payload = load_json(manifest_path)
            manifest_payload["assertion"] = record_file(assertion_path, assertion_path.relative_to(bad_dir))
            manifest_payload["artifacts"]["productionStaticGateReceipt"]["supportArtifacts"]["recoveryPlanMarkdown"]["bytes"] = support_record["bytes"]
            manifest_path.write_text(json.dumps(manifest_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")

        assert_archive_rejected(
            archive_stem="bad-static-support-bytes-string",
            expected_reason="archive_manifest_static_gate_support_bytes_invalid",
            pass_reason="bad_static_support_bytes_string_archive_passed",
            reason_missing="bad_static_support_bytes_string_archive_reason_missing",
            mutate=mutate_static_support_bytes_string,
        )

        bad_manifest_future_dir = root / "bad-manifest-future"
        shutil.copytree(stage, bad_manifest_future_dir)
        bad_manifest_future_manifest = bad_manifest_future_dir / "production-ready-archive-manifest.json"
        bad_manifest_future_payload = load_json(bad_manifest_future_manifest)
        bad_manifest_future_payload["generatedAtEpoch"] = int(time.time()) + 999999
        bad_manifest_future_manifest.write_text(json.dumps(bad_manifest_future_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        write_sha256sums(bad_manifest_future_dir)
        bad_manifest_future_archive = root / "bad-manifest-future.tar.gz"
        create_archive(bad_manifest_future_dir, bad_manifest_future_archive)
        completed = subprocess.run(
            [sys.executable, __file__, "--verify-archive", "--archive-file", str(bad_manifest_future_archive)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_manifest_future_archive_passed")
        if "archive_manifest_generated_at_future" not in completed.stderr and "archive_manifest_generated_at_future" not in completed.stdout:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_manifest_future_archive_reason_missing")

        bad_manifest_time_mismatch_dir = root / "bad-manifest-time-mismatch"
        shutil.copytree(stage, bad_manifest_time_mismatch_dir)
        bad_manifest_time_mismatch_manifest = bad_manifest_time_mismatch_dir / "production-ready-archive-manifest.json"
        bad_manifest_time_mismatch_payload = load_json(bad_manifest_time_mismatch_manifest)
        bad_manifest_time_mismatch_payload["generatedAt"] = "2000-01-01T00:00:00Z"
        bad_manifest_time_mismatch_manifest.write_text(
            json.dumps(bad_manifest_time_mismatch_payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        write_sha256sums(bad_manifest_time_mismatch_dir)
        bad_manifest_time_mismatch_archive = root / "bad-manifest-time-mismatch.tar.gz"
        create_archive(bad_manifest_time_mismatch_dir, bad_manifest_time_mismatch_archive)
        completed = subprocess.run(
            [sys.executable, __file__, "--verify-archive", "--archive-file", str(bad_manifest_time_mismatch_archive)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_manifest_time_mismatch_archive_passed")
        if "archive_manifest_generated_at_mismatch" not in completed.stderr and "archive_manifest_generated_at_mismatch" not in completed.stdout:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_manifest_time_mismatch_archive_reason_missing")

        bad_manifest_before_assertion_dir = root / "bad-manifest-before-assertion"
        shutil.copytree(stage, bad_manifest_before_assertion_dir)
        bad_manifest_before_assertion_manifest = bad_manifest_before_assertion_dir / "production-ready-archive-manifest.json"
        bad_manifest_before_assertion_payload = load_json(bad_manifest_before_assertion_manifest)
        bad_manifest_before_assertion_assertion = load_json(bad_manifest_before_assertion_dir / "production-ready-assertion.json")
        assertion_epoch = int(bad_manifest_before_assertion_assertion["generatedAtEpoch"])
        manifest_epoch = max(1, assertion_epoch - 10)
        bad_manifest_before_assertion_payload["generatedAtEpoch"] = manifest_epoch
        bad_manifest_before_assertion_payload["generatedAt"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(manifest_epoch))
        bad_manifest_before_assertion_manifest.write_text(
            json.dumps(bad_manifest_before_assertion_payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        write_sha256sums(bad_manifest_before_assertion_dir)
        bad_manifest_before_assertion_archive = root / "bad-manifest-before-assertion.tar.gz"
        create_archive(bad_manifest_before_assertion_dir, bad_manifest_before_assertion_archive)
        completed = subprocess.run(
            [sys.executable, __file__, "--verify-archive", "--archive-file", str(bad_manifest_before_assertion_archive)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_manifest_before_assertion_archive_passed")
        if "archive_manifest_before_assertion" not in completed.stderr and "archive_manifest_before_assertion" not in completed.stdout:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_manifest_before_assertion_archive_reason_missing")

        extra_file_dir = root / "extra-file"
        shutil.copytree(stage, extra_file_dir)
        (extra_file_dir / "operator-note.txt").write_text("valid checksum, but not declared by manifest\n", encoding="utf-8")
        write_sha256sums(extra_file_dir)
        extra_file_archive = root / "extra-file.tar.gz"
        create_archive(extra_file_dir, extra_file_archive)
        completed = subprocess.run(
            [sys.executable, __file__, "--verify-archive", "--archive-file", str(extra_file_archive)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=extra_file_archive_passed")
        if "archive_manifest_file_extra" not in completed.stderr and "archive_manifest_file_extra" not in completed.stdout:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=extra_file_archive_reason_missing")

        bad_support_dir = root / "bad-static-support"
        shutil.copytree(stage, bad_support_dir)
        bad_support_markdown = next(
            (bad_support_dir / "artifacts" / "productionStaticGateReceipt" / "support" / "recoveryPlanMarkdown").glob("*")
        )
        bad_support_markdown.write_text("# tampered static gate support\n", encoding="utf-8")
        bad_support_manifest = bad_support_dir / "production-ready-archive-manifest.json"
        bad_support_payload = load_json(bad_support_manifest)
        bad_support_payload["artifacts"]["productionStaticGateReceipt"]["supportArtifacts"]["recoveryPlanMarkdown"] = record_file(
            bad_support_markdown,
            bad_support_markdown.relative_to(bad_support_dir),
        )
        bad_support_manifest.write_text(json.dumps(bad_support_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        write_sha256sums(bad_support_dir)
        bad_support_archive = root / "bad-static-support.tar.gz"
        create_archive(bad_support_dir, bad_support_archive)
        completed = subprocess.run(
            [sys.executable, __file__, "--verify-archive", "--archive-file", str(bad_support_archive)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_static_support_archive_passed")
        if "archive_manifest_assertion_artifact_mismatch" not in completed.stderr and "archive_manifest_assertion_artifact_mismatch" not in completed.stdout:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=bad_static_support_archive_reason_missing")

        unsafe_archive = root / "unsafe.tar.gz"
        with tarfile.open(unsafe_archive, "w:gz") as archive:
            payload = b"unsafe\n"
            info = tarfile.TarInfo("../evil.txt")
            info.size = len(payload)
            import io

            archive.addfile(info, io.BytesIO(payload))
        completed = subprocess.run(
            [sys.executable, __file__, "--verify-archive", "--archive-file", str(unsafe_archive)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=unsafe_archive_passed")
        if "archive_member_path_unsafe" not in completed.stderr and "archive_member_path_unsafe" not in completed.stdout:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=unsafe_archive_reason_missing")

        forbidden_artifact_archive = root / "forbidden-artifact.tar.gz"
        with tarfile.open(forbidden_artifact_archive, "w:gz") as archive:
            payload = b"email,password\nload000001@example.com,do-not-archive\n"
            info = tarfile.TarInfo("artifacts/topologySmokeReceipt/load-10000.csv")
            info.size = len(payload)
            import io

            archive.addfile(info, io.BytesIO(payload))
        completed = subprocess.run(
            [sys.executable, __file__, "--verify-archive", "--archive-file", str(forbidden_artifact_archive)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=forbidden_artifact_archive_passed")
        if "archive_member_forbidden_artifact" not in completed.stderr and "archive_member_forbidden_artifact" not in completed.stdout:
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=forbidden_artifact_archive_reason_missing")

        oversized_member = tarfile.TarInfo("oversized.bin")
        oversized_member.size = MAX_ARCHIVE_MEMBER_BYTES + 1
        try:
            validate_archive_member(oversized_member)
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=oversized_member_archive_passed")
        except SystemExit as error:
            if "archive_member_too_large" not in str(error):
                raise SystemExit("production_ready_assertion_package_self_test result=fail reason=oversized_member_archive_reason_missing")

        total_limit_archive = root / "total-limit.tar.gz"
        with tarfile.open(total_limit_archive, "w:gz") as archive:
            import io

            for index in range(2):
                payload = f"{index}\n".encode("utf-8")
                info = tarfile.TarInfo(f"small-{index}.txt")
                info.size = len(payload)
                archive.addfile(info, io.BytesIO(payload))
        try:
            safe_extract_archive(total_limit_archive, root / "total-limit-out", max_total_bytes=2)
            raise SystemExit("production_ready_assertion_package_self_test result=fail reason=archive_total_limit_passed")
        except SystemExit as error:
            if "archive_total_too_large" not in str(error):
                raise SystemExit("production_ready_assertion_package_self_test result=fail reason=archive_total_limit_reason_missing")
    print("production_ready_assertion_package_self_test result=pass")


def main() -> None:
    parser = argparse.ArgumentParser(description="Package a final production-ready assertion into a portable archive.")
    parser.add_argument("--receipt-json")
    parser.add_argument("--output-dir", default="IMServer/LoadTests/results/production-ready/archive")
    parser.add_argument("--archive-file")
    parser.add_argument("--verify-archive", action="store_true")
    parser.add_argument("--artifact-root", action="append", default=[])
    parser.add_argument("--expect-base-url")
    parser.add_argument("--expect-tcp-host")
    parser.add_argument("--expect-tcp-port")
    parser.add_argument("--max-age-seconds", type=int, default=86400)
    parser.add_argument("--max-future-skew-seconds", type=int, default=300)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        run_self_test()
        return
    if args.verify_archive:
        if not args.archive_file:
            fail("archive_file_required")
        verify_archive(args)
        return
    if not args.receipt_json:
        fail("receipt_json_required")
    stage_dir, archive_path = package_assertion(args)
    print(f"production_ready_assertion_package result=pass dir={stage_dir} archive={archive_path}")


if __name__ == "__main__":
    main()
