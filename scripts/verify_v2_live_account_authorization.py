#!/usr/bin/env python3
"""Disposable native account + PostgreSQL + verified HTTPS acceptance.

Only loopback sockets are opened. All keys, database files and TLS certificates
are newly generated beneath a private temporary directory and removed at exit.
No Docker, existing database or production secret is used. Optional App UI tests
trust the temporary CA only in a newly created simulator that is deleted at exit.
The HTTPS proxy supplies the same trusted edge headers as the local Caddy edge;
all registration, credential, device and rate-limit behavior is the real server.
Cross-Gateway mode uses authenticated Actor callbacks. The former broker-outage
scenario is retired; callback transport faults are checked by
IMV2/scripts/test_v2_realtime_actor_callback.py and realtime routing fence tests.
"""
import argparse
import base64
import binascii
import collections
import concurrent.futures
import http.client
import http.server
import hashlib
import json
import math
import resource
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
from imv2_tls_backpressure_proxy import TLSBackpressureProxy

ROOT = Path(__file__).resolve().parents[1]


class BoundedTLSHTTPServer(http.server.ThreadingHTTPServer):
    """Accept plain sockets promptly; perform TLS handshakes off the accept loop."""

    request_queue_size = 128
    maximum_workers = 64
    maximum_pending_requests = 128
    handshake_timeout_seconds = 10

    def __init__(self, address, handler, context):
        self.tls_context = context
        self.tls_failures = collections.Counter()
        self.tls_failures_lock = threading.Lock()
        self.request_slots = threading.BoundedSemaphore(self.maximum_pending_requests)
        self.workers = concurrent.futures.ThreadPoolExecutor(
            max_workers=self.maximum_workers, thread_name_prefix='owned-https-proxy')
        try:
            super().__init__(address, handler)
        except BaseException:
            self.workers.shutdown(wait=True, cancel_futures=True)
            raise

    def _record_tls_failure(self, category):
        with self.tls_failures_lock:
            self.tls_failures[category] += 1

    def tls_failure_summary(self):
        with self.tls_failures_lock:
            return dict(sorted(self.tls_failures.items()))

    def process_request(self, request, client_address):
        if not self.request_slots.acquire(blocking=False):
            self._record_tls_failure('PROXY_CAPACITY')
            self.shutdown_request(request)
            return
        try:
            future = self.workers.submit(self._process_tls_request, request, client_address)
            future.add_done_callback(lambda completed: self._close_cancelled_request(completed, request))
        except BaseException:
            self.request_slots.release()
            self.shutdown_request(request)
            raise

    def _close_cancelled_request(self, future, request):
        if future.cancelled():
            try:
                self.shutdown_request(request)
            finally:
                self.request_slots.release()

    def _process_tls_request(self, raw_request, client_address):
        request = raw_request
        try:
            raw_request.settimeout(self.handshake_timeout_seconds)
            request = self.tls_context.wrap_socket(
                raw_request, server_side=True, do_handshake_on_connect=False)
            request.do_handshake()
            request.settimeout(30)
        except ssl.SSLError as error:
            reason = error.reason
            category = reason if isinstance(reason, str) and re.fullmatch(r'[A-Z0-9_]{1,80}', reason) else 'OTHER_SSL_ERROR'
            self._record_tls_failure(category)
        except TimeoutError:
            self._record_tls_failure('HANDSHAKE_TIMEOUT')
        except (ConnectionError, OSError):
            self._record_tls_failure('HANDSHAKE_CONNECTION_ERROR')
        else:
            try:
                self.finish_request(request, client_address)
            except (ConnectionError, OSError):
                # A peer may close during an ordinary proxied HTTP response.
                pass
            except BaseException:
                self.handle_error(request, client_address)
        finally:
            try:
                self.shutdown_request(request)
            except Exception:
                pass
            finally:
                self.request_slots.release()

    def server_close(self):
        try:
            super().server_close()
        finally:
            # Cancelled queued tasks run the callback above; active tasks drain
            # through their own finally blocks before owned files are removed.
            self.workers.shutdown(wait=True, cancel_futures=True)


def has_canonical_revocation_binding(record):
    value = record.get('revocationCredential')
    if not isinstance(value, str) or not value.startswith('imv2-revoke-v1.'):
        return False
    encoded = value[len('imv2-revoke-v1.'):]
    if not re.fullmatch(r'[A-Za-z0-9_-]{43}', encoded):
        return False
    try:
        raw = base64.urlsafe_b64decode(encoded + '=')
    except (ValueError, binascii.Error):
        return False
    return len(raw) == 32 and base64.urlsafe_b64encode(raw).decode('ascii').rstrip('=') == encoded


def compose_policy_defaults(name):
    """Read checked-in policy literals/defaults, never inherited .env values."""
    text = (ROOT / 'IMV2/docker-compose.local-account.yml').read_text()
    block = re.split(r'\n  [a-z][\w-]*:\n', text.split('\n  ' + name + ':\n', 1)[1], maxsplit=1)[0]
    policy = {}
    for key, raw in re.findall(r'^      (IM_V2_[A-Z0-9_]+): (.+)$', block, re.M):
        if any(part in key for part in ('LOCAL_MEDIA', 'DATABASE_URL', 'SHARD_STORES_JSON',
                                       'SECRET', 'HMAC_KEY', 'ENVELOPE_KEY')):
            continue
        value = raw.strip('"\'')
        if '${' in value:
            default = re.fullmatch(r'\$\{[A-Z0-9_]+:-([^{}$]*)\}', value)
            if default is None:
                raise ValueError('unsupported compose policy interpolation for ' + key)
            value = default.group(1)
        policy[key] = value
    return policy


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def run_gateway_recovery_mode(count, private, output, environment, binary_directory, account_url, tls_port, additional_processes):
    """Dedicated nonempty disposable TLS recovery, not the complete F18 matrix."""
    # Rate settings bound pacing, not handshake/HTTP latency. These are explicit
    # stage allocations: the outer owned-process deadline also bounds a stalled
    # initial handshake, for which the driver currently has no independent limit.
    budget = {
        'connectionRampPacing': math.ceil(count / 200),
        'workloadRampPacing': math.ceil(count / 200),
        'setupLatencyAllowance': 60,
        'roomWarmup': 300, 'scenario': 10, 'scenarioDrain': 20,
        'postDrainHold': 10, 'socketClosePacing': math.ceil(count / 100) * 0.05,
        'reportAndCleanupAllowance': 20,
    }
    warmup_timeout = math.ceil(sum(budget.values()))
    burst_budget = dict(budget, offlineWrites=60, offlinePause=10, cursorObservation=60)
    burst_timeout = math.ceil(sum(burst_budget.values()))
    credential_margin = 50
    refresh_parallelism = 16
    canary_count = min(count, refresh_parallelism + 1)
    stages = []
    def owned(command, log_path, timeout, stage_environment=None):
        started = time.monotonic()
        process = None
        timed_out = False
        completed = False
        try:
            with log_path.open('w') as log:
                process = subprocess.Popen(command, cwd=ROOT, env=environment if stage_environment is None else stage_environment, stdout=log,
                                           stderr=subprocess.STDOUT, start_new_session=True)
                additional_processes.append(process)
                try:
                    code = process.wait(timeout=timeout)
                    if code:
                        raise RuntimeError('recovery stage failed; inspect ' + log_path.name)
                    completed = True
                except subprocess.TimeoutExpired:
                    timed_out = True
                    raise
        finally:
            if process is not None and not completed:
                # A failed shell may exit before its curl/xargs children. Own the
                # whole session, not just the leader, before deleting private files.
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    pass
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait(timeout=5)
            stage_result = {
                'stage': log_path.name, 'deadlineSeconds': timeout,
                'elapsedSeconds': time.monotonic() - started,
                'timedOut': timed_out, 'exitCode': process.returncode if process else None
            }
            if log_path.name.startswith('refresh-') and log_path.exists():
                # The refresh helper emits only fixed diagnostic labels and
                # numeric status codes. Never copy arbitrary private log lines.
                failures = collections.Counter()
                for line in log_path.read_text(errors='replace').splitlines():
                    matched = re.fullmatch(r'refresh failure stage=(http|request_parse|response_parse)(?: category=(invalid_input|invalid_shape))?(?: curl_exit=([0-9]+))?(?: http_status=([0-9]{3}))?', line)
                    if matched:
                        failures[matched.groups()] += 1
                stage_result['refreshFailureSummary'] = [
                    {'stage': stage, 'category': category, 'curlExit': int(curl_exit) if curl_exit else None,
                     'httpStatus': int(http_status) if http_status else None, 'count': amount}
                    for (stage, category, curl_exit, http_status), amount in sorted(failures.items(), key=lambda item: repr(item[0]))
                ]
            stages.append(stage_result)
            # Persist outcome evidence on both failure and success without the
            # invocation, private paths, credential records or raw server bodies.
            (output / 'gateway-recovery-stages.json').write_text(json.dumps(stages, indent=2) + '\n')

    def write_credentials(path, records):
        with path.open('w') as handle:
            os.chmod(path, 0o600)
            for record in records:
                handle.write(json.dumps(record, separators=(',', ':')) + '\n')

    def read_credentials(path, expected_count, allow_expired=False):
        records = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
        if len(records) != expected_count or len({r['deviceID'] for r in records}) != expected_count or len({r['userID'] for r in records}) != expected_count:
            raise RuntimeError('recovery credential count or identity uniqueness mismatch')
        for record in records:
            uuid.UUID(record['userID']); uuid.UUID(record['deviceID'])
            if not record.get('refreshCredential'):
                raise RuntimeError('recovery credential lacks original refresh authority')
            if not has_canonical_revocation_binding(record) or not isinstance(record.get('revocationCredentialExpiresAtMilliseconds'), int):
                raise RuntimeError('recovery credential lacks revocation binding')
            if not record['accessToken'] or (not allow_expired and int(record['accessTokenExpiresAtMilliseconds']) <= int(time.time() * 1000)):
                raise RuntimeError('recovery credential expired or empty')
        return records

    baseline_revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    workspace_dirty = bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True).strip())
    # Fingerprint only checked-in public build inputs, never environment/configuration
    # directories holding credentials, keys or this run's private corpus.
    source_paths = {Path(__file__).resolve(), ROOT / 'IMV2/sql/schema.sql'}
    for package in ('IMV2Server', 'IMV2Core', 'IMV2Compression'):
        directory = ROOT / package
        source_paths.update(directory / name for name in ('Package.swift', 'Package.resolved'))
        source_paths.update((directory / 'Sources').rglob('*.swift'))
    source_paths.update((ROOT / 'Protocol').rglob('*.proto'))
    source_paths.update(ROOT / 'IMV2/scripts' / name for name in (
        'prepare_v2_gateway_load_credentials.sh', 'refresh_v2_gateway_load_credentials.sh',
        'prepare_v2_registration_cancellation.py', 'prepare_v2_room_actor_configuration.py'))
    source_paths.add(ROOT / 'scripts/imv2_tls_backpressure_proxy.py')
    source_hashes = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                     for path in sorted(source_paths) if path.is_file()}
    (output / 'gateway-recovery-input-manifest.json').write_text(json.dumps({
        'baselineRevision': baseline_revision, 'workspaceDirty': workspace_dirty,
        'sourceSHA256': source_hashes, 'requestedConnections': count,
        'fileDescriptorSoftLimit': resource.getrlimit(resource.RLIMIT_NOFILE)[0],
        'databaseConnectionBudget': {'ownedPostgres': 160, 'accountPools': 16, 'gatewayPools': 72},
        'disposableAccountClientRateLimit': 100000,
        'credentialPreparationParallelism': 2,
        'productionPasswordHashMaximumConcurrent': 2,
        'credentialRefreshParallelism': refresh_parallelism,
        'directRoomHTTPMaximumConcurrent': 32,
        'directRoomHTTPMaximumQueued': 10_000,
        'credentialWireCanaryCount': canary_count,
        'credentialWireCanaryRefreshes': 2,
        'stageBudgetComponentsSeconds': {'warmup': budget, 'burst': burst_budget},
        'stageDeadlinesSeconds': {'warmup': warmup_timeout, 'burst': burst_timeout},
        'requiredCredentialLifetimeSeconds': {'warmup': warmup_timeout + credential_margin, 'burst': burst_timeout + credential_margin},
        'fullF18Passed': False
    }, indent=2) + '\n')
    ca = private / 'ca.pem'
    def register_batch(batch, ordinal):
        path = private / ('recovery-registration-' + str(ordinal) + '.jsonl')
        owned(['bash', str(ROOT / 'IMV2/scripts/prepare_v2_gateway_load_credentials.sh'),
               account_url, str(ca), str(batch), str(path)], private / ('registration-' + str(ordinal) + '.log'), 1800,
              stage_environment=dict(environment, IM_V2_LOAD_CREDENTIAL_PREPARE_PARALLELISM='2'))
        return read_credentials(path, batch, allow_expired=True)

    def refresh_records(current, input_path, label):
        write_credentials(input_path, current)
        refreshed = private / ('recovery-refreshed-' + label + '.jsonl')
        owned(['bash', str(ROOT / 'IMV2/scripts/refresh_v2_gateway_load_credentials.sh'),
               account_url, str(ca), str(input_path), str(refreshed)], private / ('refresh-' + label + '.log'), 600,
              stage_environment=dict(environment, IM_V2_LOAD_CREDENTIAL_REFRESH_PARALLELISM=str(refresh_parallelism)))
        updated = read_credentials(refreshed, len(current))
        if [(r['userID'], r['deviceID']) for r in updated] != [(r['userID'], r['deviceID']) for r in current]:
            raise RuntimeError('refresh changed recovery identity ordering')
        if any(old['refreshCredential'] == new['refreshCredential'] for old, new in zip(current, updated)):
            raise RuntimeError('refresh did not rotate recovery credential')
        # The response is minimal; retain registration cancellation and other
        # sidecars, while accepting every newly bound credential from refresh.
        merged = []
        for old, new in zip(current, updated):
            retained = dict(old)
            retained.update(new)
            merged.append(retained)
        write_credentials(input_path, merged)
        return merged

    # Exercise a complete refresh batch and its next batch before spending time
    # registering the remaining corpus. These identities count toward the target.
    records = register_batch(canary_count, 0)
    canary_path = private / 'recovery-wire-canary.jsonl'
    for ordinal in range(2):
        records = refresh_records(records, canary_path, 'canary-' + str(ordinal))
    remaining = count - canary_count
    ordinal = 1
    while remaining:
        batch = min(5000, remaining)
        records.extend(register_batch(batch, ordinal))
        remaining -= batch
        ordinal += 1
    credentials = private / 'recovery-credentials.jsonl'
    write_credentials(credentials, records)
    records = read_credentials(credentials, count, allow_expired=True)

    def ensure_lifetime(required_seconds):
        nonlocal records
        if min(int(r['accessTokenExpiresAtMilliseconds']) for r in records) < int((time.time() + required_seconds) * 1000):
            records = refresh_records(records, credentials, 'full')
        if min(int(r['accessTokenExpiresAtMilliseconds']) for r in records) < int((time.time() + required_seconds) * 1000):
            raise RuntimeError('token lifetime cannot cover the bounded recovery stage')

    scenario = json.loads((ROOT / 'IMV2/load-scenarios/high-active-50000-uuid-connection-canary.json').read_text())
    scenario['name'] = 'disposable-local-nonempty-recovery'
    scenario['roomWarmupTimeoutSeconds'] = 300
    scenario['phases'][0]['durationSeconds'] = 10
    scenario_path = private / 'recovery-scenario.json'
    scenario_path.write_text(json.dumps(scenario))
    common = [str(binary_directory / 'IMV2GatewayLoadGenerator'), '--host', '127.0.0.1', '--port', str(tls_port),
              '--server-name', 'localhost', '--account-base-url', account_url, '--ca-path', str(ca),
              '--credentials', str(credentials), '--connections', str(count), '--ramp-per-second', '200',
              '--ramp-batch-size', str(min(count, 100)), '--event-loops', '4', '--targets-per-connection', '1',
              '--target-offset', '1', '--room-log-reads', '1', '--room-log-initial-cursor', 'tail',
              '--room-log-read-trigger', 'availability_hint', '--sync-reads', '1', '--messages-per-second', '0',
              '--recovery-burst-workers', str(count), '--scenario', str(scenario_path), '--revision', baseline_revision + ('+dirty' if workspace_dirty else '')]
    ensure_lifetime(warmup_timeout + credential_margin)
    warmup_path = output / 'gateway-warmup-report.json'
    owned(common + ['--report', str(warmup_path)], output / 'gateway-warmup.log', warmup_timeout)
    warmup = json.loads(warmup_path.read_text())
    if warmup.get('authenticated') != count or warmup.get('terminalError'):
        raise RuntimeError('not every warmup client authenticated')
    mappings = {}
    for cursor in warmup.get('roomCursorSnapshots', []):
        index = cursor['connectionIndex']
        if type(index) is not int or not 0 <= index < count or index in mappings:
            raise RuntimeError('warmup room mapping is duplicate or outside original credential corpus')
        mappings[index] = str(uuid.UUID(cursor['roomID']))
    if set(mappings) != set(range(count)):
        raise RuntimeError('warmup lacks an exact room mapping for every original device')
    for index, record in enumerate(records):
        record['targetRoomIDs'] = [mappings[index]]
    write_credentials(credentials, records)
    # Refuse insufficient real token lifetime before starting this whole stage.
    # No token TTL is extended and no identity/credential is replaced mid-burst.
    ensure_lifetime(burst_timeout + credential_margin)
    burst_path = output / 'gateway-recovery-report.json'
    owned(common + ['--report', str(burst_path), '--recovery-burst', '1', '--recovery-burst-workers', str(count),
          '--recovery-burst-max-attempts', '1', '--recovery-burst-offline-seconds', '10',
          '--recovery-burst-observe-seconds', '60',
          '--recovery-burst-offline-messages-per-room', '1',
          '--recovery-burst-offline-write-workers', '8',
          '--recovery-burst-offline-write-deadline-seconds', '60'], output / 'gateway-recovery.log', burst_timeout)
    report = json.loads(burst_path.read_text())
    burst = report.get('recoveryBurst') or {}
    room_ids = set(mappings.values())
    if report.get('terminalError') or any(burst.get(key) != count for key in (
            'requestedConnections', 'connectAuthenticated', 'expectedCursorRooms',
            'observedTargetRooms', 'roomsWithCursorBacklog', 'cursorTargetCompletedRooms')) or burst.get('cursorTargetUncompletedOrUnknownRooms') != 0:
        raise RuntimeError('nonempty recovery did not authenticate and converge every original subscription')
    if any(burst.get(key) != len(room_ids) for key in (
            'offlineInjectedRooms', 'offlineWritesRequested', 'offlineWritesAccepted')) or burst.get('offlineWritesFailed') != 0:
        raise RuntimeError('offline typed writes did not commit one message in every unique subscribed room')
    receipts = burst.get('offlineWriteReceipts') or []
    if len(receipts) != len(room_ids):
        raise RuntimeError('offline write receipt coverage is incomplete')
    injected = {}
    for receipt in receipts:
        room = str(uuid.UUID(receipt['roomID']))
        sequence = receipt.get('roomSequence')
        if room not in room_ids or room in injected or type(sequence) is not int or sequence <= 0:
            raise RuntimeError('offline write receipt mapping is invalid')
        injected[room] = sequence
    progress = burst.get('cursorProgress') or []
    seen = set()
    for cursor in progress:
        index = cursor.get('connectionIndex')
        room = str(uuid.UUID(cursor['roomID']))
        if type(index) is not int or index not in mappings or index in seen or mappings[index] != room:
            raise RuntimeError('cursor progress changed the original subscription mapping')
        seen.add(index)
        before, applied = cursor.get('beforeSequence'), cursor.get('appliedSequence')
        target, through = cursor.get('recoveryTarget'), cursor.get('injectedThrough')
        if any(type(value) is not int for value in (before, applied, target, through)) or not (0 <= before < through == injected[room] <= target <= applied) or cursor.get('remainingGap') != 0:
            raise RuntimeError('an original subscription did not prove its nonempty injected target was applied')
    if seen != set(range(count)):
        raise RuntimeError('cursor progress omitted an original subscription')
    starts = burst.get('firstAttemptStartMilliseconds') or []
    if len(starts) != count or any(type(value) not in (int, float) or not math.isfinite(value) or value < 0 for value in starts):
        raise RuntimeError('actual recovery start distribution is incomplete')
    (output / 'gateway-recovery-scope.json').write_text(json.dumps({
        'baselineRevision': baseline_revision, 'workspaceDirty': workspace_dirty, 'sourceSHA256': source_hashes,
        'requestedConnections': count, 'realRegistration': True, 'realTypedDirectRoomWarmup': True,
        'connectionRecoveryOnly': False, 'fullF18Passed': False,
        'backlogWasInjected': True, 'uniqueSubscribedRooms': len(room_ids),
        'roomsWithCursorBacklog': burst['roomsWithCursorBacklog'],
        'stageBudgetComponentsSeconds': {'warmup': budget, 'burst': burst_budget},
        'stageDeadlinesSeconds': {'warmup': warmup_timeout, 'burst': burst_timeout},
        'actualFirstAttemptStartMinimumMilliseconds': min(starts),
        'actualFirstAttemptStartMaximumMilliseconds': max(starts),
        'fileDescriptorSoftLimit': resource.getrlimit(resource.RLIMIT_NOFILE)[0],
        'databaseConnectionBudget': {'ownedPostgres': 160, 'accountPools': 16, 'gatewayPools': 72},
        'disposableAccountClientRateLimit': 100000,
        'scope': 'Local nonempty TLS reconnect/cursor recovery with actual typed HTTP offline writes; excludes App durable work, production deployment and the full F18 fault matrix.'
    }, indent=2) + '\n')


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
    parser.add_argument('--room-recovery-drop-tail', action='store_true', help='with nonempty scale, discard the last real TLS wake at the test consumer and verify periodic reconciliation')
    parser.add_argument('--room-recovery-scan-race', choices=['before-listener', 'directory', 'state'], help='commit through another Gateway at a selected recovery boundary')
    parser.add_argument('--headless-app', action='store_true', help='with --app-ui --gateway, also run real credential Push entry in an App host without constructing its root view')
    parser.add_argument('--current-logout', action='store_true', help='also verify current-device logout through real HTTPS and PostgreSQL')
    parser.add_argument('--interrupted-issuance', action='store_true', help='with --app-ui --current-logout, terminate the owned App after issuance and cancellation commit but before either response is forwarded')
    parser.add_argument('--load-credentials', action='store_true', help='exercise the actual load credential preparation script and cancel its issued session through the saved proof')
    parser.add_argument('--multi-gateway', action='store_true', help='with --private-hint or nonempty --room-recovery-scale, start a second authenticated Actor/TLS Gateway for cross-gateway recovery')
    parser.add_argument('--room-recovery-slow-tls', action='store_true', help='pause the owned opaque TLS relay and require real App backpressure closure and recovery')
    parser.add_argument('--room-recovery-membership-race', action='store_true', help='remove and rejoin a member while a real old room state response is delayed')
    parser.add_argument('--room-recovery-app-reconnect', action='store_true', help='verify foreground App reconnect after three owned relay disconnects')
    parser.add_argument('--gateway-recovery-connections', type=int, default=None,
                        help='exclusive disposable nonempty native TLS recovery, 2...10000 real registered clients; no App tests')
    args = parser.parse_args()
    if args.gateway_recovery_connections is not None:
        if not 2 <= args.gateway_recovery_connections <= 10000:
            parser.error('--gateway-recovery-connections must be 2...10000')
        if any((args.app_ui, args.gateway, args.private_hint, args.room_recovery_scale is not None,
                args.current_logout, args.interrupted_issuance, args.load_credentials, args.headless_app,
                args.multi_gateway, args.room_recovery_membership_race, args.room_recovery_slow_tls,
                args.room_recovery_app_reconnect, args.room_recovery_scan_race, args.room_recovery_drop_tail)):
            parser.error('gateway recovery mode is exclusive of App and authorization fault modes')
        required_descriptors = 2 * args.gateway_recovery_connections + 1024
        soft_limit, _ = resource.getrlimit(resource.RLIMIT_NOFILE)
        if soft_limit != resource.RLIM_INFINITY and soft_limit < required_descriptors:
            parser.error('gateway recovery requires an inherited file descriptor soft limit of at least ' + str(required_descriptors))
        args.gateway = True
    if args.room_recovery_membership_race and (not args.room_recovery_scale or not args.multi_gateway):
        parser.error('--room-recovery-membership-race requires nonempty scale and --multi-gateway')
    if sum(bool(flag) for flag in (args.room_recovery_membership_race, args.room_recovery_slow_tls,
                                  args.room_recovery_app_reconnect, args.room_recovery_scan_race,
                                  args.room_recovery_drop_tail)) > 1:
        parser.error('select exactly one room recovery fault scenario per run')
    if args.room_recovery_app_reconnect and (not args.room_recovery_scale or not args.multi_gateway):
        parser.error('--room-recovery-app-reconnect requires nonempty scale and --multi-gateway')
    if args.room_recovery_slow_tls and (not args.room_recovery_scale or not args.multi_gateway
                                      or args.room_recovery_scan_race or args.room_recovery_drop_tail):
        parser.error('--room-recovery-slow-tls requires nonempty scale, --multi-gateway and no other fault flag')
    if args.room_recovery_scan_race and (not args.room_recovery_scale or not args.multi_gateway
                                       or args.room_recovery_drop_tail):
        parser.error('--room-recovery-scan-race requires nonempty scale, --multi-gateway and no other fault flag')
    if args.room_recovery_drop_tail and not args.room_recovery_scale:
        parser.error('--room-recovery-drop-tail requires nonempty scale')
    if args.multi_gateway and not (args.private_hint or args.room_recovery_scale):
        parser.error('--multi-gateway requires --private-hint or a nonempty --room-recovery-scale')
    if args.gateway and not (args.app_ui or args.gateway_recovery_connections):
        parser.error('--gateway requires --app-ui')
    if args.private_hint and not (args.app_ui and args.gateway):
        parser.error('--private-hint requires --app-ui --gateway')
    if args.room_recovery_scale is not None and not (args.app_ui and args.gateway):
        parser.error('--room-recovery-scale requires --app-ui --gateway')
    if args.headless_app and not (args.app_ui and args.gateway):
        parser.error('--headless-app requires --app-ui --gateway')
    if args.interrupted_issuance and not (args.app_ui and args.current_logout):
        parser.error('--interrupted-issuance requires --app-ui --current-logout')
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    for tool in ['swift', 'initdb', 'pg_ctl', 'psql', 'createdb', 'openssl']:
        if not shutil.which(tool):
            raise RuntimeError('missing required tool: ' + tool)
    if args.gateway_recovery_connections:
        for tool in ['bash', 'curl', 'jq', 'uuidgen']:
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
                   if not k.startswith(('IM_V2_', 'IMV2_LIVE_ACCOUNT_', 'IMV2_ROOM_ACTOR_'))}
    with (output / 'build.log').open('w') as log:
        subprocess.run(['swift', 'build', '--disable-automatic-resolution', '--jobs', '4',
                        '--product', 'IMV2AccountServerApp'], cwd=ROOT / 'IMV2Server',
                       env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
        if args.gateway:
            subprocess.run(['swift', 'build', '--disable-automatic-resolution', '--jobs', '4',
                            '--product', 'IMV2ServerApp'], cwd=ROOT / 'IMV2Server', env=environment,
                           stdout=log, stderr=subprocess.STDOUT, check=True)
        if args.gateway_recovery_connections:
            subprocess.run(['swift', 'build', '--disable-automatic-resolution', '--jobs', '4',
                            '--product', 'IMV2GatewayLoadGenerator'], cwd=ROOT / 'IMV2Server', env=environment,
                           stdout=log, stderr=subprocess.STDOUT, check=True)
    print('Native account executable built from current sources.', flush=True)
    binary_directory = Path(subprocess.check_output(
        ['swift', 'build', '--disable-automatic-resolution', '--show-bin-path'],
        cwd=ROOT / 'IMV2Server', env=environment, text=True).strip())
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
        additional_logs = []
        gateway_samples = []
        remote_baselines = {}
        remote_proofs = {}
        scale_seeded = threading.Event()
        scale_resource_samples = []
        scale_auth = {'user': None, 'successfulRefreshes': 0}
        proxy = None
        proxy_thread = None
        simulator = None
        counts = collections.Counter()
        count_lock = threading.Lock()
        interruption_ready = {phase: threading.Event() for phase in ['issue', 'cancel']}
        interruption = dict(device=None, proof=None, issueTerminations=0, cancelTerminations=0, cancelReplays=0, proofMatched=True, failure=None)
        result = None
        app_result = None
        with (output / 'setup.log').open('w') as setup, (output / 'account.log').open('w') as account_log:
            try:
                def run(command, **kwargs):
                    return subprocess.run(command, stdout=setup, stderr=subprocess.STDOUT,
                                          env=environment, check=True, **kwargs)
                run(['initdb', '-D', str(data), '-U', 'postgres', '--auth=trust', '--no-locale', '--encoding=UTF8'])
                run(['pg_ctl', '-D', str(data), '-l', str(private / 'postgres.log'), '-o',
                     '-p {} -h 127.0.0.1 -k {} -c max_connections={}'.format(
                         db_port, private, 320 if args.multi_gateway else 160), 'start', '-w'])
                postgres_started = True
                run(['createdb', *database_arguments, 'im_live_account'])
                run(['psql', '-X', *database_arguments, '-d', 'im_live_account', '-v', 'ON_ERROR_STOP=1',
                     '-f', str(ROOT / 'IMV2/sql/schema.sql')])

                # Separate authenticated Actor identities share only this disposable
                # topology/CA. Each process receives its own signing key and listener.
                actor_configuration = [sys.executable,
                    str(ROOT / 'IMV2/scripts/prepare_v2_room_actor_configuration.py'),
                    '--output-dir', str(private / 'actors'),
                    '--host', 'gateway=localhost:{}'.format(free_port()),
                    '--caller', 'account=localhost:{}'.format(free_port()),
                    '--shards', 'rooms-primary', '--user-buckets', 'users-primary']
                if args.multi_gateway:
                    actor_configuration += ['--host', 'gateway-secondary=localhost:{}'.format(free_port())]
                run(actor_configuration)

                if args.private_hint or args.room_recovery_scale is not None or args.gateway_recovery_connections:
                    # The auth-only harness does not run the admission operator.
                    # Reserve a bounded lease solely in this disposable cluster
                    # so real room creation and sending exercise normal admission.
                    command_budget = 10000 if (args.room_recovery_slow_tls or args.gateway_recovery_connections) else 1000
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
                config = compose_policy_defaults('account')
                config.update(IMV2_ROOM_ACTOR_CONFIGURATION_FILE=str(private / 'actors/account/configuration.json'),
                              IM_V2_DATABASE_URL='postgres://postgres@127.0.0.1:{}/im_live_account'.format(db_port),
                              IM_V2_DIRECT_ROOM_SHARD_ID='rooms-primary', IM_V2_GROUP_ROOM_SHARD_ID='rooms-primary',
                              IM_V2_ACCOUNT_LISTEN_HOST='127.0.0.1', IM_V2_ACCOUNT_LISTEN_PORT=str(account_port))
                if args.gateway_recovery_connections:
                    config['IM_V2_ACCOUNT_CLIENT_RATE_LIMIT_MAX_REQUESTS'] = '100000'
                    config['IM_V2_MAX_COMMANDS_PER_WINDOW'] = str(command_budget)
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
                account = subprocess.Popen([str(binary_directory / 'IMV2AccountServerApp')],
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
                    gateway_config.update(compose_policy_defaults('gateway'))
                    primary_tls_port = free_port() if (args.room_recovery_slow_tls or args.room_recovery_app_reconnect or args.gateway_recovery_connections) else 7443
                    if args.gateway_recovery_connections:
                        gateway_config['IM_V2_MAX_COMMANDS_PER_WINDOW'] = str(command_budget)
                    if args.room_recovery_slow_tls:
                        gateway_config['IM_V2_MAX_COMMANDS_PER_WINDOW'] = str(command_budget)
                        # The paused peer cannot complete heartbeat requests.
                        # Isolate notification write backpressure from idle expiry
                        # within the bounded 600-second pressure phase.
                        gateway_config['IM_V2_IDLE_TIMEOUT_MS'] = '700000'
                    gateway_config.update(IMV2_ROOM_ACTOR_CONFIGURATION_FILE=str(private / 'actors/gateway/configuration.json'),
                        IM_V2_TLS_HOST='127.0.0.1', IM_V2_TLS_PORT=str(primary_tls_port),
                        IM_V2_TLS_CERTIFICATE_CHAIN_PATH=str(private / 'leaf.pem'),
                        IM_V2_TLS_PRIVATE_KEY_PATH=str(private / 'leaf.key'),
                        IM_V2_METRICS_HOST='127.0.0.1', IM_V2_METRICS_PORT=str(metrics_port),
                        IM_V2_METRICS_MINIMUM_REFRESH_INTERVAL_MS='4000')
                    gateway_config.update(IM_V2_GATEWAY_NODE_ID='gateway',
                        IM_V2_REALTIME_ROOM_TRANSPORT='actor',
                        IM_V2_GATEWAY_REPLICA_COUNT='2' if args.multi_gateway else '1')
                    gateway_log = (output / 'gateway.log').open('w')
                    gateway = subprocess.Popen([str(binary_directory / 'IMV2ServerApp')],
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
                    if args.multi_gateway:
                        secondary_port = free_port()
                        secondary_log = (output / 'gateway-secondary.log').open('w')
                        additional_logs.append(secondary_log)
                        secondary_config = dict(gateway_config,
                            IMV2_ROOM_ACTOR_CONFIGURATION_FILE=str(private / 'actors/gateway-secondary/configuration.json'),
                            IM_V2_GATEWAY_NODE_ID='gateway-secondary',
                            IM_V2_TLS_PORT=str(secondary_port), IM_V2_METRICS_PORT=str(free_port()))
                        secondary = subprocess.Popen([str(binary_directory / 'IMV2ServerApp')],
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
                        print('Second TLS Gateway and authenticated Actor callbacks ready.', flush=True)


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
                        INSERT INTO im_v2.room_owner_routes(room_id,room_shard_id,route_epoch,created_at,updated_at)
                        SELECT room_id,'rooms-primary',0,now(),now() FROM recovery_seed;
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
                        length = int(self.headers.get('Content-Length', '0'))
                        if not 0 <= length <= 65536:
                            self.send_error(413)
                            return
                        body = self.rfile.read(length)
                        parsed = None
                        if (args.interrupted_issuance or args.room_recovery_scale is not None
                                or self.path == '/v2/devices/remote-revocations/submit'):
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
                        if args.gateway and self.command == 'POST' and self.path == '/v2/devices/remote-revocations/submit':
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
                            if self.path == '/v2/devices/revocation-baseline' and response.status == 200:
                                observed = json.loads(payload)
                                def identifier(value):
                                    return value['rawValue'] if isinstance(value, dict) else value
                                observed_targets = list(map(identifier, observed['targetDeviceIDs']))
                                assert len(observed_targets) <= 256
                                assert observed_targets == sorted(observed_targets)
                                assert len(set(observed_targets)) == len(observed_targets)
                                assert identifier(observed['currentDeviceID']) not in observed_targets
                                assert 0 < observed['expiresAtMilliseconds'] - observed['issuedAtMilliseconds'] <= 120000
                                with count_lock:
                                    remote_baselines[observed['id'].lower()] = observed
                            if self.path == '/v2/devices/remote-revocations/submit' and response.status == 200:
                                # Validate the real frozen command against the baseline
                                # actually observed through this edge. Do not fetch a new
                                # baseline or create a replacement ID to recover its proof.
                                assert isinstance(parsed, dict)
                                command = parsed
                                baseline = command['baseline']
                                with count_lock:
                                    assert remote_baselines.get(baseline['id'].lower()) == baseline
                                assert baseline['issuedAtMilliseconds'] < command['firstSubmissionDeadlineMilliseconds'] <= baseline['expiresAtMilliseconds']
                                selection = command['selection']
                                targets = ([selection['device']['_0']] if 'device' in selection
                                           else baseline['targetDeviceIDs'])
                                assert targets and all(target in baseline['targetDeviceIDs'] for target in targets)
                                assert baseline['currentDeviceID'] not in targets
                                result = json.loads(payload)
                                proof = result['receipt']['_0']
                                expected_fingerprint = base64.b64encode(hashlib.sha256(
                                    b'IMV2.remote-device-revocation.command.v1\0' + json.dumps(command,
                                        sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).digest()).decode()
                                assert proof['actorUserID'] == baseline['actorUserID']
                                assert proof['currentDeviceID'] == baseline['currentDeviceID']
                                assert proof['operationID'].lower() == command['operationID'].lower()
                                assert proof['fingerprint'] == expected_fingerprint
                                assert proof['targetDeviceIDs'] == targets
                                assert proof['outcome'] == {'revoked': {}}
                                # Independent real upstream query after the server commit
                                # proves recovery of the original ID and fingerprint.
                                # It uses the same authenticated caller and no renewed
                                # management authorization; never manufacture a reply.
                                recovery_body = json.dumps({'command': command, 'action': 'query'}, separators=(',', ':')).encode()
                                recovery_headers = {key: value for key, value in headers.items() if key.lower() != 'content-length'}
                                recovery_headers['Content-Length'] = str(len(recovery_body))
                                recovery = http.client.HTTPConnection('127.0.0.1', account_port, timeout=15)
                                try:
                                    recovery.request('POST', '/v2/devices/remote-revocations/operations/recover', recovery_body, recovery_headers)
                                    recovered = recovery.getresponse()
                                    recovered_payload = recovered.read()
                                    assert recovered.status == 200
                                    assert json.loads(recovered_payload) == result
                                    with count_lock:
                                        counts[('POST', '/v2/devices/remote-revocations/operations/recover', recovered.status)] += 1
                                        previous = remote_proofs.get(command['operationID'].lower())
                                        assert previous is None or previous == proof
                                        remote_proofs[command['operationID'].lower()] = proof
                                finally:
                                    recovery.close()
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

                tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                tls.minimum_version = ssl.TLSVersion.TLSv1_2
                tls.load_cert_chain(str(private / 'leaf.pem'), str(private / 'leaf.key'))
                proxy = BoundedTLSHTTPServer(('127.0.0.1', 8443 if args.app_ui else 0), Proxy, tls)
                proxy_thread = threading.Thread(target=proxy.serve_forever, daemon=True)
                proxy_thread.start()
                test_environment = dict(environment, IMV2_LIVE_ACCOUNT_HTTPS_URL='https://localhost:{}'.format(proxy.server_port),
                                        IMV2_LIVE_ACCOUNT_CA_DER=str(private / 'ca.der'))
                if args.gateway_recovery_connections:
                    run_gateway_recovery_mode(args.gateway_recovery_connections, private, output, environment,
                        binary_directory, 'https://localhost:{}'.format(proxy.server_port), primary_tls_port, additional_processes)
                else:
                    if args.current_logout:
                        test_environment['IMV2_LIVE_CURRENT_LOGOUT'] = '1'
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
                        if app_result != 0 or app_summary.get('passedTests') != (2 if args.gateway else 1) + int(args.interrupted_issuance) + int(args.private_hint) + int(args.room_recovery_scale is not None) or app_summary.get('failedTests') != 0:
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
                            if args.room_recovery_scale > 0:
                                assert 'IMV2_TLS_ROOM_ONLINE_PASSED rooms=' + str(args.room_recovery_scale) in (output / 'app.log').read_text()
                        if args.private_hint:
                            assert 'IMV2_THREE_FOREGROUND_RECOVERY_CYCLES_PASSED' in (output / 'app.log').read_text()
                            assert 'IMV2_FOREGROUND_RECOVERY_COMPLETION_PASSED' in (output / 'app.log').read_text()
                        if args.multi_gateway:
                            if args.private_hint:
                                assert 'IMV2_CROSS_GATEWAY_RECOVERY_AND_ONLINE_WAKE_PASSED' in (output / 'app.log').read_text()
                                assert 'IMV2_CROSS_GATEWAY_TWO_DEVICES_AND_SINGLE_EXIT_PASSED' in (output / 'app.log').read_text()
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
                    expected_devices = 5 + (6 if args.gateway else 3 if args.app_ui else 0) + (2 if args.headless_app else 0) + (3 if args.current_logout else 0) + 2 * int(args.interrupted_issuance) + int(args.load_credentials) + 3 * int(args.private_hint) + int(args.private_hint and args.multi_gateway) + int(args.room_recovery_scale is not None) + int(args.room_recovery_membership_race) + int(args.room_recovery_app_reconnect)
                    expected_revoked = 1 + (2 if args.gateway else 1 if args.app_ui else 0) + int(args.headless_app) + (3 if args.current_logout else 0) + int(args.interrupted_issuance) + int(args.load_credentials)
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
                    expected_remote = 4 if args.headless_app else 3 if args.gateway else 2 if args.app_ui else 1
                    assert len(remote_proofs) == expected_remote
                    assert counts[('GET', '/v2/devices/revocation-baseline', 200)] >= expected_remote
                    assert counts[('POST', '/v2/devices/remote-revocations/submit', 200)] >= expected_remote
                    assert counts[('POST', '/v2/devices/remote-revocations/operations/recover', 200)] >= expected_remote
                    original_remote_rows = subprocess.check_output(['psql', '-X', '-A', '-t', *database_arguments,
                        '-d', 'im_live_account', '-v', 'ON_ERROR_STOP=1', '-c',
                        "SELECT count(*) FROM im_v2.remote_device_revocation_receipts WHERE receipt->'outcome' = '{\"revoked\":{}}'::jsonb"],
                        env=environment, text=True).strip()
                    assert int(original_remote_rows) == expected_remote
                    (output / 'remote-revocation.log').write_text(
                        'PASS observed bounded baseline; frozen original identity/fingerprint/exact targets; original query proof equals submit; permanent receipts: ' + original_remote_rows + '\n')
                    if args.current_logout:
                        assert counts[('POST', '/v2/device-credentials/cancel-registration', 204)] == 4 + 2 * int(args.interrupted_issuance) + int(args.load_credentials)
                        assert counts[('POST', '/v2/device-credentials/cancel-registration', 410)] == 1
                        assert counts[('POST', '/v2/device-credentials/cancel-registration', 400)] == 1
                        cancellations = subprocess.check_output(['psql', '-X', '-A', '-t', *database_arguments,
                            '-d', 'im_live_account', '-v', 'ON_ERROR_STOP=1', '-c',
                            'SELECT count(*), count(user_id), count(cancelled_at) FROM im_v2.device_registration_cancellations'], env=environment, text=True).strip()
                        assert cancellations == '{}|{}|{}'.format(expected_devices + 1, expected_devices, 2 + int(args.interrupted_issuance) + int(args.load_credentials)), cancellations
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
                            """WITH remote_targets AS (
                              SELECT (CASE jsonb_typeof(target) WHEN 'string' THEN target #>> '{}'
                                      ELSE target->>'rawValue' END)::uuid AS target_device_id
                              FROM im_v2.remote_device_revocation_receipts,
                                   LATERAL jsonb_array_elements(receipt->'targetDeviceIDs') AS target
                              WHERE receipt->'outcome' = '{"revoked":{}}'::jsonb
                            ), all_targets AS (
                              SELECT target_device_id FROM im_v2.device_session_operations
                              UNION SELECT target_device_id FROM remote_targets
                            ) SELECT
                              (SELECT count(*) FROM im_v2.device_session_operations) +
                              (SELECT count(*) FROM im_v2.remote_device_revocation_receipts WHERE receipt->'outcome' = '{"revoked":{}}'::jsonb),
                              (SELECT count(*) FROM all_targets),
                              (SELECT count(*) FROM im_v2.device_session_operations WHERE operation_kind <> 'revoke_device'),
                              (SELECT count(*) FROM all_targets t JOIN im_v2.auth_devices d ON d.device_id=t.target_device_id WHERE d.revoked_at IS NULL)"""], env=environment, text=True).strip()
                        total, targets, other_kinds, active_targets = map(int, operations.split('|'))
                        # The lost issuance uses its separate cancellation journal.
                        assert targets == expected_revoked - 1 - int(args.interrupted_issuance) - int(args.load_credentials), operations
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
                    print('PASS: selected real HTTPS account tests and persisted device/HTTP effects.', flush=True)
            finally:
                for ready in interruption_ready.values():
                    ready.set()
                if args.interrupted_issuance:
                    (output / 'interruption-summary.json').write_text(json.dumps({key: value for key, value in interruption.items() if key not in ['device', 'proof']}, indent=2) + '\n')
                if args.gateway:
                    (output / 'gateway-samples.json').write_text(json.dumps(gateway_samples, indent=2) + '\n')
                (output / 'http-summary.json').write_text(json.dumps({
                    'testExitCode': result, 'appExitCode': app_result,
                    'httpsProxyTLSFailures': proxy.tls_failure_summary() if proxy is not None else {},
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
