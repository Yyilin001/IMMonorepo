#!/usr/bin/env python3
"""Disposable native account + PostgreSQL + verified HTTPS acceptance.

Only loopback sockets are opened. All keys, database files and TLS certificates
are newly generated beneath a private temporary directory and removed at exit.
No Docker, existing database or production secret is used. Optional App UI tests
trust the temporary CA only in a newly created simulator that is deleted at exit.
The HTTPS proxy supplies the same trusted edge headers as the local Caddy edge;
all registration, credential, device and rate-limit behavior is the real server.
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
import tempfile
import threading
import time
import uuid
from imv2_tls_backpressure_proxy import TLSBackpressureProxy

ROOT = Path(__file__).resolve().parents[1]


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True,
                        help='new evidence directory; existing directories are rejected')
    parser.add_argument('--app-ui', action='store_true', help='also run the real App revocation UI test in a newly created, disposable iPhone 17 simulator; reserves localhost:8443')
    parser.add_argument('--simulator-runtime', default='com.apple.CoreSimulator.SimRuntime.iOS-26-2',
                        help='installed simulator runtime identifier for --app-ui (default: iOS 26.2)')
    parser.add_argument('--gateway', action='store_true', help='with --app-ui, also start the real TLS Gateway on loopback:7443 and verify connected-session revocation')
    parser.add_argument('--private-hint', action='store_true', help='with --app-ui --gateway, verify sender-only restriction hints through two real TLS clients, SQLite reopen and reconnect')
    parser.add_argument('--room-recovery-scale', type=int, choices=[0, 50, 129, 1000, 10000], help='with --app-ui --gateway, seed nonempty rooms and verify production TLS recovery and reconnect')
    parser.add_argument('--room-recovery-broker-outage', action='store_true', help='with nonempty scale and multi-gateway NATS, stop the owned broker after coverage and verify explicit invalidation and recovery')
    parser.add_argument('--room-recovery-drop-tail', action='store_true', help='with nonempty scale, discard the last real TLS wake at the test consumer and verify periodic reconciliation')
    parser.add_argument('--room-recovery-scan-race', choices=['before-listener', 'directory', 'state'], help='commit through another Gateway at a selected recovery boundary')
    parser.add_argument('--headless-app', action='store_true', help='with --app-ui --gateway, also run real credential Push entry in an App host without constructing its root view')
    parser.add_argument('--current-logout', action='store_true', help='also verify current-device logout through real HTTPS and PostgreSQL')
    parser.add_argument('--interrupted-issuance', action='store_true', help='with --app-ui --current-logout, terminate the owned App after issuance and cancellation commit but before either response is forwarded')
    parser.add_argument('--load-credentials', action='store_true', help='exercise the actual load credential preparation script and cancel its issued session through the saved proof')
    parser.add_argument('--legacy-registration', action='store_true', help='after baseline checks, verify legacy cancellation with real password factors, HTTPS and PostgreSQL rollback')
    parser.add_argument('--legacy-client', action='store_true', help='with --current-logout, run ClientKit legacy archive recovery and lost acknowledgement replay against HTTPS')
    parser.add_argument('--legacy-app', action='store_true', help='with --app-ui --current-logout, terminate App after legacy cleanup commit and verify real Keychain replay')
    parser.add_argument('--multi-gateway-nats-binary', type=Path, help='with --private-hint or nonempty --room-recovery-scale, start owned NATS and a second TLS Gateway for cross-gateway recovery')
    parser.add_argument('--room-recovery-slow-tls', action='store_true', help='pause the owned opaque TLS relay and require real App backpressure closure and recovery')
    parser.add_argument('--room-recovery-membership-race', action='store_true', help='remove and rejoin a member while a real old room state response is delayed')
    parser.add_argument('--room-recovery-app-reconnect', action='store_true', help='verify foreground App reconnect after three owned relay disconnects')
    args = parser.parse_args()
    if args.room_recovery_membership_race and (not args.room_recovery_scale or not args.multi_gateway_nats_binary):
        parser.error('--room-recovery-membership-race requires nonempty scale and multi-gateway NATS')
    if sum(bool(flag) for flag in (args.room_recovery_membership_race, args.room_recovery_slow_tls, args.room_recovery_app_reconnect,
                                  args.room_recovery_scan_race, args.room_recovery_drop_tail,
                                  args.room_recovery_broker_outage)) > 1:
        parser.error('select exactly one room recovery fault scenario per run')
    if args.room_recovery_app_reconnect and (not args.room_recovery_scale or not args.multi_gateway_nats_binary):
        parser.error('--room-recovery-app-reconnect requires nonempty scale and multi-gateway NATS')
    if args.room_recovery_slow_tls and (not args.room_recovery_scale or not args.multi_gateway_nats_binary
                                      or args.room_recovery_scan_race or args.room_recovery_drop_tail
                                      or args.room_recovery_broker_outage):
        parser.error('--room-recovery-slow-tls requires nonempty scale, multi-gateway NATS and no other fault flag')
    if args.room_recovery_scan_race and (not args.room_recovery_scale or not args.multi_gateway_nats_binary
                                       or args.room_recovery_drop_tail or args.room_recovery_broker_outage):
        parser.error('--room-recovery-scan-race requires nonempty scale, multi-gateway NATS and no other fault flag')
    if args.room_recovery_drop_tail and (not args.room_recovery_scale or args.room_recovery_broker_outage):
        parser.error('--room-recovery-drop-tail requires nonempty scale and cannot be combined with broker outage')
    if args.room_recovery_broker_outage and not (args.room_recovery_scale and args.multi_gateway_nats_binary):
        parser.error('--room-recovery-broker-outage requires nonempty scale and --multi-gateway-nats-binary')
    if args.multi_gateway_nats_binary and not (args.private_hint or args.room_recovery_scale):
        parser.error('--multi-gateway-nats-binary requires --private-hint or a nonempty --room-recovery-scale')
    if args.gateway and not args.app_ui:
        parser.error('--gateway requires --app-ui')
    if args.private_hint and not (args.app_ui and args.gateway):
        parser.error('--private-hint requires --app-ui --gateway')
    if args.room_recovery_scale is not None and not (args.app_ui and args.gateway):
        parser.error('--room-recovery-scale requires --app-ui --gateway')
    if args.headless_app and not (args.app_ui and args.gateway):
        parser.error('--headless-app requires --app-ui --gateway')
    if args.interrupted_issuance and not (args.app_ui and args.current_logout):
        parser.error('--interrupted-issuance requires --app-ui --current-logout')
    if args.legacy_client and not args.current_logout:
        parser.error('--legacy-client requires --current-logout')
    if args.legacy_app and not (args.app_ui and args.current_logout):
        parser.error('--legacy-app requires --app-ui --current-logout')
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    for tool in ['swift', 'initdb', 'pg_ctl', 'psql', 'createdb', 'openssl']:
        if not shutil.which(tool):
            raise RuntimeError('missing required tool: ' + tool)
    if args.app_ui:
        for tool in ['xcrun', 'xcodebuild']:
            if not shutil.which(tool):
                raise RuntimeError('missing required tool: ' + tool)
        runtimes = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'runtimes', '--json'], text=True))
        if not any(runtime['identifier'] == args.simulator_runtime and runtime.get('isAvailable', False)
                   for runtime in runtimes['runtimes']):
            raise RuntimeError('requested simulator runtime is not installed or available: ' + args.simulator_runtime)
        (output / 'simulator-runtime.txt').write_text(args.simulator_runtime + '\n')
    # Refuse inherited application configuration; never borrow local .env keys.
    environment = {k: v for k, v in os.environ.items()
                   if not k.startswith(('IM_V2_', 'IMV2_LIVE_ACCOUNT_'))}
    with (output / 'build.log').open('w') as log:
        subprocess.run(['swift', 'build', '--disable-automatic-resolution', '--jobs', '4',
                        '--product', 'IMV2AccountServerApp'], cwd=ROOT / 'IMV2Server',
                       env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
        if args.gateway:
            subprocess.run(['swift', 'build', '--disable-automatic-resolution', '--jobs', '4',
                            '--product', 'IMV2ServerApp'], cwd=ROOT / 'IMV2Server', env=environment,
                           stdout=log, stderr=subprocess.STDOUT, check=True)
    print('Native account executable built from current sources.', flush=True)
    with tempfile.TemporaryDirectory(prefix='im-v2-live-account-') as temporary:
        private = Path(temporary)
        data = private / 'postgres'
        db_port, account_port = free_port(), free_port()
        # PostgreSQL itself is a separate owned cluster, not a borrowed database.
        database_arguments = ['-h', '127.0.0.1', '-p', str(db_port), '-U', 'postgres']
        postgres_started = False
        account = None
        gateway = None
        gateway_log = None
        tls_relay = None
        tls_relay_events = []
        additional_processes = []
        recovery_broker = []
        recovery_broker_events = []
        additional_logs = []
        gateway_samples = []
        scale_seeded = threading.Event()
        scale_resource_samples = []
        scale_auth = {'user': None, 'successfulRefreshes': 0}
        proxy = None
        proxy_thread = None
        simulator = None
        counts = collections.Counter()
        count_lock = threading.Lock()
        interruption_ready = {phase: threading.Event() for phase in ['issue', 'cancel', 'legacy']}
        interruption = dict(device=None, proof=None, issueTerminations=0, cancelTerminations=0, cancelReplays=0, proofMatched=True, failure=None)
        interruption.update(legacyDevice=None, legacyOperation=None, legacyAssertionDevice=None, legacyTerminations=0, legacyReplays=0, legacyMatched=True)
        result = None
        app_result = None
        with (output / 'setup.log').open('w') as setup, (output / 'account.log').open('w') as account_log:
            try:
                def run(command, **kwargs):
                    return subprocess.run(command, stdout=setup, stderr=subprocess.STDOUT,
                                          env=environment, check=True, **kwargs)
                run(['initdb', '-D', str(data), '-U', 'postgres', '--auth=trust', '--no-locale', '--encoding=UTF8'])
                run(['pg_ctl', '-D', str(data), '-l', str(private / 'postgres.log'), '-o',
                     '-p {} -h 127.0.0.1 -k {}'.format(db_port, private), 'start', '-w'])
                postgres_started = True
                run(['createdb', *database_arguments, 'im_live_account'])
                run(['psql', '-X', *database_arguments, '-d', 'im_live_account', '-v', 'ON_ERROR_STOP=1',
                     '-f', str(ROOT / 'IMV2/sql/schema.sql')])

                if args.private_hint or args.room_recovery_scale is not None:
                    # The auth-only harness does not run the admission operator.
                    # Reserve a bounded lease solely in this disposable cluster
                    # so real room creation and sending exercise normal admission.
                    command_budget = 10000 if args.room_recovery_slow_tls else 1000
                    lease_sql = f"""INSERT INTO im_v2.shard_admission_pools
                        (room_shard_id, capacity_profile_id, lease_id, generation, valid_until, command_window_limit)
                        VALUES ('rooms-primary', 'standard', gen_random_uuid(), 1,
                                CURRENT_TIMESTAMP + interval '1 hour', {command_budget})"""
                    run(['psql', '-X', *database_arguments, '-d', 'im_live_account', '-v', 'ON_ERROR_STOP=1', '-c', lease_sql])

                if args.current_logout:
                    # Fault only a single fixture operation, after its journal
                    # insert. The endpoint's whole transaction must roll back.
                    fault_sql = """CREATE FUNCTION im_v2.test_fail_logout_journal() RETURNS trigger LANGUAGE plpgsql AS $$
                    BEGIN
                      IF NEW.operation_id = '00000000-0000-4000-8000-00000000b008'::uuid THEN
                        RAISE EXCEPTION 'injected logout journal failure';
                      END IF;
                      RETURN NEW;
                    END; $$;
                    CREATE TRIGGER test_fail_logout_journal AFTER INSERT ON im_v2.device_session_operations
                    FOR EACH ROW EXECUTE FUNCTION im_v2.test_fail_logout_journal();"""
                    run(['psql', '-X', *database_arguments, '-d', 'im_live_account', '-v', 'ON_ERROR_STOP=1', '-c', fault_sql])
                # Fresh CA and leaf, hostname verification remains enabled.
                run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                     '-subj', '/CN=IM V2 disposable test CA', '-keyout', str(private / 'ca.key'),
                     '-out', str(private / 'ca.pem'), '-addext', 'basicConstraints=critical,CA:TRUE'])
                run(['openssl', 'req', '-new', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=localhost',
                     '-keyout', str(private / 'leaf.key'), '-out', str(private / 'leaf.csr')])
                (private / 'leaf.ext').write_text('subjectAltName=DNS:localhost\nbasicConstraints=critical,CA:FALSE\n'
                                                'keyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n')
                run(['openssl', 'x509', '-req', '-in', str(private / 'leaf.csr'), '-CA', str(private / 'ca.pem'),
                     '-CAkey', str(private / 'ca.key'), '-CAcreateserial', '-days', '1',
                     '-extfile', str(private / 'leaf.ext'), '-out', str(private / 'leaf.pem')])
                run(['openssl', 'x509', '-in', str(private / 'ca.pem'), '-outform', 'DER', '-out', str(private / 'ca.der')])
                # Reuse the checked-in local deployment's non-secret account
                # policy values; override listener/database and omit media.
                compose = (ROOT / 'IMV2/docker-compose.local-account.yml').read_text()
                block = compose.split('\n  account:\n', 1)[1].split('\n  gateway:\n', 1)[0]
                config = {}
                for key, raw in re.findall(r'^      (IM_V2_[A-Z0-9_]+): (.+)$', block, re.M):
                    if not any(x in key for x in ['LOCAL_MEDIA', 'DATABASE_URL', 'SHARD_STORES_JSON']):
                        config[key] = raw.strip('"\'')
                config.update(IM_V2_DATABASE_URL='postgres://postgres@127.0.0.1:{}/im_live_account'.format(db_port),
                              IM_V2_ACCOUNT_LISTEN_HOST='127.0.0.1', IM_V2_ACCOUNT_LISTEN_PORT=str(account_port))
                if args.room_recovery_slow_tls:
                    config['IM_V2_MAX_COMMANDS_PER_WINDOW'] = str(command_budget)
                config['IM_V2_ROOM_SHARD_STORES_JSON'] = json.dumps([{
                    'shard_id': 'rooms-primary', 'database_url': config['IM_V2_DATABASE_URL'], 'schema': 'im_v2'}])
                config['IM_V2_USER_SHARD_STORES_JSON'] = json.dumps([{
                    'bucket': 'users-primary', 'database_url': config['IM_V2_DATABASE_URL'], 'schema': 'im_v2'}])
                for key in ['ACCESS_TOKEN_HMAC_KEY', 'CREDENTIAL_REPLAY_ENVELOPE_KEY', 'PUSH_ENDPOINT_ENVELOPE_KEY',
                            'ACCOUNT_EDGE_AUTHORIZATION_SECRET', 'ACCOUNT_CLIENT_RATE_LIMIT_HMAC_KEY',
                            'ACCOUNT_ASSERTION_HMAC_KEY', 'GROUP_INVITE_TOKEN_HMAC_KEY']:
                    config['IM_V2_' + key + '_BASE64'] = base64.b64encode(os.urandom(32)).decode('ascii')
                account = subprocess.Popen([str(ROOT / 'IMV2Server/.build/debug/IMV2AccountServerApp')],
                                           env=dict(environment, **config), stdout=account_log, stderr=subprocess.STDOUT)
                deadline = time.monotonic() + 30
                while True:
                    if account.poll() is not None:
                        raise RuntimeError('account process exited during startup; inspect account.log')
                    try:
                        with socket.create_connection(('127.0.0.1', account_port), timeout=.2):
                            break
                    except OSError:
                        if time.monotonic() >= deadline:
                            raise RuntimeError('account listener startup deadline exceeded')
                        time.sleep(.05)

                metrics_port = free_port()
                def gateway_connections():
                    connection = http.client.HTTPConnection('127.0.0.1', metrics_port, timeout=8)
                    try:
                        connection.request('GET', '/metrics')
                        response = connection.getresponse()
                        body = response.read().decode()
                        if response.status != 200:
                            raise RuntimeError('gateway metrics unavailable')
                        match = re.search(r'^im_v2_gateway_active_connections (\d+)$', body, re.M)
                        if not match:
                            raise RuntimeError('authenticated connection gauge missing')
                        return int(match.group(1))
                    finally:
                        connection.close()

                if args.gateway:
                    gateway_config = dict(config)
                    block = compose.split('\n  gateway:\n', 1)[1].split('\n  operator:\n', 1)[0]
                    for key, raw in re.findall(r'^      (IM_V2_[A-Z0-9_]+): (.+)$', block, re.M):
                        if not any(x in key for x in ['LOCAL_MEDIA', 'DATABASE_URL', 'SHARD_STORES_JSON']):
                            gateway_config[key] = raw.strip('"\'')
                    primary_tls_port = free_port() if (args.room_recovery_slow_tls or args.room_recovery_app_reconnect) else 7443
                    if args.room_recovery_slow_tls:
                        gateway_config['IM_V2_MAX_COMMANDS_PER_WINDOW'] = str(command_budget)
                        # The paused peer cannot complete heartbeat requests.
                        # Isolate notification write backpressure from idle expiry
                        # within the bounded 600-second pressure phase.
                        gateway_config['IM_V2_IDLE_TIMEOUT_MS'] = '700000'
                    gateway_config.update(IM_V2_TLS_HOST='127.0.0.1', IM_V2_TLS_PORT=str(primary_tls_port),
                        IM_V2_TLS_CERTIFICATE_CHAIN_PATH=str(private / 'leaf.pem'),
                        IM_V2_TLS_PRIVATE_KEY_PATH=str(private / 'leaf.key'),
                        IM_V2_METRICS_HOST='127.0.0.1', IM_V2_METRICS_PORT=str(metrics_port),
                        IM_V2_METRICS_MINIMUM_REFRESH_INTERVAL_MS='4000')
                    if args.multi_gateway_nats_binary:
                        nats_port = free_port()
                        nats_log = (output / 'nats.log').open('w')
                        additional_logs.append(nats_log)
                        nats = subprocess.Popen([str(args.multi_gateway_nats_binary.resolve()), '-a', '127.0.0.1', '-p', str(nats_port)],
                            stdout=nats_log, stderr=subprocess.STDOUT)
                        additional_processes.append(nats)
                        recovery_broker.append(nats)
                        deadline = time.monotonic() + 10
                        while True:
                            if nats.poll() is not None:
                                raise RuntimeError('owned NATS failed to start')
                            try:
                                with socket.create_connection(('127.0.0.1', nats_port), timeout=.2):
                                    break
                            except OSError:
                                if time.monotonic() >= deadline:
                                    raise RuntimeError('owned NATS startup deadline exceeded')
                                time.sleep(.05)
                        gateway_config.update(IM_V2_GATEWAY_REPLICA_COUNT='2',
                            IM_V2_GROUP_WAKE_NATS_URL='nats://127.0.0.1:{}'.format(nats_port),
                            IM_V2_GROUP_WAKE_NATS_SUBJECT_PREFIX='imv2.recovery.acceptance',
                            IM_V2_GROUP_WAKE_ROUTING_KEY_BASE64=base64.b64encode(os.urandom(32)).decode())
                    gateway_log = (output / 'gateway.log').open('w')
                    gateway = subprocess.Popen([str(ROOT / 'IMV2Server/.build/debug/IMV2ServerApp')],
                        env=dict(environment, **gateway_config), stdout=gateway_log, stderr=subprocess.STDOUT)
                    deadline = time.monotonic() + 40
                    while True:
                        if gateway.poll() is not None:
                            raise RuntimeError('gateway startup failed; inspect gateway.log')
                        try:
                            with socket.create_connection(('127.0.0.1', primary_tls_port), timeout=.2):
                                gateway_connections()
                                break
                        except OSError:
                            if time.monotonic() >= deadline:
                                raise RuntimeError('gateway startup deadline exceeded')
                            time.sleep(.05)
                    if args.room_recovery_slow_tls or args.room_recovery_app_reconnect:
                        tls_relay = TLSBackpressureProxy(primary_tls_port)
                    print('Native TLS Gateway and authenticated-connection metrics ready.', flush=True)
                    if args.multi_gateway_nats_binary:
                        secondary_port = free_port()
                        secondary_log = (output / 'gateway-secondary.log').open('w')
                        additional_logs.append(secondary_log)
                        secondary_config = dict(gateway_config, IM_V2_GATEWAY_NODE_ID='recovery-gateway-secondary',
                            IM_V2_TLS_PORT=str(secondary_port), IM_V2_METRICS_PORT=str(free_port()))
                        secondary = subprocess.Popen([str(ROOT / 'IMV2Server/.build/debug/IMV2ServerApp')],
                            env=dict(environment, **secondary_config), stdout=secondary_log, stderr=subprocess.STDOUT)
                        additional_processes.append(secondary)
                        deadline = time.monotonic() + 40
                        while True:
                            if secondary.poll() is not None:
                                raise RuntimeError('secondary Gateway startup failed')
                            try:
                                with socket.create_connection(('127.0.0.1', secondary_port), timeout=.2):
                                    break
                            except OSError:
                                if time.monotonic() >= deadline:
                                    raise RuntimeError('secondary Gateway startup deadline exceeded')
                                time.sleep(.05)
                        environment['SIMCTL_CHILD_IMV2_ROOM_RECOVERY_SECONDARY_PORT'] = str(secondary_port)
                        if args.room_recovery_broker_outage:
                            environment['SIMCTL_CHILD_IMV2_ROOM_RECOVERY_BROKER_OUTAGE'] = '1'
                        print('Second TLS Gateway and real NATS ready.', flush=True)


                def seed_recovery_rooms(handle):
                    if not re.fullmatch(r'dual_[a-f0-9]{20}', handle):
                        raise RuntimeError('unexpected scale fixture account handle')
                    user = subprocess.check_output(['psql', '-X', '-A', '-t', *database_arguments,
                        '-d', 'im_live_account', '-v', 'ON_ERROR_STOP=1', '-c',
                        "SELECT user_id FROM im_v2.account_password_credentials WHERE account_handle = '" + handle + "'"],
                        env=environment, text=True).strip()
                    user = str(uuid.UUID(user))
                    scale_auth['user'] = user
                    # The scale fixture normally covers only directory/body recovery.
                    # A real App also needs the personal room discovery record that
                    # production group creation writes in the source transaction.
                    room_discovery_sql = f"""
                        INSERT INTO im_v2.user_state_event_outbox
                            (source_event_id,user_id,projection_kind,payload,created_at,next_attempt_at)
                        SELECT gen_random_uuid(),'{user}'::uuid,'room',
                            jsonb_build_object('event_type','room.created','room_id',upper(room_id::text),
                                'owner_user_id',upper('{user}'),'title','Recovery scale',
                                'capacity_class','standard','membership_revision',1,
                                'created_at_ms',1750000000000),to_timestamp(1750000000),now()
                        FROM recovery_seed;
                    """ if args.room_recovery_app_reconnect else ''
                    seed_sql = f"""BEGIN;
                        CREATE TEMP TABLE recovery_seed ON COMMIT DROP AS
                        SELECT md5('{user}:' || n::text)::uuid AS room_id
                        FROM generate_series(1,{args.room_recovery_scale}) AS n;
                        INSERT INTO im_v2.rooms(room_id,room_shard_id,capacity_profile_id,membership_revision,room_sequence,timeline_sequence)
                        SELECT room_id,'rooms-primary','standard',1,1,1 FROM recovery_seed;
                        INSERT INTO im_v2.group_rooms(room_id,owner_user_id,title,created_at)
                        SELECT room_id,'{user}'::uuid,'Recovery scale',now() FROM recovery_seed;
                        INSERT INTO im_v2.room_admission
                            (room_id,eligible_member_count,command_window_limit,shard_lease_id,shard_lease_generation)
                        SELECT seed.room_id,1,pool.command_window_limit,pool.lease_id,pool.generation
                        FROM recovery_seed AS seed CROSS JOIN im_v2.shard_admission_pools AS pool
                        WHERE pool.room_shard_id='rooms-primary' AND pool.capacity_profile_id='standard';
                        INSERT INTO im_v2.room_memberships(room_id,user_id,joined_revision,role)
                        SELECT room_id,'{user}'::uuid,1,'owner' FROM recovery_seed;
                        INSERT INTO im_v2.room_events(event_id,room_id,room_sequence,event_type,actor_user_id,payload,committed_membership_revision,created_at)
                        SELECT gen_random_uuid(),room_id,1,'message.accepted','{user}'::uuid,
                            jsonb_build_object('event_type','message.accepted','room_id',room_id::text,
                                'room_sequence',1,'timeline_sequence',1,'message_id',md5(room_id::text || ':message')::uuid,
                                'message_revision',1,'sender_user_id','{user}','text','tls-scale-message',
                                'server_created_at_ms',1750000000000),1,to_timestamp(1750000000)
                        FROM recovery_seed;
                        INSERT INTO im_v2.messages(message_id,room_id,room_sequence,timeline_sequence,sender_user_id,
                            client_message_id,text_body,created_at,accepted_event_storage)
                        SELECT md5(room_id::text || ':message')::uuid,room_id,1,1,'{user}'::uuid,
                            gen_random_uuid(),'tls-scale-message',to_timestamp(1750000000),'room_event' FROM recovery_seed;
                        {room_discovery_sql}
                        COMMIT;"""
                    run(['psql', '-X', *database_arguments, '-d', 'im_live_account', '-v', 'ON_ERROR_STOP=1'],
                        input=seed_sql, text=True)
                    scale_seeded.set()
                    print('Seeded nonempty recovery rooms: ' + str(args.room_recovery_scale), flush=True)

                class Proxy(http.server.BaseHTTPRequestHandler):
                    protocol_version = 'HTTP/1.1'

                    def log_message(self, *_):
                        pass  # No URLs, headers, credentials or bodies in logs.

                    def forward(self):
                        if (tls_relay is not None and self.command == 'POST'
                                and self.path in ('/__fixture__/tls-pause', '/__fixture__/tls-resume', '/__fixture__/tls-status', '/__fixture__/tls-disconnect')):
                            # Fixed controls for this owned relay only. TLS remains opaque.
                            with count_lock:
                                if self.path.endswith('tls-pause'):
                                    tls_relay.pause()
                                elif self.path.endswith('tls-resume'):
                                    tls_relay.resume()
                                elif self.path.endswith('tls-disconnect'):
                                    tls_relay.disconnect_current()
                                state = tls_relay.snapshot()
                                connection = http.client.HTTPConnection('127.0.0.1', metrics_port, timeout=8)
                                try:
                                    connection.request('GET', '/metrics')
                                    response = connection.getresponse()
                                    metrics = response.read().decode()
                                    if response.status != 200:
                                        raise RuntimeError('primary Gateway closure metrics unavailable')
                                finally:
                                    connection.close()
                                for reason in ('required_notification_backpressure', 'required_notification_write_timeout', 'idle_timeout'):
                                    match = re.search(r'^im_v2_gateway_connection_closures_total\{reason="' + reason + r'"\} (\d+)$', metrics, re.M)
                                    if not match:
                                        raise RuntimeError('required closure metric missing: ' + reason)
                                    state[reason] = int(match.group(1))
                                tls_relay_events.append(dict(action=self.path.rsplit('/', 1)[1],
                                    monotonicTime=time.monotonic(), **state))
                                (output / 'tls-relay-events.json').write_text(json.dumps(tls_relay_events, indent=2) + '\n')
                            payload = json.dumps(state).encode()
                            self.send_response(200)
                            self.send_header('Content-Type', 'application/json')
                            self.send_header('Content-Length', str(len(payload)))
                            self.send_header('Connection', 'close')
                            self.end_headers()
                            self.wfile.write(payload)
                            self.close_connection = True
                            return
                        if (args.room_recovery_broker_outage and self.command == 'POST'
                                and self.path in ('/__fixture__/broker-stop', '/__fixture__/broker-start')):
                            # Operates exclusively on the harness-owned process.
                            # No production route or arbitrary process selector.
                            with count_lock:
                                broker = recovery_broker[0]
                                if self.path.endswith('broker-stop'):
                                    if broker.poll() is not None:
                                        self.send_error(409)
                                        return
                                    broker.terminate()
                                    broker.wait(timeout=5)
                                    recovery_broker_events.append({'action': 'stop', 'pid': broker.pid,
                                        'exitCode': broker.returncode, 'monotonicTime': time.monotonic()})
                                else:
                                    if broker.poll() is None:
                                        self.send_error(409)
                                        return
                                    broker = subprocess.Popen([str(args.multi_gateway_nats_binary.resolve()),
                                        '-a', '127.0.0.1', '-p', str(nats_port)], stdout=nats_log, stderr=subprocess.STDOUT)
                                    recovery_broker[0] = broker
                                    additional_processes.append(broker)
                                    deadline = time.monotonic() + 10
                                    while True:
                                        if broker.poll() is not None:
                                            raise RuntimeError('owned broker restart failed')
                                        try:
                                            with socket.create_connection(('127.0.0.1', nats_port), timeout=.2):
                                                break
                                        except OSError:
                                            if time.monotonic() >= deadline:
                                                raise RuntimeError('owned broker restart timed out')
                                            time.sleep(.05)
                                    recovery_broker_events.append({'action': 'start', 'pid': broker.pid,
                                        'monotonicTime': time.monotonic()})
                                (output / 'broker-fault-events.json').write_text(
                                    json.dumps(recovery_broker_events, indent=2) + '\n')
                            self.send_response(204)
                            self.send_header('Content-Length', '0')
                            self.send_header('Connection', 'close')
                            self.end_headers()
                            self.close_connection = True
                            return
                        length = int(self.headers.get('Content-Length', '0'))
                        if not 0 <= length <= 65536:
                            self.send_error(413)
                            return
                        body = self.rfile.read(length)
                        parsed = None
                        if args.interrupted_issuance or args.legacy_app or args.room_recovery_scale is not None:
                            try:
                                parsed = json.loads(body)
                            except (ValueError, UnicodeError):
                                pass
                            # This control exists only in the disposable test
                            # proxy. It cannot bypass any production endpoint.
                            if self.path == '/__fixture__/interruption-ready' and self.command == 'POST':
                                phase = parsed.get('phase') if isinstance(parsed, dict) else None
                                if phase not in interruption_ready:
                                    self.send_error(400)
                                    return
                                interruption_ready[phase].set()
                                self.send_response(204)
                                self.send_header('Content-Length', '0')
                                self.send_header('Connection', 'close')
                                self.end_headers()
                                self.close_connection = True
                                return
                        if args.gateway and self.command == 'POST' and self.path == '/v2/devices/revoke':
                            # Only the actual App connects to this gateway;
                            # the four host-side HTTP tests never open TLS.
                            gateway_samples.append({'beforeDeviceRevocation': gateway_connections()})
                        excluded = {'host', 'connection', 'transfer-encoding', 'forwarded', 'x-forwarded-for',
                                    'x-im-v2-account-edge-authorization', 'x-im-v2-account-client-address'}
                        headers = {k: v for k, v in self.headers.items() if k.lower() not in excluded}
                        headers['X-IM-V2-Account-Edge-Authorization'] = config['IM_V2_ACCOUNT_EDGE_AUTHORIZATION_SECRET_BASE64']
                        headers['X-IM-V2-Account-Client-Address'] = '127.0.0.1'
                        upstream = http.client.HTTPConnection('127.0.0.1', account_port, timeout=15)
                        try:
                            upstream.request(self.command, self.path, body, headers)
                            response = upstream.getresponse()
                            payload = response.read()
                            if (args.room_recovery_scale is not None and response.status == 200
                                    and self.path == '/v2/account-auth/password/register'
                                    and isinstance(parsed, dict) and parsed.get('displayName') == 'Room recovery scale'):
                                seed_recovery_rooms(parsed.get('accountHandle', ''))
                            with count_lock:
                                counts[(self.command, self.path.split('?')[0], response.status)] += 1
                                if (args.room_recovery_scale is not None and self.command == 'POST'
                                        and self.path == '/v2/device-credentials/refresh' and response.status == 200
                                        and isinstance(parsed, dict)
                                        and str(parsed.get('userID', '')).lower() == scale_auth['user']):
                                    scale_auth['successfulRefreshes'] += 1
                            terminate_phase = None
                            if args.legacy_app and isinstance(parsed, dict):
                                with count_lock:
                                    if self.path == '/v2/account-auth/password/register' and response.status == 200 and re.fullmatch(r'legacyapp_[a-f0-9]{20}', parsed.get('accountHandle', '')):
                                        interruption['legacyDevice'] = str(uuid.UUID(parsed['deviceID'])).upper()
                                    if self.path == '/v2/device-credentials/cancel-legacy-registration' and response.status == 204 and interruption['legacyDevice'] is not None and parsed.get('targetDeviceID') == interruption['legacyDevice']:
                                        if interruption['legacyTerminations'] == 0:
                                            interruption['legacyOperation'] = parsed['operationID']
                                            interruption['legacyAssertionDevice'] = parsed['assertionDeviceID']
                                            terminate_phase = 'legacy'
                                        else:
                                            interruption['legacyMatched'] &= parsed['operationID'] == interruption['legacyOperation'] and parsed['assertionDeviceID'] != interruption['legacyAssertionDevice']
                                            interruption['legacyReplays'] += 1
                            if args.interrupted_issuance and isinstance(parsed, dict):
                                request_device = parsed.get('deviceID')
                                if isinstance(request_device, dict):
                                    request_device = request_device.get('rawValue')
                                request_device = request_device.upper() if isinstance(request_device, str) else None
                                with count_lock:
                                    if self.path == '/v2/account-auth/password/register' and response.status == 200 and re.fullmatch(r'interrupt_[a-f0-9]{20}', parsed.get('accountHandle', '')):
                                        interruption['device'] = str(uuid.UUID(parsed['deviceID'])).upper()
                                    if self.path == '/v2/device-credentials' and response.status == 200 and interruption['device'] is not None and interruption['device'] == request_device and interruption['issueTerminations'] == 0:
                                        interruption['proof'] = parsed['cancellation']
                                        terminate_phase = 'issue'
                                    if self.path == '/v2/device-credentials/cancel-registration' and response.status == 204 and interruption['device'] is not None and interruption['device'] == request_device:
                                        interruption['proofMatched'] &= parsed == interruption['proof']
                                        if interruption['cancelTerminations'] == 0:
                                            terminate_phase = 'cancel'
                                        else:
                                            interruption['cancelReplays'] += 1
                            if terminate_phase:
                                # Hold every response byte until XCTest has
                                # returned from launch/tap and can observe the
                                # real process termination. Never return the
                                # issued credentials to the App or test code.
                                if not interruption_ready[terminate_phase].wait(timeout=20):
                                    interruption['failure'] = 'UI readiness timeout at ' + terminate_phase
                                else:
                                    stopped = subprocess.run(['xcrun', 'simctl', 'terminate', simulator, 'com.stskcxfz.imapp'],
                                        env=environment, capture_output=True, timeout=20)
                                    if stopped.returncode:
                                        interruption['failure'] = 'owned App termination failed at ' + terminate_phase
                                    else:
                                        with count_lock:
                                            interruption[terminate_phase + 'Terminations'] += 1
                                self.close_connection = True
                                return
                            self.send_response(response.status)
                            for key, value in response.getheaders():
                                if key.lower() not in {'connection', 'transfer-encoding', 'content-length'}:
                                    self.send_header(key, value)
                            self.send_header('Content-Length', str(len(payload)))
                            self.send_header('Connection', 'close')
                            self.end_headers()
                            self.wfile.write(payload)
                            self.close_connection = True
                        finally:
                            upstream.close()

                    do_GET = forward
                    do_POST = forward

                proxy = http.server.ThreadingHTTPServer(('127.0.0.1', 8443 if args.app_ui else 0), Proxy)
                tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                tls.minimum_version = ssl.TLSVersion.TLSv1_2
                tls.load_cert_chain(str(private / 'leaf.pem'), str(private / 'leaf.key'))
                proxy.socket = tls.wrap_socket(proxy.socket, server_side=True)
                proxy_thread = threading.Thread(target=proxy.serve_forever, daemon=True)
                proxy_thread.start()
                test_environment = dict(environment, IMV2_LIVE_ACCOUNT_HTTPS_URL='https://localhost:{}'.format(proxy.server_port),
                                        IMV2_LIVE_ACCOUNT_CA_DER=str(private / 'ca.der'))
                if args.current_logout:
                    test_environment['IMV2_LIVE_CURRENT_LOGOUT'] = '1'
                if args.legacy_client:
                    test_environment['IMV2_LIVE_LEGACY_RECOVERY'] = '1'
                live_filter = 'V2LiveAccountAuthorizationTests|V2LiveCurrentDeviceLogoutTests' if args.current_logout else 'V2LiveAccountAuthorizationTests'
                print('Fresh PostgreSQL, native account and isolated HTTPS listener ready.', flush=True)
                with (output / 'client.log').open('w') as log:
                    tests = subprocess.Popen(['swift', 'test', '--disable-build-manifest-caching',
                        '--disable-automatic-resolution', '--jobs', '4', '--filter', live_filter],
                        cwd=ROOT / 'IMV2ClientKit', env=test_environment, stdout=log, stderr=subprocess.STDOUT,
                        start_new_session=True)
                    try:
                        result = tests.wait(timeout=240)
                    except BaseException:
                        if tests.poll() is None:
                            os.killpg(tests.pid, signal.SIGTERM)
                            try:
                                tests.wait(timeout=5)
                            except subprocess.TimeoutExpired:
                                os.killpg(tests.pid, signal.SIGKILL)
                                tests.wait(timeout=5)
                        raise
                log_text = (output / 'client.log').read_text()
                # Swift Testing may include disabled cases in its final total.
                # Require each selected live case to pass; skipped cases never
                # satisfy this check, regardless of the aggregate test count.
                required_live_cases = [
                    'rejected access token refreshes against the real account service',
                    'another real device revokes this device and HTTP requests end its session',
                    'expired local access plus rejected real refresh clears the credential',
                    'an untrusted real TLS certificate is not account revocation',
                ]
                if args.current_logout:
                    required_live_cases.append('current logout revokes all rotations, preserves another device and tolerates concurrent delivery')
                missing_live_cases = [name for name in required_live_cases
                                      if len(re.findall(r'Test "' + re.escape(name) + r'" passed', log_text)) != 1]
                if result == 0 and missing_live_cases:
                    raise RuntimeError('live cases did not pass exactly once: ' + ', '.join(missing_live_cases))
                summary = {'testExitCode': result, 'httpResponses': [
                    {'method': method, 'path': path, 'status': status, 'count': count}
                    for (method, path, status), count in sorted(counts.items())]}
                (output / 'http-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
                if result:
                    raise RuntimeError('live authentication tests failed; inspect client.log')
                if args.legacy_client:
                    # The fixture deliberately allows only two simultaneous
                    # password workers. Run the third suite after the baseline
                    # suites instead of accidentally testing load rejection.
                    with (output / 'legacy-client-tests.log').open('w') as log:
                        tests = subprocess.Popen(['swift', 'test', '--skip-build', '--filter', 'V2LiveLegacyRegistrationRecoveryTests'],
                            cwd=ROOT / 'IMV2ClientKit', env=test_environment, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                        try:
                            legacy_result = tests.wait(timeout=120)
                        except BaseException:
                            if tests.poll() is None:
                                os.killpg(tests.pid, signal.SIGTERM)
                                try:
                                    tests.wait(timeout=5)
                                except subprocess.TimeoutExpired:
                                    os.killpg(tests.pid, signal.SIGKILL)
                                    tests.wait(timeout=5)
                            raise
                    assert legacy_result == 0, 'legacy ClientKit acceptance failed; inspect legacy-client-tests.log'
                    assert re.search(r'Test run with 1 test in 1 suite passed', (output / 'legacy-client-tests.log').read_text())
                if args.load_credentials:
                    prepared_path = private / 'load-credentials.jsonl'
                    with (output / 'load-preparation.log').open('w') as log:
                        subprocess.run(['bash', str(ROOT / 'IMV2/scripts/prepare_v2_gateway_load_credentials.sh'),
                            test_environment['IMV2_LIVE_ACCOUNT_HTTPS_URL'], str(private / 'ca.pem'), '1', str(prepared_path)],
                            env=dict(environment, IM_V2_LOAD_CREDENTIAL_PREPARE_PARALLELISM='1'),
                            stdout=log, stderr=subprocess.STDOUT, timeout=60, check=True)
                    prepared = json.loads(prepared_path.read_text())
                    proof_paths = list(Path(str(prepared_path) + '.registration-recovery').glob('*.json'))
                    assert len(proof_paths) == 1
                    proof = json.loads(proof_paths[0].read_text())
                    assert prepared['registrationCancellation'] == proof
                    def script_request(method, path, body=None, authenticated=False):
                        connection = http.client.HTTPSConnection('localhost', proxy.server_port, timeout=15,
                            context=ssl.create_default_context(cafile=str(private / 'ca.pem')))
                        headers = {'Content-Type': 'application/json'}
                        if authenticated:
                            headers.update(Authorization='Bearer ' + prepared['accessToken'])
                            headers['X-IM-Device-ID'] = prepared['deviceID']
                        try:
                            connection.request(method, path, json.dumps(body) if body else None, headers)
                            response = connection.getresponse()
                            response.read()
                            return response.status
                        finally:
                            connection.close()
                    assert script_request('GET', '/v2/devices', authenticated=True) == 200
                    assert script_request('POST', '/v2/device-credentials/cancel-registration', proof) == 204
                    assert script_request('GET', '/v2/devices', authenticated=True) == 401
                    (output / 'load-credentials-proof.log').write_text('PASS actual preparation script issued credentials with confirmed saved proof; real authorization accepted before cancellation and rejected afterward\n')
                if args.app_ui:
                    if args.room_recovery_app_reconnect:
                        environment['TEST_RUNNER_IMV2_ROOM_RECOVERY_APP_RECONNECT'] = '1'
                        environment['SIMCTL_CHILD_IMV2_ROOM_RECOVERY_APP_RECONNECT'] = '1'
                    if args.room_recovery_membership_race:
                        environment['TEST_RUNNER_IMV2_ROOM_RECOVERY_MEMBERSHIP_RACE'] = '1'
                        environment['SIMCTL_CHILD_IMV2_ROOM_RECOVERY_MEMBERSHIP_RACE'] = '1'
                    if args.room_recovery_slow_tls:
                        environment['TEST_RUNNER_IMV2_ROOM_RECOVERY_SLOW_TLS'] = '1'
                        environment['SIMCTL_CHILD_IMV2_ROOM_RECOVERY_SLOW_TLS'] = '1'
                    if args.room_recovery_scan_race:
                        environment['TEST_RUNNER_IMV2_ROOM_RECOVERY_SCAN_RACE'] = args.room_recovery_scan_race
                        environment['SIMCTL_CHILD_IMV2_ROOM_RECOVERY_SCAN_RACE'] = args.room_recovery_scan_race
                    if args.room_recovery_drop_tail:
                        environment['TEST_RUNNER_IMV2_ROOM_RECOVERY_DROP_TAIL'] = '1'
                        environment['SIMCTL_CHILD_IMV2_ROOM_RECOVERY_DROP_TAIL'] = '1'
                    simulator = subprocess.check_output(['xcrun', 'simctl', 'create', 'IM B09 disposable authentication',
                        'com.apple.CoreSimulator.SimDeviceType.iPhone-17', args.simulator_runtime],
                        env=environment, text=True).strip()
                    print('Created dedicated simulator ' + simulator, flush=True)
                    run(['xcrun', 'simctl', 'boot', simulator])
                    run(['xcrun', 'simctl', 'bootstatus', simulator, '-b'], timeout=180)
                    run(['xcrun', 'simctl', 'keychain', simulator, 'add-root-cert', str(private / 'ca.pem')])
                    if args.room_recovery_scale is not None:
                        environment['TEST_RUNNER_IMV2_ROOM_RECOVERY_SCALE'] = str(args.room_recovery_scale)
                        environment['SIMCTL_CHILD_IMV2_ROOM_RECOVERY_SCALE'] = str(args.room_recovery_scale)
                    with (output / 'app.log').open('w') as log:
                        test_selector = 'IMAppLocalAccountE2ETests/IMAppLocalAuthenticationTerminationUITests'
                        if not args.gateway:
                            test_selector += '/testRemoteDeviceRevocationReturnsToLoginAndSurvivesRelaunch'
                        additional_tests = ['-only-testing:IMAppLocalAccountE2ETests/IMAppInterruptedRegistrationUITests'] if args.interrupted_issuance else []
                        if args.room_recovery_scale is not None:
                            additional_tests += ['-only-testing:IMAppLocalAccountE2ETests/IMAppRoomRecoveryScaleTests']
                        if args.private_hint:
                            additional_tests += ['-only-testing:IMAppLocalAccountE2ETests/IMAppLocalAccountUITests/testReceiverCanBlockAndRestoreExistingDirectMessageDelivery']
                        if args.legacy_app:
                            additional_tests += ['-only-testing:IMAppLocalAccountE2ETests/IMAppLegacyRegistrationUITests']
                        ui = subprocess.Popen(['xcodebuild', 'test', '-project', str(ROOT / 'IMApp/IMApp.xcodeproj'),
                            '-scheme', 'IMAppLocalAccountE2E', '-configuration', 'Debug',
                            '-destination', 'platform=iOS Simulator,id=' + simulator,
                            '-disableAutomaticPackageResolution', '-collect-test-diagnostics', 'never',
                            '-only-testing:' + test_selector,
                            *additional_tests,
                            '-resultBundlePath', str(output / 'app.xcresult')],
                            cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                        meter_stop = threading.Event()
                        meter = None
                        if args.room_recovery_scale is not None:
                            def sample_scale_resources():
                                while not meter_stop.wait(1):
                                    if not scale_seeded.is_set():
                                        continue
                                    try:
                                        listing = subprocess.check_output(['ps', '-axo', 'pid=,rss=,time=,comm='],
                                            env=environment, text=True, timeout=5)
                                        for line in listing.splitlines():
                                            fields = line.strip().split(None, 3)
                                            if len(fields) != 4:
                                                continue
                                            pid, rss, cpu_time, command = fields
                                            role = ('gateway' if int(pid) == gateway.pid else
                                                'test-runner' if simulator in command and command.endswith('/IMAppLocalAccountE2ETests-Runner') else None)
                                            if role:
                                                scale_resource_samples.append(dict(time=time.monotonic(), role=role,
                                                    pid=int(pid), rssBytes=int(rss)*1024, cumulativeCPU=cpu_time))
                                    except Exception as error:
                                        scale_resource_samples.append(dict(error=type(error).__name__))
                            meter = threading.Thread(target=sample_scale_resources, daemon=True)
                            meter.start()
                        try:
                            # Keep production rate limits. Large recovery may legitimately
                            # need more than the auth-only harness's 15-minute budget.
                            timeout = max(900, 2 * (args.room_recovery_scale or 0) // 5 + 300)
                            app_result = ui.wait(timeout=timeout)
                        except BaseException:
                            if ui.poll() is None:
                                os.killpg(ui.pid, signal.SIGTERM)
                                try:
                                    ui.wait(timeout=10)
                                except subprocess.TimeoutExpired:
                                    os.killpg(ui.pid, signal.SIGKILL)
                                    ui.wait(timeout=5)
                            raise
                        finally:
                            meter_stop.set()
                            if meter is not None:
                                meter.join(timeout=10)
                                if meter.is_alive():
                                    raise RuntimeError('resource sampler did not stop')
                                (output / 'scale-resource-samples.json').write_text(json.dumps(scale_resource_samples, indent=2) + '\n')
                    app_summary = json.loads(subprocess.check_output(['xcrun', 'xcresulttool', 'get',
                        'test-results', 'summary', '--path', str(output / 'app.xcresult'), '--compact'],
                        env=environment, text=True))
                    (output / 'app-summary.json').write_text(json.dumps(app_summary, indent=2) + '\n')
                    if app_result != 0 or app_summary.get('passedTests') != (2 if args.gateway else 1) + int(args.interrupted_issuance) + int(args.legacy_app) + int(args.private_hint) + int(args.room_recovery_scale is not None) or app_summary.get('failedTests') != 0:
                        # Only these existing messages contain whitelisted error
                        # classifications/types. Never export arbitrary App logs.
                        predicate = ('process == "IMApp" AND ('
                            'eventMessage BEGINSWITH "Password account authentication failed:" OR '
                            'eventMessage BEGINSWITH "Password authentication failed with error type ")')
                        try:
                            diagnostic = subprocess.run(['xcrun', 'simctl', 'spawn', simulator, 'log', 'show',
                                '--last', '15m', '--style', 'compact', '--predicate', predicate],
                                capture_output=True, text=True, timeout=20)
                            (output / 'app-auth-failure-types.log').write_text(diagnostic.stdout)
                        except subprocess.TimeoutExpired:
                            (output / 'app-auth-failure-types.log').write_text('Diagnostic collection timed out.\n')
                        raise RuntimeError('App UI authentication acceptance failed; inspect app.log and app.xcresult')
                    if args.room_recovery_scale is not None:
                        assert 'IMV2_TLS_ROOM_RECOVERY_SCALE_PASSED rooms=' + str(args.room_recovery_scale) in (output / 'app.log').read_text()
                        if args.room_recovery_membership_race:
                            assert 'IMV2_TLS_ROOM_MEMBERSHIP_RACE_PASSED' in (output / 'app.log').read_text()
                            assert 'IMV2_TLS_ROOM_DIRECTORY_JOIN_PASSED' in (output / 'app.log').read_text()
                            assert 'IMV2_TLS_ROOM_UNKNOWN_DIRECTORY_JOIN_PASSED' in (output / 'app.log').read_text()
                        if args.room_recovery_app_reconnect:
                            assert 'IMV2_APP_AUTOMATIC_RECONNECT_PASSED cycles=3' in (output / 'app.log').read_text()
                            assert [event['action'] for event in tls_relay_events] == ['tls-disconnect'] * 3
                        if args.room_recovery_slow_tls:
                            assert 'IMV2_TLS_ROOM_SLOW_TLS_RECOVERY_PASSED' in (output / 'app.log').read_text()
                            actions = [event['action'] for event in tls_relay_events if event['action'] != 'tls-status']
                            assert actions == ['tls-pause', 'tls-resume'], 'TLS fault cycle did not complete'
                        if args.room_recovery_scan_race:
                            assert 'IMV2_TLS_ROOM_SCAN_RACE_PASSED boundary=' + args.room_recovery_scan_race in (output / 'app.log').read_text()
                        if args.room_recovery_drop_tail:
                            assert 'IMV2_TLS_ROOM_SILENT_TAIL_RECOVERY_PASSED' in (output / 'app.log').read_text()
                        if args.room_recovery_broker_outage:
                            assert 'IMV2_TLS_ROOM_BROKER_RECOVERY_PASSED' in (output / 'app.log').read_text()
                            assert [event['action'] for event in recovery_broker_events] == ['stop', 'start'], 'broker fault cycle did not complete'
                            assert recovery_broker_events[0]['pid'] != recovery_broker_events[1]['pid'], 'broker process was not replaced'
                            assert recovery_broker[0].poll() is None, 'restarted broker exited before acceptance'
                        if args.room_recovery_scale > 0:
                            assert 'IMV2_TLS_ROOM_ONLINE_PASSED rooms=' + str(args.room_recovery_scale) in (output / 'app.log').read_text()
                    if args.private_hint:
                        assert 'IMV2_THREE_FOREGROUND_RECOVERY_CYCLES_PASSED' in (output / 'app.log').read_text()
                        assert 'IMV2_FOREGROUND_RECOVERY_COMPLETION_PASSED' in (output / 'app.log').read_text()
                    if args.multi_gateway_nats_binary:
                        if args.private_hint:
                            assert 'IMV2_CROSS_GATEWAY_RECOVERY_AND_ONLINE_WAKE_PASSED' in (output / 'app.log').read_text()
                        if args.room_recovery_scale:
                            assert 'IMV2_TLS_ROOM_CROSS_GATEWAY_PASSED rooms=' + str(args.room_recovery_scale) in (output / 'app.log').read_text()
                    if args.gateway:
                        assert any(sample['beforeDeviceRevocation'] > 0 for sample in gateway_samples), gateway_samples
                        deadline = time.monotonic() + 5
                        while gateway_connections() != 0:
                            if time.monotonic() >= deadline:
                                raise RuntimeError('gateway still has authenticated connections after App cleanup')
                            time.sleep(.05)
                        gateway_samples.append({'afterAppCleanup': 0})
                    # Update counts after the actual App has stopped and its
                    # scoped Keychain/SQLite cleanup launch has completed.
                    summary['appExitCode'] = app_result
                    summary['httpResponses'] = [
                        {'method': method, 'path': path, 'status': status, 'count': count}
                        for (method, path, status), count in sorted(counts.items())]
                    (output / 'http-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
                if args.headless_app:
                    with (output / 'headless.log').open('w') as log:
                        headless = subprocess.Popen(['xcodebuild', 'test', '-project', str(ROOT / 'IMApp/IMApp.xcodeproj'),
                            '-scheme', 'IMApp', '-configuration', 'Debug',
                            '-destination', 'platform=iOS Simulator,id=' + simulator,
                            '-disableAutomaticPackageResolution', '-collect-test-diagnostics', 'never',
                            '-only-testing:IMAppTests/V2HeadlessPushIntegrationTests',
                            '-resultBundlePath', str(output / 'headless.xcresult')],
                            cwd=ROOT, env=dict(environment, TEST_RUNNER_IMV2_HEADLESS_PUSH_TEST='1',
                                              SIMCTL_CHILD_IMV2_HEADLESS_PUSH_TEST='1'),
                            stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                        try:
                            headless_result = headless.wait(timeout=300)
                        except BaseException:
                            if headless.poll() is None:
                                os.killpg(headless.pid, signal.SIGTERM)
                                try:
                                    headless.wait(timeout=10)
                                except subprocess.TimeoutExpired:
                                    os.killpg(headless.pid, signal.SIGKILL)
                                    headless.wait(timeout=5)
                            raise
                    headless_summary = json.loads(subprocess.check_output(['xcrun', 'xcresulttool', 'get',
                        'test-results', 'summary', '--path', str(output / 'headless.xcresult'), '--compact'],
                        env=environment, text=True))
                    (output / 'headless-summary.json').write_text(json.dumps(headless_summary, indent=2) + '\n')
                    if headless_result != 0 or headless_summary.get('passedTests') != 1 or headless_summary.get('skippedTests') != 0:
                        raise RuntimeError('headless Push acceptance did not execute and pass; inspect headless.log')
                    if gateway_connections() != 0:
                        raise RuntimeError('gateway connection remains after headless Push cleanup')
                    gateway_samples.append({'afterHeadlessCleanup': 0})
                # Assert persisted server effects, not only client presentation.
                sql = """SELECT
                    (SELECT count(*) FROM im_v2.auth_devices),
                    (SELECT count(*) FROM im_v2.auth_devices WHERE revoked_at IS NOT NULL),
                    (SELECT count(*) FROM im_v2.device_access_tokens t
                     JOIN im_v2.auth_devices d USING (device_id)
                     WHERE d.revoked_at IS NOT NULL AND t.revoked_at IS NULL),
                    (SELECT count(*) FROM im_v2.device_refresh_sessions s
                     JOIN im_v2.auth_devices d USING (device_id)
                     WHERE d.revoked_at IS NOT NULL AND s.revoked_at IS NULL),
                    (SELECT count(*) FROM im_v2.device_revocation_events)"""
                persisted = subprocess.check_output(['psql', '-X', '-A', '-t', *database_arguments,
                    '-d', 'im_live_account', '-v', 'ON_ERROR_STOP=1', '-c', sql], env=environment, text=True).strip()
                (output / 'persistence-observed.log').write_text(persisted + '\n')
                # Automatic reconnect signs the scoped App into the scale
                # account in addition to the test-owned sender session. The
                # three transport reconnects must reuse that one App device.
                expected_devices = 5 + (6 if args.gateway else 3 if args.app_ui else 0) + (2 if args.headless_app else 0) + (3 if args.current_logout else 0) + 2 * int(args.interrupted_issuance) + int(args.load_credentials) + 2 * int(args.legacy_client) + 2 * int(args.legacy_app) + 3 * int(args.private_hint) + int(args.room_recovery_scale is not None) + int(args.room_recovery_membership_race) + int(args.room_recovery_app_reconnect)
                expected_revoked = 1 + (2 if args.gateway else 1 if args.app_ui else 0) + int(args.headless_app) + (3 if args.current_logout else 0) + int(args.interrupted_issuance) + int(args.load_credentials) + int(args.legacy_client) + int(args.legacy_app)
                assert persisted == '{}|{}|0|0|{}'.format(expected_devices, expected_revoked, expected_revoked), persisted
                if args.room_recovery_app_reconnect:
                    scale_user = str(uuid.UUID(scale_auth['user']))
                    reconnect_devices = subprocess.check_output(['psql', '-X', '-A', '-t', *database_arguments,
                        '-d', 'im_live_account', '-v', 'ON_ERROR_STOP=1', '-c',
                        "SELECT count(*), count(*) FILTER (WHERE revoked_at IS NOT NULL) "
                        "FROM im_v2.auth_devices WHERE user_id = '" + scale_user + "'::uuid"],
                        env=environment, text=True).strip()
                    (output / 'app-reconnect-devices-observed.log').write_text(reconnect_devices + '\n')
                    assert reconnect_devices == '2|0', 'sender and scoped App must each retain one device: ' + reconnect_devices
                terminal_refreshes = counts[('POST', '/v2/device-credentials/refresh', 401)]
                assert terminal_refreshes in [value + int(args.current_logout) for value in ([3, 4] if args.gateway else [3] if args.app_ui else [2])]
                assert counts[('POST', '/v2/device-credentials/refresh', 200)] == 1 + int(args.current_logout) + scale_auth['successfulRefreshes']
                if args.room_recovery_scale is not None:
                    client_refreshes = re.findall(r'^IMV2_TLS_ROOM_AUTH_REFRESHES count=(\d+)$',
                        (output / 'app.log').read_text(), re.MULTILINE)
                    assert client_refreshes == [str(scale_auth['successfulRefreshes'])], 'scale refresh observations disagree'
                    if args.room_recovery_scale == 50:
                        assert scale_auth['successfulRefreshes'] == 1, '50-room rotation was not observed exactly once'
                        assert 'IMV2_TLS_ROOM_FORCED_REFRESH_PASSED rooms=50' in (output / 'app.log').read_text()
                    (output / 'scale-auth-summary.json').write_text(json.dumps({
                        'successfulRefreshes': scale_auth['successfulRefreshes']
                    }, indent=2) + '\n')
                assert counts[('POST', '/v2/devices/revoke', 204)] == (4 if args.headless_app else 3 if args.gateway else 2 if args.app_ui else 1)
                if args.current_logout:
                    assert counts[('POST', '/v2/device-credentials/cancel-registration', 204)] == 4 + 2 * int(args.interrupted_issuance) + int(args.load_credentials) + int(args.legacy_app)
                    assert counts[('POST', '/v2/device-credentials/cancel-registration', 410)] == 1
                    assert counts[('POST', '/v2/device-credentials/cancel-registration', 400)] == 1
                    cancellations = subprocess.check_output(['psql', '-X', '-A', '-t', *database_arguments,
                        '-d', 'im_live_account', '-v', 'ON_ERROR_STOP=1', '-c',
                        'SELECT count(*), count(user_id), count(cancelled_at) FROM im_v2.device_registration_cancellations'], env=environment, text=True).strip()
                    assert cancellations == '{}|{}|{}'.format(expected_devices + 1 + int(args.legacy_app), expected_devices, 2 + int(args.interrupted_issuance) + int(args.load_credentials) + int(args.legacy_app)), cancellations
                    (output / 'registration-cancellation.log').write_text('PASS pre-issuance cancellation replay; entire issuance response discarded before issuer decode; cold owner queued original proof; cancellation runner retained proof after lost cancellation response and replayed successfully: ' + cancellations + '\n')
                    assert counts[('POST', '/v2/devices/revoke-current', 204)] >= 1
                    assert counts[('POST', '/v2/devices/revoke-current', 400)] == 1
                    assert counts[('POST', '/v2/devices/revoke-current', 503)] == 1
                    assert counts[('POST', '/v2/device-credentials/revoke', 204)] >= 4
                    if not args.app_ui:
                        assert counts[('POST', '/v2/device-credentials/revoke', 204)] == 4
                    assert counts[('POST', '/v2/device-credentials/revoke', 409)] == 1
                    assert counts[('POST', '/v2/device-credentials/revoke', 401)] == 1
                    # A remote revoke and the App's independent compensation
                    # may journal different operation IDs for one device. The
                    # event/device effect must still occur exactly once.
                    operations = subprocess.check_output(['psql', '-X', '-A', '-t', *database_arguments,
                        '-d', 'im_live_account', '-v', 'ON_ERROR_STOP=1', '-c',
                        """SELECT count(*), count(DISTINCT target_device_id),
                        count(*) FILTER (WHERE operation_kind <> 'revoke_device'),
                        count(*) FILTER (WHERE EXISTS (SELECT 1 FROM im_v2.auth_devices d
                            WHERE d.device_id = target_device_id AND d.revoked_at IS NULL))
                        FROM im_v2.device_session_operations"""], env=environment, text=True).strip()
                    total, targets, other_kinds, active_targets = map(int, operations.split('|'))
                    # The lost issuance uses its separate cancellation journal.
                    assert targets == expected_revoked - 1 - int(args.interrupted_issuance) - int(args.load_credentials) - int(args.legacy_client) - int(args.legacy_app), operations
                    app_compensations = 2 if args.gateway else 1 if args.app_ui else 0
                    assert targets <= total <= targets + app_compensations, operations
                    assert other_kinds == active_targets == 0, operations
                    (output / 'logout-journal.log').write_text('PASS revocation journal total/unique targets/other kinds/active targets: ' + operations + '; independent App compensation may add an operation but no duplicate device event\n')
                (output / 'persistence.log').write_text('PASS persisted device/revocation/active-access/active-refresh/event counts: ' + persisted + '\n')
                if args.interrupted_issuance:
                    assert interruption['failure'] is None, interruption['failure']
                    assert interruption['issueTerminations'] == interruption['cancelTerminations'] == interruption['cancelReplays'] == 1
                    assert interruption['proofMatched']
                    target = str(uuid.UUID(interruption['device']))
                    interrupted_sql = """SELECT
                        (SELECT count(*) FROM im_v2.auth_devices WHERE user_id = (SELECT user_id FROM im_v2.auth_devices WHERE device_id = '{0}'::uuid)),
                        (SELECT count(*) FROM im_v2.auth_devices WHERE device_id = '{0}'::uuid AND revoked_at IS NOT NULL),
                        (SELECT count(*) FROM im_v2.device_registration_cancellations WHERE device_id = '{0}'::uuid AND cancelled_at IS NOT NULL),
                        (SELECT count(*) FROM im_v2.device_revocation_events WHERE device_id = '{0}'::uuid),
                        (SELECT count(*) FROM im_v2.device_access_tokens WHERE device_id = '{0}'::uuid AND revoked_at IS NULL),
                        (SELECT count(*) FROM im_v2.device_refresh_sessions WHERE device_id = '{0}'::uuid AND revoked_at IS NULL)""".format(target)
                    observed = subprocess.check_output(['psql', '-X', '-A', '-t', *database_arguments,
                        '-d', 'im_live_account', '-v', 'ON_ERROR_STOP=1', '-c', interrupted_sql], env=environment, text=True).strip()
                    assert observed == '2|1|1|1|0|0', observed
                    (output / 'interrupted-issuance.log').write_text('PASS actual App terminated twice before response forwarding; Keychain proof matched on both cold cancellation requests; one revocation event; new login uses a new device: ' + observed + '\n')
                if args.legacy_registration:
                    from verify_v2_legacy_registration_http import verify_legacy_registration
                    verify_legacy_registration(proxy.server_port, private / 'ca.pem', database_arguments, environment, output)
                if args.legacy_app:
                    assert interruption['failure'] is None, interruption['failure']
                    assert interruption['legacyTerminations'] == interruption['legacyReplays'] == 1
                    assert interruption['legacyMatched']
                    old = str(uuid.UUID(interruption['legacyDevice']))
                    first = str(uuid.UUID(interruption['legacyAssertionDevice']))
                    legacy_sql = """SELECT
                        (SELECT count(*) FROM im_v2.auth_devices WHERE user_id=(SELECT user_id FROM im_v2.auth_devices WHERE device_id='{0}'::uuid)),
                        (SELECT count(*) FROM im_v2.auth_devices WHERE device_id='{0}'::uuid AND revoked_at IS NOT NULL),
                        (SELECT count(*) FROM im_v2.legacy_device_registration_cancellations WHERE device_id='{0}'::uuid),
                        (SELECT count(*) FROM im_v2.device_revocation_events WHERE device_id='{0}'::uuid),
                        (SELECT count(*) FROM im_v2.device_access_tokens WHERE device_id='{0}'::uuid AND revoked_at IS NULL),
                        (SELECT count(*) FROM im_v2.device_refresh_sessions WHERE device_id='{0}'::uuid AND revoked_at IS NULL),
                        (SELECT count(*) FROM im_v2.auth_devices WHERE device_id='{1}'::uuid),
                        (SELECT count(*) FROM im_v2.device_registration_cancellations WHERE device_id='{1}'::uuid AND user_id IS NULL AND cancelled_at IS NOT NULL)""".format(old, first)
                    observed = subprocess.check_output(['psql', '-X', '-A', '-t', *database_arguments, '-d', 'im_live_account', '-v', 'ON_ERROR_STOP=1', '-c', legacy_sql], env=environment, text=True).strip()
                    assert observed == '2|1|1|1|0|0|0|1', observed
                    (output / 'legacy-app.log').write_text('PASS real App termination before legacy acknowledgement; unseeded restart replayed original archived operation with new assertion device; new login survives another cold restore; target state: ' + observed + '\n')
                if args.legacy_client:
                    assert counts[('POST', '/v2/device-credentials/cancel-legacy-registration', 204)] >= 2
                    (output / 'legacy-client.log').write_text('PASS real ClientKit factor/legacy cancellation/issuance; discarded first cleanup acknowledgement, reopened archive and replayed before issuing new credentials; old access rejected and new device authorized.\n')
                print('PASS: selected real HTTPS account tests and persisted device/HTTP effects.', flush=True)
            finally:
                for ready in interruption_ready.values():
                    ready.set()
                if args.interrupted_issuance or args.legacy_app:
                    (output / 'interruption-summary.json').write_text(json.dumps({key: value for key, value in interruption.items() if key not in ['device', 'proof', 'legacyDevice', 'legacyOperation', 'legacyAssertionDevice']}, indent=2) + '\n')
                if args.gateway:
                    (output / 'gateway-samples.json').write_text(json.dumps(gateway_samples, indent=2) + '\n')
                (output / 'http-summary.json').write_text(json.dumps({
                    'testExitCode': result, 'appExitCode': app_result,
                    'httpResponses': [{'method': method, 'path': path, 'status': status, 'count': count}
                                      for (method, path, status), count in sorted(counts.items())]
                }, indent=2) + '\n')
                simulator_cleanup_error = None
                tls_cleanup_error = None
                if simulator is not None:
                    subprocess.run(['xcrun', 'simctl', 'shutdown', simulator], stdout=setup, stderr=subprocess.STDOUT, env=environment)
                    deletion = subprocess.run(['xcrun', 'simctl', 'delete', simulator], stdout=setup, stderr=subprocess.STDOUT, env=environment)
                    if deletion.returncode:
                        simulator_cleanup_error = RuntimeError('could not remove owned simulator ' + simulator)
                    else:
                        print('Removed dedicated simulator ' + simulator, flush=True)
                if proxy is not None:
                    proxy.shutdown()
                    proxy.server_close()
                if proxy_thread is not None:
                    proxy_thread.join(timeout=5)
                if tls_relay is not None:
                    try:
                        tls_relay.close()
                    except RuntimeError as error:
                        tls_cleanup_error = error
                if gateway is not None and gateway.poll() is None:
                    gateway.terminate()
                    try:
                        gateway.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        gateway.kill()
                        gateway.wait(timeout=5)
                for owned in reversed(additional_processes):
                    if owned.poll() is None:
                        owned.terminate()
                        try:
                            owned.wait(timeout=15)
                        except subprocess.TimeoutExpired:
                            owned.kill()
                            owned.wait(timeout=5)
                for log in additional_logs:
                    log.close()
                if gateway_log is not None:
                    gateway_log.close()
                if account is not None and account.poll() is None:
                    account.terminate()
                    try:
                        account.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        account.kill()
                        account.wait(timeout=5)
                if postgres_started:
                    subprocess.run(['pg_ctl', '-D', str(data), 'stop', '-m', 'fast', '-w'],
                                   stdout=setup, stderr=subprocess.STDOUT, env=environment, check=True)
                if (private / 'postgres.log').exists():
                    shutil.copy2(private / 'postgres.log', output / 'postgres.log')
                (output / 'cleanup.log').write_text('Owned HTTP listener, account and optional Gateway processes stopped; owned PostgreSQL cluster stopped; dedicated simulator removal attempted when created.\n')
                if simulator_cleanup_error:
                    raise simulator_cleanup_error
                if tls_cleanup_error:
                    raise tls_cleanup_error
    with (output / 'cleanup.log').open('a') as cleanup:
        cleanup.write('Private temporary database, certificates and keys removed; existing stores and trust settings unchanged.\n')


if __name__ == '__main__':
    main()
