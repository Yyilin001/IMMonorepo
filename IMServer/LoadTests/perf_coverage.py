#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Any, Sequence


@dataclass(frozen=True)
class EndpointCoverage:
    area: str
    method: str
    path: str
    critical: bool
    scenarios: tuple[str, ...]
    note: str = ""

    @property
    def covered(self) -> bool:
        return len(self.scenarios) > 0


ENDPOINTS: tuple[EndpointCoverage, ...] = (
    EndpointCoverage("root", "GET", "/", False, (), "Static app shell, not a capacity target."),
    EndpointCoverage("root", "GET", "/health", True, ("entrypoint-probe",), "Required preflight signal."),
    EndpointCoverage("auth", "POST", "/api/auth/register", True, ("account-lifecycle",), "Creates disposable lifecycle accounts; load-capacity accounts are still batch-provisioned separately."),
    EndpointCoverage("auth", "POST", "/api/auth/login", True, ("login", "auth-session", "all-http-k6"), "Covered by every HTTP scenario login path."),
    EndpointCoverage("auth", "POST", "/api/auth/refresh", True, ("auth-session",)),
    EndpointCoverage("auth", "POST", "/api/auth/email-verifications/resend", True, ("account-lifecycle",)),
    EndpointCoverage("auth", "POST", "/api/auth/email-verifications/confirm", False, ("account-lifecycle-confirm",), "Requires AUTH_EMAIL_DELIVERY_MODE=webhook plus auth_email_webhook_sink.py, or an explicit IM_ACCOUNT_VERIFICATION_CODE override."),
    EndpointCoverage("auth", "POST", "/api/auth/password-resets/request", True, ("account-lifecycle",)),
    EndpointCoverage("auth", "POST", "/api/auth/password-resets/confirm", False, ("account-lifecycle-confirm",), "Requires AUTH_EMAIL_DELIVERY_MODE=webhook plus auth_email_webhook_sink.py, or an explicit IM_ACCOUNT_PASSWORD_RESET_CODE override."),
    EndpointCoverage("auth", "GET", "/api/auth/sessions", True, ("auth-session", "auth-session-management")),
    EndpointCoverage("auth", "POST", "/api/auth/logout", True, ("auth-session",)),
    EndpointCoverage("auth", "DELETE", "/api/auth/sessions/current", True, ("auth-session",)),
    EndpointCoverage("auth", "DELETE", "/api/auth/sessions/all", True, ("auth-session-management",)),
    EndpointCoverage("auth", "DELETE", "/api/auth/sessions/:sessionID", True, ("auth-session-management",)),
    EndpointCoverage("user", "GET", "/api/me", True, ("profile-sync", "client-sync-mix", "entrypoint-probe")),
    EndpointCoverage("user", "PATCH", "/api/me/profile", True, ("profile-sync",)),
    EndpointCoverage("contact", "GET", "/api/contacts", True, ("contact-sync", "client-sync-mix")),
    EndpointCoverage("contact", "GET", "/api/contacts/changes", True, ("contact-sync", "profile-sync", "client-sync-mix")),
    EndpointCoverage("contact", "POST", "/api/contacts", True, ("contact-sync",)),
    EndpointCoverage("contact", "PATCH", "/api/contacts/:contactUserID", True, ("contact-sync",)),
    EndpointCoverage("contact", "DELETE", "/api/contacts/:contactUserID", True, ("contact-sync",)),
    EndpointCoverage("contact", "GET", "/api/contact-requests", True, ("contact-request", "contact-sync")),
    EndpointCoverage("contact", "POST", "/api/contact-requests", True, ("contact-request", "contact-sync")),
    EndpointCoverage("contact", "POST", "/api/contact-requests/:requestID/accept", True, ("contact-sync",)),
    EndpointCoverage("contact", "POST", "/api/contact-requests/:requestID/decline", True, ("contact-request",)),
    EndpointCoverage("contact", "POST", "/api/contact-requests/:requestID/cancel", True, ("contact-request",)),
    EndpointCoverage("safety", "GET", "/api/blocks", True, ("safety-block",)),
    EndpointCoverage("safety", "POST", "/api/users/:userID/block", True, ("safety-block",)),
    EndpointCoverage("safety", "DELETE", "/api/users/:userID/block", True, ("safety-block",)),
    EndpointCoverage("safety", "POST", "/api/reports", True, ("safety-block", "admin-report")),
    EndpointCoverage("push", "POST", "/api/push/device-tokens", True, ("auth-session",)),
    EndpointCoverage("push", "DELETE", "/api/push/device-tokens/:tokenID", True, ("auth-session",)),
    EndpointCoverage("file", "POST", "/api/files/upload", True, ("media-file",)),
    EndpointCoverage("file", "GET", "/api/files/download", True, ("media-file",)),
    EndpointCoverage("media", "POST", "/api/media/uploads", True, ("media-file",)),
    EndpointCoverage("media", "PUT", "/api/media/uploads/:uploadID/chunk", True, ("media-file",)),
    EndpointCoverage("media", "POST", "/api/media/uploads/:uploadID/complete", True, ("media-file",)),
    EndpointCoverage("media", "GET", "/api/media/assets/:assetID", True, ("media-file",)),
    EndpointCoverage("conversation", "GET", "/api/im/conversations", True, ("cold-start", "timeline-pagination", "convergence", "governance", "small-group", "client-sync-mix")),
    EndpointCoverage("conversation", "GET", "/api/im/conversations/changes", True, ("cold-start", "read-state", "group-admin", "group-membership", "profile-sync", "client-sync-mix")),
    EndpointCoverage("conversation", "GET", "/api/im/domain-events", True, ("domain-events", "client-sync-mix")),
    EndpointCoverage("conversation", "POST", "/api/im/client-health", True, ("client-health", "client-sync-mix")),
    EndpointCoverage("conversation", "POST", "/api/im/conversations", True, ("convergence", "small-group", "group-admin", "group-membership", "message-forward", "ai-stream")),
    EndpointCoverage("conversation", "POST", "/api/im/conversations/:conversationID/members", True, ("group-admin",)),
    EndpointCoverage("conversation", "GET", "/api/im/conversations/:conversationID/members", True, ("timeline-pagination", "group-admin", "group-membership", "group-invite")),
    EndpointCoverage("conversation", "PATCH", "/api/im/conversations/:conversationID/members/me", True, ("group-membership",)),
    EndpointCoverage("conversation", "POST", "/api/im/conversations/:conversationID/members/:memberUserID/remove", True, ("group-membership",)),
    EndpointCoverage("conversation", "POST", "/api/im/conversations/:conversationID/members/:memberUserID/role", True, ("group-membership",)),
    EndpointCoverage("conversation", "POST", "/api/im/conversations/:conversationID/title", True, ("group-admin",)),
    EndpointCoverage("conversation", "PATCH", "/api/im/conversations/:conversationID/preferences", True, ("group-admin", "governance")),
    EndpointCoverage("conversation", "PATCH", "/api/im/conversations/:conversationID/metadata", True, ("group-admin",)),
    EndpointCoverage("message", "POST", "/api/im/conversations/:conversationID/messages/forward", True, ("message-forward",)),
    EndpointCoverage("message", "POST", "/api/im/conversations/:conversationID/messages/delete", True, ("governance",)),
    EndpointCoverage("message", "POST", "/api/im/conversations/:conversationID/messages/:messageID/favorite", True, ("governance",)),
    EndpointCoverage("message", "DELETE", "/api/im/conversations/:conversationID/messages/:messageID/favorite", True, ("governance",)),
    EndpointCoverage("message", "POST", "/api/im/conversations/:conversationID/messages/:messageID/edit", True, ("governance",)),
    EndpointCoverage("message", "POST", "/api/im/conversations/:conversationID/messages/:messageID/reactions", True, ("governance",)),
    EndpointCoverage("message", "POST", "/api/im/conversations/:conversationID/messages/:messageID/recall", True, ("governance",)),
    EndpointCoverage("message", "POST", "/api/im/conversations/:conversationID/ai/messages", True, ("ai-stream",)),
    EndpointCoverage("message", "POST", "/api/im/conversations/:conversationID/messages/:messageID/stream/cancel", True, ("ai-stream",)),
    EndpointCoverage("message", "GET", "/api/im/conversations/:conversationID/messages/:messageID/stream", True, ("ai-stream",)),
    EndpointCoverage("read", "POST", "/api/im/conversations/:conversationID/read", True, ("read-state",)),
    EndpointCoverage("read", "GET", "/api/im/conversations/:conversationID/receipts/summary", True, ("governance",)),
    EndpointCoverage("conversation", "GET", "/api/im/conversations/:conversationID/timeline", True, ("timeline-pagination", "cold-start", "convergence", "governance", "client-sync-mix")),
    EndpointCoverage("conversation", "GET", "/api/im/conversations/:conversationID/timeline/since", True, ("timeline-pagination", "cold-start", "convergence", "message-forward", "search-sync", "client-sync-mix")),
    EndpointCoverage("conversation", "GET", "/api/im/conversations/:conversationID/search", True, ("search-sync",)),
    EndpointCoverage("conversation", "GET", "/api/im/favorites", True, ("governance",)),
    EndpointCoverage("conversation", "POST", "/api/im/conversations/:conversationID/clear", True, ("read-state", "governance")),
    EndpointCoverage("conversation", "DELETE", "/api/im/conversations/:conversationID", True, ("governance",)),
    EndpointCoverage("invite", "POST", "/api/im/conversations/:conversationID/invites", True, ("group-invite",)),
    EndpointCoverage("invite", "GET", "/api/im/conversations/:conversationID/invites", True, ("group-invite",)),
    EndpointCoverage("invite", "DELETE", "/api/im/conversations/:conversationID/invites/:token", True, ("group-invite",)),
    EndpointCoverage("invite", "POST", "/api/im/invites/:token/join", True, ("group-invite",)),
    EndpointCoverage("conversation", "POST", "/api/im/conversations/:conversationID/leave", True, ("group-membership",)),
    EndpointCoverage("gateway-relay", "POST", "/internal/gateway/realtime/domain-event", False, ("tcp-delivery",), "Internal relay path; measured indirectly by TCP delivery scenarios."),
    EndpointCoverage("gateway-relay", "POST", "/internal/gateway/realtime/domain-event-packet", False, ("tcp-delivery",), "Internal compact packet relay path; measured indirectly by large-group delivery scenarios."),
    EndpointCoverage("gateway-relay", "POST", "/internal/gateway/realtime/domain-event-packet-bin", False, ("tcp-delivery",), "Internal binary packet relay path; measured indirectly by large-group delivery scenarios."),
    EndpointCoverage("gateway-relay", "POST", "/internal/gateway/realtime/domain-event-packets", False, ("tcp-delivery",), "Internal batch packet relay path; measured indirectly by large-group delivery scenarios."),
    EndpointCoverage("gateway-relay", "POST", "/internal/gateway/realtime/domain-event-packets-bin", False, ("tcp-delivery",), "Internal binary batch packet relay path; measured indirectly by large-group delivery scenarios."),
    EndpointCoverage("gateway-relay", "POST", "/internal/gateway/realtime/stream-signal", False, ("ai-stream",), "Internal relay path; measured indirectly by AI stream and TCP clients."),
    EndpointCoverage("gateway-relay", "POST", "/internal/gateway/realtime/kick-session", False, ("auth-session-management",), "Internal relay path; measured indirectly by session kick/logout scenarios."),
    EndpointCoverage("gateway-relay", "POST", "/internal/gateway/realtime/kick-user", False, ("auth-session-management",), "Internal relay path; measured indirectly by logout-all scenarios."),
    EndpointCoverage("gateway-relay", "POST", "/internal/gateway/realtime/session-counts", False, ("tcp-online",), "Internal relay path; measured indirectly by connection/session metrics."),
    EndpointCoverage("internal", "POST", "/internal/im/messages/send", True, ("timeline-pagination", "convergence", "read-state", "search-sync", "message-forward", "tcp-delivery"), "Command write ingress used by HTTP convergence and TCP delivery scenarios."),
    EndpointCoverage("internal", "POST", "/internal/im/conversations/:conversationID/member-cache/invalidate", False, ("group-admin", "group-membership", "group-invite"), "Internal cache invalidation side effect; covered indirectly by membership mutation scenarios."),
    EndpointCoverage("internal", "GET", "/internal/metrics", True, ("tcp-ladders", "entrypoint-probe"), "Required for production-style gates."),
    EndpointCoverage("internal", "GET", "/internal/reports", True, ("admin-report",), "Admin moderation workflow."),
    EndpointCoverage("internal", "PATCH", "/internal/reports/:reportID", True, ("admin-report",), "Admin moderation workflow."),
)


def endpoint_record(endpoint: EndpointCoverage) -> dict[str, Any]:
    data = asdict(endpoint)
    data["scenarios"] = list(endpoint.scenarios)
    data["covered"] = endpoint.covered
    return data


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


def build_report(endpoints: Sequence[EndpointCoverage] = ENDPOINTS) -> tuple[str, dict[str, Any]]:
    records = [endpoint_record(endpoint) for endpoint in endpoints]
    total = len(records)
    critical = [record for record in records if record["critical"]]
    covered = [record for record in records if record["covered"]]
    critical_covered = [record for record in critical if record["covered"]]
    critical_gaps = [record for record in critical if not record["covered"]]
    optional_gaps = [record for record in records if not record["critical"] and not record["covered"]]

    area_summary: dict[str, dict[str, int]] = {}
    for record in records:
        stats = area_summary.setdefault(record["area"], {"total": 0, "covered": 0, "critical": 0, "criticalCovered": 0})
        stats["total"] += 1
        if record["covered"]:
            stats["covered"] += 1
        if record["critical"]:
            stats["critical"] += 1
            if record["covered"]:
                stats["criticalCovered"] += 1

    area_rows = [["Area", "Covered", "Total", "Critical Covered", "Critical Total"]]
    for area, stats in sorted(area_summary.items()):
        area_rows.append([
            area,
            str(stats["covered"]),
            str(stats["total"]),
            str(stats["criticalCovered"]),
            str(stats["critical"]),
        ])

    endpoint_rows = [["Area", "Method", "Path", "Critical", "Covered By", "Note"]]
    for record in records:
        if record["covered"] and not record["critical"]:
            continue
        endpoint_rows.append([
            record["area"],
            record["method"],
            f"`{record['path']}`",
            "yes" if record["critical"] else "no",
            ", ".join(record["scenarios"]) if record["scenarios"] else "-",
            record["note"] or "-",
        ])

    recommendations = []
    if critical_gaps:
        recommendations.append("Add load-test scenarios for uncovered critical endpoints before using the matrix as full product coverage evidence.")
    if optional_gaps:
        recommendations.append("Optional gaps are mostly account lifecycle or admin workflows; test them separately when those flows become production-risk drivers.")
    if not critical_gaps:
        recommendations.append("All critical endpoints in this manifest have at least one scenario mapping; use real run gates to validate performance quality.")

    markdown = "\n".join([
        "# Performance Scenario Coverage",
        "",
        f"- endpoints: `{total}`",
        f"- covered endpoints: `{len(covered)}`",
        f"- critical endpoints: `{len(critical)}`",
        f"- covered critical endpoints: `{len(critical_covered)}`",
        f"- uncovered critical endpoints: `{len(critical_gaps)}`",
        f"- uncovered optional endpoints: `{len(optional_gaps)}`",
        "",
        "## Area Summary",
        "",
        markdown_table(area_rows),
        "",
        "## Critical And Gap Detail",
        "",
        markdown_table(endpoint_rows),
        "",
        "## Recommendations",
        "",
        *(f"- {item}" for item in recommendations),
        "",
    ])
    report = {
        "endpointCount": total,
        "coveredEndpointCount": len(covered),
        "criticalEndpointCount": len(critical),
        "coveredCriticalEndpointCount": len(critical_covered),
        "uncoveredCriticalEndpointCount": len(critical_gaps),
        "uncoveredOptionalEndpointCount": len(optional_gaps),
        "uncoveredCriticalEndpoints": critical_gaps,
        "uncoveredOptionalEndpoints": optional_gaps,
        "areaSummary": [
            {"area": area, **stats}
            for area, stats in sorted(area_summary.items())
        ],
        "endpoints": records,
        "recommendations": recommendations,
    }
    return markdown, report


def endpoint_key(record: dict[str, Any]) -> tuple[str, str]:
    return (str(record.get("method") or "").upper(), str(record.get("path") or ""))


def verify_report(report: dict[str, Any]) -> None:
    if not isinstance(report, dict):
        raise SystemExit("coverage_verify result=fail reason=report_not_object")
    count_keys = (
        "endpointCount",
        "coveredEndpointCount",
        "criticalEndpointCount",
        "coveredCriticalEndpointCount",
        "uncoveredCriticalEndpointCount",
        "uncoveredOptionalEndpointCount",
    )
    for key in count_keys:
        value = report.get(key)
        if not isinstance(value, int) or value < 0:
            raise SystemExit(f"coverage_verify result=fail reason={key}")

    list_keys = (
        "uncoveredCriticalEndpoints",
        "uncoveredOptionalEndpoints",
        "areaSummary",
        "endpoints",
        "recommendations",
    )
    for key in list_keys:
        if not isinstance(report.get(key), list):
            raise SystemExit(f"coverage_verify result=fail reason={key}_not_list")

    endpoints = report["endpoints"]
    if report["endpointCount"] != len(endpoints):
        raise SystemExit("coverage_verify result=fail reason=endpoint_count_mismatch")
    covered = [record for record in endpoints if record.get("covered") is True]
    critical = [record for record in endpoints if record.get("critical") is True]
    critical_covered = [record for record in critical if record.get("covered") is True]
    critical_gaps = [record for record in critical if record.get("covered") is not True]
    optional_gaps = [record for record in endpoints if record.get("critical") is not True and record.get("covered") is not True]
    if report["coveredEndpointCount"] != len(covered):
        raise SystemExit("coverage_verify result=fail reason=covered_count_mismatch")
    if report["criticalEndpointCount"] != len(critical):
        raise SystemExit("coverage_verify result=fail reason=critical_count_mismatch")
    if report["coveredCriticalEndpointCount"] != len(critical_covered):
        raise SystemExit("coverage_verify result=fail reason=covered_critical_count_mismatch")
    if report["uncoveredCriticalEndpointCount"] != len(critical_gaps):
        raise SystemExit("coverage_verify result=fail reason=critical_gap_count_mismatch")
    if report["uncoveredOptionalEndpointCount"] != len(optional_gaps):
        raise SystemExit("coverage_verify result=fail reason=optional_gap_count_mismatch")
    if report["uncoveredCriticalEndpoints"] != critical_gaps:
        raise SystemExit("coverage_verify result=fail reason=critical_gap_list_mismatch")
    if report["uncoveredOptionalEndpoints"] != optional_gaps:
        raise SystemExit("coverage_verify result=fail reason=optional_gap_list_mismatch")

    seen: set[tuple[str, str]] = set()
    for record in endpoints:
        if not isinstance(record, dict):
            raise SystemExit("coverage_verify result=fail reason=endpoint_row_not_object")
        key = endpoint_key(record)
        if not key[0] or not key[1]:
            raise SystemExit("coverage_verify result=fail reason=endpoint_key_missing")
        if key in seen:
            raise SystemExit(f"coverage_verify result=fail reason=duplicate_endpoint method={key[0]} path={key[1]}")
        seen.add(key)
        scenarios = record.get("scenarios")
        if not isinstance(scenarios, list):
            raise SystemExit(f"coverage_verify result=fail reason=scenarios_not_list method={key[0]} path={key[1]}")
        if (record.get("covered") is True) != (len(scenarios) > 0):
            raise SystemExit(f"coverage_verify result=fail reason=covered_scenarios_mismatch method={key[0]} path={key[1]}")

    area_summary: dict[str, dict[str, int]] = {}
    for record in endpoints:
        area = str(record.get("area") or "")
        if not area:
            raise SystemExit("coverage_verify result=fail reason=endpoint_area_missing")
        stats = area_summary.setdefault(area, {"total": 0, "covered": 0, "critical": 0, "criticalCovered": 0})
        stats["total"] += 1
        if record.get("covered") is True:
            stats["covered"] += 1
        if record.get("critical") is True:
            stats["critical"] += 1
            if record.get("covered") is True:
                stats["criticalCovered"] += 1
    expected_area_rows = [{"area": area, **stats} for area, stats in sorted(area_summary.items())]
    if report["areaSummary"] != expected_area_rows:
        raise SystemExit("coverage_verify result=fail reason=area_summary_mismatch")
    if not report["recommendations"]:
        raise SystemExit("coverage_verify result=fail reason=recommendations_missing")


def verify_markdown(expected_markdown: str, markdown_path: Path) -> None:
    if not markdown_path.is_file():
        raise SystemExit(f"coverage_verify result=fail reason=markdown_missing path={markdown_path}")
    actual = markdown_path.read_text(encoding="utf-8")
    if actual != expected_markdown:
        raise SystemExit(f"coverage_verify result=fail reason=markdown_mismatch path={markdown_path}")


def expect_system_exit(label: str, fn: Any) -> None:
    try:
        fn()
    except SystemExit:
        print(label)
        return
    raise SystemExit(f"coverage_self_test result=fail reason={label}_not_rejected")


def run_self_test() -> None:
    fixture = (
        EndpointCoverage("auth", "POST", "/api/auth/login", True, ("login",)),
        EndpointCoverage("auth", "POST", "/api/auth/register", True, ()),
        EndpointCoverage("ops", "GET", "/internal/diagnostics", False, ()),
    )
    markdown, report = build_report(fixture)
    verify_report(report)
    if report["uncoveredCriticalEndpointCount"] != 1:
        raise SystemExit("coverage_self_test result=fail reason=critical_gap_not_detected")
    if report["uncoveredOptionalEndpointCount"] != 1:
        raise SystemExit("coverage_self_test result=fail reason=optional_gap_not_detected")
    print("self_test_critical_gap_detected")
    print("self_test_optional_gap_detected")

    no_gap_fixture = (
        EndpointCoverage("auth", "POST", "/api/auth/login", True, ("login",)),
        EndpointCoverage("root", "GET", "/", False, ("entrypoint-probe",)),
    )
    _, no_gap_report = build_report(no_gap_fixture)
    verify_report(no_gap_report)
    if no_gap_report["uncoveredCriticalEndpointCount"] != 0:
        raise SystemExit("coverage_self_test result=fail reason=no_gap_fixture_failed")
    if not any("All critical endpoints" in item for item in no_gap_report["recommendations"]):
        raise SystemExit("coverage_self_test result=fail reason=no_gap_recommendation_missing")
    print("self_test_no_critical_gap_passed")

    duplicate_fixture = (
        EndpointCoverage("auth", "POST", "/api/auth/login", True, ("login",)),
        EndpointCoverage("auth", "POST", "/api/auth/login", True, ("login",)),
    )
    _, duplicate_report = build_report(duplicate_fixture)
    expect_system_exit("self_test_duplicate_endpoint_rejected", lambda: verify_report(duplicate_report))

    bad_count_report = dict(report)
    bad_count_report["coveredEndpointCount"] = report["coveredEndpointCount"] + 1
    expect_system_exit("self_test_count_mismatch_rejected", lambda: verify_report(bad_count_report))

    markdown_path = Path("/tmp/perf-coverage-self-test.md")
    markdown_path.write_text(markdown + "\nextra drift\n", encoding="utf-8")
    try:
        expect_system_exit("self_test_markdown_mismatch_rejected", lambda: verify_markdown(markdown, markdown_path))
    finally:
        markdown_path.unlink(missing_ok=True)

    print("coverage_self_test result=pass")


def write_csv(path: Path, records: list[dict[str, Any]]) -> None:
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=["area", "method", "path", "critical", "covered", "scenarios", "note"],
        )
        writer.writeheader()
        for record in records:
            writer.writerow({
                "area": record["area"],
                "method": record["method"],
                "path": record["path"],
                "critical": record["critical"],
                "covered": record["covered"],
                "scenarios": ",".join(record["scenarios"]),
                "note": record["note"],
            })


def main() -> int:
    parser = argparse.ArgumentParser(description="Report which IM API endpoints are covered by performance scenarios.")
    parser.add_argument("--output", help="Write Markdown coverage report to this path.")
    parser.add_argument("--json-output", help="Write machine-readable coverage report to this path.")
    parser.add_argument("--csv-output", help="Write flat endpoint coverage CSV to this path.")
    parser.add_argument("--strict", action="store_true", help="Exit non-zero if any critical endpoint has no scenario mapping.")
    parser.add_argument("--self-test", action="store_true", help="Run internal coverage report verifier fixtures.")
    args = parser.parse_args()

    if args.self_test:
        run_self_test()
        return 0

    markdown, report = build_report()
    verify_report(report)
    if args.output:
        Path(args.output).write_text(markdown, encoding="utf-8")
        verify_markdown(markdown, Path(args.output))
    else:
        print(markdown)
    if args.json_output:
        Path(args.json_output).write_text(json.dumps(report, indent=2, sort_keys=True), encoding="utf-8")
    if args.csv_output:
        write_csv(Path(args.csv_output), report["endpoints"])
    if args.strict and report["uncoveredCriticalEndpointCount"] > 0:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
