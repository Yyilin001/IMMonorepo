#!/usr/bin/env python3
"""Render a local-only hot-conversation benchmark report from k6 and Prometheus snapshots."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


SAMPLE = re.compile(r"^(?P<name>[A-Za-z_:][A-Za-z0-9_:]*)(?:\{(?P<labels>[^}]*)\})?\s+(?P<value>[-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)$")
LABEL = re.compile(r'\s*([A-Za-z_][A-Za-z0-9_]*)="((?:\\.|[^"\\])*)"\s*(?:,|$)')


def parse_metrics(path: Path) -> dict[tuple[str, tuple[tuple[str, str], ...]], float]:
    samples: dict[tuple[str, tuple[tuple[str, str], ...]], float] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        match = SAMPLE.match(line)
        if match is None:
            continue
        labels: dict[str, str] = {}
        label_text = match.group("labels") or ""
        position = 0
        while position < len(label_text):
            label_match = LABEL.match(label_text, position)
            if label_match is None:
                raise ValueError(f"Unsupported Prometheus labels in {path}: {line}")
            labels[label_match.group(1)] = bytes(label_match.group(2), "utf-8").decode("unicode_escape")
            position = label_match.end()
        samples[(match.group("name"), tuple(sorted(labels.items())))] = float(match.group("value"))
    return samples


def value(samples: dict[tuple[str, tuple[tuple[str, str], ...]], float], name: str, **labels: str) -> float | None:
    return samples.get((name, tuple(sorted(labels.items()))))


def delta(before: dict[tuple[str, tuple[tuple[str, str], ...]], float], after: dict[tuple[str, tuple[tuple[str, str], ...]], float], name: str, **labels: str) -> float | None:
    before_value = value(before, name, **labels)
    after_value = value(after, name, **labels)
    if before_value is None or after_value is None:
        return None
    return max(0.0, after_value - before_value)


def delta_all_labels(before: dict[tuple[str, tuple[tuple[str, str], ...]], float], after: dict[tuple[str, tuple[tuple[str, str], ...]], float], name: str) -> float | None:
    before_values = [sample for (sample_name, _), sample in before.items() if sample_name == name]
    after_values = [sample for (sample_name, _), sample in after.items() if sample_name == name]
    if not before_values or not after_values:
        return None
    return max(0.0, sum(after_values) - sum(before_values))


def compact_number(number: float | None) -> int | float | None:
    if number is None:
        return None
    normalized = float(number)
    return int(normalized) if normalized.is_integer() else round(normalized, 3)


def average(total: float | None, count: float | None) -> int | float | None:
    if total is None or count is None or count <= 0:
        return None
    return compact_number(total / count)


def metric_values(summary: dict[str, Any], name: str) -> dict[str, int | float] | None:
    metric = (summary.get("metrics") or {}).get(name)
    if not isinstance(metric, dict):
        return None
    # k6 summary-export writes metric statistics directly, while some older
    # adapters wrapped them in a `values` object. Accept both formats so local
    # reports retain latency evidence across k6 versions.
    values = metric.get("values", metric)
    if not isinstance(values, dict):
        return None
    return {key: compact_number(float(raw)) for key, raw in values.items() if isinstance(raw, (int, float))}


def counter_group(before: dict[tuple[str, tuple[tuple[str, str], ...]], float], after: dict[tuple[str, tuple[tuple[str, str], ...]], float], names: dict[str, str]) -> dict[str, int | float | None]:
    return {label: compact_number(delta(before, after, metric)) for label, metric in names.items()}


def build_report(run_id: str, base_url: str, profile: str, before: dict[tuple[str, tuple[tuple[str, str], ...]], float], after: dict[tuple[str, tuple[tuple[str, str], ...]], float], k6: dict[str, Any]) -> dict[str, Any]:
    command_count = delta(before, after, "im_message_write_command_requests_total")
    command_total = delta(before, after, "im_message_write_command_duration_millis_total")
    command_persist_total = delta(before, after, "im_message_write_command_persist_millis_total")
    pipeline_batches = delta(before, after, "im_message_write_pipeline_batches_total")
    pipeline_total = delta(before, after, "im_message_write_pipeline_duration_millis_total")

    persistence_stages: dict[str, dict[str, int | float | None]] = {}
    for stage in ("databaseRoute", "serverSequencePreallocate", "transaction", "membershipContext", "existingLookup", "directPolicy", "serverSequenceAllocate", "aggregateSequencePreallocate", "outboxEnqueue"):
        count = delta(before, after, "im_message_write_pipeline_stage_count_total", stage=stage)
        total = delta(before, after, "im_message_write_pipeline_stage_duration_millis_total", stage=stage)
        max_value = value(after, "im_message_write_pipeline_stage_duration_millis_max", stage=stage)
        if count is not None or total is not None or max_value is not None:
            persistence_stages[stage] = {
                "count": compact_number(count),
                "totalMillis": compact_number(total),
                "averageMillis": average(total, count),
                "processLifetimeMaxMillis": compact_number(max_value),
            }

    timeline_count = delta(before, after, "im_timeline_read_latency_millis_count", kind="since")
    timeline_total = delta(before, after, "im_timeline_read_latency_millis_sum", kind="since")
    report = {
        "schemaVersion": 1,
        "evidence": {"localOnly": True, "productionCapacityEvidence": False},
        "runID": run_id,
        "target": {"baseURL": base_url, "profile": profile},
        "k6": {
            "httpRequestDuration": metric_values(k6, "http_req_duration"),
            "hotWriteSendLatency": metric_values(k6, "im_hot_write_send_latency"),
            "hotWriteErrors": metric_values(k6, "im_hot_write_errors"),
            "checks": metric_values(k6, "checks"),
        },
        "stages": {
            "command": {
                "requests": compact_number(command_count),
                "failures": compact_number(delta(before, after, "im_message_write_command_failures_total")),
                "totalMillis": compact_number(command_total),
                "averageMillis": average(command_total, command_count),
                "persistTotalMillis": compact_number(command_persist_total),
                "persistAverageMillis": average(command_persist_total, command_count),
            },
            "persistence": {
                "batches": compact_number(pipeline_batches),
                "messages": compact_number(delta(before, after, "im_message_write_pipeline_messages_total")),
                "totalMillis": compact_number(pipeline_total),
                "averageBatchMillis": average(pipeline_total, pipeline_batches),
                "stages": persistence_stages,
            },
            "outbox": {
                **counter_group(before, after, {
                    "processedEvents": "im_outbox_processed_events_total",
                    "failedEvents": "im_outbox_failed_events_total",
                }),
                "backlogBefore": compact_number(value(before, "im_outbox_backlog_events")),
                "backlogAfter": compact_number(value(after, "im_outbox_backlog_events")),
            },
            "projection": {
                "lagBeforeMillis": compact_number(value(before, "im_projection_lag_millis")),
                "lagAfterMillis": compact_number(value(after, "im_projection_lag_millis")),
                "streamProcessedRuns": compact_number(delta_all_labels(before, after, "im_stream_processed_runs_total")),
                "streamFailedEvents": compact_number(delta_all_labels(before, after, "im_stream_failed_events_total")),
            },
            "relay": {
                "requestAttempts": compact_number(delta(before, after, "im_gateway_http_relay_request_attempts_total")),
                "requestFailures": compact_number(delta(before, after, "im_gateway_http_relay_request_failures_total")),
                "requestTotalMillis": compact_number(delta(before, after, "im_gateway_http_relay_request_latency_millis_total")),
                "requestAverageMillis": average(
                    delta(before, after, "im_gateway_http_relay_request_latency_millis_total"),
                    delta(before, after, "im_gateway_http_relay_request_attempts_total"),
                ),
                "inboundRequests": compact_number(delta(before, after, "im_gateway_http_relay_inbound_requests_total")),
                "inboundFailures": compact_number(delta(before, after, "im_gateway_http_relay_inbound_failures_total")),
                "inboundTotalMillis": compact_number(delta(before, after, "im_gateway_http_relay_inbound_latency_millis_total")),
                "inboundAverageMillis": average(
                    delta(before, after, "im_gateway_http_relay_inbound_latency_millis_total"),
                    delta(before, after, "im_gateway_http_relay_inbound_requests_total"),
                ),
            },
            "timelineSince": {
                "reads": compact_number(timeline_count),
                "totalMillis": compact_number(timeline_total),
                "averageMillis": average(timeline_total, timeline_count),
                **counter_group(before, after, {
                    "hotCacheHits": "im_timeline_since_hot_cache_hits_total",
                    "hotCacheMisses": "im_timeline_since_hot_cache_misses_total",
                    "targetSequenceRequests": "im_timeline_since_target_sequence_requests_total",
                    "strongFallbacks": "im_timeline_since_target_sequence_strong_fallbacks_total",
                    "errors": "im_timeline_since_target_sequence_errors_total",
                }),
            },
        },
        "notes": [
            "All averages are computed from counter deltas across this run window.",
            "processLifetimeMaxMillis values are not window-scoped and must not be compared as a run maximum.",
            "A combined local runtime can omit relay and stream work; null or zero values describe that topology, not a production result.",
        ],
    }
    return report


def run_self_test() -> None:
    key = lambda name, **labels: (name, tuple(sorted(labels.items())))
    before = {
        key("im_message_write_command_requests_total"): 10,
        key("im_message_write_command_duration_millis_total"): 100,
        key("im_message_write_command_persist_millis_total"): 60,
        key("im_message_write_command_failures_total"): 0,
        key("im_message_write_pipeline_batches_total"): 10,
        key("im_message_write_pipeline_messages_total"): 10,
        key("im_message_write_pipeline_duration_millis_total"): 80,
        key("im_message_write_pipeline_stage_count_total", stage="databaseRoute"): 10,
        key("im_message_write_pipeline_stage_duration_millis_total", stage="databaseRoute"): 30,
        key("im_message_write_pipeline_stage_duration_millis_max", stage="databaseRoute"): 5,
        key("im_gateway_http_relay_request_attempts_total"): 1,
        key("im_gateway_http_relay_request_latency_millis_total"): 4,
        key("im_timeline_read_latency_millis_count", kind="since"): 1,
        key("im_timeline_read_latency_millis_sum", kind="since"): 7,
    }
    after = {
        **before,
        key("im_message_write_command_requests_total"): 14,
        key("im_message_write_command_duration_millis_total"): 180,
        key("im_message_write_command_persist_millis_total"): 116,
        key("im_message_write_pipeline_batches_total"): 14,
        key("im_message_write_pipeline_messages_total"): 14,
        key("im_message_write_pipeline_duration_millis_total"): 148,
        key("im_message_write_pipeline_stage_count_total", stage="databaseRoute"): 14,
        key("im_message_write_pipeline_stage_duration_millis_total", stage="databaseRoute"): 46,
        key("im_message_write_pipeline_stage_duration_millis_max", stage="databaseRoute"): 8,
        key("im_gateway_http_relay_request_attempts_total"): 3,
        key("im_gateway_http_relay_request_latency_millis_total"): 24,
        key("im_timeline_read_latency_millis_count", kind="since"): 3,
        key("im_timeline_read_latency_millis_sum", kind="since"): 19,
    }
    report = build_report(
        "self-test",
        "http://127.0.0.1:8080",
        "local-hot-smoke",
        before,
        after,
        {"metrics": {"http_req_duration": {"avg": 12.5, "p(95)": 20}}},
    )
    assert report["stages"]["command"]["requests"] == 4
    assert report["stages"]["command"]["averageMillis"] == 20
    assert report["stages"]["persistence"]["stages"]["databaseRoute"]["averageMillis"] == 4
    assert report["stages"]["relay"]["requestAverageMillis"] == 10
    assert report["stages"]["timelineSince"]["averageMillis"] == 6
    assert report["k6"]["httpRequestDuration"] == {"avg": 12.5, "p(95)": 20}
    assert report["evidence"]["productionCapacityEvidence"] is False
    print("local_hot_conversation_report_self_test result=pass")


def main() -> None:
    if sys.argv[1:] == ["--self-test"]:
        run_self_test()
        return
    parser = argparse.ArgumentParser(description="Build a local-only hot-conversation stage report.")
    parser.add_argument("--before", required=True, type=Path)
    parser.add_argument("--after", required=True, type=Path)
    parser.add_argument("--k6-summary", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--profile", required=True)
    args = parser.parse_args()

    summary = json.loads(args.k6_summary.read_text(encoding="utf-8"))
    report = build_report(args.run_id, args.base_url, args.profile, parse_metrics(args.before), parse_metrics(args.after), summary)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
    print(f"local_hot_conversation_report result=pass productionEvidence=false output={args.output}")


if __name__ == "__main__":
    main()
