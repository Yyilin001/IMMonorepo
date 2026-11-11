#!/usr/bin/env python3
"""Verify production JobService -> cold App publication on an explicitly selected API 31 device.

Install the Debug App built with -PimDebugTestCaFile=<isolated backend CA> and its
instrumentation APK first. Restore a normal Debug build after the test. No device
trust store, network setting, permission, or application data is cleared here.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import time
from urllib.parse import urlparse
import uuid
from verify_device import parse_results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--backend-config', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--stop-backend', action='store_true', help='Stop this owned isolated backend after cleanup.')
    parser.add_argument('--adb', default=shutil.which('adb') or str(Path.home() / 'Library/Android/sdk/platform-tools/adb'))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    config = json.loads(args.backend_config.read_text())
    endpoint = urlparse(config['httpsBaseURL'])
    if endpoint.scheme != 'https' or endpoint.hostname != 'localhost':
        parser.error('Only the controlled localhost HTTPS backend is supported')
    adb = [args.adb, '-s', args.serial]
    package = 'com.xmtx.im.android'
    run = uuid.uuid4().hex[:12]
    ports = [endpoint.port, config['gatewayPort']]
    metadata_path = f'no_backup/download-cold-{run}.json'
    common = ['-e', 'coldDownload', 'true', '-e', 'coldRun', run,
              '-e', 'e2eURL', config['httpsBaseURL'], '-e', 'e2eTLSPort', str(config['gatewayPort'])]

    def shell(*command):
        return subprocess.check_output(adb + ['shell', *command], text=True, timeout=20).strip()

    def phase(method, label):
        output = args.output / f'{label}.log'
        command = adb + ['shell', 'am', 'instrument', '-w', '-r', '-e', 'class',
                         'com.xmtx.im.AppDownloadColdProcessTests#' + method] + common + [
                         package + '.test/androidx.test.runner.AndroidJUnitRunner']
        started = time.monotonic()
        timed_out = False
        with output.open('w') as log:
            try:
                result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=180)
            except subprocess.TimeoutExpired:
                timed_out = True
                shell('am', 'force-stop', package)
            except KeyboardInterrupt:
                shell('am', 'force-stop', package)
                raise
        report = parse_results(output.read_text())
        report['seconds'] = round(time.monotonic() - started, 3)
        report['timedOut'] = timed_out
        output.with_suffix('.json').write_text(json.dumps(report, indent=2) + '\n')
        assert not timed_out and result.returncode == 0 and report['complete'] and report['passed'] == 1 and not report['failures'], output

    assert shell('getprop', 'ro.build.version.sdk') == '31'
    assert shell('getprop', 'sys.boot_completed') == '1'
    network = {key: shell('settings', 'get', 'global', key) for key in ('wifi_on', 'mobile_data')}
    assert network == {'wifi_on': '0', 'mobile_data': '0'}, 'Prepare on the owned offline fixture; settings are not changed by this script'
    reverses = subprocess.check_output(adb + ['reverse', '--list'], text=True, timeout=15)
    assert all(f'tcp:{port}' not in reverses for port in ports), 'Refusing to replace an existing reverse rule'
    created = []
    prepared = False
    try:
        for port in ports:
            subprocess.run(adb + ['reverse', f'tcp:{port}', f'tcp:{port}'], check=True, capture_output=True, timeout=15)
            created.append(port)
        prepared = True  # Cleanup also handles partially completed account preparation.
        phase('prepareReceivedAccountTaskForProcessDeath', 'prepare')
        metadata = json.loads(shell('run-as', package, 'cat', metadata_path))
        assert metadata['run'] == run
        old = str(metadata['pid'])
        alive = subprocess.run(adb + ['shell', 'pidof', package], capture_output=True, text=True, timeout=15).stdout.split()
        host_killed = old in alive
        if host_killed:
            command = subprocess.check_output(adb + ['shell', 'run-as', package, 'cat', f'/proc/{old}/cmdline'], timeout=15)
            assert command.split(b'\0')[0].decode() == package
            # The instrumentation runner may finish terminating this PID concurrently.
            subprocess.run(adb + ['shell', 'run-as', package, 'kill', '-9', old], capture_output=True, timeout=15)
        else:
            assert not alive, 'Unexpected replacement process before the native worker was requested'
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            alive = subprocess.run(adb + ['shell', 'pidof', package], capture_output=True, text=True, timeout=15).stdout.split()
            if old not in alive:
                break
            time.sleep(.1)
        assert old not in alive
        (args.output / 'process-boundary.json').write_text(json.dumps({
            'preparedPid': int(old), 'preparedProcessObservedGone': True,
            'hostKilledPreparedProcess': host_killed,
        }, indent=2) + '\n')
        job = str(metadata['job'])
        assert 'Running job' in shell('cmd', 'jobscheduler', 'run', '-f', package, job)
        worker = None
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            alive = subprocess.run(adb + ['shell', 'pidof', package], capture_output=True, text=True, timeout=15).stdout.split()
            if alive:
                assert len(alive) == 1 and alive[0] != old
                worker = int(alive[0]);break
            time.sleep(.1)
        assert worker is not None
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            result = subprocess.run(adb + ['shell', 'cmd', 'jobscheduler', 'get-job-state', package, job], capture_output=True, text=True, timeout=15)
            state = (result.stdout + result.stderr).strip()
            if 'unknown' in state.lower() or 'could not find' in state.lower():
                break
            if result.returncode:
                raise AssertionError(state)
            time.sleep(.2)
        else:
            raise AssertionError('Native job did not finish; cleanup will cancel and drain it')
        phase('coldAppPublishesNativeReceiptAndShowsCompletedDownloadInSharedNavigation', 'verify')
        verified = json.loads(shell('run-as', package, 'cat', f'no_backup/download-cold-{run}-verified.json'))
        assert verified['nativeStatus'] == 200 and verified['foregroundByteDownloads'] == 0 and verified['completed']
        for screen in ('tasks', 'detail'):
            data = subprocess.check_output(adb + ['exec-out', 'run-as', package, 'cat', f'files/download-cold-{run}-{screen}.png'], timeout=15)
            assert data.startswith(b'\x89PNG')
            (args.output / f'{screen}.png').write_bytes(data)
        report = dict(verified, run=run, serial=args.serial, api=31, preparedProcessObservedGone=True,
                      hostKilledPreparedProcess=host_killed, systemWorkerPid=worker, jobTerminalState=state, productionService=True,
                      debugTrust='explicit isolated-backend CA resource; device trust stores unchanged')
        (args.output / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report), flush=True)
    finally:
        try:
            if prepared:
                phase('cleanupColdDownloadFixture', 'cleanup')
        finally:
            for port in created:
                subprocess.run(adb + ['reverse', '--remove', f'tcp:{port}'], capture_output=True, timeout=15)
            if args.stop_backend:
                (args.backend_config.parent / 'stop').touch()


if __name__ == '__main__':
    main()
