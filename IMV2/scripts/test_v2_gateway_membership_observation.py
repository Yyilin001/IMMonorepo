import unittest
from types import SimpleNamespace
from wait_v2_gateway_membership import PREFIX, parse_observation, matches, wait


def body(revision=2, qualified=1):
    values = dict(revision=revision, confirmed=1, configured_hosts=2, healthy_hosts=2,
                  realtime_revision=revision, realtime_qualified=qualified)
    return '\n'.join(PREFIX + key + ' ' + str(value) for key, value in values.items())


class MembershipObservationTests(unittest.TestCase):
    def test_requires_both_versions_health_and_qualification(self):
        good = parse_observation(body())
        self.assertTrue(matches(good, 2, 2))
        for key in good:
            incomplete = dict(good)
            incomplete.pop(key)
            self.assertFalse(matches(incomplete, 2, 2))
        for key in ('revision', 'realtime_revision', 'confirmed', 'healthy_hosts', 'configured_hosts', 'realtime_qualified'):
            stale = dict(good, **{key: 0})
            self.assertFalse(matches(stale, 2, 2))
        retired = parse_observation(body(qualified=0))
        self.assertTrue(matches(retired, 2, 2, retired=True))
        self.assertFalse(matches(good, 2, 2, retired=True))

    def test_rejects_ambiguous_samples(self):
        for bad in [body() + '\n' + PREFIX + 'revision 2', PREFIX + 'revision NaN',
                    PREFIX + 'revision 2.0', PREFIX + 'revision{node="x"} 2', PREFIX + 'unknown 1']:
            with self.assertRaises(ValueError):
                parse_observation(bad)

    def test_requires_three_consecutive_rounds_and_times_out(self):
        clock = [0]
        args = SimpleNamespace(timeout_seconds=8, gateway=[0], retired_gateway=[1], revision=2, hosts=2)
        def fetch(_, node):
            if clock[0] == 1:
                raise TimeoutError()
            return body(qualified=1 if node == 0 else 0)
        result = wait(args, fetch=fetch, now=lambda: clock[0], sleep=lambda n: clock.__setitem__(0, clock[0]+n))
        self.assertEqual(result['status'], 'confirmed')
        self.assertEqual(result['rounds'], 5)
        clock[0] = 0
        result = wait(args, fetch=lambda *_: body(revision=1), now=lambda: clock[0],
                      sleep=lambda n: clock.__setitem__(0, clock[0]+n))
        self.assertEqual(result['status'], 'unconfirmed')
        self.assertEqual(clock[0], 8)


if __name__ == '__main__':
    unittest.main()
