#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import subprocess
import time
import urllib.request
from pathlib import Path


def positive_float(value: str) -> float:
    parsed = float(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return parsed


def non_negative_int(value: str) -> int:
    parsed = int(value)
    if parsed < 0:
        raise argparse.ArgumentTypeError("must be non-negative")
    return parsed


def run_text(args: list[str], timeout_seconds: float = 5) -> str:
    try:
        completed = subprocess.run(
            args,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=timeout_seconds,
        )
    except Exception as error:
        return f"__command_error__ {type(error).__name__}: {error}"
    return completed.stdout


def read_progress(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except Exception as error:
        return {"readError": f"{type(error).__name__}: {error}"}


def parse_total_lag(text: str) -> int | None:
    for line in text.splitlines():
        if line.strip().startswith("TOTAL-LAG"):
            parts = line.split()
            if len(parts) >= 2 and parts[1].isdigit():
                return int(parts[1])
    return None


def sample_kafka_lag(redpanda_container: str, groups: list[str]) -> dict[str, int | None]:
    lags: dict[str, int | None] = {}
    for group in groups:
        output = run_text(["docker", "exec", redpanda_container, "rpk", "group", "describe", group])
        lags[group] = parse_total_lag(output)
    return lags


def parse_metrics(text: str, names: set[str]) -> dict[str, float]:
    values: dict[str, float] = {}
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) != 2 or parts[0] not in names:
            continue
        try:
            values[parts[0]] = float(parts[1])
        except ValueError:
            continue
    return values


def sample_metrics(url: str | None, secret: str | None, names: set[str]) -> dict[str, float]:
    if not url or not names:
        return {}
    request = urllib.request.Request(url)
    if secret:
        request.add_header("X-IM-Internal-Secret", secret)
        request.add_header("X-IM-Metrics-Secret", secret)
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            return parse_metrics(response.read().decode(errors="replace"), names)
    except Exception as error:
        return {"__metrics_error__": str(error)}


def sample_container_stats(containers: list[str]) -> dict[str, dict[str, str]]:
    if not containers:
        return {}
    output = run_text(
        [
            "docker",
            "stats",
            "--no-stream",
            "--format",
            "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}",
            *containers,
        ],
        timeout_seconds=10,
    )
    stats: dict[str, dict[str, str]] = {}
    for line in output.splitlines():
        parts = line.split("\t")
        if len(parts) == 3:
            stats[parts[0]] = {"cpu": parts[1], "memory": parts[2]}
    return stats


def tcp_established_count(port: int) -> int | None:
    output = run_text(["ss", "-tan", "state", "established", f"( sport = :{port} )"])
    if output.startswith("__command_error__"):
        return None
    lines = [line for line in output.splitlines()[1:] if line.strip()]
    return len(lines)


def all_lags_zero(lags: dict[str, int | None]) -> bool:
    return bool(lags) and all(value == 0 for value in lags.values())


def main() -> int:
    parser = argparse.ArgumentParser(description="Sample TCP message test drain time and write JSONL evidence.")
    parser.add_argument("--progress-file", required=True)
    parser.add_argument("--output-jsonl", required=True)
    parser.add_argument("--summary-file")
    parser.add_argument("--expected-messages", type=non_negative_int, required=True)
    parser.add_argument("--sample-interval-seconds", type=positive_float, default=1)
    parser.add_argument("--heavy-sample-interval-seconds", type=positive_float, default=5)
    parser.add_argument("--post-send-timeout-seconds", type=non_negative_int, default=180)
    parser.add_argument("--tcp-port", type=int, default=9000)
    parser.add_argument("--redpanda-container", default="imserver-redpanda-1")
    parser.add_argument(
        "--consumer-groups",
        default="domain-delivery-consumer,realtime-delivery-consumer,summary-projection-consumer,notification-consumer",
    )
    parser.add_argument("--metrics-url", default="http://127.0.0.1:8080/internal/metrics")
    parser.add_argument("--metrics-secret", default="")
    parser.add_argument(
        "--metrics-names",
        default=(
            "im_gateway_http_relay_inbound_requests_total,"
            "im_gateway_http_relay_inbound_successes_total,"
            "im_gateway_http_relay_inbound_failures_total,"
            "im_gateway_http_relay_inbound_latency_max_millis,"
            "im_local_fanout_packets_total,"
            "im_local_fanout_target_connections_total,"
            "im_local_fanout_chunks_total,"
            "im_local_fanout_event_loop_jobs_total,"
            "im_local_fanout_event_loop_job_start_lag_max_millis,"
            "im_tcp_write_completions_total,"
            "im_tcp_write_failures_total,"
            "im_tcp_write_backpressure_total,"
            "im_tcp_write_slow_total"
        ),
    )
    parser.add_argument(
        "--stats-containers",
        default=(
            "imserver-gateway-1,imserver-command-api-1,imserver-stream-consumer-realtime-1,"
            "imserver-stream-consumer-domain-1,imserver-stream-consumer-summary-1,"
            "imserver-postgres-1,imserver-redpanda-1,imserver-redis-1"
        ),
    )
    args = parser.parse_args()

    progress_path = Path(args.progress_file)
    output_path = Path(args.output_jsonl)
    summary_path = Path(args.summary_file) if args.summary_file else None
    groups = [item.strip() for item in args.consumer_groups.split(",") if item.strip()]
    metric_names = {item.strip() for item in args.metrics_names.split(",") if item.strip()}
    containers = [item.strip() for item in args.stats_containers.split(",") if item.strip()]

    started = time.monotonic()
    send_complete_at: float | None = None
    ack_complete_at: float | None = None
    lag_clear_at: float | None = None
    first_message_at: float | None = None
    final_progress: dict = {}
    final_lags: dict[str, int | None] = {}
    last_heavy_sample_at = 0.0
    latest_metrics: dict[str, float] = {}
    latest_container_stats: dict[str, dict[str, str]] = {}

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w") as output:
        while True:
            now = time.monotonic()
            progress = read_progress(progress_path)
            final_progress = progress
            elapsed = progress.get("elapsedSeconds")
            message_sent = int(progress.get("messageSent") or 0)
            message_ack = int(progress.get("messageAck") or 0)
            if first_message_at is None and message_sent > 0:
                first_message_at = now
            if send_complete_at is None and args.expected_messages > 0 and message_sent >= args.expected_messages:
                send_complete_at = now
            if ack_complete_at is None and args.expected_messages > 0 and message_ack >= args.expected_messages:
                ack_complete_at = now

            lags = sample_kafka_lag(args.redpanda_container, groups)
            final_lags = lags
            if send_complete_at is not None and lag_clear_at is None and all_lags_zero(lags):
                lag_clear_at = now

            if now - last_heavy_sample_at >= args.heavy_sample_interval_seconds:
                latest_metrics = sample_metrics(args.metrics_url, args.metrics_secret or None, metric_names)
                latest_container_stats = sample_container_stats(containers)
                last_heavy_sample_at = now

            sample = {
                "timestampMs": int(time.time() * 1000),
                "monitorElapsedSeconds": round(now - started, 3),
                "driverElapsedSeconds": elapsed,
                "progress": progress,
                "kafkaLag": lags,
                "tcpEstablished": tcp_established_count(args.tcp_port),
                "metrics": latest_metrics,
                "containerStats": latest_container_stats,
                "derived": {
                    "firstMessageMonitorSeconds": None if first_message_at is None else round(first_message_at - started, 3),
                    "sendCompleteMonitorSeconds": None if send_complete_at is None else round(send_complete_at - started, 3),
                    "ackCompleteMonitorSeconds": None if ack_complete_at is None else round(ack_complete_at - started, 3),
                    "lagClearMonitorSeconds": None if lag_clear_at is None else round(lag_clear_at - started, 3),
                    "lagClearAfterSendSeconds": (
                        None if lag_clear_at is None or send_complete_at is None else round(lag_clear_at - send_complete_at, 3)
                    ),
                },
            }
            output.write(json.dumps(sample, separators=(",", ":")) + "\n")
            output.flush()

            if send_complete_at is not None and lag_clear_at is not None:
                break
            if send_complete_at is not None and now - send_complete_at >= args.post_send_timeout_seconds:
                break
            time.sleep(args.sample_interval_seconds)

    summary = {
        "expectedMessages": args.expected_messages,
        "firstMessageMonitorSeconds": None if first_message_at is None else round(first_message_at - started, 3),
        "sendCompleteMonitorSeconds": None if send_complete_at is None else round(send_complete_at - started, 3),
        "ackCompleteMonitorSeconds": None if ack_complete_at is None else round(ack_complete_at - started, 3),
        "lagClearMonitorSeconds": None if lag_clear_at is None else round(lag_clear_at - started, 3),
        "lagClearAfterSendSeconds": None if lag_clear_at is None or send_complete_at is None else round(lag_clear_at - send_complete_at, 3),
        "finalKafkaLag": final_lags,
        "finalProgress": final_progress,
    }
    summary_text = json.dumps(summary, indent=2, sort_keys=True)
    if summary_path:
        summary_path.write_text(summary_text + "\n")
    print(summary_text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
