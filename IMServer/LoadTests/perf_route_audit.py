#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Sequence

from perf_coverage import ENDPOINTS, EndpointCoverage


@dataclass(frozen=True)
class SourceRoute:
    method: str
    path: str
    owner: str
    performance_scope: bool = True
    note: str = ""

    @property
    def key(self) -> tuple[str, str]:
        return (self.method.upper(), self.path)


SOURCE_ROUTES: tuple[SourceRoute, ...] = (
    SourceRoute("GET", "/", "RootRoutes", False, "Static app shell; not a capacity target."),
    SourceRoute("GET", "/health", "RootRoutes"),
    SourceRoute("GET", "/hello", "HelloController", False, "Development sample route."),
    SourceRoute("GET", "/hello/greet/:name", "HelloController", False, "Development sample route."),
    SourceRoute("GET", "/hello/info", "HelloController", False, "Development sample route."),
    SourceRoute("GET", "/hello/query", "HelloController", False, "Development sample route."),
    SourceRoute("POST", "/api/auth/register", "AuthController"),
    SourceRoute("POST", "/api/auth/login", "AuthController"),
    SourceRoute("POST", "/api/auth/refresh", "AuthController"),
    SourceRoute("POST", "/api/auth/email-verifications/resend", "AuthController"),
    SourceRoute("POST", "/api/auth/email-verifications/confirm", "AuthController"),
    SourceRoute("POST", "/api/auth/password-resets/request", "AuthController"),
    SourceRoute("POST", "/api/auth/password-resets/confirm", "AuthController"),
    SourceRoute("GET", "/api/auth/sessions", "AuthController"),
    SourceRoute("POST", "/api/auth/logout", "AuthController"),
    SourceRoute("DELETE", "/api/auth/sessions/current", "AuthController"),
    SourceRoute("DELETE", "/api/auth/sessions/all", "AuthController"),
    SourceRoute("DELETE", "/api/auth/sessions/:sessionID", "AuthController"),
    SourceRoute("GET", "/api/me", "UserController"),
    SourceRoute("PATCH", "/api/me/profile", "UserController"),
    SourceRoute("GET", "/api/contacts", "UserController"),
    SourceRoute("GET", "/api/contacts/changes", "UserController"),
    SourceRoute("POST", "/api/contacts", "UserController"),
    SourceRoute("PATCH", "/api/contacts/:contactUserID", "UserController"),
    SourceRoute("DELETE", "/api/contacts/:contactUserID", "UserController"),
    SourceRoute("GET", "/api/contact-requests", "UserController"),
    SourceRoute("POST", "/api/contact-requests", "UserController"),
    SourceRoute("POST", "/api/contact-requests/:requestID/accept", "UserController"),
    SourceRoute("POST", "/api/contact-requests/:requestID/decline", "UserController"),
    SourceRoute("POST", "/api/contact-requests/:requestID/cancel", "UserController"),
    SourceRoute("GET", "/api/blocks", "UserController"),
    SourceRoute("POST", "/api/users/:userID/block", "UserController"),
    SourceRoute("DELETE", "/api/users/:userID/block", "UserController"),
    SourceRoute("POST", "/api/reports", "UserController"),
    SourceRoute("POST", "/api/push/device-tokens", "UserController"),
    SourceRoute("DELETE", "/api/push/device-tokens/:tokenID", "UserController"),
    SourceRoute("POST", "/api/files/upload", "FileController"),
    SourceRoute("GET", "/api/files/download", "FileController"),
    SourceRoute("POST", "/api/media/uploads", "MediaController"),
    SourceRoute("PUT", "/api/media/uploads/:uploadID/chunk", "MediaController"),
    SourceRoute("POST", "/api/media/uploads/:uploadID/complete", "MediaController"),
    SourceRoute("GET", "/api/media/assets/:assetID", "MediaController"),
    SourceRoute("GET", "/api/im/conversations", "IMConversationController"),
    SourceRoute("GET", "/api/im/conversations/changes", "IMConversationController"),
    SourceRoute("GET", "/api/im/domain-events", "IMConversationController"),
    SourceRoute("GET", "/api/im/conversations/:conversationID/members", "IMConversationController"),
    SourceRoute("GET", "/api/im/conversations/:conversationID/timeline", "IMConversationController"),
    SourceRoute("GET", "/api/im/conversations/:conversationID/timeline/since", "IMConversationController"),
    SourceRoute("GET", "/api/im/conversations/:conversationID/receipts/summary", "IMConversationController"),
    SourceRoute("GET", "/api/im/conversations/:conversationID/search", "IMConversationController"),
    SourceRoute("GET", "/api/im/conversations/:conversationID/messages/:messageID/stream", "IMConversationController"),
    SourceRoute("GET", "/api/im/favorites", "IMConversationController"),
    SourceRoute("POST", "/api/im/client-health", "IMConversationController"),
    SourceRoute("POST", "/api/im/conversations", "IMConversationCommandRoute"),
    SourceRoute("POST", "/api/im/conversations/:conversationID/members", "IMConversationCommandRoute"),
    SourceRoute("PATCH", "/api/im/conversations/:conversationID/members/me", "IMConversationCommandRoute"),
    SourceRoute("POST", "/api/im/conversations/:conversationID/members/:memberUserID/remove", "IMConversationCommandRoute"),
    SourceRoute("POST", "/api/im/conversations/:conversationID/members/:memberUserID/role", "IMConversationCommandRoute"),
    SourceRoute("POST", "/api/im/conversations/:conversationID/title", "IMConversationCommandRoute"),
    SourceRoute("PATCH", "/api/im/conversations/:conversationID/preferences", "IMConversationCommandRoute"),
    SourceRoute("PATCH", "/api/im/conversations/:conversationID/metadata", "IMConversationCommandRoute"),
    SourceRoute("POST", "/api/im/conversations/:conversationID/messages/forward", "IMConversationCommandRoute"),
    SourceRoute("POST", "/api/im/conversations/:conversationID/messages/delete", "IMConversationCommandRoute"),
    SourceRoute("POST", "/api/im/conversations/:conversationID/messages/:messageID/favorite", "IMConversationCommandRoute"),
    SourceRoute("DELETE", "/api/im/conversations/:conversationID/messages/:messageID/favorite", "IMConversationCommandRoute"),
    SourceRoute("POST", "/api/im/conversations/:conversationID/messages/:messageID/edit", "IMConversationCommandRoute"),
    SourceRoute("POST", "/api/im/conversations/:conversationID/messages/:messageID/reactions", "IMConversationCommandRoute"),
    SourceRoute("POST", "/api/im/conversations/:conversationID/messages/:messageID/recall", "IMConversationCommandRoute"),
    SourceRoute("POST", "/api/im/conversations/:conversationID/ai/messages", "IMConversationCommandRoute"),
    SourceRoute("POST", "/api/im/conversations/:conversationID/messages/:messageID/stream/cancel", "IMConversationCommandRoute"),
    SourceRoute("POST", "/api/im/conversations/:conversationID/read", "IMConversationCommandRoute"),
    SourceRoute("POST", "/api/im/conversations/:conversationID/clear", "IMConversationCommandRoute"),
    SourceRoute("DELETE", "/api/im/conversations/:conversationID", "IMConversationCommandRoute"),
    SourceRoute("POST", "/api/im/conversations/:conversationID/invites", "IMConversationCommandRoute"),
    SourceRoute("GET", "/api/im/conversations/:conversationID/invites", "IMConversationCommandRoute"),
    SourceRoute("DELETE", "/api/im/conversations/:conversationID/invites/:token", "IMConversationCommandRoute"),
    SourceRoute("POST", "/api/im/invites/:token/join", "IMConversationCommandRoute"),
    SourceRoute("POST", "/api/im/conversations/:conversationID/leave", "IMConversationCommandRoute"),
    SourceRoute("POST", "/internal/gateway/realtime/domain-event", "GatewayRelayController"),
    SourceRoute("POST", "/internal/gateway/realtime/domain-event-packet", "GatewayRelayController"),
    SourceRoute("POST", "/internal/gateway/realtime/domain-event-packet-bin", "GatewayRelayController"),
    SourceRoute("POST", "/internal/gateway/realtime/domain-event-packets", "GatewayRelayController"),
    SourceRoute("POST", "/internal/gateway/realtime/domain-event-packets-bin", "GatewayRelayController"),
    SourceRoute("POST", "/internal/gateway/realtime/stream-signal", "GatewayRelayController"),
    SourceRoute("POST", "/internal/gateway/realtime/kick-session", "GatewayRelayController"),
    SourceRoute("POST", "/internal/gateway/realtime/kick-user", "GatewayRelayController"),
    SourceRoute("POST", "/internal/gateway/realtime/session-counts", "GatewayRelayController"),
    SourceRoute("POST", "/internal/im/messages/send", "InternalMessageCommandController"),
    SourceRoute("POST", "/internal/im/conversations/:conversationID/member-cache/invalidate", "InternalMessageCommandController"),
    SourceRoute("GET", "/internal/metrics", "InternalMetricsController"),
    SourceRoute("GET", "/internal/reports", "InternalReportsController"),
    SourceRoute("PATCH", "/internal/reports/:reportID", "InternalReportsController"),
)


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


def route_record(route: SourceRoute) -> dict[str, Any]:
    return asdict(route)


def endpoint_record(endpoint: EndpointCoverage) -> dict[str, Any]:
    data = asdict(endpoint)
    data["method"] = endpoint.method.upper()
    data["scenarios"] = list(endpoint.scenarios)
    return data


def build_report(
    source_routes: Sequence[SourceRoute] = SOURCE_ROUTES,
    endpoints: Sequence[EndpointCoverage] = ENDPOINTS,
) -> tuple[str, dict[str, Any]]:
    coverage_keys = {(endpoint.method.upper(), endpoint.path) for endpoint in endpoints}
    source_keys = {route.key for route in source_routes}

    missing_manifest = [
        route_record(route)
        for route in source_routes
        if route.performance_scope and route.key not in coverage_keys
    ]
    ignored_source = [
        route_record(route)
        for route in source_routes
        if not route.performance_scope and route.key not in coverage_keys
    ]
    orphan_coverage = [
        {
            "method": endpoint.method.upper(),
            "path": endpoint.path,
            "area": endpoint.area,
            "critical": endpoint.critical,
            "scenarios": list(endpoint.scenarios),
            "note": endpoint.note,
        }
        for endpoint in endpoints
        if (endpoint.method.upper(), endpoint.path) not in source_keys
    ]

    missing_rows = [["Method", "Path", "Owner", "Note"]]
    for route in missing_manifest:
        missing_rows.append([route["method"], f"`{route['path']}`", route["owner"], route["note"] or "-"])

    orphan_rows = [["Method", "Path", "Area", "Critical", "Scenarios"]]
    for endpoint in orphan_coverage:
        orphan_rows.append([
            endpoint["method"],
            f"`{endpoint['path']}`",
            endpoint["area"],
            "yes" if endpoint["critical"] else "no",
            ", ".join(endpoint["scenarios"]) if endpoint["scenarios"] else "-",
        ])

    ignored_rows = [["Method", "Path", "Owner", "Reason"]]
    for route in ignored_source:
        ignored_rows.append([route["method"], f"`{route['path']}`", route["owner"], route["note"] or "-"])

    markdown = "\n".join([
        "# Performance Route Audit",
        "",
        f"- source routes: `{len(source_routes)}`",
        f"- coverage endpoints: `{len(endpoints)}`",
        f"- missing performance routes in coverage: `{len(missing_manifest)}`",
        f"- coverage endpoints not found in source route inventory: `{len(orphan_coverage)}`",
        f"- ignored source routes: `{len(ignored_source)}`",
        "",
        "## Missing Performance Routes",
        "",
        markdown_table(missing_rows),
        "",
        "## Coverage Endpoints Not In Source Inventory",
        "",
        markdown_table(orphan_rows),
        "",
        "## Ignored Source Routes",
        "",
        markdown_table(ignored_rows),
        "",
    ])
    report = {
        "sourceRouteCount": len(source_routes),
        "coverageEndpointCount": len(endpoints),
        "missingManifestRouteCount": len(missing_manifest),
        "orphanCoverageEndpointCount": len(orphan_coverage),
        "ignoredSourceRouteCount": len(ignored_source),
        "missingManifestRoutes": missing_manifest,
        "orphanCoverageEndpoints": orphan_coverage,
        "ignoredSourceRoutes": ignored_source,
        "sourceRoutes": [route_record(route) for route in source_routes],
        "coverageEndpoints": [endpoint_record(endpoint) for endpoint in endpoints],
    }
    return markdown, report


def route_key(record: dict[str, Any]) -> tuple[str, str]:
    return (str(record.get("method") or "").upper(), str(record.get("path") or ""))


def require_unique_keys(records: list[Any], label: str) -> None:
    seen: set[tuple[str, str]] = set()
    for record in records:
        if not isinstance(record, dict):
            raise SystemExit(f"route_audit_verify result=fail reason={label}_row_not_object")
        key = route_key(record)
        if not key[0] or not key[1]:
            raise SystemExit(f"route_audit_verify result=fail reason={label}_key_missing")
        if key in seen:
            raise SystemExit(f"route_audit_verify result=fail reason=duplicate_{label} method={key[0]} path={key[1]}")
        seen.add(key)


def verify_report(report: dict[str, Any]) -> None:
    if not isinstance(report, dict):
        raise SystemExit("route_audit_verify result=fail reason=report_not_object")
    for key in (
        "sourceRouteCount",
        "coverageEndpointCount",
        "missingManifestRouteCount",
        "orphanCoverageEndpointCount",
        "ignoredSourceRouteCount",
    ):
        value = report.get(key)
        if not isinstance(value, int) or value < 0:
            raise SystemExit(f"route_audit_verify result=fail reason={key}")

    list_keys = (
        "missingManifestRoutes",
        "orphanCoverageEndpoints",
        "ignoredSourceRoutes",
        "sourceRoutes",
        "coverageEndpoints",
    )
    for key in list_keys:
        if not isinstance(report.get(key), list):
            raise SystemExit(f"route_audit_verify result=fail reason={key}_not_list")

    if report["sourceRouteCount"] != len(report["sourceRoutes"]):
        raise SystemExit("route_audit_verify result=fail reason=source_count_mismatch")
    if report["coverageEndpointCount"] != len(report["coverageEndpoints"]):
        raise SystemExit("route_audit_verify result=fail reason=coverage_count_mismatch")
    if report["missingManifestRouteCount"] != len(report["missingManifestRoutes"]):
        raise SystemExit("route_audit_verify result=fail reason=missing_count_mismatch")
    if report["orphanCoverageEndpointCount"] != len(report["orphanCoverageEndpoints"]):
        raise SystemExit("route_audit_verify result=fail reason=orphan_count_mismatch")
    if report["ignoredSourceRouteCount"] != len(report["ignoredSourceRoutes"]):
        raise SystemExit("route_audit_verify result=fail reason=ignored_count_mismatch")

    require_unique_keys(report["sourceRoutes"], "source_route")
    require_unique_keys(report["coverageEndpoints"], "coverage_endpoint")

    coverage_keys = {route_key(record) for record in report["coverageEndpoints"]}
    source_keys = {route_key(record) for record in report["sourceRoutes"]}
    for route in report["missingManifestRoutes"]:
        key = route_key(route)
        if key in coverage_keys:
            raise SystemExit(f"route_audit_verify result=fail reason=missing_route_is_covered method={key[0]} path={key[1]}")
        if route.get("performance_scope") is not True:
            raise SystemExit(f"route_audit_verify result=fail reason=missing_route_not_performance_scoped method={key[0]} path={key[1]}")
    for endpoint in report["orphanCoverageEndpoints"]:
        key = route_key(endpoint)
        if key in source_keys:
            raise SystemExit(f"route_audit_verify result=fail reason=orphan_endpoint_has_source method={key[0]} path={key[1]}")
    for route in report["ignoredSourceRoutes"]:
        if route.get("performance_scope") is not False:
            key = route_key(route)
            raise SystemExit(f"route_audit_verify result=fail reason=ignored_route_performance_scoped method={key[0]} path={key[1]}")


def verify_markdown(expected_markdown: str, markdown_path: Path) -> None:
    if not markdown_path.is_file():
        raise SystemExit(f"route_audit_verify result=fail reason=markdown_missing path={markdown_path}")
    actual = markdown_path.read_text(encoding="utf-8")
    if actual != expected_markdown:
        raise SystemExit(f"route_audit_verify result=fail reason=markdown_mismatch path={markdown_path}")


def expect_system_exit(label: str, fn: Any) -> None:
    try:
        fn()
    except SystemExit:
        print(label)
        return
    raise SystemExit(f"route_audit_self_test result=fail reason={label}_not_rejected")


def self_test_endpoint(method: str, path: str) -> EndpointCoverage:
    return EndpointCoverage("self-test", method, path, True, ("self-test-scenario",))


def run_self_test() -> None:
    covered_routes = (
        SourceRoute("GET", "/health", "SelfTestController"),
        SourceRoute("GET", "/hello", "SelfTestController", False, "Ignored only when not covered."),
    )
    covered_endpoints = (
        self_test_endpoint("GET", "/health"),
        self_test_endpoint("GET", "/hello"),
    )
    markdown, report = build_report(covered_routes, covered_endpoints)
    verify_report(report)
    if report["missingManifestRouteCount"] != 0 or report["orphanCoverageEndpointCount"] != 0:
        raise SystemExit("route_audit_self_test result=fail reason=covered_fixture_failed")

    _, missing_report = build_report((SourceRoute("POST", "/api/new", "SelfTestController"),), ())
    verify_report(missing_report)
    if missing_report["missingManifestRouteCount"] != 1:
        raise SystemExit("route_audit_self_test result=fail reason=missing_route_not_detected")
    print("self_test_missing_route_detected")

    _, orphan_report = build_report((), (self_test_endpoint("GET", "/api/orphan"),))
    verify_report(orphan_report)
    if orphan_report["orphanCoverageEndpointCount"] != 1:
        raise SystemExit("route_audit_self_test result=fail reason=orphan_endpoint_not_detected")
    print("self_test_orphan_endpoint_detected")

    _, ignored_report = build_report((SourceRoute("GET", "/dev-only", "SelfTestController", False, "Dev only."),), ())
    verify_report(ignored_report)
    if ignored_report["ignoredSourceRouteCount"] != 1 or ignored_report["missingManifestRouteCount"] != 0:
        raise SystemExit("route_audit_self_test result=fail reason=ignored_route_fixture_failed")
    print("self_test_ignored_route_recorded")

    _, duplicate_source_report = build_report(
        (
            SourceRoute("GET", "/dup", "SelfTestController"),
            SourceRoute("GET", "/dup", "SelfTestController"),
        ),
        (self_test_endpoint("GET", "/dup"),),
    )
    expect_system_exit("self_test_duplicate_source_rejected", lambda: verify_report(duplicate_source_report))

    _, duplicate_coverage_report = build_report(
        (SourceRoute("GET", "/dup-coverage", "SelfTestController"),),
        (
            self_test_endpoint("GET", "/dup-coverage"),
            self_test_endpoint("GET", "/dup-coverage"),
        ),
    )
    expect_system_exit("self_test_duplicate_coverage_rejected", lambda: verify_report(duplicate_coverage_report))

    markdown_path = Path("/tmp/perf-route-audit-self-test.md")
    markdown_path.write_text(markdown + "\nextra drift\n", encoding="utf-8")
    try:
        expect_system_exit("self_test_markdown_mismatch_rejected", lambda: verify_markdown(markdown, markdown_path))
    finally:
        markdown_path.unlink(missing_ok=True)

    print("route_audit_self_test result=pass")


def write_csv(path: Path, report: dict[str, Any]) -> None:
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=["kind", "method", "path", "owner", "area", "critical", "performance_scope", "note"],
        )
        writer.writeheader()
        for route in report["missingManifestRoutes"]:
            writer.writerow({
                "kind": "missing_manifest",
                "method": route["method"],
                "path": route["path"],
                "owner": route["owner"],
                "performance_scope": route["performance_scope"],
                "note": route["note"],
            })
        for endpoint in report["orphanCoverageEndpoints"]:
            writer.writerow({
                "kind": "orphan_coverage",
                "method": endpoint["method"],
                "path": endpoint["path"],
                "area": endpoint["area"],
                "critical": endpoint["critical"],
                "note": endpoint["note"],
            })
        for route in report["ignoredSourceRoutes"]:
            writer.writerow({
                "kind": "ignored_source",
                "method": route["method"],
                "path": route["path"],
                "owner": route["owner"],
                "performance_scope": route["performance_scope"],
                "note": route["note"],
            })


def main() -> int:
    parser = argparse.ArgumentParser(description="Audit server route inventory against the performance coverage manifest.")
    parser.add_argument("--output", help="Write Markdown audit report to this path.")
    parser.add_argument("--json-output", help="Write machine-readable audit report to this path.")
    parser.add_argument("--csv-output", help="Write route audit CSV to this path.")
    parser.add_argument("--strict", action="store_true", help="Exit non-zero if any performance source route is missing from coverage.")
    parser.add_argument("--fail-on-orphan", action="store_true", help="Exit non-zero if coverage contains endpoints not listed in the source route inventory.")
    parser.add_argument("--self-test", action="store_true", help="Run internal route audit verifier fixtures.")
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
        write_csv(Path(args.csv_output), report)
    if args.strict and report["missingManifestRouteCount"] > 0:
        return 1
    if args.fail_on_orphan and report["orphanCoverageEndpointCount"] > 0:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
