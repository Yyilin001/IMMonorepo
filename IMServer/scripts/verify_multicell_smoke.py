#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def fail(reason: str, **fields: Any) -> None:
    detail = " ".join(f"{key}={value}" for key, value in fields.items())
    message = f"multicell_smoke_verify result=fail reason={reason}"
    if detail:
        message = f"{message} {detail}"
    raise SystemExit(message)


def require_bool(payload: dict[str, Any], field: str) -> bool:
    value = payload.get(field)
    if not isinstance(value, bool):
        fail("bool_field_invalid", field=field, value=value)
    return value


def require_string(payload: dict[str, Any], field: str) -> str:
    value = payload.get(field)
    if not isinstance(value, str) or not value.strip():
        fail("string_field_invalid", field=field, value=value)
    return value


def load_receipt(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        fail("invalid_json", path=path, error=exc)
    if not isinstance(value, dict):
        fail("invalid_receipt", path=path)
    return value


def parse_timestamp(value: Any) -> int:
    if not isinstance(value, str):
        fail("generated_at_invalid", value=value)
    try:
        return int(datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp())
    except ValueError as exc:
        fail("generated_at_invalid", value=value, error=exc)


def verify(
    path: Path,
    *,
    require_pass: bool,
    require_artifacts_exist: bool,
    require_tcp: bool,
    require_fault_drill: str | None,
    max_age_seconds: int,
) -> None:
    payload = load_receipt(path)
    if payload.get("schemaVersion") != 1:
        fail("schema_version_invalid", value=payload.get("schemaVersion"))
    if payload.get("status") not in {"passed", "failed"}:
        fail("status_invalid", value=payload.get("status"))
    if require_pass and payload.get("status") != "passed":
        fail("status_not_passed", value=payload.get("status"))
    if require_pass and not require_bool(payload, "runtimeEvidence"):
        fail("runtime_evidence_missing")
    if require_string(payload, "environment") != "multicell-smoke":
        fail("environment_invalid", value=payload.get("environment"))
    require_string(payload, "project")
    require_string(payload, "conversationID")
    if not require_bool(payload, "physicalMigration"):
        fail("physical_migration_missing")
    if not require_bool(payload, "targetOutboxRecovered"):
        fail("target_outbox_recovery_missing")

    generated_at = parse_timestamp(payload.get("generatedAt"))
    age_seconds = int(time.time()) - generated_at
    if max_age_seconds > 0 and age_seconds > max_age_seconds:
        fail("receipt_stale", ageSeconds=age_seconds, maxAgeSeconds=max_age_seconds)
    if generated_at - int(time.time()) > 300:
        fail("receipt_generated_at_in_future")

    forward = payload.get("remoteCellForwardSuccesses")
    if not isinstance(forward, dict):
        fail("forward_metrics_invalid")
    for field in ("command", "query"):
        value = forward.get(field)
        if not isinstance(value, int) or value < 1:
            fail("forward_metric_invalid", field=field, value=value)

    tcp = payload.get("tcpRecipientDelivery")
    if not isinstance(tcp, dict):
        fail("tcp_delivery_invalid")
    for field in ("required", "verified"):
        if not isinstance(tcp.get(field), bool):
            fail("tcp_delivery_field_invalid", field=field, value=tcp.get(field))
    if tcp["required"] and not tcp["verified"]:
        fail("required_tcp_delivery_not_verified")
    if require_tcp and not tcp["verified"]:
        fail("tcp_delivery_not_verified")

    fault_drill = payload.get("faultDrill")
    if fault_drill is not None and fault_drill not in {"redis-outage", "kafka-outage", "target-gateway-outage"}:
        fail("fault_drill_invalid", value=fault_drill)
    if require_fault_drill is not None and fault_drill != require_fault_drill:
        fail("required_fault_drill_missing", expected=require_fault_drill, actual=fault_drill)
    source_outbox_recovered = payload.get("sourceCrossCellOutboxRecovered")
    if source_outbox_recovered is not None and not isinstance(source_outbox_recovered, bool):
        fail("source_cross_cell_outbox_recovery_invalid", value=source_outbox_recovered)
    if fault_drill == "target-gateway-outage" and source_outbox_recovered is not True:
        fail("source_cross_cell_outbox_recovery_missing")
    if fault_drill == "target-gateway-outage" and (
        tcp["required"] is not True or tcp["verified"] is not True
    ):
        fail("target_gateway_outage_tcp_delivery_missing")

    source = payload.get("source")
    if not isinstance(source, dict):
        fail("source_invalid")
    require_string(source, "gitCommit")
    require_string(source, "gitBranch")
    if not isinstance(source.get("gitDirty"), bool):
        fail("source_git_dirty_invalid")

    artifacts = payload.get("artifacts")
    if not isinstance(artifacts, dict):
        fail("artifacts_invalid")
    compose_log = artifacts.get("composeLog")
    if not isinstance(compose_log, str) or not compose_log.strip():
        fail("compose_log_invalid")
    if require_artifacts_exist and not Path(compose_log).is_file():
        fail("compose_log_missing", path=compose_log)


def valid_payload(log: Path) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "status": "passed",
        "runtimeEvidence": True,
        "environment": "multicell-smoke",
        "project": "imserver-multicell-smoke",
        "conversationID": "conversation-1",
        "physicalMigration": True,
        "targetOutboxRecovered": True,
        "sourceCrossCellOutboxRecovered": False,
        "faultDrill": "kafka-outage",
        "tcpRecipientDelivery": {"required": True, "verified": True},
        "remoteCellForwardSuccesses": {"command": 1, "query": 1},
        "source": {"gitCommit": "self-test", "gitBranch": "main", "gitDirty": False},
        "artifacts": {"composeLog": str(log)},
    }


def self_test() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        log = root / "compose.log"
        log.write_text("ok\n", encoding="utf-8")
        receipt = root / "receipt.json"
        receipt.write_text(json.dumps(valid_payload(log)), encoding="utf-8")
        verify(
            receipt,
            require_pass=True,
            require_artifacts_exist=True,
            require_tcp=True,
            require_fault_drill="kafka-outage",
            max_age_seconds=60,
        )
        invalid = valid_payload(log)
        invalid["remoteCellForwardSuccesses"] = {"command": 1, "query": 0}
        receipt.write_text(json.dumps(invalid), encoding="utf-8")
        try:
            verify(
                receipt,
                require_pass=True,
                require_artifacts_exist=True,
                require_tcp=False,
                require_fault_drill=None,
                max_age_seconds=60,
            )
        except SystemExit as exc:
            if "forward_metric_invalid" not in str(exc):
                raise
        else:
            fail("invalid_forward_metric_accepted")
        invalid = valid_payload(log)
        invalid["faultDrill"] = "target-gateway-outage"
        receipt.write_text(json.dumps(invalid), encoding="utf-8")
        try:
            verify(
                receipt,
                require_pass=True,
                require_artifacts_exist=True,
                require_tcp=False,
                require_fault_drill="target-gateway-outage",
                max_age_seconds=60,
            )
        except SystemExit as exc:
            if "source_cross_cell_outbox_recovery_missing" not in str(exc):
                raise
        else:
            fail("missing_source_outbox_recovery_accepted")
        invalid = valid_payload(log)
        invalid["faultDrill"] = "target-gateway-outage"
        invalid["sourceCrossCellOutboxRecovered"] = True
        invalid["tcpRecipientDelivery"] = {"required": False, "verified": False}
        receipt.write_text(json.dumps(invalid), encoding="utf-8")
        try:
            verify(
                receipt,
                require_pass=True,
                require_artifacts_exist=True,
                require_tcp=False,
                require_fault_drill="target-gateway-outage",
                max_age_seconds=60,
            )
        except SystemExit as exc:
            if "target_gateway_outage_tcp_delivery_missing" not in str(exc):
                raise
        else:
            fail("target_gateway_outage_without_tcp_accepted")
    print("multicell_smoke_verify_self_test result=pass")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--receipt-json", type=Path)
    parser.add_argument("--require-pass", action="store_true")
    parser.add_argument("--require-artifacts-exist", action="store_true")
    parser.add_argument("--require-tcp", action="store_true")
    parser.add_argument("--require-fault-drill", choices=("redis-outage", "kafka-outage", "target-gateway-outage"))
    parser.add_argument("--max-age-seconds", type=int, default=86_400)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if args.receipt_json is None:
        parser.error("--receipt-json is required unless --self-test is used")
    verify(
        args.receipt_json,
        require_pass=args.require_pass,
        require_artifacts_exist=args.require_artifacts_exist,
        require_tcp=args.require_tcp,
        require_fault_drill=args.require_fault_drill,
        max_age_seconds=args.max_age_seconds,
    )
    print(f"multicell_smoke_verify result=pass receipt={args.receipt_json}")


if __name__ == "__main__":
    main()
