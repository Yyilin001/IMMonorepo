import copy
import json
from pathlib import Path
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from v2_benchmark_dynamic_membership import LiveExpansion, verify_transfer_postconditions
from test_v2_live_expansion_standby import metrics


class BalanceExecutionTests(unittest.TestCase):
    def test_full_plan_uses_receipts_and_blocks_finalization_on_retained_owner_change(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for i in range(4):
                folder = root/f'gateway-{i}'
                folder.mkdir()
                (folder/'configuration.json').write_text(json.dumps(dict(hostID=f'H{i}')))
            state = dict(revision=10, shardID='rooms', hosts=[dict(identity=dict(hostID=f'H{i}', incarnationID=f'I{i}'), retired=False) for i in range(4)],
                         partitions=[dict(partition=i, owner=dict(hostID=f'H{i//4}', incarnationID=f'I{i//4}'),
                                          epoch=1, retired=False, transfer=None) for i in range(8)])
            expansion = LiveExpansion.__new__(LiveExpansion)
            expansion.args = SimpleNamespace(live_scale_out_at=1, live_scale_out_rebalance=True)
            expansion.initial_count, expansion.target_count = 2, 4
            expansion.initial_revision, expansion.joint_revision, expansion.final_revision = 3, 4, 5
            expansion.new_indices = (2, 3)
            expansion.directory = expansion.expanded = expansion.actors = root
            expansion.configuration = dict(placementControl=dict(clusterID='DEPLOY'))
            expansion.done, expansion.phase, expansion.consecutive = False, 'joint-convergence', 2
            expansion.deadline = time.monotonic()+60
            expansion.transferred = []
            expansion.joint = {}
            expansion.record = lambda *args, **kwargs: None
            submitted = []
            inspections = []
            def inspect(label):
                inspections.append(label)
                return copy.deepcopy(state)
            expansion.controller = SimpleNamespace(binary=root/'binary',
                inspect=inspect,
                prepare=lambda *args: root/'final.json',
                submit=lambda path, label: submitted.append(label))
            receipts = []
            def invoke(arguments, label):
                command = json.loads(Path(arguments[1]).read_text())
                slot = state['partitions'][command['partition']]
                self.assertEqual(slot['epoch'], command['expectedEpoch'])
                self.assertEqual(slot['owner']['hostID'], command['expectedHost']['hostID']['rawValue'])
                slot['owner'] = dict(hostID=command['successor']['hostID']['rawValue'],
                                     incarnationID=command['successor']['incarnationID'])
                slot['epoch'] += 1
                state['revision'] += 1
                receipts.append(command)
                return json.dumps(dict(status='completed', command=command))
            with patch('v2_benchmark_remote_process.gateway_metrics', return_value=metrics(1, 10, 4, 4)), \
                 patch('v2_benchmark_dynamic_membership.MembershipController', return_value=SimpleNamespace(invoke=invoke)):
                expansion.step(time.time()-10, lambda *_: None)
                self.assertEqual(expansion.pending, [2, 3, 6, 7])
                # A stale planning epoch must fail before any transfer is sent.
                state['partitions'][2]['epoch'] = 2
                with self.assertRaisesRegex(RuntimeError, 'ownership changed'):
                    expansion.step(time.time()-10, lambda *_: None)
                self.assertEqual(receipts, [])
                state['partitions'][2]['epoch'] = 1
                for _ in range(4): expansion.step(time.time()-10, lambda *_: None)
                self.assertEqual(len(receipts), 4)
                self.assertEqual(expansion.transferred, [2, 3, 6, 7])
                # A completed receipt cannot hide a later epoch or incarnation change.
                state['partitions'][7]['epoch'] += 1
                with self.assertRaisesRegex(RuntimeError, 'postcondition'):
                    expansion.step(time.time()-10, lambda *_: None)
                self.assertEqual(submitted, [])
                state['partitions'][7]['epoch'] -= 1
                self.assertFalse(any(label.endswith('-after') for label in inspections))
                self.assertEqual(len([label for label in inspections
                    if label.startswith('transfer-') and label.endswith('-inspection')]), 5)
                # All moved partitions are correct; retained ownership must also be checked.
                state['partitions'][0]['owner']['hostID'] = 'H1'
                with self.assertRaisesRegex(ValueError, 'full plan'):
                    expansion.step(time.time()-10, lambda *_: None)
                self.assertEqual(submitted, [])
                state['partitions'][0]['owner']['hostID'] = 'H0'
                expansion.step(time.time()-10, lambda *_: None)
                self.assertEqual(submitted, ['membership-final-receipt'])
                self.assertEqual(expansion.phase, 'final-convergence')




class TransferPostconditionTests(unittest.TestCase):
    def test_exact_owner_epoch_and_stable_state_are_required(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            command = dict(shardID='rooms', expectedEpoch=4,
                successor=dict(hostID=dict(rawValue='H2'), incarnationID='I2'))
            (root/'transfer-2-request.json').write_text(json.dumps(command))
            state = dict(shardID='rooms', partitions=[dict(partition=2,
                owner=dict(hostID='H2', incarnationID='I2'), epoch=5, retired=False, transfer=None)])
            verify_transfer_postconditions(state, root, [2])
            for changes in [dict(owner=dict(hostID='H3', incarnationID='I2')),
                            dict(owner=dict(hostID='H2', incarnationID='I3')),
                            dict(epoch=6), dict(retired=True), dict(transfer=dict(id='pending'))]:
                with self.subTest(changes=changes):
                    altered = copy.deepcopy(state)
                    altered['partitions'][0].update(changes)
                    with self.assertRaisesRegex(RuntimeError, 'postcondition'):
                        verify_transfer_postconditions(altered, root, [2])
            altered = copy.deepcopy(state)
            altered['shardID'] = 'another-room-shard'
            with self.assertRaisesRegex(RuntimeError, 'postcondition'):
                verify_transfer_postconditions(altered, root, [2])

if __name__ == '__main__': unittest.main()
