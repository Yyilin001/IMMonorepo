#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import tempfile
import uuid
from pathlib import Path
from typing import Any


REQUIRED_CHECKS = {
    "auth",
    "conversationCreate",
    "internalSend",
    "summaryProjection",
    "changesProjection",
    "timelineSince",
    "metricsSecret",
}


def fail(reason: str, detail: str | None = None) -> None:
    suffix = f" {detail}" if detail else ""
    raise SystemExit(f"local_acceptance_verify result=fail reason={reason}{suffix}")


def load_json(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail("json_missing", f"path={path}")
    except json.JSONDecodeError as exc:
        fail("json_invalid", f"path={path} error={exc}")
    if not isinstance(data, dict):
        fail("json_not_object", f"path={path}")
    return data


def bool_field(data: dict[str, Any], field: str, expected: bool, *, context: str) -> None:
    if data.get(field) is not expected:
        fail(f"{context}_{field}_invalid", f"value={data.get(field)!r}")


def string_field(data: dict[str, Any], field: str, *, context: str, allow_empty: bool = False) -> str:
    value = data.get(field)
    if not isinstance(value, str) or (not allow_empty and not value.strip()):
        fail(f"{context}_{field}_invalid", f"value={value!r}")
    return value


def resolve_artifact_path(raw_path: str, *, relative_to: Path) -> Path:
    path = Path(raw_path)
    if not path.is_absolute():
        path = (relative_to / path).resolve()
    return path


def latest_summary(result_root: Path) -> Path:
    candidates = sorted(
        result_root.glob("local-acceptance-*-summary.json"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    if not candidates:
        fail("summary_not_found", f"resultRoot={result_root}")
    return candidates[0]


def verify_uuid(value: Any, *, field: str) -> None:
    if not isinstance(value, str):
        fail(f"{field}_invalid", f"value={value!r}")
    try:
        uuid.UUID(value)
    except ValueError:
        fail(f"{field}_invalid", f"value={value!r}")


def verify(args: argparse.Namespace) -> None:
    summary_path = Path(args.summary_json).resolve() if args.summary_json else latest_summary(Path(args.result_root).resolve())
    summary = load_json(summary_path)
    summary_dir = summary_path.parent

    if summary.get("schemaVersion") != 1:
        fail("summary_schema_version", f"path={summary_path}")
    run_id = string_field(summary, "runID", context="summary")
    bool_field(summary, "productionEvidence", False, context="summary")
    bool_field(summary, "localOnly", True, context="summary")

    backend = string_field(summary, "backend", context="summary")
    if backend not in {"swift-postgres", "docker-compose", "external", "none"}:
        fail("summary_backend_invalid", f"backend={backend}")

    target = summary.get("target")
    if not isinstance(target, dict):
        fail("summary_target_missing", f"path={summary_path}")
    base_url = string_field(target, "baseURL", context="summary_target")
    string_field(target, "tcpHost", context="summary_target")
    string_field(target, "tcpPort", context="summary_target")

    database = summary.get("database")
    if backend == "swift-postgres":
        if not isinstance(database, dict):
            fail("summary_database_missing", f"path={summary_path}")
        database_name = string_field(database, "name", context="summary_database")
        if bool(summary.get("resetSchema")) and not database_name.startswith("imserver_local_acceptance"):
            fail("summary_database_unsafe_reset", f"database={database_name}")

    artifacts = summary.get("artifacts")
    if not isinstance(artifacts, dict):
        fail("summary_artifacts_missing", f"path={summary_path}")
    http_smoke_raw = string_field(artifacts, "httpSmokeReport", context="summary_artifacts")
    http_smoke_path = Path(args.http_smoke_json).resolve() if args.http_smoke_json else resolve_artifact_path(
        http_smoke_raw,
        relative_to=summary_dir,
    )
    if not http_smoke_path.exists():
        fail("http_smoke_report_missing", f"path={http_smoke_path}")

    server_log_raw = artifacts.get("serverLog")
    if backend == "swift-postgres":
        if not isinstance(server_log_raw, str) or not server_log_raw.strip():
            fail("server_log_missing", f"path={summary_path}")
        server_log_path = resolve_artifact_path(server_log_raw, relative_to=summary_dir)
        if not server_log_path.exists():
            fail("server_log_missing", f"path={server_log_path}")

    http_smoke = load_json(http_smoke_path)
    if http_smoke.get("schemaVersion") != 1:
        fail("http_smoke_schema_version", f"path={http_smoke_path}")
    if http_smoke.get("runID") != run_id:
        fail("run_id_mismatch", f"summary={run_id} httpSmoke={http_smoke.get('runID')!r}")
    bool_field(http_smoke, "productionEvidence", False, context="http_smoke")
    bool_field(http_smoke, "localOnly", True, context="http_smoke")
    if string_field(http_smoke, "baseURL", context="http_smoke") != base_url:
        fail("base_url_mismatch", f"summary={base_url} httpSmoke={http_smoke.get('baseURL')!r}")

    checks = http_smoke.get("checks")
    if not isinstance(checks, dict):
        fail("http_smoke_checks_missing", f"path={http_smoke_path}")
    missing = sorted(REQUIRED_CHECKS.difference(checks))
    if missing:
        fail("http_smoke_checks_missing", f"missing={','.join(missing)}")
    bad = sorted(name for name in REQUIRED_CHECKS if checks.get(name) != "ok")
    if bad:
        fail("http_smoke_checks_not_ok", f"bad={','.join(bad)}")

    verify_uuid(http_smoke.get("directConversationID"), field="direct_conversation_id")
    verify_uuid(http_smoke.get("groupConversationID"), field="group_conversation_id")

    print(f"local_acceptance_verify result=pass summary={summary_path} httpSmoke={http_smoke_path}")


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True), encoding="utf-8")


def run_self_test() -> None:
    with tempfile.TemporaryDirectory() as raw_tmp:
        tmp = Path(raw_tmp)
        summary_path = tmp / "local-acceptance-self-test-summary.json"
        http_path = tmp / "http-smoke" / "local-acceptance-self-test-local-http-smoke.json"
        log_path = tmp / "server.log"
        run_id = "local-acceptance-self-test"
        direct_id = str(uuid.uuid4())
        group_id = str(uuid.uuid4())
        log_path.write_text("server started\n", encoding="utf-8")
        write_json(
            http_path,
            {
                "schemaVersion": 1,
                "runID": run_id,
                "productionEvidence": False,
                "localOnly": True,
                "baseURL": "http://127.0.0.1:8080",
                "commandURL": "http://127.0.0.1:8080",
                "queryURL": "http://127.0.0.1:8080",
                "directConversationID": direct_id,
                "groupConversationID": group_id,
                "checks": {name: "ok" for name in sorted(REQUIRED_CHECKS)},
            },
        )
        write_json(
            summary_path,
            {
                "schemaVersion": 1,
                "runID": run_id,
                "target": {
                    "baseURL": "http://127.0.0.1:8080",
                    "tcpHost": "127.0.0.1",
                    "tcpPort": "9000",
                },
                "database": {
                    "host": "127.0.0.1",
                    "port": "5432",
                    "name": "imserver_local_acceptance",
                },
                "productionEvidence": False,
                "localOnly": True,
                "backend": "swift-postgres",
                "resetSchema": True,
                "startStack": True,
                "runProductScenarios": False,
                "suite": "smoke",
                "artifacts": {
                    "httpSmokeReport": str(http_path),
                    "serverLog": str(log_path),
                },
            },
        )
        verify(argparse.Namespace(summary_json=str(summary_path), http_smoke_json=None, result_root=str(tmp)))

        bad_summary_path = tmp / "bad-summary.json"
        bad_summary = load_json(summary_path)
        bad_summary["productionEvidence"] = True
        write_json(bad_summary_path, bad_summary)
        try:
            verify(argparse.Namespace(summary_json=str(bad_summary_path), http_smoke_json=None, result_root=str(tmp)))
        except SystemExit as exc:
            if "summary_productionEvidence_invalid" not in str(exc):
                raise
        else:
            fail("self_test_expected_production_evidence_failure")

        bad_check_path = tmp / "bad-check-summary.json"
        bad_http_path = tmp / "http-smoke" / "bad-check-http-smoke.json"
        bad_http = load_json(http_path)
        bad_http["checks"]["timelineSince"] = "fail"
        write_json(bad_http_path, bad_http)
        bad_summary = load_json(summary_path)
        bad_summary["artifacts"]["httpSmokeReport"] = str(bad_http_path)
        write_json(bad_check_path, bad_summary)
        try:
            verify(argparse.Namespace(summary_json=str(bad_check_path), http_smoke_json=None, result_root=str(tmp)))
        except SystemExit as exc:
            if "http_smoke_checks_not_ok" not in str(exc):
                raise
        else:
            fail("self_test_expected_check_failure")

    print("local_acceptance_verify_self_test result=pass")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Verify local IMServer acceptance artifacts.")
    parser.add_argument("--summary-json", help="Path to local acceptance summary JSON. Defaults to latest in --result-root.")
    parser.add_argument("--http-smoke-json", help="Optional explicit local HTTP smoke report JSON.")
    parser.add_argument(
        "--result-root",
        default=str(Path(__file__).resolve().parent / "results" / "local-acceptance"),
        help="Local acceptance result root used when --summary-json is omitted.",
    )
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.self_test:
        run_self_test()
        return
    verify(args)


if __name__ == "__main__":
    main()
