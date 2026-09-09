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

ROOT = Path(__file__).resolve().parents[1]


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True,
                        help='new evidence directory; existing directories are rejected')
    parser.add_argument('--app-ui', action='store_true', help='also run the real App revocation UI test in a newly created, disposable iPhone 17 / iOS 26.2 simulator; reserves localhost:8443')
    parser.add_argument('--gateway', action='store_true', help='with --app-ui, also start the real TLS Gateway on loopback:7443 and verify connected-session revocation')
    parser.add_argument('--headless-app', action='store_true', help='with --app-ui --gateway, also run real credential Push entry in an App host without constructing its root view')
    parser.add_argument('--current-logout', action='store_true', help='also verify current-device logout through real HTTPS and PostgreSQL')
    parser.add_argument('--interrupted-issuance', action='store_true', help='with --app-ui --current-logout, terminate the owned App after issuance and cancellation commit but before either response is forwarded')
    parser.add_argument('--load-credentials', action='store_true', help='exercise the actual load credential preparation script and cancel its issued session through the saved proof')
    parser.add_argument('--legacy-registration', action='store_true', help='after baseline checks, verify legacy cancellation with real password factors, HTTPS and PostgreSQL rollback')
    parser.add_argument('--legacy-client', action='store_true', help='with --current-logout, run ClientKit legacy archive recovery and lost acknowledgement replay against HTTPS')
    parser.add_argument('--legacy-app', action='store_true', help='with --app-ui --current-logout, terminate App after legacy cleanup commit and verify real Keychain replay')
    args = parser.parse_args()
    if args.gateway and not args.app_ui:
        parser.error('--gateway requires --app-ui')
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
        gateway_samples = []
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
                    gateway_config.update(IM_V2_TLS_HOST='127.0.0.1', IM_V2_TLS_PORT='7443',
                        IM_V2_TLS_CERTIFICATE_CHAIN_PATH=str(private / 'leaf.pem'),
                        IM_V2_TLS_PRIVATE_KEY_PATH=str(private / 'leaf.key'),
                        IM_V2_METRICS_HOST='127.0.0.1', IM_V2_METRICS_PORT=str(metrics_port),
                        IM_V2_METRICS_MINIMUM_REFRESH_INTERVAL_MS='4000')
                    gateway_log = (output / 'gateway.log').open('w')
                    gateway = subprocess.Popen([str(ROOT / 'IMV2Server/.build/debug/IMV2ServerApp')],
                        env=dict(environment, **gateway_config), stdout=gateway_log, stderr=subprocess.STDOUT)
                    deadline = time.monotonic() + 40
                    while True:
                        if gateway.poll() is not None:
                            raise RuntimeError('gateway startup failed; inspect gateway.log')
                        try:
                            with socket.create_connection(('127.0.0.1', 7443), timeout=.2):
                                gateway_connections()
                                break
                        except OSError:
                            if time.monotonic() >= deadline:
                                raise RuntimeError('gateway startup deadline exceeded')
                            time.sleep(.05)
                    print('Native TLS Gateway and authenticated-connection metrics ready.', flush=True)

                class Proxy(http.server.BaseHTTPRequestHandler):
                    protocol_version = 'HTTP/1.1'

                    def log_message(self, *_):
                        pass  # No URLs, headers, credentials or bodies in logs.

                    def forward(self):
                        length = int(self.headers.get('Content-Length', '0'))
                        if not 0 <= length <= 65536:
                            self.send_error(413)
                            return
                        body = self.rfile.read(length)
                        parsed = None
                        if args.interrupted_issuance or args.legacy_app:
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
                            with count_lock:
                                counts[(self.command, self.path.split('?')[0], response.status)] += 1
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
                expected_live_tests = r'Test run with 5 tests in 2 suites passed' if args.current_logout else r'Test run with 4 tests in 1 suite passed'
                if result == 0 and not re.search(expected_live_tests, log_text):
                    raise RuntimeError('live suites did not execute all selected tests')
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
                    simulator = subprocess.check_output(['xcrun', 'simctl', 'create', 'IM B09 disposable authentication',
                        'com.apple.CoreSimulator.SimDeviceType.iPhone-17', 'com.apple.CoreSimulator.SimRuntime.iOS-26-2'],
                        env=environment, text=True).strip()
                    print('Created dedicated simulator ' + simulator, flush=True)
                    run(['xcrun', 'simctl', 'boot', simulator])
                    run(['xcrun', 'simctl', 'bootstatus', simulator, '-b'], timeout=180)
                    run(['xcrun', 'simctl', 'keychain', simulator, 'add-root-cert', str(private / 'ca.pem')])
                    with (output / 'app.log').open('w') as log:
                        test_selector = 'IMAppLocalAccountE2ETests/IMAppLocalAuthenticationTerminationUITests'
                        if not args.gateway:
                            test_selector += '/testRemoteDeviceRevocationReturnsToLoginAndSurvivesRelaunch'
                        additional_tests = ['-only-testing:IMAppLocalAccountE2ETests/IMAppInterruptedRegistrationUITests'] if args.interrupted_issuance else []
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
                        try:
                            app_result = ui.wait(timeout=900)
                        except BaseException:
                            if ui.poll() is None:
                                os.killpg(ui.pid, signal.SIGTERM)
                                try:
                                    ui.wait(timeout=10)
                                except subprocess.TimeoutExpired:
                                    os.killpg(ui.pid, signal.SIGKILL)
                                    ui.wait(timeout=5)
                            raise
                    app_summary = json.loads(subprocess.check_output(['xcrun', 'xcresulttool', 'get',
                        'test-results', 'summary', '--path', str(output / 'app.xcresult'), '--compact'],
                        env=environment, text=True))
                    (output / 'app-summary.json').write_text(json.dumps(app_summary, indent=2) + '\n')
                    if app_result != 0 or app_summary.get('passedTests') != (2 if args.gateway else 1) + int(args.interrupted_issuance) + int(args.legacy_app) or app_summary.get('failedTests') != 0:
                        raise RuntimeError('App UI authentication acceptance failed; inspect app.log and app.xcresult')
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
                expected_devices = 5 + (6 if args.gateway else 3 if args.app_ui else 0) + (2 if args.headless_app else 0) + (3 if args.current_logout else 0) + 2 * int(args.interrupted_issuance) + int(args.load_credentials) + 2 * int(args.legacy_client) + 2 * int(args.legacy_app)
                expected_revoked = 1 + (2 if args.gateway else 1 if args.app_ui else 0) + int(args.headless_app) + (3 if args.current_logout else 0) + int(args.interrupted_issuance) + int(args.load_credentials) + int(args.legacy_client) + int(args.legacy_app)
                assert persisted == '{}|{}|0|0|{}'.format(expected_devices, expected_revoked, expected_revoked), persisted
                terminal_refreshes = counts[('POST', '/v2/device-credentials/refresh', 401)]
                assert terminal_refreshes in [value + int(args.current_logout) for value in ([3, 4] if args.gateway else [3] if args.app_ui else [2])]
                assert counts[('POST', '/v2/device-credentials/refresh', 200)] == 1 + int(args.current_logout)
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
                if gateway is not None and gateway.poll() is None:
                    gateway.terminate()
                    try:
                        gateway.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        gateway.kill()
                        gateway.wait(timeout=5)
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
    with (output / 'cleanup.log').open('a') as cleanup:
        cleanup.write('Private temporary database, certificates and keys removed; existing stores and trust settings unchanged.\n')


if __name__ == '__main__':
    main()
