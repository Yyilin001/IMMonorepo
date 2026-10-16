#!/usr/bin/env python3
"""Run one benchmark-owned process in its resource-limited simulation container.

Only an explicitly supplied private configuration enables this adapter. Native
benchmark runs do not access Docker. Containers share the controller's isolated
network namespace (loopback transport); this is not a physical-network test.
"""
import argparse
import http.client
import json
import os
from pathlib import Path
import signal
import socket
import struct
import sys
import threading
import time
import uuid


class DockerConnection(http.client.HTTPConnection):
    def __init__(self, timeout=30, socket_path='/var/run/docker.sock'):
        super().__init__('localhost', timeout=timeout)
        self.socket_path = socket_path
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.socket_path)


def request(method, path, body=None, *, socket_path='/var/run/docker.sock'):
    connection = DockerConnection(socket_path=socket_path)
    try:
        data = json.dumps(body).encode() if body is not None else None
        connection.request(method, '/v1.41' + path, body=data,
                           headers={'Content-Type': 'application/json'})
        response = connection.getresponse()
        data = response.read()
        if response.status >= 400:
            raise RuntimeError('docker_operation_failed_' + str(response.status))
        return json.loads(data) if data else None
    finally:
        connection.close()


def role_for(name):
    if name.startswith('gateway-'): return 'gateway', int(name.split('-')[1])
    if name.startswith('edge-'): return 'edge', int(name.split('-')[1])
    if name.startswith(('load-', 'loader-', 'prefill-loader-')): return 'loader', None
    return 'infrastructure', None


def specification(configuration, name, command, environment):
    role, ordinal = role_for(name)
    budget = dict(configuration['roles'][role])
    if ordinal is not None:
        budget['cpuset'] = str(configuration['gatewayCPUs'][ordinal])
    return dict(Image=configuration['image'], Entrypoint=[], Cmd=command,
        WorkingDir='/workspace', Env=[key+'='+value for key, value in environment.items()],
        Labels={'imv2.scale.run': configuration['runID'], 'imv2.scale.process': name,
                'imv2.scale.family': configuration['familyID'],
                'imv2.scale.role': role},
        HostConfig=dict(NetworkMode='container:'+configuration['networkContainer'],
            Mounts=configuration['mounts'], CpusetCpus=budget['cpuset'],
            NanoCpus=int(budget['cpus']*1_000_000_000), Memory=budget['memoryBytes'],
            MemorySwap=budget['memoryBytes'], Ulimits=[dict(Name='nofile', Soft=200000, Hard=200000)],
            SecurityOpt=['no-new-privileges:true']))


def copy_logs(container):
    connection = DockerConnection(timeout=None)
    try:
        connection.request('GET', '/v1.41/containers/'+container+'/logs?stdout=1&stderr=1&follow=1')
        response = connection.getresponse()
        if response.status != 200: return
        while True:
            header = response.read(8)
            if not header: return
            if len(header) != 8: raise RuntimeError('docker_log_header_truncated')
            size = struct.unpack('>I', header[4:])[0]
            remaining = size
            while remaining:
                data = response.read(min(remaining, 65536))
                if not data: raise RuntimeError('docker_log_payload_truncated')
                sys.stdout.buffer.write(data); sys.stdout.buffer.flush()
                remaining -= len(data)
    finally:
        connection.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configuration', required=True, type=Path)
    parser.add_argument('--name', required=True)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    configuration = json.loads(args.configuration.read_text())
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command: parser.error('process command is empty')
    name = configuration['runID']+'-'+args.name+'-'+uuid.uuid4().hex[:6]
    container = request('POST', '/containers/create?name='+name,
        specification(configuration, args.name, command, dict(os.environ)))['Id']
    def terminate(signum, _):
        try: request('POST', '/containers/'+container+'/kill?signal='+signal.Signals(signum).name)
        except RuntimeError: pass  # already exited
    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)
    # Retain only resource and lifecycle evidence, never injected credentials.
    evidence = Path(configuration['evidenceDirectory'])/(name+'.json')
    evidence.parent.mkdir(parents=True, exist_ok=True)
    body = dict(id=container, name=name, process=args.name, startedAt=time.time(),
                role=role_for(args.name)[0])
    evidence.write_text(json.dumps(body)); evidence.chmod(0o600)
    request('POST', '/containers/'+container+'/start')
    logs = threading.Thread(target=copy_logs, args=(container,), daemon=True); logs.start()
    while True:
        state = request('GET', '/containers/'+container+'/json')['State']
        if not state['Running']: break
        time.sleep(.25)
    logs.join(timeout=5)
    body.update(endedAt=time.time(), exitCode=state['ExitCode'], oomKilled=state['OOMKilled'])
    evidence.write_text(json.dumps(body))
    return state['ExitCode']


if __name__ == '__main__':
    raise SystemExit(main())
