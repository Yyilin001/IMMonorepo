#!/usr/bin/env python3
"""Reject incomplete metrics and regressions before publishing capacity gates."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from assess_v2_virtual_actor_capacity import MAIN, MeasurementFailure, assess, budgets, read_run


class AssessmentTests(unittest.TestCase):
    def test_budget_is_main_only_and_regressions_remain_visible(self):
        values = {"acceptedUnitsPerSecond": 1000, "p95Milliseconds": 10,
                  "p99Milliseconds": 20, "sqlCallsPerAcceptedUnit": 8,
                  "serverCPUSecondsPerAcceptedUnit": .0001,
                  "serverPeakRSSBytes": 100 * 1024 * 1024}
        main = {"result": {"source": {"sourceSHA": MAIN}}, "measurements": values}
        limits = budgets([main, main, main])
        self.assertEqual(limits["acceptedUnitsPerSecondMinimum"], 900)
        candidate = {"measurements": {**values, "acceptedUnitsPerSecond": 899,
                                      "p99Milliseconds": 100},
                     "actorOutstandingPeaks": {"peak_outstanding_commands": 32769}}
        failed = assess(candidate, limits)
        self.assertIn("acceptedUnitsPerSecondMinimum", failed)
        self.assertIn("p99MillisecondsMaximum", failed)
        self.assertIn("peak_outstanding_commands", failed)
        other = {**main, "result": {"source": {"sourceSHA": "a" * 40}}}
        with self.assertRaises(MeasurementFailure):
            budgets([main, main, other])
        candidate["measurements"].pop("serverPeakRSSBytes")
        with self.assertRaises(MeasurementFailure):
            assess(candidate, limits)

    def test_missing_rss_and_tampered_phase_cannot_be_zero_or_pass(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            phase = {"nativeLoader": {"completed": True, "workloadFailed": 0,
                "observedDurationSeconds": 300, "messagesAcknowledged": 30000,
                "messageLatency": {"count": 30000, "p95": 10, "p99": 20}},
                "containers": {"gateway": {"cpuUsageUsec": 30000000,
                                            "sampledPeakProcessRSSBytes": 1024},
                               "loader": {"cpuUsageUsec": 10000000,
                                          "sampledPeakProcessRSSBytes": 2048}},
                "sql": {"owner00": {"allStatementCalls": 60000}},
                "metricsCounterDeltas": {}, "metricsSampledMaximum": {}}
            phase_path = root / "measurement-steady.json"
            result = {"passed": True, "mode": "measurement", "source": {"sourceSHA": MAIN},
                      "formalSamplingEligible": True,
                      "measurement": {"scenario": {"workload": "hot"}, "phaseFiles": {}}}

            def save():
                phase_path.write_text(json.dumps(phase))
                result["measurement"]["phaseFiles"]["steady"] = hashlib.sha256(phase_path.read_bytes()).hexdigest()
                (root / "result.json").write_text(json.dumps(result))

            save()
            self.assertEqual(read_run(root)["measurements"]["acceptedUnitsPerSecond"], 100)
            self.assertIsNone(read_run(root)["meanPhysicalSendBatchSize"])
            result["formalSamplingEligible"] = False
            save()
            with self.assertRaises(MeasurementFailure):
                read_run(root)
            result["formalSamplingEligible"] = True
            save()
            phase_path.write_text(phase_path.read_text() + " ")
            with self.assertRaises(MeasurementFailure):
                read_run(root)
            phase["containers"]["gateway"].pop("sampledPeakProcessRSSBytes")
            save()
            with self.assertRaises(MeasurementFailure):
                read_run(root)


if __name__ == "__main__":
    unittest.main()
