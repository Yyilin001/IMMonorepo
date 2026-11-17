#!/usr/bin/env python3
"""Run a paired Flutter UI scenario against the repository's disposable native backend."""
import argparse
import base64
import concurrent.futures
import json
import os
from pathlib import Path
import secrets
import shutil
import ssl
import subprocess
import tempfile
import time
import urllib.request
import uuid
from urllib.parse import urlparse

APP = Path(__file__).resolve().parents[1]


def new_id():
    return str(uuid.uuid4()).upper()


def accounts(config, origin):
    tls = ssl.create_default_context(cafile=config['caPath'])
    run = secrets.token_hex(5)
    password = secrets.token_urlsafe(24) + 'aA1!'

    def post(route, body, actor=None):
        headers = {'Content-Type': 'application/json'}
        if actor:
            headers.update({'Authorization': 'Bearer ' + actor['accessToken'], 'X-IM-Device-ID': actor['deviceID']})
        request = urllib.request.Request(origin + '/v2/' + route, data=json.dumps(body).encode(), headers=headers)
        with urllib.request.urlopen(request, context=tls, timeout=30) as response:
            return json.load(response)

    def register(role):
        name = f'flutter_{run}_{role}'
        device, operation = new_id(), new_id()
        registered = post('account-auth/password/register', {
            'accountHandle': name, 'publicHandle': name, 'displayName': name, 'password': password, 'deviceID': device})
        proof = base64.urlsafe_b64encode(secrets.token_bytes(32)).decode().rstrip('=')
        return post('device-credentials', {
            'accountAssertion': registered['accountAssertion'], 'deviceID': device, 'operationID': operation,
            'cancellation': {'deviceID': {'rawValue': device}, 'operationID': operation,
                             'proof': 'imv2-cancel-registration-v1.' + proof,
                             'issueBeforeMilliseconds': int((time.time() + 600) * 1000)}})

    sender, peer = register('a'), register('b')
    first, second = register('c'), register('d')

    def direct(actor, target):
        result = post('direct-room-operations/submit', {
            'actorUserID': {'rawValue': actor['userID']}, 'targetUserID': {'rawValue': target['userID']},
            'operationID': {'rawValue': new_id()}, 'firstSubmissionDeadlineMilliseconds': int((time.time() + 60) * 1000)}, actor)
        return result['receipt']['_0']['outcome']['opened']['roomID']['rawValue']

    return dict(IM_ACCOUNT_URL=origin, IM_GATEWAY_HOST='localhost', IM_GATEWAY_PORT=str(config['gatewayPort']),
                IM_E2E_ROOM=direct(sender, peer),
                IM_ANDROID_FORWARD_FIRST=direct(sender, first), IM_ANDROID_FORWARD_SECOND=direct(sender, second),
                IM_IOS_FORWARD_FIRST=direct(peer, first), IM_IOS_FORWARD_SECOND=direct(peer, second),
                IM_E2E_RUN=run, IM_E2E_PASSWORD=password)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--endpoints', type=Path, required=True)
    parser.add_argument('--android', required=True, help='arm64 emulator serial')
    parser.add_argument('--ios-type', default='com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro')
    parser.add_argument('--ios-runtime', default='com.apple.CoreSimulator.SimRuntime.iOS-18-5')
    args = parser.parse_args()
    config = json.loads(args.endpoints.read_text())
    origin = urlparse(config['httpsBaseURL'])
    if origin.scheme != 'https' or origin.hostname != 'localhost' or not origin.port or config['gatewayHost'] != 'localhost':
        parser.error('Expected an isolated localhost backend')
    adb = [shutil.which('adb') or str(Path.home() / 'Library/Android/sdk/platform-tools/adb'), '-s', args.android]
    with tempfile.TemporaryDirectory(prefix='im-flutter-test-') as folder:
        root = Path(folder)
        defines = root / 'defines.json'
        defines.write_text(json.dumps(accounts(config, origin.geturl())))
        (root / 'res/raw').mkdir(parents=True)
        (root / 'res/xml').mkdir()
        shutil.copyfile(config['caPath'], root / 'res/raw/test_ca.pem')
        (root / 'AndroidManifest.xml').write_text('<manifest xmlns:android="http://schemas.android.com/apk/res/android"><application android:networkSecurityConfig="@xml/test_trust"/></manifest>')
        (root / 'res/xml/test_trust.xml').write_text('<network-security-config><domain-config><domain>localhost</domain><trust-anchors><certificates src="@raw/test_ca"/></trust-anchors></domain-config></network-security-config>')
        simctl = ['xcrun', 'simctl']
        simulator = subprocess.check_output(simctl + ['create', 'IM Flutter E2E', args.ios_type, args.ios_runtime], text=True).strip()
        reverses = []
        try:
            subprocess.run(simctl + ['boot', simulator], check=True)
            subprocess.run(simctl + ['bootstatus', simulator, '-b'], check=True)
            subprocess.run(simctl + ['keychain', simulator, 'add-root-cert', config['caPath']], check=True)
            for port in (origin.port, config['gatewayPort']):
                local = f'tcp:{port}'
                subprocess.run(adb + ['reverse', '--no-rebind', local, local], check=True)
                reverses.append(local)

            def test(device):
                env = os.environ.copy()
                if device == args.android:
                    env['IM_FLUTTER_TEST_OVERLAY'] = str(root)
                command = ['flutter', 'test', '--no-pub', '--no-uninstall', '--reporter', 'expanded', '-d', device,
                           '--dart-define-from-file=' + str(defines), 'integration_test/shared_sdk_test.dart']
                subprocess.run(command, cwd=APP, env=env, check=True, timeout=540)
            with concurrent.futures.ThreadPoolExecutor(2) as pool:
                list(pool.map(test, [args.android, simulator]))
            print('PASS Flutter Android ↔ iOS: login, text, attachment upload/download/export byte equality in both directions, room message search, multi-room forward, reopen, sign out')
        finally:
            subprocess.run(adb + ['uninstall', 'com.xmtx.im.flutterexample.verification'], check=False, stdout=subprocess.DEVNULL)
            for local in reverses:
                subprocess.run(adb + ['reverse', '--remove', local], check=False)
            subprocess.run(simctl + ['shutdown', simulator], check=False)
            subprocess.run(simctl + ['delete', simulator], check=False)


if __name__ == '__main__':
    main()
