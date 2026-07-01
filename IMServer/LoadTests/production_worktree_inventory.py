#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import tempfile
from collections import Counter
from pathlib import Path
from typing import Any

from perf_forbidden_artifacts import forbidden_runtime_artifact_kinds


GENERATED_PREFIXES = (
    "IMServer/LoadTests/results/",
    "IMServer/reports/",
    "reports/",
    ".build/",
    "DerivedData/",
)

GENERATED_SUFFIXES = (
    ".log",
    ".pid",
    ".tmp",
    ".sqlite",
    ".sqlite-shm",
    ".sqlite-wal",
    ".tar.gz",
    ".xcresult",
)


def run_git(repo_root: Path, args: list[str]) -> str:
    completed = subprocess.run(
        ["git", *args],
        cwd=repo_root,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return completed.stdout


def is_generated_local_artifact(path: str) -> bool:
    normalized = path.replace("\\", "/")
    name = Path(normalized).name
    if any(normalized.startswith(prefix) for prefix in GENERATED_PREFIXES):
        return True
    if any(name.endswith(suffix) for suffix in GENERATED_SUFFIXES):
        return True
    return False


def category_for_path(path: str) -> tuple[str, list[str]]:
    forbidden_kinds = forbidden_runtime_artifact_kinds(path)
    if forbidden_kinds:
        return "forbidden_runtime_artifact", forbidden_kinds
    if is_generated_local_artifact(path):
        return "generated_local_artifact", []
    return "source_change", []


def commit_group_for_path(path: str) -> str:
    normalized = path.replace("\\", "/")
    if normalized.startswith("IMServer/LoadTests/"):
        return "load-tests-and-production-evidence"
    if normalized.startswith("deploy/"):
        return "deploy-ops"
    if normalized.startswith("IMServer/Sources/") or normalized.startswith("IMServer/Tests/"):
        return "server-runtime"
    if normalized.startswith("IMServer/scripts/") or normalized.startswith("IMServer/config/"):
        return "server-ops-config"
    if normalized.startswith("IMServer/") or normalized == "IMServer/Dockerfile" or normalized == "IMServer/.dockerignore":
        return "server-packaging"
    if normalized.startswith("IMApp/") or normalized.startswith("IMClientKitAndroid/") or normalized.startswith("app/src/"):
        return "client-config"
    if normalized.startswith(".github/"):
        return "ci-workflows"
    if normalized.startswith("docs/") or normalized.endswith("README.md") or normalized == "README.md":
        return "docs"
    if normalized == "Makefile" or normalized == ".gitignore":
        return "repo-governance"
    return "misc"


def parse_porcelain_path(status: str, raw_path: str) -> str:
    if status[:1] in {"R", "C"} and " -> " in raw_path:
        return raw_path.rsplit(" -> ", 1)[-1]
    return raw_path


def parse_status_line(line: str) -> dict[str, Any]:
    status = line[:2]
    path = parse_porcelain_path(status, line[3:])
    change_type = "untracked" if status == "??" else "tracked"
    category, forbidden_kinds = category_for_path(path)
    action = "review_and_commit_or_remove"
    if category == "generated_local_artifact":
        action = "remove_or_ignore_generated_artifact"
    elif category == "forbidden_runtime_artifact":
        action = "remove_runtime_artifact_before_static_gate"
    return {
        "status": status,
        "type": change_type,
        "category": category,
        "path": path,
        "forbiddenKinds": forbidden_kinds,
        "action": action,
        "commitGroup": commit_group_for_path(path),
    }


def directory_bucket(path: str) -> str:
    parts = Path(path.replace("\\", "/")).parts
    if len(parts) >= 2:
        return "/".join(parts[:2])
    return "."


def count_rows(rows: list[dict[str, Any]], field: str) -> list[dict[str, Any]]:
    counts = Counter(str(row[field]) for row in rows)
    return [
        {"name": name, "count": count}
        for name, count in sorted(counts.items(), key=lambda item: (-item[1], item[0]))
    ]


def count_directories(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    counts = Counter(directory_bucket(str(row["path"])) for row in rows)
    return [
        {"path": path, "count": count}
        for path, count in sorted(counts.items(), key=lambda item: (-item[1], item[0]))
    ]


def inventory(
    repo_root: Path,
    commit_groups: set[str] | None = None,
    categories: set[str] | None = None,
    actions: set[str] | None = None,
    change_types: set[str] | None = None,
) -> dict[str, Any]:
    status = run_git(repo_root, ["status", "--porcelain=v1", "--untracked-files=all"])
    status_sha256 = hashlib.sha256(status.encode("utf-8")).hexdigest()
    all_rows = [parse_status_line(line) for line in status.splitlines() if line.strip()]
    rows = [
        row for row in all_rows
        if (not commit_groups or row["commitGroup"] in commit_groups)
        and (not categories or row["category"] in categories)
        and (not actions or row["action"] in actions)
        and (not change_types or row["type"] in change_types)
    ]
    tracked = [row for row in rows if row["type"] == "tracked"]
    untracked = [row for row in rows if row["type"] == "untracked"]
    generated = [row for row in rows if row["category"] == "generated_local_artifact"]
    forbidden = [row for row in rows if row["category"] == "forbidden_runtime_artifact"]
    source = [row for row in rows if row["category"] == "source_change"]
    return {
        "kind": "imserver-production-worktree-inventory",
        "repoRoot": str(repo_root),
        "status": "clean" if not rows else "dirty",
        "git": {
            "statusSha256": status_sha256,
            "dirtyCount": len(all_rows),
        },
        "filters": {
            "commitGroups": sorted(commit_groups or []),
            "categories": sorted(categories or []),
            "actions": sorted(actions or []),
            "types": sorted(change_types or []),
        },
        "summary": {
            "total": len(rows),
            "trackedModified": len(tracked),
            "untracked": len(untracked),
            "sourceChanges": len(source),
            "generatedLocalArtifacts": len(generated),
            "forbiddenRuntimeArtifacts": len(forbidden),
        },
        "actionSummary": count_rows(rows, "action"),
        "categorySummary": count_rows(rows, "category"),
        "commitGroupSummary": count_rows(rows, "commitGroup"),
        "directorySummary": count_directories(rows),
        "items": rows,
}


def render_paths(payload: dict[str, Any]) -> str:
    return "\n".join(str(row["path"]) for row in payload["items"])


def render_tracked_diff_stat(repo_root: Path, payload: dict[str, Any]) -> str:
    tracked_paths = [str(row["path"]) for row in payload["items"] if row["type"] == "tracked"]
    if not tracked_paths:
        return "tracked_diff_stat status=empty trackedModified=0"
    completed = subprocess.run(
        ["git", "diff", "--stat", "--", *tracked_paths],
        cwd=repo_root,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    output = completed.stdout.strip()
    if not output:
        return f"tracked_diff_stat status=empty trackedModified={len(tracked_paths)}"
    return output


def parse_name_status_line(line: str) -> dict[str, Any]:
    parts = line.split("\t")
    status = parts[0] if parts else ""
    path = parts[-1] if len(parts) > 1 else ""
    category, forbidden_kinds = category_for_path(path)
    return {
        "status": status,
        "path": path,
        "category": category,
        "forbiddenKinds": forbidden_kinds,
        "commitGroup": commit_group_for_path(path) if path else "",
    }


def staged_rows(repo_root: Path) -> list[dict[str, Any]]:
    output = run_git(repo_root, ["diff", "--cached", "--name-status", "--find-renames"])
    return [parse_name_status_line(line) for line in output.splitlines() if line.strip()]


def verify_staged_source_only(repo_root: Path) -> dict[str, Any]:
    rows = staged_rows(repo_root)
    for row in rows:
        if row["category"] != "source_change":
            return {
                "status": "fail",
                "reason": "staged_non_source_change",
                "stagedCount": len(rows),
                "path": row["path"],
                "category": row["category"],
                "forbiddenKinds": ",".join(row["forbiddenKinds"]) if row["forbiddenKinds"] else "-",
            }
    return {
        "status": "pass",
        "reason": "staged_source_only",
        "stagedCount": len(rows),
    }


def render_staged_verify_result(result: dict[str, Any]) -> str:
    parts = ["production_worktree_staging_verify"]
    for field in ("status", "reason", "stagedCount", "path", "category", "forbiddenKinds"):
        if field in result:
            parts.append(f"{field}={result[field]}")
    return " ".join(parts)


def verify_staged_single_group(repo_root: Path) -> dict[str, Any]:
    rows = staged_rows(repo_root)
    if not rows:
        return {"status": "fail", "reason": "staged_empty", "stagedCount": 0}
    source_result = verify_staged_source_only(repo_root)
    if source_result.get("status") != "pass":
        return source_result
    groups = sorted({str(row["commitGroup"]) for row in rows if row.get("commitGroup")})
    if len(groups) != 1:
        return {
            "status": "fail",
            "reason": "staged_multiple_commit_groups",
            "stagedCount": len(rows),
            "groups": ",".join(groups) if groups else "-",
        }
    group = groups[0]
    source_payload = inventory(repo_root, {group}, {"source_change"})
    expected_paths = {str(row["path"]) for row in source_payload["items"]}
    staged_paths = {str(row["path"]) for row in rows}
    missing_paths = sorted(expected_paths - staged_paths)
    extra_paths = sorted(staged_paths - expected_paths)
    if missing_paths:
        return {
            "status": "fail",
            "reason": "staged_plan_missing_path",
            "stagedCount": len(rows),
            "group": group,
            "expectedCount": len(expected_paths),
            "missingCount": len(missing_paths),
            "path": missing_paths[0],
        }
    if extra_paths:
        return {
            "status": "fail",
            "reason": "staged_plan_extra_path",
            "stagedCount": len(rows),
            "group": group,
            "expectedCount": len(expected_paths),
            "extraCount": len(extra_paths),
            "path": extra_paths[0],
        }
    for row in source_payload["items"]:
        status = str(row.get("status") or "")
        if status != "??" and len(status) > 1 and status[1] != " ":
            return {
                "status": "fail",
                "reason": "staged_plan_unstaged_changes",
                "stagedCount": len(rows),
                "group": group,
                "expectedCount": len(expected_paths),
                "path": row["path"],
                "worktreeStatus": status[1],
            }
    return {
        "status": "pass",
        "reason": "staged_single_commit_group",
        "stagedCount": len(rows),
        "group": group,
        "expectedCount": len(expected_paths),
        "planCheck": "source_paths_matched",
        "verifyCommand": validation_hint_for_group(group),
        "commitCommand": f"git commit -m \"{commit_subject_for_group(group)}\"",
    }


def render_staged_group_result(result: dict[str, Any]) -> str:
    parts = ["production_worktree_staged_group_verify"]
    for field in (
        "status",
        "reason",
        "stagedCount",
        "group",
        "groups",
        "expectedCount",
        "missingCount",
        "extraCount",
        "planCheck",
        "worktreeStatus",
        "verifyCommand",
        "commitCommand",
        "path",
        "category",
    ):
        if field in result:
            parts.append(f"{field}={result[field]}")
    return " ".join(parts)


def stage_dry_run_receipt(repo_root: Path, commit_groups: set[str]) -> dict[str, Any]:
    if len(commit_groups) != 1:
        return {
            "kind": "imserver-production-worktree-stage-dry-run",
            "status": "fail",
            "reason": "stage_dry_run_group_required",
            "groups": ",".join(sorted(commit_groups)) if commit_groups else "-",
        }
    group = next(iter(commit_groups))
    payload = inventory(repo_root, {group}, {"source_change"})
    paths = sorted(str(row["path"]) for row in payload["items"])
    if not paths:
        return {
            "kind": "imserver-production-worktree-stage-dry-run",
            "status": "fail",
            "reason": "stage_dry_run_no_source_changes",
            "group": group,
            "repoRoot": str(repo_root),
            "git": payload.get("git") or {},
            "summary": payload["summary"],
        }
    pathspec = "".join(f"{path}\n" for path in paths)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
        handle.write(pathspec)
        pathspec_path = Path(handle.name)
    try:
        completed = subprocess.run(
            ["git", "add", "--dry-run", f"--pathspec-from-file={pathspec_path}"],
            cwd=repo_root,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    finally:
        pathspec_path.unlink(missing_ok=True)
    output = f"{completed.stdout}{completed.stderr}"
    return {
        "kind": "imserver-production-worktree-stage-dry-run",
        "status": "pass" if completed.returncode == 0 else "fail",
        "reason": "stage_dry_run_passed" if completed.returncode == 0 else "stage_dry_run_failed",
        "repoRoot": str(repo_root),
        "group": group,
        "expectedCount": len(paths),
        "paths": paths,
        "pathspecSha256": hashlib.sha256(pathspec.encode("utf-8")).hexdigest(),
        "dryRunOutputSha256": hashlib.sha256(output.encode("utf-8")).hexdigest(),
        "dryRunOutputBytes": len(output.encode("utf-8")),
        "gitAddExitCode": completed.returncode,
        "git": payload.get("git") or {},
        "summary": payload["summary"],
    }


def render_stage_dry_run_result(result: dict[str, Any]) -> str:
    parts = ["production_worktree_stage_dry_run"]
    for field in (
        "status",
        "reason",
        "group",
        "groups",
        "expectedCount",
        "pathspecSha256",
        "dryRunOutputSha256",
        "dryRunOutputBytes",
        "gitAddExitCode",
    ):
        if field in result:
            parts.append(f"{field}={result[field]}")
    summary = result.get("summary")
    if isinstance(summary, dict):
        for field in ("trackedModified", "untracked", "sourceChanges"):
            if field in summary:
                parts.append(f"{field}={summary[field]}")
    return " ".join(parts)


def verify_stage_dry_run_receipt(path: Path, expected: dict[str, Any]) -> dict[str, Any]:
    if not path.is_file():
        return {"status": "fail", "reason": "stage_dry_run_json_missing", "path": str(path)}
    try:
        actual = read_json(path)
    except Exception as error:  # noqa: BLE001 - CLI verifier should surface the exact parse failure.
        return {"status": "fail", "reason": "stage_dry_run_json_invalid", "path": str(path), "error": str(error)}
    if actual.get("kind") != "imserver-production-worktree-stage-dry-run":
        return {
            "status": "fail",
            "reason": "stage_dry_run_json_kind_mismatch",
            "path": str(path),
            "expected": "imserver-production-worktree-stage-dry-run",
            "actual": actual.get("kind"),
        }
    actual_git = actual.get("git") if isinstance(actual.get("git"), dict) else {}
    expected_git = expected.get("git") if isinstance(expected.get("git"), dict) else {}
    if actual_git.get("statusSha256") != expected_git.get("statusSha256"):
        return {
            "status": "fail",
            "reason": "stage_dry_run_json_git_status_mismatch",
            "path": str(path),
            "group": expected.get("group"),
            "expectedStatusSha256": expected_git.get("statusSha256"),
            "actualStatusSha256": actual_git.get("statusSha256"),
            "expectedDirtyCount": expected_git.get("dirtyCount"),
            "actualDirtyCount": actual_git.get("dirtyCount"),
        }
    if actual != expected:
        return {
            "status": "fail",
            "reason": "stage_dry_run_json_stale_or_mismatched",
            "path": str(path),
            "group": expected.get("group"),
            "expectedSummary": expected.get("summary"),
            "actualSummary": actual.get("summary"),
            "expectedPathspecSha256": expected.get("pathspecSha256"),
            "actualPathspecSha256": actual.get("pathspecSha256"),
        }
    return {
        "status": "pass",
        "reason": "stage_dry_run_json_current",
        "path": str(path),
        "group": expected.get("group"),
        "expectedCount": expected.get("expectedCount"),
    }


def render_verify_stage_dry_run_result(result: dict[str, Any]) -> str:
    parts = ["production_worktree_stage_dry_run_verify"]
    for field in (
        "status",
        "reason",
        "path",
        "group",
        "expectedCount",
        "expectedStatusSha256",
        "actualStatusSha256",
        "expectedDirtyCount",
        "actualDirtyCount",
        "expectedPathspecSha256",
        "actualPathspecSha256",
        "expected",
        "actual",
    ):
        if field in result:
            parts.append(f"{field}={result[field]}")
    for field in ("expectedSummary", "actualSummary", "error"):
        if field in result:
            parts.append(f"{field}={json.dumps(result[field], ensure_ascii=False, sort_keys=True)}")
    return " ".join(parts)


def source_commit_groups(payload: dict[str, Any]) -> list[str]:
    return [
        str(group["name"])
        for group in build_plan_groups(payload)
        if int(group.get("sourceChanges") or 0) > 0
    ]


def stage_dry_run_batch_receipt(repo_root: Path) -> dict[str, Any]:
    payload = inventory(repo_root)
    groups = source_commit_groups(payload)
    receipts = [stage_dry_run_receipt(repo_root, {group}) for group in groups]
    failed = [receipt for receipt in receipts if receipt.get("status") != "pass"]
    total_paths = sum(int(receipt.get("expectedCount") or 0) for receipt in receipts)
    group_fingerprints = [
        f"{receipt.get('group')}:{receipt.get('pathspecSha256')}:{receipt.get('dryRunOutputSha256')}"
        for receipt in receipts
    ]
    return {
        "kind": "imserver-production-worktree-stage-dry-run-batch",
        "status": "pass" if not failed else "fail",
        "reason": "stage_dry_run_batch_passed" if not failed else "stage_dry_run_batch_failed",
        "repoRoot": str(repo_root),
        "git": payload.get("git") or {},
        "summary": payload["summary"],
        "groupCount": len(receipts),
        "failedGroupCount": len(failed),
        "totalExpectedCount": total_paths,
        "groupsSha256": hashlib.sha256("\n".join(group_fingerprints).encode("utf-8")).hexdigest(),
        "groups": receipts,
    }


def render_stage_dry_run_batch_result(result: dict[str, Any]) -> str:
    parts = ["production_worktree_stage_dry_run_batch"]
    for field in (
        "status",
        "reason",
        "groupCount",
        "failedGroupCount",
        "totalExpectedCount",
        "groupsSha256",
    ):
        if field in result:
            parts.append(f"{field}={result[field]}")
    summary = result.get("summary")
    if isinstance(summary, dict):
        for field in ("trackedModified", "untracked", "sourceChanges"):
            if field in summary:
                parts.append(f"{field}={summary[field]}")
    return " ".join(parts)


def verify_stage_dry_run_batch_receipt(path: Path, expected: dict[str, Any]) -> dict[str, Any]:
    if not path.is_file():
        return {"status": "fail", "reason": "stage_dry_run_batch_json_missing", "path": str(path)}
    try:
        actual = read_json(path)
    except Exception as error:  # noqa: BLE001 - CLI verifier should surface the exact parse failure.
        return {"status": "fail", "reason": "stage_dry_run_batch_json_invalid", "path": str(path), "error": str(error)}
    if actual.get("kind") != "imserver-production-worktree-stage-dry-run-batch":
        return {
            "status": "fail",
            "reason": "stage_dry_run_batch_json_kind_mismatch",
            "path": str(path),
            "expected": "imserver-production-worktree-stage-dry-run-batch",
            "actual": actual.get("kind"),
        }
    actual_git = actual.get("git") if isinstance(actual.get("git"), dict) else {}
    expected_git = expected.get("git") if isinstance(expected.get("git"), dict) else {}
    if actual_git.get("statusSha256") != expected_git.get("statusSha256"):
        return {
            "status": "fail",
            "reason": "stage_dry_run_batch_json_git_status_mismatch",
            "path": str(path),
            "expectedStatusSha256": expected_git.get("statusSha256"),
            "actualStatusSha256": actual_git.get("statusSha256"),
            "expectedDirtyCount": expected_git.get("dirtyCount"),
            "actualDirtyCount": actual_git.get("dirtyCount"),
        }
    if actual != expected:
        return {
            "status": "fail",
            "reason": "stage_dry_run_batch_json_stale_or_mismatched",
            "path": str(path),
            "expectedSummary": expected.get("summary"),
            "actualSummary": actual.get("summary"),
            "expectedGroupsSha256": expected.get("groupsSha256"),
            "actualGroupsSha256": actual.get("groupsSha256"),
        }
    return {
        "status": "pass",
        "reason": "stage_dry_run_batch_json_current",
        "path": str(path),
        "groupCount": expected.get("groupCount"),
        "totalExpectedCount": expected.get("totalExpectedCount"),
    }


def render_verify_stage_dry_run_batch_result(result: dict[str, Any]) -> str:
    parts = ["production_worktree_stage_dry_run_batch_verify"]
    for field in (
        "status",
        "reason",
        "path",
        "groupCount",
        "totalExpectedCount",
        "expectedStatusSha256",
        "actualStatusSha256",
        "expectedDirtyCount",
        "actualDirtyCount",
        "expectedGroupsSha256",
        "actualGroupsSha256",
        "expected",
        "actual",
    ):
        if field in result:
            parts.append(f"{field}={result[field]}")
    for field in ("expectedSummary", "actualSummary", "error"):
        if field in result:
            parts.append(f"{field}={json.dumps(result[field], ensure_ascii=False, sort_keys=True)}")
    return " ".join(parts)


def validation_hint_for_group(group: str) -> str:
    hints = {
        "load-tests-and-production-evidence": "make check-production-worktree-inventory && python3 scripts/validate_production_workflows.py --self-test",
        "deploy-ops": "make check-production-ops",
        "server-runtime": "make test-server",
        "server-ops-config": "cd IMServer && ./scripts/production_env_preflight_test.sh",
        "client-config": "make validate-ios-network-config && make validate-android-network-config",
        "ci-workflows": "python3 scripts/validate_production_workflows.py",
        "server-packaging": "make check-imserver-production-release-gate",
        "docs": "python3 scripts/validate_production_workflows.py",
        "repo-governance": "make check-production-worktree-inventory && python3 scripts/validate_production_workflows.py",
        "misc": "python3 scripts/validate_production_workflows.py",
    }
    return hints.get(group, "python3 scripts/validate_production_workflows.py")


def commit_subject_for_group(group: str) -> str:
    subjects = {
        "load-tests-and-production-evidence": "test(production): add load test evidence gates",
        "deploy-ops": "ops(deploy): harden production deployment scripts",
        "server-runtime": "feat(server): harden production runtime paths",
        "server-ops-config": "ops(server): harden production config checks",
        "client-config": "chore(client): validate production network config",
        "ci-workflows": "ci: add production gate workflows",
        "server-packaging": "build(server): harden production packaging",
        "docs": "docs: document production operations",
        "repo-governance": "chore(repo): add production governance checks",
        "misc": "chore: align production readiness support",
    }
    return subjects.get(group, f"chore: update {group}")


def pathspec_file_for_group(group: str) -> str:
    return f"/tmp/imserver-worktree-{group}.paths"


def build_plan_groups(payload: dict[str, Any]) -> list[dict[str, Any]]:
    groups: list[dict[str, Any]] = []
    for row in payload["commitGroupSummary"]:
        group = row["name"]
        count = row["count"]
        pathspec_file = pathspec_file_for_group(group)
        commit_subject = commit_subject_for_group(group)
        group_items = [item for item in payload["items"] if item["commitGroup"] == group]
        category_counts = Counter(str(item["category"]) for item in group_items)
        source_count = category_counts.get("source_change", 0)
        generated_count = category_counts.get("generated_local_artifact", 0)
        forbidden_count = category_counts.get("forbidden_runtime_artifact", 0)
        source_tracked_count = sum(
            1 for item in group_items
            if item["category"] == "source_change" and item["type"] == "tracked"
        )
        source_untracked_count = sum(
            1 for item in group_items
            if item["category"] == "source_change" and item["type"] == "untracked"
        )
        commands = {
            "reviewCommand": f"make production-worktree-inventory PRODUCTION_WORKTREE_INVENTORY_ARGS='--group {group}'",
            "pathsCommand": f"make production-worktree-inventory PRODUCTION_WORKTREE_INVENTORY_ARGS='--group {group} --paths-only'",
            "verifyCommand": validation_hint_for_group(group),
        }
        actions: list[str] = []
        if source_count:
            commands["sourcePathsCommand"] = f"make production-worktree-inventory PRODUCTION_WORKTREE_INVENTORY_ARGS='--group {group} --category source_change --paths-only'"
            commands["sourceTrackedDiffCommand"] = f"make production-worktree-inventory PRODUCTION_WORKTREE_INVENTORY_ARGS='--group {group} --category source_change --type tracked --tracked-diff-stat'"
            commands["stageDryRunCommand"] = f"make production-worktree-inventory PRODUCTION_WORKTREE_INVENTORY_ARGS='--group {group} --category source_change --paths-only' > {pathspec_file} && git add --dry-run --pathspec-from-file={pathspec_file}"
            commands["stageDryRunReceiptCommand"] = f"make production-worktree-stage-dry-run PRODUCTION_WORKTREE_INVENTORY_ARGS='--group {group}'"
            commands["stageCommand"] = f"make production-worktree-inventory PRODUCTION_WORKTREE_INVENTORY_ARGS='--group {group} --category source_change --paths-only' > {pathspec_file} && git add --pathspec-from-file={pathspec_file}"
            commands["commitCommand"] = f"git commit -m \"{commit_subject}\""
            if source_untracked_count:
                commands["sourceUntrackedPathsCommand"] = f"make production-worktree-inventory PRODUCTION_WORKTREE_INVENTORY_ARGS='--group {group} --category source_change --type untracked --paths-only'"
        else:
            actions.append("no_source_changes_to_stage")
        if generated_count:
            commands["generatedArtifactsCommand"] = f"make production-worktree-inventory PRODUCTION_WORKTREE_INVENTORY_ARGS='--group {group} --category generated_local_artifact --paths-only'"
            actions.append("remove_or_ignore_generated_artifact")
        if forbidden_count:
            commands["forbiddenArtifactsCommand"] = f"make production-worktree-inventory PRODUCTION_WORKTREE_INVENTORY_ARGS='--group {group} --category forbidden_runtime_artifact --paths-only'"
            actions.append("remove_runtime_artifact_before_static_gate")
        groups.append({
            "name": group,
            "count": count,
            "sourceChanges": source_count,
            "sourceTracked": source_tracked_count,
            "sourceUntracked": source_untracked_count,
            "generatedLocalArtifacts": generated_count,
            "forbiddenRuntimeArtifacts": forbidden_count,
            "pathspecFile": pathspec_file,
            "commitSubject": commit_subject if source_count else "",
            "commands": commands,
            "actions": actions,
        })
    return groups


def plan_payload(payload: dict[str, Any]) -> dict[str, Any]:
    return {
        "kind": "imserver-production-worktree-plan",
        "repoRoot": payload["repoRoot"],
        "status": payload["status"],
        "git": payload.get("git") or {},
        "filters": payload["filters"],
        "summary": payload["summary"],
        "groups": build_plan_groups(payload),
    }


def render_plan(payload: dict[str, Any]) -> str:
    lines = [
        "production_worktree_plan",
        "note=This plan is read-only. Review files before staging or committing.",
    ]
    for group in build_plan_groups(payload):
        lines.extend([
            f"group name={group['name']} count={group['count']} sourceChanges={group['sourceChanges']} sourceTracked={group['sourceTracked']} sourceUntracked={group['sourceUntracked']} generatedLocalArtifacts={group['generatedLocalArtifacts']} forbiddenRuntimeArtifacts={group['forbiddenRuntimeArtifacts']}",
            f"reviewCommand={group['commands']['reviewCommand']}",
            f"pathsCommand={group['commands']['pathsCommand']}",
            f"verifyCommand={group['commands']['verifyCommand']}",
        ])
        commands = group["commands"]
        if group["sourceChanges"]:
            lines.extend([
                f"sourcePathsCommand={commands['sourcePathsCommand']}",
                f"sourceTrackedDiffCommand={commands['sourceTrackedDiffCommand']}",
                f"stageDryRunCommand={commands['stageDryRunCommand']}",
                f"stageDryRunReceiptCommand={commands['stageDryRunReceiptCommand']}",
                f"stageCommand={commands['stageCommand']}",
                f"commitSubject={group['commitSubject']}",
                f"commitCommand={commands['commitCommand']}",
            ])
            if "sourceUntrackedPathsCommand" in commands:
                lines.append(f"sourceUntrackedPathsCommand={commands['sourceUntrackedPathsCommand']}")
        else:
            lines.append("sourceChangesAction=no_source_changes_to_stage")
        if "generatedArtifactsCommand" in commands:
            lines.extend([
                f"generatedArtifactsCommand={commands['generatedArtifactsCommand']}",
                "generatedArtifactsAction=remove_or_ignore_generated_artifact",
            ])
        if "forbiddenArtifactsCommand" in commands:
            lines.extend([
                f"forbiddenArtifactsCommand={commands['forbiddenArtifactsCommand']}",
                "forbiddenArtifactsAction=remove_runtime_artifact_before_static_gate",
            ])
    return "\n".join(lines)


def shell_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def commit_runbook(payload: dict[str, Any]) -> str:
    groups = [group for group in build_plan_groups(payload) if int(group.get("sourceChanges") or 0) > 0]
    lines = [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        "",
        "# Generated by production_worktree_inventory.py. Review before running.",
        "# This script stages and commits source_change groups one at a time.",
        "",
        'if [[ "${IMSERVER_WORKTREE_RUNBOOK_CONFIRMED:-}" != "reviewed" ]]; then',
        "  printf '%s\\n' 'Refusing to run commit runbook without IMSERVER_WORKTREE_RUNBOOK_CONFIRMED=reviewed.' >&2",
        "  exit 2",
        "fi",
        "",
        "make production-worktree-plan",
        "make production-worktree-stage-dry-run-batch",
        "make verify-production-worktree-stage-dry-run-batch",
        "",
    ]
    for group in groups:
        group_name = str(group["name"])
        commands = group["commands"]
        lines.extend([
            f"# group: {group_name}",
            f"# sourceChanges={group['sourceChanges']} sourceTracked={group['sourceTracked']} sourceUntracked={group['sourceUntracked']}",
            str(commands["reviewCommand"]),
            str(commands["sourceTrackedDiffCommand"]),
        ])
        if "sourceUntrackedPathsCommand" in commands:
            lines.append(str(commands["sourceUntrackedPathsCommand"]))
        lines.extend([
            str(commands["stageDryRunCommand"]),
            str(commands["stageDryRunReceiptCommand"]),
            f"make verify-production-worktree-stage-dry-run PRODUCTION_WORKTREE_INVENTORY_ARGS={shell_quote('--group ' + group_name)}",
            str(commands["stageCommand"]),
            "make verify-production-worktree-staging",
            "make verify-production-worktree-staged-group",
            f"( {commands['verifyCommand']} )",
            str(commands["commitCommand"]),
            "",
        ])
    lines.extend([
        "make validate-production-static",
        "python3 IMServer/LoadTests/production_completion_status.py",
        "",
    ])
    return "\n".join(lines)


def verify_commit_runbook(path: Path, expected: str) -> dict[str, Any]:
    if not path.is_file():
        return {"status": "fail", "reason": "commit_runbook_missing", "path": str(path)}
    try:
        actual = path.read_text(encoding="utf-8")
    except Exception as error:  # noqa: BLE001 - CLI verifier should surface the exact read failure.
        return {"status": "fail", "reason": "commit_runbook_invalid", "path": str(path), "error": str(error)}
    if actual != expected:
        return {
            "status": "fail",
            "reason": "commit_runbook_stale_or_mismatched",
            "path": str(path),
            "expectedSha256": hashlib.sha256(expected.encode("utf-8")).hexdigest(),
            "actualSha256": hashlib.sha256(actual.encode("utf-8")).hexdigest(),
        }
    return {
        "status": "pass",
        "reason": "commit_runbook_current",
        "path": str(path),
        "sha256": hashlib.sha256(actual.encode("utf-8")).hexdigest(),
    }


def render_verify_commit_runbook_result(result: dict[str, Any]) -> str:
    parts = ["production_worktree_commit_runbook_verify"]
    for field in ("status", "reason", "path", "sha256", "expectedSha256", "actualSha256"):
        if field in result:
            parts.append(f"{field}={result[field]}")
    if "error" in result:
        parts.append(f"error={json.dumps(result['error'], ensure_ascii=False)}")
    return " ".join(parts)


def render_text(payload: dict[str, Any], limit: int) -> str:
    summary = payload["summary"]
    groups = ",".join(payload.get("filters", {}).get("commitGroups", [])) or "-"
    categories = ",".join(payload.get("filters", {}).get("categories", [])) or "-"
    actions = ",".join(payload.get("filters", {}).get("actions", [])) or "-"
    change_types = ",".join(payload.get("filters", {}).get("types", [])) or "-"
    lines = [
        "production_worktree_inventory "
        f"status={payload['status']} "
        f"groups={groups} "
        f"categories={categories} "
        f"actions={actions} "
        f"types={change_types} "
        f"trackedModified={summary['trackedModified']} "
        f"untracked={summary['untracked']} "
        f"sourceChanges={summary['sourceChanges']} "
        f"generatedLocalArtifacts={summary['generatedLocalArtifacts']} "
        f"forbiddenRuntimeArtifacts={summary['forbiddenRuntimeArtifacts']} "
        f"total={summary['total']}",
    ]
    for row in payload["actionSummary"]:
        lines.append(f"action_summary action={row['name']} count={row['count']}")
    for row in payload["commitGroupSummary"]:
        lines.append(f"commit_group_summary group={row['name']} count={row['count']}")
    for row in payload["directorySummary"][:10]:
        lines.append(f"directory_summary path={row['path']} count={row['count']}")
    for row in payload["items"][:limit]:
        forbidden = ",".join(row["forbiddenKinds"]) if row["forbiddenKinds"] else "-"
        lines.append(
            "item "
            f"type={row['type']} "
            f"status={row['status'].strip() or '-'} "
            f"category={row['category']} "
            f"action={row['action']} "
            f"commitGroup={row['commitGroup']} "
            f"forbiddenKinds={forbidden} "
            f"path={row['path']}"
        )
    remaining = len(payload["items"]) - limit
    if remaining > 0:
        lines.append(f"items_more count={remaining}")
    return "\n".join(lines)


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(path)


def read_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return payload


def verify_plan_payload(path: Path, expected: dict[str, Any]) -> dict[str, Any]:
    if not path.is_file():
        return {"status": "fail", "reason": "plan_json_missing", "path": str(path)}
    try:
        actual = read_json(path)
    except Exception as error:  # noqa: BLE001 - CLI verifier should surface the exact parse failure.
        return {"status": "fail", "reason": "plan_json_invalid", "path": str(path), "error": str(error)}
    if actual.get("kind") != "imserver-production-worktree-plan":
        return {
            "status": "fail",
            "reason": "plan_json_kind_mismatch",
            "path": str(path),
            "expected": "imserver-production-worktree-plan",
            "actual": actual.get("kind"),
        }
    actual_git = actual.get("git") if isinstance(actual.get("git"), dict) else {}
    expected_git = expected.get("git") if isinstance(expected.get("git"), dict) else {}
    if actual_git.get("statusSha256") != expected_git.get("statusSha256"):
        return {
            "status": "fail",
            "reason": "plan_json_git_status_mismatch",
            "path": str(path),
            "expectedStatusSha256": expected_git.get("statusSha256"),
            "actualStatusSha256": actual_git.get("statusSha256"),
            "expectedDirtyCount": expected_git.get("dirtyCount"),
            "actualDirtyCount": actual_git.get("dirtyCount"),
        }
    if actual != expected:
        return {
            "status": "fail",
            "reason": "plan_json_stale_or_mismatched",
            "path": str(path),
            "expectedSummary": expected.get("summary"),
            "actualSummary": actual.get("summary"),
            "expectedGroups": len(expected.get("groups") or []),
            "actualGroups": len(actual.get("groups") or []),
        }
    contract_result = verify_plan_command_contract(actual)
    if contract_result is not None:
        contract_result["path"] = str(path)
        return contract_result
    return {
        "status": "pass",
        "reason": "plan_json_current",
        "path": str(path),
        "groups": len(actual.get("groups") or []),
        "total": (actual.get("summary") or {}).get("total"),
    }


def verify_plan_command_contract(payload: dict[str, Any]) -> dict[str, Any] | None:
    groups = payload.get("groups")
    if not isinstance(groups, list):
        return {"status": "fail", "reason": "plan_json_groups_invalid"}
    for index, group in enumerate(groups):
        if not isinstance(group, dict):
            return {"status": "fail", "reason": "plan_json_group_invalid", "groupIndex": index}
        group_name = str(group.get("name") or "")
        commands = group.get("commands")
        actions = group.get("actions")
        if not isinstance(commands, dict):
            return {"status": "fail", "reason": "plan_json_commands_invalid", "group": group_name}
        if not isinstance(actions, list):
            return {"status": "fail", "reason": "plan_json_actions_invalid", "group": group_name}
        required_base = ("reviewCommand", "pathsCommand", "verifyCommand")
        for command_name in required_base:
            if not str(commands.get(command_name) or "").strip():
                return {
                    "status": "fail",
                    "reason": "plan_json_required_command_missing",
                    "group": group_name,
                    "command": command_name,
                }
        source_changes = int(group.get("sourceChanges") or 0)
        source_untracked = int(group.get("sourceUntracked") or 0)
        generated = int(group.get("generatedLocalArtifacts") or 0)
        forbidden = int(group.get("forbiddenRuntimeArtifacts") or 0)
        if source_changes > 0:
            required_source = (
                "sourcePathsCommand",
                "sourceTrackedDiffCommand",
                "stageDryRunCommand",
                "stageDryRunReceiptCommand",
                "stageCommand",
                "commitCommand",
            )
            for command_name in required_source:
                if not str(commands.get(command_name) or "").strip():
                    return {
                        "status": "fail",
                        "reason": "plan_json_required_command_missing",
                        "group": group_name,
                        "command": command_name,
                    }
            stage = str(commands["stageCommand"])
            dry_run = str(commands["stageDryRunCommand"])
            if "--category source_change --paths-only" not in stage or "--category source_change --paths-only" not in dry_run:
                return {"status": "fail", "reason": "plan_json_stage_not_source_only", "group": group_name}
            if "git add --dry-run --pathspec-from-file=" not in dry_run:
                return {"status": "fail", "reason": "plan_json_stage_dry_run_missing", "group": group_name}
            receipt_command = str(commands["stageDryRunReceiptCommand"])
            if "make production-worktree-stage-dry-run" not in receipt_command or f"--group {group_name}" not in receipt_command:
                return {"status": "fail", "reason": "plan_json_stage_dry_run_receipt_invalid", "group": group_name}
            if "git add --pathspec-from-file=" not in stage or "--dry-run" in stage:
                return {"status": "fail", "reason": "plan_json_stage_command_invalid", "group": group_name}
            if source_untracked > 0 and not str(commands.get("sourceUntrackedPathsCommand") or "").strip():
                return {
                    "status": "fail",
                    "reason": "plan_json_required_command_missing",
                    "group": group_name,
                    "command": "sourceUntrackedPathsCommand",
                }
        else:
            forbidden_source_commands = ("stageDryRunCommand", "stageCommand", "commitCommand", "sourcePathsCommand")
            for command_name in forbidden_source_commands:
                if command_name in commands:
                    return {
                        "status": "fail",
                        "reason": "plan_json_unexpected_source_command",
                        "group": group_name,
                        "command": command_name,
                    }
            if "no_source_changes_to_stage" not in [str(action) for action in actions]:
                return {"status": "fail", "reason": "plan_json_no_source_action_missing", "group": group_name}
        if generated > 0 and not str(commands.get("generatedArtifactsCommand") or "").strip():
            return {
                "status": "fail",
                "reason": "plan_json_required_command_missing",
                "group": group_name,
                "command": "generatedArtifactsCommand",
            }
        if forbidden > 0 and not str(commands.get("forbiddenArtifactsCommand") or "").strip():
            return {
                "status": "fail",
                "reason": "plan_json_required_command_missing",
                "group": group_name,
                "command": "forbiddenArtifactsCommand",
            }
    return None


def render_verify_plan_result(result: dict[str, Any]) -> str:
    parts = ["production_worktree_plan_verify"]
    for field in (
        "status",
        "reason",
        "path",
        "groups",
        "total",
        "expectedGroups",
        "actualGroups",
        "expectedStatusSha256",
        "actualStatusSha256",
        "expectedDirtyCount",
        "actualDirtyCount",
        "group",
        "groupIndex",
        "command",
    ):
        if field in result:
            parts.append(f"{field}={result[field]}")
    for field in ("expectedSummary", "actualSummary", "error"):
        if field in result:
            parts.append(f"{field}={json.dumps(result[field], ensure_ascii=False, sort_keys=True)}")
    return " ".join(parts)


def self_test() -> None:
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)
        subprocess.run(["git", "config", "user.email", "worktree-inventory@example.invalid"], cwd=root, check=True)
        subprocess.run(["git", "config", "user.name", "Worktree Inventory Self Test"], cwd=root, check=True)
        source = root / "src.txt"
        source.write_text("committed\n", encoding="utf-8")
        subprocess.run(["git", "add", "src.txt"], cwd=root, check=True)
        subprocess.run(["git", "commit", "-m", "source fixture", "-q"], cwd=root, check=True)
        source.write_text("modified\n", encoding="utf-8")
        generated = root / "IMServer/LoadTests/results/artifact.txt"
        generated.parent.mkdir(parents=True, exist_ok=True)
        generated.write_text("generated\n", encoding="utf-8")
        forbidden = root / "IMServer/LoadTests/accounts/users.txt"
        forbidden.parent.mkdir(parents=True, exist_ok=True)
        forbidden.write_text("email,password\n", encoding="utf-8")

        payload = inventory(root)
        summary = payload["summary"]
        expected = {
            "total": 3,
            "trackedModified": 1,
            "untracked": 2,
            "sourceChanges": 1,
            "generatedLocalArtifacts": 1,
            "forbiddenRuntimeArtifacts": 1,
        }
        for field, value in expected.items():
            if summary[field] != value:
                raise SystemExit(
                    "production_worktree_inventory_self_test result=fail "
                    f"field={field} expected={value} actual={summary[field]}"
                )
        action_summary = {row["name"]: row["count"] for row in payload["actionSummary"]}
        expected_actions = {
            "review_and_commit_or_remove": 1,
            "remove_or_ignore_generated_artifact": 1,
            "remove_runtime_artifact_before_static_gate": 1,
        }
        if action_summary != expected_actions:
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"field=actionSummary expected={expected_actions} actual={action_summary}"
            )
        category_summary = {row["name"]: row["count"] for row in payload["categorySummary"]}
        expected_categories = {
            "source_change": 1,
            "generated_local_artifact": 1,
            "forbidden_runtime_artifact": 1,
        }
        if category_summary != expected_categories:
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"field=categorySummary expected={expected_categories} actual={category_summary}"
            )
        commit_group_summary = {row["name"]: row["count"] for row in payload["commitGroupSummary"]}
        expected_commit_groups = {
            "misc": 1,
            "load-tests-and-production-evidence": 2,
        }
        if commit_group_summary != expected_commit_groups:
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"field=commitGroupSummary expected={expected_commit_groups} actual={commit_group_summary}"
            )
        directory_summary = {row["path"]: row["count"] for row in payload["directorySummary"]}
        for bucket in ("IMServer/LoadTests", "."):
            if directory_summary.get(bucket) is None:
                raise SystemExit(
                    "production_worktree_inventory_self_test result=fail "
                    f"field=directorySummary missingBucket={bucket} actual={directory_summary}"
                )
        text = render_text(payload, limit=10)
        for marker in (
            "production_worktree_inventory status=dirty",
            "action_summary action=remove_runtime_artifact_before_static_gate count=1",
            "commit_group_summary group=load-tests-and-production-evidence count=2",
            "directory_summary path=IMServer/LoadTests count=2",
            "category=generated_local_artifact",
            "category=forbidden_runtime_artifact",
            "commitGroup=load-tests-and-production-evidence",
            "action=remove_runtime_artifact_before_static_gate",
        ):
            if marker not in text:
                raise SystemExit(
                    "production_worktree_inventory_self_test result=fail "
                    f"reason=render_marker_missing marker={marker}"
                )
        filtered = inventory(root, {"load-tests-and-production-evidence"})
        filtered_summary = filtered["summary"]
        if filtered_summary["total"] != 2 or filtered_summary["trackedModified"] != 0 or filtered_summary["untracked"] != 2:
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"field=filteredSummary actual={filtered_summary}"
            )
        filtered_text = render_text(filtered, limit=10)
        if "groups=load-tests-and-production-evidence categories=- actions=- types=-" not in filtered_text:
            raise SystemExit("production_worktree_inventory_self_test result=fail reason=filtered_group_render_missing")
        filtered_paths = render_paths(filtered)
        if "IMServer/LoadTests/results/artifact.txt" not in filtered_paths or "IMServer/LoadTests/accounts/users.txt" not in filtered_paths:
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=filtered_paths_missing paths={filtered_paths}"
            )
        source_filtered = inventory(root, categories={"source_change"})
        source_summary = source_filtered["summary"]
        if source_summary["total"] != 1 or source_summary["trackedModified"] != 1 or source_summary["untracked"] != 0:
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"field=sourceFilteredSummary actual={source_summary}"
            )
        source_text = render_text(source_filtered, limit=10)
        if "categories=source_change" not in source_text or "actions=-" not in source_text or "types=-" not in source_text:
            raise SystemExit("production_worktree_inventory_self_test result=fail reason=source_filter_render_missing")
        tracked_filtered = inventory(root, categories={"source_change"}, change_types={"tracked"})
        tracked_summary = tracked_filtered["summary"]
        if tracked_summary["total"] != 1 or tracked_summary["trackedModified"] != 1 or tracked_summary["untracked"] != 0:
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"field=trackedFilteredSummary actual={tracked_summary}"
            )
        tracked_diff = render_tracked_diff_stat(root, tracked_filtered)
        if "src.txt" not in tracked_diff or "1 file changed" not in tracked_diff:
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=tracked_diff_stat_missing diff={tracked_diff}"
            )
        untracked_filtered = inventory(root, {"load-tests-and-production-evidence"}, change_types={"untracked"})
        untracked_summary = untracked_filtered["summary"]
        if untracked_summary["total"] != 2 or untracked_summary["trackedModified"] != 0 or untracked_summary["untracked"] != 2:
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"field=untrackedFilteredSummary actual={untracked_summary}"
            )
        empty_diff = render_tracked_diff_stat(root, untracked_filtered)
        if empty_diff != "tracked_diff_stat status=empty trackedModified=0":
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=empty_tracked_diff_stat_mismatch diff={empty_diff}"
            )
        generated_filtered = inventory(root, {"load-tests-and-production-evidence"}, {"generated_local_artifact"})
        generated_paths = render_paths(generated_filtered)
        if generated_filtered["summary"]["total"] != 1 or "IMServer/LoadTests/results/artifact.txt" not in generated_paths:
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"field=generatedFiltered actual={generated_filtered['summary']} paths={generated_paths}"
            )
        action_filtered = inventory(root, actions={"remove_runtime_artifact_before_static_gate"})
        action_paths = render_paths(action_filtered)
        if action_filtered["summary"]["total"] != 1 or "IMServer/LoadTests/accounts/users.txt" not in action_paths:
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"field=actionFiltered actual={action_filtered['summary']} paths={action_paths}"
            )
        plan = render_plan(payload)
        for marker in (
            "production_worktree_plan",
            "group name=load-tests-and-production-evidence count=2 sourceChanges=0 sourceTracked=0 sourceUntracked=0 generatedLocalArtifacts=1 forbiddenRuntimeArtifacts=1",
            "reviewCommand=make production-worktree-inventory PRODUCTION_WORKTREE_INVENTORY_ARGS='--group load-tests-and-production-evidence'",
            "pathsCommand=make production-worktree-inventory PRODUCTION_WORKTREE_INVENTORY_ARGS='--group load-tests-and-production-evidence --paths-only'",
            "sourceChangesAction=no_source_changes_to_stage",
            "generatedArtifactsCommand=make production-worktree-inventory PRODUCTION_WORKTREE_INVENTORY_ARGS='--group load-tests-and-production-evidence --category generated_local_artifact --paths-only'",
            "generatedArtifactsAction=remove_or_ignore_generated_artifact",
            "forbiddenArtifactsCommand=make production-worktree-inventory PRODUCTION_WORKTREE_INVENTORY_ARGS='--group load-tests-and-production-evidence --category forbidden_runtime_artifact --paths-only'",
            "forbiddenArtifactsAction=remove_runtime_artifact_before_static_gate",
            "verifyCommand=make check-production-worktree-inventory",
        ):
            if marker not in plan:
                raise SystemExit(
                    "production_worktree_inventory_self_test result=fail "
                    f"reason=plan_marker_missing marker={marker}"
                )
        for forbidden_marker in (
            "sourceTrackedDiffCommand=make production-worktree-inventory PRODUCTION_WORKTREE_INVENTORY_ARGS='--group load-tests-and-production-evidence --category source_change --type tracked --tracked-diff-stat'",
            "stageDryRunCommand=make production-worktree-inventory PRODUCTION_WORKTREE_INVENTORY_ARGS='--group load-tests-and-production-evidence --category source_change --paths-only'",
            "stageCommand=make production-worktree-inventory PRODUCTION_WORKTREE_INVENTORY_ARGS='--group load-tests-and-production-evidence --category source_change --paths-only'",
            "commitCommand=git commit -m \"test(production): add load test evidence gates\"",
        ):
            if forbidden_marker in plan:
                raise SystemExit(
                    "production_worktree_inventory_self_test result=fail "
                    f"reason=plan_marker_unexpected marker={forbidden_marker}"
                )
        if "group name=misc count=1 sourceChanges=1 sourceTracked=1 sourceUntracked=0 generatedLocalArtifacts=0 forbiddenRuntimeArtifacts=0" not in plan:
            raise SystemExit("production_worktree_inventory_self_test result=fail reason=source_group_counts_missing")
        if "sourceTrackedDiffCommand=make production-worktree-inventory PRODUCTION_WORKTREE_INVENTORY_ARGS='--group misc --category source_change --type tracked --tracked-diff-stat'" not in plan:
            raise SystemExit("production_worktree_inventory_self_test result=fail reason=source_diff_command_missing")
        if "stageDryRunCommand=make production-worktree-inventory PRODUCTION_WORKTREE_INVENTORY_ARGS='--group misc --category source_change --paths-only' > /tmp/imserver-worktree-misc.paths && git add --dry-run --pathspec-from-file=/tmp/imserver-worktree-misc.paths" not in plan:
            raise SystemExit("production_worktree_inventory_self_test result=fail reason=source_stage_dry_run_command_missing")
        if "stageDryRunReceiptCommand=make production-worktree-stage-dry-run PRODUCTION_WORKTREE_INVENTORY_ARGS='--group misc'" not in plan:
            raise SystemExit("production_worktree_inventory_self_test result=fail reason=source_stage_dry_run_receipt_command_missing")
        if "stageCommand=make production-worktree-inventory PRODUCTION_WORKTREE_INVENTORY_ARGS='--group misc --category source_change --paths-only'" not in plan:
            raise SystemExit("production_worktree_inventory_self_test result=fail reason=source_stage_command_missing")
        if "commitCommand=git commit -m \"chore: align production readiness support\"" not in plan:
            raise SystemExit("production_worktree_inventory_self_test result=fail reason=source_commit_command_missing")
        structured_plan = plan_payload(payload)
        if structured_plan["kind"] != "imserver-production-worktree-plan":
            raise SystemExit("production_worktree_inventory_self_test result=fail reason=plan_kind_mismatch")
        if not structured_plan.get("git", {}).get("statusSha256"):
            raise SystemExit("production_worktree_inventory_self_test result=fail reason=plan_git_status_sha_missing")
        if structured_plan.get("git", {}).get("dirtyCount") != 3:
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=plan_git_dirty_count_mismatch git={structured_plan.get('git')}"
            )
        plan_groups = {row["name"]: row for row in structured_plan["groups"]}
        load_group = plan_groups.get("load-tests-and-production-evidence") or {}
        misc_group = plan_groups.get("misc") or {}
        if load_group.get("sourceChanges") != 0 or load_group.get("sourceTracked") != 0 or load_group.get("sourceUntracked") != 0:
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=plan_load_group_counts_mismatch group={load_group}"
            )
        if "stageCommand" in (load_group.get("commands") or {}):
            raise SystemExit("production_worktree_inventory_self_test result=fail reason=plan_json_stage_command_unexpected")
        if "no_source_changes_to_stage" not in (load_group.get("actions") or []):
            raise SystemExit("production_worktree_inventory_self_test result=fail reason=plan_json_source_action_missing")
        if misc_group.get("sourceChanges") != 1 or misc_group.get("sourceTracked") != 1:
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=plan_misc_group_counts_mismatch group={misc_group}"
            )
        misc_commands = misc_group.get("commands") or {}
        for command_name in ("sourceTrackedDiffCommand", "stageDryRunCommand", "stageDryRunReceiptCommand", "stageCommand", "commitCommand"):
            if command_name not in misc_commands:
                raise SystemExit(
                    "production_worktree_inventory_self_test result=fail "
                    f"reason=plan_json_command_missing command={command_name}"
                )
        stage_receipt = stage_dry_run_receipt(root, {"misc"})
        if (
            stage_receipt.get("status") != "pass"
            or stage_receipt.get("reason") != "stage_dry_run_passed"
            or stage_receipt.get("group") != "misc"
            or stage_receipt.get("expectedCount") != 1
            or stage_receipt.get("paths") != ["src.txt"]
            or not stage_receipt.get("pathspecSha256")
        ):
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=stage_dry_run_receipt_failed result={stage_receipt}"
            )
        stage_receipt_text = render_stage_dry_run_result(stage_receipt)
        if "production_worktree_stage_dry_run status=pass reason=stage_dry_run_passed group=misc expectedCount=1" not in stage_receipt_text:
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=stage_dry_run_render_failed text={stage_receipt_text}"
            )
        no_source_stage_receipt = stage_dry_run_receipt(root, {"load-tests-and-production-evidence"})
        if (
            no_source_stage_receipt.get("status") != "fail"
            or no_source_stage_receipt.get("reason") != "stage_dry_run_no_source_changes"
        ):
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=stage_dry_run_no_source_passed result={no_source_stage_receipt}"
            )
        missing_group_stage_receipt = stage_dry_run_receipt(root, set())
        if (
            missing_group_stage_receipt.get("status") != "fail"
            or missing_group_stage_receipt.get("reason") != "stage_dry_run_group_required"
        ):
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=stage_dry_run_group_required_passed result={missing_group_stage_receipt}"
            )
        stage_receipt_path = root / "stage-dry-run.json"
        write_json(stage_receipt_path, stage_receipt)
        verify_stage_receipt = verify_stage_dry_run_receipt(stage_receipt_path, stage_receipt)
        if verify_stage_receipt.get("status") != "pass" or verify_stage_receipt.get("reason") != "stage_dry_run_json_current":
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=stage_dry_run_verify_failed result={verify_stage_receipt}"
            )
        verify_stage_receipt_text = render_verify_stage_dry_run_result(verify_stage_receipt)
        if "production_worktree_stage_dry_run_verify status=pass reason=stage_dry_run_json_current" not in verify_stage_receipt_text:
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=stage_dry_run_verify_render_failed text={verify_stage_receipt_text}"
            )
        stale_stage_receipt = json.loads(json.dumps(stage_receipt))
        stale_stage_receipt["paths"] = ["other.txt"]
        write_json(stage_receipt_path, stale_stage_receipt)
        stale_stage_result = verify_stage_dry_run_receipt(stage_receipt_path, stage_receipt)
        if (
            stale_stage_result.get("status") != "fail"
            or stale_stage_result.get("reason") != "stage_dry_run_json_stale_or_mismatched"
        ):
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=stage_dry_run_stale_verify_passed result={stale_stage_result}"
            )
        stale_stage_receipt = json.loads(json.dumps(stage_receipt))
        stale_stage_receipt["git"] = dict(stale_stage_receipt["git"])
        stale_stage_receipt["git"]["statusSha256"] = "bad-sha"
        write_json(stage_receipt_path, stale_stage_receipt)
        stale_stage_git_result = verify_stage_dry_run_receipt(stage_receipt_path, stage_receipt)
        if (
            stale_stage_git_result.get("status") != "fail"
            or stale_stage_git_result.get("reason") != "stage_dry_run_json_git_status_mismatch"
        ):
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=stage_dry_run_git_verify_passed result={stale_stage_git_result}"
            )
        stage_receipt_path.unlink()
        batch_receipt = stage_dry_run_batch_receipt(root)
        if (
            batch_receipt.get("status") != "pass"
            or batch_receipt.get("reason") != "stage_dry_run_batch_passed"
            or batch_receipt.get("groupCount") != 1
            or batch_receipt.get("totalExpectedCount") != 1
            or len(batch_receipt.get("groups") or []) != 1
            or not batch_receipt.get("groupsSha256")
        ):
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=stage_dry_run_batch_failed result={batch_receipt}"
            )
        batch_text = render_stage_dry_run_batch_result(batch_receipt)
        if "production_worktree_stage_dry_run_batch status=pass reason=stage_dry_run_batch_passed groupCount=1" not in batch_text:
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=stage_dry_run_batch_render_failed text={batch_text}"
            )
        batch_receipt_path = root / "stage-dry-run-batch.json"
        write_json(batch_receipt_path, batch_receipt)
        verify_batch = verify_stage_dry_run_batch_receipt(batch_receipt_path, batch_receipt)
        if verify_batch.get("status") != "pass" or verify_batch.get("reason") != "stage_dry_run_batch_json_current":
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=stage_dry_run_batch_verify_failed result={verify_batch}"
            )
        verify_batch_text = render_verify_stage_dry_run_batch_result(verify_batch)
        if "production_worktree_stage_dry_run_batch_verify status=pass reason=stage_dry_run_batch_json_current" not in verify_batch_text:
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=stage_dry_run_batch_verify_render_failed text={verify_batch_text}"
            )
        stale_batch = json.loads(json.dumps(batch_receipt))
        stale_batch["groupsSha256"] = "bad-groups-sha"
        write_json(batch_receipt_path, stale_batch)
        stale_batch_result = verify_stage_dry_run_batch_receipt(batch_receipt_path, batch_receipt)
        if (
            stale_batch_result.get("status") != "fail"
            or stale_batch_result.get("reason") != "stage_dry_run_batch_json_stale_or_mismatched"
        ):
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=stage_dry_run_batch_stale_verify_passed result={stale_batch_result}"
            )
        stale_batch = json.loads(json.dumps(batch_receipt))
        stale_batch["git"] = dict(stale_batch["git"])
        stale_batch["git"]["statusSha256"] = "bad-sha"
        write_json(batch_receipt_path, stale_batch)
        stale_batch_git_result = verify_stage_dry_run_batch_receipt(batch_receipt_path, batch_receipt)
        if (
            stale_batch_git_result.get("status") != "fail"
            or stale_batch_git_result.get("reason") != "stage_dry_run_batch_json_git_status_mismatch"
        ):
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=stage_dry_run_batch_git_verify_passed result={stale_batch_git_result}"
            )
        batch_receipt_path.unlink()
        runbook = commit_runbook(payload)
        for marker in (
            "#!/usr/bin/env bash",
            "IMSERVER_WORKTREE_RUNBOOK_CONFIRMED=reviewed",
            "Refusing to run commit runbook without IMSERVER_WORKTREE_RUNBOOK_CONFIRMED=reviewed.",
            "make production-worktree-stage-dry-run-batch",
            "make verify-production-worktree-stage-dry-run-batch",
            "make production-worktree-inventory PRODUCTION_WORKTREE_INVENTORY_ARGS='--group misc'",
            "make verify-production-worktree-stage-dry-run PRODUCTION_WORKTREE_INVENTORY_ARGS='--group misc'",
            "make verify-production-worktree-staged-group",
            "( python3 scripts/validate_production_workflows.py )",
            "git commit -m \"chore: align production readiness support\"",
            "make validate-production-static",
        ):
            if marker not in runbook:
                raise SystemExit(
                    "production_worktree_inventory_self_test result=fail "
                    f"reason=commit_runbook_marker_missing marker={marker}"
                )
        runbook_path = root / "commit-runbook.sh"
        runbook_path.write_text(runbook, encoding="utf-8")
        verify_runbook = verify_commit_runbook(runbook_path, runbook)
        if verify_runbook.get("status") != "pass" or verify_runbook.get("reason") != "commit_runbook_current":
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=commit_runbook_verify_failed result={verify_runbook}"
            )
        verify_runbook_text = render_verify_commit_runbook_result(verify_runbook)
        if "production_worktree_commit_runbook_verify status=pass reason=commit_runbook_current" not in verify_runbook_text:
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=commit_runbook_verify_render_failed text={verify_runbook_text}"
            )
        runbook_path.write_text(runbook + "\n# stale\n", encoding="utf-8")
        stale_runbook = verify_commit_runbook(runbook_path, runbook)
        if stale_runbook.get("status") != "fail" or stale_runbook.get("reason") != "commit_runbook_stale_or_mismatched":
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=commit_runbook_stale_verify_passed result={stale_runbook}"
            )
        runbook_path.unlink()
        plan_path = root / "plan.json"
        write_json(plan_path, structured_plan)
        verify_result = verify_plan_payload(plan_path, structured_plan)
        if verify_result.get("status") != "pass":
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=plan_json_verify_failed result={verify_result}"
            )
        verify_text = render_verify_plan_result(verify_result)
        if "production_worktree_plan_verify status=pass reason=plan_json_current" not in verify_text:
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=plan_json_verify_render_failed text={verify_text}"
            )
        stale_plan = dict(structured_plan)
        stale_plan["summary"] = dict(stale_plan["summary"])
        stale_plan["summary"]["total"] = 999
        write_json(plan_path, stale_plan)
        stale_result = verify_plan_payload(plan_path, structured_plan)
        if stale_result.get("status") != "fail" or stale_result.get("reason") != "plan_json_stale_or_mismatched":
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=plan_json_stale_verify_passed result={stale_result}"
            )
        stale_plan = dict(structured_plan)
        stale_plan["git"] = dict(stale_plan["git"])
        stale_plan["git"]["statusSha256"] = "bad-sha"
        write_json(plan_path, stale_plan)
        stale_git_result = verify_plan_payload(plan_path, structured_plan)
        if stale_git_result.get("status") != "fail" or stale_git_result.get("reason") != "plan_json_git_status_mismatch":
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=plan_json_git_status_verify_passed result={stale_git_result}"
            )
        bad_contract_plan = json.loads(json.dumps(structured_plan))
        bad_misc = next(row for row in bad_contract_plan["groups"] if row["name"] == "misc")
        bad_misc["commands"].pop("stageDryRunCommand", None)
        write_json(plan_path, bad_contract_plan)
        bad_contract_result = verify_plan_payload(plan_path, bad_contract_plan)
        if (
            bad_contract_result.get("status") != "fail"
            or bad_contract_result.get("reason") != "plan_json_required_command_missing"
            or bad_contract_result.get("command") != "stageDryRunCommand"
        ):
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=plan_json_contract_verify_passed result={bad_contract_result}"
            )
        plan_path.unlink()
        clean_staged = verify_staged_source_only(root)
        if clean_staged.get("status") != "pass" or clean_staged.get("stagedCount") != 0:
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=initial_staged_verify_failed result={clean_staged}"
            )
        subprocess.run(["git", "add", "src.txt"], cwd=root, check=True)
        source_staged = verify_staged_source_only(root)
        if source_staged.get("status") != "pass" or source_staged.get("stagedCount") != 1:
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=source_staged_verify_failed result={source_staged}"
            )
        single_group = verify_staged_single_group(root)
        if (
            single_group.get("status") != "pass"
            or single_group.get("reason") != "staged_single_commit_group"
            or single_group.get("group") != "misc"
            or single_group.get("planCheck") != "source_paths_matched"
            or "commitCommand" not in single_group
            or "verifyCommand" not in single_group
        ):
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=single_group_staged_verify_failed result={single_group}"
            )
        single_group_text = render_staged_group_result(single_group)
        if "production_worktree_staged_group_verify status=pass reason=staged_single_commit_group" not in single_group_text:
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=single_group_staged_render_failed text={single_group_text}"
            )
        same_group_missing = root / "same-group.txt"
        same_group_missing.write_text("missing from staged plan\n", encoding="utf-8")
        missing_group = verify_staged_single_group(root)
        if (
            missing_group.get("status") != "fail"
            or missing_group.get("reason") != "staged_plan_missing_path"
            or missing_group.get("path") != "same-group.txt"
        ):
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=missing_group_staged_verify_passed result={missing_group}"
            )
        same_group_missing.unlink()
        source.write_text("modified after staging\n", encoding="utf-8")
        partial_group = verify_staged_single_group(root)
        if (
            partial_group.get("status") != "fail"
            or partial_group.get("reason") != "staged_plan_unstaged_changes"
            or partial_group.get("path") != "src.txt"
        ):
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=partial_group_staged_verify_passed result={partial_group}"
            )
        source.write_text("modified\n", encoding="utf-8")
        extra_group = root / "deploy/new.sh"
        extra_group.parent.mkdir(parents=True, exist_ok=True)
        extra_group.write_text("#!/usr/bin/env bash\n", encoding="utf-8")
        subprocess.run(["git", "add", "deploy/new.sh"], cwd=root, check=True)
        multi_group = verify_staged_single_group(root)
        if multi_group.get("status") != "fail" or multi_group.get("reason") != "staged_multiple_commit_groups":
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=multi_group_staged_verify_passed result={multi_group}"
            )
        subprocess.run(["git", "reset", "-q", "deploy/new.sh"], cwd=root, check=True)
        staged_text = render_staged_verify_result(source_staged)
        if "production_worktree_staging_verify status=pass reason=staged_source_only stagedCount=1" not in staged_text:
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=staged_verify_render_failed text={staged_text}"
            )
        subprocess.run(["git", "add", "IMServer/LoadTests/results/artifact.txt"], cwd=root, check=True)
        generated_staged = verify_staged_source_only(root)
        if (
            generated_staged.get("status") != "fail"
            or generated_staged.get("reason") != "staged_non_source_change"
            or generated_staged.get("category") != "generated_local_artifact"
        ):
            raise SystemExit(
                "production_worktree_inventory_self_test result=fail "
                f"reason=generated_staged_verify_passed result={generated_staged}"
            )
    print("production_worktree_inventory_self_test result=pass")


def main() -> int:
    parser = argparse.ArgumentParser(description="Inspect dirty git worktree state before production static gate.")
    parser.add_argument("--repo-root", default=".", help="Repository root. Defaults to current directory.")
    parser.add_argument("--group", action="append", default=[], help="Only include a commitGroup. May be repeated.")
    parser.add_argument("--category", action="append", default=[], help="Only include a category. May be repeated.")
    parser.add_argument("--action", action="append", default=[], help="Only include an action. May be repeated.")
    parser.add_argument("--type", action="append", default=[], choices=("tracked", "untracked"), help="Only include tracked or untracked rows. May be repeated.")
    parser.add_argument("--json-output", default="", help="Optional JSON output path.")
    parser.add_argument("--plan-json-output", default="", help="Optional JSON output path for the review plan.")
    parser.add_argument("--commit-runbook-output", default="", help="Optional shell runbook output path for commit-group execution.")
    parser.add_argument("--stage-dry-run-json-output", default="", help="Optional JSON output path for the stage dry-run receipt.")
    parser.add_argument("--stage-dry-run-batch-json-output", default="", help="Optional JSON output path for the batch stage dry-run receipt.")
    parser.add_argument("--verify-plan-json", default="", help="Verify a previously written review plan JSON against current worktree state.")
    parser.add_argument("--verify-commit-runbook", default="", help="Verify a previously written commit-group runbook against current worktree state.")
    parser.add_argument("--verify-stage-dry-run-json", default="", help="Verify a previously written stage dry-run receipt against current worktree state.")
    parser.add_argument("--verify-stage-dry-run-batch-json", default="", help="Verify a previously written batch stage dry-run receipt against current worktree state.")
    parser.add_argument("--verify-staged-source-only", action="store_true", help="Verify staged files contain source changes only.")
    parser.add_argument("--verify-staged-single-group", action="store_true", help="Verify staged files belong to exactly one source-change commit group.")
    parser.add_argument("--stage-dry-run", action="store_true", help="Run a non-mutating git add --dry-run for exactly one --group source-change path set.")
    parser.add_argument("--stage-dry-run-batch", action="store_true", help="Run non-mutating git add --dry-run receipts for every source-change commit group.")
    parser.add_argument("--paths-only", action="store_true", help="Print only matching paths.")
    parser.add_argument("--plan", action="store_true", help="Print a read-only commit-group review plan.")
    parser.add_argument("--plan-json", action="store_true", help="Print the read-only commit-group review plan as JSON.")
    parser.add_argument("--commit-runbook", action="store_true", help="Print a shell runbook for commit-group execution. Review before running.")
    parser.add_argument("--tracked-diff-stat", action="store_true", help="Print git diff --stat for matching tracked paths.")
    parser.add_argument("--limit", type=int, default=40, help="Maximum text rows to print.")
    parser.add_argument("--self-test", action="store_true", help="Run built-in checks.")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    repo_root = Path(args.repo_root).expanduser().resolve()
    if args.verify_staged_source_only:
        result = verify_staged_source_only(repo_root)
        print(render_staged_verify_result(result))
        return 0 if result.get("status") == "pass" else 1
    if args.verify_staged_single_group:
        result = verify_staged_single_group(repo_root)
        print(render_staged_group_result(result))
        return 0 if result.get("status") == "pass" else 1
    if args.stage_dry_run:
        result = stage_dry_run_receipt(repo_root, set(args.group))
        if args.stage_dry_run_json_output:
            write_json(Path(args.stage_dry_run_json_output).expanduser(), result)
        print(render_stage_dry_run_result(result))
        return 0 if result.get("status") == "pass" else 1
    if args.stage_dry_run_batch:
        result = stage_dry_run_batch_receipt(repo_root)
        if args.stage_dry_run_batch_json_output:
            write_json(Path(args.stage_dry_run_batch_json_output).expanduser(), result)
        print(render_stage_dry_run_batch_result(result))
        return 0 if result.get("status") == "pass" else 1
    if args.verify_stage_dry_run_json:
        expected = stage_dry_run_receipt(repo_root, set(args.group))
        result = verify_stage_dry_run_receipt(Path(args.verify_stage_dry_run_json).expanduser(), expected)
        print(render_verify_stage_dry_run_result(result))
        return 0 if result.get("status") == "pass" else 1
    if args.verify_stage_dry_run_batch_json:
        expected = stage_dry_run_batch_receipt(repo_root)
        result = verify_stage_dry_run_batch_receipt(Path(args.verify_stage_dry_run_batch_json).expanduser(), expected)
        print(render_verify_stage_dry_run_batch_result(result))
        return 0 if result.get("status") == "pass" else 1
    payload = inventory(repo_root, set(args.group), set(args.category), set(args.action), set(args.type))
    expected_plan = plan_payload(payload)
    expected_runbook = commit_runbook(payload)
    if args.verify_plan_json:
        result = verify_plan_payload(Path(args.verify_plan_json).expanduser(), expected_plan)
        print(render_verify_plan_result(result))
        return 0 if result.get("status") == "pass" else 1
    if args.verify_commit_runbook:
        result = verify_commit_runbook(Path(args.verify_commit_runbook).expanduser(), expected_runbook)
        print(render_verify_commit_runbook_result(result))
        return 0 if result.get("status") == "pass" else 1
    if args.json_output:
        write_json(Path(args.json_output).expanduser(), payload)
    if args.plan_json_output:
        write_json(Path(args.plan_json_output).expanduser(), expected_plan)
    if args.commit_runbook_output:
        runbook_path = Path(args.commit_runbook_output).expanduser()
        runbook_path.parent.mkdir(parents=True, exist_ok=True)
        runbook_path.write_text(expected_runbook, encoding="utf-8")
    if (
        (args.plan_json_output or args.commit_runbook_output)
        and not args.tracked_diff_stat
        and not args.plan_json
        and not args.plan
        and not args.commit_runbook
        and not args.paths_only
    ):
        return 0
    if args.tracked_diff_stat:
        print(render_tracked_diff_stat(repo_root, payload))
    elif args.plan_json:
        print(json.dumps(expected_plan, ensure_ascii=False, indent=2, sort_keys=True))
    elif args.plan:
        print(render_plan(payload))
    elif args.commit_runbook:
        print(expected_runbook)
    elif args.paths_only:
        print(render_paths(payload))
    else:
        print(render_text(payload, max(0, args.limit)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
