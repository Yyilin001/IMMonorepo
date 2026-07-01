#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def read_report(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text())
    except Exception as exc:
        raise SystemExit(f"Failed to read report JSON {path}: {exc}") from exc


def has_entrypoint_failure(scenario: dict[str, Any]) -> bool:
    category = str(scenario.get("category", ""))
    status = str(scenario.get("status", ""))
    reasons = " ".join(str(item) for item in scenario.get("reasons") or [])
    diagnostics = " ".join(str(item) for item in scenario.get("diagnostics") or [])
    hint = str(scenario.get("optimizationHint") or "")
    return (
        category == "preflight" and status == "FAIL"
        or "local_network_proxy_http_403_intercept" in reasons
        or "local_network_proxy_http_403_intercept" in diagnostics
        or "uniform_empty_403" in reasons
        or "uniform_empty_403" in diagnostics
        or "HTTP 403" in reasons
        or "status=403" in reasons
        or "HTTP 403" in diagnostics
        or "entrypoint/deployment" in hint
    )


def scenario_allowed_unknown(scenario: dict[str, Any], allowed_categories: set[str]) -> bool:
    return str(scenario.get("category", "")) in allowed_categories


def main() -> int:
    parser = argparse.ArgumentParser(description="Gate a performance report.json.")
    parser.add_argument("--report", required=True, help="Path to report.json")
    parser.add_argument("--allow-unknown", action="store_true", help="Allow all UNKNOWN scenarios.")
    parser.add_argument(
        "--allow-unknown-category",
        action="append",
        default=[],
        help="Allow UNKNOWN scenarios in this category. May be repeated.",
    )
    parser.add_argument("--allow-entrypoint-failure", action="store_true")
    args = parser.parse_args()

    report_path = Path(args.report)
    report = read_report(report_path)
    allowed_unknown_categories = set(args.allow_unknown_category)
    failures: list[str] = []
    warnings: list[str] = []

    scenarios = report.get("scenarios") or []
    if not scenarios:
        failures.append("report contains no scenarios")

    for scenario in scenarios:
        name = str(scenario.get("name", "<unknown>"))
        category = str(scenario.get("category", "-"))
        status = str(scenario.get("status", "UNKNOWN"))
        if has_entrypoint_failure(scenario) and not args.allow_entrypoint_failure:
            failures.append(f"{name}: entrypoint failure")
            continue
        if status == "FAIL":
            reasons = "; ".join(str(item) for item in scenario.get("reasons") or [])
            failures.append(f"{name}: FAIL {reasons}".strip())
        elif status == "UNKNOWN":
            if args.allow_unknown or scenario_allowed_unknown(scenario, allowed_unknown_categories):
                warnings.append(f"{name}: UNKNOWN allowed ({category})")
            else:
                failures.append(f"{name}: UNKNOWN ({category})")
        elif status != "PASS":
            failures.append(f"{name}: unexpected status {status}")

    print(f"Performance gate: report={report_path}")
    print(f"scenarios={len(scenarios)} failures={len(failures)} warnings={len(warnings)}")
    for item in warnings:
        print(f"WARN {item}")
    for item in failures:
        print(f"FAIL {item}")
    if failures:
        return 1
    print("PASS performance gate")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
