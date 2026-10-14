#!/usr/bin/env python3
"""Read-only phase-window evidence analysis. No services, SQL, or network calls.

Usage: analyze_v2_actor_realtime_hotspots.py CANDIDATE [BASELINE] --phase rate-5000
Shared-server metrics use the intersection of shards' actual phase intervals.
Counter boundaries are sampled approximations, never exact phase percentiles.
"""
import argparse
import collections
import json
import math
from pathlib import Path
import re
import sys


METRIC = re.compile(r'^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{.*\})?\s+([^\s]+)')
PREFIXES = ('im_v2_database_loan_', 'im_v2_database_work_', 'im_v2_gateway_message_send_', 'im_v2_gateway_commands_',
            'im_v2_gateway_command_duration_', 'im_v2_gateway_message_operation_internal_failures_', 'im_v2_send_operation_', 'im_v2_send_preparation_',
            'im_v2_room_actor_', 'im_v2_room_subscription_', 'im_v2_actor_realtime_', 'im_v2_gateway_event_loop_lag_', 'im_v2_heartbeat_', 'im_v2_gateway_journal_')


def read_jsonl(path):
    rows, errors = [], []
    if not path.exists():
        return rows, ['missing_file:' + path.name]
    for number, line in enumerate(path.read_text().splitlines(), 1):
        try:
            row = json.loads(line)
            if isinstance(row.get('time'), (int, float)):
                rows.append(row)
            else:
                errors.append('missing_timestamp:' + str(number))
        except (ValueError, TypeError):
            errors.append('invalid_json:' + str(number))
    return sorted(rows, key=lambda x: x['time']), errors


def select(rows, start, end):
    before = [x for x in rows if x['time'] <= start]
    within = [x for x in rows if start < x['time'] <= end]
    baseline = before[-1] if before else None
    last = within[-1] if within else None
    return baseline, within, dict(
        phaseStartedAt=start, phaseEndedAt=end, samplesInside=len(within),
        baselineSampleAt=baseline['time'] if baseline else None,
        baselineBeforeStartSeconds=start-baseline['time'] if baseline else None,
        lastSampleAt=last['time'] if last else None,
        endAfterLastSampleSeconds=end-last['time'] if last else None,
        missingBaseline=baseline is None, missingInsideSamples=not within,
        counterScope='nearest_pre_start_to_last_inside; includes disclosed pre_start_offset',
        rateScope='only adjacent samples whose two timestamps are inside phase')


def prometheus(body):
    values = {}
    types = {}
    for line in body.splitlines():
        if line.startswith('# TYPE '):
            fields = line.split()
            types[fields[2]] = fields[3]
        match = METRIC.match(line)
        if not match:
            continue
        name, labels, value = match.groups()
        if not name.startswith(PREFIXES):
            continue
        labels = labels or ''
        # Reads and sync compete for physical loans and can reject a workload
        # before sends fail. Preserve their bounded class labels separately.
        if name.startswith(('im_v2_gateway_commands_', 'im_v2_gateway_command_duration_')) and 'command="message_send_operation"' not in labels:
            continue
        try:
            numeric = float(value)
            if math.isfinite(numeric):
                declared_type = types.get(name)
                counter = declared_type == 'counter' if declared_type else name.endswith(('_total', '_sum', '_count', '_bucket'))
                values[name + labels] = (numeric, counter)
        except ValueError:
            pass
    return values


def counter_summary(points, baseline):
    """Do not infer a zero for an absent sparse labeled counter."""
    keys = sorted({key for _, values in points for key in values})
    result = {}
    for key in keys:
        observed = [(at, values[key][0]) for at, values in points if key in values]
        value, counter = next(values[key] for _, values in points if key in values)
        if not counter:
            result[key] = dict(kind='gauge', minimum=min(x[1] for x in observed),
                               maximum=max(x[1] for x in observed), last=observed[-1][1],
                               samples=len(observed),
                               semantics='lifetime_high_watermark_sampled_inside_phase' if 'peak_' in key or key.split('{', 1)[0].endswith(('_max', '_largest_batch', '_largest_room_count')) else 'gauge_sampled_inside_phase')
            continue
        base = baseline[1].get(key) if baseline else None
        reset = any(b[1] < a[1] for a, b in zip(observed, observed[1:]))
        delta = observed[-1][1]-base[0] if base and observed[-1][1] >= base[0] and not reset else None
        rates = [(b[1]-a[1])/(b[0]-a[0]) for a, b in zip(observed, observed[1:])
                 if b[0] > a[0] and b[1] >= a[1]]
        result[key] = dict(kind='counter', delta=delta, missingBaselineSeries=base is None,
                           resetObserved=reset or bool(base and observed[-1][1] < base[0]),
                           maximumAdjacentRatePerSecond=max(rates) if rates else None,
                           firstObservedAt=observed[0][0], lastObservedAt=observed[-1][0],
                           samples=len(observed))
    # Pair like-labeled gateway duration samples with their actual command count.
    for key, summary in list(result.items()):
        if key.startswith('im_v2_database_loan_observation_') and key.split('{', 1)[0].endswith('_duration_sum'):
            count = result.get(key.replace('_duration_sum', '_duration_count'), {}).get('delta')
            summary['meanMilliseconds'] = summary['delta']/count if count and summary['delta'] is not None else None
            summary['meanScope'] = ('completed_actual_loan_or_stage_delta; exact source and stage or SQL phase, '
                                    'same disclosed counter boundary; SQL futures include driver/network/continuation '
                                    'time and may overlap, excludes still active observations')
        elif key.startswith('im_v2_actor_realtime_route_query_duration_milliseconds_sum'):
            count = result.get(key.replace('_milliseconds_sum', '_milliseconds_count'), {}).get('delta')
            summary['meanMilliseconds'] = summary['delta']/count if count and summary['delta'] is not None else None
            summary['meanScope'] = 'completed_route_query_delta; same fixed topic kind, includes downstream loan waiting, excludes capacity-rejected and still-active queries'
        elif key == 'im_v2_gateway_event_loop_lag_milliseconds_sum':
            count = result.get('im_v2_gateway_event_loop_lag_milliseconds_count', {}).get('delta')
            summary['meanMilliseconds'] = summary['delta']/count if count and summary['delta'] is not None else None
            summary['meanScope'] = 'completed_event_loop_probe_delta; same disclosed counter boundary, excludes delayed probes not yet resumed'
        elif key.startswith('im_v2_heartbeat_stage_milliseconds_sum'):
            count = result.get(key.replace('_milliseconds_sum', '_milliseconds_count'), {}).get('delta')
            summary['meanMilliseconds'] = summary['delta']/count if count and summary['delta'] is not None else None
            summary['meanScope'] = 'completed_sampled_heartbeat_delta; same stage/cohort and disclosed counter boundary; entry/return include runtime scheduling, server_total overlaps its child stages'
        elif key.startswith('im_v2_gateway_command_duration_milliseconds_sum'):
            count = result.get(key.replace('_milliseconds_sum', '_milliseconds_count'), {}).get('delta')
            summary['meanMilliseconds'] = summary['delta']/count if count and summary['delta'] is not None else None
        elif key == 'im_v2_send_preparation_queue_wait_milliseconds_sum':
            count = result.get('im_v2_send_preparation_queue_wait_milliseconds_count', {}).get('delta')
            summary['meanMilliseconds'] = summary['delta']/count if count and summary['delta'] is not None else None
            summary['meanScope'] = 'completed_queue_wait_delta; excludes still_queued_preparations'
        elif key.startswith('im_v2_database_work_queue_wait_milliseconds_sum'):
            count = result.get(key.replace('_milliseconds_sum', '_milliseconds_count'), {}).get('delta')
            summary['meanMilliseconds'] = summary['delta']/count if count and summary['delta'] is not None else None
            summary['meanScope'] = 'completed_work_admission_queue_wait_delta; same class, excludes still queued work, not SQL execution'
        elif key.startswith('im_v2_send_operation_stage_duration_milliseconds_sum'):
            count_key = key.replace('_duration_milliseconds_sum', '_completed_total')
            count = result.get(count_key, {}).get('delta')
            summary['meanMilliseconds'] = summary['delta']/count if count and summary['delta'] is not None else None
            summary['meanScope'] = 'completed_stage_delta; same disclosed counter boundary, excludes still_in_flight_stages'
        elif key.startswith('im_v2_send_operation_sql_continuation_duration_milliseconds_sum'):
            count_key = key.replace('_duration_milliseconds_sum', '_duration_milliseconds_count')
            count = result.get(count_key, {}).get('delta')
            summary['meanMilliseconds'] = summary['delta']/count if count and summary['delta'] is not None else None
            summary['meanScope'] = 'completed_sql_continuation_segment_delta; same source and part, excludes pending observations, not SQL execution or commit latency'
        elif key.startswith('im_v2_send_operation_') and key.split('{', 1)[0].endswith('_duration_milliseconds_sum'):
            count_key = key.replace('_duration_milliseconds_sum', '_duration_milliseconds_count')
            count = result.get(count_key, {}).get('delta')
            summary['meanMilliseconds'] = summary['delta']/count if count and summary['delta'] is not None else None
            summary['meanScope'] = 'completed_handoff_delta; same path and part, before COMMIT dispatch, not successful commits'
    return result


def gateways(rows, start, end):
    hosts = collections.defaultdict(list)
    for row in rows:
        for sample in row.get('samples', []):
            if isinstance(sample.get('body'), str):
                hosts[str(sample.get('node', 'unknown'))].append(dict(time=row['time'], values=prometheus(sample['body'])))
    result = {}
    for host, samples in hosts.items():
        base, inside, window = select(samples, start, end)
        points = [(x['time'], x['values']) for x in inside]
        metrics = counter_summary(points, (base['time'], base['values']) if base else None)
        expected = ('im_v2_database_work_', 'im_v2_gateway_commands_', 'im_v2_send_operation_',
                    'im_v2_room_actor_', 'im_v2_actor_realtime_')
        result[host] = dict(window=window, metrics=metrics,
            missingMetricFamilies=[prefix for prefix in expected if not any(key.startswith(prefix) for key in metrics)])
    return result


def cpu_seconds(value):
    days, sep, rest = value.partition('-')
    pieces = [float(x) for x in (rest if sep else days).split(':')]
    return (int(days)*86400 if sep else 0) + sum(x*60**i for i, x in enumerate(reversed(pieces)))


def process_role(command):
    # The loader's binary name contains Gateway; classify it first.
    for fragments, role in (
        (('IMV2GatewayLoadGenerator', 'IMV2ConnectionLoader', 'IMV2Load'), 'loader'),
        (('IMV2AccountServerApp',), 'account'),
        (('IMV2ServerApp',), 'actor_host'),
        (('IMV2Gateway',), 'gateway'),
        (('v2_benchmark_https_edge',), 'edge'),
    ):
        if any(fragment in command for fragment in fragments):
            return role
    return 'other'


def processes(row, postgres=False):
    result = {}
    for line in row.get('processResources' if postgres else 'ps', '').splitlines():
        fields = line.split(None, 4 if postgres else 3)
        try:
            pid = fields[0]
            rss, cpu = (fields[2], fields[3]) if postgres else (fields[1], fields[2])
            # Preserve process role without retaining the entire command line.
            command = fields[3] if not postgres and len(fields) > 3 else ''
            role = process_role(command)
            result[pid] = dict(cpu=cpu_seconds(cpu), rss=int(rss), role='postgres' if postgres else role)
        except (ValueError, IndexError):
            continue
    return result


def cpu_summary(inside, postgres=False):
    per_pid = collections.defaultdict(list)
    for left, right in zip(inside, inside[1:]):
        elapsed = right['time']-left['time']
        if elapsed <= 0:
            continue
        before, after = processes(left, postgres), processes(right, postgres)
        for pid in before.keys() & after.keys():
            delta = after[pid]['cpu']-before[pid]['cpu']
            if delta >= 0:
                per_pid[pid].append((delta, elapsed, after[pid]))
    return {pid: dict(role=rows[-1][2]['role'], observedCPUSeconds=sum(x[0] for x in rows),
                      observedSeconds=sum(x[1] for x in rows),
                      averageCoreEquivalents=sum(x[0] for x in rows)/sum(x[1] for x in rows),
                      maximumCoreEquivalents=max(x[0]/x[1] for x in rows),
                      maximumRSSKiB=max(x[2]['rss'] for x in rows)) for pid, rows in per_pid.items()}


def pg_values(row):
    values = {}
    for section in ('database', 'wal'):
        for key, value in row.get(section, {}).items():
            if isinstance(value, (int, float)) and key not in ('numbackends',):
                values[section+'.'+key] = (value, True)
    for table in row.get('tables', []):
        for key in ('n_tup_ins', 'n_tup_upd', 'n_tup_del', 'n_tup_hot_upd', 'seq_scan', 'idx_scan'):
            if isinstance(table.get(key), (int, float)):
                values['table.'+table['schemaname']+'.'+table['relname']+'.'+key] = (table[key], True)
    return values


def postgres(rows, start, end):
    base, inside, window = select(rows, start, end)
    counters = counter_summary([(x['time'], pg_values(x)) for x in inside],
                               (base['time'], pg_values(base)) if base else None)
    # stats_reset/postmaster changes invalidate corresponding cumulative deltas.
    for section in ('database', 'wal'):
        witnesses = [base] + inside if base else inside
        resets = {str(x.get(section, {}).get('stats_reset')) for x in witnesses}
        identities = {x.get('postmasterPID') for x in witnesses}
        if len(resets) > 1 or len(identities) > 1:
            for key, value in counters.items():
                if key.startswith(section+'.') or (key.startswith('table.') and (section == 'database' or len(identities) > 1)):
                    value.update(delta=None, resetObserved=True)
    categories, objects, evidence = collections.Counter(), collections.Counter(), collections.Counter()
    blocked, ages, fanin, truncated = [], [], [], 0
    blocker_categories, held_categories = collections.Counter(), collections.Counter()
    xid_examples = []
    versioned = []
    for row in inside:
        if row.get('samplerVersion') == 'pg-hotspot-v2':
            versioned.append(row['time'])
        waiters = row.get('blocked', [])
        blocked.append(row.get('blocked_total', len(waiters)))
        for waiter in waiters:
            categories[waiter.get('query_category', 'missing')] += 1
            if isinstance(waiter.get('statement_age_seconds'), (int, float)):
                ages.append(waiter['statement_age_seconds'])
            for lock in waiter.get('requested_locks', []):
                objects['|'.join(str(lock.get(k)) for k in ('locktype', 'schema', 'relation', 'mode'))] += 1
            for blocker in waiter.get('blockers', []):
                blocker_categories[blocker.get('query_category', 'missing')] += 1
                for held in blocker.get('held_locks', []):
                    held_categories[held.get('category', 'missing')] += held.get('locks', 0)
                requested = {lock.get('transaction_id') for lock in waiter.get('requested_locks', [])
                             if lock.get('locktype') == 'transactionid' and lock.get('transaction_id') is not None}
                owned = {lock.get('transaction_id') for lock in blocker.get('lock_objects', [])
                         if lock.get('locktype') == 'transactionid' and lock.get('mode') == 'ExclusiveLock'}
                for xid in requested & owned:
                    if len(xid_examples) < 32:
                        xid_examples.append(dict(time=row['time'], waiterPID=waiter['pid'],
                            blockerPID=blocker['pid'], transactionID=xid))
        analysis = row.get('blockerAnalysis', {})
        fanin.append(analysis.get('maximumObservedFanIn', 0))
        truncated += int(analysis.get('truncated', False))
        for edge in analysis.get('edges', []):
            evidence.update(edge.get('evidence', []))
    return dict(window=window, counters=counters, processCPU=cpu_summary(inside, True),
                statisticsErrors=[dict(time=x['time'], error=x['statisticsError']) for x in inside if x.get('statisticsError')],
                missingSections={section: sum(not x.get(section) for x in inside) for section in ('database', 'wal', 'tables')},
                processCPUStatus='observed_adjacent_samples' if len(inside) >= 2 and any(x.get('processResources') for x in inside) else 'missing_adjacent_process_samples',
                blocked=dict(maximum=max(blocked) if blocked else None,
                    maximumStatementAgeSeconds=max(ages) if ages else None,
                    waiterCategoryObservationCounts=dict(categories), requestedLockObservationCounts=dict(objects),
                    blockerCategoryObservationCounts=dict(blocker_categories),
                    heldLockCategoryObservationCounts=dict(held_categories),
                    matchingActualXIDExamples=xid_examples, actualXIDExampleLimit=32,
                    edgeEvidenceObservationCounts=dict(evidence), maximumObservedFanIn=max(fanin) if fanin else None,
                    truncatedSamples=truncated, v2Samples=len(versioned),
                    missingV2Evidence=len(versioned) != len(inside),
                    interpretation='snapshot observations, not distinct waits; relation locks do not prove row holders; matching_transaction_id is explicit XID evidence'))


def host_resources(rows, start, end):
    _, inside, window = select(rows, start, end)
    cpu_intervals = [dict(startedAt=row['cpuIntervalStartedAt'], endedAt=row['time'],
                          percent=row['cpuPercent']) for row in inside
                     if isinstance(row.get('cpuIntervalStartedAt'), (int, float))
                     and start <= row['cpuIntervalStartedAt'] < row['time']
                     and isinstance(row.get('cpuPercent'), dict)]
    snapshots = [{key: value for key, value in row.items()
                  if key not in ('cpuPercent', 'cpuIntervalStartedAt')} for row in inside]
    return dict(window=window, cpuIntervals=cpu_intervals, snapshots=snapshots,
                status='observed' if inside else 'missing_inside_samples',
                coverage='host-wide; CPU intervals entirely inside phase; VM and swap remain raw snapshots')


READY_CATEGORIES = (
    'ready_pool_fully_borrowed_sum', 'ready_slots_full_return_pending_sum',
    'ready_slots_full_task_pending_sum', 'ready_slots_full_pool_request_pending_sum',
    'ready_slots_full_assignment_pending_sum', 'ready_slots_full_callback_pending_sum',
    'ready_slots_full_driver_pending_sum', 'ready_slots_full_mixed_pending_sum',
    'ready_slots_full_unknown_pending_sum', 'ready_slot_available_sum',
    'ready_diagnostic_history_missing_sum', 'ready_slots_full_borrow_pending_sum')


def ready_wait_traces(directory, start, end):
    """Per-request resource partitions, never inference from average pool usage."""
    paths = sorted(directory.glob('gateway-*.log'))
    rows, invalid, incomplete, outside = [], 0, 0, 0
    decoder = json.JSONDecoder()
    for path in paths:
        with path.open(errors='replace') as log:
            for line in log:
                if 'send_path=' not in line:
                    continue
                try:
                    trace, _ = decoder.raw_decode(line.split('send_path=', 1)[1])
                    if trace.get('segment') != 'room_actor':
                        continue
                    at = trace['startedAtUnixMilliseconds'] / 1000
                    stages = collections.defaultdict(float)
                    for span in trace['spans']:
                        value = span['durationMilliseconds']
                        if not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
                            raise ValueError('invalid span')
                        stages[span['stage']] += value
                    wait = stages.get('owner_ready_wait')
                    if wait is None or wait < 20:
                        continue
                    if at < start or at + trace['durationMilliseconds'] / 1000 > end:
                        outside += 1
                        continue
                    parts = {key: stages.get(key, 0) for key in READY_CATEGORIES}
                    if abs(sum(parts.values()) - wait) > 0.02:
                        incomplete += 1
                        continue
                    rows.append(dict(node=path.stem, operations=trace.get('operations', []),
                                     waitMilliseconds=wait, partition=parts))
                except (ValueError, TypeError, KeyError):
                    invalid += 1
    def distribution(values):
        values = sorted(values)
        def percentile(p):
            return values[max(0, math.ceil(len(values) * p) - 1)] if values else None
        return dict(count=len(values), meanMilliseconds=sum(values)/len(values) if values else None,
                    p50Milliseconds=percentile(.5), p95Milliseconds=percentile(.95),
                    p99Milliseconds=percentile(.99), totalMilliseconds=sum(values))
    return dict(status='observed' if rows else 'no_complete_slow_request_partitions',
                scope='logged room traces with ready wait >=20ms, wholly inside phase; slow-biased sample, not all messages',
                semantics='categories partition waiting to driver entry; mixed/unknown/history missing are not a unique cause; slot available does not prove a physical connection is idle',
                logFiles=len(paths), malformedTraces=invalid, incompletePartitions=incomplete,
                excludedBoundaryTraces=outside, wait=distribution([r['waitMilliseconds'] for r in rows]),
                categories={key: distribution([r['partition'][key] for r in rows]) for key in READY_CATEGORIES},
                longest=sorted(rows, key=lambda r: r['waitMilliseconds'], reverse=True)[:10])


def analyze(directory, names):
    reports, problems = [], []
    for path in sorted(directory.glob('report-*.json')):
        try:
            reports.append((path.name, json.loads(path.read_text())))
        except ValueError:
            problems.append('invalid_report:'+path.name)
    expected_reports = None
    try:
        evidence = json.loads((directory.parent/'evidence.json').read_text())
        candidate = evidence.get('loaderPartitions')
        if isinstance(candidate, int) and not isinstance(candidate, bool) and 1 <= candidate <= 10_000:
            expected_reports = candidate
    except (OSError, ValueError):
        pass
    if expected_reports is None:
        try:
            codes = json.loads((directory/'result.json').read_text()).get('exitCodes')
            if isinstance(codes, list) and codes:
                expected_reports = len(codes)
        except (OSError, ValueError):
            pass
    report_names = {file for file, _ in reports}
    missing_reports = ([f'report-{index}.json' for index in range(expected_reports)
                        if f'report-{index}.json' not in report_names]
                       if expected_reports is not None else None)
    if missing_reports:
        problems.extend('missing_report:'+file for file in missing_reports)
    streams = {}
    for name in ('gateway-metrics', 'postgres-metrics', 'process-resources', 'host-resources'):
        streams[name], errors = read_jsonl(directory/(name+'.jsonl'))
        problems.extend(name+':'+error for error in errors)
    output = dict(directory=str(directory.resolve()), reports=len(reports), expectedReports=expected_reports, missingReportNames=missing_reports,
                  reportSetComplete=(not missing_reports and len(reports) == expected_reports)
                  if expected_reports is not None else None, missing=problems, phases={})
    for name in names:
        shards = [(file, p) for file, r in reports for p in r.get('scenarioPhases', []) if p.get('name') == name]
        valid = [(file, p) for file, p in shards if isinstance(p.get('startedAtUnixMilliseconds'), (int, float)) and isinstance(p.get('endedAtUnixMilliseconds'), (int, float))]
        if not valid:
            output['phases'][name] = dict(missing='actual_phase_boundaries')
            continue
        start = max(p['startedAtUnixMilliseconds']/1000 for _, p in valid)
        end = min(p['endedAtUnixMilliseconds']/1000 for _, p in valid)
        phase = dict(startedAt=start, endedAt=end, durationSeconds=max(0, end-start),
                     windowPolicy='intersection_of_available_shards_actual_intervals',
                     missingShardPhaseCount=(expected_reports if expected_reports is not None else len(reports))-len(valid),
                     phaseCoverageScope="expected_shards" if expected_reports is not None else "observed_reports_only",
                     clientShards=[dict(report=file, phase=p) for file, p in valid],
                     clientPercentiles='per shard only; never average or merge precomputed percentiles')
        if end <= start:
            phase['missing'] = 'no_shared_phase_interval'
        else:
            phase['gateways'] = gateways(streams['gateway-metrics'], start, end)
            phase['postgres'] = postgres(streams['postgres-metrics'], start, end)
            phase['host'] = host_resources(streams['host-resources'], start, end)
            phase['readyWaitDiagnosis'] = ready_wait_traces(directory, start, end)
            _, inside, window = select(streams['process-resources'], start, end)
            phase['processes'] = dict(window=window, perPID=cpu_summary(inside),
                coverage='only unchanged PIDs in adjacent in-phase samples; exited process CPU may be absent',
                hostAssociation='unavailable in ps evidence; per-PID roles only, never infer node from PID order',
                status='observed_adjacent_samples' if len(inside) >= 2 else 'missing_adjacent_samples')
        output['phases'][name] = phase
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directories', nargs='+', type=Path)
    parser.add_argument('--phase', action='append', default=None)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    result = dict(formatVersion=1, limitations=[
        'Counter deltas include disclosed pre-phase boundary offset; ending samples stay inside phase.',
        'Rates and CPU use only pairs of samples entirely inside the phase.',
        'Wait histograms are cumulative bucket deltas, not exact phase p95/p99.',
        'Missing sparse counter baseline remains unknown rather than assuming zero.',
        'Sampled gauges and lock edges cannot prove causality or capture every transient.'],
        runs=[analyze(path, args.phase or ['rate-5000']) for path in args.directories])
    content = json.dumps(result, indent=2, allow_nan=False)+'\n'
    if args.output:
        args.output.write_text(content)
    else:
        sys.stdout.write(content)
    for run in result['runs']:
        for name, phase in run['phases'].items():
            print(f"{run['directory']} {name}: {phase.get('durationSeconds', 0):.3f}s shared interval; "
                  f"{len(phase.get('gateways', {}))} hosts; missing={phase.get('missing', run['missing'])}", file=sys.stderr)


if __name__ == '__main__':
    main()
