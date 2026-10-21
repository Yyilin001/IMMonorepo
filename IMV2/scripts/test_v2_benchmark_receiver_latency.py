import copy
import unittest

from v2_benchmark_receiver_latency import assess_receiver_latency


class ReceiverLatencyTests(unittest.TestCase):
    def setUp(self):
        self.visibility = dict(passed=True, expectedPeerApplications=100,
            observedPeerApplications=100, sourceAcknowledged=100,
            latency=dict(count=100, p99=12, p99UpperBoundExclusiveMilliseconds=13))

    def test_complete_but_slow_delivery_fails_performance_without_changing_integrity(self):
        before = copy.deepcopy(self.visibility)
        self.assertTrue(assess_receiver_latency(self.visibility)['passed'])
        self.assertEqual(self.visibility, before)
        self.visibility['latency'].update(p99=1959, p99UpperBoundExclusiveMilliseconds=1960)
        result = assess_receiver_latency(self.visibility)
        self.assertFalse(result['passed'])
        self.assertEqual(result['reason'], 'p99_exceeds_limit')
        self.assertTrue(self.visibility['passed'])

    def test_bucket_upper_bound_controls_threshold_and_overflow_is_not_a_pass(self):
        for upper, expected in [(500, True), (501, False), (None, False),
                                (float('nan'), False), (float('inf'), False),
                                (True, False), (-1, False)]:
            with self.subTest(upper=upper):
                self.visibility['latency']['p99UpperBoundExclusiveMilliseconds'] = upper
                self.assertEqual(assess_receiver_latency(self.visibility)['passed'], expected)

    def test_partial_or_mismatched_observation_cannot_pass(self):
        for key, value in [('passed', False), ('expectedPeerApplications', 101),
                           ('observedPeerApplications', 99), ('sourceAcknowledged', 99),
                           ('latency', None)]:
            with self.subTest(key=key):
                changed = {**self.visibility, key: value}
                self.assertFalse(assess_receiver_latency(changed)['passed'])
        self.assertFalse(assess_receiver_latency({})['passed'])

    def test_invalid_limit_is_rejected(self):
        for limit in [0, -1, True, None, float('inf'), float('nan')]:
            with self.subTest(limit=limit), self.assertRaises(ValueError):
                assess_receiver_latency(self.visibility, limit)


if __name__ == '__main__':
    unittest.main()
