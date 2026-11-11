import unittest
import json
import tempfile
from pathlib import Path
from benchmark_lists import compare, metrics_from_reports, expected_scenarios, read_stream_reports


class ListBenchmarkReportTests(unittest.TestCase):
    def report(self, value=10):
        return {'baselineEligible': True, 'environment': {'serial': 'fixed-device'},
                'metrics': {'scroll': {'frameDurationCpuMs.P95': value}}}

    def test_complete_reports_require_duration_not_just_trace_count(self):
        cases = []
        for kind, count in [('conversations', 1000), ('conversations', 10000), ('messages', 10000), ('messages', 100000)]:
            for test in ['coldLoad', 'scrollAndPage', 'batchUpdate']:
                metrics = {'timeToInitialDisplayMs': {'median': 50}, 'IM.List.loadSumMs': {'median': 75}} if test == 'coldLoad' else {}
                if test == 'batchUpdate':
                    metrics = {'IM.List.updateCount': {'median': 1}, 'IM.List.updateSumMs': {'median': 20}}
                cases.append({'name': f'{test}[{kind}_{count:,}]', 'metrics': metrics,
                              'sampledMetrics': {} if test == 'coldLoad' else {'frameDurationCpuMs': {'P95': 10, 'P99': 12}}})
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'benchmarkData.json'
            path.write_text(json.dumps({'benchmarks': cases}))
            result = metrics_from_reports([path])
            self.assertEqual(12, len(result))
            self.assertFalse(any('Count' in metric for values in result.values() for metric in values))
            cases[2]['metrics']['IM.List.updateSumMs']['median'] = 0
            path.write_text(json.dumps({'benchmarks': cases}))
            with self.assertRaises(ValueError):
                metrics_from_reports([path])

    def stream_fixture(self, directory):
        paths = []
        for kind, count in [('conversations', 1000), ('conversations', 10000), ('messages', 10000), ('messages', 100000)]:
            for mode in ['follow', 'scroll']:
                row = dict(kind=kind, count=count, mode=mode, rate=1000, seconds=5, expected=5000,
                           committed=5000, published=5000, finalRowCount=count + 5000, withinWindow=5000,
                           achievedMsgPerSecond=1000, targetMet=True, publicationSamples=10,
                           maximumWindowRows=120 if kind == 'messages' else 0, producerElapsedMs=5000,
                           maximumProducerLatenessMs=1, commitToFrameP95Ms=50, commitToFrameMaxMs=75)
                path = Path(directory) / f'{kind}-{count}-{mode}.json'; path.write_text(json.dumps(row)); paths.append(path)
        return paths

    def test_stream_reports_preserve_real_underrun_instead_of_claiming_target_rate(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = self.stream_fixture(directory)
            self.assertEqual(8, len(read_stream_reports(paths, 1000, 5, 1)))
            row = json.loads(paths[0].read_text())
            row.update(withinWindow=3000, achievedMsgPerSecond=600, targetMet=False)
            paths[0].write_text(json.dumps(row))
            result = read_stream_reports(paths, 1000, 5, 1)
            self.assertFalse(next(iter(result.values()))[0]['targetMet'])
            row['targetMet'] = True; paths[0].write_text(json.dumps(row))
            with self.assertRaises(ValueError): read_stream_reports(paths, 1000, 5, 1)

    def test_stream_reports_reject_loss_unbounded_windows_and_missing_iterations(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = self.stream_fixture(directory)
            with self.assertRaises(ValueError): read_stream_reports(paths, 1000, 5, 2)
            row = json.loads(paths[-1].read_text()); row['maximumWindowRows'] = 121
            paths[-1].write_text(json.dumps(row))
            with self.assertRaises(ValueError): read_stream_reports(paths, 1000, 5, 1)
            row['maximumWindowRows'] = 120; row['committed'] = 4999
            paths[-1].write_text(json.dumps(row))
            with self.assertRaises(ValueError): read_stream_reports(paths, 1000, 5, 1)

    def test_suite_selection_keeps_static_and_sustained_scenarios_distinct(self):
        self.assertEqual(12, len(expected_scenarios('lists')))
        self.assertEqual(8, len(expected_scenarios('stream')))
        self.assertEqual(20, len(expected_scenarios('all')))

    def test_regression_gate_and_one_millisecond_noise_floor(self):
        self.assertEqual([], compare(self.report(11), self.report(), 15))
        self.assertEqual(1, len(compare(self.report(13), self.report(), 15)))

    def test_negative_frame_slack_detects_absolute_regression(self):
        baseline = self.report(); current = self.report()
        baseline['metrics']['scroll'] = {'frameOverrunMs.P95': -3}
        current['metrics']['scroll'] = {'frameOverrunMs.P95': 2}
        self.assertEqual(1, len(compare(current, baseline, 15)))

    def test_emulator_and_other_device_cannot_be_baselines(self):
        for key, value in [('baselineEligible', False), ('environment', {'serial': 'other-device'})]:
            baseline = self.report(); baseline[key] = value
            with self.assertRaises(ValueError):
                compare(self.report(), baseline, 15)

    def test_missing_metrics_or_scenarios_fail_closed(self):
        with self.assertRaises(ValueError):
            metrics_from_reports([])
        baseline = self.report(); baseline['metrics']['scroll'] = {}
        with self.assertRaises(ValueError):
            compare(self.report(), baseline, 15)


if __name__ == '__main__':
    unittest.main()
