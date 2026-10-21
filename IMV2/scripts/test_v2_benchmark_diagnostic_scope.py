import copy
import unittest

import run_v2_multiserver_capacity as campaign
from v2_benchmark_diagnostic_scope import loader_failure_guard_percent, mark_observation_only


class DiagnosticScopeTests(unittest.TestCase):
    def test_normal_and_prefill_guards_remain_strict(self):
        self.assertEqual(loader_failure_guard_percent(False), "0.1")
        self.assertEqual(loader_failure_guard_percent(True, prefill=True), "0.1")
        self.assertEqual(loader_failure_guard_percent(True), "100")

    def test_normal_assessment_is_unchanged(self):
        result = dict(passed=True, capacityComparable=True, businessFailures=0)
        before = copy.deepcopy(result)
        mark_observation_only(result, False)
        self.assertEqual(result, before)

    def test_even_clean_diagnostic_cannot_be_capacity_evidence(self):
        result = dict(measurementStarted=True, passed=True, exitCode=0,
            capacityComparable=True, remoteLifecyclePassed=True,
            messageCohort=dict(complete=True, messagesSent=100, messagesAcknowledged=100),
            businessFailures=0, missedHeartbeats=0, foreground=dict(passed=True),
            receiverVisibility=dict(passed=True),
            cleanup=dict(settled=True, forcedKillCount=0, exitFailureCount=0), failure={})
        mark_observation_only(result, True)
        self.assertFalse(result["passed"])
        self.assertFalse(result["capacityComparable"])
        self.assertTrue(result["diagnosticObservation"]["qualityChecksPassed"])
        self.assertTrue(campaign.measurement_integrity_failure(result, 0))

    def test_failures_and_incomplete_population_are_retained(self):
        result = dict(passed=False, capacityComparable=True, businessFailures=73,
            messageCohort=dict(complete=False, messagesSent=100, messagesAcknowledged=27))
        cohort = copy.deepcopy(result["messageCohort"])
        mark_observation_only(result, True)
        self.assertFalse(result["passed"])
        self.assertFalse(result["diagnosticObservation"]["qualityChecksPassed"])
        self.assertEqual(result["businessFailures"], 73)
        self.assertEqual(result["messageCohort"], cohort)


if __name__ == "__main__":
    unittest.main()
