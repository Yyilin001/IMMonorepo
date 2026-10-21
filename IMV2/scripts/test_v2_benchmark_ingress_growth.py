import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from v2_benchmark_ingress_growth import admit


def metric(qualified=1):
    fields = dict(revision=3, confirmed=1, configured_hosts=4, healthy_hosts=4,
                  realtime_revision=3, realtime_qualified=qualified)
    return '\n'.join(f'im_v2_room_membership_{k} {v}' for k,v in fields.items())


class IngressGrowthTests(unittest.TestCase):
    def fixture(self, root):
        deployment = root/'deployment.json'
        deployment.write_text(json.dumps(dict(ingress=True, processes={
            f'gateway-{i}':dict(host=f'192.0.2.{i+1}') for i in range(4)})))
        (root/'ingress.json').write_text(json.dumps(dict(profile='owned-test', socket='/tmp/owned.sock')))
        return SimpleNamespace(server_deployment=deployment, gateway_port=7000)

    def test_unqualified_member_blocks_all_mutations(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);args=self.fixture(root)
            with patch('v2_benchmark_ingress_growth.gateway_metrics', side_effect=lambda _, i: metric(int(i!=3))), \
                 patch('v2_benchmark_ingress_growth.runtime_command') as command:
                with self.assertRaisesRegex(RuntimeError, 'every target'):
                    admit(args,root,[2,3],4,3)
                command.assert_not_called()

    def test_add_enable_and_verify_both_nodes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);args=self.fixture(root)
            rows=[{'# pxname':'gateways','svname':f'gateway-{i}','addr':f'192.0.2.{i+1}:{7000+i}','status':'UP'} for i in [2,3]]
            def respond(_, command):
                return 'New server registered.\n' if command.startswith('add ') else '\n'
            with patch('v2_benchmark_ingress_growth.gateway_metrics', return_value=metric()), \
                 patch('v2_benchmark_ingress_growth.capture', side_effect=[[],rows]), \
                 patch('v2_benchmark_ingress_growth.runtime_command', side_effect=respond) as command:
                result=admit(args,root,[2,3],4,3)
                self.assertEqual(result['status'],'ready')
                self.assertEqual(command.call_count,6)
                self.assertEqual(len(result['commands']),6)
                self.assertEqual(json.loads((root/'ingress-growth-r3.json').read_text())['status'],'ready')

    def test_existing_wrong_address_is_not_enabled(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);args=self.fixture(root)
            rows=[{'# pxname':'gateways','svname':'gateway-2','addr':'192.0.2.99:7002','status':'UP'}]
            with patch('v2_benchmark_ingress_growth.gateway_metrics', return_value=metric()), \
                 patch('v2_benchmark_ingress_growth.capture', return_value=rows), \
                 patch('v2_benchmark_ingress_growth.runtime_command') as command:
                with self.assertRaisesRegex(RuntimeError,'address differs'):
                    admit(args,root,[2,3],4,3)
                command.assert_not_called()
                self.assertEqual(json.loads((root/'ingress-growth-r3.json').read_text())['status'],'unconfirmed')

    def test_cli_rejection_is_not_reported_as_ready(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);args=self.fixture(root)
            with patch('v2_benchmark_ingress_growth.gateway_metrics', return_value=metric()), \
                 patch('v2_benchmark_ingress_growth.capture', return_value=[]), \
                 patch('v2_benchmark_ingress_growth.runtime_command', return_value='No such backend'):
                with self.assertRaisesRegex(RuntimeError,'rejected'):
                    admit(args,root,[2,3],4,3)
                evidence=json.loads((root/'ingress-growth-r3.json').read_text())
                self.assertEqual(evidence['status'],'unconfirmed')
                self.assertEqual(evidence['commands'][0]['response'],'No such backend')


if __name__=='__main__':unittest.main()
