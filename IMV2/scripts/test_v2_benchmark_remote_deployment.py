import copy
import unittest
from v2_benchmark_remote_process import validate_deployment


def configuration():
    def node(profile, address, dns):
        return dict(profile='imv2-growth-'+profile, host=address, managementHost=address, dns=dns+'.imv2.test')
    infra=node('infra','192.168.5.4','account')
    processes={name:dict(infra) for name in ('account','placement-a','placement-b','placement-c','edge-0','edge-1')}
    for i in range(2):
        processes[f'gateway-{i}']=node(f'node{i}',f'192.168.5.{10+i}',f'gateway-{i}')
        processes[f'load-{i}']=node('loader','192.168.5.20','loader')
    return dict(processes=processes, runtime='/private/runtime', postgresHost='192.168.5.4')


class RemoteDeploymentTests(unittest.TestCase):
    def test_independent_business_vms(self):
        validate_deployment(configuration(),2,2)

    def test_rejects_same_vm_disguised_as_two_servers(self):
        config=configuration()
        config['processes']['gateway-1']['profile']=config['processes']['gateway-0']['profile']
        with self.assertRaises(ValueError):validate_deployment(config,2,2)

    def test_rejects_loopback_business_network(self):
        config=configuration();config['processes']['gateway-0']['host']='127.0.0.1'
        with self.assertRaises(ValueError):validate_deployment(config,2,2)

    def test_account_edge_requires_local_upstream(self):
        config=configuration();config['processes']['edge-0']=copy.deepcopy(config['processes']['gateway-0'])
        with self.assertRaises(ValueError):validate_deployment(config,2,2)

    def test_loader_cannot_consume_business_vm_budget(self):
        config=configuration();config['processes']['load-0']=copy.deepcopy(config['processes']['gateway-0'])
        with self.assertRaises(ValueError):validate_deployment(config,2,2)


if __name__=='__main__':unittest.main()
