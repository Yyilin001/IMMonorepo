"""Admit certified live benchmark gateways to the running HAProxy ingress.

The operation changes only new-connection routing. Existing TCP connections are
not redistributed, and health readiness is not proof of client distribution.
"""
import ipaddress
import json
from pathlib import Path
import subprocess
import time

from v2_benchmark_ingress import capture, enabled
from v2_benchmark_remote_process import gateway_metrics
from wait_v2_gateway_membership import matches, parse_observation


def runtime_command(info, command):
    if '\n' in command or '\r' in command:
        raise ValueError('one ingress command required')
    script = '''import json,socket,sys
request=json.load(sys.stdin)
with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as client:
 client.settimeout(3)
 client.connect(request['socket'])
 client.sendall((request['command']+'\\n').encode())
 client.shutdown(socket.SHUT_WR)
 data=[]
 while True:
  chunk=client.recv(65536)
  if not chunk:break
  data.append(chunk)
 sys.stdout.buffer.write(b''.join(data))
'''
    result = subprocess.run(['colima', '-p', info['profile'], 'ssh', '--', 'python3', '-c', script],
                            input=json.dumps(dict(socket=info['socket'], command=command)),
                            capture_output=True, text=True, timeout=5, check=True)
    return result.stdout


def admit(args, directory, indices, target_count, membership_revision):
    """Require full certified membership before allowing new connections."""
    directory = Path(directory)
    indices = tuple(indices)
    if (not enabled(args) or not indices or len(set(indices)) != len(indices)
            or not 2 <= target_count <= 8 or membership_revision < 1
            or any(not isinstance(i, int) or not 0 <= i < target_count for i in indices)):
        raise ValueError('invalid ingress expansion')
    deployment = json.loads(Path(args.server_deployment).read_text())
    info = json.loads((directory/'ingress.json').read_text())
    endpoints = {}
    for index in indices:
        address = ipaddress.ip_address(deployment['processes'][f'gateway-{index}']['host'])
        host = f'[{address}]' if address.version == 6 else str(address)
        port = args.gateway_port + index
        if not 1 <= port <= 65535:
            raise ValueError('invalid gateway port')
        endpoints[f'gateway-{index}'] = f'{host}:{port}'
    observations = {i: parse_observation(gateway_metrics(args, i)) for i in range(target_count)}
    if not all(matches(value, membership_revision, target_count) for value in observations.values()):
        raise RuntimeError('ingress admission requires every target gateway to confirm membership and qualification')
    evidence = dict(status='applying', membershipRevision=membership_revision,
                    targetCount=target_count, endpoints=endpoints, observations=observations, commands=[])
    path = directory/f'ingress-growth-r{membership_revision}.json'
    def save():
        temporary = path.with_suffix('.tmp')
        temporary.write_text(json.dumps(evidence, indent=2)+'\n')
        temporary.replace(path)
    save()
    try:
        rows = capture(args, directory, f'ingress-before-r{membership_revision}.csv')
        existing = {r['svname']: r for r in rows if r.get('# pxname') == 'gateways'}
        for name, endpoint in endpoints.items():
            commands = []
            if name in existing:
                if existing[name].get('addr') != endpoint:
                    raise RuntimeError('existing ingress gateway address differs from deployment')
            else:
                commands.append(f'add server gateways/{name} {endpoint} check inter 1s rise 1 fall 2')
            commands += [f'enable health gateways/{name}', f'enable server gateways/{name}']
            for command in commands:
                record = dict(command=command, status='submitted')
                evidence['commands'].append(record); save()
                response = runtime_command(info, command)
                record.update(status='replied', response=response); save()
                if response.strip() not in ('', 'New server registered.'):
                    raise RuntimeError('ingress runtime command rejected; response preserved in evidence')
        deadline = time.monotonic()+15
        while True:
            rows = capture(args, directory, f'ingress-after-r{membership_revision}.csv')
            current = {r['svname']: r for r in rows if r.get('# pxname') == 'gateways'}
            if all(current.get(name, {}).get('status') == 'UP'
                   and current[name].get('addr') == endpoint for name, endpoint in endpoints.items()):
                evidence['status'] = 'ready'; evidence['completedAt'] = time.time(); save()
                return evidence
            if time.monotonic() >= deadline:
                raise TimeoutError('new ingress gateways did not become healthy')
            time.sleep(.2)
    except Exception as error:
        evidence.update(status='unconfirmed', error=type(error).__name__); save()
        raise
