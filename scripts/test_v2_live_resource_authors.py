#!/usr/bin/env python3
"""Owned cleanup, capacity phases and the local HTTP fixture transport."""
import base64
import threading
import unittest
from unittest.mock import Mock, patch

import verify_v2_live_resource_authors as verifier
from v2_live_author_capacity import AuthorCapacityFixture


class FixtureUpstreamTests(unittest.TestCase):
    def test_requests_reuse_one_real_connection_and_preserve_bodies(self):
        arrivals = []
        class Handler(verifier.http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            def log_message(self, *_):
                pass
            def do_POST(self):
                body = self.rfile.read(int(self.headers['Content-Length']))
                arrivals.append((self.client_address, self.path, body, self.headers.get('X-Test')))
                self.send_response(201)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
        server = verifier.http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        worker = threading.Thread(target=server.serve_forever)
        worker.start()
        upstream = verifier.FixtureHTTPUpstream(server.server_port)
        try:
            for i in range(4):
                body = str(i).encode()
                status, _, reply = upstream.request('POST', '/fixture', body, {'X-Test': str(i)}, timeout=2)
                self.assertEqual((status, reply), (201, body))
            self.assertEqual(len({row[0] for row in arrivals}), 1)
            self.assertEqual([(row[1], row[2], row[3]) for row in arrivals],
                             [('/fixture', str(i).encode(), str(i)) for i in range(4)])
        finally:
            upstream.close()
            server.shutdown(); worker.join(timeout=3); server.server_close()
        self.assertFalse(worker.is_alive())
        self.assertIsNone(upstream.connection)

    def test_failed_post_is_closed_without_replay(self):
        connection = Mock()
        connection.getresponse.side_effect = OSError('fixture disconnect after send')
        with patch.object(verifier.http.client, 'HTTPConnection', return_value=connection) as constructor:
            upstream = verifier.FixtureHTTPUpstream(12345)
            with self.assertRaises(OSError):
                upstream.request('POST', '/fixture', b'once', {})
            constructor.assert_called_once()
            connection.request.assert_called_once_with('POST', '/fixture', b'once', {})
            connection.close.assert_called_once()
            self.assertIsNone(upstream.connection)


class OwnedCleanupTests(unittest.TestCase):
    def process(self):
        return Mock(pid=424242, _owned_process_group=424242)

    def test_permission_race_waits_for_independently_observed_exit(self):
        process = self.process()
        with patch.object(verifier.os, 'getpgrp', return_value=1), \
             patch.object(verifier.os, 'killpg', side_effect=PermissionError) as signal, \
             patch.object(verifier.subprocess, 'check_output', side_effect=['424242 S\n', '424242 S\n', '']), \
             patch.object(verifier.time, 'sleep'):
            verifier.stop(process)
        self.assertTrue(all(call.args[0] == process.pid for call in signal.call_args_list))
        process.wait.assert_called_once_with(timeout=10)

    def test_inaccessible_live_group_is_not_reported_drained(self):
        process = self.process()
        with patch.object(verifier.os, 'getpgrp', return_value=1), \
             patch.object(verifier.os, 'killpg', side_effect=PermissionError), \
             patch.object(verifier.subprocess, 'check_output', return_value='424242 S\n'), \
             patch.object(verifier.time, 'monotonic', side_effect=range(0, 1000, 100)), \
             patch.object(verifier.time, 'sleep'):
            with self.assertRaisesRegex(RuntimeError, 'failed to drain'):
                verifier.stop(process)
        process.wait.assert_not_called()

    def test_zombie_group_has_no_live_work(self):
        process = self.process()
        with patch.object(verifier.os, 'getpgrp', return_value=1), \
             patch.object(verifier.os, 'killpg', side_effect=PermissionError), \
             patch.object(verifier.subprocess, 'check_output', return_value='424242 Z\n'):
            verifier.stop(process)
        process.wait.assert_called_once_with(timeout=10)

    def test_shared_group_is_never_signalled(self):
        with patch.object(verifier.os, 'getpgrp', return_value=424242), \
             patch.object(verifier.os, 'killpg') as signal:
            with self.assertRaisesRegex(RuntimeError, 'unowned'):
                verifier.stop(self.process())
        signal.assert_not_called()


class CapacityPhaseTests(unittest.TestCase):
    def test_phase_observation_waits_for_every_client_and_is_not_repeated_or_sent(self):
        fixture = AuthorCapacityFixture(2, None, base64.b64encode(b'test-only').decode(), {}, threading.Lock(), 2)
        fixture.population = {}
        fixture.statistics = Mock(return_value={'controlBatches': 17})
        fixture.metrics_ports = (12345, 12346)
        fixture.gateway_metrics = Mock(side_effect=lambda port: {'rooms': {'calls': port}})
        def report(index):
            return fixture.barrier(dict(process=str(index), phase='authenticated', participants='1', httpAttempts='0'))
        self.assertFalse(report(0)['ready'])
        fixture.gateway_metrics.assert_not_called()
        response = report(1)
        self.assertTrue(response['ready'])
        self.assertNotIn('observation', response)
        self.assertEqual(response, report(0))
        fixture.statistics.assert_called_once()
        self.assertEqual(fixture.gateway_metrics.call_count, 2)
        observation = fixture.evidence()['authenticated']['observation']
        self.assertEqual(observation['gatewayNodes'], [{'rooms': {'calls': 12345}}, {'rooms': {'calls': 12346}}])
        self.assertTrue(observation['metricsComplete'])
        self.assertGreaterEqual(observation['captureSeconds'], 0)

    def test_failed_node_is_explicit_and_does_not_prevent_phase_release(self):
        fixture = AuthorCapacityFixture(2, None, base64.b64encode(b'test-only').decode(), {}, threading.Lock())
        fixture.population = {}
        fixture.statistics = lambda: {}
        fixture.metrics_ports = (12345,)
        fixture.gateway_metrics = lambda _: {'errorType': 'TimeoutError'}
        response = fixture.barrier(dict(process='0', phase='authenticated', participants='2', httpAttempts='0'))
        self.assertTrue(response['ready'])
        observation = fixture.evidence()['authenticated']['observation']
        self.assertFalse(observation['metricsComplete'])
        self.assertEqual(observation['gatewayNodes'], [{'errorType': 'TimeoutError'}])

    def test_closure_evidence_keeps_only_known_fixed_transport_reasons(self):
        data = b'''im_v2_gateway_connection_closures_total{reason="idle_timeout"} 3
im_v2_gateway_connection_closures_total{reason="request_failure"} 5
im_v2_gateway_connection_closures_total{reason="unknown"} 99
im_v2_gateway_connection_closures_total{reason="idle_timeout",user="private"} 99
im_v2_gateway_active_connections 7
im_v2_room_actor_outstanding_commands 17
im_v2_room_actor_peak_outstanding_commands 23
im_v2_room_actor_cached_remote_calls_total 41
im_v2_room_actor_outstanding_commands{room="private"} 99
im_v2_room_actor_unknown 99
im_v2_room_subscription_head_delivery_total{stage="socketNotWritable"} 13
im_v2_room_subscription_head_delivery_total{stage="socketNotWritable",user="private"} 99
im_v2_gateway_foreground_nonwritable_deferrals_total 17
im_v2_gateway_foreground_nonwritable_deferrals_total{user="private"} 99
'''
        connection = Mock()
        connection.getresponse.side_effect = [Mock(status=200, read=Mock(return_value=data)),
            Mock(status=200, read=Mock(return_value=b'im_v2_author_delivered_frames_total 11\n'))]
        with patch('v2_live_author_capacity.http.client.HTTPConnection', return_value=connection):
            result = AuthorCapacityFixture.gateway_metrics(12345)
        self.assertEqual(result['connectionClosures'], {'idle_timeout': 3, 'request_failure': 5})
        self.assertEqual(result['gateway'], {'im_v2_gateway_active_connections': 7})
        self.assertEqual(result['authors'], {'im_v2_author_delivered_frames_total': 11})
        self.assertEqual(result['headDelivery'], {'socketNotWritable': 13, 'foregroundNonwritable': 17})
        self.assertEqual(result['rooms'], {'im_v2_room_actor_outstanding_commands': 17,
            'im_v2_room_actor_peak_outstanding_commands': 23,
            'im_v2_room_actor_cached_remote_calls_total': 41})
        self.assertNotIn('private', str(result))
        connection.close.assert_called_once()

    def test_node_maxima_are_not_summed_with_counters(self):
        maximum = 'im_v2_author_read_initial_room_milliseconds_max_lifetime'
        total = 'im_v2_author_read_initial_room_milliseconds_total'
        calls = 'im_v2_author_read_initial_room_calls_total'
        nodes = [dict(authors={maximum: 20, total: 100, calls: 5}),
                 dict(authors={maximum: 30, total: 200, calls: 10}), dict(errorType='TimeoutError')]
        self.assertEqual(AuthorCapacityFixture.aggregate_metric_nodes(nodes, 'authors'), {maximum: 30, total: 300, calls: 15})

    def test_optional_phases_remain_global_barriers(self):
        for seconds, avatar in ((0, False), (35, False), (0, True), (35, True)):
            with self.subTest(seconds=seconds, avatar=avatar):
                fixture = AuthorCapacityFixture(2, None, base64.b64encode(b'test-only').decode(), {}, threading.Lock(), 2, seconds, avatar)
                fixture.population = {'mediaID': '00000000-0000-0000-0000-000000000001'}
                fixture.statistics = lambda: {}
                phases = (['authenticated', 'cold', 'warm'] + (['renewed'] if seconds else [])
                          + ['changed'] + (['avatar_changed'] if avatar else []) + ['bytes'])
                def report(phase, process):
                    return fixture.barrier(dict(process=str(process), phase=phase, participants='1', httpAttempts='0'))
                with self.assertRaisesRegex(ValueError, 'skipped'):
                    report('bytes', 0)
                for phase in phases:
                    if phase == 'avatar_changed':
                        with self.assertRaisesRegex(ValueError, 'not published'):
                            report(phase, 0)
                        fixture.avatar(dict(process='0', media='00000000-0000-0000-0000-000000000002'))
                    self.assertFalse(report(phase, 0)['ready'])
                    self.assertTrue(report(phase, 1)['ready'])
                    self.assertEqual(report(phase, 0)['participants'], 2)
                self.assertEqual(list(fixture.evidence()), phases)

    def test_avatar_publication_is_author_owned_and_immutable(self):
        fixture = AuthorCapacityFixture(2, None, base64.b64encode(b'test-only').decode(), {}, threading.Lock(), avatar_replacement=True)
        original, replacement, conflicting = ('00000000-0000-0000-0000-00000000000' + str(i) for i in range(1, 4))
        fixture.population = {'mediaID': original}
        self.assertFalse(fixture.avatar(None)['ready'])
        with self.assertRaises(ValueError):
            fixture.avatar(dict(process='0', media=replacement))
        fixture.phases['changed'] = {'ready': True}
        for command in (dict(process='1', media=replacement), dict(process='0', media=original)):
            with self.assertRaises(ValueError):
                fixture.avatar(command)
        self.assertEqual(fixture.avatar(dict(process='0', media=replacement)), dict(ready=True, media=replacement))
        self.assertEqual(fixture.avatar(dict(process='0', media=replacement)), fixture.avatar(None))
        with self.assertRaises(ValueError):
            fixture.avatar(dict(process='0', media=conflicting))

    def test_fault_phase_never_counts_paused_peers_as_healthy_or_accepts_late_evidence(self):
        fixture = AuthorCapacityFixture(6, None, base64.b64encode(b'test-only').decode(), {}, threading.Lock(), 2, faults=True)
        fixture.population = {}
        fixture.statistics = lambda: {}
        fixture.profile_lock = Mock(is_held=Mock(return_value=True))
        def report(phase, process, count=3):
            return fixture.barrier(dict(process=str(process), phase=phase, participants=str(count), httpAttempts='0'))
        for phase in ('authenticated', 'cold', 'warm', 'fault_ready'):
            self.assertFalse(report(phase, 0)['ready'])
            self.assertTrue(report(phase, 1)['ready'])
        fixture.fault_state['sequence'] = 3
        with self.assertRaisesRegex(ValueError, 'partition'):
            report('fault_healthy', 0)
        self.assertFalse(report('fault_healthy', 0, 2)['ready'])
        fixture.profile_lock.is_held.return_value = False
        with self.assertRaisesRegex(ValueError, 'during'):
            report('fault_healthy', 1, 2)
        fixture.profile_lock.is_held.return_value = True
        self.assertEqual(report('fault_healthy', 1, 2)['participants'], 4)
        with self.assertRaisesRegex(ValueError, 'release'):
            report('fault_recovered', 0)
        fixture.fault_state['released'] = True
        self.assertFalse(report('fault_recovered', 0)['ready'])
        self.assertEqual(report('fault_recovered', 1)['participants'], 6)

    def test_fault_receipt_requires_observed_backpressure_and_failed_profile_reads(self):
        fixture = AuthorCapacityFixture(2, None, base64.b64encode(b'test-only').decode(), {}, threading.Lock(), faults=True)
        fixture.fault_state['active'] = True
        fixture.fault_baseline = dict(nonwritableDeferrals=3, controlFailures=5)
        fixture.profile_lock = Mock(is_held=Mock(return_value=True))
        fixture.relays = [Mock(snapshot=Mock(return_value=dict(paused=True, threadAlive=True, errorType=None)))]
        command = dict(action='message', process='0', sequence='7')
        for blocked, failed in ((3, 6), (4, 5)):
            fixture._fault_metrics = lambda: dict(nonwritableDeferrals=blocked, controlFailures=failed, gatewayNodes=[])
            with self.assertRaisesRegex(ValueError, 'evidence'):
                fixture.fault(command)
        fixture._fault_metrics = lambda: dict(nonwritableDeferrals=4, controlFailures=6, gatewayNodes=[])
        self.assertEqual(fixture.fault(command)['sequence'], 7)
        fixture.profile_lock.is_held.return_value = False
        with self.assertRaisesRegex(ValueError, 'evidence'):
            fixture.fault(command)


if __name__ == '__main__':
    unittest.main()
