import json
from pathlib import Path
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from v2_benchmark_dynamic_membership import LiveExpansion, stable_expansion_revision


def metrics(qualified, active, hosts=1, revision=1):
    fields = dict(revision=revision, confirmed=1, configured_hosts=hosts, healthy_hosts=hosts,
                  realtime_revision=revision, realtime_qualified=qualified)
    return '\n'.join([f'im_v2_room_membership_{k} {v}' for k, v in fields.items()] +
                     [f'im_v2_room_actor_active_rooms {active}'])


class StandbyGateTests(unittest.TestCase):
    def test_only_confirmed_nonserving_candidates_can_trigger_joint_commit(self):
        for count, revision in ((1, 1), (2, 3), (4, 5)):
            with self.subTest(initial=count, revision=revision):
                self.check_standby_gate(count, revision)

    def check_standby_gate(self, count, revision):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root/'membership-initial-receipt.json').write_text(json.dumps(dict(membership=dict(revision=revision,current=[f'gateway-{i}' for i in range(count)]))))
            expansion = LiveExpansion.__new__(LiveExpansion)
            expansion.args = SimpleNamespace(live_scale_out_at=1)
            expansion.initial_membership = None
            expansion.initial_revision, expansion.joint_revision, expansion.final_revision = revision, revision+1, revision+2
            expansion.initial_count, expansion.target_count = count, count * 2
            expansion.new_indices = tuple(range(count, count * 2))
            expansion.directory, expansion.configuration = root, {}
            expansion.done, expansion.phase, expansion.consecutive = False, 'standby-convergence', 0
            expansion.deadline = time.monotonic()+60
            calls, events = [], []
            def prepare(*args):
                calls.append('prepare')
                self.assertEqual(args[3], [f'gateway-{i}' for i in range(count * 2)])
                return root/'request.json'
            def submit(*args):
                calls.append('submit')
                return dict(membership=dict(revision=revision+1))
            expansion.controller = SimpleNamespace(prepare=prepare, submit=submit)
            expansion.record = lambda *args, **kwargs: events.append((args, kwargs))
            samples = {i: metrics(int(i < count), 10 if i < count else 0, count, revision) for i in range(count * 2)}
            candidate = count * 2 - 1
            with patch('v2_benchmark_remote_process.gateway_metrics', side_effect=lambda _, i: samples[i]):
                for invalid in [metrics(1, 0, count, revision), metrics(0, 1, count, revision), metrics(0, 0, count, revision+2), '']:
                    samples[candidate] = invalid
                    for _ in range(3):
                        expansion.step(0, lambda _: self.fail('candidate must already be started'))
                    self.assertEqual(calls, [])
                samples[candidate] = metrics(0, 0, count, revision)
                for _ in range(2):
                    expansion.step(0, lambda _: None)
                self.assertEqual(calls, [])
                samples[0] = metrics(0, 10, count, revision)
                expansion.step(0, lambda _: None)
                self.assertEqual(expansion.consecutive, 0)
                samples[0] = metrics(1, 10, count, revision)
                for _ in range(3):
                    expansion.step(0, lambda _: None)
                self.assertEqual(calls, ['prepare', 'submit'])
                self.assertEqual(expansion.phase, 'joint-convergence')
                self.assertEqual(events[0][0][0], 'standby-confirmed')


    def test_predecessor_must_be_exact_stable_membership(self):
        self.assertEqual(stable_expansion_revision(dict(revision=3,current=['gateway-0','gateway-1']),2),3)
        for record in [dict(revision=3,current=['gateway-0']),
                       dict(revision=3,current=['gateway-0','gateway-0']),
                       dict(revision=3,current=['gateway-0','gateway-1'],next=['gateway-2']),
                       dict(revision=True,current=['gateway-0','gateway-1'])]:
            with self.assertRaises(ValueError):stable_expansion_revision(record,2)

    def test_every_new_gateway_must_have_migrated_rooms(self):
        for count in (1, 2, 4):
            with self.subTest(initial=count), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                scenario = root/'scenario.json'
                scenario.write_text(json.dumps(dict(phases=[dict(name='measured', durationSeconds=1000)])))
                expansion = LiveExpansion.__new__(LiveExpansion)
                expansion.args = SimpleNamespace(live_scale_out_at=1, scenario=scenario, measurement_phase='measured')
                expansion.initial_revision, expansion.joint_revision, expansion.final_revision = 5, 6, 7
                expansion.directory = root
                expansion.initial_count, expansion.target_count = count, count*2
                expansion.new_indices = tuple(range(count, count*2))
                expansion.done, expansion.phase, expansion.consecutive = False, 'final-convergence', 2
                expansion.deadline = time.monotonic()+60
                events = []
                expansion.record = lambda *args, **kwargs: events.append((args, kwargs))
                samples = {i: metrics(1, 10, count*2, 7) for i in range(count*2)}
                samples[count*2-1] = metrics(1, 0, count*2, 7)
                with patch('v2_benchmark_remote_process.gateway_metrics', side_effect=lambda _, i: samples[i]):
                    with self.assertRaisesRegex(RuntimeError, 'no active migrated rooms'):
                        expansion.step(time.time()-10, lambda *_: None)
                    self.assertFalse(expansion.done)
                    samples[count*2-1] = metrics(1, 7, count*2, 7)
                    expansion.consecutive = 2
                    expansion.step(time.time()-10, lambda *_: None)
                    self.assertTrue(expansion.done)
                    self.assertEqual(set(events[-1][1]['newGatewayActiveRooms']), set(expansion.new_indices))
                    self.assertEqual(len(list(root.glob('expansion-complete-gateway-*.prom'))), count*2)


if __name__ == '__main__':
    unittest.main()
