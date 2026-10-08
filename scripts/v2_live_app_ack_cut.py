"""Run the real App lost-ACK test, gated by an independently observed COMMIT."""
import http.client
import json
import os
import re
import signal
import socket
import subprocess
import sys
import time
import uuid


def run_app_ack_cut(root, output, environment, database_arguments, simulator, gateway_a, gateway_b):
    def free_port():
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            return listener.getsockname()[1]

    ports = {gateway_a, gateway_b}
    def unique_port():
        while True:
            port = free_port()
            if port not in ports:
                ports.add(port)
                return port

    listen_port, control_port = unique_port(), unique_port()
    def control(path, body=None):
        connection = http.client.HTTPConnection('127.0.0.1', control_port, timeout=3)
        try:
            connection.request('POST' if body is not None else 'GET', path,
                json.dumps(body) if body is not None else None, {'Content-Type': 'application/json'})
            response = connection.getresponse()
            value = json.loads(response.read())
            if response.status != 200:
                raise RuntimeError('ACK-cut control rejected ' + path)
            return value
        finally:
            connection.close()

    def stop(process):
        if process is not None and process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)

    proxy, app = None, None
    with (output / 'ack-cut-proxy.log').open('w') as proxy_log, (output / 'ack-cut-app.log').open('w') as app_log:
        try:
            proxy = subprocess.Popen([sys.executable, str(root / 'IMV2/scripts/v2_app_tcp_ack_cut_proxy.py'),
                '--listen-port', str(listen_port), '--control-port', str(control_port),
                '--gateway-a', str(gateway_a), '--gateway-b', str(gateway_b)],
                env=environment, stdout=proxy_log, stderr=subprocess.STDOUT, start_new_session=True)
            deadline = time.monotonic() + 15
            while True:
                if proxy.poll() is not None:
                    raise RuntimeError('ACK-cut proxy exited during startup')
                try:
                    control('/status')
                    break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise RuntimeError('ACK-cut proxy startup deadline exceeded')
                    time.sleep(.05)
            app_environment = dict(environment)
            for key, value in {'IMV2_LOCAL_ACCOUNT_E2E': '1', 'IMV2_APP_ACK_CUT_E2E': '1',
                'IMV2_APP_ACK_CUT_PORT': str(listen_port), 'IMV2_APP_ACK_CUT_CONTROL_PORT': str(control_port),
                'IMV2_APP_ACK_CUT_RECEIVER_PORT': str(gateway_b)}.items():
                for prefix in ('TEST_RUNNER_', 'SIMCTL_CHILD_'):
                    app_environment[prefix + key] = value
            bundle = output / 'ack-cut-app.xcresult'
            app = subprocess.Popen(['xcodebuild', 'test', '-project', str(root / 'IMApp/IMApp.xcodeproj'),
                '-scheme', 'IMApp', '-configuration', 'Debug', '-destination', 'platform=iOS Simulator,id=' + simulator,
                '-disableAutomaticPackageResolution', '-collect-test-diagnostics', 'never',
                '-only-testing:IMAppTests/IMAppLocalAccountIntegrationTests/unexpectedTCPDisconnectReplaysDurableWorkAcrossGateway()',
                '-resultBundlePath', str(bundle)], cwd=root, env=app_environment,
                stdout=app_log, stderr=subprocess.STDOUT, start_new_session=True)
            deadline = time.monotonic() + 600
            fact = None
            while app.poll() is None:
                if time.monotonic() >= deadline:
                    raise RuntimeError('ACK-cut App acceptance deadline exceeded')
                status = control('/status')
                fixture = status['fixture']
                if fixture and status['held'] and not status['switched']:
                    account, room, message = (str(uuid.UUID(fixture[key])) for key in ('accountID', 'roomID', 'clientMessageID'))
                    digest = fixture['fingerprintHex']
                    if not re.fullmatch('[a-f0-9]{64}', digest) or fixture['fingerprintVersion'] != 1:
                        raise RuntimeError('invalid ACK-cut operation fingerprint')
                    # A separate PG session sees only committed rows. Validate
                    # both canonical message and its original successful result.
                    sql = ("SELECT c.message_id,c.room_sequence,c.timeline_sequence FROM im_v2.message_send_completions c "
                        "JOIN im_v2.messages m ON m.message_id=c.message_id AND m.room_id=c.room_id "
                        f"WHERE c.room_id='{room}'::uuid AND c.sender_user_id='{account}'::uuid "
                        f"AND c.client_message_id='{message}'::uuid AND c.operation_fingerprint=decode('{digest}','hex') "
                        "AND c.operation_resolved_at_ms IS NOT NULL")
                    observed = subprocess.check_output(['psql', '-X', '-A', '-t', *database_arguments,
                        '-d', 'im_live_account', '-v', 'ON_ERROR_STOP=1', '-c', sql],
                        env=environment, text=True, timeout=5).strip()
                    if observed:
                        rows = observed.splitlines()
                        if len(rows) != 1 or len(rows[0].split('|')) != 3:
                            raise RuntimeError('ACK-cut committed fact is not unique')
                        fact = {'fixture': fixture, 'committedMessage': rows[0], 'observedBeforeSwitch': True}
                        (output / 'ack-cut-commit-gate.json').write_text(json.dumps(fact, indent=2) + '\n')
                        control('/switch', {'nonce': fixture['nonce'], 'databaseFactConfirmed': True})
                time.sleep(.1)
            summary = json.loads(subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
                '--path', str(bundle), '--compact'], env=environment, text=True))
            (output / 'ack-cut-app-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
            status = control('/status')
            (output / 'ack-cut-proxy-summary.json').write_text(json.dumps(status, indent=2) + '\n')
            if app.returncode or summary.get('passedTests') != 1 or summary.get('skippedTests') != 0:
                raise RuntimeError('ACK-cut App test did not execute and pass; inspect ack-cut-app.log')
            if not fact or not status['switched'] or status['drained'] < 1 or status['closeFailures'] != 0:
                raise RuntimeError('ACK-cut fault or independently committed fact missing')
            if 'IMV2_APP_ACK_CUT_PROOF ' not in (output / 'ack-cut-app.log').read_text():
                raise RuntimeError('ACK-cut App identity/reconnect proof missing')
        finally:
            stop(app)
            stop(proxy)
