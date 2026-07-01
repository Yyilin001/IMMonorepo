#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path
from typing import Any


REQUIRED_POLICY_TRUE = (
    "requirePerformanceGate",
    "requireBackup",
    "verifyBackup",
    "requireLatestBackupFreshness",
    "requireRestoreDrillFreshness",
    "requireOffsiteBackupFreshness",
    "requireAuditTimer",
    "requireRestoreDrillTimer",
    "requireTimeSync",
    "requireAlertWebhook",
    "requireCloudSecurityGroup",
    "requireCloudSecurityGroupRepairReceipt",
    "requireNginxConfig",
    "requireTopologySmoke",
    "topologySmokeRequireArtifacts",
)

REQUIRED_PERFORMANCE_POLICY_TRUE = (
    "requireProfileArtifacts",
    "requireProductPlanArtifacts",
    "requireProductCampaignArtifacts",
    "requireProductScenarioSuiteArtifacts",
    "requireProductScenarioSuiteNoLargeGroup",
    "requireValidationInventory",
    "requireCurrentReadinessArtifacts",
    "requireCloudSecurityGroup",
    "requireProductionAcceptance",
)

REQUIRED_PASS_STEPS = (
    "systemd-units",
    "production-env",
    "entrypoint",
    "application-smoke",
    "topology-smoke-receipt",
    "operational-audit",
    "latest-backup-verify",
    "diagnostics-redaction-self-test",
    "performance-gate",
    "performance-evidence",
    "receipt",
)

REQUIRED_ARTIFACT_FIELDS = (
    "latestBackupDir",
    "restoreDrillReceipt",
    "offsiteBackupReceipt",
    "cloudSecurityGroupRulesFile",
    "cloudSecurityGroupRepairReceipt",
    "nginxHTTPConf",
    "nginxLocationsConf",
    "topologySmokeReceipt",
)


def fail(reason: str, **fields: Any) -> None:
    detail = " ".join(f"{key}={value}" for key, value in fields.items())
    message = f"deploy_readiness_receipt_verify result=fail reason={reason}"
    if detail:
        message = f"{message} {detail}"
    raise SystemExit(message)


def read_json(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        fail("invalid_json", path=path, error=exc)
    if not isinstance(payload, dict):
        fail("invalid_receipt", path=path)
    return payload


def require_int(payload: dict[str, Any], field: str) -> int:
    try:
        value = int(payload.get(field))
    except Exception:
        fail("deploy_readiness_generated_at_invalid", value=payload.get(field))
    return value


def verify_timestamp(payload: dict[str, Any], *, max_age_seconds: int, max_future_skew_seconds: int, path: Path) -> None:
    if max_age_seconds <= 0:
        fail("deploy_readiness_max_age_invalid", value=max_age_seconds)
    if max_future_skew_seconds < 0:
        fail("deploy_readiness_max_future_skew_invalid", value=max_future_skew_seconds)
    generated_at = require_int(payload, "generatedAtEpoch")
    now = int(time.time())
    future_skew_seconds = generated_at - now
    if future_skew_seconds > max_future_skew_seconds:
        fail(
            "deploy_readiness_generated_at_in_future",
            skewSeconds=future_skew_seconds,
            maxFutureSkewSeconds=max_future_skew_seconds,
            path=path,
        )
    age_seconds = now - generated_at
    if age_seconds > max_age_seconds:
        fail("deploy_readiness_stale", ageSeconds=age_seconds, maxAgeSeconds=max_age_seconds, path=path)


def verify_target(payload: dict[str, Any], *, base_url: str, tcp_host: str, tcp_port: str, path: Path) -> None:
    target = payload.get("target") or {}
    if not isinstance(target, dict):
        fail("deploy_readiness_target_invalid", path=path)
    expected_target = {
        "publicBaseURL": base_url,
        "performanceGateExpectBaseURL": base_url,
        "performanceGateExpectTCPHost": tcp_host,
        "performanceGateExpectTCPPort": str(tcp_port),
    }
    for field, expected_value in expected_target.items():
        actual_value = str(target.get(field) or "")
        if not actual_value:
            fail("deploy_readiness_target_field_missing", field=field, path=path)
        if actual_value != expected_value:
            fail(
                "deploy_readiness_target_mismatch",
                field=field,
                expected=expected_value or "-",
                actual=actual_value or "-",
                path=path,
            )


def verify_policy(payload: dict[str, Any], path: Path) -> None:
    policy = payload.get("policy") or {}
    if not isinstance(policy, dict):
        fail("deploy_readiness_policy_invalid", path=path)
    for field in REQUIRED_POLICY_TRUE:
        if policy.get(field) is not True:
            fail("deploy_readiness_policy_not_enforced", field=field, value=repr(policy.get(field)), path=path)

    performance_policy = payload.get("performanceEvidencePolicy") or {}
    if not isinstance(performance_policy, dict):
        fail("deploy_readiness_performance_policy_invalid", path=path)
    for field in REQUIRED_PERFORMANCE_POLICY_TRUE:
        if performance_policy.get(field) is not True:
            fail("deploy_readiness_performance_policy_not_enforced", field=field, value=repr(performance_policy.get(field)), path=path)


def verify_steps(payload: dict[str, Any], path: Path) -> None:
    steps = payload.get("steps") or []
    if not isinstance(steps, list):
        fail("deploy_readiness_steps_invalid", path=path)
    step_status = {
        str(step.get("name") or ""): str(step.get("status") or "")
        for step in steps
        if isinstance(step, dict)
    }
    for name in REQUIRED_PASS_STEPS:
        if step_status.get(name) != "pass":
            fail("deploy_readiness_step_not_passed", step=name, status=step_status.get(name) or "-", path=path)


def verify_artifacts(payload: dict[str, Any], path: Path) -> None:
    artifacts = payload.get("artifacts") or {}
    if not isinstance(artifacts, dict):
        fail("deploy_readiness_artifacts_invalid", path=path)
    for field in REQUIRED_ARTIFACT_FIELDS:
        if not str(artifacts.get(field) or ""):
            fail("deploy_readiness_artifact_field_missing", field=field, path=path)


def verify_receipt(
    path: Path,
    *,
    base_url: str,
    tcp_host: str,
    tcp_port: str,
    max_age_seconds: int,
    max_future_skew_seconds: int,
) -> dict[str, Any]:
    payload = read_json(path)
    if payload.get("kind") != "imserver-production-readiness-gate":
        fail("deploy_readiness_kind_mismatch", path=path, actual=payload.get("kind") or "-")
    if payload.get("status") != "pass":
        fail("deploy_readiness_status_mismatch", path=path, actual=payload.get("status") or "-")
    verify_timestamp(payload, max_age_seconds=max_age_seconds, max_future_skew_seconds=max_future_skew_seconds, path=path)
    verify_target(payload, base_url=base_url, tcp_host=tcp_host, tcp_port=str(tcp_port), path=path)
    verify_policy(payload, path)
    verify_steps(payload, path)
    verify_artifacts(payload, path)
    return payload


def valid_payload(*, base_url: str = "https://chat.myim-prod.com", tcp_host: str = "tcp.myim-prod.com", tcp_port: str = "9000") -> dict[str, Any]:
    return {
        "kind": "imserver-production-readiness-gate",
        "status": "pass",
        "generatedAtEpoch": int(time.time()),
        "target": {
            "publicBaseURL": base_url,
            "performanceGateExpectBaseURL": base_url,
            "performanceGateExpectTCPHost": tcp_host,
            "performanceGateExpectTCPPort": str(tcp_port),
        },
        "policy": {field: True for field in REQUIRED_POLICY_TRUE},
        "performanceEvidencePolicy": {field: True for field in REQUIRED_PERFORMANCE_POLICY_TRUE},
        "steps": [{"name": name, "status": "pass"} for name in REQUIRED_PASS_STEPS],
        "artifacts": {field: f"/var/lib/imserver/readiness/{field}" for field in REQUIRED_ARTIFACT_FIELDS},
    }


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")


def run_self_test() -> None:
    import tempfile

    with tempfile.TemporaryDirectory() as raw:
        tmp = Path(raw)
        valid = tmp / "valid.json"
        payload = valid_payload()
        write_json(valid, payload)
        verify_receipt(
            valid,
            base_url="https://chat.myim-prod.com",
            tcp_host="tcp.myim-prod.com",
            tcp_port="9000",
            max_age_seconds=86400,
            max_future_skew_seconds=300,
        )

        bad_target = tmp / "bad-target.json"
        broken = json.loads(json.dumps(payload))
        broken["target"]["performanceGateExpectTCPHost"] = "other.myim-prod.com"
        write_json(bad_target, broken)
        try:
            verify_receipt(
                bad_target,
                base_url="https://chat.myim-prod.com",
                tcp_host="tcp.myim-prod.com",
                tcp_port="9000",
                max_age_seconds=86400,
                max_future_skew_seconds=300,
            )
        except SystemExit as exc:
            if "deploy_readiness_target_mismatch" not in str(exc):
                raise
        else:
            fail("self_test_bad_target_passed")

        weak_policy = tmp / "weak-policy.json"
        broken = json.loads(json.dumps(payload))
        broken["policy"]["requireRestoreDrillFreshness"] = False
        write_json(weak_policy, broken)
        try:
            verify_receipt(
                weak_policy,
                base_url="https://chat.myim-prod.com",
                tcp_host="tcp.myim-prod.com",
                tcp_port="9000",
                max_age_seconds=86400,
                max_future_skew_seconds=300,
            )
        except SystemExit as exc:
            if "deploy_readiness_policy_not_enforced" not in str(exc):
                raise
        else:
            fail("self_test_weak_policy_passed")

        stale = tmp / "stale.json"
        broken = json.loads(json.dumps(payload))
        broken["generatedAtEpoch"] = int(time.time()) - 90000
        write_json(stale, broken)
        try:
            verify_receipt(
                stale,
                base_url="https://chat.myim-prod.com",
                tcp_host="tcp.myim-prod.com",
                tcp_port="9000",
                max_age_seconds=86400,
                max_future_skew_seconds=300,
            )
        except SystemExit as exc:
            if "deploy_readiness_stale" not in str(exc):
                raise
        else:
            fail("self_test_stale_passed")

        missing_step = tmp / "missing-step.json"
        broken = json.loads(json.dumps(payload))
        broken["steps"] = broken["steps"][:-1]
        write_json(missing_step, broken)
        try:
            verify_receipt(
                missing_step,
                base_url="https://chat.myim-prod.com",
                tcp_host="tcp.myim-prod.com",
                tcp_port="9000",
                max_age_seconds=86400,
                max_future_skew_seconds=300,
            )
        except SystemExit as exc:
            if "deploy_readiness_step_not_passed" not in str(exc):
                raise
        else:
            fail("self_test_missing_step_passed")
    print("deploy_readiness_receipt_verify_self_test result=pass")


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify an IMServer deploy-readiness receipt.")
    parser.add_argument("--receipt-json", type=Path, required=False)
    parser.add_argument("--expect-base-url")
    parser.add_argument("--expect-tcp-host")
    parser.add_argument("--expect-tcp-port")
    parser.add_argument("--max-age-seconds", type=int, default=86400)
    parser.add_argument("--max-future-skew-seconds", type=int, default=300)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        run_self_test()
        return 0
    if args.receipt_json is None:
        parser.error("--receipt-json is required unless --self-test is set")
    missing = [
        name
        for name, value in (
            ("--expect-base-url", args.expect_base_url),
            ("--expect-tcp-host", args.expect_tcp_host),
            ("--expect-tcp-port", args.expect_tcp_port),
        )
        if not value
    ]
    if missing:
        fail("expected_target_required", missing=",".join(missing))
    verify_receipt(
        args.receipt_json,
        base_url=str(args.expect_base_url),
        tcp_host=str(args.expect_tcp_host),
        tcp_port=str(args.expect_tcp_port),
        max_age_seconds=args.max_age_seconds,
        max_future_skew_seconds=args.max_future_skew_seconds,
    )
    print(f"deploy_readiness_receipt_verify result=pass receipt={args.receipt_json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
