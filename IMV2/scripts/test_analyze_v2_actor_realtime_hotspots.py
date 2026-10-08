"""Regression checks for incomplete performance evidence; no services required."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location(
    'hotspots', Path(__file__).with_name('analyze_v2_actor_realtime_hotspots.py'))
hotspots = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(hotspots)


class ReportCoverageTests(unittest.TestCase):
    def test_subscription_expiry_and_owner_failures_remain_distinct_counters(self):
        head = 'im_v2_room_subscription_head_delivery_total{stage="renewalAuthorityExpired"}'
        owner = 'im_v2_room_subscription_owner_failures_total{reason="catchUpRequired"}'
        baseline = hotspots.prometheus(f'{head} 2\n{owner} 3')
        current = hotspots.prometheus(f'{head} 9\n{owner} 8')
        result = hotspots.counter_summary([(2, current)], (1, baseline))
        self.assertEqual(result[head]['delta'], 7)
        self.assertEqual(result[owner]['delta'], 5)

    def test_ready_partition_quantiles_include_zero_contributions_and_exclude_missing_history(self):
        def trace(at, parts, wait=30):
            return dict(segment='room_actor', startedAtUnixMilliseconds=at,
                        durationMilliseconds=50, operations=['test-operation'],
                        spans=[dict(stage='owner_ready_wait', durationMilliseconds=wait)] +
                        [dict(stage=key, durationMilliseconds=value) for key, value in parts.items()])
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            traces = [
                trace(1100, {'ready_pool_fully_borrowed_sum': 30}),
                trace(1200, {'ready_slots_full_callback_pending_sum': 20,
                             'ready_diagnostic_history_missing_sum': 10}),
                trace(1300, {'ready_pool_fully_borrowed_sum': 10}),  # truncated evidence
                trace(1990, {'ready_pool_fully_borrowed_sum': 30}),  # crosses phase end
            ]
            (directory/'gateway-0.log').write_text('\n'.join('send_path='+json.dumps(t) for t in traces))
            result = hotspots.ready_wait_traces(directory, 1, 2)
            self.assertEqual(result['wait']['count'], 2)
            self.assertEqual(result['incompletePartitions'], 1)
            self.assertEqual(result['excludedBoundaryTraces'], 1)
            borrowed = result['categories']['ready_pool_fully_borrowed_sum']
            self.assertEqual(borrowed['meanMilliseconds'], 15)
            self.assertEqual(borrowed['p50Milliseconds'], 0)
            self.assertEqual(borrowed['p95Milliseconds'], 30)
            self.assertEqual(result['categories']['ready_diagnostic_history_missing_sum']['totalMilliseconds'], 10)
            self.assertEqual(sum(v['totalMilliseconds'] for v in result['categories'].values()), 60)

    def test_no_trace_evidence_is_not_zero_wait(self):
        with tempfile.TemporaryDirectory() as temp:
            result = hotspots.ready_wait_traces(Path(temp), 1, 2)
            self.assertEqual(result['status'], 'no_complete_slow_request_partitions')
            self.assertIsNone(result['wait']['p95Milliseconds'])

    def test_route_query_latency_excludes_admission_rejection_and_active_queries(self):
        prefix = 'im_v2_actor_realtime_route_query_'
        label = '{kind="user_presence"}'
        def sample(total, completed, started, rejected):
            return hotspots.prometheus('\n'.join([
                f'{prefix}duration_milliseconds_sum{label} {total}',
                f'{prefix}duration_milliseconds_count{label} {completed}',
                f'{prefix}started_total{label} {started}',
                f'{prefix}capacity_rejected_total{label} {rejected}',
                f'{prefix}active{label} 4']))
        result = hotspots.counter_summary([(2, sample(120, 4, 8, 12))], (1, sample(20, 2, 2, 1)))
        self.assertEqual(result[prefix + 'duration_milliseconds_sum' + label]['meanMilliseconds'], 50)
        self.assertEqual(result[prefix + 'capacity_rejected_total' + label]['delta'], 11)
        self.assertEqual(result[prefix + 'active' + label]['last'], 4)
        missing = sample(20, 2, 2, 1)
        missing.pop(prefix + 'duration_milliseconds_count' + label)
        result = hotspots.counter_summary([(2, sample(120, 4, 8, 12))], (1, missing))
        self.assertIsNone(result[prefix + 'duration_milliseconds_sum' + label]['meanMilliseconds'])

    def test_actual_loan_sources_and_sql_phases_keep_independent_populations(self):
        prefix = 'im_v2_database_loan_observation_'
        labels = [('held', '{source="group_event_pull"}'),
                  ('stage', '{source="group_event_pull",stage="awaiting_driver"}'),
                  ('sql', '{source="group_event_pull",phase="read_body"}'),
                  ('sql', '{source="group_event_pull",phase="fence"}'),
                  ('held', '{source="sync"}')]
        def sample(counts):
            lines = []
            for (part, label), count in zip(labels, counts):
                lines.extend([f'{prefix}{part}_duration_sum{label} {count * 10}',
                              f'{prefix}{part}_duration_count{label} {count}',
                              f'{prefix}{part}_duration_max{label} 900'])
            return hotspots.prometheus('\n'.join(lines))
        baseline = sample([2, 4, 8, 12, 1])
        inside = sample([5, 7, 11, 21, 1])
        result = hotspots.counter_summary([(2, inside)], (1, baseline))
        for part, label in labels[:-1]:
            self.assertEqual(result[prefix + part + '_duration_sum' + label]['meanMilliseconds'], 10)
            self.assertEqual(result[prefix + part + '_duration_max' + label]['semantics'],
                             'lifetime_high_watermark_sampled_inside_phase')
        self.assertEqual(result[prefix + 'sql_duration_count' + labels[2][1]]['delta'], 3)
        self.assertEqual(result[prefix + 'sql_duration_count' + labels[3][1]]['delta'], 9)
        self.assertIsNone(result[prefix + 'held_duration_sum' + labels[4][1]]['meanMilliseconds'])
        baseline.pop(prefix + 'sql_duration_count' + labels[2][1])
        missing = hotspots.counter_summary([(2, inside)], (1, baseline))
        self.assertIsNone(missing[prefix + 'sql_duration_sum' + labels[2][1]]['meanMilliseconds'])

    def test_competing_read_and_sync_pressure_is_not_filtered_out_or_combined(self):
        def sample(read_sum, read_count, sync_sum, sync_count, read_rejected):
            lines = ['im_v2_database_work_queued{class="foreground_write"} 0',
                     'im_v2_database_work_queued{class="interactive_read"} 384',
                     'im_v2_database_work_queued{class="sync"} 14']
            for category, total, count in [('interactive_read', read_sum, read_count),
                                           ('sync', sync_sum, sync_count)]:
                lines.extend([
                    f'im_v2_database_work_queue_wait_milliseconds_sum{{class="{category}"}} {total}',
                    f'im_v2_database_work_queue_wait_milliseconds_count{{class="{category}"}} {count}',
                ])
            if read_rejected is not None:
                lines.append(f'im_v2_database_work_rejections_total{{class="interactive_read",reason="queue_full"}} {read_rejected}')
            return hotspots.prometheus('\n'.join(lines))
        result = hotspots.counter_summary([(2, sample(120, 4, 70, 3, 5))],
                                           (1, sample(20, 2, 10, 1, 2)))
        self.assertEqual(result['im_v2_database_work_queued{class="interactive_read"}']['maximum'], 384)
        self.assertEqual(result['im_v2_database_work_queued{class="foreground_write"}']['maximum'], 0)
        self.assertEqual(result['im_v2_database_work_queue_wait_milliseconds_sum{class="interactive_read"}']['meanMilliseconds'], 50)
        self.assertEqual(result['im_v2_database_work_queue_wait_milliseconds_sum{class="sync"}']['meanMilliseconds'], 30)
        rejected = 'im_v2_database_work_rejections_total{class="interactive_read",reason="queue_full"}'
        self.assertEqual(result[rejected]['delta'], 3)
        missing = hotspots.counter_summary([(2, sample(120, 4, 70, 3, 5))],
                                            (1, sample(20, 2, 10, 1, None)))
        self.assertIsNone(missing[rejected]['delta'])

    def test_admission_subclasses_and_historical_category_remain_distinct(self):
        categories = ['admission_credit', 'admission_fast_update',
                      'admission_lock_select', 'admission_gate_update']
        row = dict(time=2, samplerVersion='pg-hotspot-v2', blocked_total=4,
                   blocked=[dict(query_category=category, requested_locks=[],
                                 blockers=[dict(query_category=category, held_locks=[
                                     dict(category='admission_credit', locks=1)])])
                            for category in categories])
        result = hotspots.postgres([row], 1, 3)['blocked']
        self.assertEqual(result['waiterCategoryObservationCounts'], dict.fromkeys(categories, 1))
        self.assertEqual(result['blockerCategoryObservationCounts'], dict.fromkeys(categories, 1))
        self.assertEqual(result['heldLockCategoryObservationCounts'], {'admission_credit': 4})

    def test_tcp_ingress_rejections_and_reserved_lifetime_peaks_remain_separate(self):
        def sample(count, bytes_):
            return hotspots.prometheus('\n'.join([
                '# TYPE im_v2_gateway_message_send_rejected_total counter',
                f'im_v2_gateway_message_send_rejected_total{{reason="connection_count"}} {count}',
                'im_v2_gateway_message_send_rejected_total{reason="process_bytes"} 0',
                f'im_v2_gateway_message_send_reserved_bytes {bytes_}',
                'im_v2_gateway_message_send_peak_reserved_bytes_lifetime 4096',
            ]))
        result = hotspots.counter_summary([(2, sample(4, 100)), (3, sample(7, 0))],
                                           (1, sample(2, 0)))
        self.assertEqual(result['im_v2_gateway_message_send_rejected_total{reason="connection_count"}']['delta'], 5)
        self.assertEqual(result['im_v2_gateway_message_send_rejected_total{reason="process_bytes"}']['delta'], 0)
        self.assertEqual(result['im_v2_gateway_message_send_reserved_bytes']['last'], 0)
        self.assertEqual(result['im_v2_gateway_message_send_peak_reserved_bytes_lifetime']['semantics'],
                         'lifetime_high_watermark_sampled_inside_phase')

    def test_event_loop_probe_deltas_do_not_turn_lifetime_max_or_missing_data_into_phase_latency(self):
        prefix = 'im_v2_gateway_event_loop_lag_milliseconds_'
        def sample(total, count, maximum):
            return hotspots.prometheus('\n'.join([
                '# TYPE im_v2_gateway_event_loop_lag_milliseconds histogram',
                f'# TYPE {prefix}max gauge',
                f'{prefix}sum {total}', f'{prefix}count {count}',
                f'{prefix}bucket{{le="500"}} {count}', f'{prefix}max {maximum}',
            ]))
        baseline = sample(20, 2, 700)
        summary = hotspots.counter_summary([(2, sample(120, 4, 700)),
                                            (3, sample(180, 6, 700))], (1, baseline))
        self.assertEqual(summary[prefix+'sum']['meanMilliseconds'], 40)
        self.assertEqual(summary[prefix+'bucket{le="500"}']['delta'], 4)
        self.assertEqual(summary[prefix+'max']['semantics'], 'lifetime_high_watermark_sampled_inside_phase')
        self.assertNotIn('delta', summary[prefix+'max'])
        missing = dict(baseline); missing.pop(prefix+'sum')
        summary = hotspots.counter_summary([(2, sample(120, 4, 700))], (1, missing))
        self.assertIsNone(summary[prefix+'sum']['meanMilliseconds'])
        self.assertTrue(summary[prefix+'sum']['missingBaselineSeries'])
        unchanged = hotspots.counter_summary([(2, baseline)], (1, baseline))
        self.assertIsNone(unchanged[prefix+'sum']['meanMilliseconds'])

    def test_sql_continuation_pairs_source_and_independent_segment_counts(self):
        prefix = 'im_v2_send_operation_sql_continuation_duration_milliseconds_'
        ready = '{source="scalar_fence_rooms",part="settled_to_resumed"}'
        dispatch = '{source="scalar_fence_rooms",part="resumed_to_dispatch"}'
        def sample(total, first_count, next_count):
            return hotspots.prometheus('\n'.join([
                f'{prefix}sum{ready} {total}', f'{prefix}count{ready} {first_count}',
                f'{prefix}sum{dispatch} {total}', f'{prefix}count{dispatch} {next_count}',
                f'{prefix}max{ready} 700',
            ]))
        result = hotspots.counter_summary([(2, sample(120, 4, 2))], (1, sample(20, 2, 1)))
        self.assertEqual(result[prefix+'sum'+ready]['meanMilliseconds'], 50)
        self.assertEqual(result[prefix+'sum'+dispatch]['meanMilliseconds'], 100)
        self.assertIn('completed_sql_continuation_segment_delta', result[prefix+'sum'+ready]['meanScope'])
        self.assertEqual(result[prefix+'max'+ready]['semantics'], 'lifetime_high_watermark_sampled_inside_phase')
        missing = sample(20, 2, 1); missing.pop(prefix+'count'+dispatch)
        result = hotspots.counter_summary([(2, sample(120, 4, 2))], (1, missing))
        self.assertIsNone(result[prefix+'sum'+dispatch]['meanMilliseconds'])

    def test_host_cpu_excludes_intervals_crossing_phase_boundary(self):
        rows = [dict(time=2, cpuIntervalStartedAt=0, cpuPercent=dict(idle=90)),
                dict(time=4, cpuIntervalStartedAt=2, cpuPercent=dict(idle=80),
                     swapUsage=dict(returnCode=0, output='raw swap snapshot')),
                dict(time=7, cpuIntervalStartedAt=4, cpuPercent=dict(idle=70))]
        result = hotspots.host_resources(rows, 1, 6)
        self.assertEqual(result['cpuIntervals'], [dict(startedAt=2, endedAt=4, percent=dict(idle=80))])
        self.assertEqual(len(result['snapshots']), 2)
        self.assertNotIn('cpuPercent', result['snapshots'][0])
        self.assertEqual(result['snapshots'][1]['swapUsage']['output'], 'raw swap snapshot')
        self.assertEqual(hotspots.host_resources([], 1, 6)['status'], 'missing_inside_samples')

    def test_declared_room_count_gauge_preserves_actual_cohort_watermark(self):
        name = 'im_v2_send_operation_owner_largest_room_count'
        def sample(value):
            return hotspots.prometheus(f'# TYPE {name} gauge\n{name} {value}\n')
        summary = hotspots.counter_summary([(2, sample(49)), (3, sample(56))], (1, sample(20)))
        self.assertEqual(summary[name]['kind'], 'gauge')
        self.assertEqual(summary[name]['minimum'], 49)
        self.assertEqual(summary[name]['maximum'], 56)
        self.assertNotIn('delta', summary[name])
        self.assertEqual(summary[name]['semantics'], 'lifetime_high_watermark_sampled_inside_phase')

    def test_stage_durations_pair_exact_labels_and_preserve_lifetime_max(self):
        def sample(body, count):
            return hotspots.prometheus('\n'.join([
                '# TYPE im_v2_send_operation_stage_duration_milliseconds_sum counter',
                '# TYPE im_v2_send_operation_stage_completed_total counter',
                '# TYPE im_v2_send_operation_stage_duration_milliseconds_max gauge',
                f'im_v2_send_operation_stage_duration_milliseconds_sum{{stage="owner_body"}} {body}',
                f'im_v2_send_operation_stage_completed_total{{stage="owner_body"}} {count}',
                'im_v2_send_operation_stage_duration_milliseconds_sum{stage="owner_commit"} 0',
                'im_v2_send_operation_stage_completed_total{stage="owner_commit"} 0',
                'im_v2_send_operation_stage_duration_milliseconds_max{stage="owner_body"} 900',
            ]))
        summary = hotspots.counter_summary([(2, sample(100, 2)), (3, sample(240, 4))],
                                           (1, sample(40, 1)))
        body = summary['im_v2_send_operation_stage_duration_milliseconds_sum{stage="owner_body"}']
        self.assertAlmostEqual(body['meanMilliseconds'], 200/3)
        self.assertIsNone(summary['im_v2_send_operation_stage_duration_milliseconds_sum{stage="owner_commit"}']['meanMilliseconds'])
        self.assertEqual(summary['im_v2_send_operation_stage_duration_milliseconds_max{stage="owner_body"}']['semantics'],
                         'lifetime_high_watermark_sampled_inside_phase')

    def test_handoff_pairs_exact_path_and_part_and_preserves_lifetime_max(self):
        prefix = 'im_v2_send_operation_admission_handoff_duration_milliseconds_'
        ready = '{path="single_success",part="result_ready_to_validated"}'
        dispatch = '{path="single_success",part="validated_to_commit_dispatch"}'
        absent = '{path="single_fallback",part="result_ready_to_validated"}'
        def sample(total, count):
            return hotspots.prometheus('\n'.join([
                f'# TYPE {prefix}sum counter', f'# TYPE {prefix}count counter',
                f'# TYPE {prefix}max gauge',
                f'{prefix}sum{ready} {total}', f'{prefix}count{ready} {count}',
                f'{prefix}max{ready} 90',
                f'{prefix}sum{dispatch} {total * 2}', f'{prefix}count{dispatch} {count}',
                f'{prefix}sum{absent} 100',
            ]))
        summary = hotspots.counter_summary([(2, sample(120, 4))], (1, sample(20, 2)))
        self.assertEqual(summary[prefix+'sum'+ready]['meanMilliseconds'], 50)
        self.assertEqual(summary[prefix+'sum'+dispatch]['meanMilliseconds'], 100)
        self.assertIsNone(summary[prefix+'sum'+absent]['meanMilliseconds'])
        self.assertEqual(summary[prefix+'max'+ready]['semantics'],
                         'lifetime_high_watermark_sampled_inside_phase')
        self.assertNotIn('delta', summary[prefix+'max'+ready])

    def test_preparation_queue_remains_separate_from_owner_write_occupancy(self):
        def sample(total, count):
            return hotspots.prometheus('\n'.join([
                '# TYPE im_v2_send_preparation_queue_wait_milliseconds_sum counter',
                '# TYPE im_v2_send_preparation_queue_wait_milliseconds_count counter',
                f'im_v2_send_preparation_queue_wait_milliseconds_sum {total}',
                f'im_v2_send_preparation_queue_wait_milliseconds_count {count}',
                'im_v2_send_preparation_in_flight 3',
                'im_v2_send_preparation_queued 11',
                'im_v2_database_work_in_flight{class="foreground_write"} 1',
                'im_v2_database_work_in_flight{class="sync"} 9',
            ]))
        summary = hotspots.counter_summary([(2, sample(120, 4))], (1, sample(20, 2)))
        self.assertEqual(summary['im_v2_send_preparation_in_flight']['last'], 3)
        self.assertEqual(summary['im_v2_send_preparation_queued']['last'], 11)
        self.assertEqual(summary['im_v2_database_work_in_flight{class="foreground_write"}']['last'], 1)
        self.assertEqual(summary['im_v2_database_work_in_flight{class="sync"}']['last'], 9)
        self.assertEqual(summary['im_v2_send_preparation_queue_wait_milliseconds_sum']['meanMilliseconds'], 50)

    def analyze_fixture(self, indices, expected=None, missing_phase=None):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = root/'candidate'
            directory.mkdir()
            if expected is not None:
                (root/'evidence.json').write_text(json.dumps({'loaderPartitions': expected}))
            for index in indices:
                phases = [] if index == missing_phase else [{
                    'name': 'rate-5000', 'startedAtUnixMilliseconds': 1000+index,
                    'endedAtUnixMilliseconds': 11000-index}]
                (directory/f'report-{index}.json').write_text(json.dumps({'scenarioPhases': phases}))
            for stream in ('gateway-metrics', 'postgres-metrics', 'process-resources'):
                (directory/(stream+'.jsonl')).write_text('')
            return hotspots.analyze(directory, ['rate-5000'])

    def test_missing_reports_remain_missing_even_with_valid_observed_phases(self):
        run = self.analyze_fixture([0, 2], expected=4)
        self.assertFalse(run['reportSetComplete'])
        self.assertEqual(run['missingReportNames'], ['report-1.json', 'report-3.json'])
        self.assertEqual(run['phases']['rate-5000']['missingShardPhaseCount'], 2)
        self.assertEqual(run['phases']['rate-5000']['startedAt'], 1.002)
        self.assertIn('missing_report:report-1.json', run['missing'])

    def test_complete_reports_do_not_hide_a_missing_phase(self):
        run = self.analyze_fixture([0, 1, 2, 3], expected=4, missing_phase=2)
        self.assertTrue(run['reportSetComplete'])
        self.assertEqual(run['missingReportNames'], [])
        self.assertEqual(run['phases']['rate-5000']['missingShardPhaseCount'], 1)

    def test_absent_manifest_does_not_assume_complete_report_set(self):
        run = self.analyze_fixture([0, 2])
        self.assertIsNone(run['expectedReports'])
        self.assertIsNone(run['reportSetComplete'])
        self.assertEqual(run['phases']['rate-5000']['phaseCoverageScope'], 'observed_reports_only')


if __name__ == '__main__':
    unittest.main()
