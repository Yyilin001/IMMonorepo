#!/usr/bin/env python3
"""Opt-in short macOS stack samples of an owned scaled benchmark only.

Profiling overhead excludes this run from capacity/performance comparison.
No SQL text, connection environment, or command-line arguments are persisted.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


def processes():
    result = subprocess.run(['ps', '-axo', 'pid=,ppid=,time=,comm='],
                            check=True, capture_output=True, text=True, timeout=3)
    rows = {}
    for line in result.stdout.splitlines():
        fields = line.strip().split(None, 3)
        if len(fields) != 4:
            continue
        pid, parent, cpu, executable = fields
        rows[int(pid)] = dict(parent=int(parent), cpu=cpu, executable=executable)
    return rows


def cpu_seconds(value):
    parts = value.split(':')
    return sum(float(part) * 60 ** index for index, part in enumerate(reversed(parts)))


def latest_pg(directory):
    try:
        lines = (directory / 'postgres-metrics.jsonl').read_text().splitlines()
        return json.loads(lines[-1]) if lines else {}
    except (OSError, ValueError):
        return {}


def select_targets(directory, runner_pid, rows):
    gateways = sorted(pid for pid, row in rows.items()
                      if row['parent'] == runner_pid
                      and Path(row['executable']).name == 'IMV2ServerApp')
    if len(gateways) != 6:
        raise RuntimeError('expected six live Gateway children of the specified runner')
    targets = [dict(pid=pid, parent=runner_pid, role='gateway', selection='first_two_owned')
               for pid in gateways[:2]]
    postmaster = int((directory.parent / 'postgres' / 'postmaster.pid').read_text().splitlines()[0])
    if postmaster not in rows or Path(rows[postmaster]['executable']).name != 'postgres':
        raise RuntimeError('owned postmaster is no longer live')
    children = {pid for pid, row in rows.items()
                if row['parent'] == postmaster and Path(row['executable']).name.startswith('postgres')}
    sample = latest_pg(directory)
    if sample.get('postmasterPID') != postmaster:
        raise RuntimeError('PG observation does not match the owned postmaster')
    edges = sample.get('blockerAnalysis', {}).get('edges', [])
    # The lock/activity observations are non-atomic. An endpoint absent from
    # edges may still be waiting on a tuple whose owner was not observed.
    waiters = {edge['waiterPID'] for edge in edges}
    waiters.update(row['pid'] for row in sample.get('blocked', [])
                   if row.get('wait_event_type') == 'Lock')
    waiters.update(blocker['pid'] for row in sample.get('blocked', [])
                   for blocker in row.get('blockers', [])
                   if blocker.get('wait_event_type') == 'Lock')
    fan_in = {}
    for edge in edges:
        pid = edge['blockerPID']
        if pid in children and pid not in waiters:
            fan_in[pid] = fan_in.get(pid, 0) + 1
    selected = []
    if fan_in:
        pid = max(fan_in, key=fan_in.get)
        selected.append(pid)
        targets.append(dict(pid=pid, parent=postmaster, role='postgres',
                            selection='observed_nonwaiting_edge_endpoint',
                            blockerSnapshotAt=sample.get('time'), observedFanIn=fan_in[pid]))
    # Pick a process present in the owned PG sampler, rather than a global PG.
    observed = set()
    for line in sample.get('processResources', '').splitlines():
        try:
            observed.add(int(line.split()[0]))
        except (ValueError, IndexError):
            pass
    remaining = (children & observed) - set(selected)
    if remaining:
        pid = max(remaining, key=lambda pid: cpu_seconds(rows[pid]['cpu']))
        targets.append(dict(pid=pid, parent=postmaster, role='postgres',
                            selection='highest_cumulative_cpu_owned_process',
                            blockerSnapshotAt=sample.get('time')))
    return targets


def capture(target, directory, duration):
    pid = target['pid']
    current = processes().get(pid)
    if current is None or current['parent'] != target['parent']:
        return dict(**target, status='target_exited_before_sample')
    started = time.time()
    path = directory / f"{target['role']}-{pid}.sample.txt"
    try:
        result = subprocess.run(['/usr/bin/sample', str(pid), str(duration), '10',
                                 '-mayDie', '-file', str(path)],
                                capture_output=True, text=True, timeout=duration + 15)
        return dict(**target, startedAt=started, endedAt=time.time(),
                    sampleIntervalMilliseconds=10, returnCode=result.returncode,
                    status='captured' if result.returncode == 0 and path.exists() else 'sample_failed',
                    file=path.name)
    except (OSError, subprocess.TimeoutExpired) as error:
        return dict(**target, startedAt=started, endedAt=time.time(),
                    status='sample_failed', error=type(error).__name__)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-directory', type=Path, required=True, help='candidate or baseline directory')
    parser.add_argument('--runner-pid', type=int, required=True)
    parser.add_argument('--phase', required=True)
    parser.add_argument('--after-phase-seconds', type=int, default=5)
    parser.add_argument('--duration-seconds', type=int, default=3, choices=range(1, 6))
    parser.add_argument('--wait-seconds', type=int, default=600)
    args = parser.parse_args()
    if sys.platform != 'darwin' or args.runner_pid <= 1 or args.after_phase_seconds < 1:
        parser.error('requires macOS, an owned runner PID, and a positive phase offset')
    directory = args.run_directory.resolve()
    deadline = time.monotonic() + args.wait_seconds
    marker = re.compile(r'scenario phase=' + re.escape(args.phase) + r' second=(\d+)\b')
    while time.monotonic() < deadline:
        if args.runner_pid not in processes():
            raise RuntimeError('runner exited before profiling trigger')
        log = directory / 'load-0.log'
        text = log.read_text() if log.exists() else ''
        seconds = [int(value) for value in marker.findall(text)]
        if seconds and max(seconds) >= args.after_phase_seconds:
            break
        time.sleep(.5)
    else:
        raise TimeoutError('measured phase was not observed before profiling deadline')
    evidence = json.loads((directory.parent / 'evidence.json').read_text())
    if not evidence.get('scaledDiagnostic'):
        raise RuntimeError('stack profiling is restricted to explicitly scaled diagnostics')
    output = directory / 'stack-profiles'
    output.mkdir(mode=0o700)
    observation = dict(phase=args.phase, observedPhaseSecond=max(seconds),
                       triggerObservedAt=time.time(), runnerPID=args.runner_pid,
                       profilingOverhead=True, excludedFromCapacityComparison=True)
    targets = select_targets(directory, args.runner_pid, processes())
    with ThreadPoolExecutor(max_workers=4) as executor:
        observation['samples'] = list(executor.map(
            lambda target: capture(target, output, args.duration_seconds), targets))
    result = output / 'manifest.json'
    descriptor = os.open(result, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        json.dump(observation, stream, indent=2)
        stream.write('\n')
    print(json.dumps(dict(profileManifest=str(result),
                         captured=sum(row['status'] == 'captured' for row in observation['samples']))))


if __name__ == '__main__':
    main()
