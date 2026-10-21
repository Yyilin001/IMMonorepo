#!/usr/bin/env python3
"""Launch one owned benchmark process in a Colima VM with a bounded watchdog.

Configuration and evidence paths must be on the explicit shared workspace mount.
The shared filesystem is orchestration only; business sockets use VM addresses.
No SSH connection failure is interpreted as proof the remote process has exited.
"""
import argparse
import ipaddress
import json
import os
import re
import resource
from pathlib import Path
import signal
import subprocess
import sys
import time
import uuid
import urllib.request


def validate_deployment(configuration, nodes, parts):
    processes = configuration['processes']
    names = ['account', 'placement-a', 'placement-b', 'placement-c']
    names += [f'{role}-{i}' for role, count in [('gateway', nodes), ('edge', nodes), ('load', parts)] for i in range(count)]
    if configuration.get('ingress'):
        names.append('ingress')
    for name in names:
        node = processes[name]
        if not node['profile'].startswith('imv2-growth-'):
            raise ValueError('remote benchmark requires explicitly owned imv2-growth-* VMs')
        for key in ('host', 'managementHost'):
            address = ipaddress.ip_address(node[key])
            if address.is_loopback or address.is_unspecified:
                raise ValueError('server endpoint must be a non-loopback VM address')
        if not re.fullmatch(r'[a-z0-9][a-z0-9.-]*\.imv2\.test', node['dns']):
            raise ValueError('benchmark TLS names must use the isolated imv2.test domain')
    gateways = [processes[f'gateway-{i}'] for i in range(nodes)]
    if len({n['profile'] for n in gateways}) != nodes or len({n['host'] for n in gateways}) != nodes:
        raise ValueError('each business server must have its own VM and address')
    if any(processes[f'edge-{i}']['profile'] != processes['account']['profile'] for i in range(nodes)):
        raise ValueError('HTTPS edges must share the Account loopback namespace')
    loaders = {processes[f'load-{i}']['profile'] for i in range(parts)}
    if loaders.intersection(n['profile'] for n in gateways):
        raise ValueError('load generators must run outside business VMs')
    ipaddress.ip_address(configuration['postgresHost'])
    if not Path(configuration['runtime']).is_absolute():
        raise ValueError('shared runtime path must be absolute')


def endpoint(args, name):
    path = getattr(args, 'server_deployment', None)
    if path is None:
        return '127.0.0.1'
    return json.loads(Path(path).read_text())['processes'][name]['host']


def hostname(args, name):
    path = getattr(args, 'server_deployment', None)
    return json.loads(Path(path).read_text())['processes'][name]['dns'] if path else 'localhost'


def management_endpoint(args, name):
    path = getattr(args, 'server_deployment', None)
    return json.loads(Path(path).read_text())['processes'][name]['managementHost'] if path else '127.0.0.1'


def gateway_metrics(args, index, suffix=''):
    url = f'http://127.0.0.1:{args.metrics_port+index}/metrics{suffix}'
    if getattr(args, 'server_deployment', None):
        node = json.loads(Path(args.server_deployment).read_text())['processes'][f'gateway-{index}']
        script = ('import urllib.request,sys; '
                  f'sys.stdout.buffer.write(urllib.request.urlopen({url!r},timeout=1).read(4*1024*1024))')
        return subprocess.check_output(['colima', '-p', node['profile'], 'ssh', '--',
                                        'python3', '-c', script], text=True, timeout=5, stderr=subprocess.DEVNULL)
    with urllib.request.urlopen(url, timeout=1) as response:
        return response.read(4*1024*1024).decode('utf-8')


def remote_command(config, name, command, environment, directory):
    deployment = json.loads(Path(config).read_text())
    node = deployment['processes'][name]
    root = Path(directory) / ('remote-' + name + '-' + uuid.uuid4().hex[:8])
    root.mkdir(mode=0o700)
    runtime = Path(deployment['runtime'])
    if Path(command[0]).name.startswith('IMV2'):
        if Path(command[0]).resolve() != (runtime / 'bin' / Path(command[0]).name).resolve():
            raise ValueError('remote executable must be the exact binary recorded by the runner')
        command = [str(runtime / 'lib/ld-linux-aarch64.so.1'), '--library-path',
                   ':'.join(str(runtime / p) for p in ('usr/lib/swift/linux', 'lib/aarch64-linux-gnu')),
                   str(runtime / 'bin' / Path(command[0]).name)] + command[1:]
    elif command[0] == 'python3':
        command[0] = '/usr/bin/python3'
    # Do not propagate macOS loader, shell, proxy or unrelated credential state.
    env = {k: v for k, v in (environment or {}).items() if k.startswith(('IM_V2_', 'IMV2_'))}
    spec = dict(profile=node['profile'], command=command, environment=env,
                cwd=str(Path(__file__).resolve().parents[2]), name=name)
    (root / 'spec.json').write_text(json.dumps(spec))
    (root / 'spec.json').chmod(0o600)
    return [sys.executable, str(Path(__file__).resolve()), '--controller', str(root)]


def worker(root):
    spec = json.loads((root / 'spec.json').read_text())
    env = dict(os.environ, **spec['environment'])
    _, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    resource.setrlimit(resource.RLIMIT_NOFILE, (hard, hard))
    child = subprocess.Popen(spec['command'], env=env, cwd=spec['cwd'], start_new_session=True)
    (root / 'started.json').write_text(json.dumps(dict(pid=child.pid, time=time.time(), nofile=hard)))
    deadline = None
    stop_started = None
    forced = False
    reason = None
    sampled = 0
    while child.poll() is None:
        now = time.time()
        if now - sampled >= 5:
            values = dict(time=now, pid=child.pid, ticksPerSecond=os.sysconf('SC_CLK_TCK'))
            for label, path in {'processStat': f'/proc/{child.pid}/stat',
                                'processStatus': f'/proc/{child.pid}/status',
                                'systemStat': '/proc/stat', 'memory': '/proc/meminfo',
                                'network': '/proc/net/dev', 'tcpStatistics': '/proc/net/netstat',
                                'sockets': '/proc/net/sockstat',
                                'conntrackCount': '/proc/sys/net/netfilter/nf_conntrack_count',
                                'conntrackMaximum': '/proc/sys/net/netfilter/nf_conntrack_max'}.items():
                try:
                    values[label] = Path(path).read_text()
                except OSError:
                    values[label] = None
            try:
                values['openFileDescriptors'] = len(list(Path(f'/proc/{child.pid}/fd').iterdir()))
            except OSError:
                values['openFileDescriptors'] = None
            with (root / 'resources.jsonl').open('a') as stream:
                stream.write(json.dumps(values) + '\n')
            sampled = now
        if deadline is None:
            heartbeat = root / 'heartbeat'
            stale = not heartbeat.exists() or now - heartbeat.stat().st_mtime > 15
            if (root / 'stop').exists() or stale:
                reason = 'requested' if (root / 'stop').exists() else 'controller_lost'
                # HAProxy uses SIGUSR1 for a soft stop after clients have drained.
                stop_signal = (signal.SIGUSR1 if spec['name'] == 'ingress' and
                               spec['command'][0] == '/usr/sbin/haproxy' else signal.SIGTERM)
                os.killpg(child.pid, stop_signal)
                stop_started = time.monotonic()
                deadline = stop_started + 30
                (root / 'stop-requested.json').write_text(json.dumps(dict(
                    time=time.time(), signal=stop_signal.name, reason=reason, graceSeconds=30)))
        elif time.monotonic() >= deadline:
            os.killpg(child.pid, signal.SIGKILL)
            forced = True
            break
        time.sleep(.2)
    code = child.wait()
    result = dict(pid=child.pid, exitCode=code, forced=forced, stopReason=reason, time=time.time(),
                  shutdownElapsedSeconds=time.monotonic()-stop_started if stop_started is not None else None,
                  shutdownGraceSeconds=30)
    temporary = root / 'finished.tmp'
    temporary.write_text(json.dumps(result))
    temporary.replace(root / 'finished.json')
    return code if code >= 0 else 128 - code


def controller(root):
    spec = json.loads((root / 'spec.json').read_text())
    def stop(*_):
        (root / 'stop').touch()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    (root / 'heartbeat').touch()
    ssh = subprocess.Popen(['colima', '-p', spec['profile'], 'ssh', '--',
                            'python3', str(Path(__file__).resolve()), '--worker', str(root)])
    while ssh.poll() is None:
        (root / 'heartbeat').touch()
        time.sleep(.2)
    if not (root / 'finished.json').exists():
        stop()
        # The shared stop file or loss of heartbeat causes remote drain. Retain
        # uncertainty if the worker cannot publish its authoritative exit record.
        until = time.monotonic() + 50
        while time.monotonic() < until and not (root / 'finished.json').exists():
            time.sleep(.2)
    if not (root / 'finished.json').exists():
        print('remote process exit unconfirmed; inspect ' + str(root), file=sys.stderr)
        return 125
    result = json.loads((root / 'finished.json').read_text())
    if result['forced'] or result['stopReason'] == 'controller_lost':
        return 124
    return result['exitCode'] if result['exitCode'] >= 0 else 128 - result['exitCode']


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--controller', type=Path)
    mode.add_argument('--worker', type=Path)
    args = parser.parse_args()
    sys.exit(controller(args.controller) if args.controller else worker(args.worker))
