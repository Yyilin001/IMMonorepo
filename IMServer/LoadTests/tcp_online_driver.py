#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import struct
import time
import uuid
from collections import Counter


CLIENT_MESSAGE_ID_PATTERN = re.compile(rb"py-tcp-[0-9]+-[0-9]+-[0-9a-f-]{36}")


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


def message_frame(
    conversation_id: str, client_message_id: str, text: str, protocol_version: int
) -> tuple[bytes, str]:
    text_content = write_field_string(1, text)
    content = write_field_bytes(1, text_content)
    message = (
        write_field_string(1, client_message_id)
        + write_field_string(3, conversation_id)
        + write_field_bytes(7, content)
        + write_field_bytes(8, b"")
    )
    request_id = str(uuid.uuid4())
    packet = make_packet_base(protocol_version, request_id)
    packet += write_field_bytes(30, message)
    return frame(packet), request_id


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


def domain_event_type(event: bytes) -> str:
    for field in protobuf_bytes_fields(event, 35):
        if protobuf_string_fields(field, 1):
            return "activity_hint"
    return "message"


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
            events = protobuf_bytes_fields(packet, 40)
            return domain_event_type(events[0]) if events else "message"
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


def protobuf_bytes_fields(packet: bytes, target_field: int) -> list[bytes]:
    values = []
    offset = 0
    while offset < len(packet):
        key, offset = read_varint(packet, offset)
        if key is None:
            return values
        field = key >> 3
        wire_type = key & 0x7
        if wire_type == 0:
            _, offset = read_varint(packet, offset)
        elif wire_type == 2:
            length, offset = read_varint(packet, offset)
            if length is None or offset + length > len(packet):
                return values
            value = packet[offset : offset + length]
            offset += length
            if field == target_field:
                values.append(value)
        else:
            return values
    return values


def protobuf_string_fields(packet: bytes, target_field: int) -> list[str]:
    values = []
    for value in protobuf_bytes_fields(packet, target_field):
        try:
            values.append(value.decode("utf-8"))
        except UnicodeDecodeError:
            continue
    return values


def packet_request_id(packet: bytes) -> str | None:
    values = protobuf_string_fields(packet, 1)
    return values[0] if values else None


def acknowledgements(packet: bytes) -> list[dict]:
    request_id = packet_request_id(packet)
    values = []
    for acknowledgement in protobuf_bytes_fields(packet, 31):
        statuses = protobuf_string_fields(acknowledgement, 3)
        message_ids = protobuf_string_fields(acknowledgement, 1)
        values.append(
            {
                "requestID": request_id,
                "messageID": message_ids[0] if message_ids else None,
                "status": statuses[0] if statuses else "missing_status",
            }
        )
    return values


def activity_hint_message_ids(packet: bytes) -> list[str]:
    message_ids = []
    for event in protobuf_bytes_fields(packet, 40):
        for hint in protobuf_bytes_fields(event, 35):
            message_ids.extend(protobuf_string_fields(hint, 1))
    return message_ids


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


class LatencyHistogram:
    """Bounded-memory latency distribution with 1 ms percentile precision."""

    def __init__(self, max_bucket_ms: int = 60_000):
        self.max_bucket_ms = max_bucket_ms
        self.buckets = [0] * (max_bucket_ms + 1)
        self.count = 0
        self.max_latency_ms = 0.0
        self.overflow_count = 0

    def record(self, latency_ms: float) -> None:
        self.count += 1
        self.max_latency_ms = max(self.max_latency_ms, latency_ms)
        bucket = max(0, int(latency_ms))
        if bucket > self.max_bucket_ms:
            self.overflow_count += 1
            bucket = self.max_bucket_ms
        self.buckets[bucket] += 1

    def summary(self) -> dict:
        if self.count == 0:
            return {"count": 0, "p50": None, "p95": None, "p99": None, "max": None}

        def percentile(percent: float) -> int:
            target = int((self.count - 1) * percent) + 1
            observed = 0
            for latency_ms, bucket_count in enumerate(self.buckets):
                observed += bucket_count
                if observed >= target:
                    return latency_ms
            return self.max_bucket_ms

        return {
            "count": self.count,
            "p50": percentile(0.50),
            "p95": percentile(0.95),
            "p99": percentile(0.99),
            "max": round(self.max_latency_ms, 3),
            "precisionMs": 1,
            "overflowCount": self.overflow_count,
        }


class RunState:
    def __init__(self, target: int, barrier_target: int, expected_message_senders: int):
        self.target = target
        self.barrier_target = barrier_target
        self.expected_message_senders = expected_message_senders
        self.auth_ok = 0
        self.packet_received = 0
        self.packet_types = Counter()
        self.heartbeat_sent = 0
        self.heartbeat_ack = 0
        self.message_sent = 0
        self.message_send_error = 0
        self.message_ack = 0
        self.message_ack_statuses = Counter()
        self.message_received = 0
        self.activity_hints_received = 0
        self.message_delivery_known = 0
        self.message_delivery_unknown = 0
        self.message_delivery_duplicate = 0
        self.message_delivery_latency = LatencyHistogram()
        self.message_sent_at = {}
        self.client_message_ids_by_request_id = {}
        self.client_message_ids_by_server_message_id = {}
        # A set of (connection, message) tuples grows with every delivery and
        # exhausts a load generator during a 10,000-member fanout run. A bitmap
        # per sent message keeps exact duplicate detection at one bit/connection.
        self.message_delivery_recipient_bitmaps: dict[str, bytearray] = {}
        self.message_delivery_bitmap_bytes = (target + 7) // 8
        self.message_senders_finished = 0
        self.failures = Counter()
        self.auth_event = asyncio.Event()
        self.message_phase_event = asyncio.Event()
        self.auth_condition = asyncio.Condition()
        self.lock = asyncio.Lock()

    async def record_auth_ok(self):
        async with self.auth_condition:
            self.auth_ok += 1
            if self.auth_ok >= self.barrier_target:
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

    async def record_message_sent(self, client_message_id: str, request_id: str):
        async with self.lock:
            self.message_sent += 1
            self.message_sent_at[client_message_id] = time.monotonic()
            self.client_message_ids_by_request_id[request_id.lower()] = client_message_id

    async def record_message_send_error(self):
        async with self.lock:
            self.message_send_error += 1

    async def record_message_ack(self, acknowledgement_items: list[dict]):
        async with self.lock:
            self.message_ack += len(acknowledgement_items)
            for item in acknowledgement_items:
                status = item["status"]
                self.message_ack_statuses[status] += 1
                request_id = item.get("requestID")
                message_id = item.get("messageID")
                client_message_id = self.client_message_ids_by_request_id.get((request_id or "").lower())
                if client_message_id and message_id:
                    self.client_message_ids_by_server_message_id[message_id.lower()] = client_message_id

    async def record_message_received(self, connection_index: int, client_message_ids: list[str]):
        async with self.lock:
            self.message_received += 1
            if not client_message_ids:
                self.message_delivery_unknown += 1
                return
            received_at = time.monotonic()
            for client_message_id in client_message_ids:
                sent_at = self.message_sent_at.get(client_message_id)
                if sent_at is None:
                    self.message_delivery_unknown += 1
                    continue
                if not self.record_unique_delivery(client_message_id, connection_index):
                    self.message_delivery_duplicate += 1
                    continue
                self.message_delivery_known += 1
                self.message_delivery_latency.record((received_at - sent_at) * 1000)

    async def record_activity_hints(self, connection_index: int, message_ids: list[str]):
        async with self.lock:
            self.activity_hints_received += len(message_ids)
            received_at = time.monotonic()
            for message_id in message_ids:
                client_message_id = self.client_message_ids_by_server_message_id.get(message_id.lower())
                if client_message_id is None:
                    self.message_delivery_unknown += 1
                    continue
                sent_at = self.message_sent_at.get(client_message_id)
                if sent_at is None:
                    self.message_delivery_unknown += 1
                    continue
                if not self.record_unique_delivery(client_message_id, connection_index):
                    self.message_delivery_duplicate += 1
                    continue
                self.message_delivery_known += 1
                self.message_delivery_latency.record((received_at - sent_at) * 1000)

    def record_unique_delivery(self, client_message_id: str, connection_index: int) -> bool:
        bitmap = self.message_delivery_recipient_bitmaps.get(client_message_id)
        if bitmap is None:
            bitmap = bytearray(self.message_delivery_bitmap_bytes)
            self.message_delivery_recipient_bitmaps[client_message_id] = bitmap
        byte_index, bit_index = divmod(connection_index, 8)
        bit_mask = 1 << bit_index
        if bitmap[byte_index] & bit_mask:
            return False
        bitmap[byte_index] |= bit_mask
        return True

    async def record_message_sender_finished(self):
        async with self.lock:
            self.message_senders_finished += 1
            if self.message_senders_finished >= self.expected_message_senders:
                self.message_phase_event.set()

    async def snapshot(self) -> dict:
        async with self.lock:
            latency = self.message_delivery_latency.summary()
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
                "messageAckStatuses": dict(self.message_ack_statuses),
                "messageReceived": self.message_received,
                "activityHintsReceived": self.activity_hints_received,
                "messageDeliveryKnown": self.message_delivery_known,
                "messageDeliveryUnknown": self.message_delivery_unknown,
                "messageDeliveryDuplicate": self.message_delivery_duplicate,
                "messageDeliveryLatencyMs": latency,
                "messageSendersFinished": self.message_senders_finished,
                "failures": dict(self.failures),
            }


def client_message_ids_in(packet: bytes) -> list[str]:
    identifiers = []
    seen = set()
    for match in CLIENT_MESSAGE_ID_PATTERN.findall(packet):
        identifier = match.decode("ascii")
        if identifier not in seen:
            identifiers.append(identifier)
            seen.add(identifier)
    return identifiers


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
                    acknowledgement_items = acknowledgements(payload)
                    await logger.log(
                        "message_ack_received",
                        connectionIndex=connection_index,
                        acknowledgements=acknowledgement_items,
                    )
                    await state.record_message_ack(acknowledgement_items)
                elif kind == "message":
                    await state.record_message_received(connection_index, client_message_ids_in(payload))
                elif kind == "activity_hint":
                    message_ids = activity_hint_message_ids(payload)
                    await logger.log(
                        "activity_hint_received",
                        connectionIndex=connection_index,
                        messageIDs=message_ids,
                    )
                    await state.record_activity_hints(connection_index, message_ids)
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
    try:
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
                packet, request_id = message_frame(
                    conversation_id,
                    client_message_id,
                    f"py tcp {connection_index}/{message_index}",
                    protocol_version,
                )
                # Register before yielding to the socket writer so a fast ACK cannot
                # arrive before its request ID is available for hint correlation.
                await state.record_message_sent(client_message_id, request_id)
                writer.write(packet)
                await writer.drain()
                await logger.log(
                    "message_send_ok",
                    connectionIndex=connection_index,
                    clientMessageID=client_message_id,
                    requestID=request_id,
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
    finally:
        await state.record_message_sender_finished()


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


async def run_connection(
    index: int,
    record: dict,
    args,
    state: RunState,
    logger: JsonlLogger,
    barrier_deadline: float,
):
    if args.connect_ramp_seconds > 0 and args.connections > 1:
        await asyncio.sleep(args.connect_ramp_seconds * index / (args.connections - 1))

    await logger.log("connection_start", connectionIndex=index)
    reader = writer = None
    read_task = None
    heartbeat_task = None
    message_task = None
    stop_event = asyncio.Event()
    completed_hold = False
    try:
        connection_options = {}
        if args.local_bind_host:
            connection_options["local_addr"] = (args.local_bind_host, 0)
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(args.tcp_host, args.tcp_port, **connection_options),
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
        # Start the normal client heartbeat as soon as this connection is
        # authenticated. A global hold barrier may take many minutes while
        # remaining connections ramp up, so delaying this loop would either
        # cause server idle timeouts or require a second, artificial keepalive.
        heartbeat_task = asyncio.create_task(
            heartbeat_loop(
                writer,
                index,
                args.protocol_version,
                args.heartbeat_interval_seconds,
                state,
                logger,
                stop_event,
                "online"
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
            remaining_barrier_seconds = max(0.0, barrier_deadline - time.monotonic())
            done, pending = await asyncio.wait(
                {barrier_task, closed_task},
                timeout=remaining_barrier_seconds,
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
        if args.message_drain_seconds > 0 and args.message_rate_per_second > 0:
            try:
                await asyncio.wait_for(
                    state.message_phase_event.wait(),
                    timeout=args.message_duration_seconds + args.timeout_seconds,
                )
                await asyncio.sleep(args.message_drain_seconds)
            except asyncio.TimeoutError:
                await state.record_failure("message_phase_timeout")
                return
        completed_hold = True
        await logger.log("connection_success", connectionIndex=index)
    except Exception as error:
        if not completed_hold:
            await state.record_failure(type(error).__name__)
        await logger.log("connection_error", connectionIndex=index, error=str(error), errorType=type(error).__name__)
    finally:
        stop_event.set()
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


def load_cache(path: str, connections: int, ttl_guard_seconds: int, offset: int = 0) -> list[dict]:
    now_ms = int(time.time() * 1000)
    records = json.load(open(path))
    if offset < 0:
        raise SystemExit(f"login cache offset must be non-negative: {offset}")
    required_records = offset + connections
    if len(records) < required_records:
        raise SystemExit(
            f"login cache has {len(records)} records, need {required_records} "
            f"for offset={offset} connections={connections}"
        )
    selected = records[offset:required_records]
    min_valid_ms = min(int(record["expiresAtMs"]) - now_ms for record in selected)
    if min_valid_ms < ttl_guard_seconds * 1000:
        raise SystemExit(f"login cache expires too soon: {min_valid_ms // 1000}s")
    return selected


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tcp-host", required=True)
    parser.add_argument("--tcp-port", type=int, required=True)
    parser.add_argument(
        "--local-bind-host",
        help="Optional local source IPv4/IPv6 address, used to shard source-port space.",
    )
    parser.add_argument("--connections", type=int, required=True)
    parser.add_argument("--connect-ramp-seconds", type=float, default=0)
    parser.add_argument("--hold-seconds", type=float, default=0)
    parser.add_argument("--timeout-seconds", type=float, default=30)
    parser.add_argument("--heartbeat-interval-seconds", type=float, default=15)
    parser.add_argument(
        "--barrier-keepalive-seconds",
        type=float,
        default=0,
        help="Deprecated. Normal heartbeats now begin immediately after auth and continue through the barrier.",
    )
    parser.add_argument("--barrier-batch-size", type=int, default=0)
    parser.add_argument(
        "--barrier-min-auth-ratio",
        type=float,
        default=1.0,
        help="Minimum authenticated ratio required before releasing the global hold barrier.",
    )
    parser.add_argument(
        "--barrier-timeout-seconds",
        type=int,
        default=0,
        help="Absolute timeout for the global hold barrier; 0 uses connect ramp plus connection timeout.",
    )
    parser.add_argument("--protocol-version", type=int, default=12)
    parser.add_argument("--login-cache-file", required=True)
    parser.add_argument(
        "--login-cache-offset",
        type=int,
        default=0,
        help="First cached credential record for this driver process.",
    )
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
    parser.add_argument("--message-drain-seconds", type=float, default=0)
    parser.add_argument("--expected-recipients-per-message", type=int, default=0)
    parser.add_argument("--min-message-ack-rate-percent", type=float, default=0)
    parser.add_argument("--min-message-delivery-coverage-percent", type=float, default=0)
    parser.add_argument(
        "--max-message-delivery-p99-milliseconds",
        type=int,
        default=0,
        help="Fail a message run when observed realtime delivery P99 exceeds this value; 0 disables the gate.",
    )
    args = parser.parse_args()
    args.active_conversation_users = min(args.connections, max(0, args.active_conversation_users))
    args.message_sender_every = max(1, args.message_sender_every)
    args.barrier_min_auth_ratio = min(1.0, max(0.0, args.barrier_min_auth_ratio))

    records = load_cache(
        args.login_cache_file,
        args.connections,
        args.login_cache_ttl_guard_seconds,
        args.login_cache_offset,
    )
    expected_message_senders = 0
    if args.message_rate_per_second > 0 and args.message_duration_seconds > 0 and args.conversation_id:
        expected_message_senders = max(
            1,
            (args.connections + args.message_sender_every - 1) // args.message_sender_every,
        )
    barrier_target = max(1, int(args.connections * args.barrier_min_auth_ratio + 0.999999))
    state = RunState(
        target=args.connections,
        barrier_target=barrier_target,
        expected_message_senders=expected_message_senders,
    )
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
        await logger.log(
            "run_start",
            connections=args.connections,
            loginCacheOffset=args.login_cache_offset,
            barrierTarget=barrier_target,
            barrierMinAuthRatio=args.barrier_min_auth_ratio,
        )
        barrier_timeout_seconds = args.barrier_timeout_seconds
        if barrier_timeout_seconds <= 0:
            barrier_timeout_seconds = args.connect_ramp_seconds + args.timeout_seconds
        barrier_deadline = started + barrier_timeout_seconds
        tasks = [
            asyncio.create_task(run_connection(i, records[i], args, state, logger, barrier_deadline))
            for i in range(args.connections)
        ]
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
    expected_deliveries = state.message_sent * max(0, args.expected_recipients_per_message)
    accepted_acks = snapshot["messageAckStatuses"].get("accepted", 0)
    ack_coverage = (
        round(accepted_acks * 100 / state.message_sent, 4)
        if state.message_sent > 0
        else None
    )
    delivery_coverage = (
        round(state.message_delivery_known * 100 / expected_deliveries, 4)
        if expected_deliveries > 0
        else None
    )
    print(
        "profile=linux-online "
        f"connections={args.connections} successes={successes} authOK={state.auth_ok} "
        f"elapsed={elapsed:.2f}s heartbeatSent={state.heartbeat_sent} "
        f"heartbeatAck={state.heartbeat_ack} packetReceived={snapshot['packetReceived']} "
        f"packetTypes={snapshot['packetTypes']} messageSent={state.message_sent} "
        f"messageAck={state.message_ack} messageReceived={state.message_received} "
        f"messageAckStatuses={snapshot['messageAckStatuses']} "
        f"messageAckAccepted={accepted_acks} messageAckCoveragePct={ack_coverage} "
        f"activityHintsReceived={snapshot['activityHintsReceived']} "
        f"messageDeliveryKnown={state.message_delivery_known} "
        f"messageDeliveryExpected={expected_deliveries} "
        f"messageDeliveryCoveragePct={delivery_coverage} "
        f"messageDeliveryUnknown={state.message_delivery_unknown} "
        f"messageDeliveryDuplicate={state.message_delivery_duplicate} "
        f"messageDeliveryLatencyMs={snapshot['messageDeliveryLatencyMs']} "
        f"messageSendError={state.message_send_error} failures={failures}"
    )
    if state.message_sent > 0 and ack_coverage is not None and ack_coverage < args.min_message_ack_rate_percent:
        raise SystemExit(
            f"message ack coverage below threshold: actual={ack_coverage} "
            f"threshold={args.min_message_ack_rate_percent}"
        )
    if (
        expected_deliveries > 0
        and delivery_coverage is not None
        and delivery_coverage < args.min_message_delivery_coverage_percent
    ):
        raise SystemExit(
            f"message delivery coverage below threshold: actual={delivery_coverage} "
            f"threshold={args.min_message_delivery_coverage_percent}"
        )
    if state.message_sent > 0 and args.max_message_delivery_p99_milliseconds > 0:
        observed_p99 = snapshot["messageDeliveryLatencyMs"]["p99"]
        if observed_p99 is None or observed_p99 > args.max_message_delivery_p99_milliseconds:
            raise SystemExit(
                f"message delivery p99 above threshold: actual={observed_p99} "
                f"threshold={args.max_message_delivery_p99_milliseconds}"
            )


if __name__ == "__main__":
    asyncio.run(main())
