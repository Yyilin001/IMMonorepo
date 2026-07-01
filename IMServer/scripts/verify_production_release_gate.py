#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


VALID_STATUSES = {"passed", "failed"}
VALID_STEP_STATUSES = {"passed", "failed", "skipped"}


def fail(reason: str, **fields: Any) -> None:
    detail = " ".join(f"{key}={value}" for key, value in fields.items())
    message = f"production_release_gate_verify result=fail reason={reason}"
    if detail:
        message = f"{message} {detail}"
    raise SystemExit(message)


def load_json(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        fail("invalid_json", path=path, error=exc)
    if not isinstance(payload, dict):
        fail("invalid_receipt", path=path)
    return payload


def parse_generated_at(value: Any) -> int:
    text = str(value or "")
    if not text:
        fail("generated_at_missing")
    try:
        parsed = datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError as exc:
        fail("generated_at_invalid", value=text, error=exc)
    return int(parsed.timestamp())


def require_bool(payload: dict[str, Any], field: str) -> bool:
    value = payload.get(field)
    if not isinstance(value, bool):
        fail("bool_field_invalid", field=field, value=value)
    return value


def require_int(payload: dict[str, Any], field: str, *, minimum: int | None = None) -> int:
    value = payload.get(field)
    if not isinstance(value, int):
        fail("int_field_invalid", field=field, value=value)
    if minimum is not None and value < minimum:
        fail("int_field_invalid", field=field, value=value, minimum=minimum)
    return value


def verify_steps(payload: dict[str, Any]) -> list[dict[str, Any]]:
    raw_steps = payload.get("steps")
    if not isinstance(raw_steps, list):
        fail("steps_invalid")
    steps: list[dict[str, Any]] = []
    seen_indexes: set[int] = set()
    for index, raw_step in enumerate(raw_steps):
        if not isinstance(raw_step, dict):
            fail("step_invalid", index=index)
        step_index = require_int(raw_step, "index", minimum=1)
        if step_index in seen_indexes:
            fail("step_index_duplicate", stepIndex=step_index)
        seen_indexes.add(step_index)
        name = raw_step.get("name")
        if not isinstance(name, str) or not name.strip():
            fail("step_name_invalid", stepIndex=step_index)
        status = raw_step.get("status")
        if status not in VALID_STEP_STATUSES:
            fail("step_status_invalid", stepIndex=step_index, status=status)
        exit_code = require_int(raw_step, "exitCode", minimum=0)
        if status == "failed" and exit_code == 0:
            fail("failed_step_exit_code_invalid", stepIndex=step_index)
        if status in {"passed", "skipped"} and exit_code != 0:
            fail("non_failed_step_exit_code_invalid", stepIndex=step_index, exitCode=exit_code)
        log = raw_step.get("log")
        if not isinstance(log, str):
            fail("step_log_invalid", stepIndex=step_index)
        steps.append(raw_step)
    return steps


def verify_summary(payload: dict[str, Any], steps: list[dict[str, Any]]) -> None:
    summary = payload.get("summary")
    if not isinstance(summary, dict):
        fail("summary_invalid")
    expected = {
        "stepCount": len(steps),
        "passed": sum(1 for step in steps if step.get("status") == "passed"),
        "failed": sum(1 for step in steps if step.get("status") == "failed"),
        "skipped": sum(1 for step in steps if step.get("status") == "skipped"),
    }
    for field, expected_value in expected.items():
        actual = summary.get(field)
        if actual != expected_value:
            fail("summary_mismatch", field=field, expected=expected_value, actual=actual)


def verify_receipt(
    path: Path,
    *,
    require_pass: bool,
    require_release_run: bool,
    require_swift_tests: bool,
    max_age_seconds: int,
    max_future_skew_seconds: int,
) -> dict[str, Any]:
    payload = load_json(path)
    if payload.get("schemaVersion") != 1:
        fail("schema_version_invalid", value=payload.get("schemaVersion"))
    status = payload.get("status")
    if status not in VALID_STATUSES:
        fail("status_invalid", status=status)
    exit_code = require_int(payload, "exitCode", minimum=0)
    if status == "passed" and exit_code != 0:
        fail("passed_exit_code_invalid", exitCode=exit_code)
    if status == "failed" and exit_code == 0:
        fail("failed_exit_code_invalid")

    generated_at = parse_generated_at(payload.get("generatedAt"))
    now = int(time.time())
    future_skew = generated_at - now
    if max_future_skew_seconds >= 0 and future_skew > max_future_skew_seconds:
        fail("receipt_generated_at_in_future", skewSeconds=future_skew, maxFutureSkewSeconds=max_future_skew_seconds)
    age = now - generated_at
    if max_age_seconds > 0 and age > max_age_seconds:
        fail("receipt_stale", ageSeconds=age, maxAgeSeconds=max_age_seconds)

    validate_args_only = require_bool(payload, "validateArgsOnly")
    swift_tests = require_bool(payload, "swiftTests")
    require_bool(payload, "realEnvPreflight")
    require_bool(payload, "realEnvStrictSecrets")
    require_int(payload, "streamConsumerEnvs", minimum=0)

    source = payload.get("source")
    if not isinstance(source, dict):
        fail("source_invalid")
    if not isinstance(source.get("gitCommit"), str):
        fail("source_git_commit_invalid")
    if not isinstance(source.get("gitDirty"), bool):
        fail("source_git_dirty_invalid")

    report_file = payload.get("reportFile")
    if not isinstance(report_file, str):
        fail("report_file_invalid")

    steps = verify_steps(payload)
    verify_summary(payload, steps)

    if require_pass and status != "passed":
        fail("status_not_passed", status=status)
    if require_pass and any(step.get("status") == "failed" for step in steps):
        fail("failed_steps_present")
    if require_release_run:
        if validate_args_only:
            fail("validate_args_only_not_release_run")
        if not steps:
            fail("release_run_steps_missing")
    if require_swift_tests and not swift_tests:
        fail("swift_tests_not_enabled")

    return payload


def write_receipt(path: Path, payload: dict[str, Any]) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")


def run_self_test() -> None:
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    with tempfile.TemporaryDirectory() as raw_tmp:
        tmp = Path(raw_tmp)
        valid = tmp / "valid.json"
        payload = {
            "schemaVersion": 1,
            "generatedAt": now,
            "status": "passed",
            "exitCode": 0,
            "validateArgsOnly": False,
            "swiftTests": True,
            "realEnvPreflight": False,
            "realEnvStrictSecrets": False,
            "streamConsumerEnvs": 0,
            "reportFile": str(tmp / "gate.md"),
            "source": {
                "gitCommit": "abc123",
                "gitBranch": "main",
                "gitDirty": False,
            },
            "summary": {
                "stepCount": 2,
                "passed": 1,
                "failed": 0,
                "skipped": 1,
            },
            "steps": [
                {"index": 1, "name": "build", "log": "build.log", "status": "passed", "exitCode": 0},
                {"index": 2, "name": "tests", "log": "", "status": "skipped", "exitCode": 0},
            ],
        }
        write_receipt(valid, payload)
        verify_receipt(
            valid,
            require_pass=True,
            require_release_run=True,
            require_swift_tests=True,
            max_age_seconds=60,
            max_future_skew_seconds=300,
        )

        bad_summary = tmp / "bad-summary.json"
        bad_payload = dict(payload)
        bad_payload["summary"] = dict(payload["summary"])
        bad_payload["summary"]["stepCount"] = 1
        write_receipt(bad_summary, bad_payload)
        try:
            verify_receipt(
                bad_summary,
                require_pass=True,
                require_release_run=True,
                require_swift_tests=True,
                max_age_seconds=60,
                max_future_skew_seconds=300,
            )
        except SystemExit as exc:
            if "summary_mismatch" not in str(exc):
                raise
        else:
            fail("self_test_bad_summary_passed")

        validate_only = tmp / "validate-only.json"
        validate_payload = dict(payload)
        validate_payload["validateArgsOnly"] = True
        validate_payload["steps"] = []
        validate_payload["summary"] = {"stepCount": 0, "passed": 0, "failed": 0, "skipped": 0}
        write_receipt(validate_only, validate_payload)
        try:
            verify_receipt(
                validate_only,
                require_pass=True,
                require_release_run=True,
                require_swift_tests=False,
                max_age_seconds=60,
                max_future_skew_seconds=300,
            )
        except SystemExit as exc:
            if "validate_args_only_not_release_run" not in str(exc):
                raise
        else:
            fail("self_test_validate_args_only_passed")

        failed = tmp / "failed.json"
        failed_payload = dict(payload)
        failed_payload["status"] = "failed"
        failed_payload["exitCode"] = 1
        failed_payload["summary"] = {"stepCount": 1, "passed": 0, "failed": 1, "skipped": 0}
        failed_payload["steps"] = [
            {"index": 1, "name": "build", "log": "build.log", "status": "failed", "exitCode": 1}
        ]
        write_receipt(failed, failed_payload)
        try:
            verify_receipt(
                failed,
                require_pass=True,
                require_release_run=False,
                require_swift_tests=False,
                max_age_seconds=60,
                max_future_skew_seconds=300,
            )
        except SystemExit as exc:
            if "status_not_passed" not in str(exc):
                raise
        else:
            fail("self_test_failed_receipt_passed")

    print("production_release_gate_verify_self_test result=pass")


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify an IMServer production release gate JSON receipt.")
    parser.add_argument("--receipt-json", type=Path, required=False)
    parser.add_argument("--require-pass", action="store_true")
    parser.add_argument("--require-release-run", action="store_true")
    parser.add_argument("--require-swift-tests", action="store_true")
    parser.add_argument("--max-age-seconds", type=int, default=86400)
    parser.add_argument("--max-future-skew-seconds", type=int, default=300)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        run_self_test()
        return 0
    if args.receipt_json is None:
        parser.error("--receipt-json is required unless --self-test is set")

    payload = verify_receipt(
        args.receipt_json,
        require_pass=args.require_pass,
        require_release_run=args.require_release_run,
        require_swift_tests=args.require_swift_tests,
        max_age_seconds=args.max_age_seconds,
        max_future_skew_seconds=args.max_future_skew_seconds,
    )
    print(
        "production_release_gate_verify result=pass "
        f"status={payload.get('status')} "
        f"steps={(payload.get('summary') or {}).get('stepCount')} "
        f"swiftTests={payload.get('swiftTests')}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
