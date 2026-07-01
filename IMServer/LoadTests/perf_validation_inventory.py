#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_DIR = Path(__file__).resolve().parent
DEPLOY_DIR = REPO_ROOT / "deploy" / "ubuntu"
K6_DIR = SCRIPT_DIR / "k6"
REQUIRED_INVENTORY_RECORDS = {
    "shell": {
        "IMServer/LoadTests/assert_production_ready.sh",
        "IMServer/LoadTests/package_production_evidence.sh",
        "IMServer/LoadTests/production_readiness_status.sh",
        "IMServer/LoadTests/run_current_production_readiness.sh",
        "IMServer/LoadTests/run_non_large_group_regression.sh",
        "IMServer/LoadTests/run_perf_scenarios.sh",
        "IMServer/LoadTests/run_product_test_plan.sh",
        "IMServer/LoadTests/run_product_scenario_suite.sh",
        "IMServer/LoadTests/run_production_acceptance.sh",
        "IMServer/LoadTests/run_production_profile.sh",
        "IMServer/LoadTests/validate_load_tests.sh",
        "IMServer/LoadTests/verify_production_acceptance.sh",
    },
    "python": {
        "IMServer/LoadTests/perf_dashboard.py",
        "IMServer/LoadTests/perf_docs_audit.py",
        "IMServer/LoadTests/perf_evidence_manifest.py",
        "IMServer/LoadTests/perf_matrix_audit.py",
        "IMServer/LoadTests/perf_next_actions.py",
        "IMServer/LoadTests/perf_product_campaign_audit.py",
        "IMServer/LoadTests/perf_product_plan_artifacts_verify.py",
        "IMServer/LoadTests/perf_product_profile_gate.py",
        "IMServer/LoadTests/perf_product_scenario_suite_verify.py",
        "IMServer/LoadTests/perf_product_test_plan_runbook.py",
        "IMServer/LoadTests/perf_production_acceptance_verify.py",
        "IMServer/LoadTests/perf_production_gate.py",
        "IMServer/LoadTests/perf_readiness_gate.py",
        "IMServer/LoadTests/perf_run_plan.py",
        "IMServer/LoadTests/perf_scenario_catalog.py",
        "IMServer/LoadTests/perf_scenario_status.py",
        "IMServer/LoadTests/perf_slo_status.py",
        "IMServer/LoadTests/perf_state_summary.py",
        "IMServer/LoadTests/perf_validation_inventory.py",
    },
    "docs": {
        "IMServer/LoadTests/README.md",
        "IMServer/LoadTests/perf_product_campaigns.json",
        "IMServer/LoadTests/perf_production_profiles.json",
        "deploy/ubuntu/README.md",
        "docs/imserver-aliyun-local-binary-deploy.md",
    },
}


def bool_arg(value: str | bool | None) -> bool:
    if isinstance(value, bool):
        return value
    return str(value or "").lower() in {"1", "true", "yes", "on"}


def read_list(path: Path) -> list[Path]:
    return [Path(line).resolve() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def discover_shell_scripts() -> list[Path]:
    paths = [
        *sorted(DEPLOY_DIR.glob("*.sh")),
        *sorted(SCRIPT_DIR.glob("*.sh")),
    ]
    return [path.resolve() for path in paths if path.is_file()]


def discover_python_scripts() -> list[Path]:
    return [path.resolve() for path in sorted(SCRIPT_DIR.glob("*.py")) if path.is_file()]


def discover_k6_scripts() -> list[Path]:
    return [path.resolve() for path in sorted(K6_DIR.glob("*.js")) if path.is_file()]


def discover_doc_files() -> list[Path]:
    candidates = [
        SCRIPT_DIR / "README.md",
        SCRIPT_DIR / "perf_product_campaigns.json",
        SCRIPT_DIR / "perf_production_profiles.json",
        DEPLOY_DIR / "README.md",
        REPO_ROOT / "docs" / "imserver-aliyun-local-binary-deploy.md",
    ]
    return [path.resolve() for path in candidates if path.is_file()]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_record(path: Path, repo_root: Path) -> dict[str, Any]:
    data = path.read_bytes()
    try:
        relative = path.relative_to(repo_root)
    except ValueError:
        relative = path
    return {
        "path": str(relative),
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
    }


def git_output(repo_root: Path, *args: str) -> str:
    return subprocess.run(
        ["git", *args],
        cwd=repo_root,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    ).stdout.strip()


def source_metadata(repo_root: Path) -> dict[str, Any]:
    git_error = ""
    try:
        actual_repo_root = Path(git_output(repo_root, "rev-parse", "--show-toplevel")).resolve()
    except Exception as exc:
        actual_repo_root = repo_root.resolve()
        git_error = f"show_toplevel_failed:{exc}"
    try:
        git_commit = git_output(actual_repo_root, "rev-parse", "--verify", "HEAD")
    except Exception as exc:
        git_commit = ""
        git_error = git_error or f"commit_failed:{exc}"
    try:
        git_branch = git_output(actual_repo_root, "branch", "--show-current")
    except Exception as exc:
        git_branch = ""
        git_error = git_error or f"branch_failed:{exc}"
    try:
        git_dirty: bool | None = bool(git_output(actual_repo_root, "status", "--porcelain"))
    except Exception as exc:
        git_dirty = None
        git_error = git_error or f"dirty_failed:{exc}"
    return {
        "repoRoot": str(actual_repo_root),
        "gitCommit": git_commit,
        "gitBranch": git_branch,
        "gitDirty": git_dirty,
        "gitError": git_error,
    }


def build_inventory(args: argparse.Namespace) -> dict[str, Any]:
    repo_root = Path(args.repo_root).resolve()
    shell_scripts = read_list(args.shell_list) if args.shell_list else discover_shell_scripts()
    python_scripts = read_list(args.python_list) if args.python_list else discover_python_scripts()
    k6_scripts = read_list(args.k6_list) if args.k6_list else discover_k6_scripts()
    doc_files = read_list(args.docs_list) if args.docs_list else discover_doc_files()
    groups = {
        "shell": [file_record(path, repo_root) for path in shell_scripts],
        "python": [file_record(path, repo_root) for path in python_scripts],
        "k6": [file_record(path, repo_root) for path in k6_scripts],
        "docs": [file_record(path, repo_root) for path in doc_files],
    }
    k6_inspect_requested = bool_arg(args.k6_inspect_requested)
    k6_inspect_status = str(args.k6_inspect_status or "")
    if not k6_inspect_status:
        if not k6_inspect_requested:
            k6_inspect_status = "skipped_disabled"
        elif not args.k6_bin:
            k6_inspect_status = "skipped_missing"
        else:
            k6_inspect_status = "unknown"
    return {
        "schemaVersion": 1,
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "source": source_metadata(repo_root),
        "tools": {
            "bash": {"path": args.bash_bin or shutil.which("bash") or ""},
            "python3": {"path": args.python_bin or sys.executable},
            "k6": {
                "path": args.k6_bin or shutil.which("k6") or "",
                "inspectRequested": k6_inspect_requested,
                "inspectStatus": k6_inspect_status,
            },
        },
        "summary": {name: len(records) for name, records in groups.items()},
        "requiredRecords": {
            name: sorted(records)
            for name, records in sorted(REQUIRED_INVENTORY_RECORDS.items())
        },
        "groups": groups,
    }


def render_markdown(payload: dict[str, Any]) -> str:
    source = payload.get("source") or {}
    tools = payload.get("tools") or {}
    k6 = tools.get("k6") or {}
    groups = payload.get("groups") or {}
    lines = [
        "# Validation Inventory",
        "",
        f"- generatedAt: `{payload.get('generatedAt') or '-'}`",
        f"- gitCommit: `{source.get('gitCommit') or '-'}`",
        f"- gitBranch: `{source.get('gitBranch') or '-'}`",
        f"- gitDirty: `{source.get('gitDirty')}`",
        f"- bash: `{(tools.get('bash') or {}).get('path') or '-'}`",
        f"- python3: `{(tools.get('python3') or {}).get('path') or '-'}`",
        f"- k6: `{k6.get('path') or '-'}`",
        f"- k6InspectStatus: `{k6.get('inspectStatus') or '-'}`",
        f"- shellScripts: `{len(groups.get('shell') or [])}`",
        f"- pythonScripts: `{len(groups.get('python') or [])}`",
        f"- k6Scripts: `{len(groups.get('k6') or [])}`",
        f"- docs: `{len(groups.get('docs') or [])}`",
        "",
        "## requiredRecords",
        "",
    ]
    required_records = payload.get("requiredRecords") or {}
    for name in ("shell", "python", "docs"):
        lines.append(f"### {name}")
        lines.append("")
        for record in required_records.get(name) or []:
            lines.append(f"- `{record}`")
        lines.append("")
    for name in ("shell", "python", "k6", "docs"):
        lines.extend([f"## {name}", ""])
        for record in groups.get(name) or []:
            lines.append(f"- `{record['path']}` `{record['sha256']}`")
        lines.append("")
    return "\n".join(lines)


def verify_inventory(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise SystemExit(f"validation_inventory result=fail reason=invalid_json path={path} error={exc}") from exc
    if int(payload.get("schemaVersion") or 0) != 1:
        raise SystemExit(f"validation_inventory result=fail reason=invalid_schema path={path}")
    summary = payload.get("summary") or {}
    groups = payload.get("groups") or {}
    source = payload.get("source") or {}
    tools = payload.get("tools") or {}
    required_records = payload.get("requiredRecords")
    expected_required_records = {
        name: sorted(records)
        for name, records in sorted(REQUIRED_INVENTORY_RECORDS.items())
    }
    if required_records != expected_required_records:
        raise SystemExit(
            "validation_inventory result=fail "
            f"reason=required_records_mismatch path={path}"
        )
    for name in ("shell", "python", "k6", "docs"):
        if name not in groups or not isinstance(groups.get(name), list):
            raise SystemExit(f"validation_inventory result=fail reason=missing_group group={name} path={path}")
        if int(summary.get(name) or -1) != len(groups.get(name) or []):
            raise SystemExit(f"validation_inventory result=fail reason=count_mismatch group={name} path={path}")
        if len(groups.get(name) or []) <= 0:
            raise SystemExit(f"validation_inventory result=fail reason=empty_group group={name} path={path}")
        seen_record_paths: set[str] = set()
        for index, record in enumerate(groups.get(name) or []):
            if not isinstance(record, dict):
                raise SystemExit(
                    "validation_inventory result=fail "
                    f"reason=invalid_record group={name} index={index} path={path}"
                )
            record_path = record.get("path")
            if not isinstance(record_path, str) or not record_path.strip():
                raise SystemExit(
                    "validation_inventory result=fail "
                    f"reason=invalid_record_path group={name} index={index} path={path}"
                )
            record_path_obj = Path(record_path)
            if record_path_obj.is_absolute() or ".." in record_path_obj.parts:
                raise SystemExit(
                    "validation_inventory result=fail "
                    f"reason=unsafe_record_path group={name} record={record_path} path={path}"
                )
            if record_path in seen_record_paths:
                raise SystemExit(
                    "validation_inventory result=fail "
                    f"reason=duplicate_record_path group={name} record={record_path} path={path}"
                )
            seen_record_paths.add(record_path)
            record_bytes = record.get("bytes")
            if not isinstance(record_bytes, int) or record_bytes <= 0:
                raise SystemExit(
                    "validation_inventory result=fail "
                    f"reason=invalid_record_bytes group={name} record={record_path} path={path}"
                )
            record_sha = record.get("sha256")
            if (
                not isinstance(record_sha, str)
                or len(record_sha) != 64
                or any(character not in "0123456789abcdef" for character in record_sha)
            ):
                raise SystemExit(
                    "validation_inventory result=fail "
                    f"reason=invalid_record_sha256 group={name} record={record_path} path={path}"
                )
        record_paths = {str(record.get("path") or "") for record in groups.get(name) or [] if isinstance(record, dict)}
        for required_path in sorted(REQUIRED_INVENTORY_RECORDS.get(name, set())):
            if required_path not in record_paths:
                raise SystemExit(
                    "validation_inventory result=fail "
                    f"reason=required_record_missing group={name} record={required_path} path={path}"
                )
    if not source.get("gitCommit") or "gitDirty" not in source:
        raise SystemExit(f"validation_inventory result=fail reason=source_metadata_missing path={path}")
    k6_status = (tools.get("k6") or {}).get("inspectStatus")
    if k6_status not in {"pass", "skipped_missing", "skipped_disabled"}:
        raise SystemExit(f"validation_inventory result=fail reason=k6_status_invalid status={k6_status} path={path}")
    return payload


def verify_inventory_markdown(inventory: dict[str, Any], path: Path) -> None:
    try:
        text = path.read_text(encoding="utf-8")
    except Exception as exc:
        raise SystemExit(f"validation_inventory result=fail reason=invalid_markdown path={path} error={exc}") from exc
    if "# Validation Inventory" not in text:
        raise SystemExit(f"validation_inventory result=fail reason=markdown_title_missing path={path}")
    summary = inventory.get("summary") or {}
    summary_labels = {
        "shell": "shellScripts",
        "python": "pythonScripts",
        "k6": "k6Scripts",
        "docs": "docs",
    }
    for group, label in summary_labels.items():
        expected = f"- {label}: `{int(summary.get(group) or 0)}`"
        if expected not in text:
            raise SystemExit(
                "validation_inventory result=fail "
                f"reason=markdown_summary_mismatch group={group} path={path}"
            )
    required_records = inventory.get("requiredRecords") or {}
    if "## requiredRecords" not in text:
        raise SystemExit(f"validation_inventory result=fail reason=markdown_required_records_missing path={path}")
    for group in ("shell", "python", "docs"):
        if f"### {group}" not in text:
            raise SystemExit(
                "validation_inventory result=fail "
                f"reason=markdown_required_group_missing group={group} path={path}"
            )
        for record in required_records.get(group) or []:
            expected = f"- `{record}`"
            if expected not in text:
                raise SystemExit(
                    "validation_inventory result=fail "
                    f"reason=markdown_required_record_missing group={group} record={record} path={path}"
                )
    groups = inventory.get("groups") or {}
    for group in ("shell", "python", "k6", "docs"):
        if f"## {group}" not in text:
            raise SystemExit(
                "validation_inventory result=fail "
                f"reason=markdown_group_missing group={group} path={path}"
            )
        for record in groups.get(group) or []:
            if not isinstance(record, dict):
                continue
            record_path = str(record.get("path") or "")
            record_sha = str(record.get("sha256") or "")
            expected = f"- `{record_path}` `{record_sha}`"
            if expected not in text:
                raise SystemExit(
                    "validation_inventory result=fail "
                    f"reason=markdown_record_missing group={group} record={record_path or '-'} path={path}"
                )


def verify_gate_source_match(inventory: dict[str, Any], gate_path: Path) -> None:
    try:
        gate = json.loads(gate_path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise SystemExit(f"validation_inventory result=fail reason=invalid_gate_json path={gate_path} error={exc}") from exc
    inventory_source = inventory.get("source") or {}
    gate_source = gate.get("source") or {}
    inventory_commit = str(inventory_source.get("gitCommit") or "")
    gate_commit = str(gate_source.get("gitCommit") or "")
    if inventory_commit != gate_commit:
        raise SystemExit(
            "validation_inventory result=fail "
            f"reason=source_git_commit_mismatch inventory={inventory_commit or '-'} gate={gate_commit or '-'}"
        )
    inventory_dirty = inventory_source.get("gitDirty")
    gate_dirty = gate_source.get("gitDirty")
    if inventory_dirty != gate_dirty:
        raise SystemExit(
            "validation_inventory result=fail "
            f"reason=source_git_dirty_mismatch inventory={inventory_dirty} gate={gate_dirty}"
        )


def write_fixture_file(root: Path, relative_path: str) -> Path:
    path = root / relative_path
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"fixture for {relative_path}\n", encoding="utf-8")
    return path


def expect_self_test_failure(label: str, action: Any, expected_reason: str) -> None:
    try:
        action()
    except SystemExit as exc:
        message = str(exc)
        if expected_reason not in message:
            raise SystemExit(f"{label}_wrong_failure reason={message}") from exc
        return
    raise SystemExit(f"{label}_did_not_fail")


def run_self_test() -> None:
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        records_by_group: dict[str, list[dict[str, Any]]] = {}
        for group in ("shell", "python", "docs"):
            records_by_group[group] = [
                file_record(write_fixture_file(root, relative_path), root)
                for relative_path in sorted(REQUIRED_INVENTORY_RECORDS[group])
            ]
        records_by_group["k6"] = [
            file_record(write_fixture_file(root, "IMServer/LoadTests/k6/self-test.js"), root)
        ]
        payload = {
            "schemaVersion": 1,
            "generatedAt": "2026-01-01T00:00:00Z",
            "source": {
                "repoRoot": str(root),
                "gitCommit": "0123456789abcdef0123456789abcdef01234567",
                "gitBranch": "self-test",
                "gitDirty": False,
                "gitError": "",
            },
            "tools": {
                "bash": {"path": "/bin/bash"},
                "python3": {"path": sys.executable},
                "k6": {
                    "path": "",
                    "inspectRequested": False,
                    "inspectStatus": "skipped_disabled",
                },
            },
            "summary": {name: len(records) for name, records in records_by_group.items()},
            "requiredRecords": {
                name: sorted(records)
                for name, records in sorted(REQUIRED_INVENTORY_RECORDS.items())
            },
            "groups": records_by_group,
        }
        json_path = root / "validation-inventory.json"
        md_path = root / "validation-inventory.md"
        json_path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
        md_path.write_text(render_markdown(payload), encoding="utf-8")
        verified = verify_inventory(json_path)
        verify_inventory_markdown(verified, md_path)

        gate_path = root / "production-gate.json"
        gate_path.write_text(json.dumps({"source": payload["source"]}, sort_keys=True), encoding="utf-8")
        verify_gate_source_match(verified, gate_path)

        bad_missing = json.loads(json.dumps(payload))
        bad_missing["groups"]["python"] = [
            record
            for record in bad_missing["groups"]["python"]
            if record.get("path") != "IMServer/LoadTests/perf_validation_inventory.py"
        ]
        bad_missing["summary"]["python"] = len(bad_missing["groups"]["python"])
        bad_missing_path = root / "validation-inventory-missing-required.json"
        bad_missing_path.write_text(json.dumps(bad_missing, sort_keys=True), encoding="utf-8")
        expect_self_test_failure(
            "self_test_missing_required_record",
            lambda: verify_inventory(bad_missing_path),
            "required_record_missing",
        )

        bad_markdown_path = root / "validation-inventory-bad.md"
        bad_markdown_path.write_text("# Validation Inventory\n", encoding="utf-8")
        expect_self_test_failure(
            "self_test_bad_markdown",
            lambda: verify_inventory_markdown(verified, bad_markdown_path),
            "markdown_summary_mismatch",
        )

        bad_gate_path = root / "production-gate-mismatch.json"
        bad_gate_path.write_text(
            json.dumps({"source": {"gitCommit": payload["source"]["gitCommit"], "gitDirty": True}}, sort_keys=True),
            encoding="utf-8",
        )
        expect_self_test_failure(
            "self_test_gate_source_mismatch",
            lambda: verify_gate_source_match(verified, bad_gate_path),
            "source_git_dirty_mismatch",
        )
    print("validation_inventory_self_test result=pass")


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate or verify load-test validation inventory artifacts.")
    parser.add_argument("--repo-root", type=Path, default=REPO_ROOT)
    parser.add_argument("--json-output", type=Path)
    parser.add_argument("--md-output", type=Path)
    parser.add_argument("--shell-list", type=Path)
    parser.add_argument("--python-list", type=Path)
    parser.add_argument("--k6-list", type=Path)
    parser.add_argument("--docs-list", type=Path)
    parser.add_argument("--bash-bin", default="")
    parser.add_argument("--python-bin", default="")
    parser.add_argument("--k6-bin", default="")
    parser.add_argument("--k6-inspect-requested", default="false")
    parser.add_argument("--k6-inspect-status", default="")
    parser.add_argument("--verify-json", type=Path)
    parser.add_argument("--verify-md", type=Path)
    parser.add_argument("--gate-json", type=Path, help="When verifying, require inventory source metadata to match this production gate.")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        run_self_test()
        return 0

    if args.verify_json:
        payload = verify_inventory(args.verify_json)
        if args.verify_md:
            verify_inventory_markdown(payload, args.verify_md)
        if args.gate_json:
            verify_gate_source_match(payload, args.gate_json)
        print(f"validation_inventory result=pass path={args.verify_json}")
        return 0

    if not args.json_output or not args.md_output:
        parser.error("--json-output and --md-output are required when generating inventory")
    payload = build_inventory(args)
    args.json_output.parent.mkdir(parents=True, exist_ok=True)
    args.md_output.parent.mkdir(parents=True, exist_ok=True)
    args.json_output.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    args.md_output.write_text(render_markdown(payload), encoding="utf-8")
    verified = verify_inventory(args.json_output)
    verify_inventory_markdown(verified, args.md_output)
    print(f"validationInventory={args.json_output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
