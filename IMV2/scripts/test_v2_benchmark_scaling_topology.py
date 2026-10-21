import unittest
import uuid
from types import SimpleNamespace
import run_v2_actor_realtime_benchmark as benchmark
from v2_benchmark_container_process import role_for, specification
from run_v2_horizontal_scaling import extract_result, scaling_rows
from prepare_v2_room_actor_configuration import logical_ids


class ScalingTopologyTests(unittest.TestCase):
    def test_repeatable_logical_identity_is_independent_of_argument_order_and_endpoints(self):
        seed=uuid.UUID('cc50ac35-0881-4366-9502-08f8bb6c118a')
        first=logical_ids(['gateway-0','gateway-1'], 'host', seed)
        self.assertEqual(first,logical_ids(['gateway-1','gateway-0'], 'host', seed))
        self.assertEqual(first['gateway-0'],logical_ids(['gateway-0','gateway-1','gateway-2'], 'host', seed)['gateway-0'])
        self.assertNotEqual(first,logical_ids(first, 'host', uuid.uuid4()))
        self.assertNotEqual(first,logical_ids(first, 'voter', seed))
        self.assertNotEqual(logical_ids(first, 'host'),logical_ids(first, 'host'))
    def tearDown(self): benchmark.configure_topology(6, 12)
    def test_fixed_loader_population_scales_only_the_servers(self):
        for nodes, ranges in [(1,40000),(2,20000),(4,10000)]:
            benchmark.configure_topology(nodes,4)
            self.assertEqual(benchmark.NODES,nodes)
            self.assertEqual(benchmark.PARTS,4)
            self.assertEqual(benchmark.LOADER_LOCAL_PORT_COUNT,ranges)
    def test_rejects_overlapping_or_unrepresentable_source_ranges(self):
        for nodes,parts in [(1,12),(4,6),(4,2),(3,6)]:
            with self.assertRaises(ValueError): benchmark.configure_topology(nodes,parts)
    def test_remote_automatic_ports_allow_fixed_eight_loaders_for_all_sizes(self):
        for nodes in (1,2,4,8):
            benchmark.configure_topology(nodes,8,automatic_source_ports=True)
            self.assertEqual((benchmark.NODES,benchmark.PARTS),(nodes,8))
        with self.assertRaises(ValueError): benchmark.configure_topology(1,8)
        with self.assertRaises(ValueError): benchmark.configure_topology(4,6,automatic_source_ports=True)
    def test_shared_ingress_tuples_are_included_in_remote_drain_audit(self):
        rows = '\n'.join(f'0: 030500C0:88B8 0C0500C0:{port:04X} 06' for port in (20000,20032,21000))
        self.assertEqual(benchmark.count_workload_tcp_tuples(rows,20000,system='Linux',all_source_ports=True),1)
        self.assertEqual(benchmark.count_workload_tcp_tuples(rows,20000,system='Linux',all_source_ports=True,
            additional_destination_ports=(20032,)),2)
    def test_each_gateway_keeps_the_same_budget_and_its_own_cpu(self):
        config=dict(image='test',runID='scale',familyID='family',networkContainer='controller',mounts=[],
            gatewayCPUs=[0,1,2,3],roles={'gateway':dict(cpuset='',cpus=1,memoryBytes=3*1024**3)})
        for ordinal in range(4):
            spec=specification(config,'gateway-'+str(ordinal),['/binary'],{'EXAMPLE':'private'})
            self.assertEqual(spec['HostConfig']['CpusetCpus'],str(ordinal))
            self.assertEqual(spec['HostConfig']['NanoCpus'],10**9)
            self.assertEqual(spec['HostConfig']['Memory'],3*1024**3)
        self.assertEqual(role_for('load-3'),('loader',None))
        self.assertEqual(role_for('edge-2'),('edge',2))
        self.assertEqual(role_for('account'),('infrastructure',None))


class ScalingAcceptanceTests(unittest.TestCase):
    def test_latency_needs_complete_ack_and_actual_delivery_and_clean_shutdown(self):
        raw=dict(qualityPassed=True,heartbeatMissed=0,
            measurementMessageCohort=dict(complete=True),
            measurementLatency=dict(messageEndToEndLatency=dict(count=100,p99UpperBoundExclusiveMilliseconds=400)),
            foregroundDelivery=dict(passed=True))
        cleanup=dict(settled=True,forcedKillCount=0,exitFailureCount=0)
        self.assertTrue(extract_result(raw,cleanup,1,500,0)['passed'])
        for upper in (None,501):
            raw['measurementLatency']['messageEndToEndLatency']['p99UpperBoundExclusiveMilliseconds']=upper
            self.assertFalse(extract_result(raw,cleanup,1,500,0)['passed'])
        raw['measurementLatency']['messageEndToEndLatency']['p99UpperBoundExclusiveMilliseconds']=400
        raw['measurementMessageCohort']['complete']=False
        self.assertFalse(extract_result(raw,cleanup,1,500,0)['passed'])
        raw['measurementMessageCohort']['complete']=True
        cleanup['forcedKillCount']=1
        self.assertFalse(extract_result(raw,cleanup,1,500,0)['passed'])
    def test_failure_is_an_upper_bound_never_capacity(self):
        rows=scaling_rows([dict(nodes=n,targetRate=r,passed=p) for n,r,p in
            [(1,1000,True),(1,1500,False),(2,2000,True),(4,3000,True),(4,4000,False)]])
        self.assertEqual(rows[0]['firstFailingNominalRate'],1500)
        setup=dict(nodes=1,targetRate=500,passed=False,measurementStarted=False)
        self.assertIsNone(scaling_rows([setup])[0]['firstFailingNominalRate'])
        self.assertEqual(rows[1]['measuredSpeedup'],2)
        self.assertEqual(rows[2]['scalingEfficiency'],.75)


if __name__ == '__main__': unittest.main()
