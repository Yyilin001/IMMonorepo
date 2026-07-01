#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import tempfile
import time
from pathlib import Path
from typing import Any

import production_completion_status


REQUIRED_LOCAL_ITEMS = tuple(check.item for check in production_completion_status.LOCAL_CHECKS) + (
    "local-static-gate-receipt",
)
REQUIRED_EVIDENCE_ITEMS = (
    "deploy-readiness",
    "current-readiness",
    "production-acceptance",
    "production-evidence-package",
    "topology-smoke",
    "final-assertion",
    "final-assertion-archive",
)
EXPECTED_LOCAL_ENGINEERING_WEIGHT = 75
EXPECTED_LIVE_PRODUCTION_EVIDENCE_WEIGHT = 25
ALLOWED_CHECK_STATUSES = ("pass", "fail", "missing")


def fail(reason: str, **fields: Any) -> None:
    detail = " ".join(f"{key}={value}" for key, value in fields.items())
    message = f"production_completion_status_verify result=fail reason={reason}"
    if detail:
        message = f"{message} {detail}"
    raise SystemExit(message)


def read_json(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        fail("invalid_json", path=path, error=exc)
    if not isinstance(payload, dict):
        fail("invalid_status_report", path=path)
    return payload


def percent(pass_count: int, total: int) -> int:
    if total <= 0:
        return 0
    return round((pass_count / total) * 100)


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


def require_absolute_repo_root(payload: dict[str, Any], *, expect_repo_root: str = "") -> None:
    raw = str(payload.get("repoRoot") or "").strip()
    if not raw:
        fail("repo_root_missing")
    if not Path(raw).is_absolute():
        fail("repo_root_not_absolute", repoRoot=raw)
    expected = str(Path(expect_repo_root).expanduser().resolve()) if expect_repo_root else ""
    if expected and str(Path(raw).expanduser().resolve()) != expected:
        fail("repo_root_mismatch", expected=expected, actual=raw)


def require_production_target(payload: dict[str, Any], *, all_passed: bool) -> dict[str, str]:
    target = payload.get("productionTarget")
    if not isinstance(target, dict):
        fail("production_target_missing")
    for field in ("baseURL", "tcpHost", "tcpPort"):
        if not isinstance(target.get(field), str):
            fail("production_target_field_invalid", field=field, actual=target.get(field))
    values = {
        "baseURL": target["baseURL"],
        "tcpHost": target["tcpHost"],
        "tcpPort": target["tcpPort"],
    }
    missing_env = target.get("missingEnv")
    if not isinstance(missing_env, list) or not all(isinstance(item, str) for item in missing_env):
        fail("production_target_missing_env_invalid")
    actual_missing = list(missing_env)
    expected_missing = [
        name
        for name, value in (
            ("BASE_URL", values["baseURL"]),
            ("TCP_HOST", values["tcpHost"]),
            ("TCP_PORT", values["tcpPort"]),
        )
        if not value
    ]
    if actual_missing != expected_missing:
        fail(
            "production_target_missing_env_mismatch",
            expected=",".join(expected_missing) or "-",
            actual=",".join(actual_missing) or "-",
        )
    if all_passed and expected_missing:
        fail("production_target_incomplete_for_ready", missingEnv=",".join(expected_missing))
    return values


def require_production_claim(
    payload: dict[str, Any],
    *,
    all_passed: bool,
    local_complete: bool,
    live_complete: bool,
    target_values: dict[str, str],
    evidence_rows: list[dict[str, Any]],
) -> None:
    claim = payload.get("productionClaim")
    if not isinstance(claim, dict):
        fail("production_claim_missing")
    final_assertion = next((row for row in evidence_rows if str(row.get("item") or "") == "final-assertion"), None)
    final_archive = next((row for row in evidence_rows if str(row.get("item") or "") == "final-assertion-archive"), None)
    final_assertion_passed = final_assertion is not None and final_assertion.get("status") == "pass"
    final_archive_passed = final_archive is not None and final_archive.get("status") == "pass"
    final_assertion_claim_verified = bool(((final_assertion or {}).get("productionClaim") or {}).get("valid"))
    final_archive_claim_verified = bool(((final_archive or {}).get("productionClaim") or {}).get("valid"))
    target_complete = all(target_values[field] for field in ("baseURL", "tcpHost", "tcpPort"))
    expected_ready = (
        all_passed
        and target_complete
        and final_assertion_passed
        and final_archive_passed
        and final_assertion_claim_verified
        and final_archive_claim_verified
    )
    expected = {
        "productionReady": expected_ready,
        "claimAllowed": expected_ready,
        "localEngineeringComplete": local_complete,
        "liveEvidenceComplete": live_complete,
        "targetComplete": target_complete,
        "finalAssertionPassed": final_assertion_passed,
        "finalAssertionArchivePassed": final_archive_passed,
        "finalAssertionClaimVerified": final_assertion_claim_verified,
        "finalAssertionArchiveClaimVerified": final_archive_claim_verified,
    }
    for field, expected_value in expected.items():
        if claim.get(field) is not expected_value:
            fail("production_claim_mismatch", field=field, expected=expected_value, actual=claim.get(field))
    expected_level = "production-ready" if expected_ready else "not-production-ready"
    if not isinstance(claim.get("claimLevel"), str):
        fail("production_claim_field_invalid", field="claimLevel", actual=claim.get("claimLevel"))
    if claim.get("claimLevel") != expected_level:
        fail("production_claim_mismatch", field="claimLevel", expected=expected_level, actual=claim.get("claimLevel") or "-")
    expected_basis = "verified-live-production-evidence" if expected_ready else "local-engineering-or-partial-evidence-only"
    if not isinstance(claim.get("basis"), str):
        fail("production_claim_field_invalid", field="basis", actual=claim.get("basis"))
    if claim.get("basis") != expected_basis:
        fail("production_claim_mismatch", field="basis", expected=expected_basis, actual=claim.get("basis") or "-")
    required_evidence = claim.get("requiredEvidence")
    if not isinstance(required_evidence, list) or not all(isinstance(item, str) for item in required_evidence):
        fail("production_claim_required_evidence_invalid")
    if list(required_evidence) != list(REQUIRED_EVIDENCE_ITEMS):
        fail(
            "production_claim_required_evidence_mismatch",
            expected=",".join(REQUIRED_EVIDENCE_ITEMS),
            actual=",".join(required_evidence),
        )
    blockers = claim.get("blockers")
    if not isinstance(blockers, list) or not all(isinstance(item, str) for item in blockers):
        fail("production_claim_blockers_invalid")
    normalized_blockers = list(blockers)
    if expected_ready and normalized_blockers:
        fail("production_claim_ready_with_blockers", blockers=",".join(normalized_blockers))
    if not expected_ready and not normalized_blockers:
        fail("production_claim_incomplete_without_blockers")


def require_readiness_tiers(
    payload: dict[str, Any],
    *,
    ready: bool,
    local_pass: int,
    local_total: int,
    evidence_pass: int,
    evidence_total: int,
    local_percent: int,
    live_percent: int,
    production_percent: int,
) -> None:
    tiers = payload.get("readinessTiers")
    if not isinstance(tiers, dict):
        fail("readiness_tiers_missing")
    claim = payload.get("productionClaim") or {}
    if not isinstance(claim, dict):
        fail("production_claim_missing")
    blockers = [str(item) for item in claim.get("blockers") or []]
    expected = {
        "localEngineering": {
            "status": "complete" if local_pass == local_total else "incomplete",
            "percent": local_percent,
            "passed": local_pass,
            "total": local_total,
            "claim": "local-engineering-complete" if local_pass == local_total else "local-engineering-incomplete",
        },
        "liveProductionEvidence": {
            "status": "complete" if evidence_pass == evidence_total else "incomplete",
            "percent": live_percent,
            "passed": evidence_pass,
            "total": evidence_total,
            "claim": "verified-live-production-evidence" if evidence_pass == evidence_total else "missing-live-production-evidence",
        },
        "productionReady": {
            "status": "ready" if ready else "blocked",
            "percent": production_percent,
            "claimAllowed": ready,
            "targetComplete": bool(claim.get("targetComplete")),
            "blockingReasons": blockers,
            "claim": "production-ready" if ready else "not-production-ready",
        },
    }
    for tier_name, expected_fields in expected.items():
        actual = tiers.get(tier_name)
        if not isinstance(actual, dict):
            fail("readiness_tier_missing", tier=tier_name)
        unexpected_fields = sorted(set(str(item) for item in actual) - set(expected_fields))
        if unexpected_fields:
            fail("readiness_tier_field_unexpected", tier=tier_name, field=unexpected_fields[0])
        for field, expected_value in expected_fields.items():
            actual_value = actual.get(field)
            if field in {"percent", "passed", "total"}:
                try:
                    actual_value = int(actual_value)
                except Exception:
                    fail("readiness_tier_field_invalid", tier=tier_name, field=field, actual=actual.get(field))
            if field == "blockingReasons":
                if not isinstance(actual_value, list):
                    fail("readiness_tier_field_invalid", tier=tier_name, field=field, actual=actual.get(field))
                actual_value = [str(item) for item in actual_value]
            if actual_value != expected_value:
                fail(
                    "readiness_tier_mismatch",
                    tier=tier_name,
                    field=field,
                    expected=",".join(expected_value) if isinstance(expected_value, list) else expected_value,
                    actual=",".join(actual_value) if isinstance(actual_value, list) else actual_value,
                )
    unexpected = sorted(set(str(item) for item in tiers) - set(expected))
    if unexpected:
        fail("readiness_tier_unexpected", tier=unexpected[0])


def require_fresh(payload: dict[str, Any], *, max_age_seconds: int, max_future_skew_seconds: int, path: Path) -> None:
    if max_age_seconds <= 0:
        fail("max_age_invalid", value=max_age_seconds)
    if max_future_skew_seconds < 0:
        fail("max_future_skew_invalid", value=max_future_skew_seconds)
    generated_at = require_int(payload, "generatedAtEpoch")
    now = int(time.time())
    future_skew = generated_at - now
    if future_skew > max_future_skew_seconds:
        fail("generated_at_in_future", skewSeconds=future_skew, maxFutureSkewSeconds=max_future_skew_seconds, path=path)
    age = now - generated_at
    if age > max_age_seconds:
        fail("status_report_stale", ageSeconds=age, maxAgeSeconds=max_age_seconds, path=path)


def check_pass_counts(rows: list[dict[str, Any]], *, field: str) -> tuple[int, int]:
    total = len(rows)
    passed = 0
    for index, item in enumerate(rows):
        status = str(item.get("status") or "")
        if not status:
            fail("row_status_missing", field=field, index=index)
        if status not in ALLOWED_CHECK_STATUSES:
            fail("row_status_invalid", field=field, index=index, status=status)
        if not str(item.get("reason") or "").strip():
            fail("row_reason_missing", field=field, index=index, item=str(item.get("item") or "-"))
        if status == "pass":
            passed += 1
    return passed, total


def require_items(rows: list[dict[str, Any]], *, field: str, required_items: tuple[str, ...]) -> None:
    seen: set[str] = set()
    allowed = set(required_items)
    for index, item in enumerate(rows):
        name = str(item.get("item") or "")
        if not name:
            fail("row_item_missing", field=field, index=index)
        if name in seen:
            fail("row_item_duplicate", field=field, item=name)
        if name not in allowed:
            fail("row_item_unexpected", field=field, item=name)
        seen.add(name)
    missing = [item for item in required_items if item not in seen]
    if missing:
        fail("required_item_missing", field=field, item=missing[0])


def verify_evidence_contracts(rows: list[dict[str, Any]]) -> None:
    expected_contracts = production_completion_status.EVIDENCE_CONTRACTS
    for row in rows:
        item = str(row.get("item") or "")
        expected = expected_contracts.get(item)
        if expected is None:
            continue
        actual = row.get("evidenceContract")
        if not isinstance(actual, dict):
            fail("evidence_contract_missing", item=item)
        actual_required_env = actual.get("requiredEnv")
        if not isinstance(actual_required_env, list) or [str(value) for value in actual_required_env] != list(expected["requiredEnv"]):
            fail(
                "evidence_contract_mismatch",
                item=item,
                field="requiredEnv",
                expected=",".join(expected["requiredEnv"]),
                actual=",".join(str(value) for value in actual_required_env) if isinstance(actual_required_env, list) else "-",
            )
        for field in ("runCommand", "verifyCommand"):
            actual_value = str(actual.get(field) or "")
            expected_value = str(expected[field])
            if actual_value != expected_value:
                fail("evidence_contract_mismatch", item=item, field=field, expected=expected_value, actual=actual_value or "-")


def verify_missing(payload: dict[str, Any], local_rows: list[dict[str, Any]], evidence_rows: list[dict[str, Any]]) -> int:
    missing = require_list(payload, "missing")
    diagnostic_fields = (
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
    expected_missing_reasons = {
        ("local", str(item.get("item") or "")): str(item.get("reason") or "").strip()
        for item in local_rows
        if item.get("status") != "pass"
    } | {
        ("evidence", str(item.get("item") or "")): str(item.get("reason") or "").strip()
        for item in evidence_rows
        if item.get("status") != "pass"
    }
    expected_missing_paths = {
        ("local", str(item.get("item") or "")): str(item.get("path") or "")
        for item in local_rows
        if item.get("status") != "pass"
    } | {
        ("evidence", str(item.get("item") or "")): str(item.get("path") or "")
        for item in evidence_rows
        if item.get("status") != "pass"
    }
    expected_missing_envs = {
        ("evidence", str(item.get("item") or "")): str(item.get("env") or "")
        for item in evidence_rows
        if item.get("status") != "pass"
    }
    expected_missing_diagnostics = {
        (scope, str(row.get("item") or ""), field): row[field]
        for scope, rows in (("local", local_rows), ("evidence", evidence_rows))
        for row in rows
        if row.get("status") != "pass"
        for field in diagnostic_fields
        if field in row
    }
    expected_missing = set(expected_missing_reasons)
    actual_missing: set[tuple[str, str]] = set()
    for index, item in enumerate(missing):
        scope = str(item.get("scope") or "")
        name = str(item.get("item") or "")
        if scope not in {"local", "evidence"}:
            fail("missing_scope_invalid", index=index, scope=scope or "-")
        if not name:
            fail("missing_item_invalid", index=index)
        if not str(item.get("reason") or "").strip():
            fail("missing_reason_missing", scope=scope, item=name)
        key = (scope, name)
        if key in actual_missing:
            fail("missing_item_duplicate", scope=scope, item=name)
        actual_missing.add(key)
        expected_reason = expected_missing_reasons.get(key)
        actual_reason = str(item.get("reason") or "").strip()
        if expected_reason is not None and actual_reason != expected_reason:
            fail("missing_reason_mismatch", scope=scope, item=name, expected=expected_reason, actual=actual_reason)
        expected_path = expected_missing_paths.get(key)
        if expected_path is not None:
            actual_path = str(item.get("path") or "")
            if actual_path != expected_path:
                fail("missing_path_mismatch", scope=scope, item=name, expected=expected_path, actual=actual_path)
        expected_env = expected_missing_envs.get(key)
        if expected_env is not None:
            actual_env = str(item.get("env") or "")
            if actual_env != expected_env:
                fail("missing_env_mismatch", scope=scope, item=name, expected=expected_env, actual=actual_env)
        for field in diagnostic_fields:
            diagnostic_key = (scope, name, field)
            if diagnostic_key not in expected_missing_diagnostics:
                continue
            if field not in item:
                fail("missing_diagnostic_field_missing", scope=scope, item=name, field=field)
            expected_value = expected_missing_diagnostics[diagnostic_key]
            actual_value = item.get(field)
            if actual_value != expected_value:
                fail(
                    "missing_diagnostic_field_mismatch",
                    scope=scope,
                    item=name,
                    field=field,
                    expected=expected_value,
                    actual=actual_value,
                )
    expected_missing_count = len(expected_missing)
    if len(missing) != expected_missing_count:
        fail("missing_count_mismatch", expected=expected_missing_count, actual=len(missing))
    if actual_missing != expected_missing:
        unexpected = sorted(actual_missing - expected_missing)
        omitted = sorted(expected_missing - actual_missing)
        if unexpected:
            fail("missing_item_unexpected", scope=unexpected[0][0], item=unexpected[0][1])
        if omitted:
            fail("missing_item_omitted", scope=omitted[0][0], item=omitted[0][1])
    summary = payload.get("summary") or {}
    if not isinstance(summary, dict):
        fail("field_invalid", field="summary")
    summary_missing = int(summary.get("missingCount", -1))
    if summary_missing != expected_missing_count:
        fail("summary_missing_count_mismatch", expected=expected_missing_count, actual=summary_missing)
    return expected_missing_count


def verify_evidence_recovery_plan(payload: dict[str, Any], evidence_rows: list[dict[str, Any]]) -> int:
    value = payload.get("evidenceRecoveryPlan")
    if not isinstance(value, list):
        fail("field_invalid", field="evidenceRecoveryPlan")
    expected_items = [
        str(row.get("item") or "")
        for row in evidence_rows
        if row.get("status") != "pass"
    ]
    expected_reasons = {
        str(row.get("item") or ""): str(row.get("reason") or "").strip()
        for row in evidence_rows
        if row.get("status") != "pass"
    }
    expected_set = set(expected_items)
    seen: set[str] = set()
    actual_order: list[str] = []
    for index, item in enumerate(value):
        if not isinstance(item, dict):
            fail("evidence_recovery_plan_item_invalid", index=index)
        name = str(item.get("item") or "")
        if not name:
            fail("evidence_recovery_plan_item_missing", index=index)
        if name in seen:
            fail("evidence_recovery_plan_duplicate", item=name)
        if name not in expected_set:
            fail("evidence_recovery_plan_unexpected", item=name)
        seen.add(name)
        actual_order.append(name)
        contract = production_completion_status.EVIDENCE_CONTRACTS.get(name)
        if contract is None:
            fail("evidence_recovery_plan_contract_missing", item=name)
        required_env = item.get("requiredEnv")
        if not isinstance(required_env, list) or [str(value) for value in required_env] != list(contract["requiredEnv"]):
            fail("evidence_recovery_plan_mismatch", item=name, field="requiredEnv")
        for field in ("runCommand", "verifyCommand"):
            if str(item.get(field) or "") != str(contract[field]):
                fail("evidence_recovery_plan_mismatch", item=name, field=field)
        actual_reason = str(item.get("reason") or "").strip()
        if not actual_reason:
            fail("evidence_recovery_plan_reason_missing", item=name)
        expected_reason = expected_reasons.get(name, "")
        if actual_reason != expected_reason:
            fail("evidence_recovery_plan_reason_mismatch", item=name, expected=expected_reason, actual=actual_reason)
    omitted = [item for item in expected_items if item not in seen]
    if omitted:
        fail("evidence_recovery_plan_omitted", item=omitted[0])
    if actual_order != expected_items:
        fail(
            "evidence_recovery_plan_order_mismatch",
            expected=",".join(expected_items),
            actual=",".join(actual_order),
        )
    return len(value)


def verify_next_actions(payload: dict[str, Any], *, missing_count: int, all_passed: bool) -> None:
    value = payload.get("nextActions")
    if not isinstance(value, list):
        fail("field_invalid", field="nextActions")
    actions: list[str] = []
    for index, item in enumerate(value):
        if not isinstance(item, str) or not item.strip():
            fail("next_action_invalid", index=index)
        actions.append(item.strip())
    if len(set(actions)) != len(actions):
        fail("next_action_duplicate")
    if all_passed:
        if actions:
            fail("ready_next_actions_not_empty", count=len(actions))
        return
    if missing_count > 0 and not actions:
        fail("incomplete_next_actions_missing")
    missing = payload.get("missing")
    if isinstance(missing, list):
        has_dirty_static_gate = any(
            isinstance(item, dict)
            and item.get("scope") == "local"
            and item.get("item") == "local-static-gate-receipt"
            and item.get("reason") == "production_static_gate_git_dirty"
            for item in missing
        )
        if has_dirty_static_gate and not any(
            action.startswith("Commit or remove local changes, then rerun make validate-production-static")
            for action in actions
        ):
            fail("dirty_static_gate_next_action_missing")
        has_git_binding_static_gate = any(
            isinstance(item, dict)
            and item.get("scope") == "local"
            and item.get("item") == "local-static-gate-receipt"
            and item.get("reason") == "git_binding_mismatch"
            for item in missing
        )
        if has_git_binding_static_gate and not any(
            action.startswith("Run make production-worktree-plan, run make production-worktree-stage-dry-run-batch and verify-production-worktree-stage-dry-run-batch, then review each commit group, run stageDryRunCommand and stageDryRunReceiptCommand, execute only the source_change stageCommand after review, verify the staged group, clean generated/forbidden artifacts separately, then rerun make validate-production-static")
            for action in actions
        ):
            fail("git_binding_static_gate_next_action_missing")


def verify_markdown_report(payload: dict[str, Any], path: Path) -> None:
    if not path.is_file():
        fail("completion_markdown_missing", path=path)
    expected = production_completion_status.render_markdown(payload)
    actual = path.read_text(encoding="utf-8")
    if actual != expected:
        fail("completion_markdown_mismatch", path=path)


def verify_status_report(path: Path, args: argparse.Namespace) -> dict[str, Any]:
    if not path.is_file():
        fail("status_report_missing", path=path)
    payload = read_json(path)
    if payload.get("kind") != "imserver-production-completion-status":
        fail("kind_mismatch", actual=payload.get("kind") or "-")
    if int(payload.get("schemaVersion") or 0) != 1:
        fail("schema_version_mismatch", actual=payload.get("schemaVersion") or "-")
    require_absolute_repo_root(payload, expect_repo_root=args.expect_repo_root)
    require_fresh(payload, max_age_seconds=args.max_age_seconds, max_future_skew_seconds=args.max_future_skew_seconds, path=path)

    local_rows = require_list(payload, "localChecks")
    evidence_rows = require_list(payload, "evidenceChecks")
    require_items(local_rows, field="localChecks", required_items=REQUIRED_LOCAL_ITEMS)
    require_items(evidence_rows, field="evidenceChecks", required_items=REQUIRED_EVIDENCE_ITEMS)
    verify_evidence_contracts(evidence_rows)
    local_pass, local_total = check_pass_counts(local_rows, field="localChecks")
    evidence_pass, evidence_total = check_pass_counts(evidence_rows, field="evidenceChecks")
    all_passed = local_pass == local_total and evidence_pass == evidence_total
    target_values = require_production_target(payload, all_passed=all_passed)
    final_assertion = next((row for row in evidence_rows if str(row.get("item") or "") == "final-assertion"), None)
    final_archive = next((row for row in evidence_rows if str(row.get("item") or "") == "final-assertion-archive"), None)
    final_assertion_passed = final_assertion is not None and final_assertion.get("status") == "pass"
    final_archive_passed = final_archive is not None and final_archive.get("status") == "pass"
    final_assertion_claim_verified = bool(((final_assertion or {}).get("productionClaim") or {}).get("valid"))
    final_archive_claim_verified = bool(((final_archive or {}).get("productionClaim") or {}).get("valid"))
    expected_ready = (
        all_passed
        and all(target_values[field] for field in ("baseURL", "tcpHost", "tcpPort"))
        and final_assertion_passed
        and final_archive_passed
        and final_assertion_claim_verified
        and final_archive_claim_verified
    )
    require_production_claim(
        payload,
        all_passed=all_passed,
        local_complete=local_pass == local_total,
        live_complete=evidence_pass == evidence_total,
        target_values=target_values,
        evidence_rows=evidence_rows,
    )

    summary = payload.get("summary") or {}
    if not isinstance(summary, dict):
        fail("field_invalid", field="summary")
    expected_summary = {
        "localPassed": local_pass,
        "localTotal": local_total,
        "localMissingCount": local_total - local_pass,
        "liveEvidencePassed": evidence_pass,
        "liveEvidenceTotal": evidence_total,
        "liveEvidenceMissingCount": evidence_total - evidence_pass,
    }
    for field, expected in expected_summary.items():
        actual = require_int(summary, field)
        if actual != expected:
            fail("summary_count_mismatch", field=field, expected=expected, actual=actual)

    local_percent = percent(local_pass, local_total)
    live_percent = percent(evidence_pass, evidence_total)
    weights = payload.get("weights") or {}
    if not isinstance(weights, dict):
        fail("field_invalid", field="weights")
    local_weight = require_int(weights, "localEngineering")
    live_weight = require_int(weights, "liveProductionEvidence")
    if (
        local_weight != EXPECTED_LOCAL_ENGINEERING_WEIGHT
        or live_weight != EXPECTED_LIVE_PRODUCTION_EVIDENCE_WEIGHT
    ):
        fail(
            "weights_invalid",
            localEngineering=local_weight,
            liveProductionEvidence=live_weight,
            expectedLocalEngineering=EXPECTED_LOCAL_ENGINEERING_WEIGHT,
            expectedLiveProductionEvidence=EXPECTED_LIVE_PRODUCTION_EVIDENCE_WEIGHT,
        )
    production_percent = round((local_percent * local_weight + live_percent * live_weight) / 100)

    expected_percents = {
        "localCompletionPercent": local_percent,
        "liveEvidenceCompletionPercent": live_percent,
        "productionCompletionPercent": production_percent,
    }
    for field, expected in expected_percents.items():
        actual = require_int(payload, field)
        if actual != expected:
            fail("completion_percent_mismatch", field=field, expected=expected, actual=actual)
    require_readiness_tiers(
        payload,
        ready=expected_ready,
        local_pass=local_pass,
        local_total=local_total,
        evidence_pass=evidence_pass,
        evidence_total=evidence_total,
        local_percent=local_percent,
        live_percent=live_percent,
        production_percent=production_percent,
    )

    report_status = str(payload.get("status") or "")
    missing_count = verify_missing(payload, local_rows, evidence_rows)
    recovery_plan_count = verify_evidence_recovery_plan(payload, evidence_rows)
    summary_recovery_plan_count = int(summary.get("evidenceRecoveryPlanCount", -1))
    if summary_recovery_plan_count != recovery_plan_count:
        fail("summary_count_mismatch", field="evidenceRecoveryPlanCount", expected=recovery_plan_count, actual=summary_recovery_plan_count)
    verify_next_actions(payload, missing_count=missing_count, all_passed=all_passed)
    if all_passed and report_status != "ready":
        fail("ready_status_mismatch", expected="ready", actual=report_status)
    if not all_passed and report_status != "incomplete":
        fail("incomplete_status_mismatch", expected="incomplete", actual=report_status)
    if args.require_local_complete and local_pass != local_total:
        fail("local_incomplete", passed=local_pass, total=local_total)
    if args.require_live_evidence_complete and evidence_pass != evidence_total:
        fail("live_evidence_incomplete", passed=evidence_pass, total=evidence_total)
    if args.require_production_ready and not all_passed:
        fail("production_not_ready", localPassed=local_pass, localTotal=local_total, liveEvidencePassed=evidence_pass, liveEvidenceTotal=evidence_total)
    markdown_report = getattr(args, "markdown_report", None)
    if markdown_report:
        verify_markdown_report(payload, Path(markdown_report).expanduser())
    return payload


def valid_report(*, ready: bool = False) -> dict[str, Any]:
    if ready:
        local_rows = [{"item": item, "status": "pass", "reason": "ok"} for item in REQUIRED_LOCAL_ITEMS]
        evidence_rows = [{"item": item, "status": "pass", "reason": "verified"} for item in REQUIRED_EVIDENCE_ITEMS]
    else:
        local_rows = [{"item": item, "status": "pass", "reason": "ok"} for item in REQUIRED_LOCAL_ITEMS]
        evidence_rows = [{"item": item, "status": "missing", "reason": "missing_env"} for item in REQUIRED_EVIDENCE_ITEMS]
    for row in evidence_rows:
        contract = production_completion_status.EVIDENCE_CONTRACTS[row["item"]]
        row["path"] = f"/tmp/imserver/evidence/{row['item']}.json"
        row["env"] = contract["requiredEnv"][0]
        row["evidenceContract"] = {
            "requiredEnv": list(contract["requiredEnv"]),
            "runCommand": contract["runCommand"],
            "verifyCommand": contract["verifyCommand"],
        }
        if row["item"] in {"final-assertion", "final-assertion-archive"}:
            row["productionClaim"] = {
                "valid": ready,
                "productionReady": ready,
                "claimAllowed": ready,
                "claimLevel": "production-ready" if ready else "",
                "basis": "verified-final-production-evidence" if ready else "",
            }
    local_pass, local_total = check_pass_counts(local_rows, field="localChecks")
    evidence_pass, evidence_total = check_pass_counts(evidence_rows, field="evidenceChecks")
    local_percent = percent(local_pass, local_total)
    live_percent = percent(evidence_pass, evidence_total)
    production_percent = round(
        (
            local_percent * EXPECTED_LOCAL_ENGINEERING_WEIGHT
            + live_percent * EXPECTED_LIVE_PRODUCTION_EVIDENCE_WEIGHT
        )
        / 100
    )
    missing = [
        {
            "scope": "evidence",
            "item": item["item"],
            "reason": "missing_env",
            "path": item.get("path", ""),
            "env": item.get("env", ""),
        }
        for item in evidence_rows
        if item["status"] != "pass"
    ]
    recovery_plan = []
    for item in evidence_rows:
        if item["status"] == "pass":
            continue
        contract = production_completion_status.EVIDENCE_CONTRACTS[item["item"]]
        recovery_plan.append({
            "item": item["item"],
            "reason": item["reason"],
            "requiredEnv": list(contract["requiredEnv"]),
            "runCommand": contract["runCommand"],
            "verifyCommand": contract["verifyCommand"],
        })
    production_claim = {
        "productionReady": ready,
        "claimAllowed": ready,
        "claimLevel": "production-ready" if ready else "not-production-ready",
        "basis": "verified-live-production-evidence" if ready else "local-engineering-or-partial-evidence-only",
        "localEngineeringComplete": True,
        "liveEvidenceComplete": ready,
        "targetComplete": ready,
        "finalAssertionPassed": ready,
        "finalAssertionArchivePassed": ready,
        "finalAssertionClaimVerified": ready,
        "finalAssertionArchiveClaimVerified": ready,
        "requiredEvidence": list(REQUIRED_EVIDENCE_ITEMS),
        "blockers": [] if ready else [
            "live-production-evidence-incomplete",
            "production-target-incomplete",
            "final-assertion-not-passed",
            "final-assertion-archive-not-passed",
            "final-assertion-claim-not-verified",
            "final-assertion-archive-claim-not-verified",
        ],
    }
    return {
        "kind": "imserver-production-completion-status",
        "schemaVersion": 1,
        "generatedAtEpoch": int(time.time()),
        "repoRoot": "/tmp/imserver",
        "productionTarget": {
            "baseURL": "https://chat.myim-prod.com" if ready else "",
            "tcpHost": "tcp.myim-prod.com" if ready else "",
            "tcpPort": "9000" if ready else "",
            "missingEnv": [] if ready else ["BASE_URL", "TCP_HOST", "TCP_PORT"],
        },
        "productionClaim": production_claim,
        "readinessTiers": production_completion_status.readiness_tiers(
            ready=ready,
            claim=production_claim,
            local_pass=local_pass,
            local_total=local_total,
            evidence_pass=evidence_pass,
            evidence_total=evidence_total,
            local_completion=local_percent,
            live_completion=live_percent,
            production_completion=production_percent,
        ),
        "status": "ready" if ready else "incomplete",
        "localCompletionPercent": local_percent,
        "liveEvidenceCompletionPercent": live_percent,
        "productionCompletionPercent": production_percent,
        "weights": {
            "localEngineering": EXPECTED_LOCAL_ENGINEERING_WEIGHT,
            "liveProductionEvidence": EXPECTED_LIVE_PRODUCTION_EVIDENCE_WEIGHT,
        },
        "summary": {
            "localPassed": local_pass,
            "localTotal": local_total,
            "localMissingCount": local_total - local_pass,
            "liveEvidencePassed": evidence_pass,
            "liveEvidenceTotal": evidence_total,
            "liveEvidenceMissingCount": len(missing),
            "missingCount": len(missing),
            "evidenceRecoveryPlanCount": len(recovery_plan),
        },
        "localChecks": local_rows,
        "evidenceChecks": evidence_rows,
        "missing": missing,
        "evidenceRecoveryPlan": recovery_plan,
        "nextActions": [] if ready else ["Restore a real production target and run make run-current-production-readiness."],
    }


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_text(path: Path, value: str) -> None:
    path.write_text(value, encoding="utf-8")


def run_self_test() -> None:
    with tempfile.TemporaryDirectory() as raw:
        tmp = Path(raw)
        incomplete = tmp / "incomplete.json"
        ready = tmp / "ready.json"
        write_json(incomplete, valid_report(ready=False))
        write_json(ready, valid_report(ready=True))
        base = argparse.Namespace(
            max_age_seconds=86400,
            max_future_skew_seconds=300,
            expect_repo_root="",
            require_local_complete=True,
            require_live_evidence_complete=False,
            require_production_ready=False,
            markdown_report=None,
        )
        verify_status_report(incomplete, base)
        incomplete_markdown = tmp / "incomplete.md"
        write_text(incomplete_markdown, production_completion_status.render_markdown(read_json(incomplete)))
        markdown_args = argparse.Namespace(**{**vars(base), "markdown_report": incomplete_markdown})
        verify_status_report(incomplete, markdown_args)
        missing_markdown_args = argparse.Namespace(**{**vars(base), "markdown_report": tmp / "missing.md"})
        try:
            verify_status_report(incomplete, missing_markdown_args)
        except SystemExit as exc:
            if "completion_markdown_missing" not in str(exc):
                raise
        else:
            fail("self_test_missing_markdown_report_passed")
        bad_markdown = tmp / "bad.md"
        write_text(bad_markdown, "# stale report\n")
        bad_markdown_args = argparse.Namespace(**{**vars(base), "markdown_report": bad_markdown})
        try:
            verify_status_report(incomplete, bad_markdown_args)
        except SystemExit as exc:
            if "completion_markdown_mismatch" not in str(exc):
                raise
        else:
            fail("self_test_bad_markdown_report_passed")
        ready_args = argparse.Namespace(**{**vars(base), "require_live_evidence_complete": True, "require_production_ready": True})
        verify_status_report(ready, ready_args)
        expected_repo_args = argparse.Namespace(**{**vars(base), "expect_repo_root": "/tmp/imserver"})
        verify_status_report(incomplete, expected_repo_args)

        mismatched_repo_root = tmp / "mismatched-repo-root.json"
        payload = valid_report(ready=False)
        write_json(mismatched_repo_root, payload)
        mismatched_repo_args = argparse.Namespace(**{**vars(base), "expect_repo_root": str(tmp / "other-repo")})
        try:
            verify_status_report(mismatched_repo_root, mismatched_repo_args)
        except SystemExit as exc:
            if "repo_root_mismatch" not in str(exc):
                raise
        else:
            fail("self_test_mismatched_repo_root_passed")

        missing_production_target = tmp / "missing-production-target.json"
        payload = valid_report(ready=False)
        del payload["productionTarget"]
        write_json(missing_production_target, payload)
        try:
            verify_status_report(missing_production_target, base)
        except SystemExit as exc:
            if "production_target_missing" not in str(exc):
                raise
        else:
            fail("self_test_missing_production_target_passed")

        mismatched_production_target_missing_env = tmp / "mismatched-production-target-missing-env.json"
        payload = valid_report(ready=False)
        payload["productionTarget"]["missingEnv"] = ["BASE_URL"]
        write_json(mismatched_production_target_missing_env, payload)
        try:
            verify_status_report(mismatched_production_target_missing_env, base)
        except SystemExit as exc:
            if "production_target_missing_env_mismatch" not in str(exc):
                raise
        else:
            fail("self_test_mismatched_production_target_missing_env_passed")

        ready_incomplete_production_target = tmp / "ready-incomplete-production-target.json"
        payload = valid_report(ready=True)
        payload["productionTarget"]["tcpHost"] = ""
        payload["productionTarget"]["missingEnv"] = ["TCP_HOST"]
        write_json(ready_incomplete_production_target, payload)
        try:
            verify_status_report(ready_incomplete_production_target, ready_args)
        except SystemExit as exc:
            if "production_target_incomplete_for_ready" not in str(exc):
                raise
        else:
            fail("self_test_ready_incomplete_production_target_passed")

        missing_production_claim = tmp / "missing-production-claim.json"
        payload = valid_report(ready=False)
        del payload["productionClaim"]
        write_json(missing_production_claim, payload)
        try:
            verify_status_report(missing_production_claim, base)
        except SystemExit as exc:
            if "production_claim_missing" not in str(exc):
                raise
        else:
            fail("self_test_missing_production_claim_passed")

        mismatched_production_claim = tmp / "mismatched-production-claim.json"
        payload = valid_report(ready=False)
        payload["productionClaim"]["claimAllowed"] = True
        write_json(mismatched_production_claim, payload)
        try:
            verify_status_report(mismatched_production_claim, base)
        except SystemExit as exc:
            if "production_claim_mismatch" not in str(exc):
                raise
        else:
            fail("self_test_mismatched_production_claim_passed")

        invalid_production_target_type = tmp / "invalid-production-target-type.json"
        payload = valid_report(ready=False)
        payload["productionTarget"]["tcpPort"] = 9000
        write_json(invalid_production_target_type, payload)
        try:
            verify_status_report(invalid_production_target_type, base)
        except SystemExit as exc:
            if "production_target_field_invalid" not in str(exc):
                raise
        else:
            fail("self_test_invalid_production_target_type_passed")

        invalid_production_claim_type = tmp / "invalid-production-claim-type.json"
        payload = valid_report(ready=False)
        payload["productionClaim"]["claimAllowed"] = "false"
        write_json(invalid_production_claim_type, payload)
        try:
            verify_status_report(invalid_production_claim_type, base)
        except SystemExit as exc:
            if "production_claim_mismatch" not in str(exc):
                raise
        else:
            fail("self_test_invalid_production_claim_type_passed")

        invalid_required_evidence_type = tmp / "invalid-required-evidence-type.json"
        payload = valid_report(ready=False)
        payload["productionClaim"]["requiredEvidence"][0] = 123
        write_json(invalid_required_evidence_type, payload)
        try:
            verify_status_report(invalid_required_evidence_type, base)
        except SystemExit as exc:
            if "production_claim_required_evidence_invalid" not in str(exc):
                raise
        else:
            fail("self_test_invalid_required_evidence_type_passed")

        incomplete_production_claim_without_blockers = tmp / "incomplete-production-claim-without-blockers.json"
        payload = valid_report(ready=False)
        payload["productionClaim"]["blockers"] = []
        write_json(incomplete_production_claim_without_blockers, payload)
        try:
            verify_status_report(incomplete_production_claim_without_blockers, base)
        except SystemExit as exc:
            if "production_claim_incomplete_without_blockers" not in str(exc):
                raise
        else:
            fail("self_test_incomplete_production_claim_without_blockers_passed")

        missing_readiness_tiers = tmp / "missing-readiness-tiers.json"
        payload = valid_report(ready=False)
        del payload["readinessTiers"]
        write_json(missing_readiness_tiers, payload)
        try:
            verify_status_report(missing_readiness_tiers, base)
        except SystemExit as exc:
            if "readiness_tiers_missing" not in str(exc):
                raise
        else:
            fail("self_test_missing_readiness_tiers_passed")

        mismatched_readiness_tier = tmp / "mismatched-readiness-tier.json"
        payload = valid_report(ready=False)
        payload["readinessTiers"]["productionReady"]["status"] = "ready"
        write_json(mismatched_readiness_tier, payload)
        try:
            verify_status_report(mismatched_readiness_tier, base)
        except SystemExit as exc:
            if "readiness_tier_mismatch" not in str(exc):
                raise
        else:
            fail("self_test_mismatched_readiness_tier_passed")

        unexpected_readiness_tier_field = tmp / "unexpected-readiness-tier-field.json"
        payload = valid_report(ready=False)
        payload["readinessTiers"]["localEngineering"]["note"] = "do not trust me"
        write_json(unexpected_readiness_tier_field, payload)
        try:
            verify_status_report(unexpected_readiness_tier_field, base)
        except SystemExit as exc:
            if "readiness_tier_field_unexpected" not in str(exc):
                raise
        else:
            fail("self_test_unexpected_readiness_tier_field_passed")

        unexpected_readiness_tier = tmp / "unexpected-readiness-tier.json"
        payload = valid_report(ready=False)
        payload["readinessTiers"]["experimental"] = {"status": "complete"}
        write_json(unexpected_readiness_tier, payload)
        try:
            verify_status_report(unexpected_readiness_tier, base)
        except SystemExit as exc:
            if "readiness_tier_unexpected" not in str(exc):
                raise
        else:
            fail("self_test_unexpected_readiness_tier_passed")

        invalid_completion_percent_type = tmp / "invalid-completion-percent-type.json"
        payload = valid_report(ready=False)
        payload["productionCompletionPercent"] = "75"
        write_json(invalid_completion_percent_type, payload)
        try:
            verify_status_report(invalid_completion_percent_type, base)
        except SystemExit as exc:
            if "field_invalid" not in str(exc) or "productionCompletionPercent" not in str(exc):
                raise
        else:
            fail("self_test_invalid_completion_percent_type_passed")

        invalid_summary_count_type = tmp / "invalid-summary-count-type.json"
        payload = valid_report(ready=False)
        payload["summary"]["localPassed"] = "64"
        write_json(invalid_summary_count_type, payload)
        try:
            verify_status_report(invalid_summary_count_type, base)
        except SystemExit as exc:
            if "field_invalid" not in str(exc) or "localPassed" not in str(exc):
                raise
        else:
            fail("self_test_invalid_summary_count_type_passed")

        invalid_weight_type = tmp / "invalid-weight-type.json"
        payload = valid_report(ready=False)
        payload["weights"]["localEngineering"] = "75"
        write_json(invalid_weight_type, payload)
        try:
            verify_status_report(invalid_weight_type, base)
        except SystemExit as exc:
            if "field_invalid" not in str(exc) or "localEngineering" not in str(exc):
                raise
        else:
            fail("self_test_invalid_weight_type_passed")

        bad_count = tmp / "bad-count.json"
        payload = valid_report(ready=False)
        payload["summary"]["localPassed"] = 0
        write_json(bad_count, payload)
        try:
            verify_status_report(bad_count, base)
        except SystemExit as exc:
            if "summary_count_mismatch" not in str(exc):
                raise
        else:
            fail("self_test_bad_count_passed")

        bad_local_missing_count = tmp / "bad-local-missing-count.json"
        payload = valid_report(ready=False)
        payload["summary"]["localMissingCount"] = 1
        write_json(bad_local_missing_count, payload)
        try:
            verify_status_report(bad_local_missing_count, base)
        except SystemExit as exc:
            if "summary_count_mismatch" not in str(exc) or "localMissingCount" not in str(exc):
                raise
        else:
            fail("self_test_bad_local_missing_count_passed")

        bad_recovery_plan_count = tmp / "bad-recovery-plan-count.json"
        payload = valid_report(ready=False)
        payload["summary"]["evidenceRecoveryPlanCount"] = 0
        write_json(bad_recovery_plan_count, payload)
        try:
            verify_status_report(bad_recovery_plan_count, base)
        except SystemExit as exc:
            if "summary_count_mismatch" not in str(exc) or "evidenceRecoveryPlanCount" not in str(exc):
                raise
        else:
            fail("self_test_bad_recovery_plan_count_passed")

        bad_live_missing_count = tmp / "bad-live-missing-count.json"
        payload = valid_report(ready=False)
        payload["summary"]["liveEvidenceMissingCount"] = 0
        write_json(bad_live_missing_count, payload)
        try:
            verify_status_report(bad_live_missing_count, base)
        except SystemExit as exc:
            if "summary_count_mismatch" not in str(exc) or "liveEvidenceMissingCount" not in str(exc):
                raise
        else:
            fail("self_test_bad_live_evidence_missing_count_passed")

        bad_row_status = tmp / "bad-row-status.json"
        payload = valid_report(ready=False)
        payload["evidenceChecks"][0]["status"] = "unknown"
        payload["summary"]["missingCount"] -= 1
        write_json(bad_row_status, payload)
        try:
            verify_status_report(bad_row_status, base)
        except SystemExit as exc:
            if "row_status_invalid" not in str(exc):
                raise
        else:
            fail("self_test_bad_row_status_passed")

        missing_row_reason = tmp / "missing-row-reason.json"
        payload = valid_report(ready=False)
        del payload["evidenceChecks"][0]["reason"]
        write_json(missing_row_reason, payload)
        try:
            verify_status_report(missing_row_reason, base)
        except SystemExit as exc:
            if "row_reason_missing" not in str(exc):
                raise
        else:
            fail("self_test_missing_row_reason_passed")

        missing_pass_row_reason = tmp / "missing-pass-row-reason.json"
        payload = valid_report(ready=False)
        del payload["localChecks"][0]["reason"]
        write_json(missing_pass_row_reason, payload)
        try:
            verify_status_report(missing_pass_row_reason, base)
        except SystemExit as exc:
            if "row_reason_missing" not in str(exc):
                raise
        else:
            fail("self_test_missing_pass_row_reason_passed")

        missing_entry_reason = tmp / "missing-entry-reason.json"
        payload = valid_report(ready=False)
        del payload["missing"][0]["reason"]
        write_json(missing_entry_reason, payload)
        try:
            verify_status_report(missing_entry_reason, base)
        except SystemExit as exc:
            if "missing_reason_missing" not in str(exc):
                raise
        else:
            fail("self_test_missing_entry_reason_passed")

        mismatched_missing_reason = tmp / "mismatched-missing-reason.json"
        payload = valid_report(ready=False)
        payload["missing"][0]["reason"] = "different_reason"
        write_json(mismatched_missing_reason, payload)
        try:
            verify_status_report(mismatched_missing_reason, base)
        except SystemExit as exc:
            if "missing_reason_mismatch" not in str(exc):
                raise
        else:
            fail("self_test_mismatched_missing_reason_passed")

        mismatched_missing_path = tmp / "mismatched-missing-path.json"
        payload = valid_report(ready=False)
        payload["missing"][0]["path"] = "/tmp/wrong-evidence.json"
        write_json(mismatched_missing_path, payload)
        try:
            verify_status_report(mismatched_missing_path, base)
        except SystemExit as exc:
            if "missing_path_mismatch" not in str(exc):
                raise
        else:
            fail("self_test_mismatched_missing_path_passed")

        mismatched_missing_env = tmp / "mismatched-missing-env.json"
        payload = valid_report(ready=False)
        payload["missing"][0]["env"] = "WRONG_ENV"
        write_json(mismatched_missing_env, payload)
        try:
            verify_status_report(mismatched_missing_env, base)
        except SystemExit as exc:
            if "missing_env_mismatch" not in str(exc):
                raise
        else:
            fail("self_test_mismatched_missing_env_passed")

        bad_evidence_contract = tmp / "bad-evidence-contract.json"
        payload = valid_report(ready=False)
        payload["evidenceChecks"][0]["evidenceContract"]["verifyCommand"] = "echo skipped"
        write_json(bad_evidence_contract, payload)
        try:
            verify_status_report(bad_evidence_contract, base)
        except SystemExit as exc:
            if "evidence_contract_mismatch" not in str(exc):
                raise
        else:
            fail("self_test_bad_evidence_contract_passed")

        bad_recovery_plan = tmp / "bad-recovery-plan.json"
        payload = valid_report(ready=False)
        payload["evidenceRecoveryPlan"][0]["runCommand"] = "echo skipped"
        write_json(bad_recovery_plan, payload)
        try:
            verify_status_report(bad_recovery_plan, base)
        except SystemExit as exc:
            if "evidence_recovery_plan_mismatch" not in str(exc):
                raise
        else:
            fail("self_test_bad_evidence_recovery_plan_passed")

        mismatched_recovery_plan_reason = tmp / "mismatched-recovery-plan-reason.json"
        payload = valid_report(ready=False)
        payload["evidenceRecoveryPlan"][0]["reason"] = "different_reason"
        write_json(mismatched_recovery_plan_reason, payload)
        try:
            verify_status_report(mismatched_recovery_plan_reason, base)
        except SystemExit as exc:
            if "evidence_recovery_plan_reason_mismatch" not in str(exc):
                raise
        else:
            fail("self_test_mismatched_evidence_recovery_plan_reason_passed")

        relative_repo_root = tmp / "relative-repo-root.json"
        payload = valid_report(ready=False)
        payload["repoRoot"] = "relative/repo"
        write_json(relative_repo_root, payload)
        try:
            verify_status_report(relative_repo_root, base)
        except SystemExit as exc:
            if "repo_root_not_absolute" not in str(exc):
                raise
        else:
            fail("self_test_relative_repo_root_passed")

        reordered_recovery_plan = tmp / "reordered-recovery-plan.json"
        payload = valid_report(ready=False)
        payload["evidenceRecoveryPlan"] = list(reversed(payload["evidenceRecoveryPlan"]))
        write_json(reordered_recovery_plan, payload)
        try:
            verify_status_report(reordered_recovery_plan, base)
        except SystemExit as exc:
            if "evidence_recovery_plan_order_mismatch" not in str(exc):
                raise
        else:
            fail("self_test_reordered_evidence_recovery_plan_passed")

        missing_recovery_plan_item = tmp / "missing-recovery-plan-item.json"
        payload = valid_report(ready=False)
        payload["evidenceRecoveryPlan"] = payload["evidenceRecoveryPlan"][1:]
        write_json(missing_recovery_plan_item, payload)
        try:
            verify_status_report(missing_recovery_plan_item, base)
        except SystemExit as exc:
            if "evidence_recovery_plan_omitted" not in str(exc):
                raise
        else:
            fail("self_test_missing_evidence_recovery_plan_item_passed")

        unexpected_local_item = tmp / "unexpected-local-item.json"
        payload = valid_report(ready=False)
        payload["localChecks"].append({"item": "unknown-local-check", "status": "pass"})
        payload["summary"]["localPassed"] += 1
        payload["summary"]["localTotal"] += 1
        write_json(unexpected_local_item, payload)
        try:
            verify_status_report(unexpected_local_item, base)
        except SystemExit as exc:
            if "row_item_unexpected" not in str(exc):
                raise
        else:
            fail("self_test_unexpected_local_item_passed")

        unexpected_evidence_item = tmp / "unexpected-evidence-item.json"
        payload = valid_report(ready=False)
        payload["evidenceChecks"].append({"item": "unknown-evidence-check", "status": "pass"})
        payload["summary"]["liveEvidencePassed"] += 1
        payload["summary"]["liveEvidenceTotal"] += 1
        write_json(unexpected_evidence_item, payload)
        try:
            verify_status_report(unexpected_evidence_item, base)
        except SystemExit as exc:
            if "row_item_unexpected" not in str(exc):
                raise
        else:
            fail("self_test_unexpected_evidence_item_passed")

        bad_missing_item = tmp / "bad-missing-item.json"
        payload = valid_report(ready=False)
        payload["missing"][0]["item"] = "wrong-evidence-item"
        write_json(bad_missing_item, payload)
        try:
            verify_status_report(bad_missing_item, base)
        except SystemExit as exc:
            if "missing_item_unexpected" not in str(exc):
                raise
        else:
            fail("self_test_bad_missing_item_passed")

        diagnostic_local_rows = [{
            "item": "local-static-gate-receipt",
            "status": "fail",
            "reason": "git_binding_mismatch",
            "path": "/tmp/static-receipt.json",
            "field": "dirtyCount",
            "expected": 242,
            "actual": 241,
            "currentDirtyCount": 242,
            "boundDirtyCount": 241,
            "currentTrackedModifiedCount": 68,
            "boundTrackedModifiedCount": 68,
            "currentUntrackedCount": 174,
            "boundUntrackedCount": 173,
        }]
        diagnostic_payload = {
            "summary": {"missingCount": 1},
            "missing": [{
                "scope": "local",
                "item": "local-static-gate-receipt",
                "reason": "git_binding_mismatch",
                "path": "/tmp/static-receipt.json",
                "field": "dirtyCount",
                "expected": 242,
                "actual": 241,
                "currentDirtyCount": 242,
                "boundDirtyCount": 241,
                "currentTrackedModifiedCount": 68,
                "boundTrackedModifiedCount": 68,
                "currentUntrackedCount": 174,
                "boundUntrackedCount": 173,
            }],
        }
        verify_missing(diagnostic_payload, diagnostic_local_rows, [])

        payload = json.loads(json.dumps(diagnostic_payload))
        del payload["missing"][0]["actual"]
        try:
            verify_missing(payload, diagnostic_local_rows, [])
        except SystemExit as exc:
            if "missing_diagnostic_field_missing" not in str(exc):
                raise
        else:
            fail("self_test_missing_diagnostic_field_passed")

        payload = json.loads(json.dumps(diagnostic_payload))
        payload["missing"][0]["actual"] = 240
        try:
            verify_missing(payload, diagnostic_local_rows, [])
        except SystemExit as exc:
            if "missing_diagnostic_field_mismatch" not in str(exc):
                raise
        else:
            fail("self_test_mismatched_diagnostic_field_passed")

        missing_next_actions = tmp / "missing-next-actions.json"
        payload = valid_report(ready=False)
        payload["nextActions"] = []
        write_json(missing_next_actions, payload)
        try:
            verify_status_report(missing_next_actions, base)
        except SystemExit as exc:
            if "incomplete_next_actions_missing" not in str(exc):
                raise
        else:
            fail("self_test_missing_next_actions_passed")

        dirty_static_gate_action = {
            "nextActions": ["Restore a real production target and run make run-current-production-readiness."],
            "missing": [{
                "scope": "local",
                "item": "local-static-gate-receipt",
                "reason": "production_static_gate_git_dirty",
            }],
        }
        try:
            verify_next_actions(dirty_static_gate_action, missing_count=1, all_passed=False)
        except SystemExit as exc:
            if "dirty_static_gate_next_action_missing" not in str(exc):
                raise
        else:
            fail("self_test_dirty_static_gate_next_action_passed")
        dirty_static_gate_action["nextActions"] = [
            "Commit or remove local changes, then rerun make validate-production-static to regenerate a clean production static receipt."
        ]
        verify_next_actions(dirty_static_gate_action, missing_count=1, all_passed=False)

        git_binding_static_gate_action = {
            "nextActions": ["Rerun make validate-production-static to refresh the production static receipt before using it as evidence."],
            "missing": [{
                "scope": "local",
                "item": "local-static-gate-receipt",
                "reason": "git_binding_mismatch",
            }],
        }
        try:
            verify_next_actions(git_binding_static_gate_action, missing_count=1, all_passed=False)
        except SystemExit as exc:
            if "git_binding_static_gate_next_action_missing" not in str(exc):
                raise
        else:
            fail("self_test_git_binding_static_gate_next_action_passed")
        git_binding_static_gate_action["nextActions"] = [
            "Run make production-worktree-plan, run make production-worktree-stage-dry-run-batch and verify-production-worktree-stage-dry-run-batch, then review each commit group, run stageDryRunCommand and stageDryRunReceiptCommand, execute only the source_change stageCommand after review, verify the staged group, clean generated/forbidden artifacts separately, then rerun make validate-production-static."
        ]
        verify_next_actions(git_binding_static_gate_action, missing_count=1, all_passed=False)

        stale = tmp / "stale.json"
        payload = valid_report(ready=False)
        payload["generatedAtEpoch"] = int(time.time()) - 90000
        write_json(stale, payload)
        try:
            verify_status_report(stale, base)
        except SystemExit as exc:
            if "status_report_stale" not in str(exc):
                raise
        else:
            fail("self_test_stale_passed")

        bad_status = tmp / "bad-status.json"
        payload = valid_report(ready=False)
        payload["status"] = "ready"
        write_json(bad_status, payload)
        try:
            verify_status_report(bad_status, base)
        except SystemExit as exc:
            if "incomplete_status_mismatch" not in str(exc):
                raise
        else:
            fail("self_test_bad_status_passed")

        ready_with_next_actions = tmp / "ready-with-next-actions.json"
        payload = valid_report(ready=True)
        payload["nextActions"] = ["Run another production check."]
        write_json(ready_with_next_actions, payload)
        try:
            verify_status_report(ready_with_next_actions, ready_args)
        except SystemExit as exc:
            if "ready_next_actions_not_empty" not in str(exc):
                raise
        else:
            fail("self_test_ready_next_actions_passed")

        missing_required = tmp / "missing-required.json"
        payload = valid_report(ready=False)
        payload["localChecks"] = payload["localChecks"][1:]
        local_pass, local_total = check_pass_counts(payload["localChecks"], field="localChecks")
        evidence_pass, evidence_total = check_pass_counts(payload["evidenceChecks"], field="evidenceChecks")
        payload["summary"]["localPassed"] = local_pass
        payload["summary"]["localTotal"] = local_total
        payload["summary"]["liveEvidencePassed"] = evidence_pass
        payload["summary"]["liveEvidenceTotal"] = evidence_total
        payload["localCompletionPercent"] = percent(local_pass, local_total)
        payload["liveEvidenceCompletionPercent"] = percent(evidence_pass, evidence_total)
        payload["productionCompletionPercent"] = round((payload["localCompletionPercent"] * 75 + payload["liveEvidenceCompletionPercent"] * 25) / 100)
        write_json(missing_required, payload)
        try:
            verify_status_report(missing_required, base)
        except SystemExit as exc:
            if "required_item_missing" not in str(exc):
                raise
        else:
            fail("self_test_missing_required_passed")

        bad_weights = tmp / "bad-weights.json"
        payload = valid_report(ready=False)
        payload["weights"] = {"localEngineering": 99, "liveProductionEvidence": 1}
        payload["productionCompletionPercent"] = round((payload["localCompletionPercent"] * 99 + payload["liveEvidenceCompletionPercent"] * 1) / 100)
        write_json(bad_weights, payload)
        try:
            verify_status_report(bad_weights, base)
        except SystemExit as exc:
            if "weights_invalid" not in str(exc):
                raise
        else:
            fail("self_test_bad_weights_passed")
    print("production_completion_status_verify_self_test result=pass")


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify an IMServer production completion status report.")
    parser.add_argument("--status-json", type=Path, required=False)
    parser.add_argument("--max-age-seconds", type=int, default=86400)
    parser.add_argument("--max-future-skew-seconds", type=int, default=300)
    parser.add_argument("--require-local-complete", action="store_true")
    parser.add_argument("--require-live-evidence-complete", action="store_true")
    parser.add_argument("--require-production-ready", action="store_true")
    parser.add_argument("--expect-repo-root", default="", help="Require the report repoRoot to match this repository root.")
    parser.add_argument("--markdown-report", type=Path, help="Require this operator-readable Markdown report to match the JSON report.")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        run_self_test()
        return 0
    if args.status_json is None:
        parser.error("--status-json is required unless --self-test is set")
    verify_status_report(args.status_json.expanduser(), args)
    print(f"production_completion_status_verify result=pass statusJson={args.status_json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
