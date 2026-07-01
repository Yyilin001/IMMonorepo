#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any


DEFAULT_RECEIPT_JSON = "IMServer/LoadTests/results/production-static/latest.json"
DEFAULT_COMPLETION_STATUS_JSON = "IMServer/LoadTests/results/production-completion-status/latest.json"
DEFAULT_COMPLETION_STATUS_MARKDOWN = "IMServer/LoadTests/results/production-completion-status/latest.md"
DEFAULT_RECOVERY_PLAN_JSON = "IMServer/LoadTests/results/production-completion-status/evidence-recovery-plan.json"
DEFAULT_RECOVERY_PLAN_MARKDOWN = "IMServer/LoadTests/results/production-completion-status/evidence-recovery-plan.md"
DEFAULT_RECOVERY_PLAN_SCRIPT = "IMServer/LoadTests/results/production-completion-status/evidence-recovery-run.sh"
EXPECTED_STATIC_RECEIPT_KIND = "imserver-production-static-gate-receipt"
EXPECTED_STATIC_RECEIPT_SCHEMA_VERSION = 1
EXPECTED_STATIC_GATE_COMMAND = "make validate-production-static"
EXPECTED_COMPLETION_STATUS_KIND = "imserver-production-completion-status"
EXPECTED_COMPLETION_STATUS_SCHEMA_VERSION = 1
EXPECTED_RECOVERY_PLAN_KIND = "imserver-production-evidence-recovery-plan"
EXPECTED_RECOVERY_PLAN_SCHEMA_VERSION = 1
EXPECTED_LOCAL_ENGINEERING_WEIGHT = 75
EXPECTED_LIVE_PRODUCTION_EVIDENCE_WEIGHT = 25


def run_git(repo_root: Path, args: list[str]) -> str:
    try:
        completed = subprocess.run(
            ["git", *args],
            cwd=repo_root,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except Exception:
        return ""
    return completed.stdout.strip()


def git_summary(repo_root: Path) -> dict[str, Any]:
    status = run_git(repo_root, ["status", "--porcelain", "--untracked-files=all"])
    rows = [line for line in status.splitlines() if line.strip()]
    untracked_rows = [line for line in rows if line.startswith("??")]
    tracked_rows = [line for line in rows if not line.startswith("??")]
    status_sha256 = hashlib.sha256(status.encode("utf-8")).hexdigest()
    return {
        "commit": run_git(repo_root, ["rev-parse", "HEAD"]),
        "branch": run_git(repo_root, ["branch", "--show-current"]),
        "dirty": bool(rows),
        "dirtyCount": len(rows),
        "trackedModifiedCount": len(tracked_rows),
        "untrackedCount": len(untracked_rows),
        "statusSha256": status_sha256,
    }


def git_diagnostic_value(summary: dict[str, Any], field: str) -> Any:
    return summary[field] if field in summary else "unknown"


def add_git_status_diagnostics(result: dict[str, Any], bound: dict[str, Any], current: dict[str, Any]) -> dict[str, Any]:
    result["currentDirtyCount"] = git_diagnostic_value(current, "dirtyCount")
    result["boundDirtyCount"] = git_diagnostic_value(bound, "dirtyCount")
    result["currentTrackedModifiedCount"] = git_diagnostic_value(current, "trackedModifiedCount")
    result["boundTrackedModifiedCount"] = git_diagnostic_value(bound, "trackedModifiedCount")
    result["currentUntrackedCount"] = git_diagnostic_value(current, "untrackedCount")
    result["boundUntrackedCount"] = git_diagnostic_value(bound, "untrackedCount")
    return result


def verify_git_binding(payload: dict[str, Any], repo_root: Path, path: Path) -> dict[str, Any] | None:
    bound = payload.get("git") or {}
    if not isinstance(bound, dict):
        return {"status": "fail", "reason": "git_binding_invalid", "path": str(path)}
    current = git_summary(repo_root)
    for field in ("commit", "branch"):
        bound_value = str(bound.get(field) or "")
        current_value = str(current.get(field) or "")
        if not bound_value or bound_value != current_value:
            return add_git_status_diagnostics({
                "status": "fail",
                "reason": "git_binding_mismatch",
                "path": str(path),
                "field": field,
                "expected": current_value,
                "actual": bound_value,
            }, bound, current)
    for field in ("dirty", "dirtyCount", "statusSha256"):
        if bound.get(field) != current.get(field):
            return add_git_status_diagnostics({
                "status": "fail",
                "reason": "git_binding_mismatch",
                "path": str(path),
                "field": field,
                "expected": current.get(field),
                "actual": bound.get(field),
            }, bound, current)
    return None


def verify_clean_git_binding(payload: dict[str, Any], path: Path) -> dict[str, Any] | None:
    bound = payload.get("git") or {}
    if not isinstance(bound, dict):
        return {"status": "fail", "reason": "git_binding_invalid", "path": str(path)}
    if bound.get("dirty") is not False:
        return {
            "status": "fail",
            "reason": "production_static_gate_git_dirty",
            "path": str(path),
            "field": "dirty",
            "boundDirtyCount": git_diagnostic_value(bound, "dirtyCount"),
            "boundTrackedModifiedCount": git_diagnostic_value(bound, "trackedModifiedCount"),
            "boundUntrackedCount": git_diagnostic_value(bound, "untrackedCount"),
        }
    dirty_count = bound.get("dirtyCount")
    if dirty_count != 0:
        return {
            "status": "fail",
            "reason": "production_static_gate_git_dirty",
            "path": str(path),
            "field": "dirtyCount",
            "value": dirty_count,
            "boundDirtyCount": dirty_count,
            "boundTrackedModifiedCount": git_diagnostic_value(bound, "trackedModifiedCount"),
            "boundUntrackedCount": git_diagnostic_value(bound, "untrackedCount"),
        }
    return None


def cli_result_line(prefix: str, result: dict[str, Any]) -> str:
    fields = ["status", "reason", "path"]
    detail_fields = (
        "field",
        "expected",
        "actual",
        "value",
        "expectedSha256",
        "actualSha256",
        "expectedRepoRoot",
        "actualRepoRoot",
        "expectedCommand",
        "actualCommand",
        "ageSeconds",
        "currentDirtyCount",
        "boundDirtyCount",
        "currentTrackedModifiedCount",
        "boundTrackedModifiedCount",
        "currentUntrackedCount",
        "boundUntrackedCount",
    )
    parts = [prefix]
    for field in fields:
        parts.append(f"{field}={result.get(field, '')}")
    for field in detail_fields:
        if field in result:
            parts.append(f"{field}={result[field]}")
    return " ".join(parts)


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_json_int(payload: dict[str, Any], field: str, context: str) -> int:
    value = payload.get(field)
    if not isinstance(value, int) or isinstance(value, bool):
        raise ValueError(f"{context}.{field} must be a JSON integer")
    return value


def require_json_bool(payload: dict[str, Any], field: str, context: str) -> bool:
    value = payload.get(field)
    if not isinstance(value, bool):
        raise ValueError(f"{context}.{field} must be a JSON boolean")
    return value


def completion_status_summary(
    repo_root: Path,
    completion_status_path: Path | None,
    completion_status_markdown_path: Path | None = None,
) -> dict[str, Any] | None:
    if completion_status_path is None:
        return None
    if not completion_status_path.is_absolute():
        completion_status_path = repo_root / completion_status_path
    if completion_status_markdown_path is None:
        completion_status_markdown_path = repo_root / DEFAULT_COMPLETION_STATUS_MARKDOWN
    elif not completion_status_markdown_path.is_absolute():
        completion_status_markdown_path = repo_root / completion_status_markdown_path
    payload = read_json(completion_status_path)
    summary = payload.get("summary") or {}
    if not isinstance(summary, dict):
        raise ValueError("completion status summary is missing")
    completion_repo_root = str(payload.get("repoRoot") or "")
    if not completion_repo_root:
        raise ValueError("completion status repoRoot is missing")
    production_target = payload.get("productionTarget")
    if not isinstance(production_target, dict):
        raise ValueError("completion status productionTarget is missing")
    production_claim = normalized_production_claim(payload.get("productionClaim"))
    if production_claim is None:
        raise ValueError("completion status productionClaim is missing")
    readiness_tiers = normalized_readiness_tiers(payload.get("readinessTiers"))
    if readiness_tiers is None:
        raise ValueError("completion status readinessTiers is missing")
    return {
        "path": str(completion_status_path),
        "sha256": file_sha256(completion_status_path),
        "markdownPath": str(completion_status_markdown_path),
        "markdownSha256": file_sha256(completion_status_markdown_path),
        "kind": str(payload.get("kind") or ""),
        "schemaVersion": require_json_int(payload, "schemaVersion", "completionStatus"),
        "repoRoot": completion_repo_root,
        "generatedAtEpoch": require_json_int(payload, "generatedAtEpoch", "completionStatus"),
        "status": str(payload.get("status") or ""),
        "localCompletionPercent": require_json_int(payload, "localCompletionPercent", "completionStatus"),
        "liveEvidenceCompletionPercent": require_json_int(payload, "liveEvidenceCompletionPercent", "completionStatus"),
        "productionCompletionPercent": require_json_int(payload, "productionCompletionPercent", "completionStatus"),
        "summary": {
            "localPassed": require_json_int(summary, "localPassed", "completionStatus.summary"),
            "localTotal": require_json_int(summary, "localTotal", "completionStatus.summary"),
            "localMissingCount": require_json_int(summary, "localMissingCount", "completionStatus.summary"),
            "liveEvidencePassed": require_json_int(summary, "liveEvidencePassed", "completionStatus.summary"),
            "liveEvidenceTotal": require_json_int(summary, "liveEvidenceTotal", "completionStatus.summary"),
            "liveEvidenceMissingCount": require_json_int(summary, "liveEvidenceMissingCount", "completionStatus.summary"),
            "missingCount": require_json_int(summary, "missingCount", "completionStatus.summary"),
            "evidenceRecoveryPlanCount": require_json_int(summary, "evidenceRecoveryPlanCount", "completionStatus.summary"),
        },
        "weights": {
            "localEngineering": require_json_int(payload.get("weights") or {}, "localEngineering", "completionStatus.weights"),
            "liveProductionEvidence": require_json_int(payload.get("weights") or {}, "liveProductionEvidence", "completionStatus.weights"),
        },
        "productionTarget": {
            "baseURL": str(production_target.get("baseURL") or ""),
            "tcpHost": str(production_target.get("tcpHost") or ""),
            "tcpPort": str(production_target.get("tcpPort") or ""),
            "missingEnv": [str(item) for item in production_target.get("missingEnv") or []],
        },
        "productionClaim": production_claim,
        "readinessTiers": readiness_tiers,
    }


def recovery_plan_summary(
    repo_root: Path,
    recovery_plan_path: Path | None,
    recovery_plan_markdown_path: Path | None,
    recovery_plan_script_path: Path | None,
) -> dict[str, Any] | None:
    if recovery_plan_path is None:
        return None
    if not recovery_plan_path.is_absolute():
        recovery_plan_path = repo_root / recovery_plan_path
    if recovery_plan_markdown_path is None:
        raise ValueError("recovery plan markdown path is required when recovery plan JSON is provided")
    if not recovery_plan_markdown_path.is_absolute():
        recovery_plan_markdown_path = repo_root / recovery_plan_markdown_path
    if recovery_plan_script_path is None:
        raise ValueError("recovery plan script path is required when recovery plan JSON is provided")
    if not recovery_plan_script_path.is_absolute():
        recovery_plan_script_path = repo_root / recovery_plan_script_path
    payload = read_json(recovery_plan_path)
    steps = payload.get("steps")
    if not isinstance(steps, list):
        raise ValueError("recovery plan steps are missing")
    summary = payload.get("summary") or {}
    if not isinstance(summary, dict):
        raise ValueError("recovery plan summary is missing")
    production_target = payload.get("productionTarget")
    if not isinstance(production_target, dict):
        raise ValueError("recovery plan productionTarget is missing")
    production_claim = normalized_production_claim(payload.get("productionClaim"))
    if production_claim is None:
        raise ValueError("recovery plan productionClaim is missing")
    readiness_tiers = normalized_readiness_tiers(payload.get("readinessTiers"))
    if readiness_tiers is None:
        raise ValueError("recovery plan readinessTiers is missing")
    return {
        "path": str(recovery_plan_path),
        "sha256": file_sha256(recovery_plan_path),
        "markdownPath": str(recovery_plan_markdown_path),
        "markdownSha256": file_sha256(recovery_plan_markdown_path),
        "scriptPath": str(recovery_plan_script_path),
        "scriptSha256": file_sha256(recovery_plan_script_path),
        "kind": str(payload.get("kind") or ""),
        "schemaVersion": require_json_int(payload, "schemaVersion", "recoveryPlan"),
        "generatedAtEpoch": require_json_int(payload, "generatedAtEpoch", "recoveryPlan"),
        "sourceStatus": str(payload.get("sourceStatus") or ""),
        "sourceStatusJson": str(payload.get("sourceStatusJson") or ""),
        "sourceStatusGeneratedAtEpoch": require_json_int(payload, "sourceStatusGeneratedAtEpoch", "recoveryPlan"),
        "readyToClaimProduction": require_json_bool(payload, "readyToClaimProduction", "recoveryPlan"),
        "localEngineeringComplete": require_json_bool(payload, "localEngineeringComplete", "recoveryPlan"),
        "stepsCount": len(steps),
        "summary": {
            "localPassed": require_json_int(summary, "localPassed", "recoveryPlan.summary"),
            "localTotal": require_json_int(summary, "localTotal", "recoveryPlan.summary"),
            "liveEvidencePassed": require_json_int(summary, "liveEvidencePassed", "recoveryPlan.summary"),
            "liveEvidenceTotal": require_json_int(summary, "liveEvidenceTotal", "recoveryPlan.summary"),
            "evidenceRecoveryPlanCount": require_json_int(summary, "evidenceRecoveryPlanCount", "recoveryPlan.summary"),
        },
        "productionTarget": {
            "baseURL": str(production_target.get("baseURL") or ""),
            "tcpHost": str(production_target.get("tcpHost") or ""),
            "tcpPort": str(production_target.get("tcpPort") or ""),
            "missingEnv": [str(item) for item in production_target.get("missingEnv") or []],
        },
        "productionClaim": production_claim,
        "readinessTiers": readiness_tiers,
    }


def receipt_payload(
    repo_root: Path,
    completion_status_path: Path | None = None,
    recovery_plan_path: Path | None = None,
    recovery_plan_markdown_path: Path | None = None,
    recovery_plan_script_path: Path | None = None,
    completion_status_markdown_path: Path | None = None,
) -> dict[str, Any]:
    completion = completion_status_summary(repo_root, completion_status_path, completion_status_markdown_path)
    recovery_plan = recovery_plan_summary(repo_root, recovery_plan_path, recovery_plan_markdown_path, recovery_plan_script_path)
    generated_at_epoch = int(time.time())
    payload = {
        "kind": EXPECTED_STATIC_RECEIPT_KIND,
        "schemaVersion": EXPECTED_STATIC_RECEIPT_SCHEMA_VERSION,
        "status": "pass",
        "generatedAtEpoch": generated_at_epoch,
        "repoRoot": str(repo_root),
        "gate": {
            "command": EXPECTED_STATIC_GATE_COMMAND,
            "completed": True,
        },
        "git": git_summary(repo_root),
        "policy": {
            "runtimeProductionEvidence": False,
            "doesNotReplaceProductionAssertion": True,
        },
    }
    if completion is not None:
        payload["completionStatus"] = completion
    if recovery_plan is not None:
        payload["recoveryPlan"] = recovery_plan
    return payload


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(path)


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def normalized_production_target(value: Any) -> dict[str, Any] | None:
    if not isinstance(value, dict):
        return None
    missing_env = value.get("missingEnv")
    if (
        not isinstance(value.get("baseURL"), str)
        or not isinstance(value.get("tcpHost"), str)
        or not isinstance(value.get("tcpPort"), str)
        or not isinstance(missing_env, list)
        or not all(isinstance(item, str) for item in missing_env)
    ):
        return None
    return {
        "baseURL": value["baseURL"],
        "tcpHost": value["tcpHost"],
        "tcpPort": value["tcpPort"],
        "missingEnv": list(missing_env),
    }


def normalized_production_claim(value: Any) -> dict[str, Any] | None:
    if not isinstance(value, dict):
        return None
    required_evidence = value.get("requiredEvidence")
    blockers = value.get("blockers")
    if (
        not isinstance(required_evidence, list)
        or not all(isinstance(item, str) for item in required_evidence)
        or not isinstance(blockers, list)
        or not all(isinstance(item, str) for item in blockers)
        or not isinstance(value.get("claimLevel"), str)
        or not isinstance(value.get("basis"), str)
    ):
        return None
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
    if any(not isinstance(value.get(field), bool) for field in bool_fields):
        return None
    return {
        **{field: value[field] for field in bool_fields},
        "claimLevel": value["claimLevel"],
        "basis": value["basis"],
        "requiredEvidence": list(required_evidence),
        "blockers": list(blockers),
    }


def normalized_readiness_tiers(value: Any) -> dict[str, Any] | None:
    if not isinstance(value, dict):
        return None
    expected_tiers = ("localEngineering", "liveProductionEvidence", "productionReady")
    if sorted(str(item) for item in value) != sorted(expected_tiers):
        return None
    local_tier_fields = {"status", "percent", "passed", "total", "claim"}
    production_tier_fields = {"status", "percent", "claimAllowed", "targetComplete", "blockingReasons", "claim"}

    def require_string(tier: dict[str, Any], field: str) -> str | None:
        raw = tier.get(field)
        return raw if isinstance(raw, str) else None

    def require_int(tier: dict[str, Any], field: str) -> int | None:
        raw = tier.get(field)
        return raw if isinstance(raw, int) and not isinstance(raw, bool) else None

    def require_bool(tier: dict[str, Any], field: str) -> bool | None:
        raw = tier.get(field)
        return raw if isinstance(raw, bool) else None

    def require_string_list(tier: dict[str, Any], field: str) -> list[str] | None:
        raw = tier.get(field)
        if not isinstance(raw, list) or not all(isinstance(item, str) for item in raw):
            return None
        return list(raw)

    normalized: dict[str, Any] = {}
    for tier_name in ("localEngineering", "liveProductionEvidence"):
        tier = value.get(tier_name)
        if not isinstance(tier, dict):
            return None
        if set(str(item) for item in tier) != local_tier_fields:
            return None
        status = require_string(tier, "status")
        percent = require_int(tier, "percent")
        passed = require_int(tier, "passed")
        total = require_int(tier, "total")
        claim = require_string(tier, "claim")
        if status is None or percent is None or passed is None or total is None or claim is None:
            return None
        normalized[tier_name] = {
            "status": status,
            "percent": percent,
            "passed": passed,
            "total": total,
            "claim": claim,
        }
    production_tier = value.get("productionReady")
    if not isinstance(production_tier, dict):
        return None
    if set(str(item) for item in production_tier) != production_tier_fields:
        return None
    production_status = require_string(production_tier, "status")
    production_percent = require_int(production_tier, "percent")
    claim_allowed = require_bool(production_tier, "claimAllowed")
    target_complete = require_bool(production_tier, "targetComplete")
    blocking_reasons = require_string_list(production_tier, "blockingReasons")
    production_claim = require_string(production_tier, "claim")
    if (
        production_status is None
        or production_percent is None
        or claim_allowed is None
        or target_complete is None
        or blocking_reasons is None
        or production_claim is None
    ):
        return None
    normalized["productionReady"] = {
        "status": production_status,
        "percent": production_percent,
        "claimAllowed": claim_allowed,
        "targetComplete": target_complete,
        "blockingReasons": blocking_reasons,
        "claim": production_claim,
    }
    return normalized


def support_root_match(path: Path, support_roots: list[str] | None = None) -> Path | None:
    file_name = path.name
    if not file_name:
        return None
    for raw_root in support_roots or []:
        if not raw_root:
            continue
        root = Path(str(raw_root)).expanduser()
        candidates: list[Path] = []
        if root.is_file():
            candidates.append(root)
        else:
            candidates.append(root / file_name)
            if root.is_dir():
                candidates.extend(sorted(root.glob(f"**/{file_name}")))
        for candidate in candidates:
            if candidate.is_file() and candidate.name == file_name:
                return candidate
    return None


def resolve_bound_file(
    path: Path,
    support_roots: list[str] | None = None,
    prefer_support_roots: bool = False,
    require_support_root: bool = False,
) -> Path:
    if prefer_support_roots or require_support_root:
        support_match = support_root_match(path, support_roots)
        if support_match is not None:
            return support_match
        if require_support_root:
            first_root = Path(str((support_roots or [""])[0])).expanduser()
            return first_root / path.name if str(first_root) else path
    if path.is_file():
        return path
    support_match = support_root_match(path, support_roots)
    if support_match is not None:
        return support_match
    file_name = path.name
    if not file_name:
        return path
    return path


def verify_completion_status_binding(
    payload: dict[str, Any],
    path: Path,
    max_age_seconds: int,
    future_skew_seconds: int,
    support_roots: list[str] | None = None,
    prefer_support_roots: bool = False,
    require_support_root: bool = False,
) -> dict[str, Any] | None:
    completion = payload.get("completionStatus")
    if not isinstance(completion, dict):
        return {"status": "fail", "reason": "completion_status_missing", "path": str(path)}
    completion_path = resolve_bound_file(
        Path(str(completion.get("path") or "")),
        support_roots,
        prefer_support_roots,
        require_support_root,
    )
    if not completion_path.is_file():
        return {"status": "fail", "reason": "completion_status_file_missing", "path": str(completion_path)}
    completion_markdown_path = resolve_bound_file(
        Path(str(completion.get("markdownPath") or "")),
        support_roots,
        prefer_support_roots,
        require_support_root,
    )
    if not completion_markdown_path.is_file():
        return {"status": "fail", "reason": "completion_status_markdown_missing", "path": str(completion_markdown_path)}
    expected_sha = str(completion.get("sha256") or "")
    actual_sha = file_sha256(completion_path)
    if not expected_sha or actual_sha != expected_sha:
        return {
            "status": "fail",
            "reason": "completion_status_sha256_mismatch",
            "path": str(completion_path),
            "expectedSha256": expected_sha,
            "actualSha256": actual_sha,
        }
    expected_markdown_sha = str(completion.get("markdownSha256") or "")
    actual_markdown_sha = file_sha256(completion_markdown_path)
    if not expected_markdown_sha or actual_markdown_sha != expected_markdown_sha:
        return {
            "status": "fail",
            "reason": "completion_status_markdown_sha256_mismatch",
            "path": str(completion_markdown_path),
            "expectedSha256": expected_markdown_sha,
            "actualSha256": actual_markdown_sha,
        }
    try:
        current = read_json(completion_path)
        current_kind = str(current.get("kind") or "")
        bound_kind = str(completion.get("kind") or "")
        if current_kind != EXPECTED_COMPLETION_STATUS_KIND or bound_kind != EXPECTED_COMPLETION_STATUS_KIND:
            return {
                "status": "fail",
                "reason": "completion_status_kind_mismatch",
                "path": str(completion_path),
                "boundKind": bound_kind,
                "currentKind": current_kind,
            }
        current_schema_version = require_json_int(current, "schemaVersion", "completionStatus.file")
        bound_schema_version = require_json_int(completion, "schemaVersion", "completionStatus.receipt")
        if (
            current_schema_version != EXPECTED_COMPLETION_STATUS_SCHEMA_VERSION
            or bound_schema_version != EXPECTED_COMPLETION_STATUS_SCHEMA_VERSION
        ):
            return {
                "status": "fail",
                "reason": "completion_status_schema_version_mismatch",
                "path": str(completion_path),
                "boundSchemaVersion": bound_schema_version,
                "currentSchemaVersion": current_schema_version,
            }
        current_weights = current.get("weights") or {}
        bound_weights = completion.get("weights") or {}
        if not isinstance(current_weights, dict) or not isinstance(bound_weights, dict):
            return {"status": "fail", "reason": "completion_status_weights_invalid", "path": str(completion_path)}
        expected_weights = {
            "localEngineering": EXPECTED_LOCAL_ENGINEERING_WEIGHT,
            "liveProductionEvidence": EXPECTED_LIVE_PRODUCTION_EVIDENCE_WEIGHT,
        }
        for field, expected in expected_weights.items():
            current_weight = require_json_int(current_weights, field, "completionStatus.file.weights")
            bound_weight = require_json_int(bound_weights, field, "completionStatus.receipt.weights")
            if current_weight != expected or bound_weight != expected:
                return {
                    "status": "fail",
                    "reason": "completion_status_weights_mismatch",
                    "path": str(completion_path),
                    "field": field,
                    "expected": expected,
                    "bound": bound_weight,
                    "current": current_weight,
                }
        current_target = normalized_production_target(current.get("productionTarget"))
        bound_target = normalized_production_target(completion.get("productionTarget"))
        if current_target is None or bound_target is None:
            return {"status": "fail", "reason": "completion_status_target_invalid", "path": str(completion_path)}
        if current_target != bound_target:
            return {
                "status": "fail",
                "reason": "completion_status_target_mismatch",
                "path": str(completion_path),
            }
        current_claim = normalized_production_claim(current.get("productionClaim"))
        bound_claim = normalized_production_claim(completion.get("productionClaim"))
        if current_claim is None or bound_claim is None:
            return {"status": "fail", "reason": "completion_status_claim_invalid", "path": str(completion_path)}
        if current_claim != bound_claim:
            return {
                "status": "fail",
                "reason": "completion_status_claim_mismatch",
                "path": str(completion_path),
            }
        current_tiers = normalized_readiness_tiers(current.get("readinessTiers"))
        bound_tiers = normalized_readiness_tiers(completion.get("readinessTiers"))
        if current_tiers is None or bound_tiers is None:
            return {"status": "fail", "reason": "completion_status_readiness_tiers_invalid", "path": str(completion_path)}
        if current_tiers != bound_tiers:
            return {
                "status": "fail",
                "reason": "completion_status_readiness_tiers_mismatch",
                "path": str(completion_path),
            }
        receipt_repo_root = str(payload.get("repoRoot") or "")
        bound_repo_root = str(completion.get("repoRoot") or "")
        current_repo_root = str(current.get("repoRoot") or "")
        if not bound_repo_root or not current_repo_root:
            return {"status": "fail", "reason": "completion_status_repo_root_missing", "path": str(completion_path)}
        if not Path(bound_repo_root).is_absolute() or not Path(current_repo_root).is_absolute():
            return {"status": "fail", "reason": "completion_status_repo_root_not_absolute", "path": str(completion_path)}
        receipt_repo_resolved = str(Path(receipt_repo_root).resolve())
        bound_repo_resolved = str(Path(bound_repo_root).resolve())
        current_repo_resolved = str(Path(current_repo_root).resolve())
        if bound_repo_resolved != current_repo_resolved or bound_repo_resolved != receipt_repo_resolved:
            return {
                "status": "fail",
                "reason": "completion_status_repo_root_mismatch",
                "path": str(completion_path),
                "receiptRepoRoot": receipt_repo_resolved,
                "boundRepoRoot": bound_repo_resolved,
                "currentRepoRoot": current_repo_resolved,
            }
        completion_generated_at = require_json_int(current, "generatedAtEpoch", "completionStatus.file")
        receipt_generated_at = require_json_int(payload, "generatedAtEpoch", "receipt")
        if completion_generated_at > receipt_generated_at:
            return {
                "status": "fail",
                "reason": "completion_status_newer_than_receipt",
                "path": str(completion_path),
                "receiptGeneratedAtEpoch": receipt_generated_at,
                "completionGeneratedAtEpoch": completion_generated_at,
            }
        now = int(time.time())
        completion_age = now - completion_generated_at
        if completion_age < -future_skew_seconds:
            return {
                "status": "fail",
                "reason": "completion_status_generated_at_in_future",
                "path": str(completion_path),
                "ageSeconds": completion_age,
            }
        if max_age_seconds > 0 and completion_age > max_age_seconds:
            return {
                "status": "fail",
                "reason": "completion_status_stale",
                "path": str(completion_path),
                "ageSeconds": completion_age,
            }
        current_summary = current.get("summary") or {}
        if not isinstance(current_summary, dict):
            return {"status": "fail", "reason": "completion_status_summary_missing", "path": str(completion_path)}
        try:
            import production_completion_status as completion_status_renderer

            expected_markdown = completion_status_renderer.render_markdown(current)
        except Exception as error:  # noqa: BLE001 - report renderer drift explicitly.
            return {"status": "fail", "reason": "completion_status_markdown_render_failed", "path": str(completion_path), "error": str(error)}
        actual_markdown = completion_markdown_path.read_text(encoding="utf-8")
        if actual_markdown != expected_markdown:
            return {"status": "fail", "reason": "completion_status_markdown_mismatch", "path": str(completion_markdown_path)}
        checks = {
            "generatedAtEpoch": completion_generated_at,
            "localCompletionPercent": require_json_int(current, "localCompletionPercent", "completionStatus.file"),
            "liveEvidenceCompletionPercent": require_json_int(current, "liveEvidenceCompletionPercent", "completionStatus.file"),
            "productionCompletionPercent": require_json_int(current, "productionCompletionPercent", "completionStatus.file"),
        }
        for field, actual in checks.items():
            if require_json_int(completion, field, "completionStatus.receipt") != actual:
                return {"status": "fail", "reason": "completion_status_binding_mismatch", "field": field, "path": str(completion_path)}
        if str(completion.get("status") or "") != str(current.get("status") or ""):
            return {"status": "fail", "reason": "completion_status_binding_mismatch", "field": "status", "path": str(completion_path)}
        bound_summary = completion.get("summary") or {}
        if not isinstance(bound_summary, dict):
            return {"status": "fail", "reason": "completion_status_binding_mismatch", "field": "summary", "path": str(completion_path)}
        for field in (
            "localPassed",
            "localTotal",
            "localMissingCount",
            "liveEvidencePassed",
            "liveEvidenceTotal",
            "liveEvidenceMissingCount",
            "missingCount",
            "evidenceRecoveryPlanCount",
        ):
            bound_value = require_json_int(bound_summary, field, "completionStatus.receipt.summary")
            current_value = require_json_int(current_summary, field, "completionStatus.file.summary")
            if bound_value != current_value:
                return {"status": "fail", "reason": "completion_status_binding_mismatch", "field": f"summary.{field}", "path": str(completion_path)}
        if require_json_int(completion, "localCompletionPercent", "completionStatus.receipt") != 100:
            return {"status": "fail", "reason": "completion_status_local_incomplete", "path": str(completion_path)}
        if require_json_int(bound_summary, "localMissingCount", "completionStatus.receipt.summary") != 0:
            return {"status": "fail", "reason": "completion_status_local_missing", "path": str(completion_path)}
    except Exception as error:  # noqa: BLE001 - surface receipt binding errors.
        return {"status": "fail", "reason": "completion_status_binding_invalid", "path": str(completion_path), "error": str(error)}
    return None


def verify_recovery_plan_binding(
    payload: dict[str, Any],
    path: Path,
    max_age_seconds: int,
    future_skew_seconds: int,
    support_roots: list[str] | None = None,
    prefer_support_roots: bool = False,
    require_support_root: bool = False,
) -> dict[str, Any] | None:
    recovery_plan = payload.get("recoveryPlan")
    if not isinstance(recovery_plan, dict):
        return {"status": "fail", "reason": "recovery_plan_missing", "path": str(path)}
    recovery_plan_path = resolve_bound_file(
        Path(str(recovery_plan.get("path") or "")),
        support_roots,
        prefer_support_roots,
        require_support_root,
    )
    if not recovery_plan_path.is_file():
        return {"status": "fail", "reason": "recovery_plan_file_missing", "path": str(recovery_plan_path)}
    markdown_path = resolve_bound_file(
        Path(str(recovery_plan.get("markdownPath") or "")),
        support_roots,
        prefer_support_roots,
        require_support_root,
    )
    if not markdown_path.is_file():
        return {"status": "fail", "reason": "recovery_plan_markdown_missing", "path": str(markdown_path)}
    script_path = resolve_bound_file(
        Path(str(recovery_plan.get("scriptPath") or "")),
        support_roots,
        prefer_support_roots,
        require_support_root,
    )
    if not script_path.is_file():
        return {"status": "fail", "reason": "recovery_plan_script_missing", "path": str(script_path)}
    expected_sha = str(recovery_plan.get("sha256") or "")
    actual_sha = file_sha256(recovery_plan_path)
    if not expected_sha or actual_sha != expected_sha:
        return {
            "status": "fail",
            "reason": "recovery_plan_sha256_mismatch",
            "path": str(recovery_plan_path),
            "expectedSha256": expected_sha,
            "actualSha256": actual_sha,
        }
    expected_markdown_sha = str(recovery_plan.get("markdownSha256") or "")
    actual_markdown_sha = file_sha256(markdown_path)
    if not expected_markdown_sha or actual_markdown_sha != expected_markdown_sha:
        return {
            "status": "fail",
            "reason": "recovery_plan_markdown_sha256_mismatch",
            "path": str(markdown_path),
            "expectedSha256": expected_markdown_sha,
            "actualSha256": actual_markdown_sha,
        }
    expected_script_sha = str(recovery_plan.get("scriptSha256") or "")
    actual_script_sha = file_sha256(script_path)
    if not expected_script_sha or actual_script_sha != expected_script_sha:
        return {
            "status": "fail",
            "reason": "recovery_plan_script_sha256_mismatch",
            "path": str(script_path),
            "expectedSha256": expected_script_sha,
            "actualSha256": actual_script_sha,
        }
    if script_path.stat().st_mode & 0o111 == 0:
        return {"status": "fail", "reason": "recovery_plan_script_not_executable", "path": str(script_path)}
    try:
        current = read_json(recovery_plan_path)
        current_kind = str(current.get("kind") or "")
        bound_kind = str(recovery_plan.get("kind") or "")
        if current_kind != EXPECTED_RECOVERY_PLAN_KIND or bound_kind != EXPECTED_RECOVERY_PLAN_KIND:
            return {
                "status": "fail",
                "reason": "recovery_plan_kind_mismatch",
                "path": str(recovery_plan_path),
                "boundKind": bound_kind,
                "currentKind": current_kind,
            }
        current_schema_version = require_json_int(current, "schemaVersion", "recoveryPlan.file")
        bound_schema_version = require_json_int(recovery_plan, "schemaVersion", "recoveryPlan.receipt")
        if (
            current_schema_version != EXPECTED_RECOVERY_PLAN_SCHEMA_VERSION
            or bound_schema_version != EXPECTED_RECOVERY_PLAN_SCHEMA_VERSION
        ):
            return {
                "status": "fail",
                "reason": "recovery_plan_schema_version_mismatch",
                "path": str(recovery_plan_path),
                "boundSchemaVersion": bound_schema_version,
                "currentSchemaVersion": current_schema_version,
            }
        try:
            import production_evidence_recovery_plan as recovery_plan_renderer

            expected_markdown = recovery_plan_renderer.render_markdown(current)
            expected_script = recovery_plan_renderer.render_shell_script(current)
        except Exception as error:  # noqa: BLE001 - report renderer drift explicitly.
            return {"status": "fail", "reason": "recovery_plan_artifact_render_failed", "path": str(recovery_plan_path), "error": str(error)}
        actual_markdown = markdown_path.read_text(encoding="utf-8")
        if actual_markdown != expected_markdown:
            return {"status": "fail", "reason": "recovery_plan_markdown_mismatch", "path": str(markdown_path)}
        actual_script = script_path.read_text(encoding="utf-8")
        if actual_script != expected_script:
            return {"status": "fail", "reason": "recovery_plan_script_mismatch", "path": str(script_path)}
        completion = payload.get("completionStatus")
        if not isinstance(completion, dict):
            return {"status": "fail", "reason": "recovery_plan_completion_status_missing", "path": str(recovery_plan_path)}
        completion_target = normalized_production_target(completion.get("productionTarget"))
        bound_target = normalized_production_target(recovery_plan.get("productionTarget"))
        current_target = normalized_production_target(current.get("productionTarget"))
        if completion_target is None or bound_target is None or current_target is None:
            return {"status": "fail", "reason": "recovery_plan_target_invalid", "path": str(recovery_plan_path)}
        if bound_target != current_target:
            return {"status": "fail", "reason": "recovery_plan_target_mismatch", "path": str(recovery_plan_path)}
        if current_target != completion_target:
            return {"status": "fail", "reason": "recovery_plan_completion_target_mismatch", "path": str(recovery_plan_path)}
        completion_claim = normalized_production_claim(completion.get("productionClaim"))
        bound_claim = normalized_production_claim(recovery_plan.get("productionClaim"))
        current_claim = normalized_production_claim(current.get("productionClaim"))
        if completion_claim is None or bound_claim is None or current_claim is None:
            return {"status": "fail", "reason": "recovery_plan_claim_invalid", "path": str(recovery_plan_path)}
        if bound_claim != current_claim:
            return {"status": "fail", "reason": "recovery_plan_claim_mismatch", "path": str(recovery_plan_path)}
        if current_claim != completion_claim:
            return {"status": "fail", "reason": "recovery_plan_completion_claim_mismatch", "path": str(recovery_plan_path)}
        completion_tiers = normalized_readiness_tiers(completion.get("readinessTiers"))
        bound_tiers = normalized_readiness_tiers(recovery_plan.get("readinessTiers"))
        current_tiers = normalized_readiness_tiers(current.get("readinessTiers"))
        if completion_tiers is None or bound_tiers is None or current_tiers is None:
            return {"status": "fail", "reason": "recovery_plan_readiness_tiers_invalid", "path": str(recovery_plan_path)}
        if bound_tiers != current_tiers:
            return {"status": "fail", "reason": "recovery_plan_readiness_tiers_mismatch", "path": str(recovery_plan_path)}
        if current_tiers != completion_tiers:
            return {"status": "fail", "reason": "recovery_plan_completion_readiness_tiers_mismatch", "path": str(recovery_plan_path)}
        completion_generated_at = require_json_int(completion, "generatedAtEpoch", "completionStatus.receipt")
        bound_source_generated_at = require_json_int(recovery_plan, "sourceStatusGeneratedAtEpoch", "recoveryPlan.receipt")
        current_source_generated_at = require_json_int(current, "sourceStatusGeneratedAtEpoch", "recoveryPlan.file")
        if bound_source_generated_at != completion_generated_at or current_source_generated_at != completion_generated_at:
            return {
                "status": "fail",
                "reason": "recovery_plan_source_status_mismatch",
                "path": str(recovery_plan_path),
                "completionGeneratedAtEpoch": completion_generated_at,
                "boundSourceStatusGeneratedAtEpoch": bound_source_generated_at,
                "currentSourceStatusGeneratedAtEpoch": current_source_generated_at,
            }
        completion_summary = completion.get("summary") or {}
        current_summary = current.get("summary") or {}
        bound_summary = recovery_plan.get("summary") or {}
        if not isinstance(completion_summary, dict) or not isinstance(current_summary, dict) or not isinstance(bound_summary, dict):
            return {"status": "fail", "reason": "recovery_plan_summary_invalid", "path": str(recovery_plan_path)}
        expected_steps = require_json_int(completion_summary, "evidenceRecoveryPlanCount", "completionStatus.receipt.summary")
        current_steps = current.get("steps")
        if not isinstance(current_steps, list):
            return {"status": "fail", "reason": "recovery_plan_steps_invalid", "path": str(recovery_plan_path)}
        bound_steps = require_json_int(recovery_plan, "stepsCount", "recoveryPlan.receipt")
        if bound_steps != len(current_steps) or len(current_steps) != expected_steps:
            return {
                "status": "fail",
                "reason": "recovery_plan_steps_count_mismatch",
                "path": str(recovery_plan_path),
                "expectedSteps": expected_steps,
                "boundSteps": bound_steps,
                "currentSteps": len(current_steps),
            }
        if not isinstance(recovery_plan.get("sourceStatus"), str) or not isinstance(current.get("sourceStatus"), str):
            return {"status": "fail", "reason": "recovery_plan_binding_mismatch", "field": "sourceStatus", "path": str(recovery_plan_path)}
        if recovery_plan.get("sourceStatus") != current.get("sourceStatus"):
            return {"status": "fail", "reason": "recovery_plan_binding_mismatch", "field": "sourceStatus", "path": str(recovery_plan_path)}
        for field in ("readyToClaimProduction", "localEngineeringComplete"):
            bound_value = require_json_bool(recovery_plan, field, "recoveryPlan.receipt")
            current_value = require_json_bool(current, field, "recoveryPlan.file")
            if bound_value != current_value:
                return {"status": "fail", "reason": "recovery_plan_binding_mismatch", "field": field, "path": str(recovery_plan_path)}
        for field in ("localPassed", "localTotal", "liveEvidencePassed", "liveEvidenceTotal", "evidenceRecoveryPlanCount"):
            bound_value = require_json_int(bound_summary, field, "recoveryPlan.receipt.summary")
            current_value = require_json_int(current_summary, field, "recoveryPlan.file.summary")
            if bound_value != current_value:
                return {"status": "fail", "reason": "recovery_plan_binding_mismatch", "field": f"summary.{field}", "path": str(recovery_plan_path)}
        plan_generated_at = require_json_int(current, "generatedAtEpoch", "recoveryPlan.file")
        receipt_generated_at = require_json_int(payload, "generatedAtEpoch", "receipt")
        if plan_generated_at > receipt_generated_at:
            return {
                "status": "fail",
                "reason": "recovery_plan_newer_than_receipt",
                "path": str(recovery_plan_path),
                "receiptGeneratedAtEpoch": receipt_generated_at,
                "recoveryPlanGeneratedAtEpoch": plan_generated_at,
            }
        now = int(time.time())
        plan_age = now - plan_generated_at
        if plan_age < -future_skew_seconds:
            return {
                "status": "fail",
                "reason": "recovery_plan_generated_at_in_future",
                "path": str(recovery_plan_path),
                "ageSeconds": plan_age,
            }
        if max_age_seconds > 0 and plan_age > max_age_seconds:
            return {
                "status": "fail",
                "reason": "recovery_plan_stale",
                "path": str(recovery_plan_path),
                "ageSeconds": plan_age,
            }
    except Exception as error:  # noqa: BLE001 - surface receipt binding errors.
        return {"status": "fail", "reason": "recovery_plan_binding_invalid", "path": str(recovery_plan_path), "error": str(error)}
    return None


def verify_receipt(
    path: Path,
    max_age_seconds: int,
    future_skew_seconds: int,
    require_completion_status: bool = False,
    require_recovery_plan: bool = False,
    expect_repo_root: str = "",
    require_current_git: bool = False,
    require_clean_git: bool = False,
    support_roots: list[str] | None = None,
    prefer_support_roots: bool = False,
    require_support_root: bool = False,
) -> dict[str, Any]:
    if not path.is_file():
        return {"status": "missing", "reason": "file_missing", "path": str(path)}
    try:
        payload = read_json(path)
    except Exception as error:  # noqa: BLE001 - report malformed receipt.
        return {"status": "fail", "reason": "invalid_json", "path": str(path), "error": str(error)}
    if payload.get("kind") != EXPECTED_STATIC_RECEIPT_KIND:
        return {"status": "fail", "reason": "kind_mismatch", "path": str(path)}
    try:
        schema_version = require_json_int(payload, "schemaVersion", "receipt")
    except ValueError:
        return {
            "status": "fail",
            "reason": "schema_version_mismatch",
            "path": str(path),
            "expectedSchemaVersion": EXPECTED_STATIC_RECEIPT_SCHEMA_VERSION,
            "actualSchemaVersion": payload.get("schemaVersion") or 0,
        }
    if schema_version != EXPECTED_STATIC_RECEIPT_SCHEMA_VERSION:
        return {
            "status": "fail",
            "reason": "schema_version_mismatch",
            "path": str(path),
            "expectedSchemaVersion": EXPECTED_STATIC_RECEIPT_SCHEMA_VERSION,
            "actualSchemaVersion": schema_version,
        }
    if payload.get("status") != "pass":
        return {"status": "fail", "reason": "status_not_pass", "path": str(path)}
    gate = payload.get("gate") or {}
    if not isinstance(gate, dict):
        return {"status": "fail", "reason": "gate_invalid", "path": str(path)}
    if str(gate.get("command") or "") != EXPECTED_STATIC_GATE_COMMAND:
        return {
            "status": "fail",
            "reason": "gate_command_mismatch",
            "path": str(path),
            "expectedCommand": EXPECTED_STATIC_GATE_COMMAND,
            "actualCommand": str(gate.get("command") or ""),
        }
    if gate.get("completed") is not True:
        return {"status": "fail", "reason": "gate_not_completed", "path": str(path)}
    repo_root_value = str(payload.get("repoRoot") or "")
    if not repo_root_value:
        return {"status": "fail", "reason": "repo_root_missing", "path": str(path)}
    repo_root_path = Path(repo_root_value)
    if not repo_root_path.is_absolute():
        return {"status": "fail", "reason": "repo_root_not_absolute", "path": str(path), "repoRoot": repo_root_value}
    if expect_repo_root:
        expected = str(Path(expect_repo_root).resolve())
        actual = str(repo_root_path.resolve())
        if actual != expected:
            return {
                "status": "fail",
                "reason": "repo_root_mismatch",
                "path": str(path),
                "expectedRepoRoot": expected,
                "actualRepoRoot": actual,
            }
    if require_current_git:
        git_error = verify_git_binding(payload, repo_root_path, path)
        if git_error is not None:
            return git_error
    if require_clean_git:
        git_error = verify_clean_git_binding(payload, path)
        if git_error is not None:
            return git_error
    if (payload.get("policy") or {}).get("runtimeProductionEvidence") is not False:
        return {"status": "fail", "reason": "runtime_evidence_policy_mismatch", "path": str(path)}
    if (payload.get("policy") or {}).get("doesNotReplaceProductionAssertion") is not True:
        return {"status": "fail", "reason": "assertion_policy_mismatch", "path": str(path)}
    if require_completion_status:
        completion_error = verify_completion_status_binding(
            payload,
            path,
            max_age_seconds,
            future_skew_seconds,
            support_roots,
            prefer_support_roots,
            require_support_root,
        )
        if completion_error is not None:
            return completion_error
    if require_recovery_plan:
        if not require_completion_status:
            return {"status": "fail", "reason": "recovery_plan_requires_completion_status", "path": str(path)}
        recovery_error = verify_recovery_plan_binding(
            payload,
            path,
            max_age_seconds,
            future_skew_seconds,
            support_roots,
            prefer_support_roots,
            require_support_root,
        )
        if recovery_error is not None:
            return recovery_error
    try:
        generated_at_epoch = require_json_int(payload, "generatedAtEpoch", "receipt")
    except Exception:
        return {"status": "fail", "reason": "generated_at_invalid", "path": str(path)}
    now = int(time.time())
    age = now - generated_at_epoch
    if age < -future_skew_seconds:
        return {"status": "fail", "reason": "generated_at_in_future", "path": str(path), "ageSeconds": age}
    if max_age_seconds > 0 and age > max_age_seconds:
        return {"status": "fail", "reason": "stale", "path": str(path), "ageSeconds": age}
    return {
        "status": "pass",
        "reason": "fresh",
        "path": str(path),
        "ageSeconds": age,
        "maxAgeSeconds": max_age_seconds,
    }


def init_self_test_git_repo(root: Path) -> None:
    subprocess.run(["git", "init", "-q"], cwd=root, check=True)
    subprocess.run(["git", "config", "user.email", "static-gate-self-test@example.invalid"], cwd=root, check=True)
    subprocess.run(["git", "config", "user.name", "Static Gate Self Test"], cwd=root, check=True)
    subprocess.run(["git", "commit", "--allow-empty", "-m", "initial self-test state", "-q"], cwd=root, check=True)
    (root / ".git/info/exclude").write_text("*\n", encoding="utf-8")


def self_test_git_summary_counts() -> None:
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)
        subprocess.run(["git", "config", "user.email", "static-gate-self-test@example.invalid"], cwd=root, check=True)
        subprocess.run(["git", "config", "user.name", "Static Gate Self Test"], cwd=root, check=True)
        tracked = root / "tracked.txt"
        tracked.write_text("committed\n", encoding="utf-8")
        subprocess.run(["git", "add", "tracked.txt"], cwd=root, check=True)
        subprocess.run(["git", "commit", "-m", "tracked fixture", "-q"], cwd=root, check=True)
        tracked.write_text("modified\n", encoding="utf-8")
        (root / "untracked.txt").write_text("new\n", encoding="utf-8")
        summary = git_summary(root)
        if summary["dirtyCount"] != 2:
            raise SystemExit(f"self_test_git_summary_dirty_count_failed: {summary}")
        if summary["trackedModifiedCount"] != 1:
            raise SystemExit(f"self_test_git_summary_tracked_count_failed: {summary}")
        if summary["untrackedCount"] != 1:
            raise SystemExit(f"self_test_git_summary_untracked_count_failed: {summary}")


def self_test() -> None:
    self_test_git_summary_counts()
    with tempfile.TemporaryDirectory() as raw:
        import production_completion_status as completion_status_renderer
        import production_evidence_recovery_plan as recovery_plan_renderer

        root = Path(raw)
        init_self_test_git_repo(root)
        receipt = root / "latest.json"
        completion = root / DEFAULT_COMPLETION_STATUS_JSON
        completion_markdown = root / DEFAULT_COMPLETION_STATUS_MARKDOWN
        completion.parent.mkdir(parents=True, exist_ok=True)
        completion.write_text(
            json.dumps(
                {
                    "kind": EXPECTED_COMPLETION_STATUS_KIND,
                    "schemaVersion": EXPECTED_COMPLETION_STATUS_SCHEMA_VERSION,
                    "repoRoot": str(root),
                    "generatedAtEpoch": int(time.time()),
                    "status": "incomplete",
                    "localCompletionPercent": 100,
                    "liveEvidenceCompletionPercent": 0,
                    "productionCompletionPercent": 75,
                    "weights": {
                        "localEngineering": EXPECTED_LOCAL_ENGINEERING_WEIGHT,
                        "liveProductionEvidence": EXPECTED_LIVE_PRODUCTION_EVIDENCE_WEIGHT,
                    },
                    "summary": {
                        "localPassed": 36,
                        "localTotal": 36,
                        "localMissingCount": 0,
                        "liveEvidencePassed": 0,
                        "liveEvidenceTotal": 7,
                        "liveEvidenceMissingCount": 7,
                        "missingCount": 7,
                        "evidenceRecoveryPlanCount": 7,
                    },
                }
            ),
            encoding="utf-8",
        )
        completion_payload = read_json(completion)
        completion_markdown.write_text(completion_status_renderer.render_markdown(completion_payload), encoding="utf-8")

        def restore_completion_markdown() -> None:
            completion_markdown.write_text(
                completion_status_renderer.render_markdown(read_json(completion)),
                encoding="utf-8",
            )

        recovery_plan = root / DEFAULT_RECOVERY_PLAN_JSON
        recovery_markdown = root / DEFAULT_RECOVERY_PLAN_MARKDOWN
        recovery_script = root / DEFAULT_RECOVERY_PLAN_SCRIPT
        recovery_plan.parent.mkdir(parents=True, exist_ok=True)
        recovery_markdown.parent.mkdir(parents=True, exist_ok=True)
        recovery_script.parent.mkdir(parents=True, exist_ok=True)
        recovery_steps = [
            {
                "item": f"step-{index}",
                "reason": "missing_env",
                "requiredEnv": ["BASE_URL"],
                "runCommand": "true",
                "verifyCommand": "true",
            }
            for index in range(7)
        ]
        production_target = {
            "baseURL": "https://chat.myim-prod.com",
            "tcpHost": "tcp.myim-prod.com",
            "tcpPort": "9000",
            "missingEnv": [],
        }
        completion_payload = read_json(completion)
        completion_payload["productionTarget"] = production_target
        completion_payload["productionClaim"] = {
            "productionReady": False,
            "claimAllowed": False,
            "claimLevel": "not-production-ready",
            "basis": "local-engineering-or-partial-evidence-only",
            "localEngineeringComplete": True,
            "liveEvidenceComplete": False,
            "targetComplete": True,
            "finalAssertionPassed": False,
            "finalAssertionArchivePassed": False,
            "finalAssertionClaimVerified": False,
            "finalAssertionArchiveClaimVerified": False,
            "requiredEvidence": [
                "deploy-readiness",
                "current-readiness",
                "production-acceptance",
                "production-evidence-package",
                "topology-smoke",
                "final-assertion",
                "final-assertion-archive",
            ],
            "blockers": [
                "live-production-evidence-incomplete",
                "final-assertion-not-passed",
                "final-assertion-archive-not-passed",
            ],
        }
        completion_payload["readinessTiers"] = completion_status_renderer.readiness_tiers(
            ready=False,
            claim=completion_payload["productionClaim"],
            local_pass=int(completion_payload["summary"]["localPassed"]),
            local_total=int(completion_payload["summary"]["localTotal"]),
            evidence_pass=int(completion_payload["summary"]["liveEvidencePassed"]),
            evidence_total=int(completion_payload["summary"]["liveEvidenceTotal"]),
            local_completion=int(completion_payload["localCompletionPercent"]),
            live_completion=int(completion_payload["liveEvidenceCompletionPercent"]),
            production_completion=int(completion_payload["productionCompletionPercent"]),
        )
        write_json(completion, completion_payload)
        completion_markdown.write_text(completion_status_renderer.render_markdown(completion_payload), encoding="utf-8")
        recovery_payload = {
            "kind": EXPECTED_RECOVERY_PLAN_KIND,
            "schemaVersion": EXPECTED_RECOVERY_PLAN_SCHEMA_VERSION,
            "generatedAtEpoch": int(time.time()),
            "sourceStatus": "incomplete",
            "sourceStatusJson": str(completion),
            "sourceStatusGeneratedAtEpoch": int(completion_payload["generatedAtEpoch"]),
            "productionTarget": production_target,
            "productionClaim": completion_payload["productionClaim"],
            "readinessTiers": completion_payload["readinessTiers"],
            "readyToClaimProduction": False,
            "localEngineeringComplete": True,
            "summary": {
                "status": "incomplete",
                "localCompletionPercent": 100,
                "liveEvidenceCompletionPercent": 0,
                "productionCompletionPercent": 75,
                "localPassed": 36,
                "localTotal": 36,
                "liveEvidencePassed": 0,
                "liveEvidenceTotal": 7,
                "missingCount": 7,
                "evidenceRecoveryPlanCount": 7,
            },
            "localMissing": [],
            "evidenceMissing": [{"scope": "evidence", "item": f"step-{index}", "reason": "missing_env"} for index in range(7)],
            "steps": recovery_steps,
            "operatorEnvironmentTemplate": [{"name": "BASE_URL", "example": "https://chat.myim-prod.com"}],
            "oneShotRecoveryCommands": [
                command
                for step in recovery_steps
                for command in (f"# {step['item']}", step["runCommand"], step["verifyCommand"])
            ],
            "finalVerificationCommands": [
                "make production-completion-status",
                "make verify-production-completion-status",
            ],
        }
        recovery_payload["oneShotRecoveryCommands"].insert(0, "set -euo pipefail")
        recovery_payload["oneShotRecoveryCommands"].append("# final-verification")
        recovery_payload["oneShotRecoveryCommands"].extend(recovery_payload["finalVerificationCommands"])
        recovery_plan.write_text(json.dumps(recovery_payload), encoding="utf-8")
        recovery_markdown.write_text(recovery_plan_renderer.render_markdown(recovery_payload), encoding="utf-8")
        recovery_script.write_text(recovery_plan_renderer.render_shell_script(recovery_payload), encoding="utf-8")
        recovery_script.chmod(0o755)

        def restore_recovery_artifacts() -> None:
            current_recovery = read_json(recovery_plan)
            recovery_markdown.write_text(recovery_plan_renderer.render_markdown(current_recovery), encoding="utf-8")
            recovery_script.write_text(recovery_plan_renderer.render_shell_script(current_recovery), encoding="utf-8")
            recovery_script.chmod(0o755)

        write_json(receipt, receipt_payload(root, completion, recovery_plan, recovery_markdown, recovery_script))
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
            require_recovery_plan=True,
            expect_repo_root=str(root),
        )
        if result["status"] != "pass":
            raise SystemExit(f"self_test_verify_failed: {result}")
        payload = read_json(receipt)
        payload["completionStatus"]["productionTarget"]["tcpHost"] = "other.myim-prod.com"
        write_json(receipt, payload)
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
            require_recovery_plan=True,
            expect_repo_root=str(root),
        )
        if result["status"] != "fail" or result["reason"] != "completion_status_target_mismatch":
            raise SystemExit(f"self_test_completion_target_mismatch_failed: {result}")
        write_json(receipt, receipt_payload(root, completion, recovery_plan, recovery_markdown, recovery_script))
        payload = read_json(receipt)
        payload["completionStatus"]["productionTarget"]["tcpPort"] = 9000
        write_json(receipt, payload)
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
            require_recovery_plan=True,
            expect_repo_root=str(root),
        )
        if result["status"] != "fail" or result["reason"] != "completion_status_target_invalid":
            raise SystemExit(f"self_test_completion_target_type_failed: {result}")
        write_json(receipt, receipt_payload(root, completion, recovery_plan, recovery_markdown, recovery_script))
        payload = read_json(receipt)
        payload["completionStatus"]["productionClaim"]["claimAllowed"] = True
        write_json(receipt, payload)
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
            require_recovery_plan=True,
            expect_repo_root=str(root),
        )
        if result["status"] != "fail" or result["reason"] != "completion_status_claim_mismatch":
            raise SystemExit(f"self_test_completion_claim_mismatch_failed: {result}")
        write_json(receipt, receipt_payload(root, completion, recovery_plan, recovery_markdown, recovery_script))
        payload = read_json(receipt)
        payload["completionStatus"]["productionClaim"]["claimAllowed"] = "false"
        write_json(receipt, payload)
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
            require_recovery_plan=True,
            expect_repo_root=str(root),
        )
        if result["status"] != "fail" or result["reason"] != "completion_status_claim_invalid":
            raise SystemExit(f"self_test_completion_claim_type_failed: {result}")
        write_json(receipt, receipt_payload(root, completion, recovery_plan, recovery_markdown, recovery_script))
        payload = read_json(receipt)
        payload["completionStatus"]["productionClaim"]["finalAssertionClaimVerified"] = True
        write_json(receipt, payload)
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
            require_recovery_plan=True,
            expect_repo_root=str(root),
        )
        if result["status"] != "fail" or result["reason"] != "completion_status_claim_mismatch":
            raise SystemExit(f"self_test_completion_final_claim_mismatch_failed: {result}")
        write_json(receipt, receipt_payload(root, completion, recovery_plan, recovery_markdown, recovery_script))
        payload = read_json(receipt)
        payload["completionStatus"]["readinessTiers"]["productionReady"]["status"] = "ready"
        write_json(receipt, payload)
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
            require_recovery_plan=True,
            expect_repo_root=str(root),
        )
        if result["status"] != "fail" or result["reason"] != "completion_status_readiness_tiers_mismatch":
            raise SystemExit(f"self_test_completion_readiness_tiers_mismatch_failed: {result}")
        write_json(receipt, receipt_payload(root, completion, recovery_plan, recovery_markdown, recovery_script))
        payload = read_json(receipt)
        payload["completionStatus"]["readinessTiers"]["localEngineering"]["note"] = "do not trust me"
        write_json(receipt, payload)
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
            require_recovery_plan=True,
            expect_repo_root=str(root),
        )
        if result["status"] != "fail" or result["reason"] != "completion_status_readiness_tiers_invalid":
            raise SystemExit(f"self_test_completion_readiness_tiers_extra_field_failed: {result}")
        write_json(receipt, receipt_payload(root, completion, recovery_plan, recovery_markdown, recovery_script))
        payload = read_json(receipt)
        payload["completionStatus"]["readinessTiers"]["localEngineering"]["percent"] = "100"
        write_json(receipt, payload)
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
            require_recovery_plan=True,
            expect_repo_root=str(root),
        )
        if result["status"] != "fail" or result["reason"] != "completion_status_readiness_tiers_invalid":
            raise SystemExit(f"self_test_completion_readiness_tiers_type_failed: {result}")
        write_json(receipt, receipt_payload(root, completion, recovery_plan, recovery_markdown, recovery_script))
        payload = read_json(receipt)
        payload["recoveryPlan"]["productionTarget"]["tcpHost"] = "other.myim-prod.com"
        write_json(receipt, payload)
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
            require_recovery_plan=True,
            expect_repo_root=str(root),
        )
        if result["status"] != "fail" or result["reason"] != "recovery_plan_target_mismatch":
            raise SystemExit(f"self_test_recovery_target_mismatch_failed: {result}")
        write_json(receipt, receipt_payload(root, completion, recovery_plan, recovery_markdown, recovery_script))
        payload = read_json(receipt)
        payload["recoveryPlan"]["productionClaim"]["finalAssertionClaimVerified"] = True
        write_json(receipt, payload)
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
            require_recovery_plan=True,
            expect_repo_root=str(root),
        )
        if result["status"] != "fail" or result["reason"] != "recovery_plan_claim_mismatch":
            raise SystemExit(f"self_test_recovery_claim_mismatch_failed: {result}")
        write_json(receipt, receipt_payload(root, completion, recovery_plan, recovery_markdown, recovery_script))
        payload = read_json(receipt)
        payload["recoveryPlan"]["productionClaim"]["finalAssertionClaimVerified"] = "false"
        write_json(receipt, payload)
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
            require_recovery_plan=True,
            expect_repo_root=str(root),
        )
        if result["status"] != "fail" or result["reason"] != "recovery_plan_claim_invalid":
            raise SystemExit(f"self_test_recovery_claim_type_failed: {result}")
        recovery_payload = read_json(recovery_plan)
        recovery_payload["productionTarget"]["tcpHost"] = "other.myim-prod.com"
        write_json(recovery_plan, recovery_payload)
        restore_recovery_artifacts()
        write_json(receipt, receipt_payload(root, completion, recovery_plan, recovery_markdown, recovery_script))
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
            require_recovery_plan=True,
            expect_repo_root=str(root),
        )
        if result["status"] != "fail" or result["reason"] != "recovery_plan_completion_target_mismatch":
            raise SystemExit(f"self_test_recovery_completion_target_mismatch_failed: {result}")
        recovery_payload = read_json(recovery_plan)
        recovery_payload["productionTarget"]["tcpHost"] = "tcp.myim-prod.com"
        recovery_payload["productionClaim"]["finalAssertionArchiveClaimVerified"] = True
        write_json(recovery_plan, recovery_payload)
        restore_recovery_artifacts()
        write_json(receipt, receipt_payload(root, completion, recovery_plan, recovery_markdown, recovery_script))
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
            require_recovery_plan=True,
            expect_repo_root=str(root),
        )
        if result["status"] != "fail" or result["reason"] != "recovery_plan_completion_claim_mismatch":
            raise SystemExit(f"self_test_recovery_completion_claim_mismatch_failed: {result}")
        recovery_payload = read_json(recovery_plan)
        recovery_payload["productionClaim"]["finalAssertionArchiveClaimVerified"] = False
        recovery_payload["readinessTiers"]["productionReady"]["status"] = "ready"
        write_json(recovery_plan, recovery_payload)
        restore_recovery_artifacts()
        write_json(receipt, receipt_payload(root, completion, recovery_plan, recovery_markdown, recovery_script))
        payload = read_json(receipt)
        payload["recoveryPlan"]["readinessTiers"]["productionReady"]["status"] = "blocked"
        write_json(receipt, payload)
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
            require_recovery_plan=True,
            expect_repo_root=str(root),
        )
        if result["status"] != "fail" or result["reason"] != "recovery_plan_readiness_tiers_mismatch":
            raise SystemExit(f"self_test_recovery_readiness_tiers_mismatch_failed: {result}")
        recovery_payload = read_json(recovery_plan)
        write_json(receipt, receipt_payload(root, completion, recovery_plan, recovery_markdown, recovery_script))
        payload = read_json(receipt)
        payload["recoveryPlan"]["readinessTiers"]["productionReady"]["note"] = "do not trust me"
        write_json(receipt, payload)
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
            require_recovery_plan=True,
            expect_repo_root=str(root),
        )
        if result["status"] != "fail" or result["reason"] != "recovery_plan_readiness_tiers_invalid":
            raise SystemExit(f"self_test_recovery_readiness_tiers_extra_field_failed: {result}")
        recovery_payload = read_json(recovery_plan)
        write_json(receipt, receipt_payload(root, completion, recovery_plan, recovery_markdown, recovery_script))
        payload = read_json(receipt)
        payload["recoveryPlan"]["readinessTiers"]["productionReady"]["claimAllowed"] = "false"
        write_json(receipt, payload)
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
            require_recovery_plan=True,
            expect_repo_root=str(root),
        )
        if result["status"] != "fail" or result["reason"] != "recovery_plan_readiness_tiers_invalid":
            raise SystemExit(f"self_test_recovery_readiness_tiers_type_failed: {result}")
        recovery_payload = read_json(recovery_plan)
        recovery_payload["readinessTiers"] = completion_payload["readinessTiers"]
        write_json(recovery_plan, recovery_payload)
        restore_recovery_artifacts()
        recovery_payload["productionTarget"] = production_target
        write_json(recovery_plan, recovery_payload)
        restore_recovery_artifacts()
        write_json(receipt, receipt_payload(root, completion, recovery_plan, recovery_markdown, recovery_script))
        support_root = root / "portable-support"
        support_completion = support_root / "completionStatus" / completion.name
        support_completion_markdown = support_root / "completionStatusMarkdown" / completion_markdown.name
        support_recovery_plan = support_root / "recoveryPlan" / recovery_plan.name
        support_recovery_markdown = support_root / "recoveryPlanMarkdown" / recovery_markdown.name
        support_recovery_script = support_root / "recoveryPlanScript" / recovery_script.name
        support_completion.parent.mkdir(parents=True, exist_ok=True)
        support_completion_markdown.parent.mkdir(parents=True, exist_ok=True)
        support_recovery_plan.parent.mkdir(parents=True, exist_ok=True)
        support_recovery_markdown.parent.mkdir(parents=True, exist_ok=True)
        support_recovery_script.parent.mkdir(parents=True, exist_ok=True)
        support_completion.write_bytes(completion.read_bytes())
        support_completion_markdown.write_bytes(completion_markdown.read_bytes())
        support_recovery_plan.write_bytes(recovery_plan.read_bytes())
        support_recovery_markdown.write_bytes(recovery_markdown.read_bytes())
        support_recovery_script.write_bytes(recovery_script.read_bytes())
        support_recovery_script.chmod(0o755)
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
            require_recovery_plan=True,
            support_roots=[str(support_root)],
            prefer_support_roots=True,
            require_support_root=True,
            expect_repo_root=str(root),
        )
        if result["status"] != "pass":
            raise SystemExit(f"self_test_support_root_verify_failed: {result}")
        support_recovery_markdown.write_text("# recovery\ncorrupt portable copy\n", encoding="utf-8")
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
            require_recovery_plan=True,
            support_roots=[str(support_root)],
            prefer_support_roots=True,
            require_support_root=True,
        )
        if result["status"] != "fail" or result["reason"] != "recovery_plan_markdown_sha256_mismatch":
            raise SystemExit(f"self_test_support_root_preference_failed: {result}")
        support_recovery_markdown.write_bytes(recovery_markdown.read_bytes())
        support_recovery_script.write_text("#!/usr/bin/env bash\nset -euo pipefail\n# corrupt portable copy\n", encoding="utf-8")
        support_recovery_script.chmod(0o755)
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
            require_recovery_plan=True,
            support_roots=[str(support_root)],
            prefer_support_roots=True,
            require_support_root=True,
        )
        if result["status"] != "fail" or result["reason"] != "recovery_plan_script_sha256_mismatch":
            raise SystemExit(f"self_test_support_root_script_preference_failed: {result}")
        support_recovery_script.write_bytes(recovery_script.read_bytes())
        support_recovery_script.chmod(0o755)
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
            require_recovery_plan=True,
            support_roots=[str(root / "missing-support")],
            prefer_support_roots=True,
            require_support_root=True,
        )
        if result["status"] != "fail" or result["reason"] != "completion_status_file_missing":
            raise SystemExit(f"self_test_support_root_required_failed: {result}")
        payload = read_json(receipt)
        del payload["recoveryPlan"]
        write_json(receipt, payload)
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
            require_recovery_plan=True,
        )
        if result["status"] != "fail" or result["reason"] != "recovery_plan_missing":
            raise SystemExit(f"self_test_recovery_missing_failed: {result}")
        write_json(receipt, receipt_payload(root, completion, recovery_plan, recovery_markdown, recovery_script))
        recovery_markdown.write_text("# recovery\nchanged\n", encoding="utf-8")
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
            require_recovery_plan=True,
        )
        if result["status"] != "fail" or result["reason"] != "recovery_plan_markdown_sha256_mismatch":
            raise SystemExit(f"self_test_recovery_markdown_sha_failed: {result}")
        restore_recovery_artifacts()
        write_json(receipt, receipt_payload(root, completion, recovery_plan, recovery_markdown, recovery_script))
        recovery_markdown.write_text("# forged recovery\n", encoding="utf-8")
        payload = read_json(receipt)
        payload["recoveryPlan"]["markdownSha256"] = file_sha256(recovery_markdown)
        write_json(receipt, payload)
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
            require_recovery_plan=True,
        )
        if result["status"] != "fail" or result["reason"] != "recovery_plan_markdown_mismatch":
            raise SystemExit(f"self_test_recovery_markdown_semantic_failed: {result}")
        restore_recovery_artifacts()
        write_json(receipt, receipt_payload(root, completion, recovery_plan, recovery_markdown, recovery_script))
        recovery_script.write_text("#!/usr/bin/env bash\nset -euo pipefail\nchanged\n", encoding="utf-8")
        recovery_script.chmod(0o755)
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
            require_recovery_plan=True,
        )
        if result["status"] != "fail" or result["reason"] != "recovery_plan_script_sha256_mismatch":
            raise SystemExit(f"self_test_recovery_script_sha_failed: {result}")
        restore_recovery_artifacts()
        write_json(receipt, receipt_payload(root, completion, recovery_plan, recovery_markdown, recovery_script))
        recovery_script.write_text("#!/usr/bin/env bash\nset -euo pipefail\necho forged\n", encoding="utf-8")
        recovery_script.chmod(0o755)
        payload = read_json(receipt)
        payload["recoveryPlan"]["scriptSha256"] = file_sha256(recovery_script)
        write_json(receipt, payload)
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
            require_recovery_plan=True,
        )
        if result["status"] != "fail" or result["reason"] != "recovery_plan_script_mismatch":
            raise SystemExit(f"self_test_recovery_script_semantic_failed: {result}")
        restore_recovery_artifacts()
        recovery_script.chmod(0o644)
        write_json(receipt, receipt_payload(root, completion, recovery_plan, recovery_markdown, recovery_script))
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
            require_recovery_plan=True,
        )
        if result["status"] != "fail" or result["reason"] != "recovery_plan_script_not_executable":
            raise SystemExit(f"self_test_recovery_script_executable_failed: {result}")
        recovery_script.chmod(0o755)
        write_json(receipt, receipt_payload(root, completion, recovery_plan, recovery_markdown, recovery_script))
        recovery_payload = read_json(recovery_plan)
        recovery_payload["sourceStatusGeneratedAtEpoch"] = int(recovery_payload["sourceStatusGeneratedAtEpoch"]) - 1
        write_json(recovery_plan, recovery_payload)
        restore_recovery_artifacts()
        write_json(receipt, receipt_payload(root, completion, recovery_plan, recovery_markdown, recovery_script))
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
            require_recovery_plan=True,
        )
        if result["status"] != "fail" or result["reason"] != "recovery_plan_source_status_mismatch":
            raise SystemExit(f"self_test_recovery_source_failed: {result}")
        recovery_payload["sourceStatusGeneratedAtEpoch"] = int(completion_payload["generatedAtEpoch"])
        write_json(recovery_plan, recovery_payload)
        restore_recovery_artifacts()
        write_json(receipt, receipt_payload(root, completion, recovery_plan, recovery_markdown, recovery_script))
        payload = read_json(receipt)
        payload["recoveryPlan"]["readyToClaimProduction"] = "false"
        write_json(receipt, payload)
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
            require_recovery_plan=True,
        )
        if result["status"] != "fail" or result["reason"] != "recovery_plan_binding_invalid":
            raise SystemExit(f"self_test_recovery_ready_type_failed: {result}")
        recovery_payload = read_json(recovery_plan)
        recovery_payload["readyToClaimProduction"] = "false"
        write_json(recovery_plan, recovery_payload)
        restore_recovery_artifacts()
        try:
            receipt_payload(root, completion, recovery_plan, recovery_markdown, recovery_script)
        except ValueError as error:
            if "recoveryPlan.readyToClaimProduction" not in str(error):
                raise SystemExit(f"self_test_recovery_source_ready_type_wrong_error: {error}")
        else:
            raise SystemExit("self_test_recovery_source_ready_type_failed")
        recovery_payload["readyToClaimProduction"] = False
        write_json(recovery_plan, recovery_payload)
        restore_recovery_artifacts()
        payload = read_json(receipt)
        payload["schemaVersion"] = 2
        write_json(receipt, payload)
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
        )
        if result["status"] != "fail" or result["reason"] != "schema_version_mismatch":
            raise SystemExit(f"self_test_schema_version_failed: {result}")
        payload = receipt_payload(root, completion)
        payload["gate"]["command"] = "make something-else"
        write_json(receipt, payload)
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
        )
        if result["status"] != "fail" or result["reason"] != "gate_command_mismatch":
            raise SystemExit(f"self_test_gate_command_failed: {result}")
        payload = receipt_payload(root, completion)
        payload["gate"]["completed"] = False
        write_json(receipt, payload)
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
        )
        if result["status"] != "fail" or result["reason"] != "gate_not_completed":
            raise SystemExit(f"self_test_gate_completed_failed: {result}")
        write_json(receipt, receipt_payload(root, completion))
        payload = read_json(receipt)
        payload["git"]["commit"] = "wrong"
        write_json(receipt, payload)
        result = verify_receipt(receipt, max_age_seconds=86400, future_skew_seconds=300, require_current_git=True)
        if result["status"] != "fail" or result["reason"] != "git_binding_mismatch":
            raise SystemExit(f"self_test_git_binding_failed: {result}")
        line = cli_result_line("production_static_gate_receipt_verify", result)
        if "field=commit" not in line or "expected=" not in line or "actual=wrong" not in line:
            raise SystemExit(f"self_test_git_binding_cli_detail_failed: {line}")
        for detail in (
            "currentDirtyCount=",
            "boundDirtyCount=",
            "currentTrackedModifiedCount=",
            "boundTrackedModifiedCount=",
            "currentUntrackedCount=",
            "boundUntrackedCount=",
        ):
            if detail not in line:
                raise SystemExit(f"self_test_git_binding_cli_dirty_detail_failed: {line}")
        write_json(receipt, receipt_payload(root, completion))
        payload = read_json(receipt)
        payload["git"]["statusSha256"] = "0" * 64
        write_json(receipt, payload)
        result = verify_receipt(receipt, max_age_seconds=86400, future_skew_seconds=300, require_current_git=True)
        if result["status"] != "fail" or result["reason"] != "git_binding_mismatch":
            raise SystemExit(f"self_test_git_status_hash_failed: {result}")
        line = cli_result_line(
            "production_static_gate_receipt_verify",
            {
                "status": "fail",
                "reason": "git_binding_mismatch",
                "path": str(receipt),
                "field": "statusSha256",
                "expected": "f" * 64,
                "actual": "0" * 64,
            },
        )
        if "field=statusSha256" not in line or "actual=0000000000000000000000000000000000000000000000000000000000000000" not in line:
            raise SystemExit(f"self_test_git_status_hash_cli_detail_failed: {line}")
        write_json(receipt, receipt_payload(root, completion))
        payload = read_json(receipt)
        payload["git"]["dirty"] = True
        payload["git"]["dirtyCount"] = 1
        write_json(receipt, payload)
        result = verify_receipt(receipt, max_age_seconds=86400, future_skew_seconds=300, require_clean_git=True)
        if result["status"] != "fail" or result["reason"] != "production_static_gate_git_dirty":
            raise SystemExit(f"self_test_clean_git_failed: {result}")
        line = cli_result_line("production_static_gate_receipt_verify", result)
        if "field=dirty" not in line:
            raise SystemExit(f"self_test_clean_git_cli_detail_failed: {line}")
        write_json(receipt, receipt_payload(root, completion))
        payload = read_json(receipt)
        payload["repoRoot"] = "relative/repo"
        write_json(receipt, payload)
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
        )
        if result["status"] != "fail" or result["reason"] != "repo_root_not_absolute":
            raise SystemExit(f"self_test_relative_repo_root_failed: {result}")
        payload["repoRoot"] = str(root / "other")
        write_json(receipt, payload)
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            expect_repo_root=str(root),
        )
        if result["status"] != "fail" or result["reason"] != "repo_root_mismatch":
            raise SystemExit(f"self_test_repo_root_mismatch_failed: {result}")
        write_json(receipt, receipt_payload(root, completion))
        payload = read_json(receipt)
        del payload["completionStatus"]
        write_json(receipt, payload)
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
        )
        if result["status"] != "fail" or result["reason"] != "completion_status_missing":
            raise SystemExit(f"self_test_completion_missing_failed: {result}")
        write_json(receipt, receipt_payload(root, completion, recovery_plan, recovery_markdown, recovery_script))
        completion_markdown.write_text("# completion status\nchanged\n", encoding="utf-8")
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
        )
        if result["status"] != "fail" or result["reason"] != "completion_status_markdown_sha256_mismatch":
            raise SystemExit(f"self_test_completion_markdown_sha_failed: {result}")
        restore_completion_markdown()
        write_json(receipt, receipt_payload(root, completion, recovery_plan, recovery_markdown, recovery_script))
        completion_markdown.write_text("# forged completion status\n", encoding="utf-8")
        payload = read_json(receipt)
        payload["completionStatus"]["markdownSha256"] = file_sha256(completion_markdown)
        write_json(receipt, payload)
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
        )
        if result["status"] != "fail" or result["reason"] != "completion_status_markdown_mismatch":
            raise SystemExit(f"self_test_completion_markdown_semantic_failed: {result}")
        restore_completion_markdown()
        payload = read_json(receipt)
        payload["completionStatus"] = completion_status_summary(root, completion)
        payload["completionStatus"]["summary"]["localMissingCount"] = 1
        write_json(receipt, payload)
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
        )
        if result["status"] != "fail" or result["reason"] != "completion_status_binding_mismatch":
            raise SystemExit(f"self_test_completion_binding_failed: {result}")
        payload = read_json(receipt)
        payload["completionStatus"] = completion_status_summary(root, completion)
        payload["completionStatus"]["summary"]["localPassed"] = "36"
        write_json(receipt, payload)
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
        )
        if result["status"] != "fail" or result["reason"] != "completion_status_binding_invalid":
            raise SystemExit(f"self_test_completion_binding_count_type_failed: {result}")
        completion_payload = read_json(completion)
        completion_payload["summary"]["localPassed"] = "36"
        write_json(completion, completion_payload)
        try:
            receipt_payload(root, completion)
        except ValueError as error:
            if "completionStatus.summary.localPassed" not in str(error):
                raise SystemExit(f"self_test_completion_source_count_type_wrong_error: {error}")
        else:
            raise SystemExit("self_test_completion_source_count_type_failed")
        completion_payload["summary"]["localPassed"] = 36
        write_json(completion, completion_payload)
        restore_completion_markdown()
        payload = read_json(receipt)
        payload["completionStatus"] = completion_status_summary(root, completion)
        payload["completionStatus"]["repoRoot"] = str(root / "other")
        write_json(receipt, payload)
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
        )
        if result["status"] != "fail" or result["reason"] != "completion_status_repo_root_mismatch":
            raise SystemExit(f"self_test_completion_repo_root_binding_failed: {result}")
        payload = receipt_payload(root, completion)
        payload["generatedAtEpoch"] = int(read_json(completion)["generatedAtEpoch"]) - 1
        write_json(receipt, payload)
        result = verify_receipt(
            receipt,
            max_age_seconds=86400,
            future_skew_seconds=300,
            require_completion_status=True,
        )
        if result["status"] != "fail" or result["reason"] != "completion_status_newer_than_receipt":
            raise SystemExit(f"self_test_completion_newer_than_receipt_failed: {result}")
        completion_payload = read_json(completion)
        completion_payload["generatedAtEpoch"] = int(time.time()) - 90000
        write_json(completion, completion_payload)
        write_json(receipt, receipt_payload(root, completion))
        result = verify_receipt(receipt, max_age_seconds=86400, future_skew_seconds=300, require_completion_status=True)
        if result["status"] != "fail" or result["reason"] != "completion_status_stale":
            raise SystemExit(f"self_test_completion_stale_failed: {result}")
        completion_payload["generatedAtEpoch"] = int(time.time())
        write_json(completion, completion_payload)
        completion_payload = read_json(completion)
        completion_payload["kind"] = "wrong"
        write_json(completion, completion_payload)
        write_json(receipt, receipt_payload(root, completion))
        result = verify_receipt(receipt, max_age_seconds=86400, future_skew_seconds=300, require_completion_status=True)
        if result["status"] != "fail" or result["reason"] != "completion_status_kind_mismatch":
            raise SystemExit(f"self_test_completion_kind_failed: {result}")
        completion_payload["kind"] = EXPECTED_COMPLETION_STATUS_KIND
        completion_payload["weights"] = {"localEngineering": 99, "liveProductionEvidence": 1}
        write_json(completion, completion_payload)
        write_json(receipt, receipt_payload(root, completion))
        result = verify_receipt(receipt, max_age_seconds=86400, future_skew_seconds=300, require_completion_status=True)
        if result["status"] != "fail" or result["reason"] != "completion_status_weights_mismatch":
            raise SystemExit(f"self_test_completion_weights_failed: {result}")
        completion_payload["weights"] = {
            "localEngineering": EXPECTED_LOCAL_ENGINEERING_WEIGHT,
            "liveProductionEvidence": EXPECTED_LIVE_PRODUCTION_EVIDENCE_WEIGHT,
        }
        write_json(completion, completion_payload)
        write_json(receipt, receipt_payload(root, completion))
        payload = read_json(receipt)
        payload["generatedAtEpoch"] = int(time.time()) - 90000
        write_json(receipt, payload)
        result = verify_receipt(receipt, max_age_seconds=86400, future_skew_seconds=300)
        if result["status"] != "fail" or result["reason"] != "stale":
            raise SystemExit(f"self_test_stale_failed: {result}")
        payload["kind"] = "wrong"
        payload["generatedAtEpoch"] = int(time.time())
        write_json(receipt, payload)
        result = verify_receipt(receipt, max_age_seconds=86400, future_skew_seconds=300)
        if result["status"] != "fail" or result["reason"] != "kind_mismatch":
            raise SystemExit(f"self_test_kind_failed: {result}")
    print("production_static_gate_receipt_self_test result=pass")


def main() -> int:
    parser = argparse.ArgumentParser(description="Write or verify the local production static gate receipt.")
    parser.add_argument("--repo-root", default=str(Path(__file__).resolve().parents[2]))
    parser.add_argument("--receipt-json", default=DEFAULT_RECEIPT_JSON)
    parser.add_argument("--completion-status-json", default="")
    parser.add_argument("--completion-status-markdown", default="")
    parser.add_argument("--recovery-plan-json", default="")
    parser.add_argument("--recovery-plan-markdown", default="")
    parser.add_argument("--recovery-plan-script", default="")
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--require-completion-status", action="store_true")
    parser.add_argument("--require-recovery-plan", action="store_true")
    parser.add_argument("--expect-repo-root", default="")
    parser.add_argument("--require-current-git", action="store_true")
    parser.add_argument("--require-clean-git", action="store_true")
    parser.add_argument("--support-root", action="append", default=[])
    parser.add_argument("--prefer-support-root", action="store_true")
    parser.add_argument("--require-support-root", action="store_true")
    parser.add_argument("--max-age-seconds", type=int, default=int(os.environ.get("PRODUCTION_STATIC_GATE_MAX_AGE_SECONDS", "86400")))
    parser.add_argument("--future-skew-seconds", type=int, default=int(os.environ.get("PRODUCTION_STATIC_GATE_MAX_FUTURE_SKEW_SECONDS", "300")))
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    repo_root = Path(args.repo_root).resolve()
    receipt_path = Path(args.receipt_json).expanduser()
    if not receipt_path.is_absolute():
        receipt_path = repo_root / receipt_path
    if args.verify:
        result = verify_receipt(
            receipt_path,
            args.max_age_seconds,
            args.future_skew_seconds,
            require_completion_status=args.require_completion_status,
            require_recovery_plan=args.require_recovery_plan,
            expect_repo_root=args.expect_repo_root,
            require_current_git=args.require_current_git,
            require_clean_git=args.require_clean_git,
            support_roots=args.support_root,
            prefer_support_roots=args.prefer_support_root,
            require_support_root=args.require_support_root,
        )
        print(cli_result_line("production_static_gate_receipt_verify", result))
        return 0 if result["status"] == "pass" else 1
    completion_status_path = Path(args.completion_status_json).expanduser() if args.completion_status_json else None
    completion_status_markdown_path = Path(args.completion_status_markdown).expanduser() if args.completion_status_markdown else None
    recovery_plan_path = Path(args.recovery_plan_json).expanduser() if args.recovery_plan_json else None
    recovery_plan_markdown_path = Path(args.recovery_plan_markdown).expanduser() if args.recovery_plan_markdown else None
    recovery_plan_script_path = Path(args.recovery_plan_script).expanduser() if args.recovery_plan_script else None
    write_json(
        receipt_path,
        receipt_payload(
            repo_root,
            completion_status_path,
            recovery_plan_path,
            recovery_plan_markdown_path,
            recovery_plan_script_path,
            completion_status_markdown_path,
        ),
    )
    print(f"production_static_gate_receipt result=pass path={receipt_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
