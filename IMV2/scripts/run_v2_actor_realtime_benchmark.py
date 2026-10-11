#!/usr/bin/env python3
"""Run a marked disposable PostgreSQL benchmark with one frozen direct-ring fixture.

The same algorithm binary uses a measurement-only wire45 reference adapter and
current-protocol candidate adapter; production endpoints retain their strict protocols.

This creates new databases only, starts only owned child processes, and retains
all logs/reports and databases by default. No build, shared-service restart or
system tuning is performed. Both revisions use the same Release load generator.
"""
import argparse
import base64
import ctypes
import hashlib
import importlib
import json
import os
import stat
from pathlib import Path
import platform
import resource
import re
import secrets
import shutil
import signal
import socket
import subprocess
import threading
import time
import uuid
import urllib.request


class LoaderFailureReportDrain:
    """Keep owned services alive for peer reports, without accepting a failed run."""

    def __init__(self, seconds):
        if not 1 <= seconds <= 600:
            raise ValueError('loader report drain must be between 1 and 600 seconds')
        self.seconds = seconds
        self.started = None
        self.failed_ordinals = set()
        self.timed_out = False

    def observe(self, codes, now):
        failed = {index for index, code in enumerate(codes) if code not in (None, 0)}
        if failed and self.started is None:
            self.started = now
        self.failed_ordinals.update(failed)
        self.timed_out = (self.started is not None and now >= self.started + self.seconds
                          and any(code is None for code in codes))
        return self.timed_out

    def evidence(self, reported_ordinals, expected):
        missing = sorted(set(range(expected)) - set(reported_ordinals))
        return dict(firstFailureObserved=self.started is not None,
                    failedLoaderOrdinals=sorted(self.failed_ordinals),
                    deadlineSeconds=self.seconds, timedOut=self.timed_out,
                    reportCount=expected-len(missing), missingReportOrdinals=missing,
                    allReportsPresent=not missing,
                    semantics='report collection only; any failed loader still fails quality')

ROOT = Path(__file__).resolve().parents[2]
NODES = 6
PARTS = 12

def current_candidate_wire_version():
    source = (ROOT / 'IMV2Server/Sources/IMV2ServerGateway/Generated/IMV2ProtocolVersion.swift').read_text()
    match = re.search(r'current: UInt32 = (\d+)', source)
    if match is None:
        raise ValueError('generated server protocol version is missing')
    return int(match.group(1))

CANDIDATE_WIRE_VERSION = current_candidate_wire_version()


def app_canary_enabled(args):
    return any(getattr(args, flag, False) for flag in
        ('app_outbox_canary', 'app_multi_device_canary', 'app_room_progress_canary'))


def app_canary_selection(args):
    choices = [('app_outbox_canary', 'v2_app_outbox_canary', 'app-outbox-canary.json'),
               ('app_multi_device_canary', 'v2_app_multi_device_canary', 'app-multi-device-canary.json'),
               ('app_room_progress_canary', 'v2_app_room_progress_canary', 'app-room-progress-canary.json')]
    selected = [choice for choice in choices if getattr(args, choice[0], False)]
    if len(selected) != 1: raise ValueError('exactly one App canary mode is required')
    return selected[0]


def run_app_canary(args, directory, query, gateway_crash=None):
    flag, module, _ = app_canary_selection(args)
    runner = importlib.import_module(module).run_canary
    if flag == 'app_room_progress_canary':
        return runner(args, directory, query, gateway_crash=gateway_crash)
    return runner(args, directory) if flag == 'app_multi_device_canary' else runner(args, directory, query)


def preflight_app_canary(args, manifest):
    _, module, _ = app_canary_selection(args)
    importlib.import_module(module).preflight(args, manifest)


def settle_app_cleanup_result(result, *, postgres_passed):
    result['ownedPostgresCleanupPending'] = False
    result['ownedPostgresCleanupPassed'] = postgres_passed
    result['fixtureCleanupPassed'] = (result.get('appFixtureCleanupPassed') is True
        and result.get('ownedServicesCleanupPassed') is True and postgres_passed)
    result['qualityPassed'] = result.get('productQualityPassed') is True and result['fixtureCleanupPassed']


def sample_host_resources(previous=None):
    """Read host-wide pressure separately from the benchmark's owned processes."""
    sample = dict(time=time.time(), cpuCount=os.cpu_count(), loadAverage=list(os.getloadavg()))
    if platform.system() != 'Darwin':
        sample['status'] = 'unsupported_host_platform'
        return sample
    for name, command in (
        ('virtualMemory', ['vm_stat']),
        ('swapUsage', ['sysctl', '-n', 'vm.swapusage']),
        ('memoryPressureLevel', ['sysctl', '-n', 'kern.memorystatus_vm_pressure_level']),
    ):
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=2)
            sample[name] = dict(returnCode=result.returncode, output=result.stdout.strip())
        except (OSError, subprocess.TimeoutExpired) as error:
            sample[name] = dict(error=type(error).__name__)
    try:
        if not hasattr(sample_host_resources, '_mach'):
            mach = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
            mach.mach_host_self.restype = ctypes.c_uint
            mach.host_statistics.argtypes = [ctypes.c_uint, ctypes.c_int,
                                             ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint)]
            mach.host_statistics.restype = ctypes.c_int
            sample_host_resources._mach = (mach, mach.mach_host_self())
        mach, host = sample_host_resources._mach
        ticks, count = (ctypes.c_uint * 4)(), ctypes.c_uint(4)
        status = mach.host_statistics(host, 3, ticks, ctypes.byref(count))  # HOST_CPU_LOAD_INFO
        if status != 0 or count.value != 4:
            sample['cpuError'] = dict(returnCode=status, count=count.value)
        else:
            sample['cpuTicks'] = dict(zip(('user', 'system', 'idle', 'nice'), ticks))
            if previous and 'cpuTicks' in previous:
                deltas = {key: (value-previous['cpuTicks'][key]) % (1 << 32)
                          for key, value in sample['cpuTicks'].items()}
                total = sum(deltas.values())
                if total:
                    sample['cpuPercent'] = {key: 100*value/total for key, value in deltas.items()}
                    sample['cpuIntervalStartedAt'] = previous['time']
    except (OSError, AttributeError) as error:
        sample['cpuError'] = type(error).__name__
    return sample


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_command(args, log, env=None):
    with log.open('ab') as stream:
        subprocess.run(args, check=True, stdout=stream, stderr=stream, env=env)


def private_json(path, body):
    with path.open('x') as stream:
        os.fchmod(stream.fileno(), 0o600)
        json.dump(body, stream, indent=2)
        stream.write('\n')


def private_json_snapshot(path, body):
    """Atomically replace one progress snapshot in the owned evidence directory.

    Unique immutable artifacts continue to use private_json(create-only).
    This synchronous writer keeps at most one bounded same-directory temporary;
    it does not reset any caller deadline or promise crash-durable SQL evidence.
    """
    data = (json.dumps(body, indent=2) + '\n').encode('utf-8')
    if len(data) > 32 * 1024 * 1024:
        raise RuntimeError('snapshot_size_bound')
    if path.is_symlink():
        raise RuntimeError('snapshot_target_invalid')
    if path.exists():
        info = path.stat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise RuntimeError('snapshot_target_invalid')
    temporary = path.with_name(path.name + '.snapshot.tmp')
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, 'wb') as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(data)
            stream.flush()
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def verify_fixture(path):
    manifest = json.loads((path/'manifest.json').read_text())
    if manifest['topology'] != 'direct-ring' or manifest['targetsPerConnection'] != 2:
        raise ValueError('requires the direct-ring fixture generator')
    for name, digest in manifest['filesSHA256'].items():
        if sha(path/name) != digest:
            raise ValueError(f'fixture hash mismatch: {name}')
    return manifest


def gateway_env(args, kind, database, index, actors, manifest):
    values = {}
    defaults_checkout = args.baseline_checkout or ROOT
    for line in (defaults_checkout/'IMV2Server/.env.example').read_text().splitlines():
        if line.startswith('IM_V2_') and '=' in line:
            key, value = line.split('=', 1)
            values[key] = value
    actor = actors/f'gateway-{index}'
    values.update(
        IM_V2_DATABASE_URL=f'postgresql://{args.pg_user}@{args.pg_host}:{args.pg_port}/{database}?sslmode=disable',
        IM_V2_TLS_HOST='127.0.0.1', IM_V2_TLS_PORT=str(args.gateway_port+index),
        IM_V2_TLS_CERTIFICATE_CHAIN_PATH=str(actor/'tls.pem'), IM_V2_TLS_PRIVATE_KEY_PATH=str(actor/'tls.key'),
        IM_V2_ACCESS_TOKEN_HMAC_KEY_BASE64=(args.fixture/'access-token-hmac-key.base64').read_text().strip(),
        IM_V2_GROUP_INVITE_TOKEN_HMAC_KEY_BASE64=base64.b64encode(bytes([7])*32).decode(),
        IM_V2_GATEWAY_NODE_ID=f'gateway-{index}', IM_V2_USER_SHARD_BUCKET=manifest['userBucket'],
        IM_V2_USER_SHARD_ROUTER_EPOCH='1', IM_V2_DIRECT_ROOM_SHARD_ID=manifest['shardID'],
        IM_V2_GROUP_ROOM_SHARD_ID=manifest['shardID'], IM_V2_CAPACITY_PROFILE_ID=manifest['capacityProfileID'],
        IM_V2_MAX_COMMANDS_PER_WINDOW=str(manifest['commandWindowLimit']), IM_V2_CONTENT_REVIEW_MODE='disabled',
        IM_V2_METRICS_HOST='127.0.0.1', IM_V2_METRICS_PORT=str(args.metrics_port+index),
        IM_V2_MAX_CONNECTIONS='20000', IM_V2_RATE_LIMIT_MAX_TRACKED_IDENTITIES='40000',
        IM_V2_FOREGROUND_WRITE_DATABASE_WORK_LIMIT='5', IM_V2_INTERACTIVE_READ_DATABASE_WORK_LIMIT='3',
        IM_V2_SYNC_DATABASE_WORK_LIMIT='3', IM_V2_DATABASE_EVENT_LOOP_THREADS='1',
        IM_V2_DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP='11', IM_V2_DATABASE_MAX_TOTAL_CONNECTIONS='100',
        IM_V2_DATABASE_WORKLOAD_POOL_ISOLATION_ENABLED='false',
        IM_V2_FOREGROUND_WRITE_DATABASE_WORK_MAX_QUEUED='1152', IM_V2_INTERACTIVE_READ_DATABASE_WORK_MAX_QUEUED='384',
        IM_V2_SYNC_DATABASE_WORK_MAX_QUEUED='1536', IM_V2_DATABASE_WORK_ADMISSION_TIMEOUT_MS='5000',
        IM_V2_LISTEN_BACKLOG='4096', IM_V2_ACCEPT_BATCH_SIZE='256', IM_V2_GATEWAY_REPLICA_COUNT=str(NODES),
        IMV2_ROOM_ACTOR_CONFIGURATION_FILE=str(actor/f'{kind}.json'),
        IM_V2_IDLE_TIMEOUT_MS='600000', IM_V2_LOG_LEVEL='notice' if app_canary_enabled(args) else 'warning')
    if kind == 'candidate':
        values['IM_V2_SEND_PATH_TRACE_MODE'] = getattr(args, 'candidate_send_path_trace_mode', 'sampled')
        if getattr(args, 'candidate_actor_binary_invocations', 'enabled') != 'enabled':
            raise ValueError('candidate Actor transport requires binary invocations')
        values['IM_V2_ACTOR_BINARY_INVOCATIONS_ENABLED'] = 'true'
        values['IM_V2_MESSAGE_WRITE_PREPARED_QUERIES_ENABLED'] = 'true' if getattr(args, 'candidate_message_write_prepared_queries', 'enabled') == 'enabled' else 'false'
        # Keep non-message workload roles fixed; the dedicated policy pool can vary independently.
        node_message_connections = getattr(args, 'candidate_message_write_connections', 4)
        loops = getattr(args, 'candidate_event_loop_threads', 1)
        message_connections = node_message_connections // loops
        values.update(IM_V2_DATABASE_POLICY_CONTROL_CONNECTIONS_PER_EVENT_LOOP=str(getattr(args, 'candidate_policy_control_connections', 4)),
                      IM_V2_DATABASE_EVENT_LOOP_THREADS=str(loops),
                      IM_V2_DATABASE_NON_MESSAGE_POOL_EVENT_LOOP_THREADS='1',
                      IM_V2_DATABASE_WORKLOAD_POOL_ISOLATION_ENABLED='true',
                      IM_V2_DATABASE_MESSAGE_WRITE_CONNECTIONS_PER_EVENT_LOOP=str(message_connections),
                      IM_V2_DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP=str(9 + message_connections),
                      IM_V2_DATABASE_FOREGROUND_CONNECTIONS_PER_EVENT_LOOP='4',
                      IM_V2_DATABASE_SYNC_CONNECTIONS_PER_EVENT_LOOP='1',
                      IM_V2_DATABASE_DELIVERY_CONNECTIONS_PER_EVENT_LOOP='1',
                      IM_V2_DATABASE_PROJECTION_CONNECTIONS_PER_EVENT_LOOP='2',
                      IM_V2_DATABASE_MAINTENANCE_CONNECTIONS_PER_EVENT_LOOP='1',
                      IM_V2_INTERACTIVE_READ_DATABASE_WORK_LIMIT='2',
                      IM_V2_SYNC_DATABASE_WORK_LIMIT='1',
                      IM_V2_USER_PROJECTION_CONCURRENCY='1')
    else:
        values.pop('IM_V2_DATABASE_MESSAGE_WRITE_CONNECTIONS_PER_EVENT_LOOP', None)
        values.update(IM_V2_DATABASE_FOREGROUND_CONNECTIONS_PER_EVENT_LOOP='4',
                      IM_V2_DATABASE_PROJECTION_CONNECTIONS_PER_EVENT_LOOP='1')
    if kind == 'baseline':
        values.update(IM_V2_GROUP_WAKE_NATS_URL=f'nats://localhost:{args.nats_port}',
                      IM_V2_GROUP_WAKE_NATS_SUBJECT_PREFIX='imv2.actor.baseline',
                      IM_V2_GROUP_WAKE_ROUTING_KEY_BASE64=base64.b64encode(bytes([9])*32).decode())
    if app_canary_enabled(args):
        values.update(IM_V2_TLS_CERTIFICATE_CHAIN_PATH=str(args.app_tls_certificate),
                      IM_V2_TLS_PRIVATE_KEY_PATH=str(args.app_tls_key))
    inherited = {k:v for k,v in os.environ.items() if not k.startswith(('IM_V2_', 'IMV2_ROOM_'))}
    return dict(inherited, **values)



def account_env(args, kind, database, actors, manifest):
    # Match the checked-in native acceptance harness's literal Account policy.
    text=(ROOT/'IMV2/docker-compose.local-account.yml').read_text()
    block=re.split(r'\n  [a-z][\w-]*:\n',text.split('\n  account:\n',1)[1],maxsplit=1)[0]
    values=gateway_env(args,kind,database,0,actors,manifest)
    for key,raw in re.findall(r'^      (IM_V2_[A-Z0-9_]+): (.+)$',block,re.M):
        if any(part in key for part in ('LOCAL_MEDIA','DATABASE','SHARD','SECRET','HMAC_KEY','ENVELOPE_KEY','CAPACITY','MAX_COMMANDS')):
            continue
        values[key]=raw.strip('"\'')
    for key in ('CREDENTIAL_REPLAY_ENVELOPE_KEY','PUSH_ENDPOINT_ENVELOPE_KEY',
                'ACCOUNT_EDGE_AUTHORIZATION_SECRET','ACCOUNT_CLIENT_RATE_LIMIT_HMAC_KEY','ACCOUNT_ASSERTION_HMAC_KEY'):
        values['IM_V2_'+key+'_BASE64']=base64.b64encode(secrets.token_bytes(32)).decode()
    values.update(IM_V2_DATABASE_EVENT_LOOP_THREADS='1',
                  IM_V2_DATABASE_NON_MESSAGE_POOL_EVENT_LOOP_THREADS='1',
                  IMV2_ROOM_ACTOR_CONFIGURATION_FILE=str(actors/'account'/f'{kind}.json'),
                  IM_V2_DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP='8',
                  IM_V2_ACCOUNT_LISTEN_HOST='127.0.0.1',IM_V2_ACCOUNT_LISTEN_PORT=str(args.account_port),
                  IM_V2_ACCOUNT_CLIENT_RATE_LIMIT_MAX_REQUESTS='10000000',IM_V2_MAX_USER_SHARD_STORES='1')
    values.pop('IM_V2_DATABASE_MESSAGE_WRITE_CONNECTIONS_PER_EVENT_LOOP', None)
    values.update(IM_V2_DATABASE_WORKLOAD_POOL_ISOLATION_ENABLED='false',
                  IM_V2_DATABASE_FOREGROUND_CONNECTIONS_PER_EVENT_LOOP='4',
                  IM_V2_DATABASE_PROJECTION_CONNECTIONS_PER_EVENT_LOOP='1')
    database_url=values['IM_V2_DATABASE_URL']
    values['IM_V2_ROOM_SHARD_STORES_JSON']=json.dumps([dict(shard_id=manifest['shardID'],database_url=database_url,schema='im_v2')])
    values['IM_V2_USER_SHARD_STORES_JSON']=json.dumps([dict(bucket=manifest['userBucket'],database_url=database_url,schema='im_v2')])
    return values


def prepare(args, manifest):
    actors = args.output_dir/'actors6'
    command = ['python3',str(ROOT/'IMV2/scripts/prepare_v2_room_actor_configuration.py'),
               '--output-dir',str(actors),'--shards',manifest['shardID'],'--user-buckets',manifest['userBucket'],
               '--caller',f'account=localhost:{args.actor_port+NODES}']
    # Exercise the redesigned candidate through the real local benchmark
    # entrypoint. Baseline files below retain their original authorization.
    command += ['--policy-partitions', '16']
    for index in range(NODES):
        command += ['--host',f'gateway-{index}=localhost:{args.actor_port+index}']
    run_command(command, args.output_dir/'prepare.log')
    for name in [f'gateway-{index}' for index in range(NODES)]+['account']:
        node = actors/name
        config = json.loads((node/'configuration.json').read_text())
        private_json(node/'candidate.json',config)
        # Frozen binaries cannot decode new policy/realtime permissions.
        config.pop('policyPlacement', None)
        for service in config['services']:
            service['permissions'] = [x for x in service['permissions']
                                      if not x.startswith(('realtime', 'policy'))]
        private_json(node/'baseline.json',config)
    parts = [[] for _ in range(PARTS)]
    lines = (args.fixture/'credentials.jsonl').read_text().splitlines(True)
    if len(lines) != manifest['users']:
        raise ValueError('fixture credential cardinality mismatch')
    for index, line in enumerate(lines):
        parts[index%PARTS].append(line)
    for index, part in enumerate(parts):
        path = args.output_dir/f'part-{index}.jsonl'
        with path.open('x') as stream:
            os.fchmod(stream.fileno(),0o600)
            stream.write(''.join(part))
    return actors, [len(p) for p in parts]


def verify_candidate_authorization_mode(args, kind, query):
    mode = 'legacy' if kind == 'baseline' else getattr(args, 'candidate_authorization_mode', 'memory')
    if kind == 'baseline':
        return dict(mode=mode, memoryDeploymentChecked=False)
    if mode != 'memory':
        raise ValueError('candidate requires memory policy owners')
    observed = json.loads(query("SELECT json_build_object('activeDeployments',count(*),"
        "'revision',max(revision)) FROM im_v2.policy_owner_deployment WHERE deployment_id='active'"))
    if observed.get('activeDeployments') != 1 or observed.get('revision') != 1:
        raise RuntimeError('candidate_memory_policy_deployment_not_active')
    return dict(mode=mode, memoryDeploymentChecked=True, **observed)


def required_benchmark_binaries(args):
    if args.kind != 'candidate' and any(value is None for value in
        (args.baseline_checkout, args.baseline_binary, args.baseline_account_binary)):
        raise ValueError('baseline/both requires baseline checkout, gateway binary and account binary')
    binaries = [args.candidate_binary, args.candidate_account_binary, args.loader_binary]
    if args.kind != 'candidate':
        binaries += [args.baseline_binary, args.baseline_account_binary]
    return binaries


def seed(args, kind, database, directory, manifest):
    pg_env = dict(os.environ, PGHOST=args.pg_host, PGPORT=str(args.pg_port), PGUSER=args.pg_user)
    log = directory/'seed.log'
    # createdb fails if the name exists; never reuse or truncate an existing DB.
    run_command(['createdb', database],log,pg_env)
    checkout = args.baseline_checkout if kind == 'baseline' else ROOT
    psql = ['psql','-X','-v','ON_ERROR_STOP=1','-d',database]
    run_command(psql+['-f',str(checkout/'IMV2/sql/schema.sql')],log,pg_env)
    if kind == 'candidate':
        # Runtime's durable source identity/control capture is installed before
        # fixture writes. Baseline uses its frozen schema and identical inputs.
        run_command(['bash',str(checkout/'IMV2/scripts/install_v2_realtime_journal.sh'),
                     '--','-d',database],log,pg_env)
    fid = str(uuid.UUID(manifest['fixtureID']))
    run_command(psql+['-c',f"CREATE TABLE public.imv2_disposable_fixture_guard(fixture_id uuid PRIMARY KEY); INSERT INTO public.imv2_disposable_fixture_guard VALUES ('{fid}');"],log,pg_env)
    for name in ('common.sql','auth-control.sql','control.sql','owner.sql'):
        run_command(psql+['-f',str(args.fixture/name)],log,pg_env)
    run_command(psql+['-c','ANALYZE'],log,pg_env)


def connection_coverage_proof(report):
    if report.get('benchmarkWireVersion') != CANDIDATE_WIRE_VERSION or report.get('coverageProofRequired') is not True:
        return False
    snapshots = report.get('connectionCoverageSnapshots', [])
    requested = report.get('requestedConnections')
    if type(requested) is not int or requested <= 0 or len(snapshots) != requested:
        return False
    indices = [item.get('connectionIndex') for item in snapshots]
    physical_ids = [item.get('physicalConnectionID') for item in snapshots]
    if len(set(indices)) != requested or len(set(physical_ids)) != requested or not all(physical_ids):
        return False
    active_rooms = {item.get('connectionIndex'): item.get('roomID')
                    for item in report.get('roomCursorSnapshots', []) if item.get('activeForeground') is True}
    for item in snapshots:
        if item.get('wireVersion') != CANDIDATE_WIRE_VERSION or item.get('passed') is not True:
            return False
        scopes = item.get('requestedScopes', [])
        expected = {'account', 'room'} if item['connectionIndex'] in active_rooms else {'account'}
        if len(scopes) != len(expected) or {scope.get('scope') for scope in scopes} != expected:
            return False
        for scope in scopes:
            if (not scope.get('scopeID') or scope.get('state') != 'ready'
                    or type(scope.get('scopeGeneration')) is not int or scope['scopeGeneration'] <= 0
                    or type(scope.get('revision')) is not int or scope['revision'] <= 0
                    or type(scope.get('highWatermark')) is not int or scope['highWatermark'] < 0
                    or type(scope.get('appliedCursor')) is not int
                    or scope['appliedCursor'] < scope['highWatermark'] or scope.get('passed') is not True):
                return False
            if scope['scope'] == 'room' and scope['scopeID'] != active_rooms[item['connectionIndex']]:
                return False
    return report.get('coverageProofPassed') is True


def room_notification_loss_proof(reports, foreground):
    discarded = sum(r.get('roomNotificationsDiscarded', 0) for r in reports)
    signals = sum(r.get('roomProgressRecoverySignals', 0) for r in reports)
    enabled = bool(reports) and all(r.get('roomNotificationLossCanary') is True for r in reports)
    return dict(passed=enabled and discarded > 0 and signals > 0 and foreground.get('passed') is True,
                injectionEnabledOnEveryLoader=enabled, discardedNotificationFrames=discarded,
                heartbeatRecoverySignals=signals, finalForegroundCursorsPassed=foreground.get('passed') is True,
                clientPersistenceProven=False,
                scope='actual TCP notification discard and simulated Loader application; not App SQLite persistence')


def room_notification_loss_constraints(args, manifest):
    if not getattr(args, 'room_notification_loss_canary', False):
        return
    if (args.kind != 'candidate' or not args.allow_small_canary or manifest['users'] > 500
            or args.shared_postgres or args.allow_scaled_diagnostic
            or args.room_host_restart_canary is not None or args.realtime_host_restart_canary is not None
            or args.actor_partition_canary is not None or args.planned_reconnect_inflight_canary
            or app_canary_enabled(args) or args.preclose_recovery_witness):
        raise ValueError('notification loss requires an owned candidate-only small fixture and no other fault')


def summarize(reports, codes, requested, reconnect_canary=False, measurement_phase='rate-5000'):
    fields = ('authenticated','peakActive','failed','workloadFailed','messagesSent','messagesAcknowledged',
              'scenarioMessageQueueOverflowed','scenarioMessageQueueAbandoned','queuedScenarioMessagesAtEnd',
              'roomEventAvailabilityHintsReceived','roomEventRecordsReceived','roomEventLivePayloadsApplied',
              'roomEventLiveGapFramesDetected','roomEventLiveMissingSequences',
              'roomEventMetadataGapsObserved','roomEventMetadataMissingSequences','heartbeatMissed',
              'roomProgressReportsSent','roomProgressStatesAccepted','roomProgressStatesIgnored',
              'roomProgressRecoverySignals','roomNotificationsDiscarded')
    result = {key:sum(r.get(key,0) for r in reports) for key in fields}
    result.update(requestedConnections=requested, exitCodes=codes, reportCount=len(reports))
    result['requestedMessageTransport'] = 'tcp'
    result['messageTransport'] = 'tcp' if reports and all(r.get('messageTransport') == 'tcp' for r in reports) else 'unknown_or_mixed'
    result['messageRecoveryTransport'] = 'tcp_query'
    result['messageSendNegotiatedConnections'] = sum(r.get('messageSendNegotiatedConnections', 0) for r in reports)
    result['plannedReconnects'] = sum(r.get('plannedReconnects', 0) for r in reports)
    result['plannedReconnectInflightCanary'] = any(r.get('plannedReconnectInflightCanary', False) for r in reports)
    result['messageTransportEvents'] = {}
    for report in reports:
        for code, count in report.get('messageTransportEvents', {}).items():
            result['messageTransportEvents'][code] = result['messageTransportEvents'].get(code, 0) + count
    # Observed coverage frames are diagnostics, not proof that clients caught up.
    result['realtimeCoverageEvents'] = {}
    for report in reports:
        for code, count in report.get('realtimeCoverageEvents', {}).items():
            result['realtimeCoverageEvents'][code] = result['realtimeCoverageEvents'].get(code, 0) + count
    # Candidate coverage is a current physical-channel/scope witness, not a
    # Ready-frame count. Keep durable DB head/cursor validation independent.
    result['coverageProofRequired'] = any(r.get('benchmarkWireVersion') == CANDIDATE_WIRE_VERSION for r in reports)
    result['coverageProofConnections'] = sum(len(r.get('connectionCoverageSnapshots', [])) for r in reports)
    result['coverageProofPassed'] = not result['coverageProofRequired'] or (
        len(reports) == PARTS and all(connection_coverage_proof(report) for report in reports))
    result['messageTransportVerified'] = len(reports) == PARTS and all(
        r.get('messageTransport') == 'tcp' and r.get('messageRecoveryTransport') == 'tcp_query'
        and r.get('messageSendNegotiatedConnections', 0) == r.get('authenticated', -1)
        and r.get('messageTransportEvents', {}).get('WIRE_SUBMIT', 0) >= r.get('messagesSent', 0)
        and r.get('messageTransportEvents', {}).get('ACCEPTED', 0) == r.get('messagesAcknowledged', -1)
        for r in reports)

    result['measurementPhase'] = measurement_phase
    phases = [p for r in reports for p in r.get('scenarioPhases',[]) if p.get('name')==measurement_phase]
    result['acknowledgedMessagesPerSecond'] = sum(p['messagesAcknowledged']/p['observedDurationSeconds'] for p in phases if p['observedDurationSeconds']>0)
    # Reconnects may make authenticated cumulative counts exceed the population.
    result['capacityCompleted'] = len(reports)==PARTS and not any(codes) and result['peakActive']==requested and all(not r.get('terminalError') for r in reports)
    result['steadyStateCompleted'] = len(phases)==PARTS and all(p['completed'] for p in phases)
    if len(phases)==PARTS and all('startedAtUnixMilliseconds' in p and 'endedAtUnixMilliseconds' in p for p in phases):
        result['steadyStateCommonWindowSeconds']=max(0,min(p['endedAtUnixMilliseconds'] for p in phases)-max(p['startedAtUnixMilliseconds'] for p in phases))/1000
        result['steadyStateCommonWindowPassed']=result['steadyStateCommonWindowSeconds']>=.9*min(p['durationSeconds'] for p in phases)
    else:
        result['steadyStateCommonWindowSeconds']=0
        result['steadyStateCommonWindowPassed']=False
    result['drained'] = len(reports)==PARTS and all(r.get('scenarioDrain',{}).get('drained',False) for r in reports)
    result['reconnectCanaryRequested'] = reconnect_canary
    result['reconnectCanaryVerified'] = not reconnect_canary or (len(reports) == PARTS and all(
        r.get('plannedReconnectInflightCanary') is True
        and r.get('messageTransportEvents', {}).get('CANARY_RECEIPT_HELD') == 1
        and all(r.get('messageTransportEvents', {}).get(key, 0) >= 1
                for key in ('TRANSFERRED', 'RESTORED', 'RECOVERED_AFTER_RECONNECT', 'TRANSFERRED_QUEUE', 'RESTORED_QUEUE'))
        and all(r.get('messageTransportEvents', {}).get(key, 0) == 0
                for key in ('OUTCOME_UNKNOWN', 'OUTCOME_UNKNOWN_CONNECTION_CLOSED'))
        for r in reports))
    result['qualityPassed'] = result['coverageProofPassed'] and result['reconnectCanaryVerified'] and result['messageTransportVerified'] and result['capacityCompleted'] and result['steadyStateCompleted'] and result['steadyStateCommonWindowPassed'] and result['drained'] and result['failed']==0 and result['workloadFailed']==0 and result['scenarioMessageQueueOverflowed']==0 and result['scenarioMessageQueueAbandoned']==0 and result['queuedScenarioMessagesAtEnd']==0 and result['messagesAcknowledged']>0 and (result['roomEventRecordsReceived']+result['roomEventLivePayloadsApplied'])>0
    return result


def capture_foreground_wake_witness(args, database, directory, lagging_rooms):
    """Best-effort read-only evidence, independent of delivery acceptance."""
    try:
        selected = sorted({str(uuid.UUID(room)) for room in lagging_rooms})[:256]
    except (ValueError, TypeError, AttributeError):
        try:
            private_json(directory/'foreground-wake-witness.json',
                         dict(formatVersion=1, status='missing', errorCode='invalid_room_identity'))
        except OSError:
            pass
        return
    if not selected:
        return
    witness = dict(formatVersion=1, status='missing', selectedRooms=len(selected),
                   totalLaggingRooms=len(set(lagging_rooms)),
                   truncated=len(set(lagging_rooms)) > len(selected),
                   scope='at_most_256_unique_lagging_rooms',
                   snapshotRelationship='separate_statement_after_committed_heads; not_atomic_with_client_reports',
                   clientObservedBeforeUnixSeconds=time.time())
    # UUID parsing above is the sole source of SQL literals; no credential,
    # payload, SQL text or lease token is recorded in the witness.
    values = ','.join("('%s'::uuid)" % room for room in selected)
    query = f"""
        WITH selected(room_id) AS (VALUES {values}),
        observed AS MATERIALIZED (SELECT clock_timestamp() AS observed_at),
        evidence AS (
            SELECT selected.room_id, room.room_sequence AS committed_head,
                   CASE WHEN room.room_id IS NULL THEN 'room_missing'
                        WHEN wake.room_id IS NULL THEN 'no_dirty_head'
                        ELSE 'dirty_head_present' END AS status,
                   wake.pending, wake.room_sequence AS target_high_watermark,
                   wake.revision, wake.owner_epoch, wake.room_control_version
            FROM selected CROSS JOIN observed
            LEFT JOIN im_v2.rooms AS room ON room.room_id = selected.room_id
            LEFT JOIN im_v2.realtime_dirty_room_heads AS wake ON wake.room_id = selected.room_id
        )
        SELECT json_build_object(
            'databaseObservedAt', (SELECT observed_at FROM observed),
            'rooms', (SELECT json_agg(evidence ORDER BY room_id) FROM evidence))::text
        """
    try:
        pg_env = dict(os.environ, PGHOST=args.pg_host, PGPORT=str(args.pg_port), PGUSER=args.pg_user)
        pg_env['PGOPTIONS'] = (pg_env.get('PGOPTIONS', '') +
                               ' -c default_transaction_read_only=on -c statement_timeout=4000').strip()
        result = subprocess.run(['psql', '-X', '-A', '-t', '-v', 'ON_ERROR_STOP=1',
                                 '-d', database, '-c', query], env=pg_env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=5)
        if result.returncode:
            witness['errorCode'] = 'database_read_failed'
        else:
            data = json.loads(result.stdout)
            if not isinstance(data, dict) or len(data.get('rooms', [])) != len(selected):
                raise ValueError('witness cardinality')
            witness.update(data)
            witness['status'] = 'observed'
    except subprocess.TimeoutExpired:
        witness['errorCode'] = 'database_read_timeout'
    except (OSError, ValueError, TypeError):
        witness['errorCode'] = 'diagnostic_read_failed'
    witness['clientObservedAfterUnixSeconds'] = time.time()
    try:
        private_json(directory/'foreground-wake-witness.json', witness)
    except OSError:
        # Diagnostics must not replace the original quality result or failure.
        pass


def preclose_witness_request(directory, counts):
    """One bounded sample request; no protocol traffic or workload changes."""
    nonce = str(uuid.uuid4())
    requested_at = int(time.time()*1000)
    selections = [[(index*count)//min(32,count) for index in range(min(32,count))]
                  for count in counts]
    for part, indices in enumerate(selections):
        private_json_snapshot(directory/f'checkpoint-request-{part}.json',
            dict(nonce=nonce, requestedAtUnixMilliseconds=requested_at, connectionIndices=indices))
    return dict(nonce=nonce, requestedAtUnixMilliseconds=requested_at, selections=selections)


def preclose_closure_diagnostic_ok(directory):
    for part in range(PARTS):
        path = directory/f'load-{part}.log'
        if path.exists():
            with path.open('rb') as log:
                log.seek(max(0, path.stat().st_size-65536))
                if b'checkpoint closure diagnostic failed' in log.read(65536): return False
    return True


def capture_preclose_witness(args, database, directory, loaders, counts, request):
    """None means not yet sampled; final incomplete never affects quality."""
    output = directory/'preclose-recovery-witness.json'
    if output.exists(): return True
    if not all(process.poll() is None for process in loaders): return None
    if any((directory/f'checkpoint-response-{part}.json.closed').exists() for part in range(PARTS)): return None
    responses = []
    for part, (count, indices) in enumerate(zip(counts, request['selections'])):
        path = directory/f'checkpoint-response-{part}.json'
        if not path.exists(): return None
        if path.stat().st_size > 1024*1024: raise ValueError('checkpoint_response_budget')
        response = json.loads(path.read_text())
        if uuid.UUID(response['nonce']) != uuid.UUID(request['nonce']): return None
        slots = response.get('slots', [])
        if (response.get('diagnosticFailureCode') is not None
                or response.get('requestedAtUnixMilliseconds') != request['requestedAtUnixMilliseconds']
                or response.get('requestedConnections') != count
                or response.get('selectedConnectionIndices') != indices
                or [slot.get('connectionIndex') for slot in slots] != indices
                or response['samplingStartedAtUnixMilliseconds'] < request['requestedAtUnixMilliseconds']
                or response['samplingCompletedAtUnixMilliseconds'] < response['samplingStartedAtUnixMilliseconds']):
            raise ValueError('checkpoint_response_invalid')
        responses.append(response)
    selected_rooms = set()
    for part, response in enumerate(responses):
        credentials = [json.loads(line) for line in (args.output_dir/f'part-{part}.jsonl').read_text().splitlines()]
        for slot in response['slots']:
            foreground = str(uuid.UUID(credentials[slot['connectionIndex']]['targetRoomIDs'][0]))
            selected_rooms.add(foreground)
            slot['rooms'] = [room for room in slot.get('rooms', [])
                             if str(uuid.UUID(room['roomID'])) == foreground]
            slot['foregroundRoomID'] = foreground
    assert len(selected_rooms) <= 384
    values = ','.join("('%s'::uuid)" % room for room in sorted(selected_rooms))
    query = f"""
        WITH selected(room_id) AS (VALUES {values}),
        observed AS MATERIALIZED (SELECT clock_timestamp() AS observed_at)
        SELECT json_build_object('databaseObservedAt',(SELECT observed_at FROM observed),
          'rooms',(SELECT json_agg(json_build_object(
            'roomID',selected.room_id,'committedHead',room.room_sequence,
            'status',CASE WHEN room.room_id IS NULL THEN 'room_missing'
                          WHEN wake.room_id IS NULL THEN 'no_dirty_head' ELSE 'dirty_head_present' END,
            'pending',wake.pending,'targetHighWatermark',wake.room_sequence,
            'revision',wake.revision,'ownerEpoch',wake.owner_epoch,
            'roomControlVersion',wake.room_control_version)
            ORDER BY selected.room_id)
            FROM selected LEFT JOIN im_v2.rooms room USING(room_id)
            LEFT JOIN im_v2.realtime_dirty_room_heads wake USING(room_id)))::text
        """
    sampled_live = all(slot.get('state') == 'active' and slot.get('physicalConnectionID')
                       and slot.get('coverage') is not None and len(slot.get('rooms', [])) == 1
                       for response in responses for slot in response['slots'])
    # Credential parsing and checkpoint decoding can outlast the original
    # alive check. Recheck immediately before the only diagnostic SQL call.
    if not all(process.poll() is None for process in loaders):
        finish_preclose_witness(directory, 'loader_exited_before_database_snapshot')
        return True
    if any((directory/f'checkpoint-response-{part}.json.closed').exists() for part in range(PARTS)):
        finish_preclose_witness(directory, 'checkpoint_stopped_before_database_snapshot')
        return True
    if not preclose_closure_diagnostic_ok(directory):
        finish_preclose_witness(directory, 'checkpoint_close_marker_failed')
        return True
    started = time.time()
    data = json.loads(fault_read_query(args, database, query))
    if not isinstance(data, dict) or len(data.get('rooms', [])) != len(selected_rooms):
        raise ValueError('database_witness_cardinality')
    processes_live = all(process.poll() is None for process in loaders)
    workers_live = not any((directory/f'checkpoint-response-{part}.json.closed').exists() for part in range(PARTS))
    closure_diagnostic_ok = preclose_closure_diagnostic_ok(directory)
    still_live = processes_live and workers_live and closure_diagnostic_ok
    private_json(output, dict(formatVersion=1, status='observed' if still_live and sampled_live else 'incomplete',
        reason=('loader_exited_during_database_snapshot' if not processes_live
                else 'checkpoint_stopped_during_database_snapshot' if not workers_live
                else 'checkpoint_close_marker_failed' if not closure_diagnostic_ok
                else None if sampled_live else 'sampled_connection_not_live'),
        capacityEvidence=False, changesQuality=False, allLoadersLiveBeforeRead=True,
        allLoadersLiveAfterRead=processes_live, checkpointWorkersNotStoppedAfterRead=workers_live,
        checkpointClosureDiagnosticOK=closure_diagnostic_ok, databaseReadStartedAtUnixSeconds=started,
        databaseReadCompletedAtUnixSeconds=time.time(),
        snapshotRelationship='separate_client_and_database_snapshots_before_close; not_atomic',
        request=request, responses=responses, database=data))
    return True


def finish_preclose_witness(directory, reason):
    path = directory/'preclose-recovery-witness.json'
    if not path.exists():
        private_json(path, dict(formatVersion=1, status='incomplete', reason=reason,
                                capacityEvidence=False, changesQuality=False))


def verify_foreground_cursors(args, database, directory):
    """Compare each actual foreground viewer with independent committed room heads."""
    pg_env=dict(os.environ,PGHOST=args.pg_host,PGPORT=str(args.pg_port),PGUSER=args.pg_user)
    heads_path=directory/'committed-room-heads.txt'
    with heads_path.open('x') as output:
        subprocess.run(['psql','-X','-A','-t','-v','ON_ERROR_STOP=1','-d',database,'-c',
                        'SELECT room_id::text,room_sequence FROM im_v2.rooms ORDER BY room_id'],
                       env=pg_env,stdout=output,stderr=subprocess.PIPE,check=True)
    heads={room:int(sequence) for room,sequence in (line.split('|') for line in heads_path.read_text().splitlines())}
    checked=missing=behind=ahead=0
    lagging_rooms=set()
    for part in range(PARTS):
        report_path=directory/f'report-{part}.json'
        if not report_path.exists():continue
        report=json.loads(report_path.read_text())
        cursors={(c['connectionIndex'],c['roomID'].lower()):c['appliedRoomSequence'] for c in report.get('roomCursorSnapshots',[])}
        credentials=[json.loads(line) for line in (args.output_dir/f'part-{part}.jsonl').read_text().splitlines()]
        for index,credential in enumerate(credentials):
            room=credential['targetRoomIDs'][0].lower()
            applied=cursors.get((index,room));head=heads.get(room)
            checked+=1
            if applied is None or head is None:missing+=1
            elif applied<head:
                behind+=1
                lagging_rooms.add(room)
            elif applied>head:ahead+=1
    proof=dict(checkedForegroundViewers=checked,missing=missing,behindCommittedHead=behind,
               aheadOfCommittedHead=ahead,passed=checked==sum(1 for _ in (args.fixture/'credentials.jsonl').open()) and missing==0 and behind==0 and ahead==0)
    private_json(directory/'foreground-delivery-proof.json',proof)
    if lagging_rooms:
        capture_foreground_wake_witness(args, database, directory, lagging_rooms)
    return proof


def postgres_admission_statement_categories():
    """Leading static SQL markers survive pg_stat_activity query truncation."""
    return [
        (r'^[[:space:]]*/\*[[:space:]]*imv2_admission_fast_update[[:space:]]*\*/[[:space:]]*UPDATE([[:space:]]|$)', 'admission_fast_update'),
        (r'^[[:space:]]*/\*[[:space:]]*imv2_admission_lock_select[[:space:]]*\*/[[:space:]]*WITH([[:space:]]|$)', 'admission_lock_select'),
        (r'^[[:space:]]*/\*[[:space:]]*imv2_admission_gate_update[[:space:]]*\*/[[:space:]]*WITH([[:space:]]|$)', 'admission_gate_update'),
    ]


def postgres_statement_category_case(column):
    """Fixed output vocabulary; the sampler and SQL probe use this exact CASE."""
    if not re.fullmatch(r'[a-z_][a-z0-9_.]*', column):
        raise ValueError('invalid internal SQL column')
    operation = f"{column} ~* '^[[:space:]]*(SELECT|UPDATE|INSERT|DELETE|WITH)([[:space:]]|$)'"
    admission_cases = '\n'.join(
        f"   WHEN {column} ~* '{pattern}' THEN '{category}'"
        for pattern, category in postgres_admission_statement_categories())
    return rf"""CASE
{admission_cases}
   WHEN {operation} AND {column} ~* '(shard_admission_pools|room_admission)' THEN 'admission_credit'
   WHEN {operation} AND {column} ~* 'room_activation_leases' THEN 'room_activation_fence'
   WHEN {operation} AND {column} ~* 'realtime_partition_leases' THEN 'realtime_partition_control'
   WHEN {operation} AND {column} ~* 'user_live_presence_leases' THEN 'presence'
   WHEN {operation} AND {column} ~* '(messages|message_send_completions)' THEN 'message_append'
   WHEN {operation} AND {column} ~* '(FROM|UPDATE)[[:space:]]+[^[:space:]]*rooms([[:space:]]|$)' AND
        {column} ~* 'FOR[[:space:]]+(NO[[:space:]]+KEY[[:space:]]+UPDATE|UPDATE|SHARE|KEY[[:space:]]+SHARE)' THEN 'room_activation_fence'
   WHEN {column} ~* '^[[:space:]]*(BEGIN|COMMIT|END|ROLLBACK|ABORT|SET|START)([[:space:];]|$)' THEN 'transaction_control'
   WHEN {column} ~* '^[[:space:]]*SELECT[[:space:]]+' AND
        {column} ~* '(clock_timestamp|set_config)[[:space:]]*\(' THEN 'transaction_control'
   ELSE 'other' END"""


def postgres_statement_category_probe_sql():
    samples = [
        ('fast_update', '/* imv2_admission_fast_update */ UPDATE im_v2.shard_admission_pools AS pool SET command_window_used=pool.command_window_used+1 RETURNING pool.lease_id', 'admission_fast_update'),
        ('lock_select', '/* imv2_admission_lock_select */ WITH input AS MATERIALIZED (SELECT 1) SELECT pool.room_shard_id FROM im_v2.shard_admission_pools pool FOR NO KEY UPDATE OF pool', 'admission_lock_select'),
        ('gate_update', '/* imv2_admission_gate_update */ WITH input AS MATERIALIZED (SELECT 1), applied AS (UPDATE im_v2.shard_admission_pools SET command_window_used=1 RETURNING lease_id) SELECT * FROM applied', 'admission_gate_update'),
        ('embedded_marker', "SELECT '/* imv2_admission_fast_update */'", 'other'),
        ('wrong_marker_operation', '/* imv2_admission_fast_update */ SELECT 1', 'other'),
        ('update_admission', 'UPDATE im_v2.shard_admission_pools SET command_window_used=1', 'admission_credit'),
        ('update_presence', 'UPDATE im_v2.user_live_presence_leases SET expires_at=clock_timestamp()', 'presence'),
        ('begin', 'BEGIN', 'transaction_control'),
        ('commit', 'COMMIT', 'transaction_control'),
        ('set_config', "SELECT set_config('lock_timeout','1s',true)", 'transaction_control'),
        ('ordinary_select', 'SELECT 1', 'other'),
    ]
    quote = lambda value: "'" + value.replace("'", "''") + "'"
    values = ','.join('(' + ','.join(map(quote, sample)) + ')' for sample in samples)
    return f"""WITH samples(name, statement_text, expected) AS (VALUES {values}),
 classified AS (SELECT name, expected, {postgres_statement_category_case('statement_text')} AS actual FROM samples)
 SELECT json_agg(json_build_object('name',name,'expected',expected,'actual',actual,'passed',expected=actual)) FROM classified;"""


def postgres_hotspot_sample_sql():
    return f"""
WITH activity_snapshot AS MATERIALIZED (
 SELECT pid, datname, state, wait_event_type, wait_event, xact_start, query_start,
 {postgres_statement_category_case("query")} AS query_category
 FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid()
), lock_snapshot AS MATERIALIZED (
 SELECT lock.*, relation.relname, namespace.nspname
 FROM pg_locks lock
 JOIN activity_snapshot activity ON activity.pid = lock.pid
 LEFT JOIN pg_class relation ON relation.oid = lock.relation
      AND lock.database = (SELECT oid FROM pg_database WHERE datname = current_database())
 LEFT JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
), waiters AS MATERIALIZED (
 SELECT activity.*, pg_blocking_pids(activity.pid) AS blocker_pids
 FROM activity_snapshot activity WHERE activity.wait_event_type = 'Lock'
 ORDER BY activity.pid LIMIT 128
), lock_object_groups AS MATERIALIZED (
 SELECT owned.pid, json_agg(json_build_object(
   'locktype', owned.locktype, 'mode', owned.mode, 'schema', owned.nspname,
   'relation', owned.relname, 'transaction_id', owned.transactionid::text,
   'virtual_xid', owned.virtualxid, 'page', owned.page, 'tuple', owned.tuple)) AS objects
 FROM lock_snapshot owned WHERE owned.granted AND owned.locktype IN ('transactionid','virtualxid','tuple')
 GROUP BY owned.pid
), held_locks AS MATERIALIZED (
 SELECT lock.pid, lock.locktype, lock.mode, count(*) AS locks,
 CASE lock.relname
   WHEN 'room_activation_leases' THEN 'room_activation_fence'
   WHEN 'rooms' THEN 'room_activation_fence'
   WHEN 'shard_admission_pools' THEN 'admission_credit'
   WHEN 'room_admission' THEN 'admission_credit'
   WHEN 'messages' THEN 'message_append'
   WHEN 'message_send_completions' THEN 'message_append'
   WHEN 'realtime_partition_leases' THEN 'realtime_partition_control'
   WHEN 'user_live_presence_leases' THEN 'presence'
   ELSE 'other' END AS category
 FROM lock_snapshot lock
 WHERE lock.granted AND lock.database = (SELECT oid FROM pg_database WHERE datname = current_database())
       AND (lock.locktype = 'tuple' OR (lock.locktype = 'relation' AND
         lock.mode IN ('RowShareLock','RowExclusiveLock','ShareRowExclusiveLock','ExclusiveLock','AccessExclusiveLock')))
 GROUP BY lock.pid, lock.locktype, lock.mode, lock.relname
)
SELECT json_build_object(
 'activity', (SELECT coalesce(json_agg(a), '[]'::json) FROM (
   SELECT state, wait_event_type, count(*) AS backends
   FROM activity_snapshot
   WHERE datname = current_database() AND pid <> pg_backend_pid()
   GROUP BY state, wait_event_type ORDER BY state, wait_event_type) a),
 'locks', (SELECT coalesce(json_agg(l), '[]'::json) FROM (
   SELECT lock.locktype, lock.nspname AS schema, lock.relname AS relation,
          lock.mode, lock.granted, count(*) AS locks
   FROM lock_snapshot lock
   GROUP BY lock.locktype, lock.nspname, lock.relname, lock.mode, lock.granted
   ORDER BY lock.locktype, lock.nspname, lock.relname, lock.mode, lock.granted) l),
 'blocked_total', (SELECT count(*) FROM activity_snapshot WHERE wait_event_type = 'Lock'),
 'blocked_limit', 128,
 'blocked', (SELECT coalesce(json_agg(b), '[]'::json) FROM (
   SELECT activity.pid, activity.state, activity.wait_event_type, activity.wait_event, activity.query_category,
          extract(epoch FROM clock_timestamp() - activity.xact_start) AS transaction_age_seconds,
          extract(epoch FROM clock_timestamp() - activity.query_start) AS statement_age_seconds,
          activity.blocker_pids,
          (SELECT coalesce(json_agg(json_build_object(
              'locktype', requested.locktype, 'schema', requested.nspname, 'relation', requested.relname,
              'mode', requested.mode, 'transaction_id', requested.transactionid::text,
              'virtual_xid', requested.virtualxid, 'page', requested.page, 'tuple', requested.tuple,
              'wait_age_seconds', extract(epoch FROM clock_timestamp() - requested.waitstart))), '[]'::json)
           FROM lock_snapshot requested WHERE requested.pid = activity.pid AND NOT requested.granted) AS requested_locks,
          (SELECT coalesce(json_agg(json_build_object(
             'pid', blocker.pid, 'state', blocker.state, 'query_category', blocker.query_category,
             'held_locks', (SELECT coalesce(json_agg(json_build_object(
                  'category', held.category, 'locktype', held.locktype, 'mode', held.mode, 'locks', held.locks)), '[]'::json)
                  FROM held_locks held WHERE held.pid = blocker.pid),
             'lock_objects', coalesce((SELECT objects FROM lock_object_groups WHERE pid=blocker.pid), '[]'::json),
             'wait_event_type', blocker.wait_event_type, 'wait_event', blocker.wait_event,
             'transaction_age_seconds', extract(epoch FROM clock_timestamp() - blocker.xact_start))), '[]'::json)
           FROM activity_snapshot blocker WHERE blocker.pid = ANY(activity.blocker_pids)) AS blockers
   FROM waiters activity ORDER BY activity.pid) b),
 'tables', (SELECT coalesce(json_agg(t), '[]'::json) FROM (
   SELECT schemaname, relname, n_tup_ins, n_tup_upd, n_tup_del, n_tup_hot_upd,
          n_live_tup, n_dead_tup, seq_scan, idx_scan, autovacuum_count, autoanalyze_count
   FROM pg_stat_user_tables WHERE relname IN (
     'room_activation_leases','user_live_presence_leases','realtime_partition_leases',
     'rooms','room_admission','shard_admission_pools','messages','message_send_completions',
     'realtime_dirty_room_heads','user_sync_wake_outbox') ORDER BY schemaname,relname) t),
 'database', (SELECT row_to_json(d) FROM (
   SELECT numbackends, xact_commit, xact_rollback, blks_read, blks_hit,
          blk_read_time, blk_write_time, deadlocks, conflicts,
          temp_files, temp_bytes, stats_reset
   FROM pg_stat_database WHERE datname = current_database()) d),
 'wal', (SELECT row_to_json(w) FROM (
   SELECT wal_records, wal_fpi, wal_bytes, wal_buffers_full, wal_write,
          wal_sync, wal_write_time, wal_sync_time, stats_reset FROM pg_stat_wal) w));
"""


def sample_owned_postgres(args, database):
    """Only sample this runner's cluster; never retain SQL text or client inputs."""
    sampled_at = time.time()
    environment = dict(os.environ, PGHOST=args.pg_host, PGPORT=str(args.pg_port),
                       PGUSER=args.pg_user, PGCONNECT_TIMEOUT='2',
                       PGAPPNAME='imv2_benchmark_metrics', PGOPTIONS='-c statement_timeout=1500')
    statement = postgres_hotspot_sample_sql()
    sample = dict(time=sampled_at, postmasterPID=args.owned_postgres_pid,
                  samplerVersion='pg-hotspot-v2', queryCategoryVersion='admission-entry-v3',
                  walScope='owned_cluster', statisticsScope='current_database')
    statistics_started = time.monotonic()
    try:
        result = subprocess.run([str(args.pg_bin_directory/'psql'), '-X', '-At',
                                 '-v', 'ON_ERROR_STOP=1', '-d', database, '-c', statement],
                                env=environment, capture_output=True, text=True, timeout=3)
        if result.returncode:
            sample['statisticsError'] = f'psql exit {result.returncode}'
        else:
            sample.update(json.loads(result.stdout))
    except Exception as error:
        sample['statisticsError'] = type(error).__name__
    sample['statisticsElapsedSeconds'] = time.monotonic() - statistics_started
    sample['blockerAnalysis'] = analyze_postgres_blockers(sample)
    try:
        # Follow the exact owned postmaster's descendants, including WAL/checkpoint
        # processes. Numeric columns avoid postgres process titles or SQL text.
        rows = subprocess.run(['ps', '-axo', 'pid=,ppid=,rss=,time='],
                              capture_output=True, text=True, timeout=2).stdout.splitlines()
        parsed = [(int(fields[0]), int(fields[1]), line)
                  for line in rows if len(fields := line.split()) == 4]
        owned = {args.owned_postgres_pid}
        while True:
            children = {pid for pid, parent, _ in parsed if parent in owned}
            if children.issubset(owned):
                break
            owned.update(children)
        sample['processResources'] = '\n'.join(line for pid, _, line in parsed if pid in owned)
        sample['processResourceColumns'] = ['pid', 'ppid', 'rssKiB', 'cpuTime']
    except Exception as error:
        sample['processResourcesError'] = type(error).__name__
    return sample


def analyze_postgres_blockers(sample):
    """Describe observed objects/edges, never infer a relation's row holder."""
    waiters = sample.get('blocked', [])
    waiting = {item['pid'] for item in waiters}
    fan_in = {}
    edges = []
    unresolved = set()
    for waiter in waiters:
        blockers = {item['pid']: item for item in waiter.get('blockers', [])}
        for pid in waiter.get('blocker_pids', blockers.keys()):
            fan_in.setdefault(pid, set()).add(waiter['pid'])
            blocker = blockers.get(pid)
            if blocker is None:
                unresolved.add(pid)
            evidence = set()
            for requested in waiter.get('requested_locks', []):
                for owned in (blocker or {}).get('lock_objects', []):
                    if requested['locktype'] != owned['locktype']:
                        continue
                    if requested['locktype'] == 'transactionid' and requested.get('transaction_id') is not None:
                        if requested['transaction_id'] == owned.get('transaction_id') and owned['mode'] == 'ExclusiveLock':
                            evidence.add('matching_transaction_id')
                    elif requested['locktype'] == 'tuple' and requested.get('relation') is not None:
                        keys = ('schema', 'relation', 'page', 'tuple')
                        if all(requested.get(key) == owned.get(key) for key in keys):
                            evidence.add('matching_observed_tuple_object')
                    elif requested['locktype'] == 'virtualxid' and requested.get('virtual_xid') is not None:
                        if requested['virtual_xid'] == owned.get('virtual_xid'):
                            evidence.add('matching_virtual_transaction')
            edges.append(dict(waiterPID=waiter['pid'], blockerPID=pid,
                              evidence=sorted(evidence) or ['blocking_pid_only']))
    return dict(edges=edges, distinctBlockers=len(fan_in),
                maximumObservedFanIn=max(map(len, fan_in.values()), default=0),
                blockersNotInObservedWaiters=sorted(set(fan_in)-waiting),
                unresolvedBlockerPIDs=sorted(unresolved),
                truncated=sample.get('blocked_total', len(waiters)) > len(waiters),
                consistency='non_atomic_activity_lock_and_blocking_snapshots')


def derive_postgres_rates(current, previous):
    """Adjacent-sample deltas; cumulative counters are not message throughput."""
    if previous is None:
        return dict(status='first_sample')
    elapsed = current['time'] - previous['time']
    if elapsed <= 0:
        return dict(status='invalid_interval')
    rates = dict(status='sample_deltas', observedSeconds=elapsed)
    for section, fields in (('database', ('xact_commit', 'xact_rollback', 'blks_read', 'blks_hit')),
                            ('wal', ('wal_bytes', 'wal_records', 'wal_buffers_full'))):
        now = current.get(section, {}); before = previous.get(section, {})
        if not now or not before or now.get('stats_reset') != before.get('stats_reset'):
            rates[section] = dict(status='missing_or_reset')
            continue
        rates[section] = {name+'PerSecond': (now[name]-before[name])/elapsed for name in fields
                          if name in now and name in before and now[name] >= before[name]}
    before_tables = {(item['schemaname'], item['relname']): item for item in previous.get('tables', [])}
    table_rates = []
    for item in current.get('tables', []):
        before = before_tables.get((item['schemaname'], item['relname']))
        if before is None:
            continue
        row = dict(schema=item['schemaname'], relation=item['relname'])
        for field in ('n_tup_ins', 'n_tup_upd', 'n_tup_del', 'n_tup_hot_upd'):
            if item[field] >= before[field]:
                row[field+'PerSecond'] = (item[field]-before[field])/elapsed
        table_rates.append(row)
    rates['tables'] = table_rates
    def cpu_seconds(value):
        days, sep, rest = value.partition('-')
        base = int(days)*86400 if sep else 0
        components = list(map(float, (rest if sep else days).split(':')))
        return base + sum(part*60**index for index, part in enumerate(reversed(components)))
    def resources(sample):
        result = {}
        for line in sample.get('processResources', '').splitlines():
            pid, _, rss, cpu = line.split()
            result[int(pid)] = (int(rss), cpu_seconds(cpu))
        return result
    try:
        now = resources(current); before = resources(previous)
        cpu = sum(max(0, value[1]-before[pid][1]) for pid, value in now.items() if pid in before)
        rates['postgresCPUCoreEquivalents'] = cpu/elapsed
        rates['postgresRSSKiB'] = sum(value[0] for value in now.values())
        rates['cpuDeltaCoverage'] = 'only_pids_present_in_both_samples'
    except (ValueError, TypeError):
        rates['resourceCode'] = 'resource_decode_failed'
    return rates


def wait_for_database_client_drain(args, database):
    environment = dict(os.environ, PGHOST=args.pg_host, PGPORT=str(args.pg_port),
                       PGUSER=args.pg_user, PGCONNECT_TIMEOUT='2', PGOPTIONS='-c statement_timeout=1500')
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        result = subprocess.run([str(args.pg_bin_directory/'psql'), '-X', '-At', '-d', database, '-c',
            "SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() "
            "AND backend_type='client backend' AND pid<>pg_backend_pid()"],
            env=environment, capture_output=True, text=True, timeout=3)
        if result.returncode: return False
        if int(result.stdout.strip()) == 0: return True
        time.sleep(.25)
    return False


def realtime_topic_partition(room_id):
    # Identical version1 encoding to ActorContracts; typed UUID IDs are uppercase.
    logical_id = str(uuid.UUID(room_id)).upper()
    body = bytearray([1])
    for value in ('roomEvents', logical_id):
        encoded = value.encode('utf-8')
        body.extend(len(encoded).to_bytes(4, 'big')); body.extend(encoded)
    value = 14695981039346656037
    for byte in body:
        value = ((value ^ byte) * 1099511628211) & ((1 << 64) - 1)
    return value % 256


def trim_owned_app_journal(args, database):
    """Retention fault on the run-owned DB, preserving every consumer cursor."""
    if not re.fullmatch(r'imv2_va_actor_(candidate|baseline)_[0-9a-f]{12}', database):
        raise RuntimeError('app_journal_trim_database_not_owned')
    sql = """
    BEGIN;
    LOCK TABLE im_v2.realtime_journal_partitions, im_v2.realtime_journal_consumers
      IN SHARE ROW EXCLUSIVE MODE;
    CREATE TEMP TABLE app_trim_consumers_before ON COMMIT DROP AS
      SELECT to_jsonb(c) AS row_value FROM im_v2.realtime_journal_consumers c;
    CREATE TEMP TABLE app_trim_result ON COMMIT DROP AS
    WITH locked AS MATERIALIZED (
      SELECT partition_id, published_through, trimmed_through
      FROM im_v2.realtime_journal_partitions FOR UPDATE
    ), cuts AS (
      SELECT p.partition_id, least(p.published_through,
        coalesce((SELECT min(c.control_cursor) FROM im_v2.realtime_journal_consumers c
                  WHERE c.partition_id=p.partition_id),p.published_through)) AS cut
      FROM locked p
    ), advanced AS (
      UPDATE im_v2.realtime_journal_partitions p SET trimmed_through=c.cut
      FROM cuts c WHERE p.partition_id=c.partition_id AND c.cut>p.trimmed_through
      RETURNING p.partition_id,p.trimmed_through
    ), removed AS (
      DELETE FROM im_v2.realtime_change_journal j USING advanced p
      WHERE j.partition_id=p.partition_id AND j.sequence<=p.trimmed_through
      RETURNING j.partition_id
    ) SELECT (SELECT count(*) FROM advanced) AS advanced_partitions,
      (SELECT count(*) FROM removed) AS removed_entries;
    SELECT json_build_object('advancedPartitions',r.advanced_partitions,
      'removedEntries',r.removed_entries,
      'consumerCursorRowsChecked',(SELECT count(*) FROM app_trim_consumers_before),
      'consumerCursorsPreserved',NOT EXISTS (
        (SELECT row_value FROM app_trim_consumers_before
         EXCEPT ALL SELECT to_jsonb(c) FROM im_v2.realtime_journal_consumers c)
        UNION ALL
        (SELECT to_jsonb(c) FROM im_v2.realtime_journal_consumers c
         EXCEPT ALL SELECT row_value FROM app_trim_consumers_before)))
    FROM app_trim_result r;
    COMMIT;
    """
    environment = dict(os.environ, PGHOST=args.pg_host, PGPORT=str(args.pg_port),
        PGUSER=args.pg_user, PGCONNECT_TIMEOUT='2',
        PGOPTIONS='-c statement_timeout=3000 -c lock_timeout=1000')
    completed = subprocess.run([str(args.pg_bin_directory/'psql'), '-X', '-qAt',
        '-v', 'ON_ERROR_STOP=1', '-d', database, '-c', sql], env=environment,
        capture_output=True, text=True, timeout=5)
    if completed.returncode: raise RuntimeError('app_journal_trim_failed')
    evidence = json.loads(completed.stdout.strip())
    if evidence.get('advancedPartitions',0)<=0 or evidence.get('removedEntries',0)<=0:
        raise RuntimeError('app_journal_trim_no_history_removed')
    checked = evidence.get('consumerCursorRowsChecked')
    if type(checked) is not int or checked < 0:
        raise RuntimeError('app_journal_trim_no_consumer_cursors_checked')
    if evidence.get('consumerCursorsPreserved') is not True:
        raise RuntimeError('app_journal_trim_consumer_cursors_changed')
    return evidence


def fault_read_query(args, database, sql):
    # Only this bounded reader changes connection policy; writer environments do not.
    environment = dict(os.environ, PGHOST=args.pg_host, PGPORT=str(args.pg_port),
                       PGUSER=args.pg_user, PGCONNECT_TIMEOUT='2',
                       PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=1500')
    result = subprocess.run([str(args.pg_bin_directory/'psql'), '-X', '-At', '-v', 'ON_ERROR_STOP=1',
                             '-d', database, '-c', sql], env=environment,
                            capture_output=True, text=True, timeout=3)
    if result.returncode:
        raise RuntimeError('canary_read_failed')
    return result.stdout.strip()


def partition_lease_snapshot(args, database, partitions):
    if not partitions or len(partitions) > 256 or any(type(value) is not int or not 0 <= value < 256 for value in partitions):
        raise ValueError('invalid canary partition keys')
    keys = ','.join(str(value) for value in sorted(set(partitions)))
    # One read-only snapshot. No SQL, account credentials or payload is emitted.
    sql = f"""SELECT json_build_object('databaseNow',extract(epoch FROM clock_timestamp()),
        'leases',coalesce((SELECT json_agg(json_build_object(
          'partitionID',partition_id,'hostID',host_id,'serviceID',service_id,
          'incarnation',process_incarnation::text,'epoch',lease_epoch,'token',lease_token::text,
          'expiresAt',extract(epoch FROM expires_at)) ORDER BY partition_id)
          FROM im_v2.realtime_partition_leases WHERE partition_id IN ({keys})), '[]'::json))"""
    value = json.loads(fault_read_query(args, database, sql))
    if {row['partitionID'] for row in value['leases']} != set(partitions):
        raise RuntimeError('canary_partition_rows_missing')
    return value


def restart_canary_constraints(args, manifest, phases):
    if args.realtime_host_restart_canary is None:
        return
    if (args.kind != 'candidate' or not args.allow_small_canary or manifest['users'] > 500
            or args.planned_reconnect_inflight_canary or args.allow_scaled_diagnostic):
        raise ValueError('restart canary requires candidate-only explicit small fixture <=500, without other fault modes')
    if not 0 <= args.realtime_host_restart_canary < NODES:
        raise ValueError('restart target must be an owned Gateway index')
    if (not phases or phases[0].get('name') != 'natural-ttl-recovery'
            or phases[0].get('durationSeconds') != 60 or phases[0].get('messagesPerSecond', 0) != 0
            or phases[0].get('roomLogReadsPerSecond', 0) != 0 or phases[0].get('syncPullsPerSecond', 0) != 0
            or any(phase.get('reconnectPercentPerMinute', 0) != 0 for phase in phases)):
        raise ValueError('restart canary requires its quiet natural-TTL scenario and no client reconnects')


class RealtimeHostRestartCanary:
    """Owned process restart; observations never change lease or client deadlines."""
    def __init__(self, args, database, directory, foreground_partitions):
        self.args, self.database, self.directory = args, database, directory
        self.target = args.realtime_host_restart_canary
        self.survivor = (self.target + 1) % NODES
        self.foreground_partitions = foreground_partitions
        self.old_process = None
        self.initial = None
        self.last_old = None
        self.samples = []
        self.restart_process = None
        self.recovered = False
        self.deadline = None
        self.kill_time = None
        self.first_higher = None
        self.pre_metrics = None
        self.post_metrics = None
        self.kill_monotonic = None
        self.recovery_elapsed = None

    def permitted_exit(self, process):
        return process is self.old_process and process.poll() == -signal.SIGKILL

    def metrics(self):
        values = []
        for index in range(NODES):
            with urllib.request.urlopen(f'http://127.0.0.1:{self.args.metrics_port+index}/metrics', timeout=1) as response:
                body = response.read(4*1024*1024).decode('utf-8')
            scalars = {}
            for key in ('reachable_nodes', 'installed_partitions', 'cached_partitions', 'control_started_total',
                        'control_settled_total', 'publish_started_total', 'publish_settled_total', 'coverage_losses_total'):
                match = re.search(r'^im_v2_actor_realtime_'+key+r' ([0-9]+(?:\.[0-9]+)?)$', body, re.M)
                if match is None:
                    raise RuntimeError('canary_metrics_missing')
                scalars[key] = float(match.group(1))
            values.append(dict(node=index, **scalars))
        return values

    def persist(self):
        value = dict(formatVersion=1, state='recovered' if self.recovered else 'observing',
                     targetGateway=self.target, survivorGateway=self.survivor,
                     oldPID=self.old_process.pid if self.old_process else None,
                     newPID=self.restart_process.pid if self.restart_process else None,
                     confirmedSIGKILL=self.old_process is not None and self.old_process.returncode == -signal.SIGKILL,
                     killAtUnixSeconds=self.kill_time, initial=self.initial, lastOld=self.last_old,
                     firstHigher=self.first_higher, samples=self.samples, preKillAggregateMetrics=self.pre_metrics,
                     postRecoveryAggregateMetrics=self.post_metrics, recoveryElapsedSeconds=self.recovery_elapsed,
                     productionControllerUsed=True, acceleratedExpiry=False,
                     ttlOrRenewalConfigurationChanged=False, preKillPerConnectionReadyProven=False,
                     clientDisconnectRecoveryProven=False, clientConnectionsRemainOnSurvivor=True,
                     scope='natural PostgreSQL TTL, real production controller and restart; final current scope/cursor proof is independent')
        private_json_snapshot(self.directory/'realtime-restart-canary.json', value)

    def step(self, release_at, gateways, launch):
        now = time.time()
        if self.deadline is None:
            if now < release_at:
                return
            # Capture the original quiet phase end once in monotonic time.
            # Wall-clock changes cannot extend this wait after it was armed.
            self.deadline = time.monotonic() + max(0, release_at + 60 - now)
        if self.recovered:
            return
        if time.monotonic() >= self.deadline:
            self.persist(); raise TimeoutError('natural_ttl_restart_not_recovered_in_quiet_phase')
        if self.old_process is None:
            try:
                metrics = self.metrics()
            except (OSError, RuntimeError, ValueError):
                return  # bounded by the unchanged quiet-phase deadline
            if (any(row['reachable_nodes'] != NODES for row in metrics)
                    or sum(row['installed_partitions'] for row in metrics) != 256):
                return
            snapshot = partition_lease_snapshot(self.args, self.database, self.foreground_partitions)
            eligible = [row for row in snapshot['leases'] if row['hostID'] == f'gateway-{self.target}'
                        and row['epoch'] > 0 and row['expiresAt'] - snapshot['databaseNow'] >= 10]
            if not eligible:
                return
            # Require enough real recovery window before touching a process.
            if self.deadline - time.monotonic() < 40:
                raise TimeoutError('natural_ttl_restart_arm_window_exhausted')
            self.initial = eligible[0]
            self.pre_metrics = metrics
            process = gateways[self.target]
            if process.poll() is not None:
                raise RuntimeError('restart_target_exited_before_planned_kill')
            self.old_process = process
            self.kill_time = time.time(); self.kill_monotonic = time.monotonic()
            self.persist()
            process.kill()
            if process.wait(timeout=5) != -signal.SIGKILL:
                raise RuntimeError('restart_target_not_confirmed_sigkill')
            self.persist()
            post = partition_lease_snapshot(self.args, self.database, [self.initial['partitionID']])
            row = post['leases'][0]
            if (row['epoch'], row['token'], row['incarnation'], row['hostID'], row['serviceID']) != (
                    self.initial['epoch'], self.initial['token'], self.initial['incarnation'], self.initial['hostID'], self.initial['serviceID']):
                raise RuntimeError('restart_old_lease_changed_before_natural_expiry')
            self.last_old = row
            self.samples.append(post)
            self.restart_process = launch(self.target)
            gateways[self.target] = self.restart_process
            self.persist()
            return
        snapshot = partition_lease_snapshot(self.args, self.database, [self.initial['partitionID']])
        self.samples.append(snapshot)
        if len(self.samples) > 64:
            raise RuntimeError('restart_observation_bound_exhausted')
        row = snapshot['leases'][0]
        if row['epoch'] == self.initial['epoch']:
            if (row['token'], row['incarnation'], row['hostID'], row['serviceID']) != (
                    self.initial['token'], self.initial['incarnation'], self.initial['hostID'], self.initial['serviceID']):
                raise RuntimeError('restart_same_epoch_identity_changed')
            # A previously dispatched real renewal can settle after process exit;
            # retain its last observed expiry instead of pretending SIGKILL cancels SQL.
            self.last_old = row
        elif row['epoch'] > self.initial['epoch']:
            if snapshot['databaseNow'] < self.last_old['expiresAt']:
                raise RuntimeError('restart_claim_preceded_observed_natural_expiry')
            if row['incarnation'] == self.initial['incarnation'] or row['token'] == self.initial['token']:
                raise RuntimeError('restart_higher_epoch_reused_old_identity')
            if self.first_higher is None:
                self.first_higher = snapshot
            if row['hostID'] == f'gateway-{self.target}' and row['expiresAt'] > snapshot['databaseNow']:
                try:
                    metrics = self.metrics()
                except (OSError, RuntimeError, ValueError):
                    metrics = []
                if (len(metrics) == NODES and all(value['reachable_nodes'] == NODES for value in metrics)
                        and sum(value['installed_partitions'] for value in metrics) == 256
                        and metrics[self.target]['installed_partitions'] > 0):
                    self.post_metrics = metrics
                    self.recovery_elapsed = time.monotonic() - self.kill_monotonic
                    self.recovered = True
        else:
            raise RuntimeError('restart_lease_epoch_regressed')
        self.persist()


def partition_canary_constraints(args, manifest, phases):
    if args.actor_partition_canary is None:
        return
    if (args.kind != 'candidate' or not args.allow_small_canary or manifest['users'] > 500
            or args.planned_reconnect_inflight_canary or args.realtime_host_restart_canary is not None
            or args.allow_scaled_diagnostic or args.shared_postgres):
        raise ValueError('partition canary requires candidate-only owned PG, explicit <=500 fixture, no other fault mode')
    if (not phases or phases[0].get('name') != 'actor-partition-recovery'
            or phases[0].get('durationSeconds') != 120
            or any(phases[0].get(key, 0) != 0 for key in ('messagesPerSecond', 'roomLogReadsPerSecond', 'syncPullsPerSecond'))
            or any(phase.get('reconnectPercentPerMinute', 0) != 0 for phase in phases)):
        raise ValueError('partition canary requires quiet 120s recovery and no client reconnects')
    if platform.system() != 'Darwin':
        raise ValueError('native partition interpose fixture requires Darwin')


class ActorProxyControl:
    """One owned subprocess; bounded control messages contain no TLS bytes."""
    def __init__(self, args, directory):
        self.directory = directory
        self.process = None
        self.last_snapshot = None
        self.cleanup_result = None
        self.stream = (directory/'actor-proxy.log').open('x')
        self.stderr = (directory/'actor-proxy-stderr.log').open('x')
        self.dylib = directory/'actor-connect.dylib'
        try:
            compiled = subprocess.run(['clang', '-std=c11', '-dynamiclib', '-arch', platform.machine(),
                str(ROOT/'IMV2/scripts/fixtures/v2_actor_connect_interpose.c'), '-o', str(self.dylib)],
                stdout=self.stderr, stderr=self.stderr, timeout=30)
            if compiled.returncode:
                raise RuntimeError('fixture_unavailable:interpose_compile')
            original_ports = list(range(args.actor_port, args.actor_port+NODES))
            proxy_ports = set(range(args.actor_proxy_port, args.actor_proxy_port+42))
            forbidden = set(original_ports + [args.actor_port+NODES, args.pg_port, args.account_port, args.nats_port])
            for base in (args.gateway_port, args.metrics_port, args.https_port):
                forbidden.update(range(base, base+NODES))
            if proxy_ports & forbidden:
                raise RuntimeError('fixture_unavailable:port_overlap')
            self.process = subprocess.Popen(['python3', str(ROOT/'IMV2/scripts/v2_actor_network_partition_proxy.py'),
                '--actor-ports', ','.join(map(str, original_ports)), '--proxy-port-base', str(args.actor_proxy_port),
                '--caller-actor-ports', str(args.actor_port+NODES)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=self.stderr, text=True, bufsize=1)
            self.ready = self.read()
            if (self.ready.get('event') != 'ready' or not self.ready.get('fixtureAvailable')
                    or len(self.ready.get('nodePortMaps', [])) != NODES
                    or len(self.ready.get('callerPortMaps', [])) != 1):
                raise RuntimeError('fixture_unavailable:proxy_start')
        except BaseException:
            try: self.close()
            except Exception: pass
            raise

    def read(self, timeout=5):
        import select
        if not select.select([self.process.stdout], [], [], timeout)[0]:
            raise RuntimeError('fixture_unavailable:proxy_control_timeout')
        line = self.process.stdout.readline(65537)
        if not line or len(line) > 65536:
            raise RuntimeError('fixture_unavailable:proxy_control_closed')
        value = json.loads(line)
        self.last_snapshot = value
        self.stream.write(json.dumps(value)+'\n'); self.stream.flush()
        if not value.get('fixtureAvailable', False):
            raise RuntimeError('fixture_unavailable:proxy_bounds')
        return value

    def command(self, action, node=None):
        value = dict(action=action)
        if node is not None: value['node'] = node
        self.process.stdin.write(json.dumps(value)+'\n'); self.process.stdin.flush()
        result = self.read()
        if result.get('event') != action:
            raise RuntimeError('fixture_unavailable:proxy_control_mismatch')
        return result

    def environment(self, node=None):
        mapping = self.ready['callerPortMaps'][0] if node is None else self.ready['nodePortMaps'][node]
        return dict(DYLD_INSERT_LIBRARIES=str(self.dylib), V2_ACTOR_PORT_MAP=mapping)

    def close(self, deadline=None):
        if self.cleanup_result is not None: return self.cleanup_result
        deadline = time.monotonic()+10 if deadline is None else deadline
        def remaining(): return max(.1, min(5, deadline-time.monotonic()))
        failure = None
        if self.process is not None:
            try:
                if self.process.poll() is None:
                    self.process.stdin.write('{"action":"close"}\n'); self.process.stdin.flush()
                if (self.last_snapshot or {}).get('event') != 'closed':
                    self.read(timeout=remaining())
                self.process.wait(timeout=remaining())
            except Exception:
                snapshot = self.last_snapshot or {}
                failure = ('proxy_closure_unconfirmed' if snapshot.get('event') == 'closed'
                           and not snapshot.get('fixtureAvailable', False) else 'proxy_close_control_failed')
                if self.process.poll() is None:
                    try: self.process.terminate()
                    except ProcessLookupError: pass
                try: self.process.wait(timeout=remaining())
                except subprocess.TimeoutExpired:
                    if failure is None: failure = 'proxy_process_timeout'
                    try: self.process.kill()
                    except ProcessLookupError: pass
                    self.process.wait()
            snapshot = self.last_snapshot or {}
            if (snapshot.get('event') != 'closed' or snapshot.get('closed') is not True
                    or not snapshot.get('fixtureAvailable', False)
                    or snapshot.get('unconfirmedClosureCount', 0) != 0
                    or snapshot.get('activeFlows') != 0):
                failure = failure or 'proxy_closed_witness_invalid'
            if self.process.returncode != 0: failure = failure or 'proxy_process_failed'
            process_settled = self.process.returncode is not None
            for pipe in (self.process.stdin, self.process.stdout):
                if pipe:
                    try: pipe.close()
                    except OSError: failure = failure or 'proxy_pipe_close_failed'
        else:
            failure = 'proxy_not_started'; process_settled = True
        self.stream.close(); self.stderr.close()
        self.cleanup_result = dict(passed=failure is None, failureCode=failure,
            ownedProcessSettled=process_settled,
            unconfirmedClosureCount=(self.last_snapshot or {}).get('unconfirmedClosureCount'),
            confirmedClosureErrorCount=(self.last_snapshot or {}).get('confirmedClosureErrorCount', 0),
            closeFailures=(self.last_snapshot or {}).get('closeFailures', {}))
        return self.cleanup_result


def apply_partition_fixture_cleanup(result, cleanup):
    # Product observations remain independently reviewable. Fixture validity is
    # an additional acceptance gate, never a throughput or SQL failure label.
    result.setdefault('productQualityPassed', result.get('qualityPassed') is True)
    result['fixtureCleanupPending'] = False
    result['fixtureCleanupPassed'] = cleanup.get('passed') is True
    result['fixtureQualified'] = (result['fixtureCleanupPassed'] and not result.get('fixtureUnavailable', False)
                                  and not result.get('progressEvidenceFailed', False))
    result['fixtureCleanup'] = cleanup
    result['qualityPassed'] = result['productQualityPassed'] and result['fixtureQualified']
    return result


def checkpoint_connection_proof(parts, counts, *, require_ready, minimum_room_head=1):
    """Actual per-channel witnesses; never infer coverage from aggregate frames."""
    if len(parts) != PARTS: return False
    physical = set()
    for part, count in zip(parts, counts):
        slots = part.get('slots', [])
        if (part.get('requestedConnections') != count or len(slots) != count
                or {slot.get('connectionIndex') for slot in slots} != set(range(count))): return False
        for slot in slots:
            coverage = slot.get('coverage') or {}
            identity = slot.get('physicalConnectionID')
            if (slot.get('state') != 'active' or not identity or identity in physical
                    or coverage.get('physicalConnectionID') != identity or coverage.get('wireVersion') != CANDIDATE_WIRE_VERSION): return False
            try: uuid.UUID(identity)
            except (ValueError, TypeError, AttributeError): return False
            physical.add(identity)
            if not require_ready: continue
            scopes = coverage.get('requestedScopes', [])
            if len(scopes) != 2 or {scope.get('scope') for scope in scopes} != {'account', 'room'}: return False
            foreground = [room for room in slot.get('rooms', []) if room.get('activeForeground') is True]
            room_scope = next(scope for scope in scopes if scope['scope'] == 'room')
            if len(foreground) != 1 or foreground[0].get('roomID') != room_scope.get('scopeID'): return False
            for scope in scopes:
                if (scope.get('state') != 'ready' or scope.get('passed') is not True
                        or type(scope.get('scopeGeneration')) is not int or scope['scopeGeneration'] <= 0
                        or type(scope.get('revision')) is not int or scope['revision'] <= 0
                        or type(scope.get('highWatermark')) is not int
                        or scope['highWatermark'] < (minimum_room_head if scope['scope'] == 'room' else 0)
                        or type(scope.get('appliedCursor')) is not int
                        or scope['appliedCursor'] < scope['highWatermark']): return False
    return True


def checkpoint_physical_continuity(before, after):
    if len(before) != len(after): return False
    for old, new in zip(before, after):
        previous = {slot['connectionIndex']: slot['physicalConnectionID'] for slot in old['slots']}
        current = {slot['connectionIndex']: slot['physicalConnectionID'] for slot in new['slots']}
        if previous != current: return False
    return True


def room_activation_checkpoint(args, database, parts):
    rooms = sorted({str(uuid.UUID(scope['scopeID']))
                    for part in parts for slot in part['slots']
                    for scope in slot['coverage']['requestedScopes'] if scope['scope'] == 'room'})
    if not rooms or len(rooms) > 500:
        raise RuntimeError('partition_room_activation_checkpoint_budget_invalid')
    literals = ','.join("'"+room+"'::uuid" for room in rooms)
    sql = f"""SELECT json_build_object('databaseNow',extract(epoch FROM clock_timestamp()),
        'requestedRooms',{len(rooms)},'leases',coalesce(json_agg(json_build_object(
        'roomID',room_id,'activationEpoch',activation_epoch,'ownerShardID',owner_shard_id,
        'ownerEpoch',owner_epoch,'hostID',host_id,'incarnation',host_incarnation_id,
        'expiresAt',extract(epoch FROM expires_at))), '[]'::json))
        FROM im_v2.room_activation_leases WHERE room_id IN ({literals})"""
    value = json.loads(fault_read_query(args, database, sql))
    if (len(value.get('leases', [])) != len(rooms)
            or {row.get('roomID') for row in value.get('leases', [])} != set(rooms)):
        raise RuntimeError('partition_room_activation_checkpoint_incomplete')
    return value


def checkpoint_rebuilt_owner_rooms(before, after, old_leases, new_leases, isolated_host):
    normalize = lambda value: str(uuid.UUID(value))
    host = normalize(isolated_host)
    old = {normalize(row['roomID']): row for row in old_leases['leases']}
    new = {normalize(row['roomID']): row for row in new_leases['leases']}
    affected = {room for room, row in old.items()
                if row['hostID'] is not None and normalize(row['hostID']) == host}
    if not affected or len(before) != len(after): return False
    for room in affected:
        previous, current = old[room], new.get(room)
        if (current is None or current['activationEpoch'] <= previous['activationEpoch']
                or current['ownerShardID'] != previous['ownerShardID']
                or current['ownerEpoch'] != previous['ownerEpoch']
                or current['hostID'] is None or current['incarnation'] is None
                or current['expiresAt'] is None or current['expiresAt'] <= new_leases['databaseNow']):
            return False
    witnessed = set()
    for old_part, new_part in zip(before, after):
        previous = {slot['connectionIndex']: slot for slot in old_part['slots']}
        for slot in new_part['slots']:
            prior = previous.get(slot['connectionIndex'])
            if prior is None: return False
            old_room = next(scope for scope in prior['coverage']['requestedScopes'] if scope['scope'] == 'room')
            room = normalize(old_room['scopeID'])
            if room not in affected: continue
            new_room = next(scope for scope in slot['coverage']['requestedScopes'] if scope['scope'] == 'room')
            if (normalize(new_room['scopeID']) != room
                    or not (new_room['scopeGeneration'] > old_room['scopeGeneration']
                            or new_room['revision'] > old_room['revision'])): return False
            witnessed.add(room)
    return witnessed == affected


def checkpoint_heartbeat_continuity(before, after, target):
    for index, (old, new) in enumerate(zip(before, after)):
        previous = {slot['connectionIndex']: slot for slot in old['slots']}
        for slot in new['slots']:
            prior = previous.get(slot['connectionIndex'])
            if prior is None or prior['physicalConnectionID'] != slot['physicalConnectionID']: return False
            if index % NODES == target:
                if slot['coverage'].get('heartbeatAcknowledged', 0) <= prior['coverage'].get('heartbeatAcknowledged', 0): return False
                if slot['coverage'].get('heartbeatMissed', 0) != prior['coverage'].get('heartbeatMissed', 0): return False
    return True


PARTITION_WITNESS_MAX_ROWS = 32768
PARTITION_WITNESS_MAX_READ = 256


def install_partition_lease_witness(args, database, directory):
    # Canary-only instrumentation in the marked owned disposable database.
    # No trigger, grant, history table or mutation is installed in capacity mode.
    partitions = sorted({realtime_topic_partition(json.loads(line)['targetRoomIDs'][0])
                         for line in (args.fixture/'credentials.jsonl').read_text().splitlines()})
    if not partitions or len(partitions) > 256:
        raise RuntimeError('partition_witness_selection_invalid')
    keys = ','.join(map(str, partitions))
    fixture_id = str(uuid.UUID(json.loads((args.fixture/'manifest.json').read_text())['fixtureID']))
    sql = f"""BEGIN;
    DO $guard$ BEGIN
      IF (SELECT count(*) FROM public.imv2_disposable_fixture_guard) <> 1
         OR NOT EXISTS (SELECT 1 FROM public.imv2_disposable_fixture_guard WHERE fixture_id='{fixture_id}'::uuid)
      THEN RAISE EXCEPTION 'invalid disposable witness fixture'; END IF;
    END $guard$;
    CREATE SCHEMA imv2_actor_fault_witness;
    REVOKE ALL ON SCHEMA imv2_actor_fault_witness FROM PUBLIC;
    CREATE TABLE imv2_actor_fault_witness.partition_history (
      witness_sequence bigint GENERATED ALWAYS AS IDENTITY (MAXVALUE {PARTITION_WITNESS_MAX_ROWS} NO CYCLE) PRIMARY KEY,
      partition_id integer NOT NULL,
      statement_at timestamptz NOT NULL, observed_at timestamptz NOT NULL,
      old_epoch bigint NOT NULL, new_epoch bigint NOT NULL,
      old_token uuid, new_token uuid,
      old_host text, new_host text, old_service text, new_service text,
      old_incarnation uuid, new_incarnation uuid,
      old_expiry timestamptz NOT NULL, new_expiry timestamptz NOT NULL,
      fence_database_at timestamptz NOT NULL
    );
    REVOKE ALL ON TABLE imv2_actor_fault_witness.partition_history FROM PUBLIC;
    CREATE FUNCTION imv2_actor_fault_witness.capture_partition_update() RETURNS trigger
      LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $capture$
    BEGIN
      INSERT INTO imv2_actor_fault_witness.partition_history
        (partition_id,statement_at,observed_at,old_epoch,new_epoch,old_token,new_token,
         old_host,new_host,old_service,new_service,old_incarnation,new_incarnation,
         old_expiry,new_expiry,fence_database_at)
      VALUES (NEW.partition_id,statement_timestamp(),clock_timestamp(),OLD.lease_epoch,NEW.lease_epoch,
         OLD.lease_token,NEW.lease_token,OLD.host_id,NEW.host_id,OLD.service_id,NEW.service_id,
         OLD.process_incarnation,NEW.process_incarnation,OLD.expires_at,NEW.expires_at,NEW.updated_at);
      RETURN NEW;
    END $capture$;
    REVOKE ALL ON FUNCTION imv2_actor_fault_witness.capture_partition_update() FROM PUBLIC;
    CREATE TRIGGER imv2_canary_partition_history AFTER UPDATE ON im_v2.realtime_partition_leases
      FOR EACH ROW WHEN (NEW.partition_id IN ({keys}))
      EXECUTE FUNCTION imv2_actor_fault_witness.capture_partition_update();
    COMMIT;
    """
    path = directory/'partition-witness-install.sql'
    with path.open('x') as stream:
        os.fchmod(stream.fileno(), 0o600); stream.write(sql)
    environment = dict(os.environ, PGHOST=args.pg_host, PGPORT=str(args.pg_port), PGUSER=args.pg_user,
                       PGCONNECT_TIMEOUT='2', PGOPTIONS='-c statement_timeout=1500 -c lock_timeout=1500')
    completed = subprocess.run([str(args.pg_bin_directory/'psql'), '-X', '-v', 'ON_ERROR_STOP=1',
                               '-d', database, '-f', str(path)], env=environment,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)
    if completed.returncode: raise RuntimeError('fixture_unavailable:partition_witness_install')
    private_json(directory/'partition-witness-contract.json', dict(selectedPartitions=partitions,
        maximumRows=PARTITION_WITNESS_MAX_ROWS, maximumRowsPerRead=PARTITION_WITNESS_MAX_READ,
        triggerSameTransaction=True, securityDefinerOwner=args.pg_user,
        searchPath='pg_catalog', publicPrivilegesRevoked=True,
        scope='owned disposable canary only; bounded history of committed control updates, not an additional lease authority'))


def partition_lease_witness_snapshot(args, database, partition):
    if type(partition) is not int or not 0 <= partition < 256:
        raise RuntimeError('partition_witness_key_invalid')
    sql = f"""SELECT json_build_object('observedAt',clock_timestamp(), 'rows',coalesce((
      SELECT json_agg(json_build_object('sequence',witness_sequence,'partitionID',partition_id,
        'statementAt',extract(epoch FROM statement_at),'observedAt',extract(epoch FROM observed_at),
        'oldEpoch',old_epoch,'newEpoch',new_epoch,'oldToken',old_token::text,'newToken',new_token::text,
        'oldHost',old_host,'newHost',new_host,'oldService',old_service,'newService',new_service,
        'oldIncarnation',old_incarnation::text,'newIncarnation',new_incarnation::text,
        'oldExpiry',extract(epoch FROM old_expiry),'newExpiry',extract(epoch FROM new_expiry),
        'fenceDatabaseAt',extract(epoch FROM fence_database_at)) ORDER BY witness_sequence)
      FROM (SELECT * FROM imv2_actor_fault_witness.partition_history
        WHERE partition_id={partition} ORDER BY witness_sequence LIMIT {PARTITION_WITNESS_MAX_READ+1}) history
      ),'[]'::json))"""
    snapshot = json.loads(fault_read_query(args, database, sql))
    if len(snapshot.get('rows', [])) > PARTITION_WITNESS_MAX_READ:
        raise RuntimeError('fixture_unavailable:partition_witness_read_bound')
    return snapshot


def partition_takeover_witness_proof(initial, rows):
    def original(row, prefix):
        return (row.get(prefix+'Epoch') == initial['epoch']
                and row.get(prefix+'Token') == initial['token']
                and row.get(prefix+'Host') == initial['hostID']
                and row.get(prefix+'Service') == initial['serviceID']
                and row.get(prefix+'Incarnation') == initial['incarnation'])
    previous = 0
    releases = []
    for row in rows:
        sequence = row.get('sequence')
        if (type(sequence) is not int or sequence <= previous
                or row.get('partitionID') != initial['partitionID']):
            raise RuntimeError('partition_witness_order_invalid')
        previous = sequence
        if not original(row, 'old'): continue
        if original(row, 'new') and row['newExpiry'] < row['oldExpiry']:
            if abs(row['newExpiry']-min(row['oldExpiry'],row['fenceDatabaseAt'])) > .00001:
                raise RuntimeError('partition_witness_release_clock_invalid')
            releases.append(row)
        if row['newEpoch'] == initial['epoch']+1:
            # NEW.updated_at is the fresh locked DB clock actually used by the
            # production store. Trigger observation time alone is insufficient.
            if (row['oldExpiry'] > row['fenceDatabaseAt'] or row['newExpiry'] <= row['fenceDatabaseAt']
                    or row['newToken'] is None or row['newToken'] == initial['token']
                    or row['newHost'] not in {f'gateway-{index}' for index in range(NODES)}
                    or row['newHost'] == initial['hostID']
                    or row['newIncarnation'] is None or row['newIncarnation'] == initial['incarnation']):
                raise RuntimeError('partition_takeover_witness_invalid')
            release = next((item for item in reversed(releases)
                            if abs(item['newExpiry']-row['oldExpiry']) <= .00001), None)
            if releases and release is None:
                raise RuntimeError('partition_takeover_release_chain_invalid')
            return dict(passed=True, boundary='strict_release' if release else 'natural_expiry',
                originalEpoch=initial['epoch'], claimedEpoch=row['newEpoch'],
                releaseSequence=release['sequence'] if release else None, claimSequence=sequence,
                claimedOldExpiry=row['oldExpiry'], claimFenceDatabaseAt=row['fenceDatabaseAt'],
                statementAt=row['statementAt'], observedAt=row['observedAt'])
    raise RuntimeError('partition_takeover_witness_missing')


def partition_observed_history_proof(initial, rows, current, *, phase):
    """Validate every committed transition through the exact sampled tuple.

    Release/claim gaps are observations, never final active-coverage success.
    Surviving process incarnation may legitimately reacquire after healing.
    """
    fields = (('epoch','Epoch'),('token','Token'),('hostID','Host'),
              ('serviceID','Service'),('incarnation','Incarnation'))
    def tuple_at(row, prefix):
        return {key:row[prefix+column] for key,column in fields} | dict(expiresAt=row[prefix+'Expiry'])
    def same(left, right):
        return all(left[key]==right[key] for key,_ in fields)
    def exact(left, right):
        return same(left,right) and abs(left['expiresAt']-right['expiresAt']) <= .00001
    tracked = None
    seen_tokens = {initial['token']}
    transitions = []
    release = None
    previous = 0
    for row in rows:
        sequence = row.get('sequence')
        if (type(sequence) is not int or sequence <= previous
                or row.get('partitionID') != initial['partitionID']):
            raise RuntimeError('partition_witness_order_invalid')
        previous = sequence
        old, new = tuple_at(row,'old'), tuple_at(row,'new')
        if tracked is None:
            if not same(old,initial): continue
            tracked = old # Earlier same-token renewals can precede the sample.
        if not exact(old,tracked): raise RuntimeError('partition_witness_tuple_chain_invalid')
        clock = row['fenceDatabaseAt']
        if new['epoch'] == old['epoch']:
            if not same(old,new): raise RuntimeError('partition_same_epoch_identity_changed')
            if new['expiresAt'] < old['expiresAt']:
                if abs(new['expiresAt']-min(old['expiresAt'],clock)) > .00001:
                    raise RuntimeError('partition_witness_release_clock_invalid')
                release = row
            elif new['expiresAt'] > old['expiresAt']:
                if old['expiresAt'] <= clock:
                    raise RuntimeError('partition_witness_expired_renewal')
                release = None
        elif new['epoch'] == old['epoch']+1:
            if (old['expiresAt'] > clock or new['expiresAt'] <= clock
                    or new['token'] is None or new['token'] in seen_tokens
                    or new['hostID'] not in {f'gateway-{index}' for index in range(NODES)}
                    or new['serviceID'] is None or new['incarnation'] is None):
                raise RuntimeError('partition_takeover_witness_invalid')
            if phase == 'isolated' and (new['hostID']==initial['hostID']
                    or new['incarnation']==initial['incarnation']):
                raise RuntimeError('partition_takeover_reused_isolated_host')
            if release is not None and abs(release['newExpiry']-old['expiresAt']) > .00001:
                raise RuntimeError('partition_takeover_release_chain_invalid')
            transitions.append(dict(oldEpoch=old['epoch'],newEpoch=new['epoch'],claimSequence=sequence,
                boundary='strict_release' if release else 'natural_expiry',
                releaseSequence=release['sequence'] if release else None,
                claimedOldExpiry=old['expiresAt'],claimFenceDatabaseAt=clock))
            seen_tokens.add(new['token']); release = None
        else: raise RuntimeError('partition_witness_epoch_chain_invalid')
        tracked = new
        if exact(tracked,current):
            if not transitions: raise RuntimeError('partition_takeover_witness_missing')
            return dict(passed=True, phase=phase, originalEpoch=initial['epoch'],
                        observedEpoch=current['epoch'],transitions=transitions)
    raise RuntimeError('partition_observed_tuple_witness_missing')


def checkpoint_response_matches_request(value, nonce, stamp):
    # Foundation UUID.encode emits uppercase; Python uuid emits lowercase. This
    # is a UUID correlation key, never an opaque string identifier.
    try:
        if not isinstance(nonce, str) or not isinstance(value.get('nonce'), str):
            raise ValueError('missing checkpoint nonce')
        expected = uuid.UUID(nonce)
        actual = uuid.UUID(value['nonce'])
    except (ValueError, TypeError, AttributeError) as error:
        raise RuntimeError('partition_checkpoint_nonce_invalid') from None
    if actual != expected: return False # A valid response to an older request.
    requested = value.get('requestedAtUnixMilliseconds')
    started = value.get('samplingStartedAtUnixMilliseconds')
    completed = value.get('samplingCompletedAtUnixMilliseconds')
    if (any(type(item) is not int for item in (stamp, requested, started, completed))
            or stamp <= 0 or requested != stamp or started < stamp or completed < started):
        raise RuntimeError('partition_checkpoint_clock_or_nonce_invalid')
    return True


class ActorPartitionCanary:
    def __init__(self, args, database, directory, counts, proxy, foreground, *, room_host=None):
        self.args, self.database, self.directory, self.counts, self.proxy = args, database, directory, counts, proxy
        self.target = args.actor_partition_canary
        self.room_host = room_host
        self.room_before = None
        self.room_rebuilt = False
        self.foreground = foreground
        self.state = 'arming'
        self.request = None
        self.initial = self.last_old = None
        self.samples = []
        self.before = self.isolated = self.after = None
        self.isolated_baseline = None
        self.pid = None
        self.first_higher = None
        self.takeover_proof = None
        self.qualified_zero = False
        self.heartbeat_alive = False
        self.heal_at = None
        self.recovered = False
        self.deadline = None
        self.proxy_samples = []

    def metrics(self):
        values = []
        for index in range(NODES):
            with urllib.request.urlopen(f'http://127.0.0.1:{self.args.metrics_port+index}/metrics', timeout=1) as response:
                text = response.read(4*1024*1024).decode()
            item = dict(node=index)
            for key in ('reachable_nodes', 'installed_partitions', 'service_qualified'):
                found = re.search(r'^im_v2_actor_realtime_'+key+r' ([0-9]+(?:\.[0-9]+)?)$', text, re.M)
                if not found: raise RuntimeError('partition_qualification_metrics_missing')
                item[key] = float(found[1])
            values.append(item)
        return values

    def checkpoint(self, label):
        if self.request is None:
            nonce = str(uuid.uuid4())
            stamp = int(time.time()*1000)
            self.request = (nonce, stamp, time.monotonic()+10)
            for index in range(PARTS):
                private_json_snapshot(self.directory/f'checkpoint-request-{index}.json',
                                      dict(nonce=nonce, requestedAtUnixMilliseconds=stamp))
            return None
        nonce, stamp, deadline = self.request
        parts = []
        for index in range(PARTS):
            path = self.directory/f'checkpoint-response-{index}.json'
            if not path.exists(): break
            value = json.loads(path.read_text())
            if not checkpoint_response_matches_request(value, nonce, stamp): break
            parts.append(value)
        if len(parts) != PARTS:
            if time.monotonic() >= deadline: raise TimeoutError('partition_checkpoint_timeout')
            return None
        self.request = None
        private_json_snapshot(self.directory/f'partition-checkpoint-{label}.json', parts)
        return parts

    def persist(self):
        private_json_snapshot(self.directory/'actor-partition-canary.json', dict(formatVersion=1,
            state=self.state, passed=self.recovered, targetGateway=self.target, targetPID=self.pid,
            roomActivationRecoveryProven=self.room_rebuilt,
            majorityRosterCount=NODES, nonVotingCallers=1, productionControllerUsed=True,
            alteredLeaseTTL=False, alteredPoolBudget=False, clientReconnectsRequested=False,
            preFaultReadyNonzeroProven=self.before is not None, targetQualificationWithdrawn=self.qualified_zero,
            targetHeartbeatsContinued=self.heartbeat_alive, initial=self.initial, lastOld=self.last_old,
            firstHigher=self.first_higher, takeoverProof=self.takeover_proof, samples=self.samples, proxySamples=self.proxy_samples,
            scope='silent Actor TLS stream loss; same Gateway process, natural authoritative lease boundary; final independent client cursor proof'))

    def step(self, release_at, gateways):
        if self.deadline is None:
            if time.time() < release_at: return
            self.deadline = time.monotonic() + max(0, release_at+120-time.time())
        if self.recovered: return
        if time.monotonic() >= self.deadline:
            self.persist(); raise TimeoutError('partition_canary_recovery_window_exhausted')
        process = gateways[self.target]
        if process.poll() is not None or (self.pid is not None and process.pid != self.pid):
            raise RuntimeError('partition_target_process_not_continuously_alive')
        if self.state == 'arming':
            parts = self.checkpoint('before')
            if parts is None: return
            if not checkpoint_connection_proof(parts, self.counts, require_ready=True):
                return # Never arm from missing/recovering/H=0; unchanged absolute window.
            metrics = self.metrics()
            if not all(item['service_qualified'] == 1 for item in metrics): return
            snap = partition_lease_snapshot(self.args, self.database, self.foreground)
            eligible = [row for row in snap['leases'] if row['hostID'] == f'gateway-{self.target}'
                        and row['expiresAt']-snap['databaseNow'] >= 10 and row['epoch'] > 0]
            if not eligible: return
            proxy = self.proxy.command('snapshot')
            # Every possible association (including the nonvoting caller) must
            # traverse a mapped listener before this fixture can claim coverage.
            logs = [self.directory/f'gateway-{i}.log' for i in range(NODES)] + [self.directory/'account.log']
            if any('v2_actor_fixture_interpose_loaded' not in path.read_text() for path in logs):
                raise RuntimeError('fixture_unavailable:interpose_not_loaded')
            if any('v2_actor_fixture_connect_mapped' not in path.read_text() for path in logs):
                raise RuntimeError('fixture_unavailable:interpose_not_mapped')
            for source in range(NODES+1):
                if not any(link['sourceNode'] == source and link['opened'] > 0 for link in proxy['links']):
                    raise RuntimeError('fixture_unavailable:association_coverage')
            if self.deadline-time.monotonic() < 80: raise TimeoutError('partition_arm_window_exhausted')
            self.room_before = room_activation_checkpoint(self.args, self.database, parts)
            if not self.room_host or not any(row['hostID'] and uuid.UUID(row['hostID']) == uuid.UUID(self.room_host)
                                             for row in self.room_before['leases']):
                return # Do not inject a Room recovery fault without actual affected rooms.
            private_json_snapshot(self.directory/'room-activation-checkpoint-before.json', self.room_before)
            self.pid = process.pid; self.before = parts; self.initial = self.last_old = eligible[0]
            self.proxy_samples.append(self.proxy.command('isolate', self.target))
            self.state = 'isolated'; self.persist(); return
        snap = partition_lease_snapshot(self.args, self.database, [self.initial['partitionID']])
        if len(self.samples) >= 80: raise RuntimeError('partition_observation_bound_exhausted')
        row = snap['leases'][0]
        if self.samples and row['epoch'] < self.samples[-1]['leases'][0]['epoch']:
            raise RuntimeError('partition_observed_epoch_regressed')
        self.samples.append(snap)
        if row['epoch'] == self.initial['epoch']:
            if any(row[field] != self.initial[field] for field in ('token', 'incarnation', 'hostID', 'serviceID')):
                raise RuntimeError('partition_same_epoch_identity_changed')
            self.last_old = row # A previously submitted renewal may actually settle.
        elif row['epoch'] > self.initial['epoch']:
            witness = partition_lease_witness_snapshot(self.args, self.database, self.initial['partitionID'])
            self.takeover_proof = partition_observed_history_proof(self.initial, witness['rows'], row, phase=self.state)
            private_json_snapshot(self.directory/'partition-lease-history-current.json', witness)
            private_json_snapshot(self.directory/'partition-takeover-proof-current.json', self.takeover_proof)
            if self.first_higher is None: self.first_higher = snap
        else: raise RuntimeError('partition_epoch_regressed')
        lease_active = row['epoch'] > self.initial['epoch'] and row['expiresAt'] > snap['databaseNow']
        metrics = self.metrics()
        if self.state == 'isolated':
            self.qualified_zero |= metrics[self.target]['service_qualified'] == 0 and metrics[self.target]['installed_partitions'] == 0
            parts = self.checkpoint('isolated')
            if parts is not None:
                if not checkpoint_connection_proof(parts, self.counts, require_ready=False):
                    raise RuntimeError('partition_client_channel_lost')
                self.isolated = parts
                # Anchor heartbeat deltas only AFTER qualification is lost and
                # blackholing has begun; pre-isolation ACKs cannot count.
                if self.qualified_zero and self.isolated_baseline is None:
                    self.isolated_baseline = parts
                    private_json(self.directory/'partition-checkpoint-isolated-baseline.json', parts)
                elif self.isolated_baseline is not None:
                    self.heartbeat_alive = checkpoint_heartbeat_continuity(self.isolated_baseline, parts, self.target)
                if not checkpoint_physical_continuity(self.before, parts):
                    raise RuntimeError('partition_physical_channel_changed')
            if (lease_active and self.first_higher and self.qualified_zero and self.heartbeat_alive
                    and metrics[self.target]['service_qualified'] == 0
                    and metrics[self.target]['installed_partitions'] == 0):
                proxy = self.proxy.command('snapshot'); self.proxy_samples.append(proxy)
                if not any(link['discardedBytes'] > 0 and (link['sourceNode'] == self.target or link['targetNode'] == self.target) for link in proxy['links']):
                    raise RuntimeError('fixture_unavailable:no_blackholed_actor_bytes')
                if not all(item['service_qualified'] == 1 for item in metrics if item['node'] != self.target):
                    raise RuntimeError('partition_majority_not_qualified')
                if time.monotonic() >= self.deadline:
                    raise TimeoutError('partition_canary_recovery_window_exhausted')
                self.proxy_samples.append(self.proxy.command('heal', self.target))
                self.request = None; self.heal_at = int(time.time()*1000)
                self.state = 'healing'
        elif self.state == 'healing':
            parts = self.checkpoint('after')
            if parts is not None and checkpoint_connection_proof(parts, self.counts, require_ready=True):
                room_after = room_activation_checkpoint(self.args, self.database, parts)
                private_json_snapshot(self.directory/'room-activation-checkpoint-after.json', room_after)
                self.room_rebuilt = checkpoint_rebuilt_owner_rooms(self.before, parts,
                    self.room_before, room_after, self.room_host)
                if not checkpoint_physical_continuity(self.before, parts):
                    raise RuntimeError('partition_repair_changed_physical_channel')
                if (lease_active and self.room_rebuilt
                        and all(item['service_qualified'] == 1 for item in metrics)
                        and sum(item['installed_partitions'] for item in metrics) == 256):
                    if time.monotonic() >= self.deadline:
                        raise TimeoutError('partition_canary_recovery_window_exhausted')
                    self.after = parts; self.recovered = True; self.state = 'recovered'
        self.persist()


def benchmark_targets_per_connection(*, prefill):
    # Both rounds consume the same frozen two-target credentials. Loader's
    # cardinality guard must remain authoritative even in the prewrite round.
    return 2


def partition_prefill_head_proof(args, database):
    rooms = sorted({str(uuid.UUID(json.loads(line)['targetRoomIDs'][0]))
                    for line in (args.fixture/'credentials.jsonl').read_text().splitlines()})
    if not rooms or len(rooms) > 500: raise RuntimeError('partition_prefill_room_budget_invalid')
    literals = ','.join("'"+room+"'::uuid" for room in rooms)
    sql = f"""WITH expected(room_id) AS (VALUES {','.join('('+literal+')' for literal in literals.split(','))})
        SELECT json_build_object('observedAt',clock_timestamp(),'expected',{len(rooms)},
        'found',count(r.room_id),'nonzero',count(*) FILTER(WHERE r.room_sequence>0))
        FROM expected LEFT JOIN im_v2.rooms r USING(room_id)"""
    result = json.loads(fault_read_query(args, database, sql))
    result['passed'] = result['found'] == result['nonzero'] == result['expected']
    return result


def planned_reconnect_fact_proof(args, database, expected_acknowledged, *, initial_facts_empty):
    # Imported by exact owned file path; ordinary capacity runs never execute it.
    import importlib.util
    spec = importlib.util.spec_from_file_location('imv2_realtime_fact_proof',
        ROOT/'IMV2/scripts/v2_actor_realtime_fact_proof.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    guard = json.loads(fault_read_query(args, database,
        "SELECT json_build_object('guards',(SELECT count(*) FROM public.imv2_disposable_fixture_guard),"
        "'fixture',(SELECT fixture_id::text FROM public.imv2_disposable_fixture_guard LIMIT 1))"))
    fresh = initial_facts_empty and guard['guards'] == 1 and guard['fixture'] == str(uuid.UUID(json.loads((args.fixture/'manifest.json').read_text())['fixtureID']))
    return module.prove_message_facts(lambda sql: fault_read_query(args, database, sql),
        expected_acknowledged, fresh_fixture=fresh)


def run_revision(args, kind, actors, counts, manifest):
    directory = args.output_dir/kind
    directory.mkdir(mode=0o700)
    # A previous revision's local TIME_WAIT tuples cannot be reused immediately.
    # Observe only this workload's source range and Gateway destination ports.
    origin=time.monotonic()
    while True:
        lingering=0
        for line in subprocess.check_output(['netstat','-an','-p','tcp'],text=True).splitlines():
            columns=line.split()
            if len(columns)<6 or not columns[0].startswith('tcp'):continue
            try:
                local=int(columns[3].rsplit('.',1)[1]);remote=int(columns[4].rsplit('.',1)[1])
            except (ValueError,IndexError):continue
            if 25000<=local<=44999 and args.gateway_port<=remote<args.gateway_port+NODES:
                lingering+=1
        if not lingering:break
        if time.monotonic()-origin>60:raise TimeoutError('previous owned workload TCP tuples have not retired')
        time.sleep(1)
    private_json(directory/'source-port-wait.json',dict(elapsedSeconds=time.monotonic()-origin,remainingOwnedTuples=0))
    database = 'imv2_va_actor_' + kind + '_' + uuid.uuid4().hex[:12]
    private_json(directory/'database.json',dict(name=database,fixtureID=manifest['fixtureID'],disposable=True))
    seed(args,kind,database,directory,manifest)
    if args.actor_partition_canary is not None:
        install_partition_lease_witness(args, database, directory)
    initial_facts_empty = False
    if args.planned_reconnect_inflight_canary:
        initial = json.loads(fault_read_query(args, database,
            "SELECT json_build_object('messages',(SELECT count(*) FROM im_v2.messages),"
            "'receipts',(SELECT count(*) FROM im_v2.message_send_completions),"
            "'roomSequenceSum',(SELECT coalesce(sum(room_sequence),0) FROM im_v2.rooms))"))
        private_json(directory/'fact-proof-initial.json', initial)
        initial_facts_empty = all(type(value) is int and value == 0 for value in initial.values()) and len(initial) == 3
        if not initial_facts_empty:
            raise RuntimeError('planned_reconnect_fixture_not_empty')
    processes, streams, loaders = [], [], []
    failure_context = None
    result = None
    fixture_cleanup = None
    failure_stage = 'startup'
    restart_canary = None
    partition_canary = None
    actor_proxy = None
    service_stop_deadline = None
    loader_report_drain = LoaderFailureReportDrain(getattr(args, 'loader_report_drain_seconds', 120))
    app_expected_killed = set()
    stop_monitor = threading.Event()
    def start(command, name, environment=None):
        stream=(directory/(name+'.log')).open('x'); streams.append(stream)
        proc=subprocess.Popen(command,env=environment,stdout=stream,stderr=stream); processes.append(proc)
        return proc
    def monitor():
        previous_postgres = None
        previous_host = None
        with (directory/'process-resources.jsonl').open('x') as stream:
            while not stop_monitor.wait(5):
                current_host = sample_host_resources(previous_host)
                previous_host = current_host
                with (directory/'host-resources.jsonl').open('a') as host_stream:
                    host_stream.write(json.dumps(current_host)+'\n')
                pids=[str(p.pid) for p in processes if p.poll() is None]
                if pids:
                    output=subprocess.run(['ps','-o','pid=,rss=,time=,command=','-p',','.join(pids)],capture_output=True,text=True).stdout
                    stream.write(json.dumps(dict(time=time.time(),ps=output))+'\n');stream.flush()
                samples=[]
                sampling_started = time.time()
                for index in range(NODES):
                    node_started = time.time()
                    try:
                        with urllib.request.urlopen(f'http://127.0.0.1:{args.metrics_port+index}/metrics',timeout=1) as response:
                            body=response.read(4*1024*1024).decode('utf-8')
                        samples.append(dict(node=index,body=body,samplingStartedAtUnixSeconds=node_started,
                                            samplingCompletedAtUnixSeconds=time.time()))
                    except Exception as error:
                        samples.append(dict(node=index,error=str(error),samplingStartedAtUnixSeconds=node_started,
                                            samplingCompletedAtUnixSeconds=time.time()))
                with (directory/'gateway-metrics.jsonl').open('a') as metrics:
                    sampling_completed = time.time()
                    metrics.write(json.dumps(dict(time=time.time(),samples=samples,
                        samplingStartedAtUnixSeconds=sampling_started,
                        samplingCompletedAtUnixSeconds=sampling_completed))+'\n')
                if args.owned_postgres_pid is not None:
                    current_postgres = sample_owned_postgres(args, database)
                    current_postgres['rates'] = derive_postgres_rates(current_postgres, previous_postgres)
                    previous_postgres = current_postgres
                    with (directory/'postgres-metrics.jsonl').open('a') as metrics:
                        metrics.write(json.dumps(current_postgres)+'\n')
    thread=threading.Thread(target=monitor,daemon=True)
    def monitor_recovery_scheduling():
        # Separate from the potentially slow full scrape. Completed-span totals
        # remain useful even if one observation arrives after its intended time.
        with (directory/'recovery-scheduling-metrics.jsonl').open('x') as stream:
            while not stop_monitor.wait(2):
                sampling_started = time.time()
                samples = []
                for index in range(NODES):
                    node_started = time.time()
                    try:
                        url = f'http://127.0.0.1:{args.metrics_port+index}/metrics/recovery-scheduling'
                        with urllib.request.urlopen(url, timeout=1) as response:
                            body = response.read(64*1024).decode('utf-8')
                        samples.append(dict(node=index, body=body,
                            samplingStartedAtUnixSeconds=node_started,
                            samplingCompletedAtUnixSeconds=time.time()))
                    except Exception as error:
                        samples.append(dict(node=index, error=str(error),
                            samplingStartedAtUnixSeconds=node_started,
                            samplingCompletedAtUnixSeconds=time.time()))
                stream.write(json.dumps(dict(time=time.time(), samples=samples,
                    samplingStartedAtUnixSeconds=sampling_started,
                    samplingCompletedAtUnixSeconds=time.time()))+'\n')
                stream.flush()
    scheduling_thread = threading.Thread(target=monitor_recovery_scheduling, daemon=True) if getattr(args, 'recovery_scheduling_metrics', False) else None
    try:
        if args.actor_partition_canary is not None:
            failure_stage = 'partition_fixture'
        if kind=='baseline':
            start([str(args.nats_binary),'-a','127.0.0.1','-p',str(args.nats_port)],'nats')
        if args.actor_partition_canary is not None:
            actor_proxy = ActorProxyControl(args, directory)
            processes.append(actor_proxy.process)
        account_values=account_env(args,kind,database,actors,manifest)
        if actor_proxy: account_values.update(actor_proxy.environment())
        account_binary=args.baseline_account_binary if kind=='baseline' else args.candidate_account_binary
        start([str(account_binary)],'account',account_values)
        for i in range(NODES):
            edge_config=directory/f'edge-configuration-{i}.json'
            private_json(edge_config,dict(listenPort=args.https_port+i,upstreamPort=args.account_port,
                         certificate=str(args.app_tls_certificate if app_canary_enabled(args) else actors/'gateway-0/tls.pem'),
                         key=str(args.app_tls_key if app_canary_enabled(args) else actors/'gateway-0/tls.key'),
                         edgeAuthorizationSecret=account_values['IM_V2_ACCOUNT_EDGE_AUTHORIZATION_SECRET_BASE64'],
                         maximumUpstreamConnections=128))
            start(['python3',str(ROOT/'IMV2/scripts/v2_benchmark_https_edge.py'),
                   '--configuration',str(edge_config),'--metrics',str(directory/f'edge-metrics-{i}.jsonl')],f'edge-{i}')
        binary = args.baseline_binary if kind=='baseline' else args.candidate_binary
        gateway_environments = [gateway_env(args,kind,database,i,actors,manifest) for i in range(NODES)]
        if actor_proxy:
            for index, environment in enumerate(gateway_environments):
                environment.update(actor_proxy.environment(index))
        gateways=[start([str(binary)],f'gateway-{i}',gateway_environments[i]) for i in range(NODES)]
        if args.room_host_restart_canary is not None:
            from v2_room_host_restart_canary import RoomHostRestartCanary
            restart_canary = RoomHostRestartCanary(args, directory, counts,
                lambda sql: fault_read_query(args, database, sql), private_json_snapshot,
                checkpoint_response_matches_request, checkpoint_connection_proof, checkpoint_physical_continuity,
                json.loads((actors/f'gateway-{args.room_host_restart_canary}'/'candidate.json').read_text())['hostID'],
                {index: json.loads((actors/f'gateway-{index}'/'candidate.json').read_text())['hostID']
                 for index in range(NODES)})
        elif args.realtime_host_restart_canary is not None:
            foreground = {realtime_topic_partition(json.loads(line)['targetRoomIDs'][0])
                          for line in (args.fixture/'credentials.jsonl').read_text().splitlines()}
            restart_canary = RealtimeHostRestartCanary(args, database, directory, foreground)
        if actor_proxy:
            foreground = {realtime_topic_partition(json.loads(line)['targetRoomIDs'][0])
                          for line in (args.fixture/'credentials.jsonl').read_text().splitlines()}
            partition_canary = ActorPartitionCanary(args, database, directory, counts, actor_proxy, foreground,
                room_host=json.loads((actors/f'gateway-{args.actor_partition_canary}'/'candidate.json').read_text())['hostID'])
        def restart_gateway(index):
            replacement = start([str(binary)], f'gateway-{index}-restarted', gateway_environments[index])
            service_processes.append(replacement)
            return replacement
        service_processes=list(processes)
        thread.start()
        if scheduling_thread is not None: scheduling_thread.start()
        deadline=time.monotonic()+120
        while True:
            if any(p.poll() is not None for p in processes):
                raise RuntimeError('Gateway/broker startup failed; logs retained')
            ready=0
            ports=[args.gateway_port+i for i in range(NODES)]+[args.account_port]+[args.https_port+i for i in range(NODES)]
            for number in ports:
                try:
                    socket.create_connection(('127.0.0.1',number),.2).close();ready+=1
                except OSError:
                    pass
            if ready==len(ports):
                if not partition_canary: break
                # Prefill must exercise qualified Actor services, rather than
                # consuming client guard budgets while only TCP listeners exist.
                try: qualification_metrics = partition_canary.metrics()
                except (OSError, RuntimeError, ValueError): qualification_metrics = []
                if (len(qualification_metrics) == NODES
                        and all(row['service_qualified'] == 1 for row in qualification_metrics)
                        and sum(row['installed_partitions'] for row in qualification_metrics) == 256
                        and time.monotonic() <= deadline): break
            if time.monotonic()>deadline: raise TimeoutError('Gateway listener/qualification readiness')
            time.sleep(1)
        authorization_mode = verify_candidate_authorization_mode(args, kind,
            lambda sql: fault_read_query(args, database, sql))
        private_json(directory/'authorization-mode.json', authorization_mode)
        if app_canary_enabled(args):
            failure_stage = app_canary_selection(args)[0]
            def crash_app_gateway():
                old = gateways[0]
                if old.poll() is not None:
                    raise RuntimeError('app_gateway_exited_before_injection')
                old.kill()
                if old.wait(timeout=5) != -signal.SIGKILL:
                    raise RuntimeError('app_gateway_sigkill_unconfirmed')
                app_expected_killed.add(old.pid)
                trim = trim_owned_app_journal(args, database) if args.app_journal_trim_canary else None
                if trim: private_json_snapshot(directory/'app-journal-trim.json', trim)
                gateways[0] = restart_gateway(0)
                evidence = dict(targetGateway=0, confirmedSIGKILL=True,
                    replacementStarted=True, clientDrivenReconnect=True)
                if trim: evidence['journalTrim'] = trim
                private_json_snapshot(directory/'app-gateway-crash.json', evidence)
                return evidence
            result = run_app_canary(args, directory, lambda sql: fault_read_query(args, database, sql),
                gateway_crash=crash_app_gateway)
            result.update(ownedPostgresCleanupPending=True, qualityPassed=False)
            private_json(directory/'result.json', result)
            private_json_snapshot(directory/app_canary_selection(args)[2], result)
            return result
        print(f'{kind}: {NODES} Gateways ready; starting {manifest["users"]} connections',flush=True)
        barrier_path=directory/'scenario-start-barrier.json'
        failure_stage = 'workload'
        def loader_command(i, count, *, prefill=False):
            client_gateway = restart_canary.survivor if restart_canary else i % NODES
            command=[str(args.loader_binary),'--benchmark-wire-version',str(45 if kind=='baseline' else CANDIDATE_WIRE_VERSION),'--host','127.0.0.1','--port',str(args.gateway_port+client_gateway),
                     '--account-base-url',f'https://localhost:{args.https_port+client_gateway}',
                     '--server-name','localhost','--ca-path',str(actors/'ca/cert.pem'),
                     '--credentials',str(args.output_dir/f'part-{i}.jsonl'),'--report',str(directory/f'prefill-report-{i}.json' if prefill else directory/f'report-{i}.json'),
                     '--revision',kind,'--connections',str(count),'--ramp-per-second','200','--ramp-batch-size','32',
                     '--workload-ramp-per-second','16',
                     '--hold-seconds','60','--event-loops','1','--messages-per-second','0',
                     '--recovery-burst-workers',str(min(128,count)), '--max-inflight-messages-per-connection',str(1 if args.planned_reconnect_inflight_canary else 8),
                     '--message-bytes','128','--targets-per-connection',str(benchmark_targets_per_connection(prefill=prefill)),'--sync-reads','1','--room-log-reads','1',
                     '--room-log-initial-cursor','tail','--room-log-read-trigger','availability_hint',
                     '--peer-topology','ring','--max-rss-mb','1800','--max-failure-percent','0.1',
                     '--scenario',str(prefill_scenario if prefill else args.scenario),'--scenario-rate-scale',str(1/PARTS),
                     '--scenario-ready-path',str(directory/f'prefill-part-{i}-ready.json' if prefill else directory/f'part-{i}-ready.json'),
                     '--scenario-start-barrier-path',str(prefill_barrier if prefill else barrier_path)]
            if not restart_canary and not partition_canary:
                at = command.index('--hold-seconds')
                command[at:at] = ['--local-port-base', str(25000+(i//NODES)*10000)]
            if args.planned_reconnect_inflight_canary:
                command += ['--planned-reconnect-inflight-canary', '1']
            if args.room_notification_loss_canary:
                command += ['--room-notification-loss-canary', '1']
            if (partition_canary or args.room_host_restart_canary is not None or args.preclose_recovery_witness) and not prefill:
                command += ['--checkpoint-request-path', str(directory/f'checkpoint-request-{i}.json'),
                            '--checkpoint-response-path', str(directory/f'checkpoint-response-{i}.json')]
            return command

        if partition_canary:
            # Actual TCP prewrites precede the new physical channels, whose first
            # Ready can therefore carry H>0. No facts are seeded by SQL.
            failure_stage = 'partition_prefill'
            prefill_scenario = ROOT/'IMV2/load-scenarios/actor-realtime-partition-prefill-canary.json'
            prefill_barrier = directory/'prefill-start-barrier.json'
            prefill_loaders = []
            for index, count in enumerate(counts):
                command = loader_command(index, count, prefill=True)
                private_json(directory/f'prefill-command-{index}.json', command)
                prefill_loaders.append(start(command, f'prefill-load-{index}'))
            prefill_deadline = time.monotonic()+args.timeout_seconds
            armed = False
            while any(process.poll() is None for process in prefill_loaders):
                if any(process.poll() is not None for process in service_processes):
                    raise RuntimeError('partition_prefill_service_exited')
                if any(process.poll() not in (None, 0) for process in prefill_loaders):
                    raise RuntimeError('partition_prefill_loader_failed')
                if time.monotonic() >= prefill_deadline: raise TimeoutError('partition_prefill_timeout')
                paths = [directory/f'prefill-part-{index}-ready.json' for index in range(PARTS)]
                if not armed and all(path.exists() for path in paths):
                    parts = [json.loads(path.read_text()) for path in paths]
                    if any(part['activeConnections'] != count or part['requestedConnections'] != count
                           for part, count in zip(parts, counts)):
                        raise RuntimeError('partition_prefill_warmup_incomplete')
                    temporary = directory/'prefill-start-barrier.tmp'
                    private_json(temporary, dict(releaseAtUnixMilliseconds=int(time.time()*1000)+3000))
                    temporary.replace(prefill_barrier); armed = True
                time.sleep(2)
            prefill_reports = [json.loads((directory/f'prefill-report-{index}.json').read_text()) for index in range(PARTS)]
            prefill = summarize(prefill_reports, [process.returncode for process in prefill_loaders],
                                manifest['users'], False, 'partition-prefill')
            private_json(directory/'partition-prefill-result.json', prefill)
            if not prefill['qualityPassed']: raise RuntimeError('partition_prefill_quality_failed')
            heads = partition_prefill_head_proof(args, database)
            private_json(directory/'partition-prefill-head-proof.json', heads)
            if not heads['passed']: raise RuntimeError('partition_prefill_missing_nonzero_heads')
            # Do not reuse explicit TCP tuples from the prefill channels. Main
            # canary uses ephemeral ports, still the same connection population.
            failure_stage = 'workload'
        for i, count in enumerate(counts):
            command = loader_command(i, count)
            private_json(directory/f'command-{i}.json', command)
            loaders.append(start(command, f'load-{i}'))
        deadline=time.monotonic()+args.timeout_seconds
        barrier_released=False
        preclose_request = None
        preclose_terminal = False
        while any(p.poll() is None for p in loaders):
            if any(p.poll() is not None and not (restart_canary and restart_canary.permitted_exit(p))
                   for p in service_processes):
                raise RuntimeError('Gateway/Account/edge/broker exited during workload')
            first_failure = loader_report_drain.started is None
            if loader_report_drain.observe([p.poll() for p in loaders], time.monotonic()):
                raise TimeoutError('loader failure report collection deadline exceeded')
            if first_failure and loader_report_drain.started is not None:
                print(f'{kind}: loader failed; collecting peer reports for at most {loader_report_drain.seconds}s; run remains failed', flush=True)
            if time.monotonic()>deadline: raise TimeoutError('workload timeout; evidence retained')
            if not barrier_released and all((directory/f'part-{i}-ready.json').exists() for i in range(PARTS)):
                ready_parts=[json.loads((directory/f'part-{i}-ready.json').read_text()) for i in range(PARTS)]
                if any(r['activeConnections']!=count or r['requestedConnections']!=count for r,count in zip(ready_parts,counts)):
                    raise RuntimeError('scenario barrier requires every requested connection active')
                release=int(time.time()*1000)+3000
                temporary=directory/'scenario-start-barrier.tmp'
                private_json(temporary,dict(releaseAtUnixMilliseconds=release))
                temporary.rename(barrier_path)
                barrier_released=True
                print(f'{kind}: all {manifest["users"]} connections warm; common scenario barrier released',flush=True)
            if barrier_released and restart_canary:
                restart_canary.step(release/1000, gateways, restart_gateway)
            if barrier_released and partition_canary:
                partition_canary.step(release/1000, gateways)
            if args.preclose_recovery_witness and barrier_released and not preclose_terminal:
                try:
                    if preclose_request is None and time.time() >= release/1000 + args.preclose_measurement_end_offset:
                        preclose_request = preclose_witness_request(directory, counts)
                        preclose_request['scheduledMeasurementEndUnixSeconds'] = release/1000 + args.preclose_measurement_end_offset
                    if preclose_request is not None:
                        preclose_terminal = capture_preclose_witness(args, database, directory, loaders, counts, preclose_request) is True
                except Exception:
                    finish_preclose_witness(directory, 'diagnostic_read_failed')
                    preclose_terminal = True
            time.sleep(2)
        if args.preclose_recovery_witness:
            finish_preclose_witness(directory, 'loader_exited_or_response_missing_before_capture')
        if partition_canary and not partition_canary.recovered:
            partition_canary.persist()
            raise RuntimeError('partition_canary_did_not_complete')
        if restart_canary:
            if any(p.poll() is not None and not restart_canary.permitted_exit(p) for p in service_processes):
                raise RuntimeError('service_exited_at_restart_canary_completion')
            if not restart_canary.recovered:
                raise RuntimeError('restart_canary_did_not_complete')
        failure_stage = 'report_aggregation'
        loader_report_drain.observe([p.poll() for p in loaders], time.monotonic())
        reports=[json.loads((directory/f'report-{i}.json').read_text()) for i in range(PARTS) if (directory/f'report-{i}.json').exists()]
        expected_wire = 45 if kind == 'baseline' else CANDIDATE_WIRE_VERSION
        expected_algorithm = args.loader_algorithm_source_sha256
        if any(report.get('benchmarkWireVersion') != expected_wire or
               report.get('algorithmSourceSHA256') != expected_algorithm for report in reports):
            raise RuntimeError('Loader report wire adapter/common algorithm identity mismatch; no capacity comparison')
        result=summarize(reports,[p.returncode for p in loaders],manifest['users'], args.planned_reconnect_inflight_canary, args.measurement_phase)
        if args.planned_reconnect_inflight_canary:
            failure_stage = 'planned_reconnect_fact_drain'
            # Reports are complete; stop all real writers before the one fact
            # snapshot. This is the original 90s cleanup budget, not a second wait.
            stop_monitor.set()
            if thread.is_alive(): thread.join(timeout=10)
            if scheduling_thread is not None and scheduling_thread.is_alive(): scheduling_thread.join(timeout=10)
            service_stop_deadline = time.monotonic() + 90
            for process in service_processes:
                if process.poll() is None: process.send_signal(signal.SIGTERM)
            for process in service_processes:
                process.wait(timeout=max(.1, service_stop_deadline-time.monotonic()))
            if not wait_for_database_client_drain(args, database):
                raise RuntimeError('planned_reconnect_fact_clients_not_drained')
            try:
                facts = planned_reconnect_fact_proof(args, database, result['messagesAcknowledged'],
                    initial_facts_empty=initial_facts_empty)
            except Exception:
                facts = dict(passed=False, failureCode='fact_read_failed',
                    scope='aggregate fixture facts; not injected-operation identities or App automatic reconnect')
            private_json(directory/'fact-proof.json', facts)
            result['plannedReconnectFactProof'] = facts
            result['qualityPassed'] = result['qualityPassed'] and facts.get('passed') is True
        failure_stage = 'delivery_proof'
        result['foregroundDelivery']=verify_foreground_cursors(args,database,directory)
        result['qualityPassed']=result['qualityPassed'] and result['foregroundDelivery']['passed']
        if args.room_notification_loss_canary:
            proof = room_notification_loss_proof(reports, result['foregroundDelivery'])
            result['roomNotificationLossCanary'] = proof
            private_json(directory/'room-notification-loss-canary.json', proof)
            result['qualityPassed'] = result['qualityPassed'] and proof['passed']
        if args.room_host_restart_canary is not None:
            result['roomHostRestartCanary'] = dict(passed=restart_canary.recovered,
                naturalLeaseExpiry=True, roomActivationTakeoverProven=restart_canary.higher is not None,
                preKillPerConnectionReadyProven=restart_canary.before is not None,
                survivorChannelContinuityProven=restart_canary.after is not None,
                subsequentAppliedSequenceProven=restart_canary.recovered,
                clientDisconnectRecoveryProven=False, lateOldFenceInjectionProven=False)
            result['qualityPassed'] = result['qualityPassed'] and restart_canary.recovered
        elif restart_canary:
            result['realtimeHostRestartCanary'] = dict(passed=restart_canary.recovered,
                naturalLeaseExpiry=True, productionControllerUsed=True,
                clientDisconnectRecoveryProven=False, preKillPerConnectionReadyProven=False)
            result['qualityPassed'] = result['qualityPassed'] and restart_canary.recovered
        if partition_canary:
            result['actorPartitionCanary'] = dict(passed=partition_canary.recovered,
                sameProcess=True, naturalLeaseBoundary=True, preFaultNonzeroReady=True,
                heartbeatsContinued=True, majorityTakeover=True, productionControllerUsed=True)
            result['qualityPassed'] = result['qualityPassed'] and partition_canary.recovered
            # A provisional report cannot advertise acceptance before the real
            # fixture shutdown witness has settled in finally.
            result['productQualityPassed'] = result['qualityPassed']
            result.update(fixtureCleanupPending=True, fixtureQualified=False, qualityPassed=False)
        private_json(directory/'result.json',result)
        if loader_report_drain.started is not None:
            failure_stage = 'workload'
            raise RuntimeError('loader failed; bounded peer report collection completed')
        if not actor_proxy: print(json.dumps(dict(kind=kind,**result)),flush=True)
        return result
    except BaseException as error:
        failure_context = dict(failureStage=failure_stage,
                               failureCode='timeout' if isinstance(error, TimeoutError) else
                               'interrupted' if isinstance(error, (KeyboardInterrupt, SystemExit)) else 'run_failed')
        if str(error).startswith('fixture_unavailable:'):
            failure_context.update(fixtureUnavailable=True, fixtureFailureCode=str(error).split(':', 1)[1])
        private_json(directory/'failure.json',dict(error=str(error),exitCodes=[p.poll() for p in processes], **failure_context))
        raise
    finally:
        if args.preclose_recovery_witness:
            try: finish_preclose_witness(directory, 'workload_failed_before_live_capture')
            except OSError: pass
        stop_monitor.set()
        if thread.is_alive(): thread.join(timeout=10)
        if scheduling_thread is not None and scheduling_thread.is_alive(): scheduling_thread.join(timeout=10)
        if partition_canary:
            try: partition_canary.persist()
            except Exception:
                # Progress diagnostics must never prevent actual owned cleanup
                # or replace an already-raised product/fixture failure.
                if result is not None:
                    result.update(progressEvidenceFailed=True, qualityPassed=False)
                if failure_context is not None:
                    failure_context['progressEvidenceCode'] = 'progress_write_failed'
                print('partition_progress_evidence_write_failed', flush=True)
        app_forced_kills = 0
        service_forced_kills = 0
        cleanup_services = [proc for proc in processes
                            if proc is not (actor_proxy.process if actor_proxy else None)]
        service_cleanup_requested = {proc.pid for proc in cleanup_services if proc.poll() is None}
        app_cleanup_requested = {proc.pid for proc in processes if proc.poll() is None} if app_canary_enabled(args) else set()
        for proc in processes:
            if proc is not (actor_proxy.process if actor_proxy else None) and proc.poll() is None: proc.send_signal(signal.SIGTERM)
        deadline=service_stop_deadline if service_stop_deadline is not None else time.monotonic()+90
        for proc in processes:
            if actor_proxy and proc is actor_proxy.process: continue
            try: proc.wait(timeout=max(0.1,deadline-time.monotonic()))
            except subprocess.TimeoutExpired:
                proc.kill();proc.wait()
                service_forced_kills += 1
                if app_canary_enabled(args): app_forced_kills += 1
        # Aggregate lifecycle evidence only: no argv, environment, credentials
        # or database URLs. Loader drain is a separate quality witness.
        private_json_snapshot(directory/'service-cleanup.json', dict(
            settled=all(proc.poll() is not None for proc in cleanup_services),
            forcedKillCount=service_forced_kills,
            exitFailureCount=sum(proc.returncode != 0 for proc in cleanup_services),
            processes=[dict(ordinal=index, exitCode=proc.returncode,
                            terminationRequested=proc.pid in service_cleanup_requested)
                       for index, proc in enumerate(cleanup_services)]))
        private_json_snapshot(directory/'loader-report-collection.json',
            loader_report_drain.evidence(
                [index for index in range(PARTS) if (directory/f'report-{index}.json').exists()], PARTS))
        if app_canary_enabled(args) and result is not None:
            result['appFixtureCleanupPassed'] = result.get('fixtureCleanupPassed') is True
            exit_failures = sum(proc.returncode != 0 and not (proc.pid in app_expected_killed and proc.returncode == -signal.SIGKILL) and not (proc.pid in app_cleanup_requested
                and proc.returncode == -signal.SIGTERM) for proc in processes)
            result['ownedServicesCleanup'] = dict(settled=all(proc.poll() is not None for proc in processes),
                forcedKillCount=app_forced_kills, exitFailureCount=exit_failures)
            result['ownedServicesCleanupPassed'] = (result['ownedServicesCleanup']['settled']
                and app_forced_kills == 0 and exit_failures == 0)
            result.update(ownedPostgresCleanupPending=True, qualityPassed=False)
            private_json_snapshot(directory/'result.json', result)
            private_json_snapshot(directory/app_canary_selection(args)[2], result)
        # Keep the task-owned forwarding infrastructure until the actual owned
        # services finish their shutdown; it is never a production dependency.
        if actor_proxy:
            try:
                fixture_cleanup = actor_proxy.close(deadline=deadline)
            except Exception:
                # Unexpected diagnostic failures still invalidate the fixture;
                # they do not replace the original product failure or stage.
                fixture_cleanup = dict(passed=False, failureCode='proxy_cleanup_failed', ownedProcessSettled=False)
            if result is not None:
                apply_partition_fixture_cleanup(result, fixture_cleanup)
            try:
                private_json(directory/'fixture-cleanup.json', fixture_cleanup)
                if result is not None:
                    private_json_snapshot(directory/'result.json', result)
                    print(json.dumps(dict(kind=kind, **result)), flush=True)
            except Exception:
                if result is not None:
                    result['fixtureQualified'] = False; result['qualityPassed'] = False
                print('actor_proxy_cleanup_evidence_write_failed', flush=True)
        for stream in streams:stream.close()
        # run_revision unwinds before main stops its owned PostgreSQL. Preserve
        # failed-run evidence only after loader reports and service SQL drains
        # have settled; this must never convert the original raise into success.
        if failure_context is not None:
            diagnostics = dict(failure_context)
            if app_canary_enabled(args):
                private_json_snapshot(directory/'result.json', dict(qualityPassed=False,
                    appOutboxCanary=args.app_outbox_canary, appMultiDeviceCanary=args.app_multi_device_canary,
                    appRoomProgressCanary=getattr(args, 'app_room_progress_canary', False),
                    capacityAcceptance=False, failedRun=True, **failure_context))
                private_json(directory/'failure-diagnostics.json', diagnostics)
            else:
                reports = []
                for part in range(PARTS):
                    path = directory/f'report-{part}.json'
                    if path.exists():
                        try: reports.append(json.loads(path.read_text()))
                        except Exception: diagnostics['reportReadCode'] = 'report_decode_failed'
                try:
                    failed_result = summarize(reports, [p.poll() for p in loaders], manifest['users'], args.planned_reconnect_inflight_canary, args.measurement_phase)
                except Exception:
                    diagnostics['aggregateCode'] = 'aggregate_failed'
                    failed_result = dict(reportCount=len(reports), exitCodes=[p.poll() for p in loaders])
                failed_result.update(failure_context, qualityPassed=False, failedRun=True)
                if fixture_cleanup is not None: apply_partition_fixture_cleanup(failed_result, fixture_cleanup)
                try:
                    if not wait_for_database_client_drain(args, database):
                        diagnostics['databaseDrainCode'] = 'database_clients_not_drained'
                        raise RuntimeError('database_clients_not_drained')
                    if not (directory/'foreground-delivery-proof.json').exists():
                        failed_result['foregroundDelivery'] = verify_foreground_cursors(args, database, directory)
                    else:
                        failed_result['foregroundDelivery'] = json.loads((directory/'foreground-delivery-proof.json').read_text())
                except Exception: diagnostics['deliveryProofCode'] = 'delivery_proof_failed'
                try:
                    private_json_snapshot(directory/'result.json', failed_result)
                    private_json(directory/'failure-diagnostics.json', diagnostics)
                except Exception:
                    # Do not print exception text, or replace the original failure.
                    print('failed_run_evidence_write_failed', flush=True)
        if args.drop_disposable_databases:
            pg_env=dict(os.environ,PGHOST=args.pg_host,PGPORT=str(args.pg_port),PGUSER=args.pg_user)
            run_command(['dropdb',database],directory/'cleanup.log',pg_env)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixture',required=True,type=Path)
    parser.add_argument('--output-dir',required=True,type=Path,help='must not exist; never overwrite evidence')
    parser.add_argument('--baseline-checkout',type=Path, help='required for baseline/both; candidate-only defaults to current checkout')
    parser.add_argument('--baseline-binary',type=Path)
    parser.add_argument('--candidate-binary',required=True,type=Path)
    parser.add_argument('--baseline-account-binary',type=Path)
    parser.add_argument('--candidate-account-binary',required=True,type=Path)
    parser.add_argument('--loader-binary',required=True,type=Path,help='one Release binary used for both revisions')
    parser.add_argument('--nats-binary',type=Path,default=Path('/opt/homebrew/bin/nats-server'))
    parser.add_argument('--kind',choices=('baseline','candidate','both'),default='both')
    parser.add_argument('--candidate-event-loop-threads', type=int, choices=(1, 2), default=1,
                        help='candidate infrastructure/message EventLoops; non-message pools keep one loop')
    parser.add_argument('--candidate-actor-binary-invocations', choices=('enabled',), default='enabled',
                        help='Actor Protobuf transport requires binary distributed invocation framing')
    parser.add_argument('--candidate-message-write-prepared-queries', choices=('enabled', 'disabled'), default='enabled',
                        help='candidate bounded per-connection message SQL shape cache')
    parser.add_argument('--candidate-send-path-trace-mode', choices=('sampled', 'all'), default='sampled',
                        help='candidate detailed diagnostics: stable 1/64 operation sample or all slow requests')
    parser.add_argument('--candidate-message-write-connections', type=int, default=4,
                        help='candidate-only total message connections per node; divided across selected loops (default: 4)')
    parser.add_argument('--candidate-policy-control-connections', type=int, default=4,
                        help='candidate-only policy control connections per node (one control loop); default: 4')
    parser.add_argument('--candidate-authorization-mode', choices=('memory',), default='memory',
                        help='candidate requires memory policy owners')
    parser.add_argument('--scenario',type=Path,default=ROOT/'IMV2/load-scenarios/high-active-50000-uuid-ab-5000.json')
    parser.add_argument('--preclose-recovery-witness',action='store_true',help='candidate scaled diagnostic: bounded pre-close checkpoints and one read-only DB witness; never changes quality')
    parser.add_argument('--measurement-phase',help='exact measured scenario phase; inferred when there is one message phase')
    parser.add_argument('--pg-user',default=os.environ.get('USER',''))
    parser.add_argument('--pg-host',default='localhost');parser.add_argument('--pg-port',type=int,default=18532)
    parser.add_argument('--pg-bin-directory',type=Path,default=Path('/opt/homebrew/opt/postgresql@16/bin'))
    parser.add_argument('--shared-postgres',action='store_true',help='explicit existing cluster, must have at least 320 max_connections; never reconfigured')
    parser.add_argument('--gateway-port',type=int,default=18443);parser.add_argument('--actor-port',type=int,default=18337)
    parser.add_argument('--metrics-port',type=int,default=20464);parser.add_argument('--nats-port',type=int,default=18422)
    parser.add_argument('--recovery-scheduling-metrics', action='store_true',
                        help='sample fixed synchronous recovery spans separately; does not change load or quality gates')
    parser.add_argument('--account-port',type=int,default=18544);parser.add_argument('--https-port',type=int,default=18643)
    parser.add_argument('--timeout-seconds',type=int,default=1800)
    parser.add_argument('--loader-report-drain-seconds', type=int, choices=range(1, 601), default=120,
                        help='bounded peer report collection after a loader fails; quality still fails')
    diagnostic_mode = parser.add_mutually_exclusive_group()
    diagnostic_mode.add_argument('--allow-small-canary',action='store_true',help='small population is expressly excluded from capacity acceptance')
    diagnostic_mode.add_argument('--allow-scaled-diagnostic',action='store_true',help='scaled iteration workload; quality checks remain enabled, never formal capacity acceptance')
    parser.add_argument('--drop-disposable-databases',action='store_true')
    parser.add_argument('--actor-partition-canary', type=int, choices=range(NODES),
                        help='candidate <=500: silent native Actor-only isolation with live PG/client channels')
    parser.add_argument('--actor-proxy-port', type=int, default=19337)
    parser.add_argument('--room-host-restart-canary', type=int, choices=range(NODES),
                        help='owned candidate <=500: actual Room host SIGKILL, natural lease takeover, survivor Ready and subsequent TCP delivery')
    parser.add_argument('--room-host-auto-target', action='store_true',
                        help='room host canary: select the actual host with most Ready foreground rooms, excluding the fixed client Gateway')
    parser.add_argument('--room-notification-loss-canary', action='store_true',
                        help='owned candidate <=500: discard actual room body/H notifications; require heartbeat-driven cursor convergence')
    parser.add_argument('--realtime-host-restart-canary', type=int, choices=range(NODES),
                        help='candidate-only <=500-user production controller restart; clients stay on a surviving Gateway; natural TTL only')
    app_mode = parser.add_mutually_exclusive_group()
    app_mode.add_argument('--app-outbox-canary', action='store_true', help='explicit real App SQLite lost-ACK test; no Loader or capacity acceptance')
    app_mode.add_argument('--app-multi-device-canary', action='store_true', help='exact real App cross-Gateway device-scope test; no proxy or capacity acceptance')
    app_mode.add_argument('--app-room-progress-canary', action='store_true', help='real App decoded room body/H loss and heartbeat-driven durable SQLite recovery; no Loader or capacity acceptance')
    parser.add_argument('--app-journal-trim-canary', action='store_true', help='room-progress App mode: trim consumed control history while its Gateway is stopped, then verify cold rebuild')
    parser.add_argument('--app-xctestrun', type=Path)
    parser.add_argument('--app-derived-data', type=Path)
    parser.add_argument('--app-device-id')
    parser.add_argument('--app-trusted-ca', type=Path, help='CA already trusted by the explicitly owned simulator; runner never changes trust')
    parser.add_argument('--app-tls-certificate', type=Path)
    parser.add_argument('--app-tls-key', type=Path)
    parser.add_argument('--planned-reconnect-inflight-canary', action='store_true', help='explicit lost-ACK injection; requires small canary <=500 users; never capacity mode')
    args=parser.parse_args()
    if args.candidate_message_write_connections % args.candidate_event_loop_threads != 0:
        parser.error('message connections must divide evenly across candidate EventLoops')
    if not 1 <= args.candidate_message_write_connections <= 247:
        parser.error('candidate message connections must be in 1...247 (total workload capacity <=256)')
    if not 1 <= args.candidate_policy_control_connections <= 64:
        parser.error('candidate policy control connections must be in 1...64; process ceiling is checked at startup')
    if args.app_journal_trim_canary and not args.app_room_progress_canary:
        parser.error('--app-journal-trim-canary requires --app-room-progress-canary')
    if args.room_host_auto_target and args.room_host_restart_canary is None:
        parser.error('--room-host-auto-target requires --room-host-restart-canary')
    for name in ('fixture','output_dir','baseline_checkout','baseline_binary','candidate_binary','loader_binary','baseline_account_binary','candidate_account_binary','scenario','nats_binary'):
        if getattr(args,name) is not None:
            setattr(args,name,getattr(args,name).resolve())
    for name in ('app_xctestrun','app_derived_data','app_trusted_ca','app_tls_certificate','app_tls_key'):
        if getattr(args,name) is not None: setattr(args,name,getattr(args,name).resolve())
    scenario_phases = [] if app_canary_enabled(args) else json.loads(args.scenario.read_text())['phases']
    measured = [phase['name'] for phase in scenario_phases if phase.get('messagesPerSecond',0)>0]
    if args.measurement_phase is None and not app_canary_enabled(args):
        if len(measured)!=1:parser.error('multiple message phases require --measurement-phase')
        args.measurement_phase = measured[0]
    if not app_canary_enabled(args) and measured.count(args.measurement_phase)!=1:parser.error('measurement phase must uniquely name a message phase in the scenario')
    manifest=verify_fixture(args.fixture)
    try:
        room_notification_loss_constraints(args, manifest)
    except ValueError as error:
        parser.error(str(error))
    if app_canary_enabled(args):
        try: preflight_app_canary(args,manifest)
        except (ValueError, OSError) as error: parser.error(str(error))
    try:
        from v2_room_host_restart_canary import constraints as room_restart_constraints
        room_restart_constraints(args, manifest, scenario_phases)
        restart_canary_constraints(args, manifest, scenario_phases)
        partition_canary_constraints(args, manifest, scenario_phases)
    except ValueError as error:
        parser.error(str(error))
    if args.preclose_recovery_witness:
        if (args.kind != 'candidate' or not (args.allow_small_canary or args.allow_scaled_diagnostic)
                or app_canary_enabled(args) or args.actor_partition_canary is not None
                or args.realtime_host_restart_canary is not None or args.planned_reconnect_inflight_canary):
            parser.error('preclose witness requires candidate-only scaled/small diagnostic without other fault modes')
        args.preclose_measurement_end_offset = 0
        for phase in scenario_phases:
            args.preclose_measurement_end_offset += phase['durationSeconds']
            if phase['name'] == args.measurement_phase: break
    non_capacity = args.allow_small_canary or args.allow_scaled_diagnostic
    if manifest['users']!=50000 and not non_capacity:parser.error('capacity acceptance requires exactly 50000 users; use an explicit diagnostic mode for smaller workloads')
    if manifest['users']<PARTS:parser.error('fixture needs at least 12 users')
    if args.planned_reconnect_inflight_canary and (not args.allow_small_canary or manifest['users'] > 500):
        parser.error('inflight reconnect injection requires explicit small canary <=500 users')
    try:
        binaries = required_benchmark_binaries(args)
    except ValueError as error:
        parser.error(str(error))
    for binary in binaries:
        if not os.access(binary,os.X_OK):parser.error(f'not executable: {binary}')
    loader_contract = dict(appCanary=True, loaderUsed=False)
    args.loader_algorithm_source_sha256 = None
    if not app_canary_enabled(args):
        # Validate the actual executable before starting services or consuming ports.
        # SwiftPM build systems can emit separate native/Xcode products.
        try:
            loader_contract = json.loads(subprocess.check_output(
                [str(args.loader_binary), '--describe-message-transport'], text=True,
                stderr=subprocess.DEVNULL, timeout=10))
        except (subprocess.SubprocessError, ValueError):
            parser.error('loader executable does not describe its TCP message contract; check actual build output path')
        expected_transport = dict(contractVersion=3, plannedReconnectHandoff=True,
                                  messageTransport='tcp', messageRecoveryTransport='tcp_query',
                                  messageAttemptTimeoutSeconds=20, messageOperationTimeoutSeconds=60,
                                  messageMaximumAttempts=5)
        if any(loader_contract.get(key) != value for key, value in expected_transport.items()):
            parser.error('loader executable TCP message contract does not match the benchmark')
        if loader_contract.get('supportedBenchmarkWireVersions') != [45, CANDIDATE_WIRE_VERSION] or loader_contract.get('defaultWireVersion') != CANDIDATE_WIRE_VERSION:
            parser.error('loader must support reference wire45 and the generated current candidate protocol')
        if not re.fullmatch(r'[0-9a-f]{64}', loader_contract.get('algorithmSourceSHA256', '')):
            parser.error('loader must identify its fixed common algorithm source')
        common_source = (ROOT/'IMV2Server/Sources/IMV2GatewayLoadGenerator/main.swift').read_text()
        canonical_source = re.sub(r'(static let algorithmSourceSHA256 = ")[0-9a-f]{64}(")',
                                  r'\1ALGORITHM_SOURCE_SHA256\2', common_source)
        args.loader_algorithm_source_sha256 = hashlib.sha256(canonical_source.encode()).hexdigest()
        if loader_contract['algorithmSourceSHA256'] != args.loader_algorithm_source_sha256:
            parser.error('loader common algorithm hash differs from frozen source; build the exact measurement artifact')
    os.umask(0o077);args.output_dir.mkdir(mode=0o700)
    soft,hard=resource.getrlimit(resource.RLIMIT_NOFILE)
    resource.setrlimit(resource.RLIMIT_NOFILE,(hard,hard))
    evidence=dict(fixtureManifestSHA256=sha(args.fixture/'manifest.json'),fixture=manifest,
                  scenarioSHA256=sha(args.scenario),measurementPhase=args.measurement_phase,platform=platform.platform(),cpuCount=os.cpu_count(),
                  fdLimitBefore=soft,fdLimit=hard,nodes=NODES,loaderPartitions=0 if app_canary_enabled(args) else PARTS,
                  baselineBinarySHA256=sha(args.baseline_binary) if args.kind != 'candidate' else None,candidateBinarySHA256=sha(args.candidate_binary),
                  loaderBinarySHA256=sha(args.loader_binary),loaderContract=loader_contract,
                  benchmarkWireVersions=dict(baseline=45,candidate=CANDIDATE_WIRE_VERSION),
                  authorizationModes=dict(baseline='legacy', candidate=args.candidate_authorization_mode),
                  candidatePolicyControlConnectionsPerNode=args.candidate_policy_control_connections,
                  candidateMessageWriteConnectionsPerEventLoop=args.candidate_message_write_connections // args.candidate_event_loop_threads,
                  candidateMessageWriteConnectionsPerNode=args.candidate_message_write_connections,
                  candidateEventLoopThreads=args.candidate_event_loop_threads,
                  candidateDBTaskExecutor='event_loop',
                  candidateSendPathTraceMode=args.candidate_send_path_trace_mode,
                  candidateMessageWritePreparedQueries=args.candidate_message_write_prepared_queries,
                  candidateActorBinaryInvocations=args.candidate_actor_binary_invocations,
                  messageTransport='tcp',messageRecoveryTransport='tcp_query',
                  accountHTTPConnectionsPerHostSoftLimit=256,scenarioStartBarrier=not app_canary_enabled(args),
                  explicitLocalSourcePorts=not app_canary_enabled(args) and args.realtime_host_restart_canary is None and args.actor_partition_canary is None and args.room_host_restart_canary is None,
                  localSourcePortRange=[25000,44999] if not app_canary_enabled(args) and args.realtime_host_restart_canary is None and args.actor_partition_canary is None and args.room_host_restart_canary is None else None,
                  candidateWorkingDiffSHA256=hashlib.sha256(subprocess.check_output(['git','-C',str(ROOT),'diff','--binary','HEAD'])).hexdigest(),
                  candidateSourceFilesSHA256={str(p.relative_to(ROOT)):sha(p) for p in sorted((ROOT/'IMV2Server/Sources').rglob('*')) if p.is_file()},
                  baselineAccountBinarySHA256=sha(args.baseline_account_binary) if args.kind != 'candidate' else None,
                  candidateAccountBinarySHA256=sha(args.candidate_account_binary),
                  edgeSourceSHA256=sha(ROOT/'IMV2/scripts/v2_benchmark_https_edge.py'),canary=args.allow_small_canary,
                  scaledDiagnostic=args.allow_scaled_diagnostic,
                  plannedReconnectInflightCanary=args.planned_reconnect_inflight_canary,
                  realtimeHostRestartCanary=args.realtime_host_restart_canary,
                  roomHostRestartCanary=args.room_host_restart_canary,
                  actorPartitionCanary=args.actor_partition_canary,
                  appOutboxCanary=args.app_outbox_canary,
                  appMultiDeviceCanary=args.app_multi_device_canary,
                  appRoomProgressCanary=args.app_room_progress_canary,
                  appCanarySourceSHA256=sha(ROOT/('IMV2/scripts/'+app_canary_selection(args)[1]+'.py')) if app_canary_enabled(args) else None,
                  appProxySourceSHA256=sha(ROOT/'IMV2/scripts/v2_app_tcp_ack_cut_proxy.py') if args.app_outbox_canary else None,
                  appXctestrunSHA256=sha(args.app_xctestrun) if app_canary_enabled(args) else None,
                  appTrustedCASHA256=sha(args.app_trusted_ca) if app_canary_enabled(args) else None,
                  appTLSCertificateSHA256=sha(args.app_tls_certificate) if app_canary_enabled(args) else None,
                  appDeviceID=args.app_device_id if app_canary_enabled(args) else None,
                  actorProxySourceSHA256=sha(ROOT/'IMV2/scripts/v2_actor_network_partition_proxy.py') if args.actor_partition_canary is not None else None,
                  actorInterposeSourceSHA256=sha(ROOT/'IMV2/scripts/fixtures/v2_actor_connect_interpose.c') if args.actor_partition_canary is not None else None,
                  actorPartitionPrefillScenarioSHA256=sha(ROOT/'IMV2/load-scenarios/actor-realtime-partition-prefill-canary.json') if args.actor_partition_canary is not None else None,
                  baselineRevision=subprocess.check_output(['git','-C',str(args.baseline_checkout),'rev-parse','HEAD'],text=True).strip() if args.kind != 'candidate' else None,
                  configurationDefaultsSHA256=sha((args.baseline_checkout or ROOT)/'IMV2Server/.env.example'),
                  candidateRevision=subprocess.check_output(['git','-C',str(ROOT),'rev-parse','HEAD'],text=True).strip())
    private_json(args.output_dir/'evidence.json',evidence)
    actors,counts=prepare(args,manifest)
    pg_started=False
    args.owned_postgres_pid=None
    if not args.shared_postgres:
        args.pg_user='imv2_benchmark';args.pg_host='127.0.0.1'
        pg_directory=args.output_dir/'postgres'
        run_command([str(args.pg_bin_directory/'initdb'),'-D',str(pg_directory),'--auth=trust',
                     '--username',args.pg_user,'--no-locale'],args.output_dir/'postgres-init.log')
        (pg_directory/'postgresql.auto.conf').write_text("listen_addresses = '127.0.0.1'\n"
                     +f"port = {args.pg_port}\nmax_connections = 320\nunix_socket_directories = ''\n")
        run_command([str(args.pg_bin_directory/'pg_ctl'),'-D',str(pg_directory),'-l',
                     str(args.output_dir/'postgres.log'),'-w','start'],args.output_dir/'postgres-start.log')
        pg_started=True
        args.owned_postgres_pid=int((pg_directory/'postmaster.pid').read_text().splitlines()[0])
    else:
        pg_env=dict(os.environ,PGHOST=args.pg_host,PGPORT=str(args.pg_port),PGUSER=args.pg_user)
        ceiling=int(subprocess.check_output(['psql','-X','-At','-d','postgres','-c','SHOW max_connections'],env=pg_env,text=True))
        if ceiling<320:raise ValueError('shared PG max_connections below 320; use the default owned cluster')
    results = {}
    try:
        results={kind:run_revision(args,kind,actors,counts,manifest) for kind in (('baseline','candidate') if args.kind=='both' else (args.kind,))}
        if args.kind=='both':
            baseline=results['baseline']['acknowledgedMessagesPerSecond']
            ratio=results['candidate']['acknowledgedMessagesPerSecond']/baseline if baseline>0 else None
            private_json(args.output_dir/'comparison.json',dict(candidateToBaselineThroughputRatio=ratio,
                         minimumRatio=0.8,accepted=not non_capacity and manifest['users']==50000 and all(r['qualityPassed'] for r in results.values()) and ratio is not None and ratio>=0.8))
        if not app_canary_enabled(args) and not all(result['qualityPassed'] for result in results.values()):
            raise SystemExit(1)
        if args.kind == 'both' and not non_capacity and (ratio is None or ratio < 0.8):
            raise SystemExit(1)
    finally:
        postgres_cleanup_passed = False
        try:
            if pg_started:
                run_command([str(args.pg_bin_directory/'pg_ctl'),'-D',str(args.output_dir/'postgres'),
                             '-m','fast','-w','stop'],args.output_dir/'postgres-stop.log')
                postgres_cleanup_passed = True
        finally:
            if app_canary_enabled(args):
                for kind, result in results.items():
                    settle_app_cleanup_result(result, postgres_passed=postgres_cleanup_passed)
                    directory = args.output_dir/kind
                    private_json_snapshot(directory/'result.json', result)
                    private_json_snapshot(directory/app_canary_selection(args)[2], result)
    if app_canary_enabled(args) and (not results or not all(result['qualityPassed'] for result in results.values())):
        raise SystemExit(1)

if __name__=='__main__':main()
