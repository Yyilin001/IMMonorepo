import unittest
from v2_benchmark_space_guard import evaluate_space, GIB


class SpaceGuardTests(unittest.TestCase):
    def test_host_and_guest_limits_are_independent(self):
        self.assertTrue(evaluate_space(8*GIB,2*GIB)['passed'])
        self.assertEqual(evaluate_space(7*GIB,20*GIB)['reasons'],['host_disk_reserve'])
        self.assertEqual(evaluate_space(30*GIB,GIB)['reasons'],['postgres_disk_reserve'])
        self.assertEqual(len(evaluate_space(GIB,GIB)['reasons']),2)
    def test_unknown_observation_is_not_zero_or_a_passing_sample(self):
        with self.assertRaises(ValueError): evaluate_space(-1,10*GIB)


if __name__ == '__main__':
    unittest.main()
