"""Pure metric-window counterexamples, never a workload or PostgreSQL fixture."""
import copy
import unittest
from v2_realtime_hotpath_proof import NODES, PARTS, PHASES, STAGES, SOURCES, PREFIX, PUBLISH, prove


def reports():
    return [dict(scenarioPhases=[dict(name='measured',completed=True,
        startedAtUnixMilliseconds=1000000,endedAtUnixMilliseconds=1040000)]) for _ in range(PARTS)]


def sample(at, publishes):
    lines=[f'{PUBLISH} {publishes}']
    lines += [f'{PREFIX}_sql_duration_count{{source="{source}",phase="{phase}"}} 0'
              for source in SOURCES for phase in PHASES]
    lines += [f'{PREFIX}_active{{source="{source}",stage="{stage}"}} 0'
              for source in SOURCES for stage in STAGES]
    return dict(time=at+.1,samplingStartedAtUnixSeconds=at,samplingCompletedAtUnixSeconds=at+.1,
        samples=[dict(node=node,body='\n'.join(lines),samplingStartedAtUnixSeconds=at,
                      samplingCompletedAtUnixSeconds=at+.1) for node in range(NODES)])


class HotpathProofTests(unittest.TestCase):
    def test_counter_reset_is_incomplete_even_if_total_delta_exceeds_10000(self):
        valid=[sample(1001,100),sample(1010,1100),sample(1030,2100)]
        self.assertTrue(prove(reports(),valid,'measured')['passed'])
        broken=copy.deepcopy(valid)
        broken[1]['samples'][0]['body']=broken[1]['samples'][0]['body'].replace(f'{PUBLISH} 1100',f'{PUBLISH} 99')
        result=prove(reports(),broken,'measured')
        self.assertEqual(result['status'],'incomplete')
        self.assertEqual(result['reasons'],['counter_reset'])

    def test_missing_node_or_actual_timestamps_never_borrow_setup_or_ack_counts(self):
        selected=[sample(1001,0),sample(1030,2000)]
        broken=copy.deepcopy(selected);broken[1]['samples'].pop()
        self.assertEqual(prove(reports(),broken,'measured')['reasons'],['nodes_missing'])
        legacy=copy.deepcopy(selected);legacy[0].pop('samplingStartedAtUnixSeconds')
        self.assertEqual(prove(reports(),legacy,'measured')['reasons'],['actual_sampling_timestamps_missing'])
        setup=[sample(990,0),sample(1001,2000),sample(1030,2001)]
        result=prove(reports(),setup,'measured')
        self.assertEqual(result['status'],'incomplete')
        self.assertEqual(result['reasons'],['publish_window_below_10000'])
