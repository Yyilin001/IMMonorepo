#!/usr/bin/env python3
"""No-container checks for cold retirement and owner-failure evidence."""

import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from virtual_actor_capacity_lifecycle import OwnerFailureWindow, validate_cold_retirement
from virtual_actor_capacity_measurement import (
    MeasurementFailure, create_scenario, freeze_calibrations, phase_delta, verify_freeze,
)


ROOT = Path(__file__).resolve().parents[2]
PROTOCOL = json.loads((ROOT / "IMV2/scripts/virtual-actor-fixtures/capacity-main-v1.json").read_text())


class LifecycleTests(unittest.TestCase):
    def test_cold_and_fault_are_fixed_and_distinct(self) -> None:
        fixture = {"users": 1500, "owners": 2, "targetsPerConnection": 20,
                   "layouts": {"cold": {"rooms": 7500},
                               "mixed": {"rooms": 940, "ownerRoomCounts": [470, 470]}}}
        cold, detail = create_scenario(ROOT, PROTOCOL, fixture, "cold", 1500, 1.0)
        self.assertEqual(detail["layout"], "cold")
        self.assertEqual(cold["phases"][1]["messagesPerSecond"], 20)
        self.assertEqual(cold["phases"][2]["messagesPerSecond"], 0)
        self.assertEqual(cold["schedulerTicksPerSecond"], 10)
        fault, detail = create_scenario(ROOT, PROTOCOL, fixture, "fault", 1500, 1.0)
        self.assertEqual(detail["layout"], "mixed")
        self.assertEqual(fault["phases"][1]["messagesPerSecond"], 0)
        self.assertEqual(fault["phases"][1]["roomSyncStateBatchesPerSecond"], 20)
        self.assertEqual(fault["phases"][1]["roomLatestVisibleBatchesPerSecond"], 20)
        self.assertEqual(fault["phases"][2]["roomSyncStateBatchesPerSecond"], 0)
        with self.assertRaises(MeasurementFailure):
            create_scenario(ROOT, PROTOCOL, fixture, "fault", 1500, 2.0)
        with self.assertRaises(MeasurementFailure):
            create_scenario(ROOT, PROTOCOL, fixture, "cold", 500, 1.0)

    def test_cold_requires_actual_release(self) -> None:
        before = {"owner00": {"rows": 0}, "owner01": {"rows": 0}}
        after = {"owner00": {"rows": 2, "released": 1, "reacquired": 0},
                 "owner01": {"rows": 1, "released": 0, "reacquired": 0}}
        self.assertEqual(validate_cold_retirement(before, after)["releasedRoomsAtEnd"], 1)
        after["owner00"]["released"] = 0
        with self.assertRaises(MeasurementFailure):
            validate_cold_retirement(before, after)

    def test_fault_requires_owner_progress_and_three_clean_seconds(self) -> None:
        clock = [0.0]
        commands = []
        def execute(command, log, timeout):
            commands.append((command, timeout))
            if "--quiet" in command:
                return "a" * 64
            if "inspect" in command:
                return json.dumps({"Running": False, "OOMKilled": False, "ExitCode": 0})
            return ""
        window = OwnerFailureWindow(["docker", "compose"], execute, now=lambda: clock[0])
        window.begin_steady()
        clock[0] = 60.0
        window.tick()
        self.assertEqual(commands[0][0][-4:], ["stop", "--timeout", "10", "owner00"])
        for second in range(62, 80):
            clock[0] = float(second)
            window.observe(self._progress(second, second - 60, second - 60), at=clock[0])
        clock[0] = 80.0
        window.tick()
        self.assertEqual(commands[-1][0][-2:], ["start", "owner00"])
        for second in range(81, 85):
            clock[0] = float(second)
            window.observe(self._progress(second, second - 60, 19), at=clock[0])
        result = window.finish()
        self.assertGreater(result["outageRoomResultDeltas"]["room_sync_state"]["success"], 0)
        self.assertGreater(result["outageRoomResultDeltas"]["room_latest_visible"]["retry"], 0)
        self.assertEqual(result["recoveryMilliseconds"], 4000)
        window.cleanup()
        self.assertEqual(len(commands), 4)

    def test_forced_postgres_exit_cannot_claim_preserved_counters(self) -> None:
        clock = [0.0]
        def execute(command, log, timeout):
            if "--quiet" in command:
                return "a" * 64
            if "inspect" in command:
                return json.dumps({"Running": False, "OOMKilled": False, "ExitCode": 137})
            return ""
        window = OwnerFailureWindow(["docker", "compose"], execute, now=lambda: clock[0])
        window.begin_steady()
        clock[0] = 60
        with self.assertRaises(MeasurementFailure):
            window.tick()
        window.cleanup()

    def test_failed_stop_is_tracked_for_cleanup(self) -> None:
        clock = [0.0]
        commands = []
        def execute(command, log, timeout):
            commands.append(command[-1])
            if command[-1] == "owner00" and "stop" in command:
                raise RuntimeError("stop response lost")
            return ""
        window = OwnerFailureWindow(["docker", "compose"], execute, now=lambda: clock[0])
        window.begin_steady()
        clock[0] = 60.0
        with self.assertRaises(RuntimeError):
            window.tick()
        window.cleanup()
        self.assertEqual(commands, ["owner00", "owner00"])

    @staticmethod
    def _progress(second: int, success: int, retry: int) -> str:
        return (f"scenario phase=steady second={second} active=20 "
                f"room_sync_state_success_rooms={success} room_sync_state_retry_rooms={retry} "
                f"room_latest_visible_success_rooms={success} "
                f"room_latest_visible_retry_rooms={retry}\n")

    def test_restart_cpu_is_not_subtracted_and_pg_reset_rejects(self) -> None:
        base = {"postgres": {"owner00": {"statsReset": "same", "statements": []}},
                "cgroup": {"owner00": {"cpuUsageUsec": 100, "memoryCurrentBytes": 30,
                                       "memoryPeakBytes": 40, "processRSSBytes": 20}},
                "metrics": {}}
        end = {"postgres": {"owner00": {"statsReset": "same", "statements": []}},
               "cgroup": {"owner00": {"cpuUsageUsec": 50, "memoryCurrentBytes": 10,
                                      "memoryPeakBytes": 15, "processRSSBytes": 9}},
               "metrics": {}}
        with self.assertRaises(MeasurementFailure):
            phase_delta(base, end, [])
        delta = phase_delta(base, end, [], restarted_services={"owner00"})
        self.assertIsNone(delta["containers"]["owner00"]["cpuUsageUsec"])
        self.assertIsNone(delta["containers"]["owner00"]["lifetimeCgroupMemoryPeakBytes"])
        end["postgres"]["owner00"]["statsReset"] = "changed"
        with self.assertRaises(MeasurementFailure):
            phase_delta(base, end, [], restarted_services={"owner00"})
        end["postgres"]["owner00"]["statsReset"] = "same"
        base["postgres"]["owner00"]["statements"] = [
            {"key": "before", "calls": 1, "totalExecMs": 1, "rows": 1, "walBytes": 0}]
        with self.assertRaises(MeasurementFailure):
            phase_delta(base, end, [], restarted_services={"owner00"})

    def test_fault_freeze_uses_successful_query_items(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            paths = []
            for index, items in enumerate((3000, 3050, 2950)):
                directory = Path(temporary) / f"main-{index}"
                directory.mkdir()
                steady = {"nativeLoader": {"completed": True, "workloadFailed": 0,
                           "observedDurationSeconds": 300, "messagesSent": 0,
                           "messagesAcknowledged": 0,
                           "roomSyncStateBatch": {"successfulRooms": items},
                           "roomLatestVisibleBatch": {"successfulRooms": items}}}
                content = json.dumps(steady)
                (directory / "measurement-steady.json").write_text(content)
                result = {"passed": True, "mode": "measurement", "layout": "mixed",
                          "source": {"sourceSHA": PROTOCOL["mainRevision"]},
                          "fixtureManifestSHA256": "a" * 64, "scenarioSHA256": "b" * 64,
                          "productSHA256": {"IMV2GatewayLoadGenerator": "c" * 64},
                          "measurement": {"scenario": {"workload": "fault"},
                             "phaseFiles": {"steady": hashlib.sha256(content.encode()).hexdigest()}}}
                (directory / "result.json").write_text(json.dumps(result))
                paths.append(directory)
            freeze = freeze_calibrations(paths, {"successfulRoomItemsPerSecondMinimum": 9.0})
            self.assertEqual(freeze["acceptedUnit"], "successfulRecoveryRoomItemsPerSecond")
            self.assertEqual(freeze["mainSteadyAcceptedPerSecond"][0], 20)
            output = Path(temporary) / "freeze.json"
            output.write_text(json.dumps(freeze))
            verify_freeze(output, workload="fault", layout="mixed", fixture_hash="a" * 64,
                          scenario_hash="b" * 64, loader_hash="c" * 64)


if __name__ == "__main__":
    unittest.main()
