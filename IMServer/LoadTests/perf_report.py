#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass
class Thresholds:
    min_connection_success_rate: float
    min_ack_success_rate: float
    min_delivery_success_rate: float
    min_heartbeat_ack_rate: float
    max_heartbeat_p99_ms: float
    max_delivery_p99_ms: float
    max_lag_clear_after_send_seconds: float


CATEGORY_OPTIMIZATION_HINTS: dict[str, str] = {
    "preflight": "Fix local scenario inputs, HTTP entrypoint, route exposure, credentials, or access-control before treating any matrix number as valid.",
    "http-login": "Optimize HTTP auth, DB/auth-session cache, Redis, and account prewarm; keep TCP online capacity separate.",
    "http-account-lifecycle": "Optimize registration password hashing, auth security challenge writes, email delivery/webhook latency, rate limiter configuration, and account lifecycle indexes.",
    "http-auth-session": "Optimize refresh token rotation, session table indexes, auth-session validation cache, push token writes, and logout side effects.",
    "http-auth-session-management": "Optimize session list indexes, per-user invalidation, logout-all batch updates, revoked refresh rejection, and gateway kick fanout.",
    "http-auth-token-rotation": "Optimize refresh token rotation writes, old-token reuse rejection lookup, revoked-token indexes, auth token issuance latency, and session validation cache.",
    "http-auth-failure-recovery": "Optimize failed-login rejection latency, auth error-path indexes, bad token parsing/validation, rate limiter overhead, and recovery login path isolation.",
    "http-push-token": "Optimize push device token upsert/delete indexes, session association writes, idempotent delete handling, and auth validation cache.",
    "http-client-health": "Optimize client-health in-memory aggregation, request decoding, auth validation cache, and report sampling frequency.",
    "http-client-sync-mix": "Split slow foreground sync requests first, then optimize auth validation cache, contact changes, conversation list/changes, domain-events pagination, timeline indexes, or client-health writes.",
    "http-user-journey": "Break down the mixed user journey by read/write/health latency first, then optimize the slowest auth, conversation list/changes, contacts, domain-events, timeline, message write, or client-health path.",
    "http-mixed-workload": "Break down the weighted daily-active mix by read/write/health latency, then optimize conversation list/changes, domain-events, contacts, timeline, internal message write, or auth validation cache.",
    "http-offline-catchup": "Optimize offline catch-up writes, owner domain-event delivery, conversation changes, timeline/since reads, domain-events replay, and payload size before tuning realtime fanout.",
    "http-inbox-fanout": "Optimize multi-conversation summary projection, conversation list ordering indexes, changes pagination, timeline/since reads, owner delivery writes, and response payload size.",
    "http-multi-device-sync": "Optimize cross-device summary/read-state propagation, conversations/changes write latency, session/device auth cache, timeline/since reads, and read-clear projection consistency.",
    "http-convergence": "Optimize summary projection, timeline/since cache, query-api read path, and projection lag.",
    "http-direct-convergence": "Optimize direct conversation command/read paths, summary projection, timeline/since cache, and direct-peer summary updates.",
    "http-cold-start": "Optimize conversation list reads, changes token scans, messages/since indexes, response payload size, and per-user read cache.",
    "http-timeline-pagination": "Optimize timeline latest/history indexes, timeline/since target-sequence reads, member search indexes, conversation list filters, and read-model cache hit rate.",
    "http-timeline-history-scroll": "Optimize timeline history pagination indexes, beforeSequence boundary handling, timeline/since cache correctness, duplicate page protection, and visibility scan limits.",
    "http-domain-events": "Optimize owner domain event delivery writes, owner cursor allocation, summary-shard read indexes, deferred event page size, and replay/backfill behavior.",
    "http-read-state": "Optimize mark-read command writes, summary/read overlay, conversations/changes propagation, and unread count consistency.",
    "http-direct-message-lifecycle": "Optimize direct conversation creation/reuse, command-api message writes, owner summary projection, timeline/since reads, unread/read-state propagation, and conversations/changes latency.",
    "http-search-sync": "Optimize search-index-consumer lag, search index write batching, query search adapter latency, and search backing store configuration.",
    "http-group-admin": "Optimize membership command transactions, member-cache invalidation, metadata/preference summary projection, changes propagation, and member page indexes.",
    "http-group-membership": "Optimize member profile writes, role privilege checks, remove/leave transactions, member-cache invalidation fanout, member page indexes, and changes projection.",
    "http-group-invite": "Optimize invite table indexes, invite create/revoke writes, invite join membership transactions, member-cache invalidation, and member page reads.",
    "http-governance": "Optimize preference writes, message lifecycle command writes, favorite/visibility overlay indexes, receipt summary reads, and changes propagation.",
    "http-conversation-preferences": "Optimize conversation preference writes, pinned list ordering indexes, summary projection refresh, conversations/changes preference upserts, and auth/read-model cache hit rate.",
    "http-conversation-visibility": "Optimize conversation visibility overlay writes, timeline visibility filtering, summary removed projection, conversations/changes removed pagination, and cache invalidation after clear/delete.",
    "http-message-forward": "Optimize source visible-message reads, target conversation writes, sequence allocation, timeline/since cache, summary projection, and message-created outbox processing.",
    "http-ai-stream": "Optimize AI stream lease reservation, initial message write, provider chunk scheduling, stream snapshot writes, realtime stream-signal fanout, and terminal state finalization.",
    "http-contact-request": "Optimize friend-request pending lookup indexes, incoming/outgoing request list scans, status updates, contact outbox writes, and changes pagination.",
    "http-contact-sync": "Optimize friend request transactions, contact outbox/change-log writes, changes pagination, realtime relay, and contacts list indexes.",
    "http-profile-sync": "Optimize profile command writes, direct-peer summary projection, contact/domain event outbox processing, and changes propagation.",
    "http-safety-block": "Optimize user block indexes, report writes, common-feature access, and HTTP command latency.",
    "http-safety-block-enforcement": "Optimize user block lookup indexes, direct conversation create rejection, unblock recovery, and direct-conversation index cache consistency.",
    "http-access-control-enforcement": "Optimize membership permission checks, non-member query rejection, role update propagation, member-cache invalidation, and removed-member access denial.",
    "http-admin-report": "Optimize report table status/target indexes, internal report pagination, moderation status updates, and internal secret/auth middleware overhead.",
    "http-media-file": "Optimize file storage I/O, media upload session storage, object-store/S3 latency, range download handling, and asset metadata reads.",
    "http-media-failure-recovery": "Optimize media/file auth rejection, invalid range handling, upload-session state transitions, missing asset lookup, and recovery upload/download path.",
    "http-small-group": "Optimize small-group conversation creation, changes projection, timeline/since reads, and summary list reads.",
    "http-hot-write": "Optimize hot conversation write limiter, command-api write path, sequence allocation, Kafka/outbox publish, and write queue pressure.",
    "tcp-online": "Optimize gateway accept/backlog, TCP auth lifecycle, heartbeat scheduling, load-generator capacity, kernel limits, and login-cache prewarm.",
    "tcp-reconnect": "Optimize gateway connection lifecycle, auth revalidation after reconnect, heartbeat recovery, route/session directory cleanup, and load-generator/network stability.",
    "tcp-multi-device-online": "Check same-account session policy, duplicate device kick rules, auth session indexing, and TCP session directory fanout.",
    "tcp-multi-device-delivery": "Check same-account route fanout, device-level session registration, duplicate canonical merge behavior, and TCP write pressure.",
    "tcp-pair-delivery": "Optimize command-api ACK path, realtime route lookup, gateway fanout, TCP write pressure, and client catch-up.",
    "tcp-large-group": "Optimize compact hint coalescing, owner delivery batch writes, relay batch size, gateway local fanout batch/yield, and Kafka consumer lag.",
}


def read_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text())
    except Exception:
        return {}


def read_exit_code(path: Path) -> int | None:
    try:
        return int(path.read_text().strip())
    except Exception:
        return None


def numeric(value: Any, default: float = 0.0) -> float:
    if value is None:
        return default
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def percent(value: float | None) -> str:
    if value is None:
        return "-"
    return f"{value * 100:.2f}%"


def number(value: float | int | None, suffix: str = "") -> str:
    if value is None:
        return "-"
    if isinstance(value, float):
        if value.is_integer():
            return f"{int(value)}{suffix}"
        return f"{value:.3f}{suffix}"
    return f"{value}{suffix}"


def last_jsonl_event(path: Path, event: str) -> dict[str, Any] | None:
    last: dict[str, Any] | None = None
    try:
        with path.open() as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if record.get("event") == event:
                    last = record
    except OSError:
        return None
    return last


def collect_tcp_finishes(scenario_dir: Path) -> list[dict[str, Any]]:
    finishes: list[dict[str, Any]] = []
    for path in sorted(scenario_dir.rglob("*.jsonl")):
        record = last_jsonl_event(path, "run_finish")
        if record:
            record["_path"] = str(path.relative_to(scenario_dir))
            finishes.append(record)
    return finishes


def rate(numerator: float, denominator: float) -> float | None:
    if denominator <= 0:
        return None
    return numerator / denominator


def summarize_tcp(finishes: list[dict[str, Any]]) -> dict[str, Any]:
    if not finishes:
        return {}
    total_connections = sum(numeric(item.get("connections")) for item in finishes)
    total_successes = sum(numeric(item.get("successes")) for item in finishes)
    total_sent = sum(numeric(item.get("sent")) for item in finishes)
    total_ack = sum(numeric(item.get("ack")) for item in finishes)
    total_delivered = sum(numeric(item.get("delivered")) for item in finishes)
    total_expected_deliveries = sum(numeric(item.get("expectedDeliveries")) for item in finishes)
    total_heartbeat_sends = sum(numeric(item.get("heartbeatSends")) for item in finishes)
    total_heartbeat_acks = sum(numeric(item.get("heartbeatAcks")) for item in finishes)
    total_reconnects = sum(numeric(item.get("reconnects")) for item in finishes)
    heartbeat_p99 = max((numeric(item.get("heartbeatSendCompletionP99Ms")) for item in finishes), default=0.0)
    delivery_p99 = max((numeric(item.get("deliveryP99Ms")) for item in finishes), default=0.0)
    elapsed_ms = max((numeric(item.get("elapsedMs")) for item in finishes), default=0.0)
    login_cache_hit = all(str(item.get("loginCacheHit", "false")).lower() == "true" for item in finishes)
    return {
        "connections": total_connections,
        "successes": total_successes,
        "connectionSuccessRate": rate(total_successes, total_connections),
        "sent": total_sent,
        "ack": total_ack,
        "ackSuccessRate": rate(total_ack, total_sent) if total_sent > 0 else None,
        "delivered": total_delivered,
        "expectedDeliveries": total_expected_deliveries,
        "deliverySuccessRate": rate(total_delivered, total_expected_deliveries) if total_expected_deliveries > 0 else None,
        "heartbeatSends": total_heartbeat_sends,
        "heartbeatAcks": total_heartbeat_acks,
        "heartbeatAckRate": rate(total_heartbeat_acks, total_heartbeat_sends) if total_heartbeat_sends > 0 else None,
        "reconnects": total_reconnects,
        "heartbeatP99Ms": heartbeat_p99 if total_heartbeat_sends > 0 else None,
        "deliveryP99Ms": delivery_p99 if total_expected_deliveries > 0 else None,
        "elapsedSeconds": elapsed_ms / 1000 if elapsed_ms > 0 else None,
        "loginCacheHit": login_cache_hit,
        "finishCount": len(finishes),
    }


def summarize_monitor(scenario_dir: Path) -> dict[str, Any]:
    summaries = []
    for path in sorted(scenario_dir.rglob("*summary*.json")):
        item = read_json(path)
        if "finalProgress" in item or "finalKafkaLag" in item or "lagClearAfterSendSeconds" in item:
            summaries.append(item)
    if not summaries:
        return {}
    latest = summaries[-1]
    progress = latest.get("finalProgress") or {}
    final_lag = latest.get("finalKafkaLag") or {}
    return {
        "lagClearAfterSendSeconds": latest.get("lagClearAfterSendSeconds"),
        "finalKafkaLagZero": bool(final_lag) and all(value == 0 for value in final_lag.values()),
        "monitorMessageSent": progress.get("messageSent"),
        "monitorMessageAck": progress.get("messageAck"),
        "monitorFailures": progress.get("failures") or {},
    }


def metric_value(metric: dict[str, Any], key: str) -> float | None:
    value = metric.get(key)
    if value is None and key == "rate":
        value = metric.get("value")
    if value is None:
        return None
    return numeric(value)


def summarize_k6(scenario_dir: Path) -> dict[str, Any]:
    summary_path = scenario_dir / "k6-summary.json"
    if not summary_path.exists():
        return {}
    data = read_json(summary_path)
    metrics = data.get("metrics") or {}
    threshold_failures: list[str] = []
    sample_counts: list[float] = []
    http_failed = metric_value(metrics.get("http_req_failed", {}) or {}, "rate")
    http_duration = metrics.get("http_req_duration", {}) or {}
    values: dict[str, Any] = {
        "httpReqFailedRate": http_failed,
        "httpReqDurationP95": metric_value(http_duration, "p(95)"),
        "httpReqDurationP99": metric_value(http_duration, "p(99)"),
    }
    checks = metrics.get("checks", {}) or {}
    if checks:
        values["checksRate"] = metric_value(checks, "rate")
        values["checksFails"] = metric_value(checks, "fails")
    for name, metric in metrics.items():
        if not name.startswith("im_") or not isinstance(metric, dict):
            continue
        if "count" in metric:
            sample_counts.append(numeric(metric.get("count")))
        elif "passes" in metric or "fails" in metric:
            sample_counts.append(numeric(metric.get("passes")) + numeric(metric.get("fails")))
        for expression, failed in (metric.get("thresholds") or {}).items():
            if failed is True:
                threshold_failures.append(f"{name}:{expression}")
        for key in ("rate", "p(95)", "p(99)", "count"):
            if key in metric:
                values[f"{name}.{key}"] = metric_value(metric, key)
    if threshold_failures:
        values["thresholdFailures"] = threshold_failures
    if sample_counts:
        values["imMetricSampleCount"] = sum(sample_counts)
    return values


def summarize_stdout(scenario_dir: Path) -> dict[str, Any]:
    path = scenario_dir / "stdout.log"
    if not path.exists():
        return {}
    try:
        text = path.read_text(errors="replace")
    except OSError:
        return {}
    diagnostics: list[str] = []

    def add_diagnostic(value: str) -> None:
        cleaned = value.replace("\\n", " ").replace("\\t", " ")
        cleaned = re.sub(r"\s+", " ", cleaned).strip()
        if len(cleaned) > 160:
            cleaned = cleaned[:157] + "..."
        if cleaned and cleaned not in diagnostics:
            diagnostics.append(cleaned)

    go_error = re.search(r"GoError:\s*([^\"\\]+)", text)
    if go_error:
        add_diagnostic(f"GoError: {go_error.group(1)}")
    threshold_error = re.search(r"thresholds on metrics '([^']+)' have been crossed", text)
    if threshold_error:
        add_diagnostic(f"k6 thresholds crossed: {threshold_error.group(1)}")
    preflight_error = re.search(r"HTTP login preflight failed:\s*([^\n]+)", text)
    if preflight_error:
        add_diagnostic(f"HTTP login preflight failed: {preflight_error.group(1)}")
    requirement_error = re.search(r"Scenario requirement preflight failed:\s*([^\n]+)", text)
    if requirement_error:
        add_diagnostic(f"Scenario requirement preflight failed: {requirement_error.group(1)}")
    preflight_body = re.search(r"HTTP login preflight response body:\s*([^\n]+)", text)
    if preflight_body:
        add_diagnostic(f"HTTP login preflight response body: {preflight_body.group(1)}")
    for probe in re.finditer(r"HTTP endpoint probe:\s*([^\n]+)", text):
        add_diagnostic(f"HTTP endpoint probe: {probe.group(1)}")
    entrypoint_diagnosis = re.search(r"diagnosis=([^\s]+)\s+([^\n]+)", text)
    if entrypoint_diagnosis:
        add_diagnostic(f"HTTP entrypoint diagnosis: {entrypoint_diagnosis.group(1)} {entrypoint_diagnosis.group(2)}")
    generic_error = re.search(r"level=error msg=\"([^\"]+)\"", text)
    if generic_error and not diagnostics:
        add_diagnostic(generic_error.group(1))
    if "HTTP/1.1 403" in text or "status=403" in text:
        add_diagnostic("HTTP 403 observed")
    return {"diagnostics": diagnostics}


def run_target_from_metadata(metadata: list[dict[str, Any]]) -> dict[str, Any]:
    fields = ["baseURL", "tcpHost", "tcpPort"]
    values: dict[str, set[str]] = {field: set() for field in fields}
    for item in metadata:
        for field in fields:
            value = item.get(field)
            if value:
                values[field].add(str(value))
    target: dict[str, Any] = {}
    mixed = False
    for field in fields:
        if not values[field]:
            target[field] = ""
        elif len(values[field]) == 1:
            target[field] = next(iter(values[field]))
        else:
            target[field] = sorted(values[field])
            mixed = True
    target["mixed"] = mixed
    return target


def scenario_status(
    exit_code: int | None,
    tcp: dict[str, Any],
    monitor: dict[str, Any],
    k6: dict[str, Any],
    thresholds: Thresholds,
) -> tuple[str, list[str]]:
    reasons: list[str] = []
    if exit_code is None:
        reasons.append("missing exit code")
    elif exit_code != 0:
        reasons.append(f"command exit code {exit_code}")

    connection_rate = tcp.get("connectionSuccessRate")
    if connection_rate is not None and connection_rate < thresholds.min_connection_success_rate:
        reasons.append(f"connection success {percent(connection_rate)}")
    ack_rate = tcp.get("ackSuccessRate")
    if ack_rate is not None and ack_rate < thresholds.min_ack_success_rate:
        reasons.append(f"ack success {percent(ack_rate)}")
    delivery_rate = tcp.get("deliverySuccessRate")
    if delivery_rate is not None and delivery_rate < thresholds.min_delivery_success_rate:
        reasons.append(f"delivery success {percent(delivery_rate)}")
    heartbeat_rate = tcp.get("heartbeatAckRate")
    if heartbeat_rate is not None and heartbeat_rate < thresholds.min_heartbeat_ack_rate:
        reasons.append(f"heartbeat ACK {percent(heartbeat_rate)}")
    heartbeat_p99 = tcp.get("heartbeatP99Ms")
    if heartbeat_p99 is not None and heartbeat_p99 > thresholds.max_heartbeat_p99_ms:
        reasons.append(f"heartbeat p99 {number(heartbeat_p99, 'ms')}")
    delivery_p99 = tcp.get("deliveryP99Ms")
    if delivery_p99 is not None and delivery_p99 > thresholds.max_delivery_p99_ms:
        reasons.append(f"delivery p99 {number(delivery_p99, 'ms')}")

    lag_clear = monitor.get("lagClearAfterSendSeconds")
    if lag_clear is not None and numeric(lag_clear) > thresholds.max_lag_clear_after_send_seconds:
        reasons.append(f"lag clear {number(numeric(lag_clear), 's')}")
    if monitor.get("monitorFailures"):
        reasons.append(f"monitor failures {monitor['monitorFailures']}")
    if "finalKafkaLagZero" in monitor and not monitor["finalKafkaLagZero"]:
        reasons.append("final Kafka lag not zero")

    http_failed_rate = k6.get("httpReqFailedRate")
    if http_failed_rate is not None and http_failed_rate >= 0.005:
        reasons.append(f"http failure rate {percent(http_failed_rate)}")
    checks_fails = k6.get("checksFails")
    if checks_fails is not None and checks_fails > 0:
        reasons.append(f"k6 checks failed {number(checks_fails)}")
    threshold_failures = k6.get("thresholdFailures") or []
    if threshold_failures:
        reasons.append(f"k6 thresholds failed {', '.join(threshold_failures[:4])}")
    if k6 and k6.get("imMetricSampleCount") == 0:
        reasons.append("k6 produced zero IM metric samples")

    if reasons:
        return "FAIL", reasons
    if not tcp and not monitor and not k6:
        return "UNKNOWN", ["no parseable result artifacts"]
    return "PASS", []


def markdown_table(rows: list[list[str]]) -> str:
    if not rows:
        return ""
    header = rows[0]
    separator = ["---"] * len(header)
    lines = [
        "| " + " | ".join(header) + " |",
        "| " + " | ".join(separator) + " |",
    ]
    for row in rows[1:]:
        lines.append("| " + " | ".join(row) + " |")
    return "\n".join(lines)


def optimization_hint(category: str, reasons: list[str]) -> str:
    if any("local_network_proxy_http_403_intercept" in reason for reason in reasons):
        return (
            "The load generator or workstation route/proxy is intercepting the entrypoint probe. Disable local TUN/proxy "
            "or rerun from a clean network path before changing server-side Nginx, cloud routing, or application code."
        )
    if any("HTTP 403" in reason or "status=403" in reason for reason in reasons):
        return (
            "HTTP 403 is an entrypoint/deployment signal: verify BASE_URL, reverse proxy or firewall rules, "
            "service binding, and whether requests reach the IM API process before optimizing application code."
        )
    return CATEGORY_OPTIMIZATION_HINTS.get(category, "Inspect the failing scenario command, raw stdout, service metrics, and matching code path before tuning.")


def k6_p99_parts(k6: dict[str, Any]) -> list[str]:
    preferred = [
        ("im_auth_login_latency.p(99)", "login"),
        ("im_account_lifecycle_total_latency.p(99)", "account-total"),
        ("im_account_register_latency.p(99)", "register"),
        ("im_account_verification_resend_latency.p(99)", "verify-resend"),
        ("im_account_password_reset_request_latency.p(99)", "reset-request"),
        ("im_auth_session_total_latency.p(99)", "session-total"),
        ("im_auth_session_login_latency.p(99)", "session-login"),
        ("im_auth_session_refresh_latency.p(99)", "refresh"),
        ("im_auth_session_list_latency.p(99)", "sessions"),
        ("im_auth_session_push_register_latency.p(99)", "push-register"),
        ("im_auth_session_logout_latency.p(99)", "logout"),
        ("im_auth_session_management_total_latency.p(99)", "session-mgmt-total"),
        ("im_auth_session_management_list_latency.p(99)", "session-list"),
        ("im_auth_session_management_logout_one_latency.p(99)", "logout-one"),
        ("im_auth_session_management_logout_all_latency.p(99)", "logout-all"),
        ("im_client_health_total_latency.p(99)", "client-health-total"),
        ("im_client_health_report_latency.p(99)", "health-report"),
        ("im_client_health_diagnostics_report_latency.p(99)", "health-diag"),
        ("im_client_sync_mix_total_latency.p(99)", "sync-mix-total"),
        ("im_client_sync_mix_read_latency.p(99)", "sync-mix-read"),
        ("im_client_sync_mix_health_latency.p(99)", "sync-mix-health"),
        ("im_user_journey_total_latency.p(99)", "journey-total"),
        ("im_user_journey_read_latency.p(99)", "journey-read"),
        ("im_user_journey_write_latency.p(99)", "journey-write"),
        ("im_user_journey_health_latency.p(99)", "journey-health"),
        ("im_cold_start_total_latency.p(99)", "cold-total"),
        ("im_cold_start_list_latency.p(99)", "list"),
        ("im_cold_start_changes_latency.p(99)", "changes"),
        ("im_cold_start_messages_since_latency.p(99)", "since"),
        ("im_timeline_pagination_total_latency.p(99)", "timeline-page-total"),
        ("im_timeline_latest_latency.p(99)", "latest"),
        ("im_timeline_history_page_latency.p(99)", "history"),
        ("im_timeline_since_catchup_latency.p(99)", "since-catchup"),
        ("im_timeline_conversation_list_latency.p(99)", "list"),
        ("im_timeline_member_search_latency.p(99)", "member-search"),
        ("im_domain_events_total_latency.p(99)", "domain-total"),
        ("im_domain_events_visible_latency.p(99)", "domain-visible"),
        ("im_domain_events_query_latency.p(99)", "domain-query"),
        ("im_domain_events_accept_latency.p(99)", "domain-accept"),
        ("im_read_state_total_latency.p(99)", "read-total"),
        ("im_read_state_unread_latency.p(99)", "unread"),
        ("im_read_state_mark_read_latency.p(99)", "mark-read"),
        ("im_read_state_clear_latency.p(99)", "clear"),
        ("im_search_sync_visible_latency.p(99)", "search-visible"),
        ("im_search_sync_query_latency.p(99)", "search-query"),
        ("im_search_sync_accept_latency.p(99)", "search-accept"),
        ("im_group_admin_total_latency.p(99)", "admin-total"),
        ("im_group_admin_changes_latency.p(99)", "admin-changes"),
        ("im_group_admin_add_member_latency.p(99)", "add-member"),
        ("im_group_admin_title_latency.p(99)", "title"),
        ("im_group_admin_metadata_latency.p(99)", "metadata"),
        ("im_group_membership_total_latency.p(99)", "membership-total"),
        ("im_group_membership_role_latency.p(99)", "member-role"),
        ("im_group_membership_remove_latency.p(99)", "member-remove"),
        ("im_group_membership_leave_latency.p(99)", "member-leave"),
        ("im_group_invite_total_latency.p(99)", "invite-total"),
        ("im_group_invite_join_latency.p(99)", "invite-join"),
        ("im_group_invite_members_visible_latency.p(99)", "invite-members"),
        ("im_group_invite_revoke_latency.p(99)", "invite-revoke"),
        ("im_governance_total_latency.p(99)", "governance-total"),
        ("im_governance_preferences_visible_latency.p(99)", "prefs-visible"),
        ("im_governance_favorite_visible_latency.p(99)", "favorite"),
        ("im_governance_receipt_latency.p(99)", "receipt"),
        ("im_governance_recall_visible_latency.p(99)", "recall"),
        ("im_governance_delete_visible_latency.p(99)", "delete"),
        ("im_message_forward_total_latency.p(99)", "forward-total"),
        ("im_message_forward_command_latency.p(99)", "forward-cmd"),
        ("im_message_forward_timeline_latency.p(99)", "forward-timeline"),
        ("im_message_forward_summary_latency.p(99)", "forward-summary"),
        ("im_ai_stream_total_latency.p(99)", "ai-stream-total"),
        ("im_ai_stream_start_latency.p(99)", "ai-start"),
        ("im_ai_stream_complete_visible_latency.p(99)", "ai-complete"),
        ("im_ai_stream_cancel_latency.p(99)", "ai-cancel"),
        ("im_ai_stream_snapshot_latency.p(99)", "ai-snapshot"),
        ("im_contact_request_total_latency.p(99)", "request-total"),
        ("im_contact_request_send_latency.p(99)", "request-send"),
        ("im_contact_request_decline_latency.p(99)", "request-decline"),
        ("im_contact_request_cancel_latency.p(99)", "request-cancel"),
        ("im_contact_total_latency.p(99)", "contact-total"),
        ("im_contact_changes_latency.p(99)", "contact-changes"),
        ("im_contact_accept_latency.p(99)", "contact-accept"),
        ("im_contact_delete_latency.p(99)", "contact-delete"),
        ("im_profile_total_latency.p(99)", "profile-total"),
        ("im_profile_changes_latency.p(99)", "profile-changes"),
        ("im_profile_update_latency.p(99)", "profile-update"),
        ("im_profile_create_direct_latency.p(99)", "direct-create"),
        ("im_safety_total_latency.p(99)", "safety-total"),
        ("im_safety_report_latency.p(99)", "report"),
        ("im_safety_block_latency.p(99)", "block"),
        ("im_safety_unblock_latency.p(99)", "unblock"),
        ("im_admin_report_total_latency.p(99)", "admin-report-total"),
        ("im_admin_report_list_latency.p(99)", "report-list"),
        ("im_admin_report_update_latency.p(99)", "report-update"),
        ("im_admin_report_create_latency.p(99)", "report-create"),
        ("im_media_file_total_latency.p(99)", "media-total"),
        ("im_media_download_latency.p(99)", "media-down"),
        ("im_media_complete_latency.p(99)", "media-complete"),
        ("im_file_download_latency.p(99)", "file-down"),
        ("im_message_accept_latency.p(99)", "accept"),
        ("im_message_timeline_latency.p(99)", "timeline"),
        ("im_message_summary_latency.p(99)", "summary"),
        ("im_changes_latency.p(99)", "changes"),
    ]
    parts: list[str] = []
    for key, label in preferred:
        value = k6.get(key)
        if value is not None:
            parts.append(f"{label} {number(value, 'ms')}")
    return parts[:4]


def main() -> int:
    parser = argparse.ArgumentParser(description="Build a Markdown performance report from scenario artifacts.")
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--output")
    parser.add_argument("--json-output")
    parser.add_argument("--csv-output")
    parser.add_argument("--min-connection-success-rate", type=float, default=0.999)
    parser.add_argument("--min-ack-success-rate", type=float, default=0.999)
    parser.add_argument("--min-delivery-success-rate", type=float, default=0.999)
    parser.add_argument("--min-heartbeat-ack-rate", type=float, default=0.999)
    parser.add_argument("--max-heartbeat-p99-ms", type=float, default=10000)
    parser.add_argument("--max-delivery-p99-ms", type=float, default=3000)
    parser.add_argument("--max-lag-clear-after-send-seconds", type=float, default=15)
    args = parser.parse_args()

    run_dir = Path(args.run_dir)
    thresholds = Thresholds(
        min_connection_success_rate=args.min_connection_success_rate,
        min_ack_success_rate=args.min_ack_success_rate,
        min_delivery_success_rate=args.min_delivery_success_rate,
        min_heartbeat_ack_rate=args.min_heartbeat_ack_rate,
        max_heartbeat_p99_ms=args.max_heartbeat_p99_ms,
        max_delivery_p99_ms=args.max_delivery_p99_ms,
        max_lag_clear_after_send_seconds=args.max_lag_clear_after_send_seconds,
    )

    rows = [[
        "Scenario",
        "Category",
        "Status",
        "Connections",
        "Ack",
        "Delivery",
        "Heartbeat",
        "P99",
        "Lag Clear",
        "Notes",
    ]]
    detail_lines: list[str] = []
    optimization_lines: list[str] = []
    category_stats: dict[str, dict[str, int]] = {}
    scenario_records: list[dict[str, Any]] = []
    scenario_metadata: list[dict[str, Any]] = []
    failed = 0
    unknown = 0

    scenario_dirs = sorted(path for path in run_dir.iterdir() if path.is_dir()) if run_dir.exists() else []
    for scenario_dir in scenario_dirs:
        meta = read_json(scenario_dir / "scenario.json")
        if meta:
            scenario_metadata.append(meta)
        name = meta.get("name") or scenario_dir.name
        category = meta.get("category") or "-"
        exit_code = read_exit_code(scenario_dir / "exit-code.txt")
        tcp = summarize_tcp(collect_tcp_finishes(scenario_dir))
        monitor = summarize_monitor(scenario_dir)
        k6 = summarize_k6(scenario_dir)
        stdout = summarize_stdout(scenario_dir)
        status, reasons = scenario_status(exit_code, tcp, monitor, k6, thresholds)
        diagnostics = stdout.get("diagnostics") or []
        for diagnostic in diagnostics:
            if diagnostic not in reasons:
                reasons.append(diagnostic)
        if status == "PASS" and diagnostics:
            status = "FAIL"
        if status == "FAIL":
            failed += 1
        elif status == "UNKNOWN":
            unknown += 1
        stats = category_stats.setdefault(str(category), {"PASS": 0, "FAIL": 0, "UNKNOWN": 0})
        stats[status] = stats.get(status, 0) + 1

        p99_parts = []
        if tcp.get("heartbeatP99Ms") is not None:
            p99_parts.append(f"hb {number(tcp.get('heartbeatP99Ms'), 'ms')}")
        if tcp.get("deliveryP99Ms") is not None:
            p99_parts.append(f"del {number(tcp.get('deliveryP99Ms'), 'ms')}")
        p99_parts.extend(k6_p99_parts(k6))
        if k6.get("httpReqDurationP99") is not None:
            p99_parts.append(f"http {number(k6.get('httpReqDurationP99'), 'ms')}")

        lag_clear_seconds = (
            numeric(monitor.get("lagClearAfterSendSeconds"))
            if monitor.get("lagClearAfterSendSeconds") is not None
            else None
        )
        optimization = optimization_hint(str(category), reasons) if status == "FAIL" else None
        scenario_records.append({
            "name": str(name),
            "category": str(category),
            "target": meta.get("target", "-"),
            "runTarget": {
                "baseURL": str(meta.get("baseURL") or ""),
                "tcpHost": str(meta.get("tcpHost") or ""),
                "tcpPort": str(meta.get("tcpPort") or ""),
            },
            "status": status,
            "exitCode": exit_code,
            "reasons": reasons,
            "optimizationHint": optimization,
            "p99": p99_parts,
            "lagClearAfterSendSeconds": lag_clear_seconds,
            "tcp": tcp,
            "monitor": monitor,
            "k6": k6,
            "diagnostics": diagnostics,
        })

        rows.append([
            str(name),
            str(category),
            status,
            f"{number(tcp.get('successes'))}/{number(tcp.get('connections'))}" if tcp else "-",
            f"{number(tcp.get('ack'))}/{number(tcp.get('sent'))} {percent(tcp.get('ackSuccessRate'))}" if tcp.get("sent") else "-",
            (
                f"{number(tcp.get('delivered'))}/{number(tcp.get('expectedDeliveries'))} "
                f"{percent(tcp.get('deliverySuccessRate'))}"
                if tcp.get("expectedDeliveries")
                else "-"
            ),
            (
                f"{number(tcp.get('heartbeatAcks'))}/{number(tcp.get('heartbeatSends'))} "
                f"{percent(tcp.get('heartbeatAckRate'))}"
                if tcp.get("heartbeatSends")
                else "-"
            ),
            ", ".join(p99_parts) if p99_parts else "-",
            number(lag_clear_seconds, "s"),
            "; ".join(reasons) if reasons else "-",
        ])

        detail_lines.append(f"### {name}\n")
        detail_lines.append(f"- category: `{category}`")
        detail_lines.append(f"- target: `{meta.get('target', '-')}`")
        detail_lines.append(f"- exitCode: `{exit_code if exit_code is not None else 'missing'}`")
        if tcp:
            detail_lines.append(f"- tcp: `{json.dumps(tcp, sort_keys=True)}`")
        if monitor:
            detail_lines.append(f"- monitor: `{json.dumps(monitor, sort_keys=True)}`")
        if k6:
            detail_lines.append(f"- k6: `{json.dumps(k6, sort_keys=True)}`")
        if stdout:
            detail_lines.append(f"- stdout: `{json.dumps(stdout, sort_keys=True)}`")
        if reasons:
            detail_lines.append(f"- action: investigate `{'; '.join(reasons)}`")
            if status == "FAIL":
                detail_lines.append(f"- optimizationHint: {optimization}")
                optimization_lines.append(f"- `{name}` (`{category}`): {optimization}")
        detail_lines.append("")

    category_rows = [["Category", "PASS", "FAIL", "UNKNOWN", "Total"]]
    category_records: list[dict[str, Any]] = []
    for category, stats in sorted(category_stats.items()):
        passed = stats.get("PASS", 0)
        failed_count = stats.get("FAIL", 0)
        unknown_count = stats.get("UNKNOWN", 0)
        category_records.append({
            "category": category,
            "pass": passed,
            "fail": failed_count,
            "unknown": unknown_count,
            "total": passed + failed_count + unknown_count,
        })
        category_rows.append([
            category,
            str(passed),
            str(failed_count),
            str(unknown_count),
            str(passed + failed_count + unknown_count),
        ])

    total = max(len(scenario_dirs), 1)
    run_target = run_target_from_metadata(scenario_metadata)
    report = [
        f"# Performance Test Report",
        "",
        f"- runDir: `{run_dir}`",
        f"- baseURL: `{run_target.get('baseURL') or '-'}`",
        f"- tcpHost: `{run_target.get('tcpHost') or '-'}`",
        f"- tcpPort: `{run_target.get('tcpPort') or '-'}`",
        f"- mixedTarget: `{run_target.get('mixed')}`",
        f"- scenarios: `{len(scenario_dirs)}`",
        f"- failed: `{failed}`",
        f"- unknown: `{unknown}`",
        "",
        markdown_table(rows),
        "",
        "## Category Summary",
        "",
        markdown_table(category_rows),
        "",
        "## Optimization Hints",
        "",
        *(optimization_lines if optimization_lines else ["- No failed scenarios with optimization hints."]),
        "",
        "## Details",
        "",
        *detail_lines,
    ]
    output = "\n".join(report).rstrip() + "\n"
    if args.output:
        Path(args.output).write_text(output)
    if args.json_output:
        payload = {
            "runDir": str(run_dir),
            "target": run_target,
            "scenarioCount": len(scenario_dirs),
            "failed": failed,
            "unknown": unknown,
            "categorySummary": category_records,
            "scenarios": scenario_records,
        }
        Path(args.json_output).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    if args.csv_output:
        csv_path = Path(args.csv_output)
        with csv_path.open("w", newline="") as handle:
            writer = csv.DictWriter(
                handle,
                fieldnames=[
                    "name",
                    "category",
                    "target",
                    "status",
                    "exitCode",
                    "reasons",
                    "optimizationHint",
                    "p99",
                    "lagClearAfterSendSeconds",
                    "connectionSuccessRate",
                    "ackSuccessRate",
                    "deliverySuccessRate",
                    "heartbeatAckRate",
                    "reconnects",
                    "httpReqFailedRate",
                    "httpReqDurationP99",
                ],
            )
            writer.writeheader()
            for record in scenario_records:
                tcp = record.get("tcp") or {}
                k6 = record.get("k6") or {}
                writer.writerow({
                    "name": record.get("name"),
                    "category": record.get("category"),
                    "target": record.get("target"),
                    "status": record.get("status"),
                    "exitCode": record.get("exitCode"),
                    "reasons": "; ".join(record.get("reasons") or []),
                    "optimizationHint": record.get("optimizationHint") or "",
                    "p99": "; ".join(record.get("p99") or []),
                    "lagClearAfterSendSeconds": record.get("lagClearAfterSendSeconds"),
                    "connectionSuccessRate": tcp.get("connectionSuccessRate"),
                    "ackSuccessRate": tcp.get("ackSuccessRate"),
                    "deliverySuccessRate": tcp.get("deliverySuccessRate"),
                    "heartbeatAckRate": tcp.get("heartbeatAckRate"),
                    "reconnects": tcp.get("reconnects"),
                    "httpReqFailedRate": k6.get("httpReqFailedRate"),
                    "httpReqDurationP99": k6.get("httpReqDurationP99"),
                })
    print(output)
    return 1 if failed == total else 0


if __name__ == "__main__":
    raise SystemExit(main())
