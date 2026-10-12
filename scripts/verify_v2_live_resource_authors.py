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
import http.client
import http.server
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'IMV2/scripts'))
from v2_native_placement_processes import voter_arguments, start_controls


def free_port():
    with socket.socket() as connection:
        connection.bind(('127.0.0.1', 0))
        return connection.getsockname()[1]


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

    def drain(seconds):
        deadline = time.monotonic() + seconds
        while group_exists():
            if time.monotonic() >= deadline:
                return False
            time.sleep(.05)
        return True

    if group_exists():
        try: os.killpg(group, signal.SIGTERM)
        except ProcessLookupError: pass
        if not drain(90):
            try: os.killpg(group, signal.SIGKILL)
            except ProcessLookupError: pass
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
    parser.add_argument('--slow-resource', action='store_true', help='one opt-in slow signed-byte upload with concurrent typed control and TLS cursor progress')
    parser.add_argument('--extended-acceptance', action='store_true', help='also run typed message and group operation acceptance against the owned stack')
    parser.add_argument('--nickname-directory-only', action='store_true', help='real multi-page nickname reads with two independently issued devices')
    args = parser.parse_args()
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
            subprocess.run(['swift', 'build', '--disable-automatic-resolution', '--jobs', '4', '--product', product],
                           cwd=ROOT / 'IMV2Server', env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
    binary = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=ROOT / 'IMV2Server',
                                         env=environment, text=True).strip())
    print('Current native Account, Gateway and image worker built.', flush=True)
    processes, logs = [], []
    counts = collections.Counter()
    counts_lock = threading.Lock()
    with tempfile.TemporaryDirectory(prefix='im-resource-live-') as directory:
        private = Path(directory)
        private.chmod(0o700)
        database_port, account_port, gateway_port, metrics_port = [free_port() for _ in range(4)]
        operator_port = free_port() if args.extended_acceptance else None
        database_args = ['-h', '127.0.0.1', '-p', str(database_port), '-U', 'postgres']
        started_postgres, proxy, proxy_thread = False, None, None
        slow_gate = SlowUploadGate() if args.slow_resource else None
        with (output / 'setup.log').open('w') as setup:
            def run(command):
                subprocess.run(command, env=environment, stdout=setup, stderr=subprocess.STDOUT, check=True)

            def sql(statement):
                return subprocess.check_output(['psql', '-X', *database_args, '-d', 'im_live_resources',
                    '-v', 'ON_ERROR_STOP=1', '-tA', '-c', statement], env=environment, text=True).strip()

            def launch(name, config, executable=None):
                log = (output / (name + '.log')).open('w'); logs.append(log)
                process = subprocess.Popen([str(executable or binary / name)], env=dict(environment, **config),
                    stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                process._owned_process_group = process.pid
                processes.append(process)
                return process

            try:
                run(['initdb', '-D', str(private / 'pg'), '-U', 'postgres', '--auth=trust', '--no-locale'])
                run(['pg_ctl', '-D', str(private / 'pg'), '-l', str(output / 'postgres.log'),
                     '-o', f'-h 127.0.0.1 -p {database_port} -k {private} -c max_connections=160', '-w', 'start'])
                started_postgres = True
                run(['createdb', *database_args, 'im_live_resources'])
                run(['psql', '-X', *database_args, '-d', 'im_live_resources', '-v', 'ON_ERROR_STOP=1',
                     '-f', str(ROOT / 'IMV2/sql/schema.sql')])
                run(['psql', '-X', *database_args, '-d', 'im_live_resources', '-v', 'ON_ERROR_STOP=1',
                     '-f', str(ROOT / 'IMV2/sql/realtime-change-journal.sql')])
                run([sys.executable, str(ROOT / 'IMV2/scripts/prepare_v2_room_actor_configuration.py'),
                     '--output-dir', str(private / 'actors'), '--host', f'gateway=localhost:{free_port()}',
                     '--caller', f'account=localhost:{free_port()}', '--shards', 'rooms-primary']
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
                if args.extended_acceptance:
                    sql("INSERT INTO im_v2.shard_admission_pools (room_shard_id,capacity_profile_id,lease_id,generation,valid_until,command_window_limit) VALUES ('rooms-primary','standard',gen_random_uuid(),1,now()+interval '1 hour',1000) ON CONFLICT DO NOTHING")

                class Proxy(http.server.BaseHTTPRequestHandler):
                    protocol_version = 'HTTP/1.1'

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
                        upstream = http.client.HTTPConnection('127.0.0.1', account_port, timeout=5 if self._slow_claimed else 20)
                        try:
                            upstream.request(self.command, self.path, body, headers)
                            response = upstream.getresponse(); payload = response.read()
                            path = self.path.split('?')[0]
                            if path.startswith('/v2/resource-bytes/'): path = '/v2/resource-bytes/:placement'
                            if path.startswith('/v2/local-media/upload/'): path = '/v2/local-media/upload/:media'
                            if path.startswith('/v2/profile-presentations/groups/') and path.rsplit('/', 1)[-1] in ('nickname', 'nicknames'):
                                path = '/v2/profile-presentations/groups/:room/' + path.rsplit('/', 1)[-1]
                            with counts_lock: counts[(self.command, path, response.status)] += 1
                            self.send_response(response.status)
                            for key, value in response.getheaders():
                                if key.lower() not in {'transfer-encoding', 'connection', 'content-length'}:
                                    self.send_header(key, value)
                            self.send_header('Content-Length', str(len(payload))); self.end_headers()
                            self.wfile.write(payload)
                            self._slow_success = 200 <= response.status < 300
                        finally:
                            upstream.close()

                    do_GET = do_POST = do_PUT = dispatch

                tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); tls.minimum_version = ssl.TLSVersion.TLSv1_3
                tls.load_cert_chain(str(certificate), str(key))
                proxy = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Proxy)
                proxy.daemon_threads = True
                proxy.socket = tls.wrap_socket(proxy.socket, server_side=True)
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
                gateway = compose_defaults('gateway'); gateway.update(shared)
                gateway.update(IMV2_ROOM_ACTOR_CONFIGURATION_FILE=str(private / 'actors/gateway/configuration.json'),
                    IM_V2_AUTHOR_PRESENTATIONS_ENABLED='true', IM_V2_DATABASE_WORKLOAD_POOL_ISOLATION_ENABLED='true',
                    IM_V2_TLS_HOST='127.0.0.1', IM_V2_TLS_PORT=str(gateway_port),
                    IM_V2_TLS_CERTIFICATE_CHAIN_PATH=str(certificate), IM_V2_TLS_PRIVATE_KEY_PATH=str(key),
                    IM_V2_METRICS_HOST='127.0.0.1', IM_V2_METRICS_PORT=str(metrics_port), IM_V2_GATEWAY_NODE_ID='gateway')
                wait_listener(launch('IMV2ServerApp', gateway), gateway_port)
                account = compose_defaults('account'); account.update(shared)
                account.update(IMV2_ROOM_ACTOR_CONFIGURATION_FILE=str(private / 'actors/account/configuration.json'),
                               IM_V2_ACCOUNT_LISTEN_HOST='127.0.0.1', IM_V2_ACCOUNT_LISTEN_PORT=str(account_port))
                wait_listener(launch('IMV2AccountServerApp', account), account_port)
                if args.extended_acceptance:
                    operator = compose_defaults('operator'); operator.update(shared)
                    operator.pop('IMV2_ROOM_ACTOR_CONFIGURATION_FILE', None)
                    operator.update(IM_V2_OPERATOR_REPLAY_LISTEN_HOST='127.0.0.1', IM_V2_OPERATOR_REPLAY_LISTEN_PORT=str(operator_port))
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
                test_filter = 'V2LiveResourceAuthorTests/slowResourceUploadKeepsControlAndCursorProgress' if args.slow_resource else 'V2LiveResourceAuthorTests'
                if args.nickname_directory_only:
                    test_filter = 'V2LiveResourceAuthorTests/largeNicknameDirectoryIndependentDeviceReads'
                with (output / 'client.log').open('w') as log:
                    test = subprocess.Popen(['swift', 'test', '--disable-automatic-resolution', '--no-parallel',
                        '--jobs', '4', '--filter', test_filter], cwd=ROOT / 'IMV2ClientKit', env=test_env,
                        stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                    test._owned_process_group = test.pid
                    try:
                        result = test.wait(timeout=600 if args.extended_acceptance else 240)
                    finally:
                        stop(test)
                text = (output / 'client.log').read_text()
                if args.slow_resource:
                    passed = 'slowResourceUploadKeepsControlAndCursorProgress' in text and bool(re.search(r'Test .*slowResourceUploadKeepsControlAndCursorProgress.* passed', text))
                    state = slow_gate.snapshot()
                    passed = passed and state['hits'] == state['completed'] == 1 and state['expired'] == state['active'] == 0 and state['released'] and state['bodyBytesRead'] > 16384
                elif args.nickname_directory_only:
                    passed = bool(re.search(r'Test .*largeNicknameDirectoryIndependentDeviceReads.* passed', text))
                else:
                    passed = len(re.findall(r'Test "real resource upload, author delivery, byte access and block revocation" passed', text)) == 1
                summary = {'clientExitCode': result, 'requiredTestPassed': passed,
                    'httpResponses': [{'method': m, 'path': p, 'status': s, 'count': n} for (m, p, s), n in sorted(counts.items())],
                    'slowResourceGate': slow_gate.snapshot() if slow_gate else None,
                    'resourceFacts': json.loads(sql("""SELECT json_build_object(
                        'readyAvatars',(SELECT count(*) FROM im_v2.resource_catalog r JOIN im_v2.media_objects m USING(media_id) WHERE r.usage_kind='user_avatar' AND m.state='available'),
                        'variants',(SELECT count(*) FROM im_v2.resource_variants),
                        'blocks',(SELECT count(*) FROM im_v2.user_blocks));"""))}
                (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
                if result or not passed:
                    raise RuntimeError('required live resource test failed; inspect client.log')
            finally:
                failures = []
                if slow_gate is not None:
                    try: slow_gate.close_and_drain()
                    except Exception as error: failures.append(str(error))
                    (output / 'slow-resource-gate.json').write_text(json.dumps(slow_gate.snapshot(), indent=2) + '\n')
                for process in reversed(processes):
                    try: stop(process)
                    except Exception as error: failures.append(str(error))
                if proxy is not None:
                    try:
                        if proxy_thread is not None and proxy_thread.is_alive():
                            proxy.shutdown(); proxy_thread.join(timeout=5)
                        proxy.server_close()
                    except Exception as error: failures.append(str(error))
                for log in logs: log.close()
                if started_postgres:
                    run(['pg_ctl', '-D', str(private / 'pg'), '-m', 'fast', '-w', 'stop'])
                if failures: raise RuntimeError('; '.join(failures))
    print('Real resource acceptance and owned-service cleanup passed; evidence: ' + str(output), flush=True)


if __name__ == '__main__':
    main()
