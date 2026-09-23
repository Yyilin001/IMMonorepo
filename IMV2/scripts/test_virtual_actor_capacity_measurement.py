#!/usr/bin/env python3
"""No-container checks for capacity measurement planning and counter deltas."""

import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from virtual_actor_capacity_measurement import (
    HARNESS_FILE_KEYS, MEASUREMENT_SEMANTICS_VERSION, MeasurementFailure,
    create_scenario, freeze_calibrations, parse_cgroup,
    parse_prometheus, phase_delta, supports_recovery_loader, verify_freeze,
)


ROOT = Path(__file__).resolve().parents[2]
PROTOCOL = json.loads((ROOT / "IMV2/scripts/virtual-actor-fixtures/capacity-main-v1.json").read_text())


class MeasurementTests(unittest.TestCase):
    def test_three_fixed_phases_and_unsupported_workloads(self) -> None:
        fixture = {"users": 10_000, "owners": 1, "layouts": {
            "hot": {"rooms": 1}, "same-owner": {"rooms": 800},
            "mixed": {"rooms": 800}, "cold": {"rooms": 100}}}
        for workload in ("hot", "same-owner", "mixed"):
            scenario, detail = create_scenario(ROOT, PROTOCOL, fixture, workload,
                                               10_000 if workload == "mixed" else 100, 1.0)
            self.assertEqual([(p["name"], p["durationSeconds"]) for p in scenario["phases"]],
                             [("warmup", 120), ("steady", 300), ("cooldown", 60)])
            self.assertEqual(detail["batchRecoveryQueriesCovered"], False)
            self.assertEqual(detail["loaderWorkers"], 1)
            self.assertEqual(detail["connectionsPerWorker"], 10_000 if workload == "mixed" else 100)
            self.assertEqual(detail["latencyScope"], "single-process-phase-samples")
            self.assertEqual(detail["measurementSemanticsVersion"], MEASUREMENT_SEMANTICS_VERSION)
            self.assertEqual(scenario["phases"][0]["messagesPerSecond"],
                             scenario["phases"][1]["messagesPerSecond"])
            self.assertTrue(all(scenario["phases"][2].get(name, 0) == 0 for name in
                                ("messagesPerSecond", "roomLogReadsPerSecond", "syncPullsPerSecond",
                                 "readReceiptsPerSecond", "roomSyncStateBatchesPerSecond",
                                 "roomLatestVisibleBatchesPerSecond", "reconnectPercentPerMinute")))
            if workload == "mixed":
                self.assertEqual(scenario["phases"][1]["readReceiptsPerSecond"], 20)
                self.assertEqual(scenario["phases"][1]["roomSyncStateBatchesPerSecond"], 20)
                self.assertEqual(scenario["phases"][1]["roomLatestVisibleBatchesPerSecond"], 20)
                self.assertTrue(detail["batchRecoveryQueriesRequired"])
        hot, hot_detail = create_scenario(ROOT, PROTOCOL, fixture, "hot", 100, 1.0)
        self.assertEqual(hot["phases"][1]["messagesPerSecond"], 500)
        self.assertEqual(hot["sendDispatch"], "bounded_client_queue")
        self.assertEqual(hot["maximumQueuedMessagesPerConnection"], 32)
        self.assertEqual(hot_detail["templatePath"],
                         "IMV2/scripts/virtual-actor-fixtures/capacity-hot-write-v1.json")
        with self.assertRaises(MeasurementFailure):
            create_scenario(ROOT, PROTOCOL, fixture, "cold", 100, 1)
        with self.assertRaises(MeasurementFailure):
            create_scenario(ROOT, PROTOCOL, fixture, "mixed", 5_000, 1)
        with self.assertRaises(MeasurementFailure):
            create_scenario(ROOT, PROTOCOL, fixture, "fault", 100, 1)
        fixture["layouts"]["hot"]["rooms"] = 2
        with self.assertRaises(MeasurementFailure):
            create_scenario(ROOT, PROTOCOL, fixture, "hot", 100, 1)
        fixture["owners"] = 2
        with self.assertRaises(MeasurementFailure):
            create_scenario(ROOT, PROTOCOL, fixture, "same-owner", 100, 1)

    def test_counter_arithmetic_and_reset_rejection(self) -> None:
        before = {"postgres": {"postgres": {"statsReset": "start", "statements": [
            {"key": "1:t:123", "calls": 2, "totalExecMs": 4.5, "rows": 2, "walBytes": 10}]}},
            "cgroup": {"gateway": {"cpuUsageUsec": 100, "memoryCurrentBytes": 10,
                                  "memoryPeakBytes": 20, "processRSSBytes": 7}},
            "metrics": {"im_v2_send_batches_total": 4.0, "im_v2_room_actor_active_rooms": 2.0}}
        after = {"postgres": {"postgres": {"statsReset": "start", "statements": [
            {"key": "1:t:123", "calls": 5, "totalExecMs": 9.5, "rows": 5, "walBytes": 30}]}},
            "cgroup": {"gateway": {"cpuUsageUsec": 300, "memoryCurrentBytes": 15,
                                  "memoryPeakBytes": 30, "processRSSBytes": 9}},
            "metrics": {"im_v2_send_batches_total": 7.0, "im_v2_room_actor_active_rooms": 1.0}}
        samples = [{"postgres": {}, "cgroup": {"gateway": {"memoryCurrentBytes": 24,
                                                                "processRSSBytes": 12}},
                    "metrics": {"im_v2_room_actor_active_rooms": 5.0}}]
        delta = phase_delta(before, after, samples)
        self.assertEqual(delta["sql"]["postgres"]["allStatementCalls"], 3)
        self.assertEqual(delta["containers"]["gateway"]["cpuUsageUsec"], 200)
        self.assertEqual(delta["containers"]["gateway"]["sampledPeakCgroupMemoryCurrentBytes"], 24)
        self.assertEqual(delta["containers"]["gateway"]["sampledPeakProcessRSSBytes"], 12)
        self.assertEqual(delta["metricsCounterDeltas"]["im_v2_send_batches_total"], 3)
        self.assertEqual(delta["metricsSampledMaximum"]["im_v2_room_actor_active_rooms"], 5)
        after["postgres"]["postgres"]["statsReset"] = "changed"
        with self.assertRaises(MeasurementFailure):
            phase_delta(before, after, samples)

    def test_metrics_and_cgroup_parser(self) -> None:
        self.assertEqual(parse_prometheus("# HELP x y\nx 2\ny{kind=\"a\"} 3\n"),
                         {"x": 2.0, 'y{kind="a"}': 3.0})
        self.assertEqual(parse_cgroup("usage_usec 42;user_usec 30;system_usec 12;\n20\n80\n15\n"),
                         {"cpuUsageUsec": 42, "memoryCurrentBytes": 20,
                          "memoryPeakBytes": 80, "processRSSBytes": 15})

    def test_mixed_requires_binary_with_both_native_batch_actions(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / "loader"
            binary.write_bytes(b"ELF\0room_sync_state_batches_per_second=")
            self.assertFalse(supports_recovery_loader(binary))
            binary.write_bytes(binary.read_bytes() + b"x" * (1024 * 1024) +
                               b"room_latest_visible_batches_per_second=")
            self.assertTrue(supports_recovery_loader(binary))
            self.assertFalse(supports_recovery_loader(binary, require_timeout=True))

    def test_main_calibration_freeze_precedes_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = []
            harness_files = {key: "d" * 64 for key in HARNESS_FILE_KEYS}
            for index, messages in enumerate((3000, 3050, 2950)):
                run = root / f"main-{index}"
                run.mkdir()
                steady = {"nativeLoader": {"completed": True, "workloadFailed": 0,
                                           "observedDurationSeconds": 300,
                                           "messagesAcknowledged": messages}}
                content = json.dumps(steady)
                (run / "measurement-steady.json").write_text(content)
                result = {"passed": True, "mode": "measurement", "layout": "hot",
                          "source": {"sourceSHA": PROTOCOL["mainRevision"]},
                          "harness": {"revision": "e" * 40, "trackedClean": True,
                                      "filesSHA256": harness_files},
                          "fixtureManifestSHA256": "a" * 64, "scenarioSHA256": "b" * 64,
                          "productSHA256": {"IMV2GatewayLoadGenerator": "c" * 64},
                          "measurement": {"nativeConnectionsAuthenticated": 100,
                                          "scenario": {"workload": "hot", "loaderWorkers": 1,
                                                       "connectionsPerWorker": 100,
                                                       "latencyScope": "single-process-phase-samples",
                                                       "measurementSemanticsVersion": MEASUREMENT_SEMANTICS_VERSION},
                                          "phaseFiles": {"steady": hashlib.sha256(content.encode()).hexdigest()}}}
                (run / "result.json").write_text(json.dumps(result))
                paths.append(run)
            freeze = freeze_calibrations(paths, {"messagesAcknowledgedPerSecondMinimum": 9.0})
            output = root / "freeze.json"
            output.write_text(json.dumps(freeze))
            verify_freeze(output, workload="hot", layout="hot", fixture_hash="a" * 64,
                          scenario_hash="b" * 64, loader_hash="c" * 64,
                          connections_per_worker=100, harness_revision="e" * 40,
                          harness_files=harness_files)
            self.assertEqual(freeze["loaderWorkers"], 1)
            self.assertEqual(freeze["connectionsPerWorker"], 100)
            with self.assertRaises(MeasurementFailure):
                verify_freeze(output, workload="mixed", layout="hot", fixture_hash="a" * 64,
                              scenario_hash="b" * 64, loader_hash="c" * 64,
                              connections_per_worker=100, harness_revision="e" * 40,
                              harness_files=harness_files)
            with self.assertRaises(MeasurementFailure):
                verify_freeze(output, workload="hot", layout="hot", fixture_hash="a" * 64,
                              scenario_hash="b" * 64, loader_hash="c" * 64,
                              connections_per_worker=5_000, harness_revision="e" * 40,
                              harness_files=harness_files)
            with self.assertRaises(MeasurementFailure):
                verify_freeze(output, workload="hot", layout="hot", fixture_hash="a" * 64,
                              scenario_hash="b" * 64, loader_hash="c" * 64,
                              connections_per_worker=100, harness_revision="f" * 40,
                              harness_files=harness_files)
            wrong_topology = json.loads((paths[2] / "result.json").read_text())
            wrong_topology["measurement"]["scenario"]["loaderWorkers"] = 2
            (paths[2] / "result.json").write_text(json.dumps(wrong_topology))
            with self.assertRaises(MeasurementFailure):
                freeze_calibrations(paths, {"messagesAcknowledgedPerSecondMinimum": 9.0})
            wrong_topology["measurement"]["scenario"]["loaderWorkers"] = 1
            (paths[2] / "result.json").write_text(json.dumps(wrong_topology))
            revised = json.loads((paths[2] / "measurement-steady.json").read_text())
            revised["nativeLoader"]["messagesAcknowledged"] = 2000
            content = json.dumps(revised)
            (paths[2] / "measurement-steady.json").write_text(content)
            result = json.loads((paths[2] / "result.json").read_text())
            result["measurement"]["phaseFiles"]["steady"] = hashlib.sha256(content.encode()).hexdigest()
            (paths[2] / "result.json").write_text(json.dumps(result))
            with self.assertRaises(MeasurementFailure):
                freeze_calibrations(paths, {"messagesAcknowledgedPerSecondMinimum": 9.0})


if __name__ == "__main__":
    unittest.main()
