#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import tempfile
from pathlib import Path
from typing import Any

from perf_matrix_audit import K6Scenario, list_output_scenarios, parse_k6_scenarios, read_text


HTTP_MATURITY_PROFILES = ("smoke", "baseline", "capacity")


def infer_tcp_category(name: str) -> str:
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


def scenario_profile(name: str, record: K6Scenario | None = None) -> str:
    if record is not None:
        profile = record.profile
        for suffix in HTTP_MATURITY_PROFILES:
            if profile.endswith(suffix) or name.endswith(f"-{suffix}"):
                return suffix
    for suffix in HTTP_MATURITY_PROFILES:
        if name.endswith(f"-{suffix}"):
            return suffix
    if name.startswith("online-idle-"):
        return "online"
    if name.startswith("reconnect-soak-"):
        return "reconnect-soak"
    if name.startswith("reconnect-drill-"):
        return "reconnect-drill"
    if name.startswith("multi-device-online-"):
        return "multi-device-online"
    if name.startswith("multi-device-delivery-"):
        return "multi-device-delivery"
    if name.startswith("pair-delivery-"):
        return "pair-delivery"
    if name.startswith("online-chat-mix-"):
        return "online-chat-mix"
    if name.startswith("direct-burst-"):
        return "direct-burst"
    if name.startswith("group-delivery-"):
        return "group-delivery"
    if name.startswith("large-group-"):
        return "large-group"
    return "custom"


def domain_for(category: str, name: str) -> str:
    value = f"{category} {name}"
    if "entrypoint" in value or "preflight" in value:
        return "preflight"
    if "hot-write" in value or "large-group" in value:
        return "hot-large-group"
    if "group-delivery" in value:
        return "group-realtime"
    if "online" in value or "delivery" in value or category.startswith("tcp"):
        return "tcp-realtime"
    if "login" in value or "auth" in value or "account" in value or "session" in value or "push-token" in value:
        return "auth-session"
    if "client-sync" in value or "user-journey" in value or "mixed-workload" in value or "offline-catchup" in value or "inbox-fanout" in value or "multi-device-sync" in value or "client-health" in value or "cold-start" in value or "timeline" in value or "domain-events" in value:
        return "client-sync"
    if "group" in value:
        return "group-lifecycle"
    if "contact" in value or "profile" in value:
        return "social-profile"
    if "safety" in value or "access-control" in value or "admin-report" in value:
        return "safety-moderation"
    if "media" in value or "file" in value:
        return "media-file"
    if "ai-stream" in value:
        return "ai-stream"
    if "governance" in value or "conversation-preferences" in value or "conversation-visibility" in value or "message-forward" in value or "direct-message-lifecycle" in value or "read-state" in value or "search" in value or "convergence" in value or "small-group" in value:
        return "message-workflow"
    return "other"


def family_for(name: str) -> str:
    for suffix in HTTP_MATURITY_PROFILES:
        marker = f"-{suffix}"
        if name.endswith(marker):
            return name[: -len(marker)]
    if name.startswith("online-idle-"):
        return "online-idle"
    if name.startswith("reconnect-soak-"):
        return "reconnect-soak"
    if name.startswith("reconnect-drill-"):
        return "reconnect-drill"
    if name.startswith("multi-device-online-"):
        return "multi-device-online"
    if name.startswith("multi-device-delivery-"):
        return "multi-device-delivery"
    if name.startswith("pair-delivery-"):
        return "pair-delivery"
    if name.startswith("online-chat-mix-"):
        return "online-chat-mix"
    if name.startswith("direct-burst-"):
        return "direct-burst"
    if name.startswith("group-delivery-"):
        return "group-delivery"
    if name.startswith("large-group-"):
        return "large-group"
    return name


def load_status(path: Path | None) -> dict[str, dict[str, Any]]:
    if path is None or not path.exists():
        return {}
    data = json.loads(path.read_text())
    return {
        str(row.get("scenario") or ""): row
        for row in data.get("scenarios") or []
        if row.get("scenario")
    }


def collect(script_path: Path, status_json: Path | None = None) -> tuple[list[dict[str, Any]], list[dict[str, Any]], dict[str, Any]]:
    text = read_text(script_path)
    _, listed = list_output_scenarios(script_path)
    k6_by_name = {record.name: record for record in parse_k6_scenarios(text)}
    statuses = load_status(status_json)

    scenarios: list[dict[str, Any]] = []
    for name in listed:
        record = k6_by_name.get(name)
        category = record.category if record else infer_tcp_category(name)
        profile = scenario_profile(name, record)
        family = family_for(name)
        domain = domain_for(category, name)
        status = statuses.get(name, {})
        scenarios.append({
            "scenario": name,
            "family": family,
            "domain": domain,
            "category": category,
            "target": record.target if record else "",
            "profile": profile,
            "script": record.script if record else "",
            "latestStatus": status.get("latestStatus", "NO_RESULT"),
            "latestReason": status.get("latestReason", ""),
            "latestP99": status.get("latestP99", ""),
            "runCount": int(status.get("runCount") or 0),
        })

    family_profiles: dict[str, set[str]] = {}
    family_domains: dict[str, str] = {}
    family_categories: dict[str, set[str]] = {}
    for row in scenarios:
        family = str(row["family"])
        family_profiles.setdefault(family, set()).add(str(row["profile"]))
        family_domains.setdefault(family, str(row["domain"]))
        family_categories.setdefault(family, set()).add(str(row["category"]))

    gaps: list[dict[str, Any]] = []
    for family, profiles in sorted(family_profiles.items()):
        categories = family_categories.get(family, set())
        is_http_family = any(category.startswith("http-") for category in categories)
        if not is_http_family:
            continue
        missing = [profile for profile in HTTP_MATURITY_PROFILES if profile not in profiles]
        if missing:
            gaps.append({
                "family": family,
                "domain": family_domains.get(family, "other"),
                "existingProfiles": sorted(profiles),
                "missingProfiles": missing,
                "severity": "warning" if "smoke" in profiles else "info",
                "recommendation": f"Add {', '.join(missing)} variant(s) when this workflow becomes a capacity target.",
            })

    domain_summary: dict[str, dict[str, Any]] = {}
    for row in scenarios:
        domain = str(row["domain"])
        bucket = domain_summary.setdefault(domain, {
            "domain": domain,
            "scenarioCount": 0,
            "families": set(),
            "profiles": set(),
            "fail": 0,
            "unknown": 0,
            "neverRun": 0,
            "pass": 0,
            "noResult": 0,
        })
        bucket["scenarioCount"] += 1
        bucket["families"].add(str(row["family"]))
        bucket["profiles"].add(str(row["profile"]))
        latest = str(row["latestStatus"])
        if latest == "FAIL":
            bucket["fail"] += 1
        elif latest == "UNKNOWN":
            bucket["unknown"] += 1
        elif latest == "NEVER_RUN":
            bucket["neverRun"] += 1
        elif latest == "PASS":
            bucket["pass"] += 1
        else:
            bucket["noResult"] += 1

    domain_rows = []
    for bucket in domain_summary.values():
        domain_rows.append({
            "domain": bucket["domain"],
            "scenarioCount": bucket["scenarioCount"],
            "familyCount": len(bucket["families"]),
            "profiles": sorted(bucket["profiles"]),
            "fail": bucket["fail"],
            "unknown": bucket["unknown"],
            "neverRun": bucket["neverRun"],
            "pass": bucket["pass"],
            "noResult": bucket["noResult"],
        })
    domain_rows.sort(key=lambda item: (-int(item["scenarioCount"]), str(item["domain"])))

    summary = {
        "scenarioCount": len(scenarios),
        "familyCount": len(family_profiles),
        "domainCount": len(domain_rows),
        "maturityGapCount": len(gaps),
        "httpFamilyCount": sum(
            1 for family, categories in family_categories.items()
            if any(category.startswith("http-") for category in categories)
        ),
        "statusAttached": bool(statuses),
    }
    return scenarios, gaps, {"summary": summary, "domains": domain_rows}


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


def build_markdown(scenarios: list[dict[str, Any]], gaps: list[dict[str, Any]], meta: dict[str, Any]) -> str:
    summary = meta["summary"]
    domain_rows = [["Domain", "Scenarios", "Families", "Profiles", "FAIL", "UNKNOWN", "NEVER_RUN", "PASS", "NO_RESULT"]]
    for row in meta["domains"]:
        domain_rows.append([
            str(row["domain"]),
            str(row["scenarioCount"]),
            str(row["familyCount"]),
            ", ".join(row["profiles"]),
            str(row["fail"]),
            str(row["unknown"]),
            str(row["neverRun"]),
            str(row["pass"]),
            str(row["noResult"]),
        ])

    gap_rows = [["Family", "Domain", "Existing", "Missing", "Recommendation"]]
    for row in gaps:
        gap_rows.append([
            str(row["family"]),
            str(row["domain"]),
            ", ".join(row["existingProfiles"]),
            ", ".join(row["missingProfiles"]),
            str(row["recommendation"]),
        ])

    scenario_rows = [["Scenario", "Domain", "Family", "Category", "Profile", "Latest", "P99"]]
    for row in scenarios:
        scenario_rows.append([
            str(row["scenario"]),
            str(row["domain"]),
            str(row["family"]),
            str(row["category"]),
            str(row["profile"]),
            str(row["latestStatus"]),
            str(row["latestP99"] or "-"),
        ])

    recommendations = []
    if gaps:
        recommendations.append("Maturity gaps are not matrix errors; use them as the backlog for adding baseline/capacity scenarios beyond smoke coverage.")
    if summary["statusAttached"]:
        recommendations.append("Use domain FAIL/UNKNOWN/NEVER_RUN counts to pick the next scenario batch after entrypoint blockers are cleared.")
    else:
        recommendations.append("Pass --scenario-status after a run to combine catalog coverage with latest runtime results.")

    return "\n".join([
        "# Performance Scenario Catalog",
        "",
        f"- scenarios: `{summary['scenarioCount']}`",
        f"- scenario families: `{summary['familyCount']}`",
        f"- domains: `{summary['domainCount']}`",
        f"- HTTP families: `{summary['httpFamilyCount']}`",
        f"- maturity gaps: `{summary['maturityGapCount']}`",
        f"- status attached: `{summary['statusAttached']}`",
        "",
        "## Domain Summary",
        "",
        markdown_table(domain_rows),
        "",
        "## Maturity Gaps",
        "",
        markdown_table(gap_rows) if gaps else "No HTTP maturity gaps found.",
        "",
        "## Scenario Detail",
        "",
        markdown_table(scenario_rows),
        "",
        "## Recommendations",
        "",
        *(f"- {item}" for item in recommendations),
        "",
    ])


def verify_payload(payload: dict[str, Any]) -> None:
    if not isinstance(payload, dict):
        raise SystemExit("scenario_catalog_verify result=fail reason=payload_not_object")
    summary = payload.get("summary")
    if not isinstance(summary, dict):
        raise SystemExit("scenario_catalog_verify result=fail reason=summary_not_object")
    scenarios = payload.get("scenarios")
    gaps = payload.get("maturityGaps")
    domains = payload.get("domains")
    if not isinstance(scenarios, list):
        raise SystemExit("scenario_catalog_verify result=fail reason=scenarios_not_list")
    if not isinstance(gaps, list):
        raise SystemExit("scenario_catalog_verify result=fail reason=gaps_not_list")
    if not isinstance(domains, list):
        raise SystemExit("scenario_catalog_verify result=fail reason=domains_not_list")

    for key in ("scenarioCount", "familyCount", "domainCount", "maturityGapCount", "httpFamilyCount"):
        value = summary.get(key)
        if not isinstance(value, int) or value < 0:
            raise SystemExit(f"scenario_catalog_verify result=fail reason={key}")
    if not isinstance(summary.get("statusAttached"), bool):
        raise SystemExit("scenario_catalog_verify result=fail reason=status_attached_not_bool")
    if summary["scenarioCount"] != len(scenarios):
        raise SystemExit("scenario_catalog_verify result=fail reason=scenario_count_mismatch")
    if summary["maturityGapCount"] != len(gaps):
        raise SystemExit("scenario_catalog_verify result=fail reason=gap_count_mismatch")
    if summary["domainCount"] != len(domains):
        raise SystemExit("scenario_catalog_verify result=fail reason=domain_count_mismatch")

    scenario_names: set[str] = set()
    families: set[str] = set()
    domains_from_scenarios: set[str] = set()
    http_families: set[str] = set()
    for row in scenarios:
        if not isinstance(row, dict):
            raise SystemExit("scenario_catalog_verify result=fail reason=scenario_row_not_object")
        name = str(row.get("scenario") or "")
        family = str(row.get("family") or "")
        domain = str(row.get("domain") or "")
        category = str(row.get("category") or "")
        profile = str(row.get("profile") or "")
        if not name or not family or not domain or not profile:
            raise SystemExit(f"scenario_catalog_verify result=fail reason=scenario_field_missing scenario={name or '-'}")
        if name in scenario_names:
            raise SystemExit(f"scenario_catalog_verify result=fail reason=duplicate_scenario scenario={name}")
        scenario_names.add(name)
        families.add(family)
        domains_from_scenarios.add(domain)
        if category.startswith("http-"):
            http_families.add(family)
        run_count = row.get("runCount")
        if not isinstance(run_count, int) or run_count < 0:
            raise SystemExit(f"scenario_catalog_verify result=fail reason=run_count scenario={name}")

    if summary["familyCount"] != len(families):
        raise SystemExit("scenario_catalog_verify result=fail reason=family_count_mismatch")
    if summary["httpFamilyCount"] != len(http_families):
        raise SystemExit("scenario_catalog_verify result=fail reason=http_family_count_mismatch")

    domain_names: set[str] = set()
    for row in domains:
        if not isinstance(row, dict):
            raise SystemExit("scenario_catalog_verify result=fail reason=domain_row_not_object")
        domain = str(row.get("domain") or "")
        if not domain:
            raise SystemExit("scenario_catalog_verify result=fail reason=domain_name_missing")
        if domain in domain_names:
            raise SystemExit(f"scenario_catalog_verify result=fail reason=duplicate_domain domain={domain}")
        domain_names.add(domain)
        if not isinstance(row.get("profiles"), list):
            raise SystemExit(f"scenario_catalog_verify result=fail reason=domain_profiles_not_list domain={domain}")
    if domain_names != domains_from_scenarios:
        raise SystemExit("scenario_catalog_verify result=fail reason=domain_set_mismatch")

    for row in gaps:
        if not isinstance(row, dict):
            raise SystemExit("scenario_catalog_verify result=fail reason=gap_row_not_object")
        family = str(row.get("family") or "")
        if family not in families:
            raise SystemExit(f"scenario_catalog_verify result=fail reason=gap_unknown_family family={family or '-'}")
        missing = row.get("missingProfiles")
        existing = row.get("existingProfiles")
        if not isinstance(missing, list) or not missing:
            raise SystemExit(f"scenario_catalog_verify result=fail reason=gap_missing_profiles family={family}")
        if not isinstance(existing, list) or not existing:
            raise SystemExit(f"scenario_catalog_verify result=fail reason=gap_existing_profiles family={family}")
        invalid_missing = [item for item in missing if item not in HTTP_MATURITY_PROFILES]
        if invalid_missing:
            raise SystemExit(f"scenario_catalog_verify result=fail reason=gap_invalid_profile family={family}")


def verify_markdown(expected_markdown: str, markdown_path: Path) -> None:
    if not markdown_path.is_file():
        raise SystemExit(f"scenario_catalog_verify result=fail reason=markdown_missing path={markdown_path}")
    actual = markdown_path.read_text(encoding="utf-8")
    if actual != expected_markdown:
        raise SystemExit(f"scenario_catalog_verify result=fail reason=markdown_mismatch path={markdown_path}")


def write_self_test_script(path: Path, *, scenarios: list[tuple[str, str, str, str, str]]) -> None:
    list_output = "\n".join(f"    echo \"{name}\"" for name, *_ in scenarios)
    cases = "\n".join(
        [
            f"    {name})\n"
            f"      run_k6 \"${{scenario}}\" \"{category}\" \"{target}\" \"{profile}\" \"{script}\"\n"
            "      ;;\n"
            for name, category, target, profile, script in scenarios
        ]
    )
    path.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "DEFAULT_SCENARIOS=\"auth-login-smoke\"\n"
        "run_k6() { :; }\n"
        "if [[ \"${1:-}\" == \"--list\" ]]; then\n"
        "  echo \"Available scenario groups:\"\n"
        "  echo \"self-test\"\n"
        "  echo \"Available scenarios:\"\n"
        f"{list_output}\n"
        "  exit 0\n"
        "fi\n"
        "SCENARIOS=\"${DEFAULT_SCENARIOS}\"\n"
        "for scenario in ${SCENARIOS}; do\n"
        "  case \"${scenario}\" in\n"
        f"{cases}"
        "  esac\n"
        "done\n",
        encoding="utf-8",
    )
    path.chmod(0o755)


def expect_system_exit(label: str, fn: Any) -> None:
    try:
        fn()
    except SystemExit:
        print(label)
        return
    raise SystemExit(f"scenario_catalog_self_test result=fail reason={label}_not_rejected")


def run_self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="scenario-catalog-self-test-") as tmp:
        root = Path(tmp)
        script = root / "run_perf_scenarios.sh"
        status = root / "status.json"
        write_self_test_script(
            script,
            scenarios=[
                ("auth-login-smoke", "http-auth", "api", "auth-smoke", "http-auth-login.js"),
                ("auth-login-baseline", "http-auth", "api", "auth-baseline", "http-auth-login.js"),
                ("group-delivery-1000", "tcp-group-delivery", "tcp", "group-delivery", ""),
            ],
        )
        status.write_text(json.dumps({
            "scenarios": [
                {
                    "scenario": "auth-login-smoke",
                    "latestStatus": "PASS",
                    "latestReason": "ok",
                    "latestP99": "120ms",
                    "runCount": 2,
                },
                {
                    "scenario": "auth-login-baseline",
                    "latestStatus": "FAIL",
                    "latestReason": "p99 regression",
                    "latestP99": "900ms",
                    "runCount": 1,
                },
            ]
        }), encoding="utf-8")
        scenarios, gaps, meta = collect(script, status)
        markdown = build_markdown(scenarios, gaps, meta)
        payload = {**meta, "maturityGaps": gaps, "scenarios": scenarios}
        verify_payload(payload)
        if meta["summary"]["scenarioCount"] != 3:
            raise SystemExit("scenario_catalog_self_test result=fail reason=scenario_count")
        if meta["summary"]["statusAttached"] is not True:
            raise SystemExit("scenario_catalog_self_test result=fail reason=status_not_attached")
        if not any(row["family"] == "auth-login" and "capacity" in row["missingProfiles"] for row in gaps):
            raise SystemExit("scenario_catalog_self_test result=fail reason=maturity_gap_not_detected")
        if not any(row["scenario"] == "group-delivery-1000" and row["domain"] == "group-realtime" for row in scenarios):
            raise SystemExit("scenario_catalog_self_test result=fail reason=tcp_domain_not_detected")
        print("self_test_maturity_gap_detected")
        print("self_test_status_attached")
        print("self_test_tcp_domain_detected")

        markdown_path = root / "scenario-catalog.md"
        markdown_path.write_text(markdown + "\nextra drift\n", encoding="utf-8")
        expect_system_exit("self_test_markdown_mismatch_rejected", lambda: verify_markdown(markdown, markdown_path))

        bad_payload = dict(payload)
        bad_summary = dict(payload["summary"])
        bad_summary["scenarioCount"] += 1
        bad_payload["summary"] = bad_summary
        expect_system_exit("self_test_summary_count_rejected", lambda: verify_payload(bad_payload))

        duplicate_payload = dict(payload)
        duplicate_payload["scenarios"] = [*payload["scenarios"], payload["scenarios"][0]]
        duplicate_summary = dict(payload["summary"])
        duplicate_summary["scenarioCount"] += 1
        duplicate_payload["summary"] = duplicate_summary
        expect_system_exit("self_test_duplicate_scenario_rejected", lambda: verify_payload(duplicate_payload))

    print("scenario_catalog_self_test result=pass")


def write_csv(path: Path, scenarios: list[dict[str, Any]]) -> None:
    fieldnames = ["scenario", "family", "domain", "category", "target", "profile", "script", "latestStatus", "latestReason", "latestP99", "runCount"]
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in scenarios:
            writer.writerow(row)


def main() -> int:
    parser = argparse.ArgumentParser(description="Catalog performance scenarios by product domain, family, maturity, and latest status.")
    parser.add_argument("--script", default="run_perf_scenarios.sh", help="Path to run_perf_scenarios.sh.")
    parser.add_argument("--scenario-status", help="Optional perf_scenario_status.py JSON output.")
    parser.add_argument("--output", help="Write Markdown catalog.")
    parser.add_argument("--json-output", help="Write machine-readable catalog.")
    parser.add_argument("--csv-output", help="Write flat scenario CSV.")
    parser.add_argument("--strict", action="store_true", help="Exit non-zero if HTTP maturity gaps exist.")
    parser.add_argument("--self-test", action="store_true", help="Run internal scenario catalog verifier fixtures.")
    args = parser.parse_args()

    if args.self_test:
        run_self_test()
        return 0

    scenarios, gaps, meta = collect(
        Path(args.script),
        Path(args.scenario_status) if args.scenario_status else None,
    )
    markdown = build_markdown(scenarios, gaps, meta)
    payload = {
        **meta,
        "maturityGaps": gaps,
        "scenarios": scenarios,
    }
    verify_payload(payload)

    if args.output:
        Path(args.output).write_text(markdown, encoding="utf-8")
        verify_markdown(markdown, Path(args.output))
    else:
        print(markdown)
    if args.json_output:
        Path(args.json_output).write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    if args.csv_output:
        write_csv(Path(args.csv_output), scenarios)
    return 1 if args.strict and gaps else 0


if __name__ == "__main__":
    raise SystemExit(main())
