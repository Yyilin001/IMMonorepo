#!/usr/bin/env python3
"""Summarize completed App recovery evidence without treating missing data as zero.

This reads XCTest evidence only; HTTP/database acceptance remains a separate gate.
Resource peaks cover sampled processes, not the whole system. Logical traffic
excludes TLS, notifications and handshakes. Older reconnect runs may have counted
only the final connection; those cycles are explicitly marked unverified.
"""
import argparse
import json
from pathlib import Path
import re


def summarize(directory):
    summary = json.loads((directory / 'app-summary.json').read_text())
    if summary.get('result') != 'Passed' or summary.get('failedTests') != 0:
        raise ValueError(f'{directory}: App acceptance did not pass')
    log = (directory / 'app.log').read_text()
    match = re.search(r'IMV2_TLS_ROOM_RECOVERY_SCALE_PASSED rooms=(\d+)', log)
    if not match:
        raise ValueError(f'{directory}: recovery completion marker missing')
    rooms = int(match[1])
    cycles = []
    for cycle in (0, 1):
        scope = rf'rooms={rooms} cycle={cycle}'
        elapsed = re.findall(rf'IMV2_TLS_ROOM_RECOVERY_SCALE {scope} catchup=([\d.]+) seconds', log)
        ready = re.findall(rf'IMV2_TLS_ROOM_LIST_READY {scope} elapsed=([\d.]+) seconds', log)
        traffic = re.findall(rf'IMV2_TLS_ROOM_RECOVERY_REQUESTS {scope} commands=\[([^\]]*)\] logicalSentBytes=(\d+) logicalReceivedBytes=(\d+)', log)
        reconnects = len(re.findall(rf'IMV2_TLS_ROOM_RECOVERY_RECONNECT {scope} attempt=', log))
        if len(elapsed) != 1:
            raise ValueError(f'{directory}: cycle {cycle} is missing or ambiguous')
        entry = dict(cycle=cycle, catchupSeconds=float(elapsed[0]),
                     localListReadySeconds=float(ready[0]) if ready else None,
                     reconnectCount=reconnects, traffic=None)
        if len(traffic) == 1:
            commands, sent, received = traffic[0]
            entry['traffic'] = dict(commands={key: int(value) for key, value in
                re.findall(r'(\d+):\s*(\d+)', commands)}, logicalSentBytes=int(sent),
                logicalReceivedBytes=int(received),
                scope='cycle' if reconnects == 0 else 'requires_meter_version_verification')
        cycles.append(entry)
    resource_path = directory / 'scale-resource-samples.json'
    resources = None
    if resource_path.exists():
        samples = json.loads(resource_path.read_text())
        resources = dict(errors=[row['error'] for row in samples if 'error' in row], processes=[])
        identities = sorted({(row['role'], row['pid']) for row in samples if 'role' in row})
        for role, pid in identities:
            rows = [row for row in samples if row.get('role') == role and row.get('pid') == pid]
            resources['processes'].append(dict(role=role, pid=pid, sampleCount=len(rows),
                sampledSeconds=max(row['time'] for row in rows)-min(row['time'] for row in rows),
                peakRSSBytes=max(row['rssBytes'] for row in rows)))
    return dict(directory=str(directory.resolve()), rooms=rooms, cycles=cycles,
        appPassedTests=summary.get('passedTests'), appSkippedTests=summary.get('skippedTests'),
        resources=resources)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directories', nargs='+', type=Path)
    parser.add_argument('--output', required=True, type=Path, help='new JSON output; never overwrite evidence')
    args = parser.parse_args()
    results = [summarize(directory) for directory in args.directories]
    with args.output.open('x') as output:
        json.dump(results, output, indent=2)
        output.write('\n')


if __name__ == '__main__':
    main()
