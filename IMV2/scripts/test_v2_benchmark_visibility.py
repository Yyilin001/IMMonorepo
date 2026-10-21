import copy
import contextlib
import io
import json
from pathlib import Path
import tempfile
import sys
from unittest.mock import patch
import run_v2_actor_realtime_benchmark as benchmark
from test_v2_benchmark_remote_deployment import configuration
import unittest
import uuid
from v2_benchmark_visibility import summarize_visibility


class VisibilityEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.run, self.clock = str(uuid.uuid4()), str(uuid.uuid4())
        self.report = dict(messageSendCohorts={'measured': dict(messagesSent=100, messagesAcknowledged=100)},
            receiverVisibility=dict(enabled=True, runID=self.run, clockDomain=self.clock, events={},
                cohorts={'measured': dict(count=100, maximum=12, histogramBuckets=[dict(lowerBoundMilliseconds=12, count=100)])}))

    def test_complete_counts_are_merged_across_receivers(self):
        result = summarize_visibility([self.report, self.report], 'measured', self.run)
        self.assertTrue(result['passed'])
        self.assertEqual(result['latency']['count'], 200)
        self.assertEqual(result['latency']['p99'], 12)

    def test_staggered_cohorts_merge_different_counts_without_losing_peer_bodies(self):
        late = copy.deepcopy(self.report)
        late['messageSendCohorts']['measured'].update(messagesSent=20, messagesAcknowledged=20)
        late['receiverVisibility']['cohorts']['measured'].update(count=20)
        late['receiverVisibility']['cohorts']['measured']['histogramBuckets'][0]['count'] = 20
        result = summarize_visibility([self.report, late], 'measured', self.run)
        self.assertTrue(result['passed'])
        self.assertEqual(result['observedPeerApplications'], 120)
        late['receiverVisibility']['cohorts']['measured']['count'] = 19
        late['receiverVisibility']['cohorts']['measured']['histogramBuckets'][0]['count'] = 19
        incomplete = summarize_visibility([self.report, late], 'measured', self.run)
        self.assertFalse(incomplete['passed'])
        self.assertIsNone(incomplete['latency'])

    def test_missing_peer_bodies_do_not_produce_an_authoritative_percentile(self):
        changed = copy.deepcopy(self.report)
        changed['receiverVisibility']['cohorts']['measured']['count'] = 99
        changed['receiverVisibility']['cohorts']['measured']['histogramBuckets'][0]['count'] = 99
        result = summarize_visibility([changed], 'measured', self.run)
        self.assertFalse(result['passed'])
        self.assertIsNone(result['latency'])
        self.assertEqual(result['partialLatency']['count'], 99)

    def test_mixed_clock_domains_or_run_ids_are_rejected(self):
        for field in ('clockDomain', 'runID'):
            changed = copy.deepcopy(self.report)
            changed['receiverVisibility'][field] = str(uuid.uuid4())
            self.assertFalse(summarize_visibility([self.report, changed], 'measured', self.run)['passed'])

    def test_overflow_and_unknown_clock_samples_are_not_hidden(self):
        for event in ('capacityExceeded', 'foreignClock', 'conflictingBody', 'invalidClockSamples', 'unknownCohort'):
            changed = copy.deepcopy(self.report)
            changed['receiverVisibility']['events'][event] = 1
            self.assertFalse(summarize_visibility([changed], 'measured', self.run)['passed'])
        self.assertFalse(summarize_visibility([{}], 'measured', self.run)['passed'])



class FixtureValidationReached(RuntimeError):
    pass


class GrowthVisibilityPreflightTests(unittest.TestCase):
    def setUp(self):
        self.previous = benchmark.NODES, benchmark.PARTS, benchmark.LOADER_LOCAL_PORT_COUNT

    def tearDown(self):
        benchmark.NODES, benchmark.PARTS, benchmark.LOADER_LOCAL_PORT_COUNT = self.previous

    def preflight(self, root, *, mixed_clocks=False, live_growth=True):
        config = configuration()
        processes = config['processes']
        for i in range(2, 8):
            processes[f'gateway-{i}'] = dict(processes['gateway-0'],
                profile=f'imv2-growth-node{i}', host=f'192.168.5.{10+i}',
                managementHost=f'192.168.5.{10+i}', dns=f'gateway-{i}.imv2.test')
            processes[f'load-{i}'] = dict(processes['load-0'])
        for role in ['membership-controller', 'placement-controller', 'ingress']:
            processes[role] = dict(processes['account'])
        config['ingress'] = dict(enabled=True)
        if live_growth:
            config['authorityProfile'] = 'imv2-growth-authority'
        if mixed_clocks:
            processes['load-7']['profile'] = 'imv2-growth-another-loader'
        deployment = root/'deployment.json'
        deployment.write_text(json.dumps(config))
        scenario = root/'scenario.json'
        scenario.write_text(json.dumps(dict(phases=[dict(name='measured', durationSeconds=1500, messagesPerSecond=100)])))
        argv = ['benchmark', '--kind', 'candidate', '--fixture', str(root/'fixture'),
            '--output-dir', str(root/'output'), '--scenario', str(scenario),
            '--server-deployment', str(deployment), '--shared-postgres',
            '--allow-scaled-diagnostic', '--nodes', '1', '--loader-partitions', '8',
            '--dynamic-membership',
            '--visibility-run-id', str(uuid.uuid4()), '--candidate-binary', str(root/'gateway'),
            '--candidate-account-binary', str(root/'account'), '--loader-binary', str(root/'loader')]
        if live_growth:
            argv += ['--continuous-user-growth', '--live-scale-out-at', '300']
        with patch.object(sys, 'argv', argv), \
             patch.object(benchmark.shutil, 'which', return_value='/usr/bin/psql'), \
             patch.object(benchmark, 'verify_fixture', side_effect=FixtureValidationReached):
            benchmark.main()

    def test_online_growth_accepts_peer_visibility_with_one_shared_loader_clock(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaises(FixtureValidationReached):
                self.preflight(Path(temporary))

    def test_fixed_membership_visibility_does_not_require_an_offline_signer(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaises(FixtureValidationReached):
                self.preflight(Path(temporary), live_growth=False)

    def test_online_growth_still_rejects_mixed_loader_clocks(self):
        with tempfile.TemporaryDirectory() as temporary, contextlib.redirect_stderr(io.StringIO()) as errors:
            with self.assertRaises(SystemExit) as stopped:
                self.preflight(Path(temporary), mixed_clocks=True)
            self.assertEqual(stopped.exception.code, 2)
            self.assertIn('one shared Linux loader clock', errors.getvalue())


if __name__ == '__main__':
    unittest.main()
