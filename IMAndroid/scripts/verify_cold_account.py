#!/usr/bin/env python3
"""Verify a real account upload across process death on an explicitly selected API 31 device.

Requires installed Debug/app-test APKs and a live isolated backend configured with
--resource-part-uploads. The device must already have no default network; HTTPS
and realtime use only this invocation's adb reverses. No device data is cleared,
network settings changed, or test TLS service added to the production manifest.
The original fixture process is killed only after its successful preparation.
"""
import argparse
import base64
import json
import re
import subprocess
import time
from pathlib import Path
from urllib.parse import urlparse
from verify_device import parse_results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--endpoints', type=Path, required=True)
    parser.add_argument('--run', required=True, help='A new 12-character lowercase hex fixture identifier')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--adb', default=str(Path.home() / 'Library/Android/sdk/platform-tools/adb'))
    args = parser.parse_args()
    if not re.fullmatch('[0-9a-f]{12}', args.run):
        parser.error('--run must be 12 lowercase hexadecimal characters')
    args.output.mkdir(parents=True, exist_ok=True)
    prefix = args.output / ('cold-account-' + args.run)
    if list(args.output.glob(prefix.name + '-*')):
        parser.error('This run already has artifacts; use its existing evidence or a new explicit run ID')
    cfg = json.loads(args.endpoints.read_text())
    adb = [args.adb, '-s', args.serial]
    package = 'com.xmtx.im.android'
    test_package = package + '.test'
    owned_ports = []
    metadata = None
    started_preparation = False
    summary = {'run': args.run, 'serial': args.serial, 'api': 31}

    def shell(*command, check=True):
        return subprocess.run(adb + ['shell', *command], text=True, capture_output=True, check=check, timeout=20)

    def phase(method, label):
        log = Path(str(prefix) + '-' + label + '.log')
        if log.exists():
            raise RuntimeError('Refusing to replace an existing phase result: ' + str(log))
        command = adb + ['shell', 'am', 'instrument', '-w', '-r', '-e', 'class',
            'com.xmtx.im.AppAccountColdProcessTests#' + method,
            '-e', 'coldAccount', 'true', '-e', 'coldRun', args.run,
            '-e', 'e2eURL', cfg['httpsBaseURL'], '-e', 'e2eTLSPort', str(cfg['gatewayPort']),
            '-e', 'e2eCA', base64.b64encode(Path(cfg['caPath']).read_bytes()).decode(),
            test_package + '/androidx.test.runner.AndroidJUnitRunner']
        started = time.monotonic()
        with log.open('w') as output:
            try:
                result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, timeout=180)
            except (subprocess.TimeoutExpired, KeyboardInterrupt):
                # End only this invocation's instrumented target before any cleanup instrumentation.
                shell('am', 'force-stop', package)
                raise
        report = parse_results(log.read_text())
        report['seconds'] = round(time.monotonic() - started, 3)
        log.with_suffix('.json').write_text(json.dumps(report, indent=2) + '\n')
        print(label, json.dumps({k: v for k, v in report.items() if k != 'results'}), flush=True)
        if result.returncode or not report['complete'] or report['passed'] != 1 or report['failures']:
            raise RuntimeError('Instrumentation phase failed: ' + str(log))
        return report

    def read_fixture():
        result = shell('run-as', package, 'cat', 'no_backup/account-cold-' + args.run + '.json', check=False)
        if result.returncode:
            return None
        value = json.loads(result.stdout)
        if value['run'] != args.run:
            raise RuntimeError('Fixture identity mismatch')
        return value

    def state(job):
        result = shell('cmd', 'jobscheduler', 'get-job-state', package, str(job), check=False)
        value = (result.stdout + result.stderr).strip()
        terminal = 'unknown' in value.lower() or 'could not find' in value.lower()
        if result.returncode and not terminal:
            raise RuntimeError('Cannot inspect the existing job: ' + value)
        return value, terminal

    try:
        assert shell('getprop', 'ro.build.version.sdk').stdout.strip() == '31'
        assert shell('getprop', 'sys.boot_completed').stdout.strip() == '1'
        if read_fixture() is not None:
            raise RuntimeError('Fixture already exists; do not overwrite a previous handoff')
        existing = subprocess.check_output(adb + ['reverse', '--list'], text=True, timeout=20)
        ports = [urlparse(cfg['httpsBaseURL']).port, cfg['gatewayPort']]
        for port in ports:
            if re.search(r'\btcp:' + str(port) + r'\b', existing):
                raise RuntimeError('A required reverse already exists; refusing to replace it')
        for port in ports:
            subprocess.run(adb + ['reverse', f'tcp:{port}', f'tcp:{port}'], capture_output=True, check=True, timeout=20)
            owned_ports.append(port)
        started_preparation = True
        phase('prepareRealAccountDelegationForProcessDeath', 'prepare')
        metadata = read_fixture()
        if metadata is None:
            raise RuntimeError('Preparation did not publish its durable mapping')
        old_pid = str(metadata['pid'])
        alive = shell('pidof', package, check=False).stdout.split()
        if old_pid in alive:
            # This is the exact process that just passed the preparation phase, not a
            # package force-stop (which would revoke scheduled execution semantics).
            shell('run-as', package, 'kill', '-9', old_pid)
        deadline = time.monotonic() + 15
        while old_pid in shell('pidof', package, check=False).stdout.split():
            if time.monotonic() >= deadline:
                raise RuntimeError('Original process is still present; do not start replacement work')
            time.sleep(.2)
        summary.update(prepared_pid=int(old_pid), prepared_process_observed_gone=True)
        current, terminal = state(metadata['job'])
        if not terminal and 'active' not in current.lower().split():
            forced = shell('cmd', 'jobscheduler', 'run', '-f', package, str(metadata['job'])).stdout
            if 'Running job' not in forced:
                raise RuntimeError('Existing job was not started: ' + forced)
        deadline = time.monotonic() + 45
        while not terminal:
            if time.monotonic() >= deadline:
                raise RuntimeError('Existing job is not terminal; no replacement job was scheduled')
            time.sleep(.2)
            current, terminal = state(metadata['job'])
        workers = shell('pidof', package, check=False).stdout.split()
        assert old_pid not in workers
        summary.update(job_terminal_state=current, worker_pids=[int(p) for p in workers])
        phase('coldAppRestoresCredentialsReconcilesUnknownSystemResultAndFinalizesOriginalUpload', 'verify')
        verified = shell('run-as', package, 'cat', 'no_backup/account-cold-' + args.run + '-verified.json')
        summary['app_result'] = json.loads(verified.stdout)
        summary['verified'] = True
    finally:
        try:
            # The cleanup test drains only this run's exact mapping before revoking its fixture credentials.
            if started_preparation:
                phase('cleanupColdAccountFixture', 'cleanup')
                summary['fixture_drained'] = True
        finally:
            for port in owned_ports:
                subprocess.run(adb + ['reverse', '--remove', f'tcp:{port}'], capture_output=True, timeout=20)
            Path(str(prefix) + '-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary), flush=True)


if __name__ == '__main__':
    main()
