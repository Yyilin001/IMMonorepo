#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import tempfile
from pathlib import Path
from typing import Any

from perf_matrix_audit import list_output_scenarios, parse_k6_scenarios, read_text


def read_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text())
    except Exception:
        return {}


def first_reason(scenario: dict[str, Any]) -> str:
    reasons = scenario.get("reasons") or []
    if reasons:
        return str(reasons[0])
    diagnostics = scenario.get("diagnostics") or []
    if diagnostics:
        return str(diagnostics[0])
    return ""


def compact_p99(scenario: dict[str, Any]) -> str:
    values = scenario.get("p99") or []
    return "; ".join(str(item) for item in values[:4])


def scenario_sort_key(row: dict[str, Any]) -> tuple[int, str, str]:
    status_rank = {"FAIL": 0, "NEVER_RUN": 1, "UNKNOWN": 2, "PASS": 3}
    return (
        status_rank.get(str(row.get("latestStatus")), 3),
        str(row.get("category") or ""),
        str(row.get("scenario") or ""),
    )


def runner_scenario_metadata(matrix_script: Path | None) -> dict[str, dict[str, str]]:
    if matrix_script is None:
        return {}
    text = read_text(matrix_script)
    metadata = {
        record.name: {
            "category": record.category,
            "target": record.target,
        }
        for record in parse_k6_scenarios(text)
    }
    _, listed = list_output_scenarios(matrix_script)
    for name in listed:
        metadata.setdefault(name, {"category": infer_category(name), "target": ""})
    return metadata


def infer_category(name: str) -> str:
    if name.startswith("online-idle-"):
        return "tcp-online"
    if name.startswith("reconnect-"):
        return "tcp-reconnect"
    if name.startswith("multi-device-online-"):
        return "tcp-multi-device-online"
    if name.startswith("multi-device-delivery-"):
        return "tcp-multi-device-delivery"
    if name.startswith("pair-delivery-"):
        return "tcp-pair-delivery"
    if name.startswith("online-chat-mix-"):
        return "tcp-pair-delivery"
    if name.startswith("direct-burst-"):
        return "tcp-pair-delivery"
    if name.startswith("group-delivery-"):
        return "tcp-group-delivery"
    if name.startswith("large-group-"):
        return "tcp-large-group"
    return ""


def target_matches(run_target: dict[str, Any], args: argparse.Namespace) -> bool:
    if not bool(getattr(args, "filter_target", False)):
        return True
    checks = [
        ("baseURL", getattr(args, "base_url", "")),
        ("tcpHost", getattr(args, "tcp_host", "")),
        ("tcpPort", getattr(args, "tcp_port", "")),
    ]
    for field, expected in checks:
        if not expected:
            continue
        actual = str(run_target.get(field) or "")
        if actual != str(expected):
            return False
    return True


def collect_scenario_status(
    results_dir: Path,
    matrix_script: Path | None = None,
    args: argparse.Namespace | None = None,
) -> list[dict[str, Any]]:
    records: dict[str, dict[str, Any]] = {}
    for name, metadata in runner_scenario_metadata(matrix_script).items():
        records[name] = {
            "scenario": name,
            "category": metadata.get("category", ""),
            "target": metadata.get("target", ""),
            "runCount": 0,
            "passCount": 0,
            "failCount": 0,
            "unknownCount": 0,
            "latestRunID": "",
            "latestRunDir": "",
            "latestMtime": 0.0,
            "latestBaseURL": "",
            "latestTCPHost": "",
            "latestTCPPort": "",
            "latestStatus": "NEVER_RUN",
            "latestReason": "no report.json found for this scenario",
            "latestP99": "",
            "optimizationHint": "Run this scenario at least once before treating the matrix as complete runtime evidence.",
        }
    for report_path in sorted(results_dir.glob("*/report.json")):
        report = read_json(report_path)
        if not report:
            continue
        run_dir = report_path.parent
        run_mtime = report_path.stat().st_mtime
        run_id = run_dir.name
        report_target = report.get("target") or {}
        for scenario in report.get("scenarios") or []:
            name = str(scenario.get("name") or "")
            if not name:
                continue
            scenario_target = scenario.get("runTarget") or report_target
            if args is not None and not target_matches(scenario_target, args):
                continue
            status = str(scenario.get("status") or "UNKNOWN")
            row = records.setdefault(name, {
                "scenario": name,
                "category": str(scenario.get("category") or ""),
                "target": str(scenario.get("target") or ""),
                "runCount": 0,
                "passCount": 0,
                "failCount": 0,
                "unknownCount": 0,
                "latestRunID": "",
                "latestRunDir": "",
                "latestMtime": 0.0,
                "latestBaseURL": "",
                "latestTCPHost": "",
                "latestTCPPort": "",
                "latestStatus": "UNKNOWN",
                "latestReason": "",
                "latestP99": "",
                "optimizationHint": "",
            })
            row["runCount"] += 1
            if status == "PASS":
                row["passCount"] += 1
            elif status == "FAIL":
                row["failCount"] += 1
            else:
                row["unknownCount"] += 1

            if run_mtime >= float(row["latestMtime"] or 0):
                row.update({
                    "category": str(scenario.get("category") or row["category"]),
                    "target": str(scenario.get("target") or row["target"]),
                    "latestRunID": run_id,
                    "latestRunDir": str(run_dir),
                    "latestMtime": run_mtime,
                    "latestBaseURL": str(scenario_target.get("baseURL") or report_target.get("baseURL") or ""),
                    "latestTCPHost": str(scenario_target.get("tcpHost") or report_target.get("tcpHost") or ""),
                    "latestTCPPort": str(scenario_target.get("tcpPort") or report_target.get("tcpPort") or ""),
                    "latestStatus": status,
                    "latestReason": first_reason(scenario),
                    "latestP99": compact_p99(scenario),
                    "optimizationHint": str(scenario.get("optimizationHint") or ""),
                })
    return sorted(records.values(), key=scenario_sort_key)


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


def build_markdown(rows: list[dict[str, Any]], results_dir: Path, limit: int | None) -> str:
    status_counts: dict[str, int] = {}
    for row in rows:
        status = str(row.get("latestStatus") or "UNKNOWN")
        status_counts[status] = status_counts.get(status, 0) + 1

    status_table = [["Latest Status", "Scenarios"]]
    for status in ["FAIL", "NEVER_RUN", "UNKNOWN", "PASS"]:
        status_table.append([f"`{status}`", str(status_counts.get(status, 0))])

    category_totals: dict[str, dict[str, int]] = {}
    for row in rows:
        category = str(row.get("category") or "unknown")
        status = str(row.get("latestStatus") or "UNKNOWN")
        bucket = category_totals.setdefault(category, {"FAIL": 0, "NEVER_RUN": 0, "UNKNOWN": 0, "PASS": 0})
        bucket[status if status in bucket else "UNKNOWN"] += 1
    category_table = [["Category", "FAIL", "NEVER_RUN", "UNKNOWN", "PASS", "Total"]]
    for category, counts in sorted(
        category_totals.items(),
        key=lambda item: (-(item[1]["FAIL"] + item[1]["NEVER_RUN"] + item[1]["UNKNOWN"]), item[0]),
    ):
        total = counts["FAIL"] + counts["NEVER_RUN"] + counts["UNKNOWN"] + counts["PASS"]
        category_table.append([
            category,
            str(counts["FAIL"]),
            str(counts["NEVER_RUN"]),
            str(counts["UNKNOWN"]),
            str(counts["PASS"]),
            str(total),
        ])

    display_rows = rows[:limit] if limit is not None else rows
    scenario_table = [[
        "Scenario",
        "Category",
        "Latest",
        "Runs",
        "PASS/FAIL/UNKNOWN",
        "Latest Run",
        "Latest P99",
        "Reason",
    ]]
    for row in display_rows:
        scenario_table.append([
            str(row["scenario"]),
            str(row["category"] or "-"),
            str(row["latestStatus"]),
            str(row["runCount"]),
            f"{row['passCount']}/{row['failCount']}/{row['unknownCount']}",
            str(row["latestRunID"]),
            str(row["latestP99"] or "-"),
            str(row["latestReason"] or row["optimizationHint"] or "-")[:160],
        ])

    display_line = f"- scenarios: `{len(rows)}`"
    if limit is not None:
        display_line = f"- scenarios: `{len(display_rows)}` displayed of `{len(rows)}` total"
    return "\n".join([
        "# Performance Scenario Status",
        "",
        f"- resultsDir: `{results_dir}`",
        display_line,
        "",
        "## Latest Status Summary",
        "",
        markdown_table(status_table),
        "",
        "## Category Summary",
        "",
        markdown_table(category_table),
        "",
        "## Scenarios",
        "",
        markdown_table(scenario_table),
        "",
    ])


def build_payload(rows: list[dict[str, Any]], results_dir: Path, args: argparse.Namespace) -> dict[str, Any]:
    return {
        "resultsDir": str(results_dir),
        "targetFilter": {
            "enabled": bool(args.filter_target),
            "baseURL": args.base_url,
            "tcpHost": args.tcp_host,
            "tcpPort": args.tcp_port,
        },
        "scenarioCount": len(rows),
        "latestStatusCounts": {
            status: sum(1 for row in rows if row["latestStatus"] == status)
            for status in ["FAIL", "NEVER_RUN", "UNKNOWN", "PASS"]
        },
        "scenarios": rows,
    }


def verify_payload(payload: dict[str, Any]) -> None:
    if not isinstance(payload, dict):
        raise SystemExit("scenario_status_verify result=fail reason=payload_not_object")
    target_filter = payload.get("targetFilter")
    if not isinstance(target_filter, dict):
        raise SystemExit("scenario_status_verify result=fail reason=target_filter_not_object")
    if not isinstance(target_filter.get("enabled"), bool):
        raise SystemExit("scenario_status_verify result=fail reason=target_filter_enabled_not_bool")
    scenarios = payload.get("scenarios")
    if not isinstance(scenarios, list):
        raise SystemExit("scenario_status_verify result=fail reason=scenarios_not_list")
    scenario_count = payload.get("scenarioCount")
    if not isinstance(scenario_count, int) or scenario_count < 0:
        raise SystemExit("scenario_status_verify result=fail reason=scenario_count")
    if scenario_count != len(scenarios):
        raise SystemExit("scenario_status_verify result=fail reason=scenario_count_mismatch")
    counts = payload.get("latestStatusCounts")
    if not isinstance(counts, dict):
        raise SystemExit("scenario_status_verify result=fail reason=status_counts_not_object")
    expected_statuses = ["FAIL", "NEVER_RUN", "UNKNOWN", "PASS"]
    for status in expected_statuses:
        value = counts.get(status)
        if not isinstance(value, int) or value < 0:
            raise SystemExit(f"scenario_status_verify result=fail reason=status_count status={status}")
        actual = sum(1 for row in scenarios if isinstance(row, dict) and row.get("latestStatus") == status)
        if value != actual:
            raise SystemExit(f"scenario_status_verify result=fail reason=status_count_mismatch status={status}")
    if sum(int(counts.get(status) or 0) for status in expected_statuses) != len(scenarios):
        raise SystemExit("scenario_status_verify result=fail reason=status_total_mismatch")

    seen: set[str] = set()
    for row in scenarios:
        if not isinstance(row, dict):
            raise SystemExit("scenario_status_verify result=fail reason=scenario_row_not_object")
        name = str(row.get("scenario") or "")
        if not name:
            raise SystemExit("scenario_status_verify result=fail reason=scenario_name_missing")
        if name in seen:
            raise SystemExit(f"scenario_status_verify result=fail reason=duplicate_scenario scenario={name}")
        seen.add(name)
        status = str(row.get("latestStatus") or "")
        if status not in expected_statuses:
            raise SystemExit(f"scenario_status_verify result=fail reason=invalid_status scenario={name}")
        for key in ("runCount", "passCount", "failCount", "unknownCount"):
            value = row.get(key)
            if not isinstance(value, int) or value < 0:
                raise SystemExit(f"scenario_status_verify result=fail reason={key} scenario={name}")
        if row["runCount"] != row["passCount"] + row["failCount"] + row["unknownCount"]:
            raise SystemExit(f"scenario_status_verify result=fail reason=run_count_total scenario={name}")
        if status == "NEVER_RUN" and row["runCount"] != 0:
            raise SystemExit(f"scenario_status_verify result=fail reason=never_run_with_runs scenario={name}")
        if status != "NEVER_RUN" and row["runCount"] == 0:
            raise SystemExit(f"scenario_status_verify result=fail reason=status_without_runs scenario={name}")
        if not isinstance(row.get("latestMtime"), (int, float)):
            raise SystemExit(f"scenario_status_verify result=fail reason=latest_mtime scenario={name}")


def verify_markdown(expected_markdown: str, markdown_path: Path) -> None:
    if not markdown_path.is_file():
        raise SystemExit(f"scenario_status_verify result=fail reason=markdown_missing path={markdown_path}")
    actual = markdown_path.read_text(encoding="utf-8")
    if actual != expected_markdown:
        raise SystemExit(f"scenario_status_verify result=fail reason=markdown_mismatch path={markdown_path}")


def write_self_test_matrix(path: Path) -> None:
    path.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "run_k6() { :; }\n"
        "if [[ \"${1:-}\" == \"--list\" ]]; then\n"
        "  echo \"Available scenario groups:\"\n"
        "  echo \"self-test\"\n"
        "  echo \"Available scenarios:\"\n"
        "  echo \"login-smoke\"\n"
        "  echo \"sync-smoke\"\n"
        "  echo \"large-group-1000\"\n"
        "  exit 0\n"
        "fi\n"
        "SCENARIOS=\"login-smoke sync-smoke large-group-1000\"\n"
        "for scenario in ${SCENARIOS}; do\n"
        "  case \"${scenario}\" in\n"
        "    login-smoke)\n"
        "      run_k6 \"${scenario}\" \"http-auth\" \"api\" \"smoke\" \"http-auth-login.js\"\n"
        "      ;;\n"
        "    sync-smoke)\n"
        "      run_k6 \"${scenario}\" \"http-sync\" \"api\" \"smoke\" \"http-sync.js\"\n"
        "      ;;\n"
        "    large-group-1000)\n"
        "      :\n"
        "      ;;\n"
        "  esac\n"
        "done\n",
        encoding="utf-8",
    )
    path.chmod(0o755)


def write_report(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")


def self_test_args(**overrides: Any) -> argparse.Namespace:
    values = {
        "filter_target": False,
        "base_url": "",
        "tcp_host": "",
        "tcp_port": "",
    }
    values.update(overrides)
    return argparse.Namespace(**values)


def expect_system_exit(label: str, fn: Any) -> None:
    try:
        fn()
    except SystemExit:
        print(label)
        return
    raise SystemExit(f"scenario_status_self_test result=fail reason={label}_not_rejected")


def run_self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="scenario-status-self-test-") as tmp:
        root = Path(tmp)
        matrix = root / "run_perf_scenarios.sh"
        results = root / "results"
        write_self_test_matrix(matrix)
        target = {"baseURL": "https://prod.example.com", "tcpHost": "tcp.prod.example.com", "tcpPort": "9000"}
        other_target = {"baseURL": "https://other.example.com", "tcpHost": "tcp.other.example.com", "tcpPort": "9000"}
        write_report(results / "001" / "report.json", {
            "target": target,
            "scenarios": [
                {"name": "login-smoke", "status": "PASS", "category": "http-auth", "target": "api", "p99": ["120ms"]},
                {"name": "sync-smoke", "status": "FAIL", "category": "http-sync", "target": "api", "reasons": ["p99 regression"], "p99": ["900ms"]},
            ],
        })
        write_report(results / "002" / "report.json", {
            "target": other_target,
            "scenarios": [
                {"name": "sync-smoke", "status": "PASS", "category": "http-sync", "target": "api", "p99": ["100ms"]},
            ],
        })
        rows = collect_scenario_status(results, matrix_script=matrix, args=self_test_args())
        payload = build_payload(rows, results, self_test_args())
        verify_payload(payload)
        if payload["latestStatusCounts"]["FAIL"] != 0 or payload["latestStatusCounts"]["PASS"] != 2:
            raise SystemExit("scenario_status_self_test result=fail reason=latest_status_selection")
        if payload["latestStatusCounts"]["NEVER_RUN"] != 1:
            raise SystemExit("scenario_status_self_test result=fail reason=never_run_missing")
        print("self_test_latest_run_selected")
        print("self_test_never_run_seeded")

        filtered_args = self_test_args(filter_target=True, base_url=target["baseURL"], tcp_host=target["tcpHost"], tcp_port=target["tcpPort"])
        filtered_rows = collect_scenario_status(results, matrix_script=matrix, args=filtered_args)
        filtered_payload = build_payload(filtered_rows, results, filtered_args)
        verify_payload(filtered_payload)
        if filtered_payload["latestStatusCounts"]["FAIL"] != 1 or filtered_payload["latestStatusCounts"]["PASS"] != 1:
            raise SystemExit("scenario_status_self_test result=fail reason=target_filter_counts")
        print("self_test_target_filter_applied")

        markdown = build_markdown(filtered_rows, results, 2)
        markdown_path = root / "scenario-status.md"
        markdown_path.write_text(markdown + "\nextra drift\n", encoding="utf-8")
        expect_system_exit("self_test_markdown_mismatch_rejected", lambda: verify_markdown(markdown, markdown_path))

        bad_payload = dict(filtered_payload)
        bad_payload["scenarioCount"] += 1
        expect_system_exit("self_test_count_mismatch_rejected", lambda: verify_payload(bad_payload))

        duplicate_payload = dict(filtered_payload)
        duplicate_payload["scenarios"] = [*filtered_payload["scenarios"], filtered_payload["scenarios"][0]]
        duplicate_payload["scenarioCount"] += 1
        duplicate_counts = dict(filtered_payload["latestStatusCounts"])
        duplicate_counts[str(filtered_payload["scenarios"][0]["latestStatus"])] += 1
        duplicate_payload["latestStatusCounts"] = duplicate_counts
        expect_system_exit("self_test_duplicate_scenario_rejected", lambda: verify_payload(duplicate_payload))

    print("scenario_status_self_test result=pass")


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    fieldnames = [
        "scenario",
        "category",
        "target",
        "runCount",
        "passCount",
        "failCount",
        "unknownCount",
        "latestRunID",
        "latestRunDir",
        "latestMtime",
        "latestBaseURL",
        "latestTCPHost",
        "latestTCPPort",
        "latestStatus",
        "latestReason",
        "latestP99",
        "optimizationHint",
    ]
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def main() -> int:
    parser = argparse.ArgumentParser(description="Summarize latest status per performance scenario across result reports.")
    parser.add_argument("--results-dir", default="results")
    parser.add_argument("--limit", type=int, help="Only display the first N scenarios after status/category sorting.")
    parser.add_argument("--matrix-script", help="Optional run_perf_scenarios.sh path; listed scenarios with no report become NEVER_RUN.")
    parser.add_argument("--filter-target", action="store_true", help="Only count reports/scenarios whose recorded target matches the supplied base/tcp target.")
    parser.add_argument("--base-url", default="")
    parser.add_argument("--tcp-host", default="")
    parser.add_argument("--tcp-port", default="")
    parser.add_argument("--output", help="Write Markdown scenario status report.")
    parser.add_argument("--json-output", help="Write machine-readable scenario status report.")
    parser.add_argument("--csv-output", help="Write flat scenario status CSV.")
    parser.add_argument("--self-test", action="store_true", help="Run internal scenario status verifier fixtures.")
    args = parser.parse_args()

    if args.self_test:
        run_self_test()
        return 0

    if args.limit is not None and args.limit <= 0:
        parser.error("--limit must be greater than 0")

    results_dir = Path(args.results_dir)
    matrix_script = Path(args.matrix_script).resolve() if args.matrix_script else None
    rows = collect_scenario_status(results_dir, matrix_script=matrix_script, args=args)
    markdown = build_markdown(rows, results_dir, args.limit)
    payload = build_payload(rows, results_dir, args)
    verify_payload(payload)
    if args.output:
        Path(args.output).write_text(markdown, encoding="utf-8")
        verify_markdown(markdown, Path(args.output))
    else:
        print(markdown)
    if args.json_output:
        Path(args.json_output).write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    if args.csv_output:
        write_csv(Path(args.csv_output), rows)
    return 1 if payload["latestStatusCounts"]["FAIL"] > 0 else 0


if __name__ == "__main__":
    raise SystemExit(main())
