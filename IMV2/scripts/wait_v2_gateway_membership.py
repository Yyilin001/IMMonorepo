#!/usr/bin/env python3
"""Wait for running gateways to confirm one committed membership version.

Read-only diagnostic for the owned benchmark deployment. A successful control
commit is not a substitute for this runtime observation. This gate does not
prove message correctness or authorize finalization by itself.
"""
import argparse
import json
from pathlib import Path
import re
import time

from v2_benchmark_remote_process import gateway_metrics

PREFIX = 'im_v2_room_membership_'
FIELDS = ('revision', 'confirmed', 'configured_hosts', 'healthy_hosts',
          'realtime_revision', 'realtime_qualified')


def parse_observation(body):
    values = {}
    for line in body.splitlines():
        if not line.startswith(PREFIX):
            continue
        parts = line.split()
        if len(parts) != 2 or not parts[0].startswith(PREFIX):
            raise ValueError('malformed membership sample')
        field = parts[0][len(PREFIX):]
        if field not in FIELDS or field in values or not re.fullmatch(r'0|[1-9][0-9]*', parts[1]):
            raise ValueError('unknown, duplicate or noninteger membership sample')
        values[field] = int(parts[1])
    return values


def matches(value, revision, hosts, retired=False):
    return value == dict(revision=revision, confirmed=1, configured_hosts=hosts,
                        healthy_hosts=hosts, realtime_revision=revision,
                        realtime_qualified=0 if retired else 1)


def wait(args, fetch=gateway_metrics, now=time.monotonic, sleep=time.sleep):
    deadline = now() + args.timeout_seconds
    consecutive = 0
    last = {}
    rounds = 0
    targets = [(node, False) for node in args.gateway] + [(node, True) for node in args.retired_gateway]
    while now() < deadline:
        last = {}
        complete = True
        for node, retired in targets:
            if now() >= deadline:
                complete = False
                break
            try:
                sample = parse_observation(fetch(args, node))
                ready = matches(sample, args.revision, args.hosts, retired)
                last[str(node)] = dict(matches=ready, retired=retired, sample=sample)
            except Exception as error:
                ready = False
                last[str(node)] = dict(matches=False, retired=retired, error=type(error).__name__)
            complete = complete and ready
        rounds += 1
        consecutive = consecutive + 1 if complete else 0
        if consecutive >= 3 and now() < deadline:
            return dict(status='confirmed', revision=args.revision, rounds=rounds, observations=last)
        remaining = deadline - now()
        if remaining > 0:
            sleep(min(1, remaining))
    return dict(status='unconfirmed', revision=args.revision, rounds=rounds, observations=last)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--server-deployment', type=Path)
    parser.add_argument('--gateway', type=int, action='append', required=True)
    parser.add_argument('--retired-gateway', type=int, action='append', default=[])
    parser.add_argument('--metrics-port', type=int, required=True)
    parser.add_argument('--revision', type=int, required=True)
    parser.add_argument('--hosts', type=int, required=True)
    parser.add_argument('--timeout-seconds', type=int, default=60)
    args = parser.parse_args()
    nodes = args.gateway + args.retired_gateway
    if (len(nodes) > 64 or len(set(nodes)) != len(nodes) or any(not 0 <= n < 64 for n in nodes)
            or not 1 <= args.revision < 2**64 or not 1 <= args.hosts <= 64
            or not 1024 <= args.metrics_port <= 65472 or not 3 <= args.timeout_seconds <= 600):
        parser.error('invalid or overlapping targets, revision, capacity, port or timeout')
    if args.server_deployment:
        deployment = json.loads(args.server_deployment.read_text())
        for node in nodes:
            profile = deployment['processes'][f'gateway-{node}']['profile']
            if not re.fullmatch(r'imv2-growth-[a-z0-9-]+', profile):
                parser.error('remote observations require an owned growth-test VM')
    result = wait(args)
    print(json.dumps(result, sort_keys=True))
    return 0 if result['status'] == 'confirmed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
