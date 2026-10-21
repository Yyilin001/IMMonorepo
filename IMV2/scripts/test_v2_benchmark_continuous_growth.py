import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from v2_benchmark_continuous_growth import ContinuousUserGrowth, partition_continuous_cohorts, cohort_duration


class ContinuousGrowthTests(unittest.TestCase):
    def test_partition_preserves_pairs_and_every_user_once(self):
        lines=[json.dumps(dict(userID=str(i),targetRoomIDs=[str(i//2),'secondary'])) for i in range(32)]
        parts=partition_continuous_cohorts(lines,8)
        self.assertEqual([len(p) for p in parts],[4]*8)
        self.assertEqual(sum(parts,[]),lines)
        lines[4]=json.dumps(dict(userID='4',targetRoomIDs=['0']))
        with self.assertRaisesRegex(ValueError,'share foreground'):partition_continuous_cohorts(lines,8)
        with self.assertRaises(ValueError):partition_continuous_cohorts(lines,4)

    def test_duration_reserves_connection_time_and_rejects_short_overlap(self):
        scenario=dict(phases=[dict(name='warmup',durationSeconds=10),dict(name='measured',durationSeconds=2000)])
        self.assertEqual(cohort_duration(scenario,'measured',120,[2000,1700],100),1410)
        with self.assertRaises(RuntimeError):cohort_duration(scenario,'measured',120,[200],100)

    def fixture(self,root):
        scenario=root/'scenario.json'
        scenario.write_text(json.dumps(dict(phases=[dict(name='warmup',durationSeconds=10),
            dict(name='measured',durationSeconds=2000,messagesPerSecond=10)])))
        args=SimpleNamespace(nodes=1,scenario=scenario,measurement_phase='measured',growth_measurement_seconds=120,
                             output_dir=root,live_scale_out_at=45)
        def expansion(args,actors,directory,manifest,binary,initial_membership=None):
            initial=args.nodes;target=initial*2;revision=initial_membership['revision'] if initial_membership else 1
            record=dict(revision=revision+2,current=[f'gateway-{i}' for i in range(target)])
            (directory/'membership-final-receipt.json').write_text(json.dumps(dict(membership=record)))
            (directory/'live-expansion.json').write_text(json.dumps(dict(completed=True,targetNodes=target)))
            return SimpleNamespace(done=True,initial_count=initial,target_count=target,new_indices=tuple(range(initial,target)),
                directory=directory,expanded=directory/'expanded',initial_revision=revision,final_revision=revision+2,
                step=lambda *_:None)
        initial=expansion(args,root,root,{},None)
        growth=ContinuousUserGrowth(args,root,[4]*8,initial,{},None)
        return growth,expansion

    def test_three_stages_keep_loaders_and_advance_certified_revisions(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);growth,factory=self.fixture(root);clock=[100.0];spawned=[]
            process=lambda:SimpleNamespace(poll=lambda:None)
            loaders=[process()]
            def spawn(command,name):spawned.append(name);return process()
            with patch('v2_benchmark_continuous_growth.time.time',side_effect=lambda:clock[0]), \
                 patch('v2_benchmark_continuous_growth.LiveExpansion',side_effect=factory), \
                 patch('v2_benchmark_continuous_growth.admit',return_value=dict(status='ready')) as admission, \
                 patch('v2_benchmark_continuous_growth.gateway_metrics',return_value='im_v2_gateway_active_connections 4'), \
                 patch('v2_benchmark_continuous_growth.capture',side_effect=lambda *_:[{'# pxname':'gateways','svname':f'gateway-{i}','scur':'4'} for i in range(8)]):
                for stage,indices in enumerate([(1,),(2,3),(4,5,6,7)],1):
                    growth.step(100,lambda i,c:['loader',str(i)],spawn,loaders,lambda *_:None)
                    self.assertEqual(growth.stage,stage)
                    self.assertEqual(len(loaders),2**stage)
                    self.assertFalse(growth.released)
                    for i in indices:(root/f'part-{i}-ready.json').write_text(json.dumps(dict(activeConnections=4,requestedConnections=4)))
                    clock[0]+=30
                    growth.step(100,lambda *_:None,spawn,loaders,lambda *_:None)
                    self.assertTrue(growth.released)
                    for i in indices:self.assertTrue(growth.paths_for(i)[1].exists())
                    clock[0]=growth.next_stage_at+1
                self.assertEqual([call.args[-1] for call in admission.call_args_list],[3,5,7])
                self.assertEqual(spawned,[f'load-{i}' for i in range(1,8)])
                self.assertTrue((root/'first-stage-live-expansion.json').exists())
                reports=[dict(scenarioPhases=[dict(name='measured',completed=True,messagesAcknowledged=10,observedDurationSeconds=1)],
                    messageSendCohorts=dict(measured=dict(messagesSent=10,messagesAcknowledged=10,
                        messageEndToEndLatency=dict(count=10)))) for _ in range(8)]
                result=dict(qualityPassed=True,steadyStateCommonWindowSeconds=120)
                merge=lambda rows:dict(count=sum(r['count'] for r in rows),p99UpperBoundExclusiveMilliseconds=20)
                self.assertTrue(growth.finish(result,reports,merge)['passed'])
                summary=json.loads((root/'live-expansion.json').read_text())
                self.assertEqual((summary['initialNodes'],summary['targetNodes'],summary['finalRevision']),(1,8,7))

    def test_exited_prior_cohort_blocks_next_expansion(self):
        with tempfile.TemporaryDirectory() as temporary:
            growth,_=self.fixture(Path(temporary));growth.released=True;growth.next_stage_at=0;growth.ends={0:2000}
            with patch('v2_benchmark_continuous_growth.LiveExpansion') as create:
                with self.assertRaisesRegex(RuntimeError,'exited'):
                    growth.step(100,None,None,[SimpleNamespace(poll=lambda:0)],None)
                create.assert_not_called()


if __name__=='__main__':unittest.main()
