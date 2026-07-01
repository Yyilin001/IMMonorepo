#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import tempfile
from pathlib import Path
from typing import Any

from perf_scenario_catalog import collect


DEFAULT_REQUIRED_DOMAINS = (
    "auth-session",
    "client-sync",
    "message-workflow",
    "group-lifecycle",
    "group-realtime",
    "social-profile",
    "safety-moderation",
    "media-file",
    "tcp-realtime",
    "ai-stream",
)


def read_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise SystemExit(f"Failed to read JSON {path}: {exc}") from exc


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def issue(kind: str, severity: str, profile: str, detail: str) -> dict[str, str]:
    return {
        "kind": kind,
        "severity": severity,
        "profile": profile,
        "detail": detail,
    }


def audit(args: argparse.Namespace) -> dict[str, Any]:
    profile_catalog = read_json(Path(args.profile_catalog))
    profiles = profile_catalog.get("profiles") if isinstance(profile_catalog, dict) else {}
    if not isinstance(profiles, dict):
        profiles = {}

    scenarios, gaps, meta = collect(Path(args.matrix_script))
    scenario_by_name = {str(row["scenario"]): row for row in scenarios}
    required_domains = [str(item) for item in args.required_domain if str(item)]
    forbidden_prefixes = [str(item) for item in args.forbid_scenario_prefix if str(item)]
    profile_rows: list[dict[str, Any]] = []
    issues: list[dict[str, str]] = []

    for profile in args.profile:
        profile_scenarios_raw = profiles.get(profile)
        if not isinstance(profile_scenarios_raw, list) or not profile_scenarios_raw:
            issues.append(issue("missing-profile", "error", profile, "profile is missing or has no scenarios."))
            profile_rows.append({
                "profile": profile,
                "scenarioCount": 0,
                "domainCount": 0,
                "missingDomains": required_domains,
                "largeGroupScenarioCount": 0,
                "forbiddenScenarioCount": 0,
                "unknownScenarioCount": 0,
                "status": "FAIL",
            })
            continue

        profile_scenarios = [str(item) for item in profile_scenarios_raw if str(item)]
        unknown = [name for name in profile_scenarios if name not in scenario_by_name]
        for name in unknown:
            issues.append(issue("unknown-scenario", "error", profile, f"scenario is not listed by run_perf_scenarios.sh: {name}"))

        known_rows = [scenario_by_name[name] for name in profile_scenarios if name in scenario_by_name]
        domain_counts: dict[str, int] = {}
        for row in known_rows:
            domain = str(row.get("domain") or "other")
            domain_counts[domain] = domain_counts.get(domain, 0) + 1

        missing_domains = [domain for domain in required_domains if domain_counts.get(domain, 0) <= 0]
        for domain in missing_domains:
            issues.append(issue("missing-domain", "error", profile, f"profile does not cover required product domain: {domain}"))

        large_group = [name for name in profile_scenarios if name.startswith("large-group-")]
        if large_group and not args.allow_large_group:
            issues.append(issue("large-group-in-product-profile", "error", profile, "normal product profiles must not include isolated large-group stress scenarios."))

        forbidden = [
            name
            for name in profile_scenarios
            if any(name.startswith(prefix) for prefix in forbidden_prefixes)
        ]
        if forbidden:
            issues.append(issue("forbidden-scenario-prefix", "error", profile, f"profile includes forbidden scenario prefix: {', '.join(sorted(set(forbidden))[:5])}"))

        if len(profile_scenarios) < args.min_scenarios:
            issues.append(issue("insufficient-scenario-count", "error", profile, f"profile has {len(profile_scenarios)} scenarios, expected at least {args.min_scenarios}."))

        profile_rows.append({
            "profile": profile,
            "scenarioCount": len(profile_scenarios),
            "domainCount": len(domain_counts),
            "domains": [
                {"domain": name, "scenarioCount": count}
                for name, count in sorted(domain_counts.items())
            ],
            "missingDomains": missing_domains,
            "largeGroupScenarioCount": len(large_group),
            "forbiddenScenarioCount": len(forbidden),
            "unknownScenarioCount": len(unknown),
            "status": "PASS" if not (missing_domains or large_group or forbidden or unknown or len(profile_scenarios) < args.min_scenarios) else "FAIL",
        })

    if gaps and args.require_no_maturity_gaps:
        issues.append(issue("maturity-gaps", "error", "-", f"scenario catalog has {len(gaps)} HTTP maturity gap(s)."))

    error_count = sum(1 for row in issues if row["severity"] == "error")
    warning_count = sum(1 for row in issues if row["severity"] == "warning")
    return {
        "schemaVersion": 1,
        "status": "PASS" if error_count == 0 else "FAIL",
        "profileCatalog": args.profile_catalog,
        "matrixScript": args.matrix_script,
        "profilesChecked": list(args.profile),
        "requiredDomains": required_domains,
        "forbiddenScenarioPrefixes": forbidden_prefixes,
        "allowLargeGroup": bool(args.allow_large_group),
        "minScenarios": int(args.min_scenarios),
        "scenarioCatalogSummary": meta.get("summary") or {},
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
    profile_rows = [["Profile", "Status", "Scenarios", "Domains", "Missing Domains", "Large Group", "Forbidden", "Unknown"]]
    for row in payload["profiles"]:
        profile_rows.append([
            f"`{row['profile']}`",
            str(row["status"]),
            str(row["scenarioCount"]),
            str(row["domainCount"]),
            ", ".join(row.get("missingDomains") or []) or "-",
            str(row["largeGroupScenarioCount"]),
            str(row["forbiddenScenarioCount"]),
            str(row["unknownScenarioCount"]),
        ])

    domain_rows = [["Profile", "Domain", "Scenarios"]]
    for row in payload["profiles"]:
        for domain in row.get("domains") or []:
            domain_rows.append([
                f"`{row['profile']}`",
                str(domain["domain"]),
                str(domain["scenarioCount"]),
            ])

    issue_rows = [["Severity", "Kind", "Profile", "Detail"]]
    for row in payload["issues"]:
        issue_rows.append([
            row["severity"],
            row["kind"],
            f"`{row['profile']}`",
            row["detail"],
        ])

    return "\n".join([
        "# Product Profile Gate",
        "",
        f"- status: `{payload['status']}`",
        f"- profiles checked: `{payload['profileCount']}`",
        f"- required domains: `{', '.join(payload['requiredDomains'])}`",
        f"- forbidden prefixes: `{', '.join(payload['forbiddenScenarioPrefixes']) or '-'}`",
        f"- minimum scenarios: `{payload['minScenarios']}`",
        f"- errors/warnings: `{payload['errorCount']}/{payload['warningCount']}`",
        "",
        "## Profiles",
        "",
        markdown_table(profile_rows),
        "",
        "## Domain Coverage",
        "",
        markdown_table(domain_rows),
        "",
        "## Issues",
        "",
        markdown_table(issue_rows) if payload["issues"] else "No product profile gate issues found.",
        "",
    ])


def verify_payload(payload: dict[str, Any]) -> None:
    if not isinstance(payload, dict):
        raise SystemExit("product_profile_gate_verify result=fail reason=json_not_object")
    if payload.get("schemaVersion") != 1:
        raise SystemExit("product_profile_gate_verify result=fail reason=schema_version")
    if payload.get("status") not in {"PASS", "FAIL"}:
        raise SystemExit("product_profile_gate_verify result=fail reason=status")

    profiles = payload.get("profiles")
    if not isinstance(profiles, list):
        raise SystemExit("product_profile_gate_verify result=fail reason=profiles_not_list")
    if int(payload.get("profileCount") or 0) != len(profiles):
        raise SystemExit("product_profile_gate_verify result=fail reason=profile_count_mismatch")

    issues = payload.get("issues")
    if not isinstance(issues, list):
        raise SystemExit("product_profile_gate_verify result=fail reason=issues_not_list")
    error_count = sum(1 for row in issues if isinstance(row, dict) and row.get("severity") == "error")
    warning_count = sum(1 for row in issues if isinstance(row, dict) and row.get("severity") == "warning")
    if int(payload.get("errorCount") or 0) != error_count:
        raise SystemExit("product_profile_gate_verify result=fail reason=error_count_mismatch")
    if int(payload.get("warningCount") or 0) != warning_count:
        raise SystemExit("product_profile_gate_verify result=fail reason=warning_count_mismatch")
    if (payload.get("status") == "PASS") != (error_count == 0):
        raise SystemExit("product_profile_gate_verify result=fail reason=status_count_mismatch")

    for key in ("profilesChecked", "requiredDomains", "forbiddenScenarioPrefixes"):
        value = payload.get(key)
        if not isinstance(value, list):
            raise SystemExit(f"product_profile_gate_verify result=fail reason={key}_not_list")

    seen_profiles: set[str] = set()
    for row in profiles:
        if not isinstance(row, dict):
            raise SystemExit("product_profile_gate_verify result=fail reason=profile_row_not_object")
        profile = str(row.get("profile") or "")
        if not profile:
            raise SystemExit("product_profile_gate_verify result=fail reason=profile_name_missing")
        if profile in seen_profiles:
            raise SystemExit(f"product_profile_gate_verify result=fail reason=duplicate_profile profile={profile}")
        seen_profiles.add(profile)
        if row.get("status") not in {"PASS", "FAIL"}:
            raise SystemExit(f"product_profile_gate_verify result=fail reason=profile_status profile={profile}")
        for key in ("scenarioCount", "domainCount", "largeGroupScenarioCount", "forbiddenScenarioCount", "unknownScenarioCount"):
            value = row.get(key)
            if not isinstance(value, int) or value < 0:
                raise SystemExit(f"product_profile_gate_verify result=fail reason=profile_{key} profile={profile}")
        if not isinstance(row.get("missingDomains"), list):
            raise SystemExit(f"product_profile_gate_verify result=fail reason=profile_missing_domains profile={profile}")
        domains = row.get("domains")
        if domains is not None and not isinstance(domains, list):
            raise SystemExit(f"product_profile_gate_verify result=fail reason=profile_domains profile={profile}")


def verify_markdown(payload: dict[str, Any], markdown_path: Path) -> None:
    verify_payload(payload)
    if not markdown_path.is_file():
        raise SystemExit(f"product_profile_gate_verify result=fail reason=markdown_missing path={markdown_path}")
    expected = build_markdown(payload)
    actual = markdown_path.read_text(encoding="utf-8")
    if actual != expected:
        raise SystemExit(f"product_profile_gate_verify result=fail reason=markdown_mismatch path={markdown_path}")


SELF_TEST_SCENARIOS = (
    "login-smoke",
    "client-sync-mix-smoke",
    "direct-message-lifecycle-smoke",
    "group-admin-smoke",
    "group-delivery-50-5",
    "contact-sync-smoke",
    "safety-block-smoke",
    "media-file-smoke",
    "online-idle-1000",
    "ai-stream-smoke",
    "large-group-1000-10",
)


def write_self_test_matrix(path: Path) -> None:
    scenario_cases = []
    for scenario in SELF_TEST_SCENARIOS:
        if scenario.startswith(("group-delivery-", "online-idle-", "large-group-")):
            scenario_cases.append(f"""    {scenario})
      ;;
""")
            continue
        category = "http-auth"
        if scenario.startswith("client-sync"):
            category = "http-client-sync"
        elif scenario.startswith("direct-message"):
            category = "http-message"
        elif scenario.startswith("group-admin"):
            category = "http-group"
        elif scenario.startswith("contact-sync"):
            category = "http-contact"
        elif scenario.startswith("safety-block"):
            category = "http-safety"
        elif scenario.startswith("media-file"):
            category = "http-media"
        elif scenario.startswith("ai-stream"):
            category = "http-ai"
        scenario_cases.append(f"""    {scenario})
      run_k6 "${{scenario}}" "{category}" "http" "smoke" "{scenario}.js"
      ;;
""")

    content = f"""#!/usr/bin/env bash
set -euo pipefail

SCENARIOS="${{SCENARIOS:-{' '.join(SELF_TEST_SCENARIOS)}}}"

if [[ "${{1:-}}" == "--list" ]]; then
  echo "Available scenario groups:"
  echo "self-test"
  echo "Available scenarios:"
  for scenario in {' '.join(SELF_TEST_SCENARIOS)}; do
    echo "${{scenario}}"
  done
  exit 0
fi

run_k6() {{ :; }}

for scenario in ${{SCENARIOS}}; do
  case "${{scenario}}" in
{''.join(scenario_cases)}    *)
      exit 1
      ;;
  esac
done
"""
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def self_test_args(root: Path, profile_catalog: Path, matrix_script: Path, *, profile: list[str] | None = None, require_no_maturity_gaps: bool = False) -> argparse.Namespace:
    return argparse.Namespace(
        profile_catalog=str(profile_catalog),
        matrix_script=str(matrix_script),
        profile=profile or ["normal-product-baseline"],
        required_domain=list(DEFAULT_REQUIRED_DOMAINS),
        forbid_scenario_prefix=["large-group-"],
        min_scenarios=10,
        allow_large_group=False,
        require_no_maturity_gaps=require_no_maturity_gaps,
        output=str(root / "product-profile-gate.md"),
        json_output=str(root / "product-profile-gate.json"),
        csv_output=str(root / "product-profile-gate.csv"),
        verify_json=None,
        verify_md=None,
        strict=True,
    )


def expect_self_test_issue(payload: dict[str, Any], kind: str, label: str) -> None:
    kinds = {str(row.get("kind") or "") for row in payload.get("issues") or [] if isinstance(row, dict)}
    if payload.get("status") != "FAIL" or kind not in kinds:
        raise SystemExit(f"product_profile_gate_self_test result=fail reason={label} status={payload.get('status')} kinds={sorted(kinds)}")


def expect_self_test_verify_failure(func: Any, label: str, expected: str) -> None:
    try:
        func()
    except SystemExit as exc:
        message = str(exc)
        if expected not in message:
            raise SystemExit(f"product_profile_gate_self_test result=fail reason={label}_wrong_error error={message}") from exc
        return
    raise SystemExit(f"product_profile_gate_self_test result=fail reason={label}_passed")


def run_self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="product-profile-gate-self-test-") as raw_root:
        root = Path(raw_root)
        matrix_script = root / "run_perf_scenarios.sh"
        profile_catalog = root / "perf_production_profiles.json"
        write_self_test_matrix(matrix_script)
        write_json(profile_catalog, {
            "schemaVersion": 1,
            "profiles": {
                "normal-product-baseline": list(SELF_TEST_SCENARIOS[:-1]),
                "missing-domain-profile": [name for name in SELF_TEST_SCENARIOS[:-2] if name != "ai-stream-smoke"],
                "large-group-profile": ["large-group-1000-10"],
                "unknown-profile": ["missing-scenario"],
            },
        })

        args = self_test_args(root, profile_catalog, matrix_script)
        payload = audit(args)
        if payload.get("status") != "PASS":
            raise SystemExit(f"product_profile_gate_self_test result=fail reason=good_profile_failed issues={payload.get('issues')}")
        verify_payload(payload)
        markdown_path = Path(args.output)
        markdown_path.write_text(build_markdown(payload), encoding="utf-8")
        verify_markdown(payload, markdown_path)

        bad_md = root / "product-profile-gate-bad.md"
        bad_md.write_text(markdown_path.read_text(encoding="utf-8").replace("- status: `PASS`", "- gateStatus: `PASS`"), encoding="utf-8")
        expect_self_test_verify_failure(
            lambda: verify_markdown(payload, bad_md),
            "self_test_markdown_mismatch",
            "markdown_mismatch",
        )

        missing_domain = audit(self_test_args(root, profile_catalog, matrix_script, profile=["missing-domain-profile"]))
        expect_self_test_issue(missing_domain, "missing-domain", "self_test_missing_domain_rejected")

        large_group = audit(self_test_args(root, profile_catalog, matrix_script, profile=["large-group-profile"]))
        expect_self_test_issue(large_group, "large-group-in-product-profile", "self_test_large_group_rejected")

        unknown = audit(self_test_args(root, profile_catalog, matrix_script, profile=["unknown-profile"]))
        expect_self_test_issue(unknown, "unknown-scenario", "self_test_unknown_scenario_rejected")

        maturity_gap = audit(self_test_args(root, profile_catalog, matrix_script, require_no_maturity_gaps=True))
        expect_self_test_issue(maturity_gap, "maturity-gaps", "self_test_maturity_gap_rejected")

    print("product_profile_gate_self_test result=pass")


def write_csv(path: Path, rows: list[dict[str, str]]) -> None:
    fieldnames = ["severity", "kind", "profile", "detail"]
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow({key: row.get(key, "") for key in fieldnames})


def main() -> int:
    parser = argparse.ArgumentParser(description="Gate production IM product profiles against required product scenario domains.")
    parser.add_argument("--profile-catalog", default=str(Path(__file__).with_name("perf_production_profiles.json")))
    parser.add_argument("--matrix-script", default=str(Path(__file__).with_name("run_perf_scenarios.sh")))
    parser.add_argument("--profile", action="append", default=None, help="Production profile to gate. Repeatable.")
    parser.add_argument("--required-domain", action="append", default=None)
    parser.add_argument("--forbid-scenario-prefix", action="append", default=None)
    parser.add_argument("--min-scenarios", type=int, default=20)
    parser.add_argument("--allow-large-group", action="store_true")
    parser.add_argument("--require-no-maturity-gaps", action="store_true")
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

    if args.min_scenarios < 1:
        parser.error("--min-scenarios must be greater than 0")
    if args.profile is None:
        args.profile = ["normal-product-baseline"]
    if args.required_domain is None:
        args.required_domain = list(DEFAULT_REQUIRED_DOMAINS)
    if args.forbid_scenario_prefix is None:
        args.forbid_scenario_prefix = ["large-group-"]

    payload = audit(args)
    markdown = build_markdown(payload)
    if args.output:
        Path(args.output).write_text(markdown, encoding="utf-8")
    else:
        print(markdown)
    if args.json_output:
        Path(args.json_output).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if args.csv_output:
        write_csv(Path(args.csv_output), payload["issues"])
    if args.output:
        verify_markdown(payload, Path(args.output))
    return 1 if args.strict and payload["status"] != "PASS" else 0


if __name__ == "__main__":
    raise SystemExit(main())
