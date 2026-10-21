import copy
from pathlib import Path
import tempfile
import unittest
from v2_benchmark_membership_commands import membership_command, save_command


def configuration(count):
    return dict(placementControl=dict(clusterID='00000000-0000-0000-0000-000000000001'),
                serviceMembershipShard='rooms-primary',
                realtimePeers=[dict(nodeID=f'g{i}', serviceID=f'g{i}', address=f'node{i}', port=7337)
                               for i in range(count)],
                peers=[dict(hostID=f'host{i}', serviceID=f'g{i}', address=f'node{i}', port=7337,
                            shardIDs=['rooms-primary'], maximumRooms=10000) for i in range(count)])


class MembershipCommandsTests(unittest.TestCase):
    def test_online_growth_then_removal_uses_joint_records(self):
        initial = membership_command(configuration(1), 1, target=['g0'])
        self.assertEqual(len(initial['membership']['roomPeers']), 1)
        self.assertEqual(initial['membership']['roomPeers'][0]['accessibleShardIDs'], ['rooms-primary'])
        self.assertNotIn('shardIDs', initial['membership']['roomPeers'][0])
        joint = membership_command(configuration(2), 8, initial['membership'], ['g0', 'g1'])
        self.assertEqual(joint['membership']['current'], ['g0'])
        self.assertEqual(joint['membership']['next'], ['g0', 'g1'])
        self.assertEqual(len(joint['membership']['roomPeers']), 2)
        final = membership_command(configuration(2), 12, joint['membership'])
        self.assertNotIn('next', final['membership'])
        removal = membership_command(configuration(2), 16, final['membership'], ['g1'])
        self.assertEqual(len(removal['membership']['roomPeers']), 2)
        removed = membership_command(configuration(2), 20, removal['membership'])
        self.assertEqual([p['serviceID']['rawValue'] for p in removed['membership']['roomPeers']], ['g1'])
        self.assertEqual(removed['membership']['revision'], 5)

    def test_rejects_endpoint_change_and_invalid_finalization(self):
        original = configuration(2)
        first = membership_command(original, 1, target=['g0'])['membership']
        changed = copy.deepcopy(original)
        changed['peers'][0]['maximumRooms'] += 1
        with self.assertRaises(ValueError):
            membership_command(changed, 2, first, ['g0', 'g1'])
        joint = membership_command(original, 2, first, ['g0', 'g1'])['membership']
        with self.assertRaises(ValueError):
            membership_command(original, 3, joint, ['g1'])
        with self.assertRaises(ValueError):
            membership_command(original, 0, first, ['g0', 'g1'])
        with self.assertRaises(ValueError):
            membership_command(configuration(1), 2, first, ['g0', 'g1'])

    def test_saved_retry_identity_cannot_be_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'request.json'
            command = membership_command(configuration(1), 1, target=['g0'])
            save_command(path, command)
            before = path.read_bytes()
            with self.assertRaises(FileExistsError):
                save_command(path, membership_command(configuration(1), 1, target=['g0']))
            self.assertEqual(path.read_bytes(), before)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)


if __name__ == '__main__':
    unittest.main()
