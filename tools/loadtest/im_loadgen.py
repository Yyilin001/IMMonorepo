#!/usr/bin/env python3
"""
IMServer capacity smoke/load generator.

The script intentionally uses only Python standard library modules so it can run
on a fresh Ubuntu host after `apt install python3`.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import random
import statistics
import time
import uuid
from dataclasses import dataclass, field
from typing import Any
from urllib import parse, request


@dataclass
class Counter:
    count: int = 0
    failures: int = 0
    latencies_ms: list[float] = field(default_factory=list)

    def record(self, latency_ms: float, failed: bool = False) -> None:
        self.count += 1
        if failed:
            self.failures += 1
        self.latencies_ms.append(latency_ms)


class Metrics:
    def __init__(self) -> None:
        self._lock = asyncio.Lock()
        self._counters: dict[str, Counter] = {}

    async def record(self, name: str, latency_ms: float, failed: bool = False) -> None:
        async with self._lock:
            self._counters.setdefault(name, Counter()).record(latency_ms, failed)

    async def snapshot(self) -> dict[str, Counter]:
        async with self._lock:
            return {
                name: Counter(counter.count, counter.failures, list(counter.latencies_ms))
                for name, counter in self._counters.items()
            }


def percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, int(round((pct / 100.0) * (len(ordered) - 1)))))
    return ordered[index]


def print_report(counters: dict[str, Counter], started_at: float) -> None:
    elapsed = max(0.001, time.monotonic() - started_at)
    print("\n=== IMServer load report ===")
    print(f"elapsed_seconds {elapsed:.1f}")
    for name, counter in sorted(counters.items()):
        latencies = counter.latencies_ms
        avg = statistics.fmean(latencies) if latencies else 0.0
        print(
            f"{name}: count={counter.count} failures={counter.failures} "
            f"rps={counter.count / elapsed:.2f} avg_ms={avg:.1f} "
            f"p95_ms={percentile(latencies, 95):.1f} p99_ms={percentile(latencies, 99):.1f} "
            f"max_ms={(max(latencies) if latencies else 0.0):.1f}"
        )


def http_json(method: str, base_url: str, path: str, token: str | None = None, body: Any = None) -> Any:
    url = base_url.rstrip("/") + "/" + path.lstrip("/")
    data = None
    headers = {"Accept": "application/json"}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = request.Request(url, data=data, headers=headers, method=method)
    with request.urlopen(req, timeout=15) as response:
        raw = response.read()
        if not raw:
            return None
        return json.loads(raw.decode("utf-8"))


async def timed_http(metrics: Metrics, name: str, fn, *args) -> Any:
    started = time.monotonic()
    try:
        result = await asyncio.to_thread(fn, *args)
        await metrics.record(name, (time.monotonic() - started) * 1000)
        return result
    except Exception:
        await metrics.record(name, (time.monotonic() - started) * 1000, failed=True)
        raise


async def login_or_register(metrics: Metrics, base_url: str, email: str, password: str) -> dict[str, Any]:
    body = {
        "email": email,
        "password": password,
        "device": {
            "deviceID": f"loadgen-{uuid.uuid4()}",
            "deviceName": "loadgen",
            "platform": "python",
            "appVersion": "loadgen",
        },
    }
    try:
        return await timed_http(metrics, "http_login", http_json, "POST", base_url, "api/auth/login", None, body)
    except Exception:
        return await timed_http(metrics, "http_register", http_json, "POST", base_url, "api/auth/register", None, body)


async def ensure_conversation(
    metrics: Metrics,
    base_url: str,
    token: str,
    peer_emails: list[str],
    title: str,
) -> str:
    body = {"kind": "group", "title": title, "memberEmails": peer_emails}
    conversation = await timed_http(
        metrics,
        "http_create_conversation",
        http_json,
        "POST",
        base_url,
        "api/im/conversations",
        token,
        body,
    )
    return str(conversation["id"])


async def fetch_conversations(metrics: Metrics, base_url: str, token: str, limit: int, kind: str | None) -> None:
    query = {"limit": str(limit)}
    if kind:
        query["kind"] = kind
    path = "api/im/conversations?" + parse.urlencode(query)
    await timed_http(metrics, "http_conversations", http_json, "GET", base_url, path, token, None)


async def fetch_messages(metrics: Metrics, base_url: str, token: str, conversation_id: str, limit: int) -> None:
    path = f"api/im/conversations/{conversation_id}/messages?" + parse.urlencode({"limit": str(limit)})
    await timed_http(metrics, "http_messages", http_json, "GET", base_url, path, token, None)


def iso8601_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


async def tcp_connect(host: str, port: int, access_token: str, user_index: int) -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
    reader, writer = await asyncio.open_connection(host, port)
    envelope = {
        "type": "auth",
        "timestamp": iso8601_now(),
        "payload": {
            "accessToken": access_token,
            "deviceID": f"loadgen-tcp-{user_index}-{uuid.uuid4()}",
            "deviceName": "loadgen",
            "platform": "python",
            "appVersion": "loadgen",
            "protocolVersion": 1,
        },
    }
    writer.write((json.dumps(envelope, separators=(",", ":")) + "\n").encode("utf-8"))
    await writer.drain()
    line = await asyncio.wait_for(reader.readline(), timeout=10)
    packet = json.loads(line.decode("utf-8"))
    if packet.get("type") != "auth_ok":
        raise RuntimeError(f"TCP auth failed: {packet}")
    return reader, writer


async def tcp_send_message(
    metrics: Metrics,
    writer: asyncio.StreamWriter,
    conversation_id: str,
    text: str,
) -> None:
    started = time.monotonic()
    envelope = {
        "type": "message",
        "requestID": str(uuid.uuid4()),
        "timestamp": iso8601_now(),
        "payload": {
            "clientMessageID": str(uuid.uuid4()),
            "messageID": None,
            "conversationID": conversation_id,
            "senderUserID": None,
            "serverSequence": None,
            "serverTimestamp": None,
            "content": {"type": "text", "text": text},
            "derivedState": {"recallState": {"active": {}}, "edits": [], "reactions": []},
        },
    }
    try:
        writer.write((json.dumps(envelope, separators=(",", ":")) + "\n").encode("utf-8"))
        await writer.drain()
        await metrics.record("tcp_messages_sent", (time.monotonic() - started) * 1000)
    except Exception:
        await metrics.record("tcp_messages_sent", (time.monotonic() - started) * 1000, failed=True)
        raise


async def user_worker(
    args: argparse.Namespace,
    metrics: Metrics,
    user_index: int,
    account: dict[str, Any],
    conversation_id: str,
    stop_at: float,
) -> None:
    token = account["accessToken"]
    reader: asyncio.StreamReader | None = None
    writer: asyncio.StreamWriter | None = None
    if args.tcp_messages_per_second > 0:
        started = time.monotonic()
        try:
            reader, writer = await tcp_connect(args.tcp_host, args.tcp_port, token, user_index)
            await metrics.record("tcp_connect", (time.monotonic() - started) * 1000)
        except Exception:
            await metrics.record("tcp_connect", (time.monotonic() - started) * 1000, failed=True)
            return

    next_message_at = time.monotonic()
    message_interval = 1.0 / args.tcp_messages_per_second if args.tcp_messages_per_second > 0 else None
    operation = 0
    while time.monotonic() < stop_at:
        operation += 1
        if operation % max(1, args.read_every) == 0:
            await fetch_conversations(metrics, args.http_base_url, token, 100, args.conversation_kind)
            if conversation_id:
                await fetch_messages(metrics, args.http_base_url, token, conversation_id, 100)

        if writer and message_interval is not None:
            now = time.monotonic()
            if now >= next_message_at:
                await tcp_send_message(metrics, writer, conversation_id, f"loadgen user-{user_index} msg-{operation}")
                next_message_at = now + message_interval

        await asyncio.sleep(args.tick_seconds)

    if writer:
        writer.close()
        await writer.wait_closed()
    _ = reader


async def main_async(args: argparse.Namespace) -> None:
    metrics = Metrics()
    started_at = time.monotonic()
    accounts = []
    password = args.password
    for index in range(args.users):
        email = args.email_template.format(index=index)
        account = await login_or_register(metrics, args.http_base_url, email, password)
        accounts.append(account)

    conversation_id = args.conversation_id
    if not conversation_id:
        peer_emails = [args.email_template.format(index=index) for index in range(1, min(args.users, args.group_size))]
        conversation_id = await ensure_conversation(
            metrics,
            args.http_base_url,
            accounts[0]["accessToken"],
            peer_emails,
            f"loadgen-{uuid.uuid4()}",
        )

    stop_at = time.monotonic() + args.duration_seconds
    tasks = [
        asyncio.create_task(user_worker(args, metrics, index, account, conversation_id, stop_at))
        for index, account in enumerate(accounts)
    ]
    try:
        await asyncio.gather(*tasks)
    finally:
        for task in tasks:
            task.cancel()
    print_report(await metrics.snapshot(), started_at)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="IMServer 100w DAU capacity validation load generator")
    parser.add_argument("--http-base-url", default="http://127.0.0.1:8080")
    parser.add_argument("--tcp-host", default="127.0.0.1")
    parser.add_argument("--tcp-port", type=int, default=9000)
    parser.add_argument("--users", type=int, default=100)
    parser.add_argument("--group-size", type=int, default=10)
    parser.add_argument("--duration-seconds", type=int, default=300)
    parser.add_argument("--email-template", default="loadgen{index}@example.com")
    parser.add_argument("--password", default="password1234")
    parser.add_argument("--conversation-id")
    parser.add_argument("--conversation-kind", choices=["group", "direct"], default=None)
    parser.add_argument("--tcp-messages-per-second", type=float, default=0.1)
    parser.add_argument("--read-every", type=int, default=20)
    parser.add_argument("--tick-seconds", type=float, default=0.05)
    return parser.parse_args()


def main() -> None:
    asyncio.run(main_async(parse_args()))


if __name__ == "__main__":
    main()
