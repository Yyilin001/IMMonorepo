#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import json
import os
import struct
import time
import uuid
from collections import Counter


def write_varint(value: int) -> bytes:
    out = bytearray()
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def write_field_varint(field: int, value: int) -> bytes:
    return write_varint(field << 3) + write_varint(value)


def write_field_bytes(field: int, value: bytes) -> bytes:
    return write_varint((field << 3) | 2) + write_varint(len(value)) + value


def write_field_string(field: int, value: str) -> bytes:
    return write_field_bytes(field, value.encode())


def make_packet_base(protocol_version: int, request_id: str) -> bytes:
    now_ms = int(time.time() * 1000)
    return (
        write_field_string(1, request_id)
        + write_field_varint(2, now_ms)
        + write_field_varint(3, protocol_version)
    )


def frame(packet: bytes) -> bytes:
    return struct.pack(">I", len(packet)) + packet


def auth_frame(record: dict, protocol_version: int) -> bytes:
    auth = (
        write_field_string(1, record["accessToken"])
        + write_field_string(2, record.get("deviceID") or "")
        + write_field_string(3, record.get("deviceName") or record.get("deviceID") or "")
        + write_field_string(4, "ios")
        + write_field_string(5, "load")
    )
    packet = make_packet_base(protocol_version, str(uuid.uuid4()))
    packet += write_field_bytes(10, auth)
    return frame(packet)


def heartbeat_frame(sequence: int, protocol_version: int) -> bytes:
    heartbeat = write_field_varint(1, sequence)
    packet = make_packet_base(protocol_version, str(uuid.uuid4()))
    packet += write_field_bytes(20, heartbeat)
    return frame(packet)


def conversation_activity_frame(conversation_id: str, is_active: bool, protocol_version: int) -> bytes:
    activity = write_field_string(1, conversation_id) + write_field_varint(2, 1 if is_active else 0)
    packet = make_packet_base(protocol_version, str(uuid.uuid4()))
    packet += write_field_bytes(60, activity)
    return frame(packet)


def message_frame(conversation_id: str, client_message_id: str, text: str, protocol_version: int) -> bytes:
    text_content = write_field_string(1, text)
    content = write_field_bytes(1, text_content)
    message = (
        write_field_string(1, client_message_id)
        + write_field_string(3, conversation_id)
        + write_field_bytes(7, content)
        + write_field_bytes(8, b"")
    )
    packet = make_packet_base(protocol_version, str(uuid.uuid4()))
    packet += write_field_bytes(30, message)
    return frame(packet)


def read_varint(data: bytes, offset: int) -> tuple[int | None, int]:
    shift = 0
    value = 0
    while offset < len(data):
        byte = data[offset]
        offset += 1
        value |= (byte & 0x7F) << shift
        if byte < 0x80:
            return value, offset
        shift += 7
        if shift > 63:
            return None, offset
    return None, offset


def packet_type(packet: bytes) -> str | None:
    offset = 0
    while offset < len(packet):
        key, offset = read_varint(packet, offset)
        if key is None:
            return None
        field = key >> 3
        wire_type = key & 0x7
        if field == 11:
            return "auth_ok"
        if field == 12:
            return "auth_error"
        if field == 21:
            return "heartbeat_ack"
        if field == 30:
            return "message"
        if field == 31:
            return "ack"
        if field == 40:
            return "message"
        if field == 50:
            return "kick"
        if wire_type == 0:
            _, offset = read_varint(packet, offset)
        elif wire_type == 2:
            length, offset = read_varint(packet, offset)
            if length is None:
                return None
            offset += length
        else:
            return None
    return None


class JsonlLogger:
    def __init__(self, path: str | None):
        self.started = time.monotonic()
        self.file = open(path, "w") if path else None
        self.lock = asyncio.Lock()

    async def log(self, event: str, **fields):
        if not self.file:
            return
        record = {
            "event": event,
            "elapsedMs": int((time.monotonic() - self.started) * 1000),
            "timestampMs": int(time.time() * 1000),
            **fields,
        }
        async with self.lock:
            self.file.write(json.dumps(record, separators=(",", ":")) + "\n")
            self.file.flush()

    def close(self):
        if self.file:
            self.file.close()


class RunState:
    def __init__(self, target: int):
        self.target = target
        self.auth_ok = 0
        self.packet_received = 0
        self.packet_types = Counter()
        self.heartbeat_sent = 0
        self.heartbeat_ack = 0
        self.message_sent = 0
        self.message_send_error = 0
        self.message_ack = 0
        self.message_received = 0
        self.failures = Counter()
        self.auth_event = asyncio.Event()
        self.auth_condition = asyncio.Condition()
        self.lock = asyncio.Lock()

    async def record_auth_ok(self):
        async with self.auth_condition:
            self.auth_ok += 1
            if self.auth_ok >= self.target:
                self.auth_event.set()
            self.auth_condition.notify_all()

    async def wait_for_auth_count(self, count: int):
        async with self.auth_condition:
            await self.auth_condition.wait_for(lambda: self.auth_ok >= count)

    async def record_failure(self, reason: str):
        async with self.lock:
            self.failures[reason] += 1

    async def record_packet_received(self, packet_type: str):
        async with self.lock:
            self.packet_received += 1
            self.packet_types[packet_type] += 1

    async def record_heartbeat_sent(self):
        async with self.lock:
            self.heartbeat_sent += 1

    async def record_heartbeat_ack(self):
        async with self.lock:
            self.heartbeat_ack += 1

    async def record_message_sent(self):
        async with self.lock:
            self.message_sent += 1

    async def record_message_send_error(self):
        async with self.lock:
            self.message_send_error += 1

    async def record_message_ack(self):
        async with self.lock:
            self.message_ack += 1

    async def record_message_received(self):
        async with self.lock:
            self.message_received += 1

    async def snapshot(self) -> dict:
        async with self.lock:
            return {
                "target": self.target,
                "authOK": self.auth_ok,
                "packetReceived": self.packet_received,
                "packetTypes": dict(self.packet_types),
                "heartbeatSent": self.heartbeat_sent,
                "heartbeatAck": self.heartbeat_ack,
                "messageSent": self.message_sent,
                "messageSendError": self.message_send_error,
                "messageAck": self.message_ack,
                "messageReceived": self.message_received,
                "failures": dict(self.failures),
            }


async def read_frames(
    reader: asyncio.StreamReader,
    connection_index: int,
    state: RunState,
    logger: JsonlLogger,
    auth_ok_event: asyncio.Event,
    closed_event: asyncio.Event,
    log_packet_received: bool,
):
    buffer = bytearray()
    try:
        while True:
            chunk = await reader.read(65536)
            if not chunk:
                return
            buffer.extend(chunk)
            while len(buffer) >= 4:
                length = struct.unpack(">I", buffer[:4])[0]
                if len(buffer) < 4 + length:
                    break
                payload = bytes(buffer[4 : 4 + length])
                del buffer[: 4 + length]
                kind = packet_type(payload)
                await state.record_packet_received(kind or "")
                if log_packet_received:
                    await logger.log("packet_received", connectionIndex=connection_index, packetType=kind or "")
                if kind == "auth_ok":
                    await state.record_auth_ok()
                    auth_ok_event.set()
                    await logger.log("auth_ok_received", connectionIndex=connection_index)
                elif kind == "heartbeat_ack":
                    await state.record_heartbeat_ack()
                elif kind == "ack":
                    await state.record_message_ack()
                elif kind == "message":
                    await state.record_message_received()
                elif kind in ("auth_error", "kick"):
                    await state.record_failure(kind)
                    return
    finally:
        closed_event.set()


async def heartbeat_loop(
    writer: asyncio.StreamWriter,
    connection_index: int,
    protocol_version: int,
    interval_seconds: float,
    state: RunState,
    logger: JsonlLogger,
    stop_event: asyncio.Event,
    phase: str,
):
    sequence = 0
    while not stop_event.is_set():
        sequence += 1
        writer.write(heartbeat_frame(sequence, protocol_version))
        await writer.drain()
        await state.record_heartbeat_sent()
        await logger.log("heartbeat_send_ok", connectionIndex=connection_index, sequence=sequence, phase=phase)
        try:
            await asyncio.wait_for(stop_event.wait(), timeout=max(0.1, interval_seconds))
            return
        except asyncio.TimeoutError:
            pass


async def message_send_loop(
    writer: asyncio.StreamWriter,
    connection_index: int,
    protocol_version: int,
    conversation_id: str,
    rate_per_second: float,
    duration_seconds: float,
    sender_every: int,
    state: RunState,
    logger: JsonlLogger,
    stop_event: asyncio.Event,
):
    if rate_per_second <= 0 or duration_seconds <= 0 or not conversation_id:
        return
    if connection_index % max(1, sender_every) != 0:
        return

    sender_count = max(1, (state.target + max(1, sender_every) - 1) // max(1, sender_every))
    sender_ordinal = connection_index // max(1, sender_every)
    total_messages = max(1, int(rate_per_second * duration_seconds))
    started = time.monotonic()
    message_index = 0
    global_index = sender_ordinal
    while global_index < total_messages and not stop_event.is_set():
        target_at = started + (global_index / rate_per_second)
        delay = target_at - time.monotonic()
        if delay > 0:
            try:
                await asyncio.wait_for(stop_event.wait(), timeout=delay)
                return
            except asyncio.TimeoutError:
                pass
        client_message_id = f"py-tcp-{connection_index}-{message_index}-{uuid.uuid4()}"
        try:
            writer.write(
                message_frame(
                    conversation_id,
                    client_message_id,
                    f"py tcp {connection_index}/{message_index}",
                    protocol_version,
                )
            )
            await writer.drain()
            await state.record_message_sent()
            await logger.log(
                "message_send_ok",
                connectionIndex=connection_index,
                clientMessageID=client_message_id,
                globalIndex=global_index,
            )
        except Exception as error:
            await state.record_message_send_error()
            await logger.log(
                "message_send_error",
                connectionIndex=connection_index,
                clientMessageID=client_message_id,
                error=str(error),
                errorType=type(error).__name__,
            )
            return
        message_index += 1
        global_index += sender_count


async def progress_loop(
    path: str,
    interval_seconds: float,
    started: float,
    state: RunState,
    stop_event: asyncio.Event,
):
    while not stop_event.is_set():
        snapshot = await state.snapshot()
        snapshot["elapsedSeconds"] = round(time.monotonic() - started, 3)
        snapshot["timestampMs"] = int(time.time() * 1000)
        tmp_path = f"{path}.tmp"
        with open(tmp_path, "w") as file:
            json.dump(snapshot, file, separators=(",", ":"))
            file.write("\n")
        os.replace(tmp_path, path)
        try:
            await asyncio.wait_for(stop_event.wait(), timeout=max(0.5, interval_seconds))
        except asyncio.TimeoutError:
            pass


async def run_connection(index: int, record: dict, args, state: RunState, logger: JsonlLogger):
    if args.connect_ramp_seconds > 0 and args.connections > 1:
        await asyncio.sleep(args.connect_ramp_seconds * index / (args.connections - 1))

    await logger.log("connection_start", connectionIndex=index)
    reader = writer = None
    read_task = None
    heartbeat_task = None
    message_task = None
    barrier_keepalive_task = None
    stop_event = asyncio.Event()
    barrier_keepalive_stop_event = asyncio.Event()
    completed_hold = False
    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(args.tcp_host, args.tcp_port),
            timeout=args.timeout_seconds,
        )
        await logger.log("connection_ready", connectionIndex=index)
        writer.write(auth_frame(record, args.protocol_version))
        await writer.drain()
        await logger.log("auth_send_ok", connectionIndex=index)

        auth_ok_event = asyncio.Event()
        closed_event = asyncio.Event()
        read_task = asyncio.create_task(
            read_frames(
                reader,
                index,
                state,
                logger,
                auth_ok_event,
                closed_event,
                not args.suppress_packet_received_log,
            )
        )
        await asyncio.wait_for(auth_ok_event.wait(), timeout=args.timeout_seconds)
        if args.conversation_id and index < args.active_conversation_users:
            writer.write(conversation_activity_frame(args.conversation_id, True, args.protocol_version))
            await writer.drain()
            await logger.log("conversation_activity_send_ok", connectionIndex=index)
        if args.barrier_keepalive_seconds > 0:
            barrier_keepalive_task = asyncio.create_task(
                heartbeat_loop(
                    writer,
                    index,
                    args.protocol_version,
                    args.barrier_keepalive_seconds,
                    state,
                    logger,
                    barrier_keepalive_stop_event,
                    "barrier"
                )
            )

        try:
            if args.barrier_batch_size > 0:
                batch_index = index // args.barrier_batch_size
                barrier_target = min(args.connections, (batch_index + 1) * args.barrier_batch_size)
                barrier_task = asyncio.create_task(state.wait_for_auth_count(barrier_target))
            else:
                barrier_task = asyncio.create_task(state.auth_event.wait())
            closed_task = asyncio.create_task(closed_event.wait())
            done, pending = await asyncio.wait(
                {barrier_task, closed_task},
                timeout=args.connect_ramp_seconds + args.timeout_seconds,
                return_when=asyncio.FIRST_COMPLETED,
            )
            for task in pending:
                task.cancel()
            if closed_task in done and not state.auth_event.is_set():
                await state.record_failure("connection_closed_before_barrier")
                return
            if barrier_task not in done:
                await state.record_failure("global_hold_barrier_timeout")
                return
        except asyncio.TimeoutError:
            await state.record_failure("global_hold_barrier_timeout")
            return

        barrier_keepalive_stop_event.set()
        if barrier_keepalive_task is not None and not barrier_keepalive_task.done():
            barrier_keepalive_task.cancel()
        heartbeat_task = asyncio.create_task(
            heartbeat_loop(
                writer,
                index,
                args.protocol_version,
                args.heartbeat_interval_seconds,
                state,
                logger,
                stop_event,
                "hold"
            )
        )
        message_task = asyncio.create_task(
            message_send_loop(
                writer,
                index,
                args.protocol_version,
                args.conversation_id or "",
                args.message_rate_per_second,
                args.message_duration_seconds,
                args.message_sender_every,
                state,
                logger,
                stop_event,
            )
        )
        hold_task = asyncio.create_task(asyncio.sleep(args.hold_seconds))
        closed_task = asyncio.create_task(closed_event.wait())
        done, pending = await asyncio.wait({hold_task, closed_task}, return_when=asyncio.FIRST_COMPLETED)
        for task in pending:
            task.cancel()
        if closed_task in done:
            await state.record_failure("connection_closed_before_hold_complete")
            return
        completed_hold = True
        await logger.log("connection_success", connectionIndex=index)
    except Exception as error:
        if not completed_hold:
            await state.record_failure(type(error).__name__)
        await logger.log("connection_error", connectionIndex=index, error=str(error), errorType=type(error).__name__)
    finally:
        barrier_keepalive_stop_event.set()
        stop_event.set()
        if barrier_keepalive_task is not None and not barrier_keepalive_task.done():
            barrier_keepalive_task.cancel()
        if heartbeat_task is not None and not heartbeat_task.done():
            heartbeat_task.cancel()
        if message_task is not None and not message_task.done():
            message_task.cancel()
        if read_task is not None and not read_task.done():
            read_task.cancel()
        if writer is not None:
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass


def load_cache(path: str, connections: int, ttl_guard_seconds: int) -> list[dict]:
    now_ms = int(time.time() * 1000)
    records = json.load(open(path))
    if len(records) < connections:
        raise SystemExit(f"login cache has {len(records)} records, need {connections}")
    selected = records[:connections]
    min_valid_ms = min(int(record["expiresAtMs"]) - now_ms for record in selected)
    if min_valid_ms < ttl_guard_seconds * 1000:
        raise SystemExit(f"login cache expires too soon: {min_valid_ms // 1000}s")
    return selected


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tcp-host", required=True)
    parser.add_argument("--tcp-port", type=int, required=True)
    parser.add_argument("--connections", type=int, required=True)
    parser.add_argument("--connect-ramp-seconds", type=float, default=0)
    parser.add_argument("--hold-seconds", type=float, default=0)
    parser.add_argument("--timeout-seconds", type=float, default=30)
    parser.add_argument("--heartbeat-interval-seconds", type=float, default=15)
    parser.add_argument("--barrier-keepalive-seconds", type=float, default=0)
    parser.add_argument("--barrier-batch-size", type=int, default=0)
    parser.add_argument("--protocol-version", type=int, default=12)
    parser.add_argument("--login-cache-file", required=True)
    parser.add_argument("--login-cache-ttl-guard-seconds", type=int, default=60)
    parser.add_argument("--connection-log-file")
    parser.add_argument("--suppress-packet-received-log", action="store_true")
    parser.add_argument("--progress-file")
    parser.add_argument("--progress-interval-seconds", type=float, default=5)
    parser.add_argument("--conversation-id")
    parser.add_argument("--active-conversation-users", type=int, default=0)
    parser.add_argument("--message-rate-per-second", type=float, default=0)
    parser.add_argument("--message-duration-seconds", type=float, default=0)
    parser.add_argument("--message-sender-every", type=int, default=1)
    args = parser.parse_args()
    args.active_conversation_users = min(args.connections, max(0, args.active_conversation_users))
    args.message_sender_every = max(1, args.message_sender_every)

    records = load_cache(args.login_cache_file, args.connections, args.login_cache_ttl_guard_seconds)
    state = RunState(target=args.connections)
    logger = JsonlLogger(args.connection_log_file)
    started = time.monotonic()
    progress_stop_event = asyncio.Event()
    progress_task = None
    if args.progress_file:
        progress_task = asyncio.create_task(
            progress_loop(
                args.progress_file,
                args.progress_interval_seconds,
                started,
                state,
                progress_stop_event,
            )
        )
    try:
        await logger.log("run_start", connections=args.connections)
        tasks = [asyncio.create_task(run_connection(i, records[i], args, state, logger)) for i in range(args.connections)]
        await asyncio.gather(*tasks)
    finally:
        progress_stop_event.set()
        if progress_task is not None and not progress_task.done():
            progress_task.cancel()
        logger.close()

    elapsed = time.monotonic() - started
    failures = dict(state.failures)
    successes = args.connections - sum(failures.values())
    snapshot = await state.snapshot()
    print(
        "profile=linux-online "
        f"connections={args.connections} successes={successes} authOK={state.auth_ok} "
        f"elapsed={elapsed:.2f}s heartbeatSent={state.heartbeat_sent} "
        f"heartbeatAck={state.heartbeat_ack} packetReceived={snapshot['packetReceived']} "
        f"packetTypes={snapshot['packetTypes']} messageSent={state.message_sent} "
        f"messageAck={state.message_ack} messageReceived={state.message_received} "
        f"messageSendError={state.message_send_error} failures={failures}"
    )


if __name__ == "__main__":
    asyncio.run(main())
