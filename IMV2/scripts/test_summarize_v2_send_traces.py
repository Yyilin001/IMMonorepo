import json
import tempfile
import unittest
from collections import Counter, defaultdict
from pathlib import Path

from summarize_v2_send_traces import collect_room_queue, collect_send_path, stage_summary


def span(name, start, duration):
    return {"stage": name, "startMilliseconds": start, "durationMilliseconds": duration}


def queue_spans():
    return [
        span("room_queue_wait", -60, 60),
        span("room_queue_before_consumer_request", -60, 0),
        span("room_consumer_start_wait", -60, 0),
        span("room_queue_after_consumer_start", -60, 60),
    ]


class SendPathSummaryTests(unittest.TestCase):
    def test_matched_boundaries_and_ambiguous_calls(self):
        marks = [span(name, t, 0) for name, t in (
            ("directory_cached_dispatch", 1), ("peer_cached_enter", 11), ("rpc_dispatch_task_enter", 15),
            ("rpc_remote_return", 50), ("rpc_dispatch_settle", 51), ("rpc_waiter_resumed", 59),
            ("gateway_send_return", 62))]
        ack = span("result_ready_to_ack_write", 63, 4)
        for spans, core, expected in ((marks + [ack], 30, "matched"), (marks, 30, "missingBoundary"),
                                     (marks + [ack, ack], 30, "duplicateBoundary"),
                                     (marks + [ack], 40, "inconsistentBoundary")):
            with self.subTest(expected=expected):
                counts, groups = Counter(), defaultdict(list)
                collect_send_path({"spans": spans, "durationMilliseconds": 70},
                                  {"durationMilliseconds": core}, counts, groups)
                self.assertEqual(counts, {expected: 1})
                if expected == "matched":
                    self.assertEqual(groups, {"peerEntryQueue": [10], "coreExecution": [30],
                        "rpcReturnToPeerResume": [9], "rpcSettleToPeerResume": [8],
                        "rpcReturnToGatewayHandler": [12],
                        "ackWrite": [4], "rpcOutsideCore": [5], "gatewayTotal": [70]})
                else:
                    self.assertEqual(groups, {})


class RoomQueueSummaryTests(unittest.TestCase):
    def test_grouped_send_without_individual_write_span_still_measures_room_queue(self):
        def record(segment, spans):
            return {"operations": ["op"], "startedAtUnixMilliseconds": 1000,
                    "durationMilliseconds": 80, "segment": segment, "spans": spans}

        records = [
            record("gateway", [span("rpc_transport_dispatch", 0, 0), span("rpc_transport_return", 80, 0)]),
            record("room_rpc", []), record("room_actor", queue_spans()),
        ]
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "send.log"
            log.write_text("".join("send_path=" + json.dumps(row) + "\n" for row in records))
            phase = {"name": "send", "startTime": 1, "endTime": 2}
            result = stage_summary(log, [phase])["send"]
            self.assertEqual(result["counts"]["missingWriteFuture"], 1)
            self.assertEqual(result["milliseconds"], {})
            queue = result["roomQueue"]
            self.assertEqual(queue["counts"],
                             {"matched": 1, "atLeast50ms": 1, "atLeast50msEntirelyAfterConsumerStart": 1})
            self.assertEqual(queue["milliseconds"]["room_queue_wait"]["p99"], 60)
            with log.open("a") as out:
                out.write("send_path=" + json.dumps(records[0]) + "\n")
            self.assertEqual(stage_summary(log, [phase])["send"]["roomQueue"]["milliseconds"], {})

    def test_invalid_queue_partition_is_excluded(self):
        spans = queue_spans()
        for invalid, reason in (
            (spans[:-1], "missingBoundary"),
            (spans + [spans[-1]], "duplicateBoundary"),
            (spans[:-1] + [span("room_queue_after_consumer_start", -59, 60)], "inconsistentBoundary"),
        ):
            with self.subTest(reason=reason):
                counts, durations = Counter(), defaultdict(list)
                collect_room_queue(invalid, counts, durations)
                self.assertEqual(counts, {reason: 1})
                self.assertEqual(durations, {})

    def test_slow_send_with_startup_wait_is_counted_separately(self):
        spans = queue_spans()
        spans[2:] = [span("room_consumer_start_wait", -60, 20),
                     span("room_queue_after_consumer_start", -40, 40)]
        counts, durations = Counter(), defaultdict(list)
        collect_room_queue(spans, counts, durations)
        self.assertEqual(counts, {"matched": 1, "atLeast50ms": 1})
        self.assertEqual(durations["room_queue_after_consumer_start"], [40])


if __name__ == "__main__":
    unittest.main()
