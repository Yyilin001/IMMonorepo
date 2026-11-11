#!/usr/bin/env python3
"""Run isolated Android list Macrobenchmarks and retain JSON + Perfetto evidence."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys
from verify_device import parse_results

ROOT = Path(__file__).resolve().parents[1]
TARGET = 'com.xmtx.im.android.benchmark'
RUNNER = 'com.xmtx.im.benchmark'


def expected_scenarios(suite):
    datasets = [('conversations', 1000), ('conversations', 10000), ('messages', 10000), ('messages', 100000)]
    lists = {f'{test}[{kind}_{count}]' for test in ('coldLoad', 'scrollAndPage', 'batchUpdate') for kind, count in datasets}
    streams = {f'sustainedMessages[{kind}_{count}_{mode}]' for kind, count in datasets for mode in ('follow', 'scroll')}
    return lists if suite == 'lists' else streams if suite == 'stream' else lists | streams


def metrics_from_reports(paths, suite='lists'):
    result = {}
    for path in paths:
        document = json.loads(path.read_text())
        for case in document.get('benchmarks', []):
            name = case['name']
            if name in result:
                raise ValueError(f'Duplicate benchmark: {name}')
            values = {}
            for group in ('metrics', 'sampledMetrics'):
                for metric, data in case.get(group, {}).items():
                    if not metric.endswith('Ms'):
                        continue
                    for statistic in ('median', 'P95', 'P99'):
                        if statistic in data:
                            value = data[statistic]
                            if not isinstance(value, (int, float)) or not math.isfinite(value):
                                raise ValueError(f'Invalid measurement: {name}/{metric}/{statistic}')
                            values[f'{metric}.{statistic}'] = value
            if not values:
                raise ValueError(f'Missing measured metrics: {name}')
            required = ('timeToInitialDisplayMs', 'IM.List.loadSumMs') if name.startswith('coldLoad') else (
                ('frameDurationCpuMs', 'IM.List.updateSumMs') if name.startswith('batchUpdate') else
                ('frameDurationCpuMs', 'IM.List.streamSumMs') if name.startswith('sustainedMessages') else ('frameDurationCpuMs',))
            for prefix in required:
                if not any(key.startswith(prefix) and value > 0 for key, value in values.items()):
                    raise ValueError(f'Missing positive {prefix} measurement: {name}')
            result[name] = values
    expected = expected_scenarios(suite)
    if {name.replace(',', '') for name in result} != expected:
        raise ValueError(f'Expected {len(expected)} scenarios for {suite}, got {list(result)}')
    return result


def read_stream_reports(paths, rate, seconds, iterations):
    result = {}
    for path in paths:
        row = json.loads(path.read_text())
        key = f"sustainedMessages[{row['kind']}_{row['count']}_{row['mode']}]"
        if key not in expected_scenarios('stream') or row['rate'] != rate or row['seconds'] != seconds:
            raise ValueError('Stream fixture/configuration mismatch')
        expected = rate * seconds
        if row['expected'] != expected or row['committed'] != expected or row['published'] != expected or row['finalRowCount'] != row['count'] + expected:
            raise ValueError('Stream dropped messages or did not drain its UI publication')
        if not 0 <= row['withinWindow'] <= expected or not math.isclose(row['achievedMsgPerSecond'], row['withinWindow'] / seconds):
            raise ValueError('Invalid actual message rate')
        if row['targetMet'] != (row['withinWindow'] >= math.ceil(expected * 0.95)):
            raise ValueError('Incorrect throughput target classification')
        if row['publicationSamples'] < (2 if row['mode'] == 'follow' else 1) or row['kind'] == 'messages' and row['maximumWindowRows'] != 120:
            raise ValueError('Missing sustained publications or unbounded message window')
        for metric in ['producerElapsedMs', 'maximumProducerLatenessMs', 'commitToFrameP95Ms', 'commitToFrameMaxMs']:
            if not math.isfinite(row[metric]) or row[metric] < 0:
                raise ValueError(f'Invalid stream metric: {metric}')
        result.setdefault(key, []).append(row)
    if set(result) != expected_scenarios('stream') or any(len(rows) != iterations for rows in result.values()):
        raise ValueError('Missing or duplicated per-iteration stream evidence')
    return result


def compare(current, baseline, percent):
    if not current['baselineEligible'] or not baseline['baselineEligible']:
        raise ValueError('Emulator smoke results cannot be used for a performance regression gate')
    if current['environment'] != baseline['environment']:
        raise ValueError('Baseline device/build/display/iteration configuration differs')
    if current['metrics'].keys() != baseline['metrics'].keys():
        raise ValueError('Baseline scenario set differs')
    regressions = []
    for name, values in current['metrics'].items():
        if values.keys() != baseline['metrics'][name].keys():
            raise ValueError(f'Baseline metric set differs: {name}')
        for metric, value in values.items():
            # Negative deadline slack has no meaningful percentage; use an absolute 1 ms change.
            old = baseline['metrics'][name][metric]
            threshold = old + 1.0 if metric.startswith('frameOverrunMs.') and old <= 0 else max(old * (1 + percent / 100), old + 1.0)
            if (old > 0 or metric.startswith('frameOverrunMs.')) and value > threshold:
                regressions.append({'scenario': name, 'metric': metric, 'baseline': old, 'current': value})
    return regressions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--output', type=Path, required=True, help='New directory; existing results are never overwritten')
    parser.add_argument('--adb', default=str(Path(os.environ.get('ANDROID_HOME', Path.home() / 'Library/Android/sdk')) / 'platform-tools/adb'))
    parser.add_argument('--smoke', action='store_true', help='One iteration; permits emulator, never a performance baseline')
    parser.add_argument('--iterations', type=int, default=5)
    parser.add_argument('--suite', choices=('lists', 'stream', 'all'), default='all')
    parser.add_argument('--message-rate', type=int, default=1000, help='Offered messages/sec, 1..1000')
    parser.add_argument('--stream-seconds', type=int, help='5..120; default 30, or 5 in smoke mode')
    parser.add_argument('--baseline', type=Path, help='Prior summary.json from the same physical device/configuration')
    parser.add_argument('--max-regression-percent', type=float, default=15)
    args = parser.parse_args()
    iterations = 1 if args.smoke else args.iterations
    seconds = args.stream_seconds if args.stream_seconds is not None else (5 if args.smoke else 30)
    if not 1 <= args.message_rate <= 1000 or not 5 <= seconds <= 120:
        parser.error('message-rate must be 1..1000 and stream-seconds must be 5..120')
    expected_tests = len(expected_scenarios(args.suite))
    if not 1 <= iterations <= 20 or args.max_regression_percent < 0:
        parser.error('iterations must be 1..20 and regression percentage must be nonnegative')
    if args.smoke and args.baseline:
        parser.error('--smoke cannot compare performance baselines')
    adb = [args.adb, '-s', args.serial]
    def shell(*command):
        return subprocess.check_output(adb + ['shell', *command], text=True, timeout=30).strip()
    api = int(shell('getprop', 'ro.build.version.sdk'))
    if api < 31 or shell('getprop', 'sys.boot_completed') != '1':
        parser.error('Select a booted Android 12+ device')
    emulator = shell('getprop', 'ro.kernel.qemu') == '1'
    if emulator and not args.smoke:
        parser.error('Use a physical device for baselines, or --smoke for emulator verification')
    args.output.mkdir(parents=True, exist_ok=False)
    apks = [ROOT / 'app/build/outputs/apk/benchmark/app-benchmark.apk', ROOT / 'benchmark/build/outputs/apk/benchmark/benchmark-benchmark.apk']
    for apk in apks:
        if not apk.is_file():
            parser.error('Build :app:assembleBenchmark :benchmark:assembleBenchmark before running')
    environment = {'serial': args.serial, 'api': api, 'fingerprint': shell('getprop', 'ro.build.fingerprint'),
                   'model': shell('getprop', 'ro.product.model'), 'size': shell('wm', 'size'), 'density': shell('wm', 'density'),
                   'animations': {key: shell('settings', 'get', 'global', key) for key in
                                  ('window_animation_scale', 'transition_animation_scale', 'animator_duration_scale')},
                   'displaySettings': {key: shell('settings', 'get', 'system', key) for key in
                                       ('peak_refresh_rate', 'min_refresh_rate', 'user_rotation', 'accelerometer_rotation')},
                   'fontScale': shell('settings', 'get', 'system', 'font_scale'),
                   'locale': shell('getprop', 'persist.sys.locale'),
                   'iterations': iterations, 'compilation': 'Full', 'fixtureVersion': 3,
                   'codeOptimization': 'R8',
                   'suite': args.suite, 'messageRate': args.message_rate, 'streamSeconds': seconds}
    summary = {'environment': environment, 'baselineEligible': not args.smoke and not emulator,
               'apks': {apk.name: hashlib.sha256(apk.read_bytes()).hexdigest() for apk in apks}}
    for apk in apks:
        subprocess.run(adb + ['install', '-r', str(apk)], check=True)
    remote = f'/sdcard/Android/media/{RUNNER}/list-benchmark-output'
    # This directory belongs exclusively to the benchmark test APK, not the normal App.
    shell('rm', '-rf', remote)
    classes = {'lists': 'com.xmtx.im.benchmark.ListPerformanceBenchmark', 'stream': 'com.xmtx.im.benchmark.MessageStreamBenchmark'}
    selected = ','.join(classes.values()) if args.suite == 'all' else classes[args.suite]
    command = adb + ['shell', 'am', 'instrument', '-w', '-r', '-e', 'class', selected,
                     '-e', 'im.benchmark.messageRate', str(args.message_rate), '-e', 'im.benchmark.streamSeconds', str(seconds),
                     '-e', 'im.benchmark.iterations', str(iterations), '-e', 'additionalTestOutputDir', remote,
                     '-e', 'androidx.benchmark.output.enable', 'true']
    if args.smoke:
        command += ['-e', 'androidx.benchmark.suppressErrors', 'EMULATOR']
    command += [RUNNER + '/androidx.test.runner.AndroidJUnitRunner']
    log = args.output / 'instrumentation.log'
    try:
        with log.open('w') as stream:
            subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, timeout=7200, check=True)
    finally:
        shell('am', 'force-stop', RUNNER); shell('am', 'force-stop', TARGET)
        subprocess.run(adb + ['pull', remote, str(args.output / 'raw')], check=False, stdout=subprocess.DEVNULL)
    summary['instrumentation'] = parse_results(log.read_text())
    try:
        outcome = summary['instrumentation']
        if not outcome['complete'] or outcome['failures'] or outcome['passed'] != expected_tests or outcome['skipped']:
            raise ValueError(f'Instrumentation did not pass all {expected_tests} scenarios; inspect instrumentation.log')
        reports = list((args.output / 'raw').rglob('*benchmarkData.json'))
        summary['metrics'] = metrics_from_reports(reports, args.suite)
        traces = list((args.output / 'raw').rglob('*.perfetto-trace'))
        if len(traces) < expected_tests * iterations:
            raise ValueError('Missing per-iteration Perfetto traces')
        summary['traceCount'] = len(traces)
        summary['loadTargetMet'] = None
        if args.suite != 'lists':
            streams = read_stream_reports(list((args.output / 'raw').rglob('stream-*.json')), args.message_rate, seconds, iterations)
            summary['streams'] = streams
            summary['loadTargetMet'] = all(row['targetMet'] for rows in streams.values() for row in rows)
            for case, values in summary['metrics'].items():
                rows = streams.get(case.replace(',', ''))
                if rows:
                    for metric in ['commitToFrameP95Ms', 'commitToFrameMaxMs', 'maximumProducerLatenessMs']:
                        values[f'{metric}.median'] = sorted(row[metric] for row in rows)[len(rows) // 2]
        summary['regressions'] = compare(summary, json.loads(args.baseline.read_text()), args.max_regression_percent) if args.baseline else []
        summary['passed'] = not summary['regressions'] and (args.smoke or summary['loadTargetMet'] is not False)
    except ValueError as error:
        summary.update(passed=False, error=str(error))
    (args.output / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({key: value for key, value in summary.items() if key not in ('metrics', 'instrumentation', 'streams')}, ensure_ascii=False))
    return 0 if summary['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
