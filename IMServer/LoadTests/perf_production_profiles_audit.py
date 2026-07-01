#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import tempfile
from pathlib import Path
from typing import Any

from perf_matrix_audit import list_output_scenarios, parse_group_items, read_text


def read_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text())
    except Exception as exc:
        raise SystemExit(f"Failed to read JSON {path}: {exc}") from exc


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def issue(kind: str, severity: str, profile: str, scenario: str, detail: str) -> dict[str, str]:
    return {
        "kind": kind,
        "severity": severity,
        "profile": profile,
        "scenario": scenario,
        "detail": detail,
    }


def profile_group_relation(profile_scenarios: list[str], group_scenarios: list[str]) -> str:
    if profile_scenarios == group_scenarios:
        return "exact"
    profile_set = set(profile_scenarios)
    group_set = set(group_scenarios)
    if group_set.issubset(profile_set):
        return "superset"
    if profile_set.issubset(group_set):
        return "subset"
    return "overlap"


def audit(catalog_path: Path, matrix_script: Path) -> dict[str, Any]:
    payload = read_json(catalog_path)
    _, listed_scenarios = list_output_scenarios(matrix_script)
    groups = parse_group_items(read_text(matrix_script))
    listed_set = set(listed_scenarios)
    issues: list[dict[str, str]] = []
    profile_rows: list[dict[str, Any]] = []

    if int(payload.get("schemaVersion") or 0) != 1:
        issues.append(issue("schema", "error", "-", "-", "schemaVersion must be 1."))

    profiles = payload.get("profiles")
    if not isinstance(profiles, dict) or not profiles:
        issues.append(issue("profiles", "error", "-", "-", "profiles must be a non-empty object."))
        profiles = {}

    for profile, scenarios in sorted(profiles.items()):
        if not isinstance(profile, str) or not profile:
            issues.append(issue("profile-name", "error", str(profile), "-", "profile name must be non-empty string."))
            continue
        if not isinstance(scenarios, list) or not scenarios:
            issues.append(issue("profile-scenarios", "error", profile, "-", "profile scenarios must be a non-empty array."))
            profile_rows.append({"profile": profile, "scenarioCount": 0, "missingCount": 0, "duplicateCount": 0})
            continue

        seen: set[str] = set()
        duplicate_count = 0
        missing_count = 0
        for scenario in scenarios:
            if not isinstance(scenario, str) or not scenario:
                issues.append(issue("scenario-name", "error", profile, str(scenario), "scenario must be non-empty string."))
                continue
            if scenario in seen:
                duplicate_count += 1
                issues.append(issue("duplicate-scenario", "error", profile, scenario, "scenario appears more than once in profile."))
            seen.add(scenario)
            if scenario not in listed_set:
                missing_count += 1
                issues.append(issue("unknown-scenario", "error", profile, scenario, "scenario is not listed by run_perf_scenarios.sh --list."))
        group_scenarios = groups.get(profile)
        group_relation = "none"
        group_scenario_count = 0
        missing_from_profile_count = 0
        extra_in_profile_count = 0
        if group_scenarios is not None:
            group_relation = profile_group_relation(scenarios, group_scenarios)
            group_scenario_count = len(group_scenarios)
            missing_from_profile = [scenario for scenario in group_scenarios if scenario not in scenarios]
            extra_in_profile = [scenario for scenario in scenarios if scenario not in group_scenarios]
            missing_from_profile_count = len(missing_from_profile)
            extra_in_profile_count = len(extra_in_profile)
            if group_relation == "subset":
                issues.append(issue(
                    "profile-group-subset",
                    "warning",
                    profile,
                    ",".join(missing_from_profile[:3]) or "-",
                    "profile has the same name as a scenario group but covers fewer scenarios than the group expansion.",
                ))
            elif group_relation == "overlap":
                issues.append(issue(
                    "profile-group-overlap",
                    "warning",
                    profile,
                    ",".join(missing_from_profile[:3]) or "-",
                    "profile has the same name as a scenario group but is neither an exact match nor a superset.",
                ))

        profile_rows.append({
            "profile": profile,
            "scenarioCount": len(scenarios),
            "missingCount": missing_count,
            "duplicateCount": duplicate_count,
            "groupScenarioCount": group_scenario_count,
            "groupRelation": group_relation,
            "missingFromProfileCount": missing_from_profile_count,
            "extraInProfileCount": extra_in_profile_count,
        })

    error_count = sum(1 for item in issues if item["severity"] == "error")
    warning_count = sum(1 for item in issues if item["severity"] == "warning")
    return {
        "status": "PASS" if error_count == 0 else "FAIL",
        "catalog": str(catalog_path),
        "matrixScript": str(matrix_script),
        "listedScenarioCount": len(listed_scenarios),
        "profileCount": len(profile_rows),
        "errorCount": error_count,
        "warningCount": warning_count,
        "profiles": profile_rows,
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
    profile_rows = [["Profile", "Scenarios", "Missing", "Duplicates", "Group", "Relation", "Group Missing", "Profile Extra"]]
    for row in payload["profiles"]:
        profile_rows.append([
            f"`{row['profile']}`",
            str(row["scenarioCount"]),
            str(row["missingCount"]),
            str(row["duplicateCount"]),
            str(row.get("groupScenarioCount", 0) or "-"),
            str(row.get("groupRelation") or "none"),
            str(row.get("missingFromProfileCount", 0)),
            str(row.get("extraInProfileCount", 0)),
        ])

    issue_rows = [["Severity", "Kind", "Profile", "Scenario", "Detail"]]
    for row in payload["issues"]:
        issue_rows.append([
            row["severity"],
            row["kind"],
            f"`{row['profile']}`",
            f"`{row['scenario']}`",
            row["detail"],
        ])

    return "\n".join([
        "# Production Profile Catalog Audit",
        "",
        f"- status: `{payload['status']}`",
        f"- catalog: `{payload['catalog']}`",
        f"- matrixScript: `{payload['matrixScript']}`",
        f"- listed scenarios: `{payload['listedScenarioCount']}`",
        f"- profiles: `{payload['profileCount']}`",
        f"- errors/warnings: `{payload['errorCount']}/{payload['warningCount']}`",
        "",
        "## Profiles",
        "",
        markdown_table(profile_rows),
        "",
        "## Issues",
        "",
        markdown_table(issue_rows) if payload["issues"] else "No production profile catalog issues found.",
        "",
    ])


def verify_payload(payload: dict[str, Any]) -> None:
    if not isinstance(payload, dict):
        raise SystemExit("production_profiles_audit_verify result=fail reason=json_not_object")
    if payload.get("status") not in {"PASS", "FAIL"}:
        raise SystemExit("production_profiles_audit_verify result=fail reason=status")
    for key in ("catalog", "matrixScript"):
        if not str(payload.get(key) or ""):
            raise SystemExit(f"production_profiles_audit_verify result=fail reason={key}_missing")
    for key in ("listedScenarioCount", "profileCount", "errorCount", "warningCount"):
        value = payload.get(key)
        if not isinstance(value, int) or value < 0:
            raise SystemExit(f"production_profiles_audit_verify result=fail reason={key}")

    profiles = payload.get("profiles")
    if not isinstance(profiles, list):
        raise SystemExit("production_profiles_audit_verify result=fail reason=profiles_not_list")
    if payload["profileCount"] != len(profiles):
        raise SystemExit("production_profiles_audit_verify result=fail reason=profile_count_mismatch")

    issues = payload.get("issues")
    if not isinstance(issues, list):
        raise SystemExit("production_profiles_audit_verify result=fail reason=issues_not_list")
    error_count = sum(1 for row in issues if isinstance(row, dict) and row.get("severity") == "error")
    warning_count = sum(1 for row in issues if isinstance(row, dict) and row.get("severity") == "warning")
    if payload["errorCount"] != error_count:
        raise SystemExit("production_profiles_audit_verify result=fail reason=error_count_mismatch")
    if payload["warningCount"] != warning_count:
        raise SystemExit("production_profiles_audit_verify result=fail reason=warning_count_mismatch")
    if (payload["status"] == "PASS") != (error_count == 0):
        raise SystemExit("production_profiles_audit_verify result=fail reason=status_count_mismatch")

    seen_profiles: set[str] = set()
    for row in profiles:
        if not isinstance(row, dict):
            raise SystemExit("production_profiles_audit_verify result=fail reason=profile_row_not_object")
        profile = str(row.get("profile") or "")
        if not profile:
            raise SystemExit("production_profiles_audit_verify result=fail reason=profile_missing")
        if profile in seen_profiles:
            raise SystemExit(f"production_profiles_audit_verify result=fail reason=duplicate_profile profile={profile}")
        seen_profiles.add(profile)
        if row.get("groupRelation") not in {"exact", "superset", "subset", "overlap", "none"}:
            raise SystemExit(f"production_profiles_audit_verify result=fail reason=profile_group_relation profile={profile}")
        for key in (
            "scenarioCount",
            "missingCount",
            "duplicateCount",
            "groupScenarioCount",
            "missingFromProfileCount",
            "extraInProfileCount",
        ):
            value = row.get(key)
            if not isinstance(value, int) or value < 0:
                raise SystemExit(f"production_profiles_audit_verify result=fail reason=profile_{key} profile={profile}")


def verify_markdown(payload: dict[str, Any], markdown_path: Path) -> None:
    verify_payload(payload)
    if not markdown_path.is_file():
        raise SystemExit(f"production_profiles_audit_verify result=fail reason=markdown_missing path={markdown_path}")
    expected = build_markdown(payload)
    actual = markdown_path.read_text(encoding="utf-8")
    if actual != expected:
        raise SystemExit(f"production_profiles_audit_verify result=fail reason=markdown_mismatch path={markdown_path}")


def write_self_test_matrix(path: Path) -> None:
    content = """#!/usr/bin/env bash
set -euo pipefail

DEFAULT_SCENARIOS="login-smoke client-sync-smoke direct-message-smoke group-delivery-smoke"

scenario_group_items() {
  case "$1" in
    normal-product-baseline)
      printf '%s\\n' "login-smoke client-sync-smoke direct-message-smoke group-delivery-smoke"
      ;;
    *)
      printf '%s\\n' ""
      ;;
  esac
}

if [[ "${1:-}" == "--list" ]]; then
  echo "Available scenario groups:"
  echo "normal-product-baseline"
  echo "Available scenarios:"
  for scenario in ${DEFAULT_SCENARIOS}; do
    echo "${scenario}"
  done
  exit 0
fi

for scenario in ${SCENARIOS:-${DEFAULT_SCENARIOS}}; do
  case "${scenario}" in
    login-smoke|client-sync-smoke|direct-message-smoke|group-delivery-smoke)
      ;;
    *)
      exit 1
      ;;
  esac
done
"""
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def expect_self_test_issue(payload: dict[str, Any], kind: str, label: str) -> None:
    kinds = {str(row.get("kind") or "") for row in payload.get("issues") or [] if isinstance(row, dict)}
    if payload.get("status") != "FAIL" or kind not in kinds:
        raise SystemExit(f"production_profiles_audit_self_test result=fail reason={label} status={payload.get('status')} kinds={sorted(kinds)}")


def expect_self_test_warning(payload: dict[str, Any], kind: str, label: str) -> None:
    kinds = {str(row.get("kind") or "") for row in payload.get("issues") or [] if isinstance(row, dict)}
    if payload.get("status") != "PASS" or kind not in kinds:
        raise SystemExit(f"production_profiles_audit_self_test result=fail reason={label} status={payload.get('status')} kinds={sorted(kinds)}")


def expect_self_test_verify_failure(func: Any, label: str, expected: str) -> None:
    try:
        func()
    except SystemExit as exc:
        message = str(exc)
        if expected not in message:
            raise SystemExit(f"production_profiles_audit_self_test result=fail reason={label}_wrong_error error={message}") from exc
        return
    raise SystemExit(f"production_profiles_audit_self_test result=fail reason={label}_passed")


def run_self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="production-profiles-audit-self-test-") as raw_root:
        root = Path(raw_root)
        matrix_script = root / "run_perf_scenarios.sh"
        catalog = root / "perf_production_profiles.json"
        write_self_test_matrix(matrix_script)
        write_json(catalog, {
            "schemaVersion": 1,
            "profiles": {
                "normal-product-baseline": [
                    "login-smoke",
                    "client-sync-smoke",
                    "direct-message-smoke",
                    "group-delivery-smoke",
                ],
                "small-product": ["login-smoke", "client-sync-smoke"],
            },
        })

        payload = audit(catalog, matrix_script)
        if payload.get("status") != "PASS":
            raise SystemExit(f"production_profiles_audit_self_test result=fail reason=good_catalog_failed issues={payload.get('issues')}")
        verify_payload(payload)
        markdown_path = root / "production-profile-audit.md"
        markdown_path.write_text(build_markdown(payload), encoding="utf-8")
        verify_markdown(payload, markdown_path)

        bad_md = root / "production-profile-audit-bad.md"
        bad_md.write_text(markdown_path.read_text(encoding="utf-8").replace("- status: `PASS`", "- auditStatus: `PASS`"), encoding="utf-8")
        expect_self_test_verify_failure(
            lambda: verify_markdown(payload, bad_md),
            "self_test_markdown_mismatch",
            "markdown_mismatch",
        )

        unknown_catalog = root / "unknown-profile.json"
        write_json(unknown_catalog, {"schemaVersion": 1, "profiles": {"normal-product-baseline": ["login-smoke", "missing-smoke"]}})
        expect_self_test_issue(
            audit(unknown_catalog, matrix_script),
            "unknown-scenario",
            "self_test_unknown_scenario_rejected",
        )

        duplicate_catalog = root / "duplicate-profile.json"
        write_json(duplicate_catalog, {"schemaVersion": 1, "profiles": {"normal-product-baseline": ["login-smoke", "login-smoke"]}})
        expect_self_test_issue(
            audit(duplicate_catalog, matrix_script),
            "duplicate-scenario",
            "self_test_duplicate_scenario_rejected",
        )

        subset_catalog = root / "subset-profile.json"
        write_json(subset_catalog, {"schemaVersion": 1, "profiles": {"normal-product-baseline": ["login-smoke", "client-sync-smoke"]}})
        expect_self_test_warning(
            audit(subset_catalog, matrix_script),
            "profile-group-subset",
            "self_test_group_subset_warned",
        )

    print("production_profiles_audit_self_test result=pass")


def write_csv(path: Path, rows: list[dict[str, str]]) -> None:
    fieldnames = ["severity", "kind", "profile", "scenario", "detail"]
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow({key: row.get(key, "") for key in fieldnames})


def main() -> int:
    parser = argparse.ArgumentParser(description="Audit production performance profile catalog against the scenario matrix.")
    parser.add_argument("--catalog", default=str(Path(__file__).with_name("perf_production_profiles.json")))
    parser.add_argument("--matrix-script", default=str(Path(__file__).with_name("run_perf_scenarios.sh")))
    parser.add_argument("--output")
    parser.add_argument("--json-output")
    parser.add_argument("--csv-output")
    parser.add_argument("--verify-json")
    parser.add_argument("--verify-md")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--strict", action="store_true")
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

    payload = audit(Path(args.catalog), Path(args.matrix_script))
    markdown = build_markdown(payload)
    if args.output:
        Path(args.output).write_text(markdown)
    else:
        print(markdown)
    if args.json_output:
        Path(args.json_output).write_text(json.dumps(payload, indent=2, sort_keys=True))
    if args.csv_output:
        write_csv(Path(args.csv_output), payload["issues"])
    if args.output:
        verify_markdown(payload, Path(args.output))
    return 1 if args.strict and payload["status"] != "PASS" else 0


if __name__ == "__main__":
    raise SystemExit(main())
