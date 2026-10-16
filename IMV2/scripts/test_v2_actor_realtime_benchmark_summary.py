"""Measured-phase quality regression; no services or load required."""
import importlib.util
import json
import re
import tempfile
from pathlib import Path
import unittest
from types import SimpleNamespace

SPEC = importlib.util.spec_from_file_location('benchmark', Path(__file__).with_name('run_v2_actor_realtime_benchmark.py'))
benchmark = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(benchmark)


class MergedLatencyHistogramTests(unittest.TestCase):
    def sample(self, values):
        return dict(count=sum(values.values()), maximum=max(values, default=0),
            histogramBuckets=[dict(lowerBoundMilliseconds=k, count=v) for k, v in values.items()])

    def test_global_rank_weights_samples_instead_of_shard_percentiles(self):
        result = benchmark.merge_latency_histograms([self.sample({10: 999}), self.sample({1400: 1})])
        self.assertEqual(result['count'], 1000)
        self.assertEqual(result['p99'], 10)
        self.assertEqual(result['p99UpperBoundExclusiveMilliseconds'], 11)
        result = benchmark.merge_latency_histograms([self.sample({10: 98}), self.sample({1400: 2})])
        self.assertEqual(result['p99'], 1400)

    def test_missing_counts_and_inconsistent_histograms_do_not_prove_a_percentile(self):
        self.assertIsNone(benchmark.merge_latency_histograms([dict(count=1, p99=10)]))
        wrong = self.sample({10: 5})
        wrong['count'] = 6
        with self.assertRaises(ValueError):
            benchmark.merge_latency_histograms([wrong])

    def test_overflow_cannot_claim_a_finite_upper_bound(self):
        result = benchmark.merge_latency_histograms([self.sample({10000: 1})])
        self.assertIsNone(result['p99UpperBoundExclusiveMilliseconds'])


class MessageSendCohortSummaryTests(unittest.TestCase):
    sample = MergedLatencyHistogramTests.sample
    def reports(self):
        fast, complete = self.sample({10: 1}), self.sample({10: 1, 900: 1})
        return [dict(scenarioPhases=[dict(name='measured', messagesAcknowledged=1,
                observedDurationSeconds=1, durationSeconds=1, completed=True,
                messageLatency=fast, messageEndToEndLatency=fast)],
            messageSendCohorts=dict(measured=dict(messagesSent=2, messagesAcknowledged=2,
                messageLatency=complete, messageEndToEndLatency=complete)))
            for _ in range(benchmark.PARTS)]

    def test_late_ack_is_included_without_using_other_phase_samples(self):
        reports = self.reports()
        for report in reports:
            report['messageSendCohorts']['warmup'] = dict(messagesSent=100,
                messagesAcknowledged=100, messageLatency=self.sample({5000: 100}))
        result = benchmark.summarize(reports, [0]*benchmark.PARTS, 12, measurement_phase='measured')
        self.assertTrue(result['measurementMessageCohort']['complete'])
        self.assertEqual(result['measurementLatency']['messageEndToEndLatency']['count'], 24)
        self.assertEqual(result['measurementLatency']['messageEndToEndLatency']['p99'], 900)
        self.assertEqual(result['measurementWindowLatency']['messageEndToEndLatency']['count'], 12)
        self.assertEqual(result['measurementWindowLatency']['messageEndToEndLatency']['p99'], 10)

    def test_incomplete_missing_or_inconsistent_cohort_cannot_prove_p99(self):
        for field in ('missing', 'messagesAcknowledged', 'histogramCount'):
            reports = self.reports()
            if field == 'missing': reports[0].pop('messageSendCohorts')
            elif field == 'messagesAcknowledged': reports[0]['messageSendCohorts']['measured'][field] = 1
            else: reports[0]['messageSendCohorts']['measured']['messageLatency'] = self.sample({10: 1})
            result = benchmark.summarize(reports, [0]*benchmark.PARTS, 12, measurement_phase='measured')
            self.assertFalse(result['measurementMessageCohort']['complete'])
            self.assertIsNone(result['measurementLatency']['messageEndToEndLatency'])

    def test_corrupt_bucket_count_is_rejected(self):
        reports = self.reports()
        reports[0]['messageSendCohorts']['measured']['messageLatency']['histogramBuckets'][0]['count'] += 1
        with self.assertRaises(ValueError):
            benchmark.summarize(reports, [0]*benchmark.PARTS, 12, measurement_phase='measured')


class WorkloadTCPInspectionTests(unittest.TestCase):
    def test_custom_source_range_does_not_wait_for_an_unrelated_default_range(self):
        for system, text in [
            ('Darwin', '\n'.join([
                'tcp4 0 0 127.0.0.1.1024 127.0.0.1.21453 TIME_WAIT',
                'tcp4 0 0 127.0.0.1.21023 127.0.0.1.21458 ESTABLISHED',
                'tcp4 0 0 127.0.0.1.21024 127.0.0.1.21453 TIME_WAIT',
                'tcp4 0 0 127.0.0.1.25000 127.0.0.1.21453 TIME_WAIT',
            ])),
            ('Linux', '\n'.join(f'{i}: 0100007F:{local:04X} 0100007F:{remote:04X} 06 0:0'
                for i, (local, remote) in enumerate([
                    (1024, 21453), (21023, 21458), (21024, 21453), (25000, 21453)]))),
        ]:
            with self.subTest(system=system):
                self.assertEqual(benchmark.count_workload_tcp_tuples(text, 21453,
                    system=system, local_port_base=1024), 2)

    def test_darwin_counts_only_workload_source_and_gateway_destination_pairs(self):
        rows = '\n'.join([
            'Proto Recv-Q Send-Q Local Address Foreign Address (state)',
            'tcp4 0 0 127.0.0.1.25000 127.0.0.1.21453 TIME_WAIT',
            'tcp6 0 0 ::1.44999 ::1.21458 ESTABLISHED',
            'tcp4 0 0 127.0.0.1.24999 127.0.0.1.21453 TIME_WAIT',
            'tcp4 0 0 127.0.0.1.45000 127.0.0.1.21453 TIME_WAIT',
            'tcp4 0 0 127.0.0.1.25000 127.0.0.1.21459 ESTABLISHED',
            'tcp4 0 0 *.21453 *.* LISTEN',
            'udp4 0 0 127.0.0.1.25000 127.0.0.1.21453 CONNECTED',
        ])
        self.assertEqual(benchmark.count_workload_tcp_tuples(rows, 21453, system='Darwin'), 2)

    def test_linux_decodes_hex_ports_for_both_tcp_address_families(self):
        rows = ['sl local_address rem_address st tx_queue rx_queue']
        for index, (local, remote, state) in enumerate([
            (25000, 21453, '06'), (44999, 21458, '01'),
            (24999, 21453, '06'), (45000, 21453, '06'),
            (25000, 21459, '01'), (21453, 0, '0A'),
        ]):
            address = '0100007F' if index % 2 == 0 else '00000000000000000000000001000000'
            rows.append(f'{index}: {address}:{local:04X} {address}:{remote:04X} {state} 0:0')
        rows += ['malformed', '7: invalid:nothex invalid:53CD 01 0:0']
        self.assertEqual(benchmark.count_workload_tcp_tuples('\n'.join(rows), 21453, system='Linux'), 2)


class PostgresSamplerFailureTests(unittest.TestCase):
    def test_connection_failures_are_distinct_from_execution_timeouts_without_retaining_inputs(self):
        cases = (
            (2, 'connection to server at private-host failed: timeout expired', 'connection_timeout'),
            (2, 'Connection refused', 'connection_refused'),
            (2, 'FATAL: remaining connection slots are reserved', 'connection_capacity'),
            (2, 'FATAL: too many clients already', 'connection_capacity'),
            (2, 'password authentication failed for user private-user', 'authentication'),
            (2, 'server closed the connection unexpectedly', 'connection_closed'),
            (2, 'could not receive data from server', 'connection_closed'),
            (1, 'ERROR: canceling statement due to statement timeout\nSELECT private-data', 'statement_timeout'),
            (1, 'ERROR: canceling statement due to lock timeout', 'lock_timeout'),
            (2, 'unknown private diagnostic', 'connection_error'),
            (1, 'unknown private diagnostic', 'statement_error'),
        )
        for returncode, stderr, expected in cases:
            with self.subTest(expected=expected):
                self.assertEqual(benchmark.postgres_sampler_failure_category(returncode, stderr), expected)


class LoaderFailureReportDrainTests(unittest.TestCase):
    def test_failed_peer_does_not_immediately_abort_and_later_failures_do_not_extend_deadline(self):
        drain = benchmark.LoaderFailureReportDrain(30)
        self.assertFalse(drain.observe([None, 1, None], 100))
        self.assertFalse(drain.observe([2, 1, None], 129))
        self.assertTrue(drain.observe([2, 1, None], 130))
        self.assertEqual(drain.started, 100)
        self.assertEqual(drain.evidence([0, 1], 3)['failedLoaderOrdinals'], [0, 1])
        self.assertEqual(drain.evidence([0, 1], 3)['missingReportOrdinals'], [2])

    def test_all_peers_may_finish_and_report_after_failure_without_becoming_success(self):
        drain = benchmark.LoaderFailureReportDrain(30)
        drain.observe([1, None], 100)
        self.assertFalse(drain.observe([1, 0], 131))
        proof = drain.evidence([0, 1], 2)
        self.assertTrue(proof['firstFailureObserved'])
        self.assertTrue(proof['allReportsPresent'])
        self.assertFalse(proof['timedOut'])

    def test_no_failure_does_not_change_success_or_start_a_deadline(self):
        drain = benchmark.LoaderFailureReportDrain(30)
        self.assertFalse(drain.observe([0, None], 100))
        self.assertFalse(drain.observe([0, 0], 500))
        self.assertIsNone(drain.started)

    def test_invalid_budget_is_rejected(self):
        for seconds in [0, 601]:
            with self.assertRaises(ValueError):
                benchmark.LoaderFailureReportDrain(seconds)


class CandidateAuthorizationConfigurationTests(unittest.TestCase):
    def test_candidate_only_does_not_require_frozen_baseline_binaries(self):
        args = SimpleNamespace(kind='candidate', baseline_checkout=None, baseline_binary=None,
            baseline_account_binary=None, candidate_binary=Path('gateway'),
            candidate_account_binary=Path('account'), loader_binary=Path('loader'))
        self.assertEqual(benchmark.required_benchmark_binaries(args), [Path('gateway'), Path('account'), Path('loader'), Path('IMV2PlacementControlApp')])
        for kind in ('baseline', 'both'):
            args.kind = kind
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                benchmark.required_benchmark_binaries(args)
        args.baseline_checkout, args.baseline_binary, args.baseline_account_binary = Path('frozen'), Path('old-gateway'), Path('old-account')
        self.assertEqual(len(benchmark.required_benchmark_binaries(args)), 6)

    def test_two_message_loops_preserve_node_pool_budgets(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory)
            (fixture / 'access-token-hmac-key.base64').write_text('test-fixture')
            args = SimpleNamespace(baseline_checkout=None, fixture=fixture,
                gateway_port=21453, metrics_port=23464, pg_user='test', pg_host='localhost', pg_port=24533)
            manifest = dict(userBucket='user-a', shardID='room-a', capacityProfileID='standard', commandWindowLimit=100)
            defaults = benchmark.gateway_env(args, 'candidate', 'test_database', 0, fixture, manifest)
            self.assertNotIn('IM_V2_GATEWAY_HEARTBEAT_DIAGNOSTICS', defaults)
            self.assertNotIn('IM_V2_GATEWAY_COVERAGE_DIAGNOSTICS', defaults)
            args.candidate_coverage_diagnostics = True
            diagnostic = benchmark.gateway_env(args, 'candidate', 'test_database', 0, fixture, manifest)
            self.assertEqual(diagnostic['IM_V2_GATEWAY_COVERAGE_DIAGNOSTICS'], 'true')
            args.candidate_coverage_diagnostics = False
            args.candidate_heartbeat_diagnostics = True
            diagnostic = benchmark.gateway_env(args, 'candidate', 'test_database', 0, fixture, manifest)
            self.assertEqual(diagnostic['IM_V2_GATEWAY_HEARTBEAT_DIAGNOSTICS'], 'true')
            args.candidate_heartbeat_diagnostics = False
            self.assertEqual(defaults['IM_V2_DATABASE_EVENT_LOOP_THREADS'], '4')
            self.assertEqual(defaults['IM_V2_DATABASE_MESSAGE_WRITE_CONNECTIONS_PER_EVENT_LOOP'], '2')
            self.assertEqual(defaults['IM_V2_DATABASE_NON_MESSAGE_POOL_EVENT_LOOP_THREADS'], '1')
            args.candidate_message_write_connections = 4
            args.candidate_event_loop_threads = 1
            one = benchmark.gateway_env(args, 'candidate', 'test_database', 0, fixture, manifest)
            self.assertEqual(one['IM_V2_DATABASE_POLICY_CONTROL_CONNECTIONS_PER_EVENT_LOOP'], '4')
            args.candidate_event_loop_threads = 2
            two = benchmark.gateway_env(args, 'candidate', 'test_database', 0, fixture, manifest)
            self.assertEqual(two['IM_V2_SEND_PATH_TRACE_MODE'], 'off')
            self.assertEqual(two['IM_V2_MESSAGE_WRITE_PREPARED_QUERIES_ENABLED'], 'true')
            self.assertEqual(two['IM_V2_ACTOR_BINARY_INVOCATIONS_ENABLED'], 'true')
            args.candidate_actor_binary_invocations = 'enabled'
            args.candidate_send_path_trace_mode = 'all'
            args.candidate_message_write_prepared_queries = 'disabled'
            comparison = benchmark.gateway_env(args, 'candidate', 'test_database', 0, fixture, manifest)
            self.assertEqual(comparison['IM_V2_SEND_PATH_TRACE_MODE'], 'all')
            self.assertEqual(comparison['IM_V2_MESSAGE_WRITE_PREPARED_QUERIES_ENABLED'], 'false')
            self.assertEqual(comparison['IM_V2_ACTOR_BINARY_INVOCATIONS_ENABLED'], 'true')
            self.assertEqual(two['IM_V2_DATABASE_EVENT_LOOP_THREADS'], '2')
            self.assertEqual(two['IM_V2_DATABASE_NON_MESSAGE_POOL_EVENT_LOOP_THREADS'], '1')
            self.assertEqual(two['IM_V2_DATABASE_MESSAGE_WRITE_CONNECTIONS_PER_EVENT_LOOP'], '2')
            args.candidate_policy_control_connections = 8
            control = benchmark.gateway_env(args, 'candidate', 'test_database', 0, fixture, manifest)
            self.assertEqual(control['IM_V2_DATABASE_POLICY_CONTROL_CONNECTIONS_PER_EVENT_LOOP'], '8')
            for key, value in comparison.items():
                if key != 'IM_V2_DATABASE_POLICY_CONTROL_CONNECTIONS_PER_EVENT_LOOP':
                    self.assertEqual(control[key], value)
            for role in ('FOREGROUND', 'SYNC', 'DELIVERY', 'PROJECTION', 'MAINTENANCE'):
                key = f'IM_V2_DATABASE_{role}_CONNECTIONS_PER_EVENT_LOOP'
                self.assertEqual(one[key], two[key])
                self.assertEqual(defaults[key], two[key])
            for key in ('IM_V2_USER_PROJECTION_CONCURRENCY', 'IM_V2_INTERACTIVE_READ_DATABASE_WORK_LIMIT',
                        'IM_V2_SYNC_DATABASE_WORK_LIMIT', 'IM_V2_DATABASE_MAX_TOTAL_CONNECTIONS'):
                self.assertEqual(one[key], two[key])

    def test_candidate_send_window_is_explicit(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory)
            (fixture / 'access-token-hmac-key.base64').write_text('test-fixture')
            args = SimpleNamespace(baseline_checkout=None, fixture=fixture,
                gateway_port=21453, metrics_port=23464, pg_user='test', pg_host='localhost', pg_port=24533)
            manifest = dict(userBucket='user-a', shardID='room-a', capacityProfileID='standard', commandWindowLimit=100)
            for window in (4, 8):
                args.candidate_message_send_inflight_per_connection = window
                env = benchmark.gateway_env(args, 'candidate', 'test_database', 0, fixture, manifest)
                self.assertEqual(env['IM_V2_MESSAGE_SEND_MAX_IN_FLIGHT_PER_CONNECTION'], str(window))
                self.assertEqual(benchmark.benchmark_message_send_window(args, 'candidate'), window)
                self.assertEqual(benchmark.benchmark_message_send_window(args, 'baseline'), 8)
            args.planned_reconnect_inflight_canary = True
            self.assertEqual(benchmark.benchmark_message_send_window(args, 'candidate'), 1)

    def test_message_transport_and_depth_are_explicit_and_owned(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'access-token-hmac-key.base64').write_text('test-fixture')
            args = SimpleNamespace(baseline_checkout=None, fixture=root,
                output_dir=Path('/tmp/imv2-socket-test'), kind='candidate', shared_postgres=False,
                gateway_port=21453, metrics_port=23464, pg_user='test', pg_host='localhost', pg_port=24533,
                candidate_message_write_transport='unix', candidate_message_write_pipeline_depth=1)
            manifest = dict(userBucket='user-a', shardID='room-a', capacityProfileID='standard', commandWindowLimit=100)
            values = benchmark.gateway_env(args, 'candidate', 'test_database', 0, root, manifest)
            self.assertEqual(values['IM_V2_DATABASE_MESSAGE_WRITE_PIPELINE_DEPTH'], '1')
            mapping = json.loads(values['IM_V2_DATABASE_MESSAGE_WRITE_UNIX_SOCKETS_JSON'])
            self.assertEqual(mapping, {values['IM_V2_DATABASE_URL']: '/tmp/imv2-socket-test/pg-socket/.s.PGSQL.24533'})
            args.shared_postgres = True
            with self.assertRaises(ValueError): benchmark.candidate_message_write_socket(args)
            args.candidate_message_write_transport = 'tcp'
            self.assertIsNone(benchmark.candidate_message_write_socket(args))
            values = benchmark.gateway_env(args, 'candidate', 'test_database', 0, root, manifest)
            self.assertNotIn('IM_V2_DATABASE_MESSAGE_WRITE_UNIX_SOCKETS_JSON', values)

    def test_selected_memory_path_requires_durable_startup_evidence(self):
        args = SimpleNamespace()
        proof = benchmark.verify_candidate_authorization_mode(args, 'candidate',
            lambda _: json.dumps(dict(activeDeployments=1, revision=1)))
        self.assertTrue(proof['memoryDeploymentChecked'])
        for observed in (dict(activeDeployments=0, revision=None), dict(activeDeployments=1, revision=2)):
            with self.subTest(observed=observed), self.assertRaises(RuntimeError):
                benchmark.verify_candidate_authorization_mode(args, 'candidate', lambda _: json.dumps(observed))
        def unexpected_query(_):
            self.fail('legacy/baseline cannot query a table unavailable in frozen schemas')
        self.assertFalse(benchmark.verify_candidate_authorization_mode(args, 'baseline',
            unexpected_query)['memoryDeploymentChecked'])
        args.candidate_authorization_mode = 'legacy'
        with self.assertRaises(ValueError):
            benchmark.verify_candidate_authorization_mode(args, 'candidate', unexpected_query)

    def test_real_generated_configs_enable_memory_only_for_candidate(self):
        for mode in (None, 'memory'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                fixture = root / 'fixture'
                fixture.mkdir()
                (fixture / 'credentials.jsonl').write_text('{}\n' * benchmark.PARTS)
                output = root / 'output'
                output.mkdir()
                args = SimpleNamespace(output_dir=output, fixture=fixture, actor_port=28337, placement_port=None)
                if mode is not None:
                    args.candidate_authorization_mode = mode
                actors, parts = benchmark.prepare(args, dict(shardID='rooms-primary',
                    userBucket='users-primary', users=benchmark.PARTS, rooms=benchmark.PARTS))
                self.assertEqual(parts, [1] * benchmark.PARTS)
                placement = None
                for name in [f'gateway-{index}' for index in range(benchmark.NODES)] + ['account']:
                    node = actors / name
                    candidate = json.loads((node / 'candidate.json').read_text())
                    baseline = json.loads((node / 'baseline.json').read_text())
                    self.assertNotIn('policyPlacement', baseline)
                    self.assertFalse(any(permission.startswith(('policy', 'realtime'))
                        for service in baseline['services'] for permission in service['permissions']))
                    current = candidate['policyPlacement']
                    if placement is None:
                        placement = current
                    self.assertEqual(current, placement)
                    self.assertEqual(current['partitionCount'], 16)
                    self.assertEqual(sorted(partition for owner in current['owners']
                        for partition in owner['partitions']), list(range(16)))
                    for service in candidate['services']:
                        if 'placementVote' in service['permissions'] or 'placementExclude' in service['permissions']:
                            self.assertFalse(any(permission.startswith('policy') for permission in service['permissions']))
                            continue
                        self.assertIn('policyMutation', service['permissions'])
                        if service['hostIDs']:
                            self.assertIn('policyRegistration', service['permissions'])
                            self.assertNotIn('policyRevocation', service['permissions'])
                self.assertEqual(candidate['hostID'], baseline['hostID'])
                self.assertEqual(candidate['signingKeyPath'], baseline['signingKeyPath'])


class NotificationLossProofTests(unittest.TestCase):
    def test_fault_is_owned_small_candidate_and_cannot_mix_injections(self):
        valid = dict(room_notification_loss_canary=True, kind='candidate', allow_small_canary=True,
                     shared_postgres=False, allow_scaled_diagnostic=False,
                     actor_partition_canary=None,
                     planned_reconnect_inflight_canary=False, app_outbox_canary=False,
                     app_multi_device_canary=False, preclose_recovery_witness=False)
        benchmark.room_notification_loss_constraints(SimpleNamespace(**valid), dict(users=120))
        for field, value in [('kind', 'both'), ('allow_small_canary', False), ('shared_postgres', True),
                             ('planned_reconnect_inflight_canary', True)]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                benchmark.room_notification_loss_constraints(SimpleNamespace(**dict(valid, **{field: value})), dict(users=120))
        with self.assertRaises(ValueError):
            benchmark.room_notification_loss_constraints(SimpleNamespace(**valid), dict(users=1000))

    def test_fault_requires_actual_discard_recovery_and_final_convergence(self):
        reports = [dict(roomNotificationLossCanary=True, roomNotificationsDiscarded=2,
                        roomProgressRecoverySignals=1)]
        self.assertTrue(benchmark.room_notification_loss_proof(reports, dict(passed=True))['passed'])
        self.assertFalse(benchmark.room_notification_loss_proof(reports, dict(passed=False))['passed'])
        for field, value in [('roomNotificationLossCanary', False), ('roomNotificationsDiscarded', 0),
                             ('roomProgressRecoverySignals', 0)]:
            altered = [dict(reports[0], **{field: value})]
            self.assertFalse(benchmark.room_notification_loss_proof(altered, dict(passed=True))['passed'])
        self.assertFalse(benchmark.room_notification_loss_proof([], dict(passed=True))['passed'])
        self.assertFalse(benchmark.room_notification_loss_proof(reports, dict(passed=True))['clientPersistenceProven'])


class MeasuredPhaseTests(unittest.TestCase):
    def test_scaled_phase_requires_every_report_to_complete_the_selected_window(self):
        reports = [dict(authenticated=10, peakActive=10, messagesSent=100, messagesAcknowledged=100,
                        messageTransport='tcp', messageRecoveryTransport='tcp_query',
                        messageSendNegotiatedConnections=10,
                        messageTransportEvents=dict(WIRE_SUBMIT=100, ACCEPTED=100),
                        roomEventRecordsReceived=100, scenarioDrain=dict(drained=True),
                        scenarioPhases=[dict(name='rate-1000', messagesAcknowledged=100,
                                             observedDurationSeconds=30, durationSeconds=30, completed=True,
                                             startedAtUnixMilliseconds=1000, endedAtUnixMilliseconds=31000)])
                   for _ in range(benchmark.PARTS)]
        args = (reports, [0]*benchmark.PARTS, 10*benchmark.PARTS)
        summary = benchmark.summarize(*args, measurement_phase='rate-1000')
        self.assertTrue(summary['qualityPassed'])
        self.assertEqual(summary['steadyStateCommonWindowSeconds'], 30)
        self.assertEqual(summary['acknowledgedMessagesPerSecond'], 40)
        self.assertFalse(benchmark.summarize(*args)['qualityPassed'])
        reports[-1]['scenarioPhases'] = []
        self.assertFalse(benchmark.summarize(*args, measurement_phase='rate-1000')['qualityPassed'])


class OnlineOnlySummaryTests(unittest.TestCase):
    def reports(self):
        return [dict(authenticated=10, peakActive=10, failed=0, workloadFailed=0,
            messagesSent=0, messagesAcknowledged=0, heartbeatMissed=0, onlineOnly=True,
            directRoomAttempted=0, roomEventPullsSent=0, syncPullsSent=0, plannedReconnects=0,
            scenarioDrain=dict(drained=True), scenarioPhases=[dict(name='online-idle',
                messagesAcknowledged=0, observedDurationSeconds=180, durationSeconds=180, completed=True,
                startedAtUnixMilliseconds=1000, endedAtUnixMilliseconds=181000,
                heartbeatLatency=dict(count=60))]) for _ in range(benchmark.PARTS)]

    def test_online_quality_requires_actual_heartbeats_without_message_work(self):
        reports = self.reports()
        result = benchmark.summarize(reports, [0]*benchmark.PARTS, 120,
            measurement_phase='online-idle', online_only=True)
        self.assertTrue(result['qualityPassed'])
        self.assertTrue(result['onlineOnlyVerified'])
        self.assertEqual(result['heartbeatAcknowledged'], 720)
        self.assertFalse(benchmark.summarize(reports, [0]*benchmark.PARTS, 120,
            measurement_phase='online-idle')['qualityPassed'])
        reports[0]['directRoomAttempted'] = 1
        self.assertFalse(benchmark.summarize(reports, [0]*benchmark.PARTS, 120,
            measurement_phase='online-idle', online_only=True)['qualityPassed'])

    def test_online_quality_rejects_missed_heartbeats_and_missing_phase(self):
        reports = self.reports(); reports[0]['heartbeatMissed'] = 1
        self.assertFalse(benchmark.summarize(reports, [0]*benchmark.PARTS, 120,
            measurement_phase='online-idle', online_only=True)['qualityPassed'])
        reports[0]['heartbeatMissed'] = 0; reports[0]['scenarioPhases'] = []
        self.assertFalse(benchmark.summarize(reports, [0]*benchmark.PARTS, 120,
            measurement_phase='online-idle', online_only=True)['qualityPassed'])


class AdmissionStatementCategoryTests(unittest.TestCase):
    def test_actual_sql_markers_classify_before_and_after_query_truncation(self):
        source = (Path(__file__).resolve().parents[2] / 'IMV2Server/Sources/IMV2ServerInfrastructure/RoomWrite/V2RoomWriteDurableOwnerBatchAdmission.swift').read_text()
        statements = re.findall(r'raw\("""\n(.*?)"""\)', source, re.DOTALL)
        marked = [sql for sql in statements if '/* imv2_admission_' in sql]
        self.assertEqual(len(marked), 3)
        # These are the same patterns interpolated into the actual PG CASE;
        # Python only substitutes the equivalent whitespace character class.
        patterns = benchmark.postgres_admission_statement_categories()
        for statement, (_, expected) in zip(marked, patterns):
            for text in (statement, statement[:1024]):
                matched = [category for pattern, category in patterns
                           if re.search(pattern.replace('[[:space:]]', r'\s'), text, re.I)]
                self.assertEqual(matched, [expected])
        self.assertFalse(any(re.search(pattern.replace('[[:space:]]', r'\s'),
            "SELECT '/* imv2_admission_fast_update */'", re.I) for pattern, _ in patterns))
        case = benchmark.postgres_statement_category_case('query')
        self.assertLess(case.index("THEN 'admission_fast_update'"), case.index("THEN 'admission_credit'"))
        self.assertIn(benchmark.postgres_statement_category_case('statement_text'),
                      benchmark.postgres_statement_category_probe_sql())
        sampler = benchmark.postgres_hotspot_sample_sql()
        self.assertIn(case, sampler)
        self.assertNotIn('room_activation_leases', sampler)
        self.assertNotIn('room_activation_fence', sampler)
        self.assertIn("WHEN 'rooms' THEN 'room_state_lock'", sampler)
        # CASE sees the SQL on the server; emitted JSON carries only category.
        self.assertNotIn("'query',", sampler)
        self.assertNotIn("'statement_text',", sampler)




if __name__ == '__main__':
    unittest.main()
