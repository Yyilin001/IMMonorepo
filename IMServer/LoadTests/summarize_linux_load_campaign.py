#!/usr/bin/env python3
"""Summarize Linux TCP capacity and message-delivery campaign artifacts."""

from __future__ import annotations

import argparse
import re
from collections import defaultdict
from pathlib import Path


ONLINE_RESULT = re.compile(
    r"step_result=(?P<result>\w+) connections=(?P<connections>\d+) "
    r"authOK=(?P<auth>\d+) successes=(?P<successes>\d+) successRatePercent=(?P<rate>[\d.]+)"
)
PROFILE_RESULT = re.compile(r"profile=linux-online\s+(?P<body>.*)")
KEY_VALUE = re.compile(r"(\w+)=((?:\{[^}]*\})|(?:\[[^]]*\])|(?:[^\s]+))")
MEMORY = re.compile(r"^Mem:\s+(?P<total>\d+)\s+(?P<used>\d+)\s+(?P<free>\d+)\s+(?P<shared>\d+)\s+(?P<cache>\d+)\s+(?P<available>\d+)")
DOCKER = re.compile(r"^(?P<name>\S+)\s+cpu=(?P<cpu>[\d.]+)%\s+mem=(?P<used>[\d.]+)(?P<unit>KiB|MiB|GiB)")


def as_mib(value: float, unit: str) -> float:
    if unit == "GiB":
        return value * 1024
    if unit == "KiB":
        return value / 1024
    return value


def extract_online_results(root: Path) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for path in root.rglob("connections-*/result.log"):
        for line in path.read_text(errors="replace").splitlines():
            match = ONLINE_RESULT.search(line)
            if match:
                row = match.groupdict()
                row["artifact"] = str(path.relative_to(root))
                rows.append(row)
    return rows


def extract_message_results(root: Path) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for path in root.rglob("*.log"):
        if "message-matrix" not in path.parts:
            continue
        if path.name != "summary.log" and not path.name.startswith("summary-shard-"):
            continue
        for line in path.read_text(errors="replace").splitlines():
            match = PROFILE_RESULT.search(line)
            if not match:
                continue
            values = dict(KEY_VALUE.findall(match.group("body")))
            values["artifact"] = str(path.relative_to(root))
            rows.append(values)
    return rows


def extract_resources(root: Path) -> tuple[dict[str, dict[str, float]], int | None]:
    service: dict[str, dict[str, float]] = defaultdict(lambda: {"cpu": 0.0, "memoryMiB": 0.0})
    available_min: int | None = None
    for path in root.rglob("host-metrics.log"):
        for line in path.read_text(errors="replace").splitlines():
            memory = MEMORY.match(line)
            if memory:
                available = int(memory.group("available"))
                available_min = available if available_min is None else min(available_min, available)
                continue
            docker = DOCKER.match(line)
            if docker:
                name = docker.group("name")
                service[name]["cpu"] = max(service[name]["cpu"], float(docker.group("cpu")))
                service[name]["memoryMiB"] = max(
                    service[name]["memoryMiB"],
                    as_mib(float(docker.group("used")), docker.group("unit")),
                )
    return dict(service), available_min


def render(root: Path) -> str:
    online = extract_online_results(root)
    messages = extract_message_results(root)
    services, available_min = extract_resources(root)
    lines = ["# Linux Load Campaign Summary", "", f"Artifacts: `{root}`", ""]

    lines += ["## Online Capacity", "", "| Connections | Auth OK | Successes | Rate | Evidence |", "|---:|---:|---:|---:|---|"]
    if online:
        for row in online:
            lines.append(
                f"| {row['connections']} | {row['auth']} | {row['successes']} | {row['rate']}% | `{row['artifact']}` |"
            )
    else:
        lines.append("| - | - | - | - | Not complete |")

    lines += ["", "## Message Delivery", "", "| Evidence | Connections | Sent | Accepted ACK | ACK Coverage | Known Deliveries | Expected | Delivery Coverage | P95 | P99 |", "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
    if messages:
        for row in messages:
            latency = row.get("messageDeliveryLatencyMs", "{}")
            latency_values = {
                key: match.group(1)
                for key in ("p95", "p99")
                if (match := re.search(rf"['\"]{key}['\"]:\s*([^,}}]+)", latency))
            }
            lines.append(
                "| `{artifact}` | {connections} | {messageSent} | {messageAckAccepted} | {messageAckCoveragePct}% | "
                "{messageDeliveryKnown} | {messageDeliveryExpected} | {messageDeliveryCoveragePct}% | {p95} | {p99} |".format(
                    artifact=row.get("artifact", "-"),
                    connections=row.get("connections", "-"),
                    messageSent=row.get("messageSent", "-"),
                    messageAckAccepted=row.get("messageAckAccepted", "-"),
                    messageAckCoveragePct=row.get("messageAckCoveragePct", "-"),
                    messageDeliveryKnown=row.get("messageDeliveryKnown", "-"),
                    messageDeliveryExpected=row.get("messageDeliveryExpected", "-"),
                    messageDeliveryCoveragePct=row.get("messageDeliveryCoveragePct", "-"),
                    p95=latency_values.get("p95", "-"),
                    p99=latency_values.get("p99", "-"),
                )
            )
    else:
        lines.append("| - | - | - | - | - | - | - | - | - | - |")

    lines += ["", "## Resource Peaks", "", "| Service | Max CPU | Max Memory |", "|---|---:|---:|"]
    if services:
        for name in sorted(services):
            sample = services[name]
            lines.append(f"| {name} | {sample['cpu']:.2f}% | {sample['memoryMiB']:.1f} MiB |")
    else:
        lines.append("| - | - | - |")
    lines.append("")
    lines.append(f"Minimum observed host available memory: `{available_min if available_min is not None else '-'} MiB`")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-dir", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    report = render(args.run_dir)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(report)
    print(f"summary_result=pass output={args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
