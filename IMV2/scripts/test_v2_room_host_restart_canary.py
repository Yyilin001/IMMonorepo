import copy
import unittest
import json
import signal
import time
import uuid
from pathlib import Path
from types import SimpleNamespace

from v2_room_host_restart_canary import RoomHostRestartCanary, constraints, lease_snapshot, takeover_proven


class RoomRestartProofTests(unittest.TestCase):
    def setUp(self):
        self.initial = dict(roomID='00000000-0000-0000-0000-000000000001', epoch=3,
                            ownerShard='s0', ownerEpoch=0, incarnation='old', expiresAt=100)
        self.snapshot = dict(databaseNow=101, leases=[dict(self.initial, epoch=4,
                             incarnation='new', expiresAt=130)])

    def test_requires_actual_room_epoch_identity_and_natural_expiry(self):
        self.assertTrue(takeover_proven(self.initial, self.initial, self.snapshot))
        for key, value in [('epoch', 3), ('incarnation', 'old'), ('incarnation', None),
                           ('ownerEpoch', 1), ('ownerShard', 'other'), ('expiresAt', 100),
                           ('roomID', '00000000-0000-0000-0000-000000000002')]:
            invalid = copy.deepcopy(self.snapshot)
            invalid['leases'][0][key] = value
            with self.subTest(key=key, value=value):
                self.assertFalse(takeover_proven(self.initial, self.initial, invalid))
        # A renewal dispatched before kill may commit after it: honor its expiry.
        self.assertFalse(takeover_proven(self.initial, dict(self.initial, expiresAt=110), self.snapshot))

    def test_sql_witness_uses_room_activation_and_never_mutates(self):
        captured = []
        def read(sql):
            captured.append(sql)
            return '{"databaseNow":1,"leases":[]}'
        lease_snapshot(read, [self.initial['roomID']])
        self.assertIn('im_v2.room_activation_leases', captured[0])
        self.assertNotIn('realtime_partition_leases', captured[0])
        self.assertNotIn('FOR UPDATE', captured[0])
        self.assertNotIn('UPDATE ', captured[0])
        with self.assertRaises(ValueError):
            lease_snapshot(read, ["'); DELETE FROM im_v2.rooms;--"])

    def test_mode_excludes_shared_services_and_requires_postfault_tcp_sends(self):
        args = SimpleNamespace(room_host_restart_canary=0, kind='candidate', allow_small_canary=True,
            shared_postgres=False, allow_scaled_diagnostic=False, realtime_host_restart_canary=None,
            actor_partition_canary=None, planned_reconnect_inflight_canary=False,
            app_outbox_canary=False, app_multi_device_canary=False)
        phases = [dict(name='room-host-natural-recovery', durationSeconds=120),
                  dict(name='post-recovery', messagesPerSecond=12)]
        constraints(args, dict(users=120), phases)
        for field, value in [('shared_postgres', True), ('kind', 'both'),
                             ('actor_partition_canary', 1), ('allow_scaled_diagnostic', True)]:
            invalid = copy.copy(args); setattr(invalid, field, value)
            with self.subTest(field=field), self.assertRaises(ValueError):
                constraints(invalid, dict(users=120), phases)
        with self.assertRaises(ValueError):
            constraints(args, dict(users=120), phases[:1])

    def test_kill_selects_configured_physical_host_uuid_not_gateway_label(self):
        class Process:
            returncode = None
            def poll(self): return self.returncode
            def kill(self): self.returncode = -signal.SIGKILL
            def wait(self, timeout): return self.returncode
        host = 'abcdefab-cdef-abcd-efab-cdefabcdefab'
        row = dict(self.initial, hostID=host.upper(), head=0, expiresAt=100)
        witness = RoomHostRestartCanary(SimpleNamespace(room_host_restart_canary=0), Path('/unused'), [1],
            lambda sql: json.dumps(dict(databaseNow=1, leases=[row])), lambda *args: None,
            lambda *args: True, lambda *args, **kwargs: True, lambda *args: True, host)
        witness.checkpoint = lambda: [dict(slots=[dict(coverage=dict(requestedScopes=[
            dict(scope='room', scopeID=row['roomID'])]))])]
        original, survivor, replacement = Process(), Process(), Process()
        gateways = [original, survivor]
        witness.step(time.time() - 1, gateways, lambda index: replacement)
        self.assertEqual(original.returncode, -signal.SIGKILL)
        self.assertIs(gateways[0], replacement)
        self.assertIsNone(survivor.returncode)
        self.assertEqual(witness.initial['hostID'], host.upper())
        self.assertFalse(witness.recovered)  # SIGKILL itself never proves recovery

    def test_auto_target_uses_actual_ready_rooms_and_never_kills_client_gateway(self):
        class Process:
            returncode = None
            def poll(self): return self.returncode
            def kill(self): self.returncode = -signal.SIGKILL
            def wait(self, timeout): return self.returncode
        hosts = {i: str(uuid.UUID(int=i + 10)) for i in range(3)}
        rows = [dict(self.initial, roomID=str(uuid.UUID(int=i + 1)), hostID=hosts[host],
                     head=0, expiresAt=100) for i, host in enumerate([0, 1, 1, 1, 2, 2])]
        witness = RoomHostRestartCanary(SimpleNamespace(room_host_restart_canary=0, room_host_auto_target=True),
            Path('/unused'), [1], lambda sql: json.dumps(dict(databaseNow=1, leases=rows)),
            lambda *args: None, lambda *args: True, lambda *args, **kwargs: True,
            lambda *args: True, hosts[0], hosts)
        witness.checkpoint = lambda: [dict(slots=[dict(coverage=dict(requestedScopes=[
            dict(scope='room', scopeID=row['roomID']) for row in rows]))])]
        gateways = [Process() for _ in hosts]
        witness.step(time.time() - 1, gateways, lambda index: Process())
        self.assertEqual(witness.target, 2)
        self.assertEqual(witness.survivor, 1)
        self.assertIsNone(gateways[1].returncode)
        self.assertEqual(len(witness.candidates), 2)
        self.assertFalse(witness.recovered)

    def test_idle_first_room_cannot_hide_recovered_traffic_on_another_killed_room(self):
        first = dict(self.initial, head=0)
        second = dict(first, roomID='00000000-0000-0000-0000-000000000002')
        snapshot = dict(databaseNow=101, leases=[
            dict(first, epoch=4, incarnation='new', expiresAt=130),
            dict(second, epoch=4, incarnation='new', expiresAt=130, head=1)])
        witness = RoomHostRestartCanary(SimpleNamespace(room_host_restart_canary=0), Path('/unused'), [1],
            lambda sql: json.dumps(snapshot), lambda *args: None, lambda *args: True,
            lambda *args, **kwargs: True, lambda *args: True, '00000000-0000-0000-0000-000000000099')
        witness.old_process = SimpleNamespace(returncode=-signal.SIGKILL)
        witness.initial, witness.last_old = first, first
        witness.candidates = {row['roomID']: row for row in (first, second)}
        witness.last_old_by_room = dict(witness.candidates)
        witness.before = []
        witness.checkpoint = lambda: [dict(slots=[dict(coverage=dict(requestedScopes=[
            dict(scope='room', scopeID=second['roomID'], appliedCursor=1)]))])]
        witness.step(time.time() - 1, [], None)
        self.assertEqual(witness.selected_room, second['roomID'])
        self.assertEqual(witness.initial, second)
        self.assertTrue(witness.recovered)


if __name__ == '__main__':
    unittest.main()
