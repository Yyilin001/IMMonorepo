import json
from pathlib import Path
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from v2_benchmark_user_growth import LiveUserGrowth, partition_cohorts, cohort_quality


class UserGrowthTests(unittest.TestCase):
    def test_partition_preserves_identity_and_foreground_pairs(self):
        lines=[json.dumps(dict(userID=str(i),targetRoomIDs=[str(i//2),'shared-secondary']))+'\n' for i in range(16)]
        parts=partition_cohorts(lines,4)
        self.assertEqual([len(p) for p in parts],[4]*4)
        self.assertEqual(sorted(sum(parts,[])),sorted(lines))
        early={json.loads(l)['targetRoomIDs'][0] for p in parts[:2] for l in p}
        late={json.loads(l)['targetRoomIDs'][0] for p in parts[2:] for l in p}
        self.assertFalse(early & late)
        bad=list(lines);bad[8]=json.dumps(dict(userID='8',targetRoomIDs=['0']))+'\n'
        with self.assertRaisesRegex(ValueError,'disjoint'):partition_cohorts(bad,4)
        with self.assertRaises(ValueError):partition_cohorts(lines,3)

    def fixture(self,root):
        scenario=root/'scenario.json'
        scenario.write_text(json.dumps(dict(phases=[dict(name='warmup',durationSeconds=30),dict(name='settle',durationSeconds=10),dict(name='measured',durationSeconds=420,messagesPerSecond=200)])))
        args=SimpleNamespace(scenario=scenario,measurement_phase='measured',growth_measurement_seconds=120)
        return LiveUserGrowth(args,root,[2,2,2,2])

    def test_growth_waits_for_expansion_and_requires_real_distribution(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);growth=self.fixture(root)
            expansion=SimpleNamespace(done=False,new_indices=[2,3],target_count=4,final_revision=3)
            process=lambda:SimpleNamespace(poll=lambda:None)
            loaders=[process(),process()];spawned=[]
            def spawn(command,name):spawned.append(name);return process()
            with patch('v2_benchmark_user_growth.admit',return_value=dict(status='ready')) as admit:
                growth.step(time.time()-160,expansion,lambda i,c:['loader',str(i)],spawn,loaders)
                admit.assert_not_called();self.assertEqual(spawned,[])
                expansion.done=True
                growth.step(time.time()-160,expansion,lambda i,c:['loader',str(i)],spawn,loaders)
                self.assertEqual(spawned,['load-2','load-3']);self.assertEqual(len(loaders),4)
                self.assertFalse(growth.released)
                for i in [2,3]:(root/f'part-{i}-ready.json').write_text(json.dumps(dict(activeConnections=2,requestedConnections=2)))
                counts={0:4,1:2,2:2,3:0}
                with patch('v2_benchmark_user_growth.gateway_metrics',side_effect=lambda _,i:f'im_v2_gateway_active_connections {counts[i]}'), \
                     patch('v2_benchmark_user_growth.capture',return_value=[{'# pxname':'gateways','svname':f'gateway-{i}','scur':'2'} for i in range(4)]):
                    with self.assertRaisesRegex(RuntimeError,'not active across'):
                        growth.step(time.time()-160,expansion,lambda *_:None,spawn,loaders)
                    self.assertFalse(growth.barrier_path.exists())
                    counts.update({0:2,3:2})
                    with self.assertRaisesRegex(RuntimeError,'insufficient'):
                        growth.step(time.time()-400,expansion,lambda *_:None,spawn,loaders)
                    self.assertFalse(growth.barrier_path.exists())
                    growth.step(time.time()-160,expansion,lambda *_:None,spawn,loaders)
                    self.assertTrue(growth.released);self.assertTrue(growth.barrier_path.exists())
                    self.assertEqual(growth.evidence['authenticatedConnectionsByGateway'],counts)
                self.assertEqual(admit.call_count,1)

    def test_each_cohort_has_its_own_rate_and_latency_gate(self):
        reports=[dict(scenarioPhases=[dict(name='measured',messagesAcknowledged=100,observedDurationSeconds=1,completed=True)],
                      messageSendCohorts=dict(measured=dict(messagesSent=100,messagesAcknowledged=100,
                          messageEndToEndLatency=dict(count=100,p99UpperBoundExclusiveMilliseconds=bound)))) for bound in (20,900)]
        merge=lambda snapshots:snapshots[0]
        self.assertTrue(cohort_quality(reports,[0],'measured',100,merge)['passed'])
        self.assertFalse(cohort_quality(reports,[1],'measured',100,merge)['passed'])
        self.assertFalse(cohort_quality(reports,[0],'measured',200,merge)['passed'])
        self.assertFalse(cohort_quality(reports,[2],'measured',100,merge)['passed'])

    def test_finish_rejects_bad_added_cohort_even_when_aggregate_passes(self):
        with tempfile.TemporaryDirectory() as temporary:
            growth=self.fixture(Path(temporary));growth.released=True
            reports=[dict(scenarioPhases=[dict(name='measured',messagesAcknowledged=100,observedDurationSeconds=1,completed=True)],
                          messageSendCohorts=dict(measured=dict(messagesSent=100,messagesAcknowledged=100,
                              messageEndToEndLatency=dict(count=100,bound=bound)))) for bound in (20,20,900,900)]
            merge=lambda values:dict(count=sum(v['count'] for v in values),
                                     p99UpperBoundExclusiveMilliseconds=max(v['bound'] for v in values))
            report=dict(qualityPassed=True,steadyStateCommonWindowSeconds=120,measurementMessageCohort={},measurementLatency={})
            result=growth.finish(report,reports,merge)
            self.assertTrue(result['cohortQuality']['initial']['passed'])
            self.assertFalse(result['cohortQuality']['added']['passed'])
            self.assertFalse(result['passed'])

    def test_short_overlap_cannot_pass(self):
        with tempfile.TemporaryDirectory() as temporary:
            growth=self.fixture(Path(temporary));growth.released=True
            report=dict(qualityPassed=True,steadyStateCommonWindowSeconds=20,measurementMessageCohort={},measurementLatency={})
            self.assertFalse(growth.finish(report,[],lambda _:None)['passed'])


if __name__=='__main__':unittest.main()
