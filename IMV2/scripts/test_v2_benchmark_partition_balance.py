import copy
import unittest
from v2_benchmark_partition_balance import partition_balance_plan, verify_partition_balance


def slots(owners):
    return [dict(partition=i, owner=dict(hostID=h), epoch=1, retired=False, transfer=None)
            for i, h in enumerate(owners)]


def apply_plan(rows, plan):
    result = copy.deepcopy(rows)
    for move in plan['moves']:
        result[move['partition']]['owner']['hostID'] = move['targetHost']
        result[move['partition']]['epoch'] += 1
    return result


class PartitionBalanceTests(unittest.TestCase):
    def test_continuous_doubling_moves_half_and_preserves_old_hosts(self):
        rows = slots(['g0'] * 256)
        for count in (2, 4, 8):
            plan = partition_balance_plan(rows, [f'g{i}' for i in range(count)])
            self.assertEqual(len(plan['moves']), 128)
            rows = apply_plan(rows, plan)
            self.assertEqual(verify_partition_balance(rows, plan),
                             {f'g{i}': 256 // count for i in range(count)})
            self.assertEqual(partition_balance_plan(rows, [f'g{i}' for i in range(count)])['moves'], [])

    def test_repairs_observed_251_1_2_2_skew(self):
        rows = slots(['g0'] * 251 + ['g1'] + ['g2'] * 2 + ['g3'] * 2)
        plan = partition_balance_plan(rows, [f'g{i}' for i in range(8)])
        self.assertEqual(len(plan['moves']), 219)
        self.assertEqual(verify_partition_balance(apply_plan(rows, plan), plan),
                         {f'g{i}': 32 for i in range(8)})
        with self.assertRaises(ValueError):
            verify_partition_balance(rows, plan)

    def test_verification_rejects_partial_and_wrong_assignment_even_if_counts_match(self):
        rows = slots(['g0'] * 5)
        plan = partition_balance_plan(rows, ['g0', 'g1'])
        final = apply_plan(rows, plan)
        self.assertEqual(verify_partition_balance(final, plan), {'g0': 3, 'g1': 2})
        final[0]['owner'], final[4]['owner'] = final[4]['owner'], final[0]['owner']
        with self.assertRaises(ValueError): verify_partition_balance(final, plan)
        with self.assertRaises(ValueError): verify_partition_balance(rows[:-1], plan)

    def test_rejects_incomplete_or_unstable_inspections(self):
        rows = slots(['g0'] * 4)
        for changed in [rows[1:], rows + [rows[0]], [dict(rows[0], transfer={'id': 'pending'})] + rows[1:],
                        [dict(rows[0], retired=True)] + rows[1:]]:
            with self.assertRaises(ValueError): partition_balance_plan(changed, ['g0', 'g1'])
        with self.assertRaises(ValueError): partition_balance_plan(rows, ['g0', 'G0'])


if __name__ == '__main__': unittest.main()
