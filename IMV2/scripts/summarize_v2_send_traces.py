"""Join sampled Gateway, Room RPC and Room execution spans from a benchmark run."""

import argparse
from collections import Counter, defaultdict
import json
import math
from pathlib import Path


def percentiles(values):
    ordered = sorted(values)
    return {
        q: round(ordered[math.ceil(len(ordered) * frac) - 1], 2)
        for q, frac in (("p50", 0.5), ("p95", 0.95), ("p99", 0.99), ("max", 1))
    }


def trace_rows(log):
    decoder = json.JSONDecoder()
    with log.open() as stream:
        for line in stream:
            _, marker, payload = line.partition("send_path=")
            if marker:
                yield decoder.raw_decode(payload)[0]


def covered(intervals):
    end = -math.inf
    duration = 0.0
    for start, stop in sorted(intervals):
        duration += max(0, stop - max(start, end))
        end = max(stop, end)
    return duration


SQL_FUTURES = {"owner_begin_future", "owner_write_future", "owner_commit_future", "policy_snapshot_sql_future"}
ROOM_QUEUE_STAGES = ("room_queue_wait", "room_queue_before_consumer_request",
                     "room_consumer_start_wait", "room_queue_after_consumer_start")


def collect_room_queue(spans, counts, durations):
    """Room scheduling can be measured even when a grouped write lacks its own SQL span."""
    boundaries = {}
    for span in spans:
        name = span["stage"]
        if name in ROOM_QUEUE_STAGES:
            if name in boundaries:
                counts["duplicateBoundary"] += 1
                return
            start, duration = span["startMilliseconds"], span["durationMilliseconds"]
            if not math.isfinite(start) or not math.isfinite(duration) or duration < 0:
                counts["inconsistentBoundary"] += 1
                return
            boundaries[name] = (start, duration)
    if len(boundaries) != len(ROOM_QUEUE_STAGES):
        counts["missingBoundary"] += 1
        return
    start, total = boundaries["room_queue_wait"]
    end = start
    for name in ROOM_QUEUE_STAGES[1:]:
        segment_start, elapsed = boundaries[name]
        if not math.isclose(segment_start, end, rel_tol=0, abs_tol=0.001):
            counts["inconsistentBoundary"] += 1
            return
        end = segment_start + elapsed
    if not math.isclose(start + total, end, rel_tol=0, abs_tol=0.001):
        counts["inconsistentBoundary"] += 1
        return
    counts["matched"] += 1
    for name, (_, elapsed) in boundaries.items():
        durations[name].append(elapsed)
    if total >= 50:
        counts["atLeast50ms"] += 1
        if boundaries["room_queue_after_consumer_start"][1] == total:
            counts["atLeast50msEntirelyAfterConsumerStart"] += 1


def collect_send_path(gateway, rpc, counts, durations):
    """All differences use one process's monotonic timeline. Join the Core duration by operation."""
    boundaries = ("directory_cached_dispatch", "peer_cached_enter", "rpc_dispatch_task_enter",
                  "rpc_remote_return", "rpc_dispatch_settle", "rpc_waiter_resumed", "gateway_send_return",
                  "result_ready_to_ack_write")
    spans = {}
    for span in gateway["spans"]:
        stage = span["stage"]
        if stage in boundaries:
            if stage in spans:
                counts["duplicateBoundary"] += 1
                return
            spans[stage] = span
    if len(spans) != len(boundaries):
        counts["missingBoundary"] += 1
        return
    dispatch, enter, sent, returned, settled, resumed, handler, write = (
        spans[key]["startMilliseconds"] for key in boundaries)
    ack = spans["result_ready_to_ack_write"]["durationMilliseconds"]
    core = rpc["durationMilliseconds"]
    total = gateway["durationMilliseconds"]
    times = (dispatch, enter, sent, returned, settled, resumed, handler, write, write + ack, total)
    if (not all(math.isfinite(t) for t in (*times, core)) or dispatch < 0 or core < 0 or
            any(b < a for a, b in zip(times, times[1:])) or returned - sent + 0.001 < core):
        counts["inconsistentBoundary"] += 1
        return
    counts["matched"] += 1
    for key, value in {
        "peerEntryQueue": enter - dispatch,
        "coreExecution": core,
        "rpcReturnToPeerResume": resumed - returned,
        "rpcSettleToPeerResume": resumed - settled,
        "rpcReturnToGatewayHandler": handler - returned,
        "ackWrite": ack,
        "rpcOutsideCore": max(0, returned - sent - core),
        "gatewayTotal": total,
    }.items():
        durations[key].append(value)


def stage_summary(log, phases):
    """Use the phase of the Gateway receive timestamp. Exclude ambiguous joins from latency percentiles."""
    by_operation = defaultdict(lambda: defaultdict(list))
    for row in trace_rows(log):
        if row["segment"] in ("gateway", "room_rpc", "room_actor"):
            for op in row["operations"]:
                by_operation[op][row["segment"]].append(row)
    result = {}
    for phase in phases:
        groups = defaultdict(list)
        counts = Counter()
        path_counts = Counter()
        path_durations = defaultdict(list)
        queue_counts = Counter()
        queue_durations = defaultdict(list)
        for segments in by_operation.values():
            gateways = segments["gateway"]
            attempts = [g for g in gateways
                        if phase["startTime"] <= g["startedAtUnixMilliseconds"] / 1000 < phase["endTime"]]
            if not attempts:
                continue
            counts["sampledGateway"] += len(attempts)
            if len(gateways) != 1:
                counts["ambiguousGatewayAttempts"] += len(attempts)
                path_counts["ambiguousGatewayAttempts"] += len(attempts)
                continue
            gateway = attempts[0]
            if len(segments["room_rpc"]) == 1:
                collect_send_path(gateway, segments["room_rpc"][0], path_counts, path_durations)
            else:
                path_counts["missingOrRepeatedRPC"] += 1
            if len(segments["room_rpc"]) != 1 or len(segments["room_actor"]) != 1:
                counts["missingOrRepeatedSegment"] += 1
                continue
            rpc, actor = segments["room_rpc"][0], segments["room_actor"][0]
            collect_room_queue(actor["spans"], queue_counts, queue_durations)
            markers = defaultdict(list)
            for span in gateway["spans"]:
                markers[span["stage"]].append(span["startMilliseconds"])
            starts, ends = markers["rpc_transport_dispatch"], markers["rpc_transport_return"]
            if len(starts) != len(ends) or not ends:
                counts["missingRPCBoundary"] += 1
                continue
            transport = covered(zip(starts, ends))
            if not any(s["stage"] == "owner_write_future" for s in actor["spans"]):
                counts["missingWriteFuture"] += 1
                continue
            database = covered((s["startMilliseconds"], s["startMilliseconds"] + s["durationMilliseconds"])
                               for s in actor["spans"] if s["stage"] in SQL_FUTURES)
            core = rpc["durationMilliseconds"]
            total = gateway["durationMilliseconds"]
            values = {"gatewayLocal": total - transport, "rpcTransportResidual": transport - core,
                      "coreExcludingSQL": core - database, "postgresRoundTrips": database,
                      "coreIncludingSQL": core, "gatewayIncludingRPC": total}
            if min(values.values()) < -0.1:
                counts["inconsistentBoundary"] += 1
                continue
            counts["matched"] += 1
            for name, value in values.items():
                groups[name].append(value)
            for name in ("owner_ready_wait", "owner_write_future", "room_queue_wait", "permission_preparation",
                         "policy_snapshot_sql_future"):
                groups[name].append(sum(s["durationMilliseconds"] for s in actor["spans"] if s["stage"] == name))
        result[phase["name"]] = {
            "counts": dict(counts),
            "milliseconds": {name: percentiles(values) for name, values in groups.items()},
            "sendPath": {
                "counts": dict(path_counts),
                "milliseconds": {name: percentiles(values) for name, values in path_durations.items()},
            },
            "roomQueue": {
                "counts": dict(queue_counts),
                "milliseconds": {name: percentiles(values) for name, values in queue_durations.items()},
            },
        }
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    directory = parser.parse_args().directory
    phases = json.loads((directory / "result.json").read_text())["phases"]
    print(json.dumps(stage_summary(directory / "send-traces.log", phases), indent=2))
