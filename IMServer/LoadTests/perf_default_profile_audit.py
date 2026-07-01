#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import re
import tempfile
import time
from pathlib import Path
from typing import Any


EXPECTED_PROFILE = "normal-product-baseline"

CHECKS = [
    {
        "path": "IMServer/LoadTests/run_perf_scenarios.sh",
        "kind": "shell-default",
        "pattern": r'PERF_PRODUCTION_GATE_PROFILE="\$\{PERF_PRODUCTION_GATE_PROFILE:-([^}]+)\}"',
        "expected": EXPECTED_PROFILE,
    },
    {
        "path": "IMServer/LoadTests/run_production_profile.sh",
        "kind": "shell-default",
        "pattern": r'PERF_PRODUCTION_GATE_PROFILE="\$\{PERF_PRODUCTION_GATE_PROFILE:-([^}]+)\}"',
        "expected": EXPECTED_PROFILE,
    },
    {
        "path": "IMServer/LoadTests/package_production_evidence.sh",
        "kind": "shell-default",
        "pattern": r'PERF_PRODUCTION_GATE_PROFILE="\$\{PERF_PRODUCTION_GATE_PROFILE:-([^}]+)\}"',
        "expected": EXPECTED_PROFILE,
    },
    {
        "path": "IMServer/LoadTests/perf_production_gate.py",
        "kind": "argparse-default",
        "pattern": r'--profile",\s*choices=sorted\(PROFILES\),\s*default="([^"]+)"',
        "expected": EXPECTED_PROFILE,
    },
    {
        "path": "deploy/ubuntu/68_install_performance_gate.sh",
        "kind": "deploy-default",
        "pattern": r'PERF_PRODUCTION_GATE_PROFILE="\$\{PERF_PRODUCTION_GATE_PROFILE:-([^}]+)\}"',
        "expected": EXPECTED_PROFILE,
    },
    {
        "path": "deploy/ubuntu/69_install_performance_evidence_package.sh",
        "kind": "deploy-default",
        "pattern": r'PERF_PRODUCTION_GATE_PROFILE="\$\{PERF_PRODUCTION_GATE_PROFILE:-([^}]+)\}"',
        "expected": EXPECTED_PROFILE,
    },
    {
        "path": "deploy/ubuntu/70_verify_performance_evidence_package.sh",
        "kind": "deploy-default",
        "pattern": r'PERF_PRODUCTION_GATE_PROFILE="\$\{PERF_PRODUCTION_GATE_PROFILE:-([^}]+)\}"',
        "expected": EXPECTED_PROFILE,
    },
    {
        "path": "deploy/ubuntu/76_collect_diagnostics_bundle.sh",
        "kind": "diagnostics-default",
        "pattern": r'DIAGNOSTIC_PERFORMANCE_GATE_PROFILE="\$\{DIAGNOSTIC_PERFORMANCE_GATE_PROFILE:-([^}]+)\}"',
        "expected": EXPECTED_PROFILE,
    },
    {
        "path": "deploy/ubuntu/77_operational_audit.sh",
        "kind": "operational-default",
        "pattern": r'AUDIT_PERFORMANCE_GATE_PROFILE="\$\{AUDIT_PERFORMANCE_GATE_PROFILE:-([^}]+)\}"',
        "expected": EXPECTED_PROFILE,
    },
    {
        "path": "deploy/ubuntu/78_install_operational_audit_timer.sh",
        "kind": "operational-default",
        "pattern": r'AUDIT_PERFORMANCE_GATE_PROFILE="\$\{AUDIT_PERFORMANCE_GATE_PROFILE:-([^}]+)\}"',
        "expected": EXPECTED_PROFILE,
    },
    {
        "path": "deploy/ubuntu/95_production_readiness_gate.sh",
        "kind": "readiness-default",
        "pattern": r'PERF_PRODUCTION_GATE_PROFILE="\$\{PERF_PRODUCTION_GATE_PROFILE:-([^}]+)\}"',
        "expected": EXPECTED_PROFILE,
    },
    {
        "path": "IMServer/LoadTests/README.md",
        "kind": "docs-default",
        "pattern": r"defaults to\s+`PERF_PRODUCTION_GATE_PROFILE=([^`]+)`",
        "expected": EXPECTED_PROFILE,
    },
]


def issue(kind: str, severity: str, path: str, expected: str, actual: str, detail: str) -> dict[str, str]:
    return {
        "kind": kind,
        "severity": severity,
        "path": path,
        "expected": expected,
        "actual": actual,
        "detail": detail,
    }


def read_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise SystemExit(f"Failed to read JSON {path}: {exc}") from exc


def audit(repo_root: Path) -> dict[str, Any]:
    rows: list[dict[str, str]] = []
    issues: list[dict[str, str]] = []
    for check in CHECKS:
        rel_path = str(check["path"])
        path = repo_root / rel_path
        expected = str(check["expected"])
        pattern = str(check["pattern"])
        kind = str(check["kind"])
        if not path.exists():
            actual = ""
            status = "FAIL"
            detail = "file is missing"
            issues.append(issue(kind, "error", rel_path, expected, actual, detail))
        else:
            text = path.read_text(encoding="utf-8", errors="replace")
            match = re.search(pattern, text, re.MULTILINE | re.DOTALL)
            if not match:
                actual = ""
                status = "FAIL"
                detail = "default profile pattern was not found"
                issues.append(issue(kind, "error", rel_path, expected, actual, detail))
            else:
                actual = match.group(1)
                if actual == expected:
                    status = "PASS"
                    detail = ""
                else:
                    status = "FAIL"
                    detail = "default production profile drifted"
                    issues.append(issue(kind, "error", rel_path, expected, actual, detail))
        rows.append({
            "path": rel_path,
            "kind": kind,
            "expected": expected,
            "actual": actual,
            "status": status,
            "detail": detail,
        })

    error_count = sum(1 for item in issues if item["severity"] == "error")
    warning_count = sum(1 for item in issues if item["severity"] == "warning")
    return {
        "schemaVersion": 1,
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "expectedDefaultProfile": EXPECTED_PROFILE,
        "status": "PASS" if error_count == 0 else "FAIL",
        "checkedCount": len(rows),
        "passCount": sum(1 for row in rows if row["status"] == "PASS"),
        "errorCount": error_count,
        "warningCount": warning_count,
        "checks": rows,
        "issues": issues,
    }


def markdown_table(rows: list[list[str]]) -> str:
    if not rows:
        return ""
    lines = [
        "| " + " | ".join(rows[0]) + " |",
        "| " + " | ".join(["---"] * len(rows[0])) + " |",
    ]
    for row in rows[1:]:
        lines.append("| " + " | ".join(cell.replace("\n", " ") for cell in row) + " |")
    return "\n".join(lines)


def build_markdown(payload: dict[str, Any]) -> str:
    check_rows = [["Status", "Kind", "Path", "Expected", "Actual"]]
    for row in payload["checks"]:
        check_rows.append([
            row["status"],
            row["kind"],
            f"`{row['path']}`",
            f"`{row['expected']}`",
            f"`{row['actual'] or '-'}`",
        ])
    issue_rows = [["Severity", "Kind", "Path", "Expected", "Actual", "Detail"]]
    for row in payload["issues"]:
        issue_rows.append([
            row["severity"],
            row["kind"],
            f"`{row['path']}`",
            f"`{row['expected']}`",
            f"`{row['actual'] or '-'}`",
            row["detail"],
        ])
    return "\n".join([
        "# Default Production Profile Audit",
        "",
        f"- status: `{payload['status']}`",
        f"- expectedDefaultProfile: `{payload['expectedDefaultProfile']}`",
        f"- checked/pass: `{payload['checkedCount']}/{payload['passCount']}`",
        f"- errors/warnings: `{payload['errorCount']}/{payload['warningCount']}`",
        "",
        "## Checks",
        "",
        markdown_table(check_rows),
        "",
        "## Issues",
        "",
        markdown_table(issue_rows) if payload["issues"] else "No default production profile drift found.",
        "",
    ])


def verify_payload(payload: dict[str, Any]) -> None:
    if not isinstance(payload, dict):
        raise SystemExit("default_profile_audit_verify result=fail reason=json_not_object")
    if payload.get("schemaVersion") != 1:
        raise SystemExit("default_profile_audit_verify result=fail reason=schema_version")
    if payload.get("status") not in {"PASS", "FAIL"}:
        raise SystemExit("default_profile_audit_verify result=fail reason=status")
    if payload.get("expectedDefaultProfile") != EXPECTED_PROFILE:
        raise SystemExit("default_profile_audit_verify result=fail reason=expected_default_profile")
    for key in ("checkedCount", "passCount", "errorCount", "warningCount"):
        value = payload.get(key)
        if not isinstance(value, int) or value < 0:
            raise SystemExit(f"default_profile_audit_verify result=fail reason={key}")

    checks = payload.get("checks")
    if not isinstance(checks, list):
        raise SystemExit("default_profile_audit_verify result=fail reason=checks_not_list")
    if payload["checkedCount"] != len(checks):
        raise SystemExit("default_profile_audit_verify result=fail reason=checked_count_mismatch")
    pass_count = sum(1 for row in checks if isinstance(row, dict) and row.get("status") == "PASS")
    if payload["passCount"] != pass_count:
        raise SystemExit("default_profile_audit_verify result=fail reason=pass_count_mismatch")

    issues = payload.get("issues")
    if not isinstance(issues, list):
        raise SystemExit("default_profile_audit_verify result=fail reason=issues_not_list")
    error_count = sum(1 for row in issues if isinstance(row, dict) and row.get("severity") == "error")
    warning_count = sum(1 for row in issues if isinstance(row, dict) and row.get("severity") == "warning")
    if payload["errorCount"] != error_count:
        raise SystemExit("default_profile_audit_verify result=fail reason=error_count_mismatch")
    if payload["warningCount"] != warning_count:
        raise SystemExit("default_profile_audit_verify result=fail reason=warning_count_mismatch")
    if (payload["status"] == "PASS") != (error_count == 0):
        raise SystemExit("default_profile_audit_verify result=fail reason=status_count_mismatch")

    seen_paths: set[str] = set()
    for row in checks:
        if not isinstance(row, dict):
            raise SystemExit("default_profile_audit_verify result=fail reason=check_row_not_object")
        path = str(row.get("path") or "")
        if not path:
            raise SystemExit("default_profile_audit_verify result=fail reason=check_path_missing")
        if path in seen_paths:
            raise SystemExit(f"default_profile_audit_verify result=fail reason=duplicate_check path={path}")
        seen_paths.add(path)
        if row.get("status") not in {"PASS", "FAIL"}:
            raise SystemExit(f"default_profile_audit_verify result=fail reason=check_status path={path}")
        if str(row.get("expected") or "") != EXPECTED_PROFILE:
            raise SystemExit(f"default_profile_audit_verify result=fail reason=check_expected path={path}")
        if row.get("status") == "PASS" and str(row.get("actual") or "") != EXPECTED_PROFILE:
            raise SystemExit(f"default_profile_audit_verify result=fail reason=check_actual path={path}")


def verify_markdown(payload: dict[str, Any], markdown_path: Path) -> None:
    verify_payload(payload)
    if not markdown_path.is_file():
        raise SystemExit(f"default_profile_audit_verify result=fail reason=markdown_missing path={markdown_path}")
    expected = build_markdown(payload)
    actual = markdown_path.read_text(encoding="utf-8")
    if actual != expected:
        raise SystemExit(f"default_profile_audit_verify result=fail reason=markdown_mismatch path={markdown_path}")


def self_test_content(check: dict[str, str], value: str) -> str:
    kind = str(check["kind"])
    if kind == "argparse-default":
        return f'parser.add_argument("--profile", choices=sorted(PROFILES), default="{value}")\n'
    if kind == "diagnostics-default":
        return f'DIAGNOSTIC_PERFORMANCE_GATE_PROFILE="${{DIAGNOSTIC_PERFORMANCE_GATE_PROFILE:-{value}}}"\n'
    if kind == "operational-default":
        return f'AUDIT_PERFORMANCE_GATE_PROFILE="${{AUDIT_PERFORMANCE_GATE_PROFILE:-{value}}}"\n'
    if kind == "docs-default":
        return f"The production gate defaults to `PERF_PRODUCTION_GATE_PROFILE={value}`.\n"
    return f'PERF_PRODUCTION_GATE_PROFILE="${{PERF_PRODUCTION_GATE_PROFILE:-{value}}}"\n'


def write_self_test_repo(root: Path, *, value: str = EXPECTED_PROFILE, skip_path: str = "", bad_pattern_path: str = "") -> None:
    for check in CHECKS:
        rel_path = str(check["path"])
        if rel_path == skip_path:
            continue
        path = root / rel_path
        path.parent.mkdir(parents=True, exist_ok=True)
        if rel_path == bad_pattern_path:
            path.write_text("PROFILE_DEFAULT_IS_NOT_DECLARED_HERE=true\n", encoding="utf-8")
        else:
            path.write_text(self_test_content(check, value), encoding="utf-8")


def expect_self_test_issue(payload: dict[str, Any], *, path: str, detail: str) -> None:
    for item in payload.get("issues", []):
        if item.get("path") == path and item.get("detail") == detail:
            return
    raise SystemExit(f"default_profile_audit_self_test result=fail reason=missing_issue path={path} detail={detail}")


def expect_system_exit(label: str, fn: Any) -> None:
    try:
        fn()
    except SystemExit:
        print(label)
        return
    raise SystemExit(f"default_profile_audit_self_test result=fail reason={label}_not_rejected")


def run_self_test() -> None:
    first_path = str(CHECKS[0]["path"])
    with tempfile.TemporaryDirectory(prefix="default-profile-audit-self-test-") as tmp:
        root = Path(tmp)
        write_self_test_repo(root)
        payload = audit(root)
        if payload["status"] != "PASS" or payload["errorCount"] != 0 or payload["passCount"] != len(CHECKS):
            raise SystemExit("default_profile_audit_self_test result=fail reason=valid_fixture_failed")
        markdown_path = root / "default-profile-audit.md"
        markdown_path.write_text(build_markdown(payload), encoding="utf-8")
        verify_markdown(payload, markdown_path)

    with tempfile.TemporaryDirectory(prefix="default-profile-audit-self-test-") as tmp:
        root = Path(tmp)
        write_self_test_repo(root, value="large-group-5000-steady")
        payload = audit(root)
        if payload["status"] != "FAIL" or payload["errorCount"] != len(CHECKS):
            raise SystemExit("default_profile_audit_self_test result=fail reason=drift_fixture_failed")
        expect_self_test_issue(payload, path=first_path, detail="default production profile drifted")
        print("self_test_profile_drift_rejected")

    with tempfile.TemporaryDirectory(prefix="default-profile-audit-self-test-") as tmp:
        root = Path(tmp)
        write_self_test_repo(root, skip_path=first_path)
        payload = audit(root)
        if payload["status"] != "FAIL":
            raise SystemExit("default_profile_audit_self_test result=fail reason=missing_file_fixture_failed")
        expect_self_test_issue(payload, path=first_path, detail="file is missing")
        print("self_test_missing_file_rejected")

    with tempfile.TemporaryDirectory(prefix="default-profile-audit-self-test-") as tmp:
        root = Path(tmp)
        write_self_test_repo(root, bad_pattern_path=first_path)
        payload = audit(root)
        if payload["status"] != "FAIL":
            raise SystemExit("default_profile_audit_self_test result=fail reason=missing_pattern_fixture_failed")
        expect_self_test_issue(payload, path=first_path, detail="default profile pattern was not found")
        print("self_test_missing_pattern_rejected")

    with tempfile.TemporaryDirectory(prefix="default-profile-audit-self-test-") as tmp:
        root = Path(tmp)
        write_self_test_repo(root)
        payload = audit(root)
        markdown_path = root / "default-profile-audit.md"
        markdown_path.write_text(build_markdown(payload) + "\nextra drift\n", encoding="utf-8")
        expect_system_exit("self_test_markdown_mismatch_rejected", lambda: verify_markdown(payload, markdown_path))

    with tempfile.TemporaryDirectory(prefix="default-profile-audit-self-test-") as tmp:
        root = Path(tmp)
        write_self_test_repo(root)
        payload = audit(root)
        bad_payload = dict(payload)
        bad_payload["checkedCount"] = payload["checkedCount"] + 1
        expect_system_exit("self_test_payload_count_mismatch_rejected", lambda: verify_payload(bad_payload))

    print("default_profile_audit_self_test result=pass")


def write_csv(path: Path, rows: list[dict[str, str]]) -> None:
    fieldnames = ["severity", "kind", "path", "expected", "actual", "detail"]
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow({key: row.get(key, "") for key in fieldnames})


def main() -> int:
    parser = argparse.ArgumentParser(description="Audit default production performance profile settings.")
    parser.add_argument("--repo-root", default=str(Path(__file__).resolve().parents[2]))
    parser.add_argument("--output")
    parser.add_argument("--json-output")
    parser.add_argument("--csv-output")
    parser.add_argument("--verify-json")
    parser.add_argument("--verify-md")
    parser.add_argument("--strict", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        run_self_test()
        return 0

    if args.verify_json:
        payload = read_json(Path(args.verify_json))
        verify_payload(payload)
        if args.verify_md:
            verify_markdown(payload, Path(args.verify_md))
        return 1 if args.strict and payload["status"] != "PASS" else 0
    if args.verify_md:
        parser.error("--verify-md requires --verify-json")

    payload = audit(Path(args.repo_root).resolve())
    markdown = build_markdown(payload)
    if args.output:
        Path(args.output).write_text(markdown, encoding="utf-8")
    else:
        print(markdown)
    if args.json_output:
        Path(args.json_output).write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    if args.csv_output:
        write_csv(Path(args.csv_output), payload["issues"])
    if args.output:
        verify_markdown(payload, Path(args.output))
    return 1 if args.strict and payload["status"] != "PASS" else 0


if __name__ == "__main__":
    raise SystemExit(main())
