#!/usr/bin/env python3
"""Opt-in native resource acceptance with owned PostgreSQL, Actor nodes and TLS.

No existing database, .env, Keychain trust, container or listening service is
modified. Private keys and bytes live in a temporary directory. Output contains
only process/test logs and aggregate evidence; never credentials or signed URLs.

--slow-resource selects only the dedicated slow upload scenario. The HTTPS
fixture arm/state/release endpoints require X-Resource-Fixture and gate one PUT
body after its first 16KiB for at most 45s; account control and Gateway TLS remain
unpaused. Successful evidence requires real control/cursor assertions in that
scenario, followed by a completed upload and drained gate.
"""
import argparse
import base64
import collections
import hashlib
import http.client
import http.server
import json
import os
import plistlib
from pathlib import Path
import re
import resource
import shutil
import signal
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import zlib
from v2_live_author_capacity import AuthorCapacityFixture

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'IMV2/scripts'))
from v2_native_placement_processes import voter_arguments, start_controls


def oss_validation_parent(value):
    # A scoped ECS role may allow only e.g. ecs-test/*. Always put this run in
    # a fresh validation/native-UUID child, never directly in a business prefix.
    if len(value.encode()) > 128 or not re.fullmatch(r'(?:[A-Za-z0-9_-]+/)*validation/', value):
        raise argparse.ArgumentTypeError('OSS test parent must be a relative safe prefix ending in validation/')
    return value


def free_port():
    with socket.socket() as connection:
        connection.bind(('127.0.0.1', 0))
        return connection.getsockname()[1]


class FixtureHTTPUpstream:
    """One sequential keep-alive connection owned by one downstream handler.

    Per-request reconnects exhaust local ephemeral ports during the byte phase.
    Failed requests are never replayed: a POST may already have committed.
    """
    def __init__(self, port):
        self.port = port
        self.connection = None

    def request(self, method, path, body, headers, timeout=20):
        if self.connection is None:
            self.connection = http.client.HTTPConnection('127.0.0.1', self.port, timeout=timeout)
        connection = self.connection
        connection.timeout = timeout
        if connection.sock is not None:
            connection.sock.settimeout(timeout)
        try:
            connection.request(method, path, body, headers)
            response = connection.getresponse()
            return response.status, response.getheaders(), response.read()
        except Exception:
            self.close()
            raise

    def close(self):
        if self.connection is not None:
            self.connection.close()
            self.connection = None


def wait_listener(process, port):
    deadline = time.monotonic() + 60
    while process.poll() is None:
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=.2):
                return
        except OSError:
            if time.monotonic() >= deadline:
                break
            time.sleep(.1)
    raise RuntimeError('owned service failed its listener startup; inspect process log')


def stop(process):
    # All callers below mark their start_new_session children at launch. Never
    # derive a group from an inherited/shared child or from the current process.
    group = getattr(process, '_owned_process_group', None)
    if group != process.pid or group == os.getpgrp():
        raise RuntimeError('refusing cleanup of an unowned process group')

    def group_exists():
        process.poll()  # Reap the leader even when only descendants remain.
        try:
            os.killpg(group, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            # Darwin may report EPERM after a short-lived group has vanished.
            # Establish absence independently; an extant inaccessible group
            # remains a cleanup failure and must never be treated as drained.
            rows = subprocess.check_output(['ps', '-axo', 'pgid=,stat='], text=True)
            members = [row.split()[1] for row in rows.splitlines()
                       if len(row.split()) == 2 and int(row.split()[0]) == group]
            # A zombie has already exited and cannot retain I/O or descendants.
            # Reaping the owned leader can race Darwin's final group teardown.
            if not members or all(state.startswith('Z') for state in members):
                return False
            return True

    def signal_group(value):
        try:
            os.killpg(group, value)
        except ProcessLookupError:
            pass
        except PermissionError:
            # An exiting Darwin group may still be visible while signals are
            # already refused. Keep the bounded drain obligation: only an
            # independently observed absence can complete cleanup. A group
            # that remains alive still fails after TERM/KILL drain budgets.
            pass

    def drain(seconds):
        deadline = time.monotonic() + seconds
        while group_exists():
            if time.monotonic() >= deadline:
                return False
            time.sleep(.05)
        return True

    if group_exists():
        signal_group(signal.SIGTERM)
        if not drain(90):
            signal_group(signal.SIGKILL)
            if not drain(10):
                raise RuntimeError('owned process group failed to drain')
    process.wait(timeout=10)


def compose_defaults(name):
    text = (ROOT / 'IMV2/docker-compose.local-account.yml').read_text()
    block = re.split(r'\n  [a-z][\w-]*:\n', text.split('\n  ' + name + ':\n', 1)[1], maxsplit=1)[0]
    return {key: value.strip('"\'') for key, value in
            re.findall(r'^      (IM_V2_[A-Z0-9_]+): (.+)$', block, re.M)
            if '${' not in value}


class SlowUploadGate:
    """One owned upstream body gate; no capability, URL or body is retained."""
    def __init__(self):
        self.condition = threading.Condition()
        self.release_event = threading.Event()
        self.armed = False
        self.closed = False
        self.connection = None
        self.hits = self.body_bytes = self.active = self.completed = self.expired = 0
        self.waiting = self.released = False

    def snapshot(self):
        with self.condition:
            return dict(hits=self.hits, bodyBytesRead=self.body_bytes, waiting=self.waiting,
                        active=self.active, completed=self.completed, expired=self.expired, released=self.released)

    def arm(self):
        with self.condition:
            if self.closed or self.armed or self.hits:
                return False
            self.armed = True
            return True

    def claim(self, connection):
        with self.condition:
            if self.closed or not self.armed:
                return False
            self.armed = False
            self.hits += 1
            self.active += 1
            self.connection = connection
            return True

    def read(self, handler, length):
        # A remaining body is essential: a completed upload followed by a delayed
        # response is not evidence of slow up-stream bytes.
        if length <= 16384:
            raise ValueError('slow upload requires a body larger than 16KiB')
        handler.connection.settimeout(5)
        prefix = handler.rfile.read(16384)
        if len(prefix) != 16384:
            raise ValueError('short upload body')
        with self.condition:
            self.body_bytes += len(prefix)
            self.waiting = True
        if not self.release_event.wait(timeout=45):
            with self.condition:
                self.expired += 1
            raise TimeoutError('owned upload gate deadline exceeded')
        with self.condition:
            self.waiting = False
            if self.closed:
                raise ConnectionError('owned upload gate is closing')
        handler.connection.settimeout(20)
        remainder = handler.rfile.read(length - len(prefix))
        with self.condition:
            self.body_bytes += len(remainder)
        if len(remainder) != length - len(prefix):
            raise ValueError('short upload body')
        return prefix + remainder

    def release(self):
        with self.condition:
            self.released = True
        self.release_event.set()

    def finish(self, success):
        with self.condition:
            self.completed += int(success)
            self.active -= 1
            self.waiting = False
            self.connection = None
            self.condition.notify_all()

    def close_and_drain(self):
        with self.condition:
            self.closed = True
            connection = self.connection
        self.release()
        if connection is not None:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        deadline = time.monotonic() + 10
        with self.condition:
            while self.active:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise RuntimeError('owned slow upload handler did not drain')
                self.condition.wait(timeout=remaining)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='new evidence directory')
    parser.add_argument('--configuration', choices=('debug', 'release'), default='debug',
                        help='Swift build configuration for the owned services and native ClientKit test')
    parser.add_argument('--slow-resource', action='store_true', help='one opt-in slow signed-byte upload with concurrent typed control and TLS cursor progress')
    parser.add_argument('--extended-acceptance', action='store_true', help='also run typed message and group operation acceptance against the owned stack')
    parser.add_argument('--nickname-directory-only', action='store_true', help='real multi-page nickname reads with two independently issued devices')
    parser.add_argument('--author-capacity', type=int, metavar='PARTICIPANTS', help='2..10000 real TLS/ClientKit participants with PostgreSQL query counters')
    parser.add_argument('--author-client-processes', type=int, default=1, help='independent ClientKit processes sharing the same capacity room (1..32)')
    parser.add_argument('--author-gateway-processes', type=int, default=1,
                        help='independent Gateway/Actor processes in one capacity cluster (1..4)')
    parser.add_argument('--author-renewal-seconds', type=int, default=0,
                        help='hold every capacity presentation across grant renewal (35..120 seconds, 0 disables)')
    parser.add_argument('--author-avatar-replacement', action='store_true',
                        help='replace the author avatar without another message and verify every capacity recipient')
    parser.add_argument('--author-faults', action='store_true',
                        help='combine a bounded profile database lock with one real slow TLS connection per process')
    parser.add_argument('--oss', action='store_true', help='use a private OSS bucket with runtime credentials for the owned resource stack')
    parser.add_argument('--oss-test-parent', type=oss_validation_parent, default='validation/',
                        help='authorized parent for a fresh validation/native-UUID namespace, e.g. ecs-test/validation/')
    parser.add_argument('--resource-center', action='store_true', help='require resource-center and group-avatar scenarios only, with real OSS')
    parser.add_argument('--app-xctestrun', type=Path, help='prebuilt iOS App integration test manifest; requires resource-center')
    parser.add_argument('--app-simulator', help='explicit dedicated simulator UDID for App integration')
    parser.add_argument('--app-ui-simulator', help='explicit dedicated simulator for the real two-account photo UI closure')
    parser.add_argument('--app-ui-derived-data', type=Path, help='owned Xcode build directory for that UI closure')
    args = parser.parse_args()
    if not 1 <= args.author_client_processes <= min(32, args.author_capacity or 1):
        parser.error('--author-client-processes requires capacity mode and cannot exceed participants or 32')
    if not 1 <= args.author_gateway_processes <= min(4, args.author_client_processes) or (args.author_gateway_processes > 1 and not args.author_capacity):
        parser.error('--author-gateway-processes requires capacity mode and cannot exceed client processes or 4')
    if args.author_renewal_seconds != 0 and (not args.author_capacity or not 35 <= args.author_renewal_seconds <= 120):
        parser.error('--author-renewal-seconds requires capacity mode and 35..120 seconds')
    if args.author_avatar_replacement and not args.author_capacity:
        parser.error('--author-avatar-replacement requires capacity mode')
    if args.author_faults and (not args.author_capacity or args.author_capacity < args.author_client_processes * 2
                              or args.author_renewal_seconds):
        parser.error('--author-faults requires two participants per process and a separate run without renewal')
    if args.author_capacity is not None:
        if not 2 <= args.author_capacity <= 10000 or any((args.slow_resource, args.extended_acceptance,
                args.nickname_directory_only, args.resource_center, args.oss)):
            parser.error('--author-capacity requires 2..10000 participants and a separate local scenario')
        soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        desired = max(soft, 65536 if hard == resource.RLIM_INFINITY else min(65536, hard))
        resource.setrlimit(resource.RLIMIT_NOFILE, (desired, hard))
    if args.oss_test_parent != 'validation/' and not args.oss:
        parser.error('--oss-test-parent requires --oss')
    if bool(args.app_xctestrun) != bool(args.app_simulator) or (args.app_xctestrun and not args.resource_center):
        parser.error('App integration requires --resource-center, --app-xctestrun and --app-simulator together')
    if args.app_xctestrun:
        args.app_xctestrun = args.app_xctestrun.resolve(strict=True)
        if not re.fullmatch(r'[0-9A-Fa-f-]{36}', args.app_simulator):
            parser.error('invalid explicit simulator UDID')
    if bool(args.app_ui_simulator) != bool(args.app_ui_derived_data) or (args.app_ui_simulator and not args.resource_center):
        parser.error('App UI closure requires resource-center and both App UI options')
    if args.app_ui_simulator and not re.fullmatch(r'[0-9A-Fa-f-]{36}', args.app_ui_simulator):
        parser.error('invalid explicit App UI simulator UDID')
    if args.resource_center and (not args.oss or args.extended_acceptance or args.slow_resource or args.nickname_directory_only):
        parser.error('--resource-center requires --oss and cannot combine with other scenario selectors')
    if args.oss and (args.slow_resource or args.nickname_directory_only):
        parser.error('--oss requires the resource lifecycle scenario')
    if args.oss:
        for required in ('BUCKET', 'REGION', 'ACCESS_KEY_ID', 'ACCESS_KEY_SECRET'):
            if not os.environ.get('IM_V2_OSS_' + required):
                parser.error('missing OSS runtime configuration: ' + required)
    if args.nickname_directory_only and (args.slow_resource or args.extended_acceptance):
        parser.error('--nickname-directory-only cannot combine with other scenario modes')
    if sys.platform != 'darwin':
        raise RuntimeError('this native ClientKit acceptance requires macOS')
    if not ssl.HAS_TLSv1_3:
        raise RuntimeError('this Python runtime lacks TLS 1.3; use a Python linked to a current OpenSSL')
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    for tool in ('swift', 'initdb', 'pg_ctl', 'psql', 'createdb', 'openssl'):
        if not shutil.which(tool):
            raise RuntimeError('missing required tool: ' + tool)
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(('IMV2_', 'IM_V2_'))}
    with (output / 'build.log').open('w') as log:
        products = ['IMV2PlacementControlApp', 'IMV2AccountServerApp', 'IMV2ServerApp', 'IMV2ResourceImageWorker']
        if args.extended_acceptance:
            products.append('IMV2OperatorServerApp')
        for product in products:
            subprocess.run(['swift', 'build', '--configuration', args.configuration, '--disable-automatic-resolution', '--jobs', '4', '--product', product],
                           cwd=ROOT / 'IMV2Server', env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
    binary = Path(subprocess.check_output(['swift', 'build', '--configuration', args.configuration, '--show-bin-path'], cwd=ROOT / 'IMV2Server',
                                         env=environment, text=True).strip())
    print('Current native Account, Gateway and image worker built.', flush=True)
    processes, logs = [], []
    process_records = []
    counts = collections.Counter()
    counts_lock = threading.Lock()
    with tempfile.TemporaryDirectory(prefix='im-resource-live-') as directory:
        private = Path(directory)
        private.chmod(0o700)
        database_port, account_port, gateway_port, metrics_port = [free_port() for _ in range(4)]
        gateway_names = ['gateway'] + [f'gateway-{index}' for index in range(1, args.author_gateway_processes)]
        gateway_ports = [gateway_port] + [free_port() for _ in gateway_names[1:]]
        metrics_ports = [metrics_port] + [free_port() for _ in gateway_names[1:]]
        operator_port = free_port() if args.extended_acceptance else None
        database_args = ['-h', '127.0.0.1', '-p', str(database_port), '-U', 'postgres']
        started_postgres, proxy, proxy_thread = False, None, None
        ui_input = None
        ui_input_bytes = b'Resource center live document payload.\nSelected with the system file picker.\n'
        slow_gate = SlowUploadGate() if args.slow_resource else None
        with (output / 'setup.log').open('w') as setup:
            def run(command):
                subprocess.run(command, env=environment, stdout=setup, stderr=subprocess.STDOUT, check=True)

            def sql(statement, timeout=None):
                return subprocess.check_output(['psql', '-X', *database_args, '-d', 'im_live_resources',
                    '-v', 'ON_ERROR_STOP=1', '-tA', '-f', '-'], input=statement, env=environment, text=True, timeout=timeout).strip()

            def launch(name, config, executable=None):
                log = (output / (name + '.log')).open('w'); logs.append(log)
                process = subprocess.Popen([str(executable or binary / name)], env=dict(environment, **config),
                    stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                process._owned_process_group = process.pid
                processes.append(process)
                process_records.append(dict(name=name, pid=process.pid))
                (output / 'owned-processes.json').write_text(json.dumps(process_records, indent=2) + '\n')
                return process

            try:
                run(['initdb', '-D', str(private / 'pg'), '-U', 'postgres', '--auth=trust', '--no-locale'])
                run(['pg_ctl', '-D', str(private / 'pg'), '-l', str(output / 'postgres.log'),
                     '-o', f'-h 127.0.0.1 -p {database_port} -k {private} -c max_connections={160 + 64 * (len(gateway_names) - 1)}'
                     + (' -c shared_preload_libraries=pg_stat_statements -c pg_stat_statements.track=all' if args.author_capacity else ''), '-w', 'start'])
                started_postgres = True
                run(['createdb', *database_args, 'im_live_resources'])
                if args.author_capacity:
                    sql('CREATE EXTENSION pg_stat_statements;')
                run(['psql', '-X', *database_args, '-d', 'im_live_resources', '-v', 'ON_ERROR_STOP=1',
                     '-f', str(ROOT / 'IMV2/sql/schema.sql')])
                run(['psql', '-X', *database_args, '-d', 'im_live_resources', '-v', 'ON_ERROR_STOP=1',
                     '-f', str(ROOT / 'IMV2/sql/realtime-change-journal.sql')])
                run([sys.executable, str(ROOT / 'IMV2/scripts/prepare_v2_room_actor_configuration.py'),
                     '--output-dir', str(private / 'actors')]
                     + [argument for name in gateway_names for argument in ('--host', f'{name}=localhost:{free_port()}')]
                     + ['--caller', f'account=localhost:{free_port()}', '--shards', 'rooms-primary']
                     + (['--caller', f'operator=localhost:{free_port()}'] if args.extended_acceptance else [])
                     + voter_arguments([free_port() for _ in range(3)]))
                placement_processes = []
                start_controls(binary=binary / 'IMV2PlacementControlApp', actors=private / 'actors',
                    shards=['rooms-primary'], log_directory=output, owned=placement_processes,
                    spawn=lambda name, executable, config: launch(name, config, executable))
                certificate = private / 'actors/gateway/tls.pem'
                key = private / 'actors/gateway/tls.key'
                run(['openssl', 'x509', '-in', str(private / 'actors/gateway/ca.pem'),
                     '-outform', 'DER', '-out', str(private / 'ca.der')])
                secrets = {'IM_V2_' + key + '_BASE64': base64.b64encode(os.urandom(32)).decode() for key in
                    ('ACCESS_TOKEN_HMAC_KEY', 'CREDENTIAL_REPLAY_ENVELOPE_KEY', 'PUSH_ENDPOINT_ENVELOPE_KEY',
                     'ACCOUNT_EDGE_AUTHORIZATION_SECRET', 'ACCOUNT_CLIENT_RATE_LIMIT_HMAC_KEY',
                     'ACCOUNT_ASSERTION_HMAC_KEY', 'GROUP_INVITE_TOKEN_HMAC_KEY', 'LOCAL_MEDIA_SIGNING_KEY',
                     'OPERATOR_REPLAY_BEARER_TOKEN', 'OPERATOR_ACCOUNT_DISABLE_BEARER_TOKEN')}
                fixture_token = base64.b64encode(os.urandom(32)).decode()
                capacity = AuthorCapacityFixture(args.author_capacity, sql,
                    secrets['IM_V2_ACCESS_TOKEN_HMAC_KEY_BASE64'], counts, counts_lock,
                    args.author_client_processes, args.author_renewal_seconds, args.author_avatar_replacement,
                    args.author_faults) if args.author_capacity else None
                if args.extended_acceptance:
                    sql("INSERT INTO im_v2.shard_admission_pools (room_shard_id,capacity_profile_id,lease_id,generation,valid_until,command_window_limit) VALUES ('rooms-primary','standard',gen_random_uuid(),1,now()+interval '1 hour',1000) ON CONFLICT DO NOTHING")

                class Proxy(http.server.BaseHTTPRequestHandler):
                    protocol_version = 'HTTP/1.1'

                    def setup(self):
                        super().setup()
                        self.upstream = FixtureHTTPUpstream(account_port)

                    def finish(self):
                        try:
                            self.upstream.close()
                        finally:
                            super().finish()

                    def log_message(self, *_):
                        pass  # Signed object capabilities must not enter access logs.

                    def dispatch(self):
                        self._slow_claimed = False
                        self._slow_success = False
                        try:
                            self.dispatch_request()
                        except (TimeoutError, ValueError, OSError):
                            if not self._slow_claimed:
                                raise
                            self.close_connection = True
                            try: self.send_error(408)
                            except OSError: pass
                        finally:
                            if self._slow_claimed:
                                slow_gate.finish(self._slow_success)

                    def dispatch_request(self):
                        path = self.path.split('?', 1)[0]
                        if path.startswith('/__fixture__/slow-upload/'):
                            if slow_gate is None or self.headers.get('X-Resource-Fixture') != fixture_token:
                                self.send_error(403); return
                            if self.headers.get('Transfer-Encoding') or self.headers.get('Content-Length', '0') != '0':
                                self.send_error(400); self.close_connection = True; return
                            if path == '/__fixture__/slow-upload/state' and self.command == 'GET':
                                value = slow_gate.snapshot()
                            elif path == '/__fixture__/slow-upload/arm' and self.command == 'POST':
                                if not slow_gate.arm(): self.send_error(409); return
                                value = slow_gate.snapshot()
                            elif path == '/__fixture__/slow-upload/release' and self.command == 'POST':
                                slow_gate.release(); value = slow_gate.snapshot()
                            else:
                                self.send_error(404); return
                            payload = json.dumps(value).encode()
                            self.send_response(200); self.send_header('Content-Type', 'application/json')
                            self.send_header('Content-Length', str(len(payload))); self.end_headers()
                            self.wfile.write(payload); return
                        length = int(self.headers.get('Content-Length', '0'))
                        if not 0 <= length <= 2 * 1024 * 1024 or self.headers.get('Transfer-Encoding'):
                            self.send_error(413); return
                        if slow_gate is not None and self.command == 'PUT' and re.fullmatch(r'/v2/local-media/upload/[0-9a-fA-F-]{36}', path):
                            self._slow_claimed = slow_gate.claim(self.connection)
                        body = slow_gate.read(self, length) if self._slow_claimed else self.rfile.read(length)
                        if path.startswith('/__fixture__/author-capacity/'):
                            if capacity is None or self.headers.get('X-Resource-Fixture') != fixture_token:
                                self.send_error(403); return
                            if path.endswith('/seed') and self.command == 'POST':
                                value = capacity.seed(json.loads(body))
                            elif path.endswith('/assignment') and self.command == 'POST':
                                value = capacity.assignment(json.loads(body))
                            elif path.endswith('/barrier') and self.command == 'POST':
                                value = capacity.barrier(json.loads(body))
                            elif path.endswith('/message') and self.command in ('GET', 'POST'):
                                value = capacity.message(json.loads(body) if body else None)
                            elif path.endswith('/avatar') and self.command in ('GET', 'POST'):
                                value = capacity.avatar(json.loads(body) if body else None)
                            elif path.endswith('/fault') and self.command in ('GET', 'POST'):
                                value = capacity.fault(json.loads(body) if body else None)
                            elif path.endswith('/statistics') and self.command == 'GET':
                                value = capacity.statistics()
                            else:
                                self.send_error(404); return
                            payload = json.dumps(value).encode()
                            self.send_response(200); self.send_header('Content-Type', 'application/json')
                            self.send_header('Content-Length', str(len(payload))); self.end_headers()
                            self.wfile.write(payload); return
                        if self.path == '/__fixture__/disable-account' and self.command == 'POST':
                            if operator_port is None or self.headers.get('X-Resource-Fixture') != fixture_token:
                                self.send_error(403); return
                            command = json.loads(body)
                            if set(command) != {'operationID', 'userID', 'reason'} or command['reason'] != 'policy_enforcement':
                                self.send_error(400); return
                            command['operationID'] = str(uuid.UUID(command['operationID']))
                            command['userID'] = str(uuid.UUID(command['userID']))
                            operator = http.client.HTTPConnection('127.0.0.1', operator_port, timeout=20)
                            try:
                                operator.request('POST', '/internal/v2/accounts/disable', json.dumps(command),
                                    {'Content-Type': 'application/json', 'Authorization': 'Bearer ' + secrets['IM_V2_OPERATOR_ACCOUNT_DISABLE_BEARER_TOKEN_BASE64']})
                                result = operator.getresponse(); payload = result.read()
                                with counts_lock: counts[('POST', '/internal/v2/accounts/disable', result.status)] += 1
                                self.send_response(result.status); self.send_header('Content-Type', 'application/json')
                                self.send_header('Content-Length', str(len(payload))); self.end_headers(); self.wfile.write(payload)
                            finally:
                                operator.close()
                            return
                        if self.path == '/__fixture__/room' and self.command == 'POST':
                            if self.headers.get('X-Resource-Fixture') != fixture_token:
                                self.send_error(403); return
                            actors = json.loads(body)
                            viewer, author = str(uuid.UUID(actors['viewer'])), str(uuid.UUID(actors['author']))
                            room_id = str(uuid.uuid4())
                            directory_ids = []
                            if actors.get('directoryCount') is not None:
                                if not args.nickname_directory_only or actors['directoryCount'] != '257':
                                    self.send_error(400); return
                                directory_ids = [str(uuid.uuid4()) for _ in range(257)]
                            # Seed a large-class room; directory-only mode also
                            # seeds a bounded profile/nickname population. Reads,
                            # messages, authorization changes and revocation use
                            # real public routes.
                            sql(f"""BEGIN;
                              INSERT INTO im_v2.shard_admission_pools
                                (room_shard_id,capacity_profile_id,lease_id,generation,valid_until,command_window_limit)
                                VALUES('rooms-primary','standard',gen_random_uuid(),1,now()+interval '1 hour',1000) ON CONFLICT DO NOTHING;
                              INSERT INTO im_v2.rooms(room_id,room_shard_id,capacity_profile_id,capacity_class,membership_revision)
                                VALUES('{room_id}','rooms-primary','standard','large',1);
                              INSERT INTO im_v2.room_owner_routes(room_id,room_shard_id,route_epoch,created_at,updated_at)
                                VALUES('{room_id}','rooms-primary',0,now(),now());
                              INSERT INTO im_v2.group_rooms(room_id,owner_user_id,title,created_at)
                                VALUES('{room_id}','{author}','Resource acceptance',now());
                              INSERT INTO im_v2.room_memberships(room_id,user_id,joined_revision,role)
                                VALUES('{room_id}','{viewer}',1,'member'),('{room_id}','{author}',1,'owner');
                              INSERT INTO im_v2.room_admission(room_id,eligible_member_count,command_window_limit,shard_lease_id,shard_lease_generation)
                                SELECT '{room_id}',2,command_window_limit,lease_id,generation FROM im_v2.shard_admission_pools
                                WHERE room_shard_id='rooms-primary' AND capacity_profile_id='standard';
                              COMMIT;""")
                            if directory_ids:
                                rows = ','.join(f"('{identity}'::uuid,'directory{i}')" for i, identity in enumerate(directory_ids))
                                sql(f"""BEGIN;
                                  CREATE TEMP TABLE directory_seed(user_id uuid,nickname text) ON COMMIT DROP;
                                  INSERT INTO directory_seed VALUES {rows};
                                  INSERT INTO im_v2.public_user_profiles(user_id,public_handle,display_name,created_at,updated_at)
                                    SELECT user_id,replace(user_id::text,'-',''),nickname,now(),now() FROM directory_seed;
                                  INSERT INTO im_v2.room_memberships(room_id,user_id,joined_revision,role)
                                    SELECT '{room_id}',user_id,1,'member' FROM directory_seed;
                                  INSERT INTO im_v2.room_member_nicknames(room_id,user_id,nickname,revision,updated_at)
                                    SELECT '{room_id}',user_id,nickname,1,now() FROM directory_seed;
                                  UPDATE im_v2.room_admission SET eligible_member_count=259 WHERE room_id='{room_id}';
                                  COMMIT;""")
                            reply = {'roomID': room_id.upper()}
                            if directory_ids: reply['directoryIDs'] = directory_ids
                            payload = json.dumps(reply).encode()
                            self.send_response(200); self.send_header('Content-Type', 'application/json')
                            self.send_header('Content-Length', str(len(payload))); self.end_headers()
                            self.wfile.write(payload); return
                        excluded = {'host', 'connection', 'transfer-encoding', 'forwarded', 'x-forwarded-for',
                            'x-im-v2-account-edge-authorization', 'x-im-v2-account-client-address', 'x-resource-fixture'}
                        headers = {key: value for key, value in self.headers.items() if key.lower() not in excluded}
                        headers['X-IM-V2-Account-Edge-Authorization'] = secrets['IM_V2_ACCOUNT_EDGE_AUTHORIZATION_SECRET_BASE64']
                        headers['X-IM-V2-Account-Client-Address'] = '127.0.0.1'
                        byte_started = capacity.byte_request_started() if capacity and path.startswith('/v2/resource-bytes/') else None
                        try:
                            status, response_headers, payload = self.upstream.request(self.command, self.path, body,
                                headers, timeout=5 if self._slow_claimed else 20)
                            path = self.path.split('?')[0]
                            if path.startswith('/v2/resource-bytes/'): path = '/v2/resource-bytes/:placement'
                            if path.startswith('/v2/local-media/upload/'): path = '/v2/local-media/upload/:media'
                            if path.startswith('/v2/profile-presentations/groups/') and path.rsplit('/', 1)[-1] in ('nickname', 'nicknames'):
                                path = '/v2/profile-presentations/groups/:room/' + path.rsplit('/', 1)[-1]
                            with counts_lock: counts[(self.command, path, status)] += 1
                            self.send_response(status)
                            for key, value in response_headers:
                                if key.lower() not in {'transfer-encoding', 'connection', 'content-length'}:
                                    self.send_header(key, value)
                            self.send_header('Content-Length', str(len(payload))); self.end_headers()
                            self.wfile.write(payload)
                            self._slow_success = 200 <= status < 300
                        finally:
                            if byte_started is not None:
                                capacity.byte_request_finished(byte_started)

                    do_GET = do_POST = do_PUT = dispatch

                tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); tls.minimum_version = ssl.TLSVersion.TLSv1_3
                tls.load_cert_chain(str(certificate), str(key))
                class ConcurrentTLSFixtureServer(http.server.ThreadingHTTPServer):
                    # A wrapped listening socket performs each handshake inside
                    # accept(), serializing all clients before worker dispatch.
                    # Keep the listener raw and authenticate each accepted TLS
                    # socket in its request worker instead.
                    request_queue_size = 128

                    def process_request_thread(self, request, client_address):
                        try:
                            request.settimeout(10)
                            secured = tls.wrap_socket(request, server_side=True)
                            secured.settimeout(20)
                        except OSError:
                            request.close()
                            with counts_lock: counts[('TLS', '/__fixture__/handshake', 0)] += 1
                            return
                        super().process_request_thread(secured, client_address)

                proxy = ConcurrentTLSFixtureServer(('127.0.0.1', 0), Proxy)
                proxy.daemon_threads = True
                proxy_thread = threading.Thread(target=proxy.serve_forever, daemon=True)
                proxy_thread.start()
                base_url = f'https://localhost:{proxy.server_port}'
                db_url = f'postgres://postgres@127.0.0.1:{database_port}/im_live_resources'
                shared = dict(secrets, IM_V2_DATABASE_URL=db_url,
                    IM_V2_DIRECT_ROOM_SHARD_ID='rooms-primary', IM_V2_GROUP_ROOM_SHARD_ID='rooms-primary',
                    IM_V2_ROOM_SHARD_STORES_JSON=json.dumps([{'shard_id': 'rooms-primary', 'database_url': db_url, 'schema': 'im_v2'}]),
                    IM_V2_USER_SHARD_STORES_JSON=json.dumps([{'bucket': 'users-primary', 'database_url': db_url, 'schema': 'im_v2'}]),
                    IM_V2_LOCAL_MEDIA_MODE='filesystem', IM_V2_LOCAL_MEDIA_UNSAFE_TEST_ONLY='1',
                    IM_V2_LOCAL_MEDIA_ROOT_DIRECTORY=str(private / 'media'), IM_V2_LOCAL_MEDIA_PUBLIC_BASE_URL=base_url,
                    IMV2_RESOURCE_IMAGE_WORKER=str(binary / 'IMV2ResourceImageWorker'), IM_V2_LOG_LEVEL='warning')
                if args.oss:
                    bucket, region = os.environ['IM_V2_OSS_BUCKET'], os.environ['IM_V2_OSS_REGION']
                    prefix = args.oss_test_parent + 'native-' + uuid.uuid4().hex + '/'
                    for config_key in list(shared):
                        if config_key.startswith('IM_V2_LOCAL_MEDIA_'): shared.pop(config_key)
                    shared.update(IM_V2_RESOURCE_MODE='enabled',
                        IM_V2_RESOURCE_MAXIMUM_BYTES='268435456',
                        IM_V2_RESOURCE_WORK_DIRECTORY=str(private / 'resource-work'),
                        IM_V2_RESOURCE_PUBLIC_BASE_URL=base_url,
                        IM_V2_RESOURCE_SIGNING_KEY_BASE64=base64.b64encode(os.urandom(32)).decode(),
                        IM_V2_RESOURCE_DEFAULT_BINDING='oss-native', IM_V2_RESOURCE_DEFAULT_REVISION='1',
                        IM_V2_RESOURCE_STORAGE_BINDINGS_JSON=json.dumps([dict(id='oss-native', revision=1, kind='oss',
                            oss=dict(bucket=bucket, region=region,
                                endpoint=f'https://{bucket}.oss-{region}.aliyuncs.com', prefix=prefix))]))
                    for suffix in ('ACCESS_KEY_ID', 'ACCESS_KEY_SECRET', 'SECURITY_TOKEN', 'CREDENTIAL_EXPIRATION'):
                        config_key = 'IM_V2_OSS_' + suffix
                        if os.environ.get(config_key): shared[config_key] = os.environ[config_key]
                    (output / 'oss-fixture.json').write_text(json.dumps(dict(bucket=bucket, region=region, prefix=prefix)) + '\n')
                gateways = []
                for index, name in enumerate(gateway_names):
                    gateway = compose_defaults('gateway'); gateway.update(shared)
                    if args.oss:
                        for config_key in list(gateway):
                            if config_key.startswith('IM_V2_LOCAL_MEDIA_'): gateway.pop(config_key)
                    node = private / 'actors' / name
                    gateway.update(IMV2_ROOM_ACTOR_CONFIGURATION_FILE=str(node / 'configuration.json'),
                        IM_V2_AUTHOR_PRESENTATIONS_ENABLED='true', IM_V2_DATABASE_WORKLOAD_POOL_ISOLATION_ENABLED='true',
                        IM_V2_TLS_HOST='127.0.0.1', IM_V2_TLS_PORT=str(gateway_ports[index]),
                        IM_V2_TLS_CERTIFICATE_CHAIN_PATH=str(node / 'tls.pem'), IM_V2_TLS_PRIVATE_KEY_PATH=str(node / 'tls.key'),
                        IM_V2_METRICS_HOST='127.0.0.1', IM_V2_METRICS_PORT=str(metrics_ports[index]), IM_V2_GATEWAY_NODE_ID=name)
                    process_name = 'IMV2ServerApp' if index == 0 else 'IMV2ServerApp-' + str(index)
                    gateways.append(launch(process_name, gateway, binary / 'IMV2ServerApp'))
                # Launch every voter before waiting: a node may need its peers
                # to qualify before completing application startup.
                for process, port in zip(gateways, gateway_ports):
                    wait_listener(process, port)
                account = compose_defaults('account'); account.update(shared)
                if args.oss:
                    for config_key in list(account):
                        if config_key.startswith('IM_V2_LOCAL_MEDIA_'): account.pop(config_key)
                account.update(IMV2_ROOM_ACTOR_CONFIGURATION_FILE=str(private / 'actors/account/configuration.json'),
                               IM_V2_ACCOUNT_LISTEN_HOST='127.0.0.1', IM_V2_ACCOUNT_LISTEN_PORT=str(account_port))
                wait_listener(launch('IMV2AccountServerApp', account), account_port)
                if args.extended_acceptance:
                    operator = compose_defaults('operator'); operator.update(shared)
                    operator.update(IMV2_ROOM_ACTOR_CONFIGURATION_FILE=str(private / 'actors/operator/configuration.json'),
                        IM_V2_OPERATOR_REPLAY_LISTEN_HOST='127.0.0.1', IM_V2_OPERATOR_REPLAY_LISTEN_PORT=str(operator_port))
                    wait_listener(launch('IMV2OperatorServerApp', operator), operator_port)
                print('Owned PostgreSQL, separate Actor nodes, HTTPS resources and TLS Gateway ready.', flush=True)
                test_env = dict(environment, IMV2_LIVE_RESOURCE_GATEWAY_PORT=str(gateway_port),
                    IMV2_LIVE_RESOURCE_FIXTURE_TOKEN=fixture_token, IMV2_LIVE_ACCOUNT_HTTPS_URL=base_url,
                    IMV2_LIVE_ACCOUNT_CA_DER=str(private / 'ca.der'))
                if args.slow_resource:
                    test_env['IMV2_LIVE_RESOURCE_SLOW_UPLOAD'] = '1'
                if args.extended_acceptance:
                    test_env['IMV2_LIVE_EXTENDED_ACCEPTANCE'] = '1'
                if args.nickname_directory_only:
                    test_env['IMV2_LIVE_NICKNAME_DIRECTORY'] = '1'
                if args.author_capacity:
                    test_env['IMV2_LIVE_AUTHOR_CAPACITY'] = str(args.author_capacity)
                    test_env['IMV2_LIVE_AUTHOR_RENEWAL_SECONDS'] = str(args.author_renewal_seconds)
                    test_env['IMV2_LIVE_AUTHOR_AVATAR_REPLACEMENT'] = '1' if args.author_avatar_replacement else '0'
                    test_env['IMV2_LIVE_AUTHOR_FAULTS'] = '1' if args.author_faults else '0'
                if args.resource_center:
                    test_env['IMV2_LIVE_RESOURCE_CENTER'] = '1'
                test_filter = 'V2LiveResourceAuthorTests/slowResourceUploadKeepsControlAndCursorProgress' if args.slow_resource else 'V2LiveResourceAuthorTests'
                if args.nickname_directory_only:
                    test_filter = 'V2LiveResourceAuthorTests/largeNicknameDirectoryIndependentDeviceReads'
                if args.resource_center:
                    test_filter = 'V2LiveResourceAuthorTests/(resourceLifecycle|groupAvatarAcceptance)'
                if args.author_capacity:
                    test_filter = 'V2LiveAuthorCapacityTests'
                if capacity:
                    result = capacity.run_clients(ROOT, output, test_env, stop, metrics_ports, gateway_ports, args.configuration)
                else:
                    with (output / 'client.log').open('w') as log:
                        test = subprocess.Popen(['swift', 'test', '--configuration', args.configuration, '--disable-automatic-resolution', '--no-parallel',
                            '--jobs', '4', '--filter', test_filter], cwd=ROOT / 'IMV2ClientKit', env=test_env,
                            stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                        test._owned_process_group = test.pid
                        try:
                            result = test.wait(timeout=600 if args.extended_acceptance else 240)
                        finally:
                            stop(test)
                text = (output / 'client.log').read_text()
                if args.author_capacity:
                    passed = len(re.findall(r'Test .*realClientKitAuthorFanout.* passed', text)) == args.author_client_processes
                elif args.slow_resource:
                    passed = 'slowResourceUploadKeepsControlAndCursorProgress' in text and bool(re.search(r'Test .*slowResourceUploadKeepsControlAndCursorProgress.* passed', text))
                    state = slow_gate.snapshot()
                    passed = passed and state['hits'] == state['completed'] == 1 and state['expired'] == state['active'] == 0 and state['released'] and state['bodyBytesRead'] > 16384
                elif args.nickname_directory_only:
                    passed = bool(re.search(r'Test .*largeNicknameDirectoryIndependentDeviceReads.* passed', text))
                else:
                    passed = len(re.findall(r'Test "real resource upload, author delivery, byte access and block revocation" passed', text)) == 1
                group_avatar_passed = len(re.findall(r'Test "real group avatar upload, byte presentation, removal and original recovery" passed', text)) == 1
                if args.resource_center:
                    passed = passed and group_avatar_passed
                app_result, app_passed = None, None
                if args.app_xctestrun and result == 0 and passed:
                    # Keep __TESTROOT__ relative to the original built products.
                    # The one-run manifest contains only the owned fixture token
                    # and CA; OSS credentials are never handed to the simulator.
                    manifest = plistlib.loads(args.app_xctestrun.read_bytes())
                    app = manifest['IMAppTests']
                    manifest = {'IMAppTests': app, '__xctestrun_metadata__': manifest['__xctestrun_metadata__']}
                    app['EnvironmentVariables'].update({
                        'IMV2_LIVE_APP_RESOURCES': '1',
                        'IMV2_LIVE_ACCOUNT_HTTPS_URL': base_url,
                        'IMV2_LIVE_RESOURCE_GATEWAY_PORT': str(gateway_port),
                        'IMV2_LIVE_RESOURCE_FIXTURE_TOKEN': fixture_token,
                        'IMV2_LIVE_RESOURCE_CA_BASE64': base64.b64encode((private / 'ca.der').read_bytes()).decode('ascii'),
                    })
                    app['OnlyTestIdentifiers'] = ['V2LiveResourceAppSendTests']
                    app['CommandLineArguments'] = ['-v2-ui-testing-signed-out']
                    fd, manifest_name = tempfile.mkstemp(prefix='owned-resource-', suffix='.xctestrun', dir=args.app_xctestrun.parent)
                    try:
                        with os.fdopen(fd, 'wb') as target:
                            plistlib.dump(manifest, target)
                        with (output / 'app-client.log').open('w') as log:
                            test = subprocess.Popen(['xcodebuild', 'test-without-building', '-xctestrun', manifest_name,
                                '-destination', 'platform=iOS Simulator,id=' + args.app_simulator,
                                '-parallel-testing-enabled', 'NO', '-only-testing:IMAppTests/V2LiveResourceAppSendTests',
                                '-resultBundlePath', str(output / 'app.xcresult')],
                                cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                            test._owned_process_group = test.pid
                            try:
                                app_result = test.wait(timeout=360)
                            finally:
                                stop(test)
                                # Simulator test hosts are launched by launchd,
                                # outside xcodebuild's owned process group. Drain
                                # only this explicit test app on this simulator.
                                subprocess.run(['xcrun', 'simctl', 'terminate', args.app_simulator,
                                    app['TestHostBundleIdentifier']], env=environment,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
                    finally:
                        Path(manifest_name).unlink(missing_ok=True)
                    app_text = (output / 'app-client.log').read_text()
                    app_passed = app_result == 0 and 'Live iOS resource send: frozen image+file' in app_text and bool(re.search(r'Test .*appAccountRecoversFrozenImageAndFileAndRecipientReadsBoth.* passed', app_text))
                    passed = passed and app_passed
                app_ui_result, app_ui_passed = None, None
                if args.app_ui_simulator and result == 0 and passed:
                    # Trust is changed only in this explicitly selected test
                    # simulator, never the host or any real device. No cloud
                    # credentials enter the UI process or its launch arguments.
                    run(['xcrun', 'simctl', 'keychain', args.app_ui_simulator, 'add-root-cert', str(private / 'ca.der')])
                    def png_chunk(kind, data):
                        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
                    image = output / 'system-photo-fixture.png'
                    image.write_bytes(b'\x89PNG\r\n\x1a\n' +
                        png_chunk(b'IHDR', struct.pack('>IIBBBBB', 64, 64, 8, 2, 0, 0, 0)) +
                        png_chunk(b'IDAT', zlib.compress((b'\0' + bytes([32, 120, 230]) * 64) * 64)) + png_chunk(b'IEND', b''))
                    run(['xcrun', 'simctl', 'addmedia', args.app_ui_simulator, str(image)])
                    groups = subprocess.check_output(['xcrun', 'simctl', 'get_app_container', args.app_ui_simulator,
                        'com.apple.DocumentsApp', 'groups'], env=environment, text=True)
                    roots = [Path(line.split('\t', 1)[1]) for line in groups.splitlines()
                        if line.startswith('group.com.apple.FileProvider.LocalStorage\t')]
                    if len(roots) != 1 or roots[0].is_symlink():
                        raise RuntimeError('explicit simulator has no safe local file-provider root')
                    folder = roots[0] / 'File Provider Storage'
                    if folder.is_symlink():
                        raise RuntimeError('refusing a symbolic-link file-provider folder')
                    folder.mkdir(mode=0o700, exist_ok=True)
                    candidate = folder / 'IM Resource UI input.txt'
                    # Exclusive creation establishes ownership; never replace
                    # a document already present in the simulator's Files app.
                    with candidate.open('xb') as source:
                        source.write(ui_input_bytes)
                    ui_input = candidate
                    (output / 'system-file-fixture.json').write_text(json.dumps({
                        'fileName': candidate.name, 'byteCount': len(ui_input_bytes),
                        'sha256': hashlib.sha256(ui_input_bytes).hexdigest(), 'removedOwnedInput': False}, indent=2))
                    command = ['xcodebuild', '-project', str(ROOT / 'IMApp/IMApp.xcodeproj'),
                        '-scheme', 'IMAppLocalAccountE2E', '-configuration', 'Debug',
                        '-destination', 'platform=iOS Simulator,id=' + args.app_ui_simulator,
                        '-derivedDataPath', str(args.app_ui_derived_data),
                        '-parallel-testing-enabled', 'NO', '-collect-test-diagnostics', 'never',
                        'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-', 'IM_V2_ACCOUNT_BASE_URL=' + base_url,
                        'IM_V2_GATEWAY_HOST=localhost', 'IM_V2_GATEWAY_PORT=' + str(gateway_port),
                        '-only-testing:IMAppLocalAccountE2ETests/IMAppLiveResourceUITests/testSystemPhotoSendsToIndependentAccountAndSurvivesRelaunch',
                        '-only-testing:IMAppLocalAccountE2ETests/IMAppLiveResourceUITests/testSystemFileSendsToIndependentAccountAndPreviewsAfterRelaunch',
                        '-resultBundlePath', str(output / 'app-ui.xcresult'), 'test']
                    with (output / 'app-ui-client.log').open('w') as log:
                        test = subprocess.Popen(command, cwd=ROOT, env=environment, stdout=log,
                            stderr=subprocess.STDOUT, start_new_session=True)
                        test._owned_process_group = test.pid
                        try:
                            app_ui_result = test.wait(timeout=900)
                        finally:
                            stop(test)
                            for bundle in ['com.stskcxfz.imapp', 'com.codex.imappLocalAccountE2ETests.xctrunner']:
                                subprocess.run(['xcrun', 'simctl', 'terminate', args.app_ui_simulator, bundle],
                                    env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
                    ui_text = (output / 'app-ui-client.log').read_text()
                    photo_ui_passed = 'Live resource UI closure: system photo -> real author -> independent recipient -> relaunch' in ui_text and bool(re.search(
                        r'Test Case .*testSystemPhotoSendsToIndependentAccountAndSurvivesRelaunch.* passed \(', ui_text))
                    file_ui_passed = 'Live resource UI file closure: system file picker -> real author -> independent recipient preview -> relaunch' in ui_text and bool(re.search(
                        r'Test Case .*testSystemFileSendsToIndependentAccountAndPreviewsAfterRelaunch.* passed \(', ui_text))
                    app_ui_passed = app_ui_result == 0 and photo_ui_passed and file_ui_passed
                    passed = passed and app_ui_passed
                summary = {'clientExitCode': result, 'requiredTestPassed': passed,
                    'authorCapacityParticipants': args.author_capacity,
                    'authorCapacityClientProcesses': args.author_client_processes if capacity else None,
                    'authorCapacityGatewayProcesses': args.author_gateway_processes if capacity else None,
                    'authorCapacityRenewalSeconds': args.author_renewal_seconds if capacity else None,
                    'authorCapacityAvatarReplacement': args.author_avatar_replacement if capacity else None,
                    'swiftBuildConfiguration': args.configuration,
                    'authorCapacitySQL': capacity.statistics() if capacity else None,
                    'resourceCenterGate': args.resource_center, 'groupAvatarPassed': group_avatar_passed,
                    'appClientExitCode': app_result, 'appResourcePassed': app_passed,
                    'appUIClientExitCode': app_ui_result, 'appUIResourcePassed': app_ui_passed,
                    'httpResponses': [{'method': m, 'path': p, 'status': s, 'count': n} for (m, p, s), n in sorted(counts.items())],
                    'slowResourceGate': slow_gate.snapshot() if slow_gate else None,
                    'resourceFacts': json.loads(sql("""SELECT json_build_object(
                        'readyAvatars',(SELECT count(*) FROM im_v2.resource_catalog r JOIN im_v2.media_objects m USING(media_id) WHERE r.usage_kind='user_avatar' AND m.state='available'),
                        'variants',(SELECT count(*) FROM im_v2.resource_variants),
                        'blocks',(SELECT count(*) FROM im_v2.user_blocks));"""))}
                (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
                if result or not passed:
                    # Preserve bounded state facts before disposing this owned
                    # database. Never capture payloads, object handles or URLs.
                    try:
                        diagnostics = json.loads(sql("""SELECT json_build_object(
                            'mediaStates',(SELECT coalesce(json_agg(s),'[]') FROM (
                                SELECT c.usage_kind,m.state AS media_state,
                                    coalesce(o.state,'none') AS scan_state,count(*) AS count,
                                    max(o.retry_count) AS maximum_retry_count,
                                    max(extract(epoch FROM o.lease_expires_at-clock_timestamp())) AS maximum_lease_seconds
                                FROM im_v2.resource_catalog c JOIN im_v2.media_objects m USING(media_id)
                                LEFT JOIN im_v2.media_scan_outbox o USING(media_id)
                                GROUP BY c.usage_kind,m.state,o.state) s),
                            'uploadStates',(SELECT coalesce(json_agg(s),'[]') FROM (
                                SELECT state,count(*) AS count FROM im_v2.resource_upload_sessions GROUP BY state) s),
                            'variantStates',(SELECT coalesce(json_agg(s),'[]') FROM (
                                SELECT recipe,size,state,count(*) AS count FROM im_v2.resource_variants GROUP BY recipe,size,state) s),
                            'databaseWaits',(SELECT coalesce(json_agg(s),'[]') FROM (
                                SELECT state,wait_event_type,wait_event,count(*) AS count
                                FROM pg_stat_activity WHERE datname=current_database()
                                GROUP BY state,wait_event_type,wait_event) s));"""))
                        (output / 'resource-failure-diagnostics.json').write_text(json.dumps(diagnostics, indent=2) + '\n')
                    except Exception as error:
                        (output / 'resource-failure-diagnostics-error.json').write_text(json.dumps(dict(type=type(error).__name__)) + '\n')
                    if shutil.which('pg_dump'):
                        dump = output / 'failure-database.dump'
                        with dump.open('xb') as destination:
                            os.fchmod(destination.fileno(), 0o600)
                            subprocess.run(['pg_dump', *database_args, '-Fc', 'im_live_resources'],
                                env=environment, stdout=destination, stderr=setup, timeout=30, check=False)
                    raise RuntimeError('required live resource test failed; inspect client.log')
            finally:
                failures = []
                if ui_input is not None:
                    try:
                        if ui_input.is_symlink() or not ui_input.is_file() or ui_input.read_bytes() != ui_input_bytes:
                            raise RuntimeError('owned system-file input changed; refusing cleanup')
                        ui_input.unlink()
                        evidence = output / 'system-file-fixture.json'
                        value = json.loads(evidence.read_text()); value['removedOwnedInput'] = not ui_input.exists()
                        evidence.write_text(json.dumps(value, indent=2))
                    except Exception as error: failures.append(str(error))
                if slow_gate is not None:
                    try: slow_gate.close_and_drain()
                    except Exception as error: failures.append(str(error))
                    (output / 'slow-resource-gate.json').write_text(json.dumps(slow_gate.snapshot(), indent=2) + '\n')
                for process in reversed(processes):
                    try: stop(process)
                    except Exception as error: failures.append(f"owned PID {process.pid}: {error}")
                if proxy is not None:
                    try:
                        if proxy_thread is not None and proxy_thread.is_alive():
                            proxy.shutdown(); proxy_thread.join(timeout=5)
                        proxy.server_close()
                    except Exception as error: failures.append(str(error))
                for log in logs: log.close()
                if started_postgres:
                    run(['pg_ctl', '-D', str(private / 'pg'), '-m', 'fast', '-w', 'stop'])
                (output / 'owned-cleanup.json').write_text(json.dumps(dict(
                    processLeadersExited=all(process.poll() is not None for process in processes),
                    processGroupsDrained=not failures, postgresStopped=started_postgres,
                    failureCount=len(failures)), indent=2) + '\n')
                if failures: raise RuntimeError('; '.join(failures))
    print('Real resource acceptance and owned-service cleanup passed; evidence: ' + str(output), flush=True)


if __name__ == '__main__':
    main()
