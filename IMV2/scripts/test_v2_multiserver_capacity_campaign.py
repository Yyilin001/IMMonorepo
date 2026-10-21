"""Campaign verdicts must include the final sustained-load assessment."""
import contextlib
import io
from itertools import product
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import run_v2_multiserver_capacity as campaign


def intact_result(passed=True):
    return dict(measurementStarted=True, passed=passed, exitCode=0,
        capacityComparable=True, remoteLifecyclePassed=True,
        messageCohort=dict(complete=True, messagesSent=100, messagesAcknowledged=100),
        businessFailures=0, missedHeartbeats=0, foreground=dict(passed=True),
        receiverVisibility=dict(passed=True),
        cleanup=dict(settled=True, forcedKillCount=0, exitFailureCount=0), failure={})


class CapacityCampaignTests(unittest.TestCase):
    def test_missing_runtime_fails_before_starting_measurement(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root/'bin').mkdir()
            with self.assertRaisesRegex(RuntimeError, 'Runtime missing executable binaries: IMV2ServerApp'):
                campaign.validate_runtime(root)

    def test_default_growth_scales_users_and_traffic_and_repeats_every_size(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root/'runtime/bin').mkdir(parents=True)
            deployment = root/'deployment.json'
            deployment.write_text(json.dumps(dict(runtime=str(root/'runtime'))))
            output = root/'campaign'
            commands = []
            def run_case(command, **kwargs):
                commands.append(command)
                directory = Path(command[command.index('--output-dir')+1])
                directory.mkdir()
                result = intact_result()
                result['acknowledgedPerSecond'] = int(command[command.index('--rate')+1])
                (directory/'assessment.json').write_text(json.dumps(result))
                return campaign.subprocess.CompletedProcess(command, 0)
            with patch.object(campaign.sys, 'argv', ['campaign', '--deployment', str(deployment),
                    '--output-dir', str(output)]), \
                 patch.object(campaign, 'local_inputs', return_value=[]), \
                     patch.object(campaign, 'validate_runtime'), \
                 patch.object(campaign, 'resource_configuration', return_value={}), \
                 patch.object(campaign.subprocess, 'run', side_effect=run_case), \
                 contextlib.redirect_stdout(io.StringIO()):
                campaign.main()
            self.assertEqual([int(c[c.index('--nodes')+1]) for c in commands], [1,2,4,8,8,4,2,1])
            for command in commands:
                n = int(command[command.index('--nodes')+1])
                self.assertEqual(int(command[command.index('--users')+1]), 1200*n)
                self.assertEqual(int(command[command.index('--rate')+1]), 150*n)
                self.assertEqual(command[command.index('--seconds')+1], '600')
                self.assertIn('--measure-visibility', command)
                self.assertNotIn('--diagnostic-observe-through-failures', command)
                self.assertNotIn('--live-scale-out-at', command)
            summary = json.loads((output/'user-growth.json').read_text())
            self.assertTrue(all(row['verified'] for row in summary['rows']))
            self.assertEqual(summary['capacityEstimateKind'], 'demonstrated_load_only')
            self.assertIsNone(summary['capacityEfficiency'])
            self.assertTrue((output/'user-growth.md').is_file())

    def test_partial_growth_report_never_promotes_failed_or_unmeasured_sizes(self):
        cases = [dict(name='one', nodes=1, exitCode=0, result=intact_result()),
                 dict(name='two', nodes=1, exitCode=1, result=intact_result(False))]
        summary = campaign.growth_summary(cases, [1,2], 2, 1200, 150)
        self.assertTrue(all(not row['verified'] for row in summary['rows']))
        self.assertTrue(all(row['demonstratedUsers'] is None for row in summary['rows']))

    def test_unused_business_vms_are_not_required_for_smaller_campaign(self):
        deployment = dict(postgres=dict(dockerContext='colima-db', container='postgres'),
            postgresManagementHost='db', processes={
                'gateway-0': dict(profile='node0'), 'gateway-1': dict(profile='node1'),
                'gateway-2': dict(profile='stopped-node2'), 'edge-2': dict(profile='stopped-edge2'),
                'account': dict(profile='account'), 'load-0': dict(profile='probe')})
        profiles = ['node0', 'node1', 'account', 'probe', 'db']
        def output(command, **kwargs):
            if command[:2] == ['colima', 'list']:
                return '\n'.join(json.dumps(dict(name=p, status='Running', cpus=1)) for p in profiles)
            if command[0] == 'docker':
                return '{}'
            if command[0] == 'psql':
                return 'fsync|on'
            if command[0] == 'colima':
                return '65536\n16384\n'
            self.fail(command)
        with patch.object(campaign.subprocess, 'check_output', side_effect=output):
            result = campaign.resource_configuration(deployment, 2)
        self.assertEqual(set(result['vms']), set(profiles))
        self.assertEqual(set(result['networkLimits']), set(profiles))
        deployment['authorityProfile'] = 'imv2-growth-authority'
        with patch.object(campaign.subprocess, 'check_output', side_effect=output):
            unchanged = campaign.resource_configuration(deployment, 2)
        self.assertNotIn('imv2-growth-authority', unchanged['vms'])
        profiles.append('imv2-growth-authority')
        with patch.object(campaign.subprocess, 'check_output', side_effect=output):
            online = campaign.resource_configuration(deployment, 2, include_authority=True)
        self.assertIn('imv2-growth-authority', online['vms'])

    def test_complete_slow_peer_delivery_is_a_performance_failure_not_lost_evidence(self):
        result = intact_result(False)
        result['receiverLatency'] = dict(passed=False, reason='p99_exceeds_limit')
        self.assertEqual(campaign.measurement_integrity_failure(result, 1), [])
        result['receiverVisibility'] = dict(passed=False)
        self.assertIn('receiver_visibility', campaign.measurement_integrity_failure(result, 1))

    def test_corrupt_observations_stop_campaign_before_capacity_search(self):
        mutations = [
            dict(remoteLifecyclePassed=False), dict(foreground=dict(passed=False)),
            dict(receiverVisibility=dict(passed=False)), dict(businessFailures=1),
            dict(messageCohort=dict(complete=True, messagesSent=100, messagesAcknowledged=99)),
            dict(cleanup=dict(settled=True, forcedKillCount=1, exitFailureCount=0)),
            dict(exitCode=1), dict(failure=dict(reason='unexpected failure')),
        ]
        for mutation in mutations:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                (root/'runtime/bin').mkdir(parents=True)
                deployment = root/'deployment.json'
                deployment.write_text(json.dumps(dict(runtime=str(root/'runtime'))))
                output = root/'campaign'
                def run_case(command, **kwargs):
                    directory = Path(command[command.index('--output-dir')+1])
                    directory.mkdir()
                    result = intact_result(False)
                    result.update(mutation)
                    (directory/'assessment.json').write_text(json.dumps(result))
                    return campaign.subprocess.CompletedProcess(command, 1)
                with patch.object(campaign.sys, 'argv', ['campaign', '--deployment', str(deployment),
                        '--output-dir', str(output), '--profile', 'throughput', '--maximum-rate', '2000', '--soak-seconds', '3600']), \
                     patch.object(campaign, 'local_inputs', return_value=[]), \
                     patch.object(campaign, 'validate_runtime'), \
                     patch.object(campaign, 'resource_configuration', return_value={}), \
                     patch.object(campaign.subprocess, 'run', side_effect=run_case), \
                     contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaisesRegex(RuntimeError, 'Measurement integrity failed'):
                        campaign.main()
                state = json.loads((output/'campaign.json').read_text())
                self.assertEqual(state['status'], 'needs_investigation')
                self.assertEqual(len(state['cases']), 1)
                self.assertEqual(state['capacity'], {})

    def test_campaign_requires_soak_and_distinguishes_capacity_bounds(self):
        for soak_passed, boundaries in product((False, True), (
            {}, {1: 1700}, {2: 1850, 4: 1850, 8: 1850},
            {1: 1700, 2: 1850, 4: 1850, 8: 1850},
        )):
            with self.subTest(soak_passed=soak_passed, boundaries=boundaries), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                runtime = root / 'runtime'
                (runtime / 'bin').mkdir(parents=True)
                deployment = root / 'deployment.json'
                deployment.write_text(json.dumps({'runtime': str(runtime)}))
                output = root / 'campaign'

                def run_case(command, **kwargs):
                    directory = Path(command[command.index('--output-dir') + 1])
                    directory.mkdir()
                    is_soak = command[command.index('--seconds') + 1] == '3600'
                    node_count = int(command[command.index('--nodes') + 1])
                    rate = int(command[command.index('--rate') + 1])
                    passed = soak_passed if is_soak else rate <= boundaries.get(node_count, 2000)
                    (directory / 'assessment.json').write_text(json.dumps(intact_result(passed)))
                    return campaign.subprocess.CompletedProcess(command, 0 if passed else 1)

                argv = ['campaign', '--deployment', str(deployment), '--output-dir', str(output),
                        '--profile', 'throughput', '--maximum-rate', '2000', '--soak-seconds', '3600']
                with patch.object(campaign.sys, 'argv', argv), \
                     patch.object(campaign, 'local_inputs', return_value=[]), \
                     patch.object(campaign, 'validate_runtime'), \
                     patch.object(campaign, 'resource_configuration', return_value={}), \
                     patch.object(campaign.subprocess, 'run', side_effect=run_case), \
                     contextlib.redirect_stdout(io.StringIO()):
                    if soak_passed:
                        campaign.main()
                    else:
                        with self.assertRaisesRegex(RuntimeError, 'Sustained-load validation failed'):
                            campaign.main()

                state = json.loads((output / 'campaign.json').read_text())
                self.assertEqual(state['soakPassed'], soak_passed)
                self.assertEqual(state['status'], 'completed' if soak_passed else 'needs_investigation')
                self.assertEqual(state['cases'][-1]['stage'], 'soak')
                self.assertEqual(state['cases'][-1]['result']['passed'], soak_passed)
                self.assertTrue(all(len(value['confirmations']) == 3
                                    for value in state['capacity'].values()))
                for node, value in state['capacity'].items():
                    bounded = int(node) in boundaries
                    self.assertEqual(value['searchCeilingReached'], not bounded)
                    self.assertEqual(value['capacityEstimateKind'], 'bracketed' if bounded else 'lower_bound')
                    self.assertGreater(value['confirmedRateRatio'], 0)
                    if bounded and 1 in boundaries:
                        self.assertIsNotNone(value['speedup'])
                        self.assertIsNotNone(value['efficiency'])
                        self.assertGreater(value['nearestFailedAbove'], value['confirmedRate'])
                    else:
                        self.assertIsNone(value['speedup'])
                        self.assertIsNone(value['efficiency'])


if __name__ == '__main__':
    unittest.main()
