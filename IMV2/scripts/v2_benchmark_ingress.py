"""Real HAProxy TCP ingress for the owned multi-VM benchmark."""
import json
import csv
from pathlib import Path
import subprocess
import uuid


def enabled(args):
    path = getattr(args, 'server_deployment', None)
    return bool(path and json.loads(Path(path).read_text()).get('ingress'))


def prepare(args, actors):
    if not enabled(args):
        return
    config = json.loads(args.server_deployment.read_text())
    name = config['processes']['ingress']['dns']
    directory = actors/'public-ingress'
    directory.mkdir(mode=0o700)
    extensions = directory/'extensions.cnf'
    extensions.write_text('basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n'
                          'extendedKeyUsage=serverAuth\nsubjectAltName=DNS:'+name+'\n')
    commands = [
        ['openssl','req','-new','-newkey','ec','-pkeyopt','ec_paramgen_curve:P-256','-nodes',
         '-keyout',str(directory/'tls.key'),'-out',str(directory/'tls.csr'),'-subj','/CN='+name],
        ['openssl','x509','-req','-in',str(directory/'tls.csr'),'-CA',str(actors/'ca/cert.pem'),
         '-CAkey',str(actors/'ca/key.pem'),'-CAcreateserial','-days','7',
         '-extfile',str(extensions),'-out',str(directory/'tls.pem')]]
    with (directory/'provision.log').open('w') as log:
        for command in commands:
            subprocess.run(command,check=True,stdout=log,stderr=subprocess.STDOUT)
    (directory/'tls.key').chmod(0o600)


def start(args, directory, count, spawn):
    if not enabled(args):
        return None
    config = json.loads(args.server_deployment.read_text())
    socket = '/tmp/imv2-growth-ingress-'+uuid.uuid4().hex+'.sock'
    port = args.gateway_port + 32
    lines = ['global','  maxconn 100000','  stats socket '+socket+' mode 600 level admin',
             'defaults','  mode tcp','  timeout connect 5s','  timeout client 10m',
             '  timeout server 10m','frontend clients','  bind 0.0.0.0:'+str(port),
             # Sessions survive every expansion. Round-robin over only new
             # connections compounds the old gateways' existing session load.
             '  default_backend gateways','backend gateways','  balance leastconn']
    for i in range(count):
        host = config['processes'][f'gateway-{i}']['host']
        lines.append(f'  server gateway-{i} {host}:{args.gateway_port+i} check inter 1s rise 1 fall 2')
    path = directory/'haproxy.cfg'
    path.write_text('\n'.join(lines)+'\n')
    (directory/'ingress.json').write_text(json.dumps(dict(port=port, socket=socket,
        profile=config['processes']['ingress']['profile'], mode='TCP TLS passthrough',
        balance='leastconn', existingConnectionsRedistributed=False)))
    return spawn(['/usr/sbin/haproxy','-db','-f',str(path)], 'ingress')


def capture(args, directory, filename='ingress-stats.csv'):
    if not enabled(args):
        return
    info = json.loads((directory/'ingress.json').read_text())
    script = ('import socket,sys; s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.settimeout(3); '
              f's.connect({info["socket"]!r}); s.sendall(b"show stat\\n"); s.shutdown(socket.SHUT_WR); '
              'data=[]\nwhile True:\n b=s.recv(65536)\n if not b:break\n data.append(b)\n'
              's.close(); sys.stdout.buffer.write(b"".join(data))')
    result = subprocess.run(['colima','-p',info['profile'],'ssh','--','python3','-c',script],
                            capture_output=True,timeout=5,check=True)
    (directory/filename).write_bytes(result.stdout)
    return list(csv.DictReader(result.stdout.decode().splitlines()))


def ready(args, directory, count):
    if not enabled(args):
        return True
    try:
        rows = capture(args, directory, 'ingress-ready-stats.csv')
        up = {r['svname'] for r in rows if r.get('status') == 'UP'}
        return all(f'gateway-{i}' in up for i in range(count))
    except (OSError, subprocess.SubprocessError, ValueError):
        return False
