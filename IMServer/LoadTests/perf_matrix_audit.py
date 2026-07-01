#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import re
import subprocess
import tempfile
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class K6Scenario:
    name: str
    category: str
    target: str
    profile: str
    script: str


def read_text(path: Path) -> str:
    try:
        return path.read_text()
    except OSError as exc:
        raise SystemExit(f"Failed to read {path}: {exc}") from exc


def split_words(value: str) -> list[str]:
    return [item for item in re.split(r"\s+", value.strip()) if item]


def parse_default_scenarios(text: str) -> list[str]:
    match = re.search(r'^DEFAULT_SCENARIOS="([^"]*)"', text, re.MULTILINE)
    return split_words(match.group(1)) if match else []


def parse_group_items(text: str) -> dict[str, list[str]]:
    groups: dict[str, list[str]] = {}
    group_case = re.search(r"scenario_group_items\(\)\s*\{(?P<body>.*?)\n\}", text, re.DOTALL)
    if not group_case:
        return groups
    body = group_case.group("body")
    for match in re.finditer(r"^\s{4}([a-zA-Z0-9_-]+)\)\s*\n(?P<body>.*?)(?=^\s{4}[a-zA-Z0-9_-]+\)|^\s{4}\*\)|\Z)", body, re.MULTILINE | re.DOTALL):
        name = match.group(1)
        block = match.group("body")
        printf_match = re.search(r'printf\s+[^"]*"([^"]*)"', block)
        if not printf_match:
            continue
        raw = printf_match.group(1)
        items: list[str] = []
        for token_match in re.finditer(r"\$\(scenario_group_items\s+[a-zA-Z0-9_-]+\)|\S+", raw):
            token = token_match.group(0)
            ref_match = re.fullmatch(r"\$\(scenario_group_items\s+([a-zA-Z0-9_-]+)\)", token)
            if ref_match:
                items.append(f"@{ref_match.group(1)}")
            else:
                items.append(token)
        groups[name] = items

    def expand(name: str, seen: set[str] | None = None) -> list[str]:
        seen = seen or set()
        if name in seen:
            return []
        seen.add(name)
        expanded: list[str] = []
        for item in groups.get(name, []):
            if item.startswith("@"):
                expanded.extend(expand(item[1:], seen.copy()))
            else:
                expanded.append(item)
        return list(dict.fromkeys(expanded))

    return {name: expand(name) for name in groups}


def parse_case_scenarios(text: str) -> set[str]:
    marker = "for scenario in ${SCENARIOS}; do"
    start = text.find(marker)
    if start < 0:
        return set()
    body = text[start:]
    return set(re.findall(r"^\s{4}([a-zA-Z0-9_-]+)\)", body, re.MULTILINE))


def parse_k6_scenarios(text: str) -> list[K6Scenario]:
    records: list[K6Scenario] = []
    pattern = re.compile(
        r'run_k6\s+"\$\{scenario\}"\s+"([^"]+)"\s+"([^"]+)"\s+"([^"]+)"\s+"([^"]+)"'
    )
    current: str | None = None
    for line in text.splitlines():
        case_match = re.match(r"\s{4}([a-zA-Z0-9_-]+)\)", line)
        if case_match:
            current = case_match.group(1)
            continue
        if current is None:
            continue
        run_match = pattern.search(line)
        if run_match:
            records.append(K6Scenario(
                name=current,
                category=run_match.group(1),
                target=run_match.group(2),
                profile=run_match.group(3),
                script=run_match.group(4),
            ))
    return records


def list_output_scenarios(script_path: Path) -> tuple[list[str], list[str]]:
    executable = script_path if script_path.is_absolute() else script_path.resolve()
    try:
        completed = subprocess.run(
            [str(executable), "--list"],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except Exception as exc:
        raise SystemExit(f"Failed to run {script_path} --list: {exc}") from exc
    groups: list[str] = []
    scenarios: list[str] = []
    section: str | None = None
    for raw_line in completed.stdout.splitlines():
        line = raw_line.strip()
        if line == "Available scenario groups:":
            section = "groups"
            continue
        if line == "Available scenarios:":
            section = "scenarios"
            continue
        if not line:
            continue
        if section == "groups":
            groups.append(line)
        elif section == "scenarios":
            scenarios.append(line)
    return groups, scenarios


def issue(kind: str, severity: str, item: str, detail: str) -> dict[str, str]:
    return {"kind": kind, "severity": severity, "item": item, "detail": detail}


def build_report(script_path: Path, k6_dir: Path) -> tuple[str, dict[str, Any]]:
    text = read_text(script_path)
    default_scenarios = parse_default_scenarios(text)
    groups = parse_group_items(text)
    case_scenarios = parse_case_scenarios(text)
    k6_scenarios = parse_k6_scenarios(text)
    listed_groups, listed_scenarios = list_output_scenarios(script_path)
    listed_group_set = set(listed_groups)
    listed_scenario_set = set(listed_scenarios)
    k6_script_names = {path.name for path in k6_dir.glob("*.js")}

    issues: list[dict[str, str]] = []
    declared = set(default_scenarios)
    for scenarios in groups.values():
        declared.update(scenarios)
    declared.update(listed_scenarios)

    for scenario in sorted(declared - case_scenarios):
        issues.append(issue("missing-case", "error", scenario, "Scenario is declared in default/group/list output but has no case branch."))
    for scenario in sorted(case_scenarios - listed_scenario_set):
        issues.append(issue("missing-list-entry", "error", scenario, "Scenario has a case branch but is not shown by --list."))
    for scenario in sorted(set(default_scenarios) - case_scenarios):
        issues.append(issue("default-without-case", "error", scenario, "DEFAULT_SCENARIOS includes a scenario without a case branch."))
    for group_name, scenarios in sorted(groups.items()):
        if group_name not in listed_group_set:
            issues.append(issue("missing-group-list-entry", "error", group_name, "Group exists in scenario_group_items but is not shown by --list."))
        if not scenarios:
            issues.append(issue("empty-group", "error", group_name, "Scenario group expands to no scenarios."))
        for scenario in scenarios:
            if scenario not in case_scenarios:
                issues.append(issue("group-scenario-without-case", "error", f"{group_name}:{scenario}", "Group includes a scenario without a case branch."))

    seen_k6: set[str] = set()
    for record in k6_scenarios:
        seen_k6.add(record.script)
        if record.script not in k6_script_names:
            issues.append(issue("missing-k6-script", "error", record.name, f"Referenced k6 script does not exist: {record.script}"))
    for script_name in sorted(k6_script_names - seen_k6):
        issues.append(issue("unused-k6-script", "warning", script_name, "k6 script exists but is not referenced by run_perf_scenarios.sh."))

    duplicate_listed = sorted({item for item in listed_scenarios if listed_scenarios.count(item) > 1})
    for scenario in duplicate_listed:
        issues.append(issue("duplicate-list-entry", "warning", scenario, "Scenario appears more than once in --list output."))

    scenario_records = [asdict(record) for record in k6_scenarios]
    error_count = sum(1 for item in issues if item["severity"] == "error")
    warning_count = sum(1 for item in issues if item["severity"] == "warning")
    issue_rows = [["Severity", "Kind", "Item", "Detail"]]
    for item in issues:
        issue_rows.append([item["severity"], item["kind"], f"`{item['item']}`", item["detail"]])
    group_rows = [["Group", "Scenario Count"]]
    for name, scenarios in sorted(groups.items()):
        group_rows.append([f"`{name}`", str(len(scenarios))])

    markdown = "\n".join([
        "# Performance Matrix Audit",
        "",
        f"- runner: `{script_path}`",
        f"- default scenarios: `{len(default_scenarios)}`",
        f"- listed groups: `{len(listed_groups)}`",
        f"- listed scenarios: `{len(listed_scenarios)}`",
        f"- case scenarios: `{len(case_scenarios)}`",
        f"- k6 scenarios: `{len(k6_scenarios)}`",
        f"- errors: `{error_count}`",
        f"- warnings: `{warning_count}`",
        "",
        "## Issues",
        "",
        markdown_table(issue_rows) if issues else "No matrix issues found.",
        "",
        "## Groups",
        "",
        markdown_table(group_rows),
        "",
    ])
    report = {
        "runner": str(script_path),
        "defaultScenarioCount": len(default_scenarios),
        "listedGroupCount": len(listed_groups),
        "listedScenarioCount": len(listed_scenarios),
        "caseScenarioCount": len(case_scenarios),
        "k6ScenarioCount": len(k6_scenarios),
        "errorCount": error_count,
        "warningCount": warning_count,
        "defaultScenarios": default_scenarios,
        "groups": groups,
        "listedGroups": listed_groups,
        "listedScenarios": listed_scenarios,
        "caseScenarios": sorted(case_scenarios),
        "k6Scenarios": scenario_records,
        "issues": issues,
    }
    return markdown, report


def markdown_table(rows: list[list[str]]) -> str:
    if not rows:
        return ""
    lines = [
        "| " + " | ".join(rows[0]) + " |",
        "| " + " | ".join(["---"] * len(rows[0])) + " |",
    ]
    for row in rows[1:]:
        lines.append("| " + " | ".join(row) + " |")
    return "\n".join(lines)


def write_csv(path: Path, issues: list[dict[str, str]]) -> None:
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=["severity", "kind", "item", "detail"])
        writer.writeheader()
        for item in issues:
            writer.writerow(item)


def self_test_script(
    path: Path,
    *,
    default_scenarios: str = "login-smoke sync-smoke",
    group_list: str = "normal-product-smoke",
    group_items: str = "login-smoke sync-smoke",
    list_scenarios: str = "login-smoke sync-smoke",
    case_scenarios: tuple[tuple[str, str], ...] = (("login-smoke", "http-login.js"), ("sync-smoke", "http-sync.js")),
) -> None:
    case_blocks = []
    for scenario, script in case_scenarios:
        case_blocks.append(f"""    {scenario})
      run_k6 "${{scenario}}" "http" "api" "smoke" "{script}"
      ;;
""")
    content = f"""#!/usr/bin/env bash
set -euo pipefail

DEFAULT_SCENARIOS="{default_scenarios}"

scenario_group_items() {{
  case "$1" in
    normal-product-smoke)
      printf '%s\\n' "{group_items}"
      ;;
    *)
      printf '%s\\n' ""
      ;;
  esac
}}

if [[ "${{1:-}}" == "--list" ]]; then
  echo "Available scenario groups:"
  for group in {group_list}; do
    echo "${{group}}"
  done
  echo "Available scenarios:"
  for scenario in {list_scenarios}; do
    echo "${{scenario}}"
  done
  exit 0
fi

run_k6() {{ :; }}

SCENARIOS="${{SCENARIOS:-${{DEFAULT_SCENARIOS}}}}"
for scenario in ${{SCENARIOS}}; do
  case "${{scenario}}" in
{''.join(case_blocks)}    *)
      exit 1
      ;;
  esac
done
"""
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def expect_self_test_issue(report: dict[str, Any], kind: str, label: str, *, severity: str = "error") -> None:
    kinds = {
        str(row.get("kind") or "")
        for row in report.get("issues") or []
        if isinstance(row, dict) and str(row.get("severity") or "") == severity
    }
    if kind not in kinds:
        raise SystemExit(f"matrix_audit_self_test result=fail reason={label} severity={severity} kinds={sorted(kinds)}")


def run_self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="matrix-audit-self-test-") as raw_root:
        root = Path(raw_root)
        script = root / "run_perf_scenarios.sh"
        k6_dir = root / "k6"
        k6_dir.mkdir()
        (k6_dir / "http-login.js").write_text("// login\n", encoding="utf-8")
        (k6_dir / "http-sync.js").write_text("// sync\n", encoding="utf-8")

        self_test_script(script)
        markdown, report = build_report(script, k6_dir)
        if report.get("errorCount") != 0 or report.get("warningCount") != 0:
            raise SystemExit(f"matrix_audit_self_test result=fail reason=good_matrix_failed errors={report.get('errorCount')} warnings={report.get('warningCount')} issues={report.get('issues')}")
        if "# Performance Matrix Audit" not in markdown or "## Groups" not in markdown:
            raise SystemExit("matrix_audit_self_test result=fail reason=markdown_missing_sections")

        self_test_script(script, group_list="")
        _, report = build_report(script, k6_dir)
        expect_self_test_issue(report, "missing-group-list-entry", "self_test_unlisted_group_rejected")

        self_test_script(script, default_scenarios="login-smoke missing-case", list_scenarios="login-smoke missing-case")
        _, report = build_report(script, k6_dir)
        expect_self_test_issue(report, "missing-case", "self_test_missing_case_rejected")
        expect_self_test_issue(report, "default-without-case", "self_test_default_without_case_rejected")

        self_test_script(script, list_scenarios="login-smoke", group_items="login-smoke")
        _, report = build_report(script, k6_dir)
        expect_self_test_issue(report, "missing-list-entry", "self_test_missing_list_entry_rejected")

        self_test_script(script, case_scenarios=(("login-smoke", "http-login.js"), ("sync-smoke", "missing.js")))
        _, report = build_report(script, k6_dir)
        expect_self_test_issue(report, "missing-k6-script", "self_test_missing_k6_script_rejected")

        self_test_script(script, group_list="normal-product-smoke", list_scenarios="login-smoke login-smoke sync-smoke")
        _, report = build_report(script, k6_dir)
        expect_self_test_issue(report, "duplicate-list-entry", "self_test_duplicate_list_warned", severity="warning")

    print("matrix_audit_self_test result=pass")


def main() -> int:
    parser = argparse.ArgumentParser(description="Audit run_perf_scenarios.sh scenario matrix consistency.")
    parser.add_argument("--script", default="run_perf_scenarios.sh", help="Path to run_perf_scenarios.sh.")
    parser.add_argument("--k6-dir", default="k6", help="Path to the k6 script directory.")
    parser.add_argument("--output", help="Write Markdown audit report.")
    parser.add_argument("--json-output", help="Write machine-readable audit JSON.")
    parser.add_argument("--csv-output", help="Write issue CSV.")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--strict", action="store_true", help="Exit non-zero when errors exist.")
    args = parser.parse_args()

    if args.self_test:
        run_self_test()
        return 0

    script_path = Path(args.script)
    k6_dir = Path(args.k6_dir)
    markdown, report = build_report(script_path, k6_dir)
    if args.output:
        Path(args.output).write_text(markdown)
    else:
        print(markdown)
    if args.json_output:
        Path(args.json_output).write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    if args.csv_output:
        write_csv(Path(args.csv_output), report["issues"])
    if args.strict and report["errorCount"] > 0:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
