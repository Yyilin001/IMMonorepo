"""Closed canary checkpoint predicates; no process, socket or database fixture."""
import copy
import json
import tempfile
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from run_v2_actor_realtime_benchmark import (
    CANDIDATE_WIRE_VERSION, preclose_witness_request, capture_preclose_witness, finish_preclose_witness, ActorPartitionCanary, PARTS, private_json, private_json_snapshot, apply_partition_fixture_cleanup, benchmark_targets_per_connection, checkpoint_connection_proof, checkpoint_heartbeat_continuity, checkpoint_response_matches_request,
    checkpoint_rebuilt_owner_rooms, room_activation_checkpoint, checkpoint_physical_continuity, partition_takeover_witness_proof, partition_observed_history_proof,
)


class ActorPartitionCheckpointTests(unittest.TestCase):
    def test_owner_recovery_requires_exact_activation_and_every_device_scope(self):
        host = 'aaaaaaaa-0000-0000-0000-000000000001'
        room = 'bbbbbbbb-0000-0000-0000-000000000001'
        old = dict(databaseNow=10, leases=[dict(roomID=room, hostID=host.upper(),
            activationEpoch=1, ownerShardID='rooms', ownerEpoch=0,
            incarnation=host, expiresAt=20)])
        new = copy.deepcopy(old)
        new['leases'][0].update(activationEpoch=2, expiresAt=30)
        before = [dict(slots=[dict(connectionIndex=i, coverage=dict(requestedScopes=[
            dict(scope='room', scopeID=room.upper(), scopeGeneration=1, revision=1)])) for i in range(2)])]
        after = copy.deepcopy(before)
        for slot in after[0]['slots']: slot['coverage']['requestedScopes'][0]['revision'] = 2
        check = lambda a, leases: checkpoint_rebuilt_owner_rooms(before, a, old, leases, host)
        self.assertTrue(check(after, new))
        unchanged = copy.deepcopy(after)
        unchanged[0]['slots'][1]['coverage']['requestedScopes'][0]['revision'] = 1
        self.assertFalse(check(unchanged, new))
        for field, value in [('activationEpoch', 1), ('ownerEpoch', 1), ('ownerShardID', 'other'),
                             ('expiresAt', 10), ('hostID', None), ('incarnation', None)]:
            invalid = copy.deepcopy(new); invalid['leases'][0][field] = value
            self.assertFalse(check(after, invalid))
        self.assertFalse(check(after, dict(databaseNow=10, leases=[])))
        self.assertFalse(checkpoint_rebuilt_owner_rooms(before, after, old, new,
            'aaaaaaaa-0000-0000-0000-000000000002'))

    def test_room_activation_checkpoint_requires_exact_owned_room_set(self):
        room = '00000000-0000-0000-0000-000000000001'
        parts = [dict(slots=[dict(coverage=dict(requestedScopes=[
            dict(scope='room', scopeID=room), dict(scope='room', scopeID=room)]))])]
        with patch('run_v2_actor_realtime_benchmark.fault_read_query',
                   return_value=json.dumps(dict(leases=[dict(roomID=room)]))) as read:
            value = room_activation_checkpoint(SimpleNamespace(), {}, parts)
            self.assertEqual(len(value['leases']), 1)
            self.assertIn('FROM im_v2.room_activation_leases', read.call_args.args[2])
        for leases in ([], [dict(roomID='00000000-0000-0000-0000-000000000002')],
                       [dict(roomID=room), dict(roomID=room)]):
            with patch('run_v2_actor_realtime_benchmark.fault_read_query',
                       return_value=json.dumps(dict(leases=leases))):
                with self.assertRaisesRegex(RuntimeError, 'checkpoint_incomplete'):
                    room_activation_checkpoint(SimpleNamespace(), {}, parts)
        with patch('run_v2_actor_realtime_benchmark.fault_read_query') as read:
            with self.assertRaisesRegex(RuntimeError, 'budget_invalid'):
                room_activation_checkpoint(SimpleNamespace(), {}, [])
            read.assert_not_called()

    def test_preclose_sampling_is_bounded_and_missing_response_is_incomplete(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            request = preclose_witness_request(directory, [4167] * PARTS)
            self.assertEqual(sum(map(len, request['selections'])), 384)
            for indices in request['selections']:
                self.assertEqual(len(set(indices)), 32)
                self.assertTrue(all(0 <= index < 4167 for index in indices))
            # No response means no PG read. A closed loader likewise prevents a
            # false after-close observed witness; original quality is untouched.
            args = SimpleNamespace()
            live = [SimpleNamespace(poll=lambda: None) for _ in range(PARTS)]
            self.assertIsNone(capture_preclose_witness(args, 'unused', directory, live, [4167]*PARTS, request))
            live[0] = SimpleNamespace(poll=lambda: 0)
            self.assertIsNone(capture_preclose_witness(args, 'unused', directory, live, [4167]*PARTS, request))
            finish_preclose_witness(directory, 'loader_exited_or_response_missing_before_capture')
            result = json.loads((directory/'preclose-recovery-witness.json').read_text())
            self.assertEqual(result['status'], 'incomplete')
            self.assertFalse(result['changesQuality'])

    def test_progress_checkpoint_rounds_and_cleanup_replace_only_snapshots(self):
        # Exercise the actual file-backed checkpoint state machine, not a mock
        # persist implementation. No Loader, socket or database is started.
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            canary = ActorPartitionCanary(SimpleNamespace(actor_partition_canary=0),
                'owned', directory, [1] * PARTS, None, {7})
            for round_index, (label, state) in enumerate([
                ('before', 'arming'), ('isolated', 'isolated'),
                ('isolated', 'isolated'), ('after', 'healing'), ('after', 'recovered')]):
                self.assertIsNone(canary.checkpoint(label))
                nonce, stamp, _ = canary.request
                for index in range(PARTS):
                    request = json.loads((directory / f'checkpoint-request-{index}.json').read_text())
                    self.assertEqual(request['nonce'], nonce)
                    private_json_snapshot(directory / f'checkpoint-response-{index}.json',
                        dict(nonce=nonce.upper(), requestedAtUnixMilliseconds=stamp,
                             samplingStartedAtUnixMilliseconds=stamp,
                             samplingCompletedAtUnixMilliseconds=stamp, round=round_index))
                parts = canary.checkpoint(label)
                self.assertEqual(len(parts), PARTS)
                self.assertIsNone(canary.request)
                self.assertEqual(json.loads((directory / f'partition-checkpoint-{label}.json').read_text())[0]['round'], round_index)
                canary.state = state
                canary.recovered = state == 'recovered'
                canary.persist()
                canary.persist() # completion/finally also rewrites the snapshot
                self.assertEqual(json.loads((directory / 'actor-partition-canary.json').read_text())['state'], state)
            result = directory / 'result.json'
            private_json(result, dict(qualityPassed=False, fixtureCleanupPending=True))
            private_json_snapshot(result, dict(qualityPassed=True, fixtureCleanupPending=False))
            self.assertTrue(json.loads(result.read_text())['qualityPassed'])
            self.assertEqual(result.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                private_json(result, dict(overwriteImmutable=True))
            self.assertTrue(json.loads(result.read_text())['qualityPassed'])
            self.assertEqual(list(directory.glob('*.snapshot.tmp')), [])

    def test_healing_release_gap_and_same_incarnation_reclaim_require_full_history(self):
        initial = dict(partitionID=7, epoch=1, token='token1', hostID='gateway-0',
            serviceID='service0', incarnation='inc0', expiresAt=200)
        def change(sequence, old, new, clock):
            value = dict(sequence=sequence,partitionID=7,fenceDatabaseAt=clock,statementAt=clock,observedAt=clock)
            for key, column in [('epoch','Epoch'),('token','Token'),('hostID','Host'),
                                ('serviceID','Service'),('incarnation','Incarnation'),('expiresAt','Expiry')]:
                value['old'+column]=old[key]; value['new'+column]=new[key]
            return value
        released1 = dict(initial,expiresAt=120)
        claimed2 = dict(initial,epoch=2,token='token2',hostID='gateway-1',serviceID='service1',incarnation='inc1',expiresAt=155)
        released2 = dict(claimed2,expiresAt=140)
        claimed3 = dict(initial,epoch=3,token='token3',expiresAt=175)
        rows = [change(1,initial,released1,120),change(2,released1,claimed2,125),
                change(3,claimed2,released2,140),change(4,released2,claimed3,145)]
        gap = partition_observed_history_proof(initial,rows,released2,phase='healing')
        self.assertEqual(gap['observedEpoch'],2) # history valid, but expiry140 is not an active final lease
        proof = partition_observed_history_proof(initial,rows,claimed3,phase='healing')
        self.assertEqual([item['newEpoch'] for item in proof['transitions']],[2,3])
        self.assertTrue(all(item['boundary']=='strict_release' for item in proof['transitions']))
        with self.assertRaisesRegex(RuntimeError,'isolated_host'):
            partition_observed_history_proof(initial,rows,claimed3,phase='isolated')
        with self.assertRaisesRegex(RuntimeError,'tuple_chain'):
            partition_observed_history_proof(initial,[rows[0],rows[1],rows[3]],claimed3,phase='healing')
        with self.assertRaisesRegex(RuntimeError,'witness_invalid'):
            partition_observed_history_proof(initial,rows[:3]+[dict(rows[3],newToken='token1')],claimed3,phase='healing')

    def test_takeover_uses_committed_exact_old_tuple_not_a_sampled_expiry_guess(self):
        initial = dict(partitionID=7, epoch=3, token='old-token', hostID='gateway-0',
                       serviceID='gateway-0', incarnation='old-incarnation', expiresAt=200)
        release = dict(sequence=8, partitionID=7, oldEpoch=3, newEpoch=3,
            oldToken='old-token', newToken='old-token', oldHost='gateway-0', newHost='gateway-0',
            oldService='gateway-0', newService='gateway-0', oldIncarnation='old-incarnation',
            newIncarnation='old-incarnation', oldExpiry=200, newExpiry=120,
            fenceDatabaseAt=120, statementAt=120, observedAt=120.001)
        claim = dict(sequence=9, partitionID=7, oldEpoch=3, newEpoch=4,
            oldToken='old-token', newToken='new-token', oldHost='gateway-0', newHost='gateway-1',
            oldService='gateway-0', newService='gateway-1', oldIncarnation='old-incarnation',
            newIncarnation='new-incarnation', oldExpiry=120, newExpiry=155,
            fenceDatabaseAt=125, statementAt=125, observedAt=125.001)
        proof = partition_takeover_witness_proof(initial, [release, claim])
        self.assertEqual(proof['boundary'], 'strict_release')
        self.assertLess(proof['claimFenceDatabaseAt'], initial['expiresAt'])
        self.assertEqual(proof['releaseSequence'], 8)
        natural = dict(claim, oldExpiry=200, fenceDatabaseAt=201, newExpiry=231,
                       statementAt=201, observedAt=201.001)
        self.assertEqual(partition_takeover_witness_proof(initial, [natural])['boundary'], 'natural_expiry')
        with self.assertRaisesRegex(RuntimeError, 'witness_invalid'):
            partition_takeover_witness_proof(initial, [dict(claim, oldExpiry=200)])
        with self.assertRaisesRegex(RuntimeError, 'witness_missing'):
            partition_takeover_witness_proof(initial, [dict(claim, oldToken='different-old-token')])

    def test_actual_swift_checkpoint_correlates_with_python_uuid(self):
        # The nonce and three timestamps are the actual r47 captured pair.
        nonce = '00cef843-d737-46df-b30e-aac5fa603a8d'
        stamp = 1790942404313
        response = dict(nonce='00CEF843-D737-46DF-B30E-AAC5FA603A8D',
            requestedAtUnixMilliseconds=stamp, samplingStartedAtUnixMilliseconds=1790942404377,
            samplingCompletedAtUnixMilliseconds=1790942404377)
        self.assertTrue(checkpoint_response_matches_request(response, nonce, stamp))
        prior = dict(response, nonce='00000000-0000-0000-0000-000000000001')
        self.assertFalse(checkpoint_response_matches_request(prior, nonce, stamp))
        for invalid in (None, '', 'not-a-uuid'):
            with self.assertRaisesRegex(RuntimeError, 'nonce_invalid'):
                checkpoint_response_matches_request(dict(response, nonce=invalid), nonce, stamp)

    def test_nonzero_actual_scope_and_post_isolation_heartbeat_are_required(self):
        product = dict(qualityPassed=True)
        apply_partition_fixture_cleanup(product, dict(passed=False, failureCode='proxy_closure_unconfirmed'))
        self.assertTrue(product['productQualityPassed'])
        self.assertFalse(product['fixtureQualified'])
        self.assertFalse(product['qualityPassed'])
        failed = dict(qualityPassed=False, failureStage='partition_prefill')
        apply_partition_fixture_cleanup(failed, dict(passed=True, failureCode=None))
        self.assertFalse(failed['qualityPassed'])
        self.assertEqual(failed['failureStage'], 'partition_prefill')
        self.assertEqual(benchmark_targets_per_connection(prefill=True), 2)
        self.assertEqual(benchmark_targets_per_connection(prefill=False), 2)
        room = '00000000-0000-0000-0000-000000000001'
        parts = []
        for index in range(PARTS):
            identity = f'00000000-0000-0000-0000-{index+1:012d}'
            scopes = [dict(scope=kind, scopeID=room if kind == 'room' else 'account',
                           scopeGeneration=1, revision=1, state='ready', highWatermark=2,
                           appliedCursor=2, passed=True) for kind in ('account', 'room')]
            coverage = dict(physicalConnectionID=identity, wireVersion=CANDIDATE_WIRE_VERSION, requestedScopes=scopes,
                            heartbeatAcknowledged=1, heartbeatMissed=0)
            parts.append(dict(requestedConnections=1, slots=[dict(connectionIndex=0,
                state='active', physicalConnectionID=identity, coverage=coverage,
                rooms=[dict(activeForeground=True, roomID=room)])]))
        self.assertTrue(checkpoint_connection_proof(parts, [1]*PARTS, require_ready=True))
        empty_account = copy.deepcopy(parts)
        empty_account[0]['slots'][0]['coverage']['requestedScopes'][0]['highWatermark'] = 0
        empty_account[0]['slots'][0]['coverage']['requestedScopes'][0]['appliedCursor'] = 0
        self.assertTrue(checkpoint_connection_proof(empty_account, [1]*PARTS, require_ready=True))
        incomplete = copy.deepcopy(parts)
        incomplete[0]['slots'][0]['coverage']['requestedScopes'][1]['highWatermark'] = 0
        self.assertFalse(checkpoint_connection_proof(incomplete, [1]*PARTS, require_ready=True))
        incomplete[0]['slots'][0]['state'] = 'missing'
        self.assertFalse(checkpoint_connection_proof(incomplete, [1]*PARTS, require_ready=False))
        self.assertFalse(checkpoint_heartbeat_continuity(parts, parts, 0))
        after = copy.deepcopy(parts)
        for index in (0, 6): after[index]['slots'][0]['coverage']['heartbeatAcknowledged'] += 1
        self.assertTrue(checkpoint_heartbeat_continuity(parts, after, 0))
        self.assertTrue(checkpoint_physical_continuity(parts, after))
        after[0]['slots'][0]['physicalConnectionID'] = 'replacement'
        self.assertFalse(checkpoint_physical_continuity(parts, after))
        self.assertFalse(checkpoint_heartbeat_continuity(parts, after, 0))


if __name__ == '__main__':
    unittest.main()
