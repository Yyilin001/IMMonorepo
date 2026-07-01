#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

FAIL_REASON_ONLY = False

REQUIRED_POLICY_TRUE = (
    "requiresPublicProductionTarget",
    "requiresTopologySmokeReceipt",
    "requiresDeployReadinessReceipt",
    "requiresProductionStaticGateReceipt",
    "requiresCurrentProductionReadiness",
    "requiresProductionAcceptanceReceipt",
    "requiresProductionEvidencePackage",
    "requiresFreshTopologySmokeReceipt",
    "requiresFreshDeployReadinessReceipt",
    "requiresFreshProductionStaticGateReceipt",
    "requiresFreshCurrentProductionReadiness",
    "requiresFreshProductionAcceptanceReceipt",
    "requiresMatchingTarget",
)

REQUIRED_ARTIFACTS = (
    "topologySmokeReceipt",
    "deployReadinessReceipt",
    "productionStaticGateReceipt",
    "currentProductionReadinessJSON",
    "productionAcceptanceReceiptJSON",
    "productionEvidencePackage",
)

FINAL_PRODUCTION_CLAIM_LEVEL = "production-ready"
FINAL_PRODUCTION_CLAIM_BASIS = "verified-final-production-evidence"


def final_production_claim() -> dict[str, Any]:
    return {
        "productionReady": True,
        "claimAllowed": True,
        "claimLevel": FINAL_PRODUCTION_CLAIM_LEVEL,
        "basis": FINAL_PRODUCTION_CLAIM_BASIS,
        "targetComplete": True,
        "requiredArtifacts": list(REQUIRED_ARTIFACTS),
        "requiredPolicies": list(REQUIRED_POLICY_TRUE),
        "blockers": [],
    }

DEPLOY_READINESS_VERIFIER_PATH = Path(__file__).resolve().with_name("verify_deploy_readiness_receipt.py")
TOPOLOGY_SMOKE_VERIFIER_PATH = Path(__file__).resolve().parents[1] / "scripts" / "verify_production_smoke.py"
STATIC_GATE_VERIFIER_PATH = Path(__file__).resolve().with_name("production_static_gate_receipt.py")
ACCEPTANCE_VERIFIER_PATH = Path(__file__).resolve().with_name("perf_production_acceptance_verify.py")
TARGET_POLICY_PATH = Path(__file__).resolve().with_name("production_target_policy.py")


def fail(reason: str, detail: str = "") -> None:
    suffix = f" {detail}" if detail else ""
    if FAIL_REASON_ONLY:
        raise SystemExit(f"{reason}{suffix}")
    raise SystemExit(f"production_ready_assertion_verify result=fail reason={reason}{suffix}")


def load_json(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        fail("invalid_json", f"path={path} detail={exc}")
    if not isinstance(payload, dict):
        fail("receipt_not_object", f"path={path}")
    return payload


def load_module(path: Path, name: str) -> Any:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        fail("artifact_verifier_missing", f"path={path}")
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
    except FileNotFoundError:
        fail("artifact_verifier_missing", f"path={path}")
    return module


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


def require_target(receipt: dict[str, Any], args: argparse.Namespace) -> None:
    target = receipt.get("target")
    if not isinstance(target, dict):
        fail("target_missing")
    expected = {
        "baseURL": args.expect_base_url,
        "tcpHost": args.expect_tcp_host,
        "tcpPort": str(args.expect_tcp_port) if args.expect_tcp_port is not None else None,
    }
    for key, expected_value in expected.items():
        actual = str(target.get(key) or "")
        if not actual:
            fail("target_field_missing", f"field={key}")
        if expected_value is not None and actual != str(expected_value):
            fail("target_mismatch", f"field={key} expected={expected_value} actual={actual}")


def require_public_production_target(receipt: dict[str, Any]) -> None:
    target = target_values(receipt)
    module = load_module(TARGET_POLICY_PATH, "production_ready_target_policy")
    try:
        module.validate_public_target(target["baseURL"], target["tcpHost"], target["tcpPort"])
    except Exception as exc:  # noqa: BLE001 - policy module exposes its own exception type.
        reason = str(getattr(exc, "reason", "") or exc)
        detail = str(getattr(exc, "detail", "") or "")
        suffix = f"reason={reason}"
        if detail:
            suffix = f"{suffix} {detail}"
        fail("production_target_policy_invalid", suffix)


def require_fresh(receipt: dict[str, Any], args: argparse.Namespace) -> None:
    generated_epoch = require_json_int(receipt, "generatedAtEpoch", "generated_at_epoch_invalid")
    now = int(time.time())
    if generated_epoch > now + args.max_future_skew_seconds:
        fail("receipt_from_future", f"generatedAtEpoch={generated_epoch} now={now}")
    if args.max_age_seconds >= 0 and now - generated_epoch > args.max_age_seconds:
        fail("receipt_stale", f"ageSeconds={now - generated_epoch} maxAgeSeconds={args.max_age_seconds}")


def require_policy(receipt: dict[str, Any]) -> None:
    policy = receipt.get("policy")
    if not isinstance(policy, dict):
        fail("policy_missing")
    for key in REQUIRED_POLICY_TRUE:
        if policy.get(key) is not True:
            fail("policy_not_enforced", f"field={key}")


def require_final_production_claim(receipt: dict[str, Any]) -> None:
    claim = receipt.get("productionClaim")
    if not isinstance(claim, dict):
        fail("production_claim_missing")
    expected = final_production_claim()
    for key in ("productionReady", "claimAllowed", "targetComplete"):
        if claim.get(key) is not True:
            fail("production_claim_mismatch", f"field={key}")
    for key in ("claimLevel", "basis"):
        actual = str(claim.get(key) or "")
        if actual != expected[key]:
            fail("production_claim_mismatch", f"field={key} expected={expected[key]} actual={actual or '-'}")
    blockers = claim.get("blockers")
    if not isinstance(blockers, list) or blockers:
        fail("production_claim_mismatch", "field=blockers")
    if claim.get("requiredArtifacts") != list(REQUIRED_ARTIFACTS):
        fail("production_claim_required_artifacts_mismatch")
    if claim.get("requiredPolicies") != list(REQUIRED_POLICY_TRUE):
        fail("production_claim_required_policies_mismatch")


def artifact_root_candidates(record: dict[str, Any], key: str, artifact_roots: list[str]) -> list[Path]:
    raw_path = str(record.get("path") or "")
    direct = Path(raw_path).expanduser()
    file_name = str(record.get("fileName") or direct.name)
    candidates: list[Path] = []
    for raw_root in artifact_roots:
        if not raw_root:
            continue
        root = Path(raw_root).expanduser()
        candidates.append(root / file_name)
        candidates.append(root / key / file_name)
        candidates.append(root / key)
    return candidates


def resolve_artifact_path(
    record: dict[str, Any],
    key: str,
    artifact_roots: list[str],
    *,
    prefer_artifact_roots: bool = False,
) -> Path:
    raw_path = str(record.get("path") or "")
    direct = Path(raw_path).expanduser()
    candidates = artifact_root_candidates(record, key, artifact_roots)
    if prefer_artifact_roots:
        for candidate in candidates:
            if candidate.is_file():
                return candidate
    if direct.is_file():
        return direct
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    root_hint = ",".join(str(Path(raw).expanduser()) for raw in artifact_roots if raw) or "-"
    fail("artifact_file_missing", f"field={key} path={direct} artifactRoots={root_hint}")


def target_values(receipt: dict[str, Any]) -> dict[str, str]:
    target = receipt.get("target") or {}
    return {
        "baseURL": str(target.get("baseURL") or ""),
        "tcpHost": str(target.get("tcpHost") or ""),
        "tcpPort": str(target.get("tcpPort") or ""),
    }


def static_gate_target_values(payload: dict[str, Any]) -> dict[str, str]:
    completion = payload.get("completionStatus") or {}
    if not isinstance(completion, dict):
        fail("production_static_gate_receipt_invalid", "reason=completion_status_missing")
    target = completion.get("productionTarget") or {}
    if not isinstance(target, dict):
        fail("production_static_gate_receipt_invalid", "reason=production_target_missing")
    return {
        "baseURL": str(target.get("baseURL") or ""),
        "tcpHost": str(target.get("tcpHost") or ""),
        "tcpPort": str(target.get("tcpPort") or ""),
    }


def require_static_gate_local_only_claim(payload: dict[str, Any]) -> None:
    completion = payload.get("completionStatus") or {}
    if not isinstance(completion, dict):
        fail("production_static_gate_receipt_invalid", "reason=completion_status_missing")
    claim = completion.get("productionClaim") or {}
    if not isinstance(claim, dict):
        fail("production_static_gate_receipt_invalid", "reason=production_claim_missing")
    if claim.get("productionReady") is True or claim.get("claimAllowed") is True:
        fail(
            "production_static_gate_claim_mismatch",
            "reason=static_gate_must_not_claim_production_ready",
        )
    if str(claim.get("claimLevel") or "") != "not-production-ready":
        fail(
            "production_static_gate_claim_mismatch",
            f"reason=claim_level_invalid claimLevel={claim.get('claimLevel') or '-'}",
        )
    if str(claim.get("basis") or "") != "local-engineering-or-partial-evidence-only":
        fail(
            "production_static_gate_claim_mismatch",
            f"reason=basis_invalid basis={claim.get('basis') or '-'}",
        )


def freshness_value(receipt: dict[str, Any], field: str, fallback: int) -> int:
    freshness = receipt.get("freshness") or {}
    if not isinstance(freshness, dict) or field not in freshness:
        return fallback
    return require_json_int(freshness, field, "freshness_field_invalid")


def verify_topology_smoke_artifact(path: Path, receipt: dict[str, Any], args: argparse.Namespace) -> None:
    module = load_module(TOPOLOGY_SMOKE_VERIFIER_PATH, "production_ready_topology_smoke_verifier")
    max_age_seconds = freshness_value(receipt, "topologySmokeMaxAgeSeconds", args.max_age_seconds)
    try:
        module.verify_receipt(
            path,
            require_pass=True,
            require_artifacts_exist=False,
            max_age_seconds=max_age_seconds,
            max_future_skew_seconds=args.max_future_skew_seconds,
        )
    except SystemExit as exc:
        fail("topology_smoke_receipt_invalid", f"path={path} detail={exc}")


def verify_static_gate_artifact(path: Path, receipt: dict[str, Any], args: argparse.Namespace) -> None:
    module = load_module(STATIC_GATE_VERIFIER_PATH, "production_ready_static_gate_verifier")
    max_age_seconds = freshness_value(receipt, "productionStaticGateMaxAgeSeconds", args.max_age_seconds)
    try:
        result = module.verify_receipt(
            path,
            max_age_seconds=max_age_seconds,
            future_skew_seconds=args.max_future_skew_seconds,
            require_completion_status=True,
            require_recovery_plan=True,
            require_current_git=not args.require_static_gate_support_root,
            require_clean_git=True,
            support_roots=[str(path.parent / "support")],
            prefer_support_roots=args.require_static_gate_support_root,
            require_support_root=args.require_static_gate_support_root,
        )
    except SystemExit as exc:
        fail("production_static_gate_receipt_invalid", f"path={path} detail={exc}")
    if not isinstance(result, dict) or result.get("status") != "pass":
        reason = result.get("reason") if isinstance(result, dict) else "invalid_result"
        if reason == "production_static_gate_git_dirty":
            detail_parts = [f"path={path}"]
            for field in ("field", "value"):
                if isinstance(result, dict) and field in result:
                    detail_parts.append(f"{field}={result[field]}")
            fail("production_static_gate_git_dirty", " ".join(detail_parts))
        if reason == "git_binding_mismatch":
            detail_parts = [f"path={path}"]
            for field in ("field", "expected", "actual"):
                if isinstance(result, dict) and field in result:
                    detail_parts.append(f"{field}={result[field]}")
            fail("production_static_gate_git_binding_mismatch", " ".join(detail_parts))
        fail("production_static_gate_receipt_invalid", f"path={path} reason={reason or '-'}")
    payload = load_json(path)
    expected = target_values(receipt)
    actual = static_gate_target_values(payload)
    for field, expected_value in expected.items():
        actual_value = actual[field]
        if actual_value != expected_value:
            fail("production_static_gate_target_mismatch", f"field={field} expected={expected_value or '-'} actual={actual_value or '-'}")
    require_static_gate_local_only_claim(payload)


def verify_current_readiness_artifact(path: Path, receipt: dict[str, Any], args: argparse.Namespace) -> None:
    payload = load_json(path)
    if payload.get("schemaVersion") != 1:
        fail("current_readiness_receipt_invalid", f"path={path} reason=schema_version_invalid")
    if payload.get("status") != "PASS":
        fail("current_readiness_receipt_invalid", f"path={path} reason=status_not_pass status={payload.get('status') or '-'}")
    expected = target_values(receipt)
    target = payload.get("target") or {}
    if not isinstance(target, dict):
        fail("current_readiness_receipt_invalid", f"path={path} reason=target_missing")
    for field, expected_value in expected.items():
        actual = str(target.get(field) or "")
        if actual != expected_value:
            fail("current_readiness_target_mismatch", f"field={field} expected={expected_value or '-'} actual={actual or '-'}")
    generated_at = require_json_int(
        payload,
        "generatedAtEpoch",
        "current_readiness_receipt_invalid",
        f"path={path} reason=generated_at_invalid",
    )
    now = int(time.time())
    if generated_at > now + args.max_future_skew_seconds:
        fail("current_readiness_receipt_invalid", f"path={path} reason=generated_at_in_future")
    max_age_seconds = freshness_value(receipt, "currentReadinessMaxAgeSeconds", args.max_age_seconds)
    if max_age_seconds >= 0 and now - generated_at > max_age_seconds:
        fail("current_readiness_receipt_invalid", f"path={path} reason=stale ageSeconds={now - generated_at}")


def verify_production_acceptance_artifact(
    acceptance_path: Path,
    package_path: Path,
    receipt: dict[str, Any],
    args: argparse.Namespace,
) -> None:
    payload = load_json(acceptance_path)
    if payload.get("schemaVersion") != 1:
        fail("production_acceptance_receipt_invalid", f"path={acceptance_path} reason=schema_version_invalid")
    if payload.get("status") != "PASS":
        fail("production_acceptance_receipt_invalid", f"path={acceptance_path} reason=status_not_pass status={payload.get('status') or '-'}")
    if payload.get("reason") != "accepted":
        fail("production_acceptance_receipt_invalid", f"path={acceptance_path} reason=reason_not_accepted value={payload.get('reason') or '-'}")
    expected = target_values(receipt)
    target = payload.get("target") or {}
    if not isinstance(target, dict):
        fail("production_acceptance_receipt_invalid", f"path={acceptance_path} reason=target_missing")
    for field, expected_value in expected.items():
        actual = str(target.get(field) or "")
        if actual != expected_value:
            fail("production_acceptance_target_mismatch", f"field={field} expected={expected_value or '-'} actual={actual or '-'}")
    generated_at = require_json_int(
        payload,
        "generatedAtEpoch",
        "production_acceptance_receipt_invalid",
        f"path={acceptance_path} reason=generated_at_invalid",
    )
    now = int(time.time())
    if generated_at > now + args.max_future_skew_seconds:
        fail("production_acceptance_receipt_invalid", f"path={acceptance_path} reason=generated_at_in_future")
    max_age_seconds = freshness_value(receipt, "productionAcceptanceMaxAgeSeconds", args.max_age_seconds)
    if max_age_seconds >= 0 and now - generated_at > max_age_seconds:
        fail("production_acceptance_receipt_invalid", f"path={acceptance_path} reason=stale ageSeconds={now - generated_at}")
    artifacts = payload.get("artifacts") or {}
    if not isinstance(artifacts, dict):
        fail("production_acceptance_receipt_invalid", f"path={acceptance_path} reason=artifacts_missing")
    if artifacts.get("packagePresent") is not True:
        fail("production_acceptance_package_binding_invalid", f"path={acceptance_path} reason=package_present_invalid")
    expected_bytes = require_json_int(
        artifacts,
        "packageBytes",
        "production_acceptance_package_binding_invalid",
        f"path={acceptance_path} reason=package_bytes_invalid",
    )
    expected_sha = str(artifacts.get("packageSha256") or "")
    if expected_bytes <= 0:
        fail("production_acceptance_package_binding_invalid", f"path={acceptance_path} reason=package_bytes_missing")
    if len(expected_sha) != 64 or any(ch not in "0123456789abcdef" for ch in expected_sha.lower()):
        fail("production_acceptance_package_binding_invalid", f"path={acceptance_path} reason=package_sha256_invalid")
    actual_bytes, actual_sha = sha256_file(package_path)
    if actual_bytes != expected_bytes:
        fail("production_acceptance_package_binding_invalid", f"expectedBytes={expected_bytes} actualBytes={actual_bytes}")
    if actual_sha != expected_sha.lower():
        fail("production_acceptance_package_binding_invalid", "reason=package_sha256_mismatch")
    module = load_module(ACCEPTANCE_VERIFIER_PATH, "production_ready_acceptance_verifier")
    try:
        module.verify_package_archive(package_path, expected_target=expected)
    except SystemExit as exc:
        fail("production_evidence_package_invalid", f"path={package_path} detail={exc}")


def verify_deploy_readiness_artifact(path: Path, receipt: dict[str, Any], args: argparse.Namespace) -> None:
    module = load_module(DEPLOY_READINESS_VERIFIER_PATH, "production_ready_deploy_readiness_verifier")
    target = target_values(receipt)
    max_age_seconds = freshness_value(receipt, "deployReadinessMaxAgeSeconds", args.max_age_seconds)
    try:
        module.verify_receipt(
            path,
            base_url=target["baseURL"],
            tcp_host=target["tcpHost"],
            tcp_port=target["tcpPort"],
            max_age_seconds=max_age_seconds,
            max_future_skew_seconds=args.max_future_skew_seconds,
        )
    except SystemExit as exc:
        detail = str(exc)
        fail("production_deploy_readiness_receipt_invalid", f"path={path} detail={detail}")


def require_artifacts(receipt: dict[str, Any], args: argparse.Namespace, *, require_exists: bool, artifact_roots: list[str]) -> None:
    artifacts = receipt.get("artifacts")
    if not isinstance(artifacts, dict):
        fail("artifacts_missing")
    resolved_paths: dict[str, Path] = {}
    for key in REQUIRED_ARTIFACTS:
        record = artifacts.get(key)
        if not isinstance(record, dict):
            fail("artifact_record_missing", f"field={key}")
        raw_path = str(record.get("path") or "")
        if not raw_path:
            fail("artifact_path_missing", f"field={key}")
        expected_bytes = require_json_int(record, "bytes", "artifact_bytes_invalid", f"artifact={key}")
        expected_sha = str(record.get("sha256") or "")
        if expected_bytes <= 0:
            fail("artifact_bytes_invalid", f"field={key} value={expected_bytes}")
        if len(expected_sha) != 64 or any(ch not in "0123456789abcdef" for ch in expected_sha.lower()):
            fail("artifact_sha256_invalid", f"field={key}")
        if require_exists:
            path = resolve_artifact_path(
                record,
                key,
                artifact_roots,
                prefer_artifact_roots=args.require_static_gate_support_root,
            )
            resolved_paths[key] = path
            actual_bytes, actual_sha = sha256_file(path)
            if actual_bytes != expected_bytes:
                fail("artifact_bytes_mismatch", f"field={key} expected={expected_bytes} actual={actual_bytes}")
            if actual_sha != expected_sha:
                fail("artifact_sha256_mismatch", f"field={key}")
    if require_exists:
        topology_smoke_path = resolved_paths.get("topologySmokeReceipt")
        if topology_smoke_path is None:
            fail("artifact_file_missing", "field=topologySmokeReceipt")
        verify_topology_smoke_artifact(topology_smoke_path, receipt, args)

        deploy_receipt_path = resolved_paths.get("deployReadinessReceipt")
        if deploy_receipt_path is None:
            fail("artifact_file_missing", "field=deployReadinessReceipt")
        verify_deploy_readiness_artifact(deploy_receipt_path, receipt, args)

        static_gate_path = resolved_paths.get("productionStaticGateReceipt")
        if static_gate_path is None:
            fail("artifact_file_missing", "field=productionStaticGateReceipt")
        verify_static_gate_artifact(static_gate_path, receipt, args)

        current_readiness_path = resolved_paths.get("currentProductionReadinessJSON")
        if current_readiness_path is None:
            fail("artifact_file_missing", "field=currentProductionReadinessJSON")
        verify_current_readiness_artifact(current_readiness_path, receipt, args)

        acceptance_path = resolved_paths.get("productionAcceptanceReceiptJSON")
        if acceptance_path is None:
            fail("artifact_file_missing", "field=productionAcceptanceReceiptJSON")
        package_path = resolved_paths.get("productionEvidencePackage")
        if package_path is None:
            fail("artifact_file_missing", "field=productionEvidencePackage")
        verify_production_acceptance_artifact(acceptance_path, package_path, receipt, args)


def verify_receipt(args: argparse.Namespace) -> None:
    receipt_path = Path(args.receipt_json).expanduser()
    if not receipt_path.is_file():
        fail("receipt_missing", f"path={receipt_path}")
    receipt = load_json(receipt_path)
    if receipt.get("kind") != "imserver-production-ready-assertion":
        fail("kind_mismatch", f"actual={receipt.get('kind') or '-'}")
    schema_version = require_json_int(receipt, "schemaVersion", "schema_version_mismatch")
    if schema_version != 1:
        fail("schema_version_mismatch", f"actual={schema_version}")
    if args.require_pass and receipt.get("status") != "pass":
        fail("status_not_pass", f"actual={receipt.get('status') or '-'}")
    require_target(receipt, args)
    require_public_production_target(receipt)
    require_fresh(receipt, args)
    require_policy(receipt)
    require_final_production_claim(receipt)
    require_artifacts(receipt, args, require_exists=args.require_artifacts_exist, artifact_roots=args.artifact_root or [])
    print(f"production_ready_assertion_verify result=pass receipt={receipt_path}")


def write_artifact(path: Path, text: str) -> dict[str, Any]:
    path.write_text(text, encoding="utf-8")
    size, digest = sha256_file(path)
    return {"path": str(path), "fileName": path.name, "bytes": size, "sha256": digest}


def record_existing_artifact(path: Path) -> dict[str, Any]:
    size, digest = sha256_file(path)
    return {"path": str(path), "fileName": path.name, "bytes": size, "sha256": digest}


def write_json_artifact(path: Path, payload: dict[str, Any]) -> dict[str, Any]:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    size, digest = sha256_file(path)
    return {"path": str(path), "fileName": path.name, "bytes": size, "sha256": digest}


def init_self_test_git_repo(root: Path) -> None:
    subprocess.run(["git", "init", "-q"], cwd=root, check=True)
    subprocess.run(["git", "config", "user.email", "production-ready-assertion-self-test@example.invalid"], cwd=root, check=True)
    subprocess.run(["git", "config", "user.name", "Production Ready Assertion Self Test"], cwd=root, check=True)
    subprocess.run(["git", "commit", "--allow-empty", "-m", "initial self-test state", "-q"], cwd=root, check=True)
    (root / ".git/info/exclude").write_text("*\n", encoding="utf-8")


def write_static_gate_support(static_gate_path: Path) -> None:
    payload = load_json(static_gate_path)
    support_specs = (
        ("completionStatus", "completionStatus", "path"),
        ("completionStatusMarkdown", "completionStatus", "markdownPath"),
        ("recoveryPlan", "recoveryPlan", "path"),
        ("recoveryPlanMarkdown", "recoveryPlan", "markdownPath"),
        ("recoveryPlanScript", "recoveryPlan", "scriptPath"),
    )
    support_root = static_gate_path.parent / "support"
    for support_name, section, field in support_specs:
        section_payload = payload.get(section)
        if not isinstance(section_payload, dict):
            fail("static_gate_support_fixture_missing", f"field={section}")
        source = Path(str(section_payload.get(field) or ""))
        if not source.is_file():
            fail("static_gate_support_fixture_source_missing", f"field={section}.{field} path={source}")
        target_dir = support_root / support_name
        target_dir.mkdir(parents=True, exist_ok=True)
        target = target_dir / source.name
        target.write_bytes(source.read_bytes())
        if support_name == "recoveryPlanScript":
            target.chmod(0o755)


def valid_deploy_readiness_payload() -> dict[str, Any]:
    module = load_module(DEPLOY_READINESS_VERIFIER_PATH, "production_ready_deploy_readiness_fixture")
    return module.valid_payload()


def valid_topology_smoke_payload(root: Path) -> dict[str, Any]:
    module = load_module(TOPOLOGY_SMOKE_VERIFIER_PATH, "production_ready_topology_smoke_fixture")
    return module.valid_payload(root)


def valid_static_gate_payload(root: Path, production_target: dict[str, Any] | None = None) -> dict[str, Any]:
    module = load_module(STATIC_GATE_VERIFIER_PATH, "production_ready_static_gate_fixture")
    import production_completion_status as completion_status_renderer
    import production_evidence_recovery_plan as recovery_plan_renderer

    generated_at = int(time.time())
    completion_status = root / "static-completion-status.json"
    completion_status_markdown = root / "static-completion-status.md"
    recovery_plan = root / "static-evidence-recovery-plan.json"
    recovery_plan_markdown = root / "static-evidence-recovery-plan.md"
    recovery_plan_script = root / "static-evidence-recovery-run.sh"
    recovery_steps = [
        {
            "item": item,
            "reason": "missing_env",
            "requiredEnv": list(contract["requiredEnv"]),
            "runCommand": str(contract["runCommand"]),
            "verifyCommand": str(contract["verifyCommand"]),
        }
        for item, contract in completion_status_renderer.EVIDENCE_CONTRACTS.items()
    ]
    missing_evidence = [
        {
            "scope": "evidence",
            "item": step["item"],
            "reason": step["reason"],
            "path": "",
            "env": step["requiredEnv"][0],
        }
        for step in recovery_steps
    ]
    if production_target is None:
        production_target = {
            "baseURL": "https://chat.myim-prod.com",
            "tcpHost": "tcp.myim-prod.com",
            "tcpPort": "9000",
            "missingEnv": [],
        }
    production_claim = {
        "productionReady": False,
        "claimAllowed": False,
        "claimLevel": "not-production-ready",
        "basis": "local-engineering-or-partial-evidence-only",
        "localEngineeringComplete": True,
        "liveEvidenceComplete": False,
        "targetComplete": not production_target.get("missingEnv"),
        "finalAssertionPassed": False,
        "finalAssertionArchivePassed": False,
        "finalAssertionClaimVerified": False,
        "finalAssertionArchiveClaimVerified": False,
        "requiredEvidence": list(completion_status_renderer.EVIDENCE_CONTRACTS),
        "blockers": [
            blocker
            for blocker in (
                "live-production-evidence-incomplete",
                "production-target-incomplete",
                "final-assertion-not-passed",
                "final-assertion-archive-not-passed",
                "final-assertion-claim-not-verified",
                "final-assertion-archive-claim-not-verified",
            )
            if blocker != "production-target-incomplete" or production_target.get("missingEnv")
        ],
    }
    completion_status_payload = {
        "kind": module.EXPECTED_COMPLETION_STATUS_KIND,
        "schemaVersion": module.EXPECTED_COMPLETION_STATUS_SCHEMA_VERSION,
        "repoRoot": str(root),
        "generatedAtEpoch": generated_at,
        "productionTarget": production_target,
        "productionClaim": production_claim,
        "status": "incomplete",
        "localCompletionPercent": 100,
        "liveEvidenceCompletionPercent": 0,
        "productionCompletionPercent": 75,
        "weights": {
            "localEngineering": module.EXPECTED_LOCAL_ENGINEERING_WEIGHT,
            "liveProductionEvidence": module.EXPECTED_LIVE_PRODUCTION_EVIDENCE_WEIGHT,
        },
        "summary": {
            "localPassed": 64,
            "localTotal": 64,
            "localMissingCount": 0,
            "liveEvidencePassed": 0,
            "liveEvidenceTotal": 7,
            "liveEvidenceMissingCount": 7,
            "missingCount": 7,
            "evidenceRecoveryPlanCount": 7,
        },
        "missing": missing_evidence,
        "evidenceRecoveryPlan": recovery_steps,
        "nextActions": [
            "Restore a real production target and run make run-current-production-readiness."
        ],
    }
    completion_status_payload["readinessTiers"] = completion_status_renderer.readiness_tiers(
        ready=False,
        claim=production_claim,
        local_pass=int(completion_status_payload["summary"]["localPassed"]),
        local_total=int(completion_status_payload["summary"]["localTotal"]),
        evidence_pass=int(completion_status_payload["summary"]["liveEvidencePassed"]),
        evidence_total=int(completion_status_payload["summary"]["liveEvidenceTotal"]),
        local_completion=int(completion_status_payload["localCompletionPercent"]),
        live_completion=int(completion_status_payload["liveEvidenceCompletionPercent"]),
        production_completion=int(completion_status_payload["productionCompletionPercent"]),
    )
    completion_status.write_text(
        json.dumps(
            completion_status_payload,
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    completion_status_markdown.write_text(completion_status_renderer.render_markdown(completion_status_payload), encoding="utf-8")
    recovery_plan_payload = {
        "kind": module.EXPECTED_RECOVERY_PLAN_KIND,
        "schemaVersion": module.EXPECTED_RECOVERY_PLAN_SCHEMA_VERSION,
        "generatedAtEpoch": generated_at,
        "sourceStatus": "incomplete",
        "sourceStatusJson": str(completion_status),
        "sourceStatusGeneratedAtEpoch": generated_at,
        "productionTarget": production_target,
        "productionClaim": production_claim,
        "readinessTiers": completion_status_payload["readinessTiers"],
        "readyToClaimProduction": False,
        "localEngineeringComplete": True,
        "summary": {
            "status": "incomplete",
            "localCompletionPercent": 100,
            "liveEvidenceCompletionPercent": 0,
            "productionCompletionPercent": 75,
            "localPassed": 64,
            "localTotal": 64,
            "liveEvidencePassed": 0,
            "liveEvidenceTotal": 7,
            "missingCount": 7,
            "evidenceRecoveryPlanCount": 7,
        },
        "localMissing": [],
        "evidenceMissing": missing_evidence,
        "steps": recovery_steps,
        "finalVerificationCommands": [
            "make production-completion-status",
            "make verify-production-completion-status",
            "make verify-production-ready-assertion",
            "make verify-production-ready-archive",
        ],
    }
    recovery_plan_payload["operatorEnvironmentTemplate"] = recovery_plan_renderer.operator_environment_template(recovery_plan_payload)
    recovery_plan_payload["oneShotRecoveryCommands"] = recovery_plan_renderer.one_shot_recovery_commands(recovery_plan_payload)
    recovery_plan.write_text(
        json.dumps(recovery_plan_payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    recovery_plan_markdown.write_text(recovery_plan_renderer.render_markdown(recovery_plan_payload), encoding="utf-8")
    recovery_plan_script.write_text(recovery_plan_renderer.render_shell_script(recovery_plan_payload), encoding="utf-8")
    recovery_plan_script.chmod(0o755)
    return module.receipt_payload(
        root,
        completion_status,
        recovery_plan,
        recovery_plan_markdown,
        recovery_plan_script,
        completion_status_markdown,
    )


def valid_current_readiness_payload() -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "status": "PASS",
        "generatedAtEpoch": int(time.time()),
        "target": {
            "baseURL": "https://chat.myim-prod.com",
            "tcpHost": "tcp.myim-prod.com",
            "tcpPort": "9000",
        },
    }


def valid_production_acceptance_payload(package_path: Path) -> dict[str, Any]:
    package_bytes, package_sha = sha256_file(package_path)
    return {
        "schemaVersion": 1,
        "status": "PASS",
        "reason": "accepted",
        "generatedAtEpoch": int(time.time()),
        "level": "baseline",
        "target": {
            "baseURL": "https://chat.myim-prod.com",
            "tcpHost": "tcp.myim-prod.com",
            "tcpPort": "9000",
            "requiredAccountRows": 5000,
        },
        "policy": {
            "requirePackageableEvidence": True,
            "requireCloudSecurityGroup": True,
            "requireCloudSecurityGroupRepairReceipt": True,
            "requirePublicPortPolicy": True,
            "allowTempHTTP8080": False,
        },
        "artifacts": {
            "package": str(package_path),
            "packageFileName": package_path.name,
            "packagePresent": True,
            "packageBytes": package_bytes,
            "packageSha256": package_sha,
        },
    }


def valid_production_evidence_package(path: Path) -> Path:
    module = load_module(ACCEPTANCE_VERIFIER_PATH, "production_ready_acceptance_fixture")
    target = {
        "baseURL": "https://chat.myim-prod.com",
        "tcpHost": "tcp.myim-prod.com",
        "tcpPort": "9000",
    }
    stage = path.parent / f"{path.stem}-stage"
    module.write_minimal_evidence_package(path, stage, target)
    return path


def write_receipt(path: Path, root: Path, *, mutate: str = "") -> Path:
    evidence_package = root / "evidence.tar.gz"
    valid_production_evidence_package(evidence_package)
    static_gate_path = root / "static-gate.json"
    artifacts = {
        "topologySmokeReceipt": write_json_artifact(root / "topology.json", valid_topology_smoke_payload(root)),
        "deployReadinessReceipt": write_json_artifact(root / "deploy.json", valid_deploy_readiness_payload()),
        "productionStaticGateReceipt": write_json_artifact(static_gate_path, valid_static_gate_payload(root)),
        "currentProductionReadinessJSON": write_json_artifact(root / "current.json", valid_current_readiness_payload()),
        "productionEvidencePackage": record_existing_artifact(evidence_package),
    }
    write_static_gate_support(static_gate_path)
    artifacts["productionAcceptanceReceiptJSON"] = write_json_artifact(
        root / "acceptance.json",
        valid_production_acceptance_payload(Path(str(artifacts["productionEvidencePackage"]["path"]))),
    )
    payload: dict[str, Any] = {
        "schemaVersion": 1,
        "kind": "imserver-production-ready-assertion",
        "status": "pass",
        "generatedAtEpoch": int(time.time()),
        "target": {
            "baseURL": "https://chat.myim-prod.com",
            "tcpHost": "tcp.myim-prod.com",
            "tcpPort": "9000",
        },
        "productionClaim": final_production_claim(),
        "policy": {key: True for key in REQUIRED_POLICY_TRUE},
        "artifacts": artifacts,
    }
    if mutate == "bad-target":
        payload["target"]["tcpHost"] = "wrong.myim-prod.com"
    elif mutate == "schema-version-string":
        payload["schemaVersion"] = "1"
    elif mutate == "generated-at-string":
        payload["generatedAtEpoch"] = str(payload["generatedAtEpoch"])
    elif mutate == "bad-hash":
        payload["artifacts"]["productionEvidencePackage"]["sha256"] = "0" * 64
    elif mutate == "artifact-bytes-string":
        payload["artifacts"]["deployReadinessReceipt"]["bytes"] = str(payload["artifacts"]["deployReadinessReceipt"]["bytes"])
    elif mutate == "stale":
        payload["generatedAtEpoch"] = int(time.time()) - 999999
    elif mutate == "future":
        payload["generatedAtEpoch"] = int(time.time()) + 999999
    elif mutate == "weak-policy":
        payload["policy"]["requiresDeployReadinessReceipt"] = False
    elif mutate == "missing-production-claim":
        del payload["productionClaim"]
    elif mutate == "bad-production-claim":
        payload["productionClaim"]["claimAllowed"] = False
    elif mutate == "missing-artifact":
        Path(payload["artifacts"]["topologySmokeReceipt"]["path"]).unlink()
    elif mutate == "bad-deploy-readiness":
        payload["artifacts"]["deployReadinessReceipt"] = write_artifact(root / "deploy.json", "not a deploy readiness receipt\n")
    elif mutate == "bad-topology-smoke":
        payload["artifacts"]["topologySmokeReceipt"] = write_artifact(root / "topology.json", "not a topology smoke receipt\n")
    elif mutate == "bad-static-gate":
        payload["artifacts"]["productionStaticGateReceipt"] = write_artifact(root / "static-gate.json", "not a static gate receipt\n")
    elif mutate == "bad-static-gate-missing-recovery-plan":
        static_gate_payload = valid_static_gate_payload(root)
        del static_gate_payload["recoveryPlan"]
        payload["artifacts"]["productionStaticGateReceipt"] = write_json_artifact(
            root / "static-gate.json",
            static_gate_payload,
        )
    elif mutate == "bad-static-gate-target":
        static_gate_payload = valid_static_gate_payload(
            root,
            production_target={
                "baseURL": "https://chat.myim-prod.com",
                "tcpHost": "other.myim-prod.com",
                "tcpPort": "9000",
                "missingEnv": [],
            },
        )
        static_gate_path = root / "static-gate.json"
        payload["artifacts"]["productionStaticGateReceipt"] = write_json_artifact(
            static_gate_path,
            static_gate_payload,
        )
        write_static_gate_support(static_gate_path)
    elif mutate == "bad-static-gate-claim":
        import production_completion_status as completion_status_renderer
        import production_evidence_recovery_plan as recovery_plan_renderer

        static_gate_module = load_module(STATIC_GATE_VERIFIER_PATH, "production_ready_static_gate_claim_fixture")
        static_gate_payload = valid_static_gate_payload(root)
        bad_claim = {
            **static_gate_payload["completionStatus"]["productionClaim"],
            "productionReady": True,
            "claimAllowed": True,
            "claimLevel": "production-ready",
            "basis": "verified-live-production-evidence",
            "blockers": [],
        }
        completion_path = Path(str(static_gate_payload["completionStatus"]["path"]))
        completion_markdown_path = Path(str(static_gate_payload["completionStatus"]["markdownPath"]))
        completion_payload = load_json(completion_path)
        completion_payload["productionClaim"] = bad_claim
        completion_path.write_text(json.dumps(completion_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        completion_markdown_path.write_text(completion_status_renderer.render_markdown(completion_payload), encoding="utf-8")
        static_gate_payload["completionStatus"] = static_gate_module.completion_status_summary(
            root,
            completion_path,
            completion_markdown_path,
        )
        recovery_plan_path = Path(str(static_gate_payload["recoveryPlan"]["path"]))
        recovery_markdown_path = Path(str(static_gate_payload["recoveryPlan"]["markdownPath"]))
        recovery_script_path = Path(str(static_gate_payload["recoveryPlan"]["scriptPath"]))
        recovery_payload = load_json(recovery_plan_path)
        recovery_payload["productionClaim"] = bad_claim
        recovery_plan_path.write_text(json.dumps(recovery_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        recovery_markdown_path.write_text(recovery_plan_renderer.render_markdown(recovery_payload), encoding="utf-8")
        recovery_script_path.write_text(recovery_plan_renderer.render_shell_script(recovery_payload), encoding="utf-8")
        recovery_script_path.chmod(0o755)
        static_gate_payload["recoveryPlan"] = static_gate_module.recovery_plan_summary(
            root,
            recovery_plan_path,
            recovery_markdown_path,
            recovery_script_path,
        )
        static_gate_path = root / "static-gate.json"
        payload["artifacts"]["productionStaticGateReceipt"] = write_json_artifact(
            static_gate_path,
            static_gate_payload,
        )
        write_static_gate_support(static_gate_path)
    elif mutate == "bad-static-gate-dirty-git":
        static_gate_payload = valid_static_gate_payload(root)
        static_gate_payload["git"] = {
            **(static_gate_payload.get("git") or {}),
            "dirty": True,
            "dirtyCount": 1,
        }
        static_gate_path = root / "static-gate.json"
        payload["artifacts"]["productionStaticGateReceipt"] = write_json_artifact(
            static_gate_path,
            static_gate_payload,
        )
        write_static_gate_support(static_gate_path)
    elif mutate == "bad-current-readiness":
        payload["artifacts"]["currentProductionReadinessJSON"] = write_json_artifact(
            root / "current.json",
            {**valid_current_readiness_payload(), "status": "FAIL"},
        )
    elif mutate == "bad-production-acceptance":
        payload["artifacts"]["productionAcceptanceReceiptJSON"] = write_artifact(root / "acceptance.json", "not an acceptance receipt\n")
    elif mutate == "stale-production-acceptance":
        package_path = Path(str(payload["artifacts"]["productionEvidencePackage"]["path"]))
        bad_payload = valid_production_acceptance_payload(package_path)
        bad_payload["generatedAtEpoch"] = int(time.time()) - 999999
        payload["artifacts"]["productionAcceptanceReceiptJSON"] = write_json_artifact(root / "acceptance.json", bad_payload)
    elif mutate == "bad-production-acceptance-package-binding":
        package_path = Path(str(payload["artifacts"]["productionEvidencePackage"]["path"]))
        bad_payload = valid_production_acceptance_payload(package_path)
        bad_payload["artifacts"]["packageSha256"] = "0" * 64
        payload["artifacts"]["productionAcceptanceReceiptJSON"] = write_json_artifact(root / "acceptance.json", bad_payload)
    elif mutate == "production-acceptance-package-bytes-string":
        package_path = Path(str(payload["artifacts"]["productionEvidencePackage"]["path"]))
        bad_payload = valid_production_acceptance_payload(package_path)
        bad_payload["artifacts"]["packageBytes"] = str(bad_payload["artifacts"]["packageBytes"])
        payload["artifacts"]["productionAcceptanceReceiptJSON"] = write_json_artifact(root / "acceptance.json", bad_payload)
    elif mutate == "bad-production-evidence-package":
        package_path = Path(str(payload["artifacts"]["productionEvidencePackage"]["path"]))
        package_path.write_text("not a production evidence package\n", encoding="utf-8")
        payload["artifacts"]["productionEvidencePackage"] = record_existing_artifact(package_path)
        payload["artifacts"]["productionAcceptanceReceiptJSON"] = write_json_artifact(
            root / "acceptance.json",
            valid_production_acceptance_payload(package_path),
        )
    elif mutate == "bad-public-target":
        payload["target"]["baseURL"] = "https://127.0.0.1"
        payload["target"]["tcpHost"] = "127.0.0.1"
    path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    return path


def run_self_test() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        init_self_test_git_repo(root)
        good = write_receipt(root / "good.json", root)
        base = [
            sys.executable,
            __file__,
            "--receipt-json",
            str(good),
            "--require-pass",
            "--require-artifacts-exist",
            "--expect-base-url",
            "https://chat.myim-prod.com",
            "--expect-tcp-host",
            "tcp.myim-prod.com",
            "--expect-tcp-port",
            "9000",
        ]
        subprocess.run(base, check=True, stdout=subprocess.DEVNULL)
        portable_dir = root / "portable-artifacts"
        portable_dir.mkdir()
        for record in (load_json(good).get("artifacts") or {}).values():
            if not isinstance(record, dict):
                continue
            source = Path(str(record.get("path") or ""))
            file_name = str(record.get("fileName") or source.name)
            if source.is_file() and file_name:
                shutil.copyfile(source, portable_dir / file_name)
                if file_name == "static-gate.json" and (source.parent / "support").is_dir():
                    shutil.copytree(source.parent / "support", portable_dir / "support")
                source.unlink()
        subprocess.run([*base, "--artifact-root", str(portable_dir)], check=True, stdout=subprocess.DEVNULL)
        subprocess.run(
            [*base, "--artifact-root", str(portable_dir), "--require-static-gate-support-root"],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        portable_markdown = next((portable_dir / "support" / "recoveryPlanMarkdown").glob("*"))
        original_markdown = portable_markdown.read_text(encoding="utf-8")
        portable_markdown.write_text("# portable support tampered\n", encoding="utf-8")
        completed = subprocess.run(
            [*base, "--artifact-root", str(portable_dir), "--require-static-gate-support-root"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_verify_self_test result=fail reason=portable_support_tamper_passed")
        if "recovery_plan_markdown_sha256_mismatch" not in completed.stderr and "recovery_plan_markdown_sha256_mismatch" not in completed.stdout:
            raise SystemExit(
                "production_ready_assertion_verify_self_test result=fail "
                "reason=portable_support_tamper_reason_missing"
            )
        portable_markdown.write_text(original_markdown, encoding="utf-8")

        portable_script = next((portable_dir / "support" / "recoveryPlanScript").glob("*"))
        original_script = portable_script.read_text(encoding="utf-8")
        portable_script.write_text("#!/usr/bin/env bash\nset -euo pipefail\n# portable support tampered\n", encoding="utf-8")
        portable_script.chmod(0o755)
        completed = subprocess.run(
            [*base, "--artifact-root", str(portable_dir), "--require-static-gate-support-root"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_verify_self_test result=fail reason=portable_support_script_tamper_passed")
        if "recovery_plan_script_sha256_mismatch" not in completed.stderr and "recovery_plan_script_sha256_mismatch" not in completed.stdout:
            raise SystemExit(
                "production_ready_assertion_verify_self_test result=fail "
                "reason=portable_support_script_tamper_reason_missing"
            )
        portable_script.write_text(original_script, encoding="utf-8")
        portable_script.chmod(0o755)

        bad_public_target_dir = root / "bad-public-target"
        bad_public_target_dir.mkdir()
        bad_public_target_receipt = write_receipt(
            bad_public_target_dir / "receipt.json",
            bad_public_target_dir,
            mutate="bad-public-target",
        )
        bad_public_target_command = [
            sys.executable,
            __file__,
            "--receipt-json",
            str(bad_public_target_receipt),
            "--require-pass",
            "--require-artifacts-exist",
        ]
        completed = subprocess.run(bad_public_target_command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_verify_self_test result=fail reason=bad-public-target_passed")
        if "production_target_policy_invalid" not in completed.stderr and "production_target_policy_invalid" not in completed.stdout:
            raise SystemExit(
                "production_ready_assertion_verify_self_test result=fail "
                "reason=bad-public-target_reason_missing expected=production_target_policy_invalid"
            )

        cases = {
            "bad-target": "target_mismatch",
            "schema-version-string": "schema_version_mismatch",
            "generated-at-string": "generated_at_epoch_invalid",
            "bad-hash": "artifact_sha256_mismatch",
            "artifact-bytes-string": "artifact_bytes_invalid",
            "stale": "receipt_stale",
            "future": "receipt_from_future",
            "weak-policy": "policy_not_enforced",
            "missing-production-claim": "production_claim_missing",
            "bad-production-claim": "production_claim_mismatch",
            "missing-artifact": "artifact_file_missing",
            "bad-topology-smoke": "topology_smoke_receipt_invalid",
            "bad-deploy-readiness": "production_deploy_readiness_receipt_invalid",
            "bad-static-gate": "production_static_gate_receipt_invalid",
            "bad-static-gate-missing-recovery-plan": "recovery_plan_missing",
            "bad-static-gate-target": "production_static_gate_target_mismatch",
            "bad-static-gate-claim": "production_static_gate_claim_mismatch",
            "bad-static-gate-dirty-git": "production_static_gate_git_binding_mismatch",
            "bad-current-readiness": "current_readiness_receipt_invalid",
            "bad-production-acceptance": "invalid_json",
            "stale-production-acceptance": "production_acceptance_receipt_invalid",
            "bad-production-acceptance-package-binding": "production_acceptance_package_binding_invalid",
            "production-acceptance-package-bytes-string": "production_acceptance_package_binding_invalid",
            "bad-production-evidence-package": "production_evidence_package_invalid",
        }
        for mutate, reason in cases.items():
            case_dir = root / mutate
            case_dir.mkdir()
            receipt = write_receipt(case_dir / "receipt.json", case_dir, mutate=mutate)
            command = base.copy()
            command[command.index(str(good))] = str(receipt)
            completed = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if completed.returncode == 0:
                raise SystemExit(f"production_ready_assertion_verify_self_test result=fail reason={mutate}_passed")
            if reason not in completed.stderr and reason not in completed.stdout:
                raise SystemExit(
                    "production_ready_assertion_verify_self_test result=fail "
                    f"reason={mutate}_reason_missing expected={reason}"
                )
        reason_only_dir = root / "reason-only"
        reason_only_dir.mkdir()
        reason_only_receipt = write_receipt(reason_only_dir / "receipt.json", reason_only_dir, mutate="bad-target")
        reason_only_command = base.copy()
        reason_only_command[reason_only_command.index(str(good))] = str(reason_only_receipt)
        reason_only_command.append("--fail-reason-only")
        completed = subprocess.run(reason_only_command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if completed.returncode == 0:
            raise SystemExit("production_ready_assertion_verify_self_test result=fail reason=fail_reason_only_passed")
        reason_only_output = f"{completed.stdout}\n{completed.stderr}".strip()
        if not reason_only_output.startswith("target_mismatch "):
            raise SystemExit("production_ready_assertion_verify_self_test result=fail reason=fail_reason_only_missing_reason")
        if "production_ready_assertion_verify result=fail" in reason_only_output:
            raise SystemExit("production_ready_assertion_verify_self_test result=fail reason=fail_reason_only_prefix_leaked")
    print("production_ready_assertion_verify_self_test result=pass")


def main() -> None:
    parser = argparse.ArgumentParser(description="Verify a final production-ready assertion receipt.")
    parser.add_argument("--receipt-json", required=False)
    parser.add_argument("--expect-base-url")
    parser.add_argument("--expect-tcp-host")
    parser.add_argument("--expect-tcp-port")
    parser.add_argument("--require-pass", action="store_true")
    parser.add_argument("--require-artifacts-exist", action="store_true")
    parser.add_argument(
        "--artifact-root",
        action="append",
        default=[],
        help="Directory containing copied assertion artifact files; may be repeated.",
    )
    parser.add_argument("--max-age-seconds", type=int, default=86400)
    parser.add_argument("--max-future-skew-seconds", type=int, default=300)
    parser.add_argument("--reason-only", "--fail-reason-only", dest="reason_only", action="store_true")
    parser.add_argument("--require-static-gate-support-root", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    global FAIL_REASON_ONLY
    FAIL_REASON_ONLY = args.reason_only

    if args.self_test:
        run_self_test()
        return
    if not args.receipt_json:
        fail("receipt_json_required")
    verify_receipt(args)


if __name__ == "__main__":
    main()
