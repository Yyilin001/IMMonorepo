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


REQUIRED_CHECKS = {
    "docker_compose_runtime_roles",
    "runtime_services_health",
    "http_health",
    "auth_register_or_login",
    "conversation_create",
    "message_write",
    "summary_projection",
    "changes_projection",
    "messages_since",
    "metrics_secret",
    "outbox_recovery",
}


def fail(reason: str, **fields: Any) -> None:
    detail = " ".join(f"{key}={value}" for key, value in fields.items())
    message = f"production_smoke_verify result=fail reason={reason}"
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


def require_str(payload: dict[str, Any], field: str) -> str:
    value = payload.get(field)
    if not isinstance(value, str) or not value.strip():
        fail("string_field_invalid", field=field, value=value)
    return value


def require_int(payload: dict[str, Any], field: str, *, minimum: int | None = None) -> int:
    value = payload.get(field)
    if not isinstance(value, int):
        fail("int_field_invalid", field=field, value=value)
    if minimum is not None and value < minimum:
        fail("int_field_invalid", field=field, value=value, minimum=minimum)
    return value


def require_bool(payload: dict[str, Any], field: str) -> bool:
    value = payload.get(field)
    if not isinstance(value, bool):
        fail("bool_field_invalid", field=field, value=value)
    return value


def verify_artifacts(payload: dict[str, Any], *, require_artifacts_exist: bool) -> None:
    artifacts = payload.get("artifacts")
    if not isinstance(artifacts, dict):
        fail("artifacts_invalid")
    required = {"markdownReport", "stateFile", "composePs", "composeLog", "outboxInspect"}
    for field in sorted(required):
        value = artifacts.get(field)
        if not isinstance(value, str) or not value.strip():
            fail("artifact_invalid", field=field, value=value)
        if require_artifacts_exist and not Path(value).is_file():
            fail("artifact_missing", field=field, path=value)
    state_file = Path(str(artifacts["stateFile"]))
    if require_artifacts_exist and state_file.is_file():
        state_text = state_file.read_text(encoding="utf-8", errors="replace")
        forbidden = ("OWNER_TOKEN", "ACCESS_TOKEN", "INTERNAL_SECRET", "Authorization:")
        for marker in forbidden:
            if marker in state_text:
                fail("state_artifact_contains_sensitive_marker", marker=marker, path=state_file)


def verify_checks(payload: dict[str, Any]) -> None:
    checks = payload.get("checks")
    if not isinstance(checks, list):
        fail("checks_invalid")
    seen: set[str] = set()
    for index, item in enumerate(checks):
        if not isinstance(item, dict):
            fail("check_invalid", index=index)
        name = item.get("name")
        status = item.get("status")
        if not isinstance(name, str) or not name.strip():
            fail("check_name_invalid", index=index)
        if status != "passed":
            fail("check_status_invalid", name=name, status=status)
        if name in seen:
            fail("check_duplicate", name=name)
        seen.add(name)
    missing = sorted(REQUIRED_CHECKS - seen)
    if missing:
        fail("required_checks_missing", checks=",".join(missing))


def verify_receipt(
    path: Path,
    *,
    require_pass: bool,
    require_artifacts_exist: bool,
    max_age_seconds: int,
    max_future_skew_seconds: int,
) -> dict[str, Any]:
    payload = load_json(path)
    if payload.get("schemaVersion") != 1:
        fail("schema_version_invalid", value=payload.get("schemaVersion"))
    status = payload.get("status")
    if status not in {"passed", "failed"}:
        fail("status_invalid", status=status)
    exit_code = require_int(payload, "exitCode", minimum=0)
    if status == "passed" and exit_code != 0:
        fail("passed_exit_code_invalid", exitCode=exit_code)
    if status == "failed" and exit_code == 0:
        fail("failed_exit_code_invalid")
    if require_pass and status != "passed":
        fail("status_not_passed", status=status)
    if require_pass and not require_bool(payload, "runtimeEvidence"):
        fail("runtime_evidence_missing")

    if require_str(payload, "environment") != "production-smoke":
        fail("environment_invalid", value=payload.get("environment"))
    require_str(payload, "project")
    require_str(payload, "composeFile")

    generated_at = parse_generated_at(payload.get("generatedAt"))
    now = int(time.time())
    future_skew = generated_at - now
    if max_future_skew_seconds >= 0 and future_skew > max_future_skew_seconds:
        fail("receipt_generated_at_in_future", skewSeconds=future_skew, maxFutureSkewSeconds=max_future_skew_seconds)
    age = now - generated_at
    if max_age_seconds > 0 and age > max_age_seconds:
        fail("receipt_stale", ageSeconds=age, maxAgeSeconds=max_age_seconds)

    source = payload.get("source")
    if not isinstance(source, dict):
        fail("source_invalid")
    if not isinstance(source.get("gitCommit"), str):
        fail("source_git_commit_invalid")
    if not isinstance(source.get("gitBranch"), str):
        fail("source_git_branch_invalid")
    if not isinstance(source.get("gitDirty"), bool):
        fail("source_git_dirty_invalid")

    endpoints = payload.get("endpoints")
    if not isinstance(endpoints, dict):
        fail("endpoints_invalid")
    for field in ("gateway", "command", "query"):
        value = endpoints.get(field)
        if not isinstance(value, str) or not value.startswith("http"):
            fail("endpoint_invalid", field=field, value=value)

    conversations = payload.get("conversations")
    if not isinstance(conversations, dict):
        fail("conversations_invalid")
    for field in ("directConversationID", "groupConversationID"):
        value = conversations.get(field)
        if not isinstance(value, str) or not value.strip():
            fail("conversation_id_invalid", field=field, value=value)

    verify_artifacts(payload, require_artifacts_exist=require_artifacts_exist)
    verify_checks(payload)
    return payload


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")


def valid_payload(tmp: Path) -> dict[str, Any]:
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    artifacts = {}
    for name in ("markdownReport", "stateFile", "composePs", "composeLog", "outboxInspect"):
        artifact = tmp / f"{name}.txt"
        artifact.write_text("ok\n", encoding="utf-8")
        artifacts[name] = str(artifact)
    return {
        "schemaVersion": 1,
        "generatedAt": now,
        "status": "passed",
        "exitCode": 0,
        "environment": "production-smoke",
        "project": "imserver-production-smoke",
        "runtimeEvidence": True,
        "composeFile": "docker-compose.production-smoke.yml",
        "endpoints": {
            "gateway": "http://127.0.0.1:8080",
            "command": "http://127.0.0.1:8081",
            "query": "http://127.0.0.1:8082",
        },
        "conversations": {
            "directConversationID": "direct-1",
            "groupConversationID": "group-1",
        },
        "source": {
            "gitCommit": "abc123",
            "gitBranch": "main",
            "gitDirty": False,
        },
        "artifacts": artifacts,
        "checks": [{"name": name, "status": "passed"} for name in sorted(REQUIRED_CHECKS)],
    }


def run_self_test() -> None:
    with tempfile.TemporaryDirectory() as raw_tmp:
        tmp = Path(raw_tmp)
        valid = tmp / "valid.json"
        payload = valid_payload(tmp)
        write_json(valid, payload)
        verify_receipt(
            valid,
            require_pass=True,
            require_artifacts_exist=True,
            max_age_seconds=60,
            max_future_skew_seconds=300,
        )

        missing_check = tmp / "missing-check.json"
        broken = dict(payload)
        broken["checks"] = list(payload["checks"])[:-1]
        write_json(missing_check, broken)
        try:
            verify_receipt(
                missing_check,
                require_pass=True,
                require_artifacts_exist=False,
                max_age_seconds=60,
                max_future_skew_seconds=300,
            )
        except SystemExit as exc:
            if "required_checks_missing" not in str(exc):
                raise
        else:
            fail("self_test_missing_check_passed")

        no_runtime = tmp / "no-runtime.json"
        broken = dict(payload)
        broken["runtimeEvidence"] = False
        write_json(no_runtime, broken)
        try:
            verify_receipt(
                no_runtime,
                require_pass=True,
                require_artifacts_exist=False,
                max_age_seconds=60,
                max_future_skew_seconds=300,
            )
        except SystemExit as exc:
            if "runtime_evidence_missing" not in str(exc):
                raise
        else:
            fail("self_test_missing_runtime_evidence_passed")

        stale = tmp / "stale.json"
        broken = dict(payload)
        broken["generatedAt"] = "2000-01-01T00:00:00Z"
        write_json(stale, broken)
        try:
            verify_receipt(
                stale,
                require_pass=True,
                require_artifacts_exist=False,
                max_age_seconds=60,
                max_future_skew_seconds=300,
            )
        except SystemExit as exc:
            if "receipt_stale" not in str(exc):
                raise
        else:
            fail("self_test_stale_receipt_passed")

        sensitive_state = tmp / "sensitive-state.json"
        broken = dict(payload)
        broken_artifacts = dict(payload["artifacts"])
        bad_state = tmp / "state-with-token.env"
        bad_state.write_text("OWNER_TOKEN=secret\n", encoding="utf-8")
        broken_artifacts["stateFile"] = str(bad_state)
        broken["artifacts"] = broken_artifacts
        write_json(sensitive_state, broken)
        try:
            verify_receipt(
                sensitive_state,
                require_pass=True,
                require_artifacts_exist=True,
                max_age_seconds=60,
                max_future_skew_seconds=300,
            )
        except SystemExit as exc:
            if "state_artifact_contains_sensitive_marker" not in str(exc):
                raise
        else:
            fail("self_test_sensitive_state_passed")

    print("production_smoke_verify_self_test result=pass")


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify IMServer production-smoke JSON receipt.")
    parser.add_argument("--receipt-json", type=Path, default=Path("IMServer/reports/latest-production-smoke.json"))
    parser.add_argument("--require-pass", action="store_true")
    parser.add_argument("--require-artifacts-exist", action="store_true")
    parser.add_argument("--max-age-seconds", type=int, default=0)
    parser.add_argument("--max-future-skew-seconds", type=int, default=300)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        run_self_test()
        return 0

    verify_receipt(
        args.receipt_json,
        require_pass=args.require_pass,
        require_artifacts_exist=args.require_artifacts_exist,
        max_age_seconds=args.max_age_seconds,
        max_future_skew_seconds=args.max_future_skew_seconds,
    )
    print(f"production_smoke_verify result=pass receipt={args.receipt_json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
