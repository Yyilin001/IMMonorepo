"""Owned fixture data and aggregate evidence for real ClientKit capacity runs.

Only the isolated verifier imports this module. Random bearer values are returned
over its private HTTPS fixture route, never logged or placed in process arguments.
Production authentication, profile SQL, Actor authorization and byte delivery are
used after this initial database seed.
"""
import base64
from contextlib import contextmanager
from concurrent.futures import ThreadPoolExecutor
import hashlib
import hmac
import http.client
import json
import os
import subprocess
import threading
import time
import uuid
from v2_live_author_faults import AuthorByteRelay, AuthorProfileLock


class AuthorCapacityFixture:
    def __init__(self, count, sql, key, counts, counts_lock, processes=1, renewal_seconds=0, avatar_replacement=False, faults=False):
        self.count, self.sql, self.key = count, sql, base64.b64decode(key)
        self.counts, self.counts_lock = counts, counts_lock
        self.lock = threading.Lock()
        self.seeded = False
        self.processes = processes
        self.renewal_seconds = renewal_seconds
        self.avatar_replacement = avatar_replacement
        self.faults = faults
        self.relays = []
        self.profile_lock = AuthorProfileLock(sql) if faults else None
        self.fault_state = dict(started=False, active=False, released=False, sequence=None)
        self.fault_baseline = None
        self.fault_proof = None
        self.replacement_media = None
        self.population = None
        self.phases = {}
        self.metrics_ports = ()
        self.message_sequence = None
        self.byte_requests = dict(started=0, completed=0, totalSeconds=0, maximumSeconds=0)

    def byte_request_started(self):
        with self.lock:
            self.byte_requests['started'] += 1
        return time.monotonic()

    def byte_request_finished(self, started):
        elapsed = time.monotonic() - started
        with self.lock:
            self.byte_requests['completed'] += 1
            self.byte_requests['totalSeconds'] += elapsed
            self.byte_requests['maximumSeconds'] = max(self.byte_requests['maximumSeconds'], elapsed)

    def seed(self, command):
        if set(command) != {'author', 'device', 'token', 'media'}:
            raise ValueError('invalid seed fields')
        author, author_device, media = (str(uuid.UUID(command[k])) for k in ('author', 'device', 'media'))
        if not isinstance(command['token'], str) or not 16 <= len(command['token']) <= 4096:
            raise ValueError('invalid fixture credential')
        with self.lock:
            if self.seeded:
                raise ValueError('capacity fixture already seeded')
            self.seeded = True
        room = str(uuid.uuid4())
        viewers, rows = [], []
        # The real registered author is also a receiving participant. N means
        # exactly N room members/connections, not N viewers plus an extra author.
        for _ in range(self.count - 1):
            user, device = str(uuid.uuid4()), str(uuid.uuid4())
            token = base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip('=')
            digest = hmac.new(self.key, token.encode(), hashlib.sha256).hexdigest()
            viewers.append(dict(userID=user, deviceID=device, accessToken=token))
            rows.append(f"('{user}'::uuid,'{device}'::uuid,'{digest}')")
        self.sql(f"""BEGIN;
            CREATE TEMP TABLE capacity_seed(user_id uuid,device_id uuid,token_hmac text) ON COMMIT DROP;
            INSERT INTO capacity_seed VALUES {','.join(rows)};
            INSERT INTO im_v2.public_user_profiles(user_id,public_handle,display_name,created_at,updated_at)
                SELECT user_id,replace(user_id::text,'-',''),'Capacity viewer',now(),now() FROM capacity_seed;
            INSERT INTO im_v2.auth_devices(user_id,device_id,created_at,last_active_at,session_expires_at)
                SELECT user_id,device_id,now(),now(),now()+interval '1 hour' FROM capacity_seed;
            INSERT INTO im_v2.device_access_tokens(token_hmac,user_id,device_id,issued_at,expires_at)
                SELECT token_hmac,user_id,device_id,now(),now()+interval '1 hour' FROM capacity_seed;
            INSERT INTO im_v2.shard_admission_pools(room_shard_id,capacity_profile_id,lease_id,generation,valid_until,command_window_limit)
                VALUES('rooms-primary','standard',gen_random_uuid(),1,now()+interval '1 hour',1000) ON CONFLICT DO NOTHING;
            INSERT INTO im_v2.rooms(room_id,room_shard_id,capacity_profile_id,capacity_class,membership_revision)
                VALUES('{room}','rooms-primary','standard','large',1);
            INSERT INTO im_v2.room_owner_routes(room_id,room_shard_id,route_epoch,created_at,updated_at)
                VALUES('{room}','rooms-primary',0,now(),now());
            INSERT INTO im_v2.group_rooms(room_id,owner_user_id,title,created_at)
                VALUES('{room}','{author}','Author capacity acceptance',now());
            INSERT INTO im_v2.room_memberships(room_id,user_id,joined_revision,role)
                SELECT '{room}',user_id,1,'member' FROM capacity_seed;
            INSERT INTO im_v2.room_memberships(room_id,user_id,joined_revision,role)
                VALUES('{room}','{author}',1,'owner');
            INSERT INTO im_v2.room_admission(room_id,eligible_member_count,command_window_limit,shard_lease_id,shard_lease_generation)
                SELECT '{room}',{self.count},command_window_limit,lease_id,generation FROM im_v2.shard_admission_pools
                WHERE room_shard_id='rooms-primary' AND capacity_profile_id='standard';
            COMMIT;""")
        with self.lock:
            self.population = dict(roomID=room, authorUserID=author, mediaID=media,
                credentials=[dict(userID=author, deviceID=author_device, accessToken=command['token'])] + viewers)
        return dict(ready=True)

    def assignment(self, command):
        if set(command) != {'process'}:
            raise ValueError('invalid assignment fields')
        index = int(command['process'])
        if not 0 <= index < self.processes:
            raise ValueError('invalid process index')
        with self.lock:
            if self.population is None:
                return dict(ready=False)
            seed = {k: v for k, v in self.population.items() if k != 'credentials'}
            # Contiguous disjoint partitions, including the real author in process 0.
            seed['credentials'] = self.population['credentials'][index*self.count//self.processes:(index+1)*self.count//self.processes]
            return dict(ready=True, seed=seed)

    def barrier(self, command):
        if set(command) != {'process', 'phase', 'participants', 'httpAttempts'}:
            raise ValueError('invalid barrier fields')
        index, participants, attempts = (int(command[k]) for k in ('process', 'participants', 'httpAttempts'))
        phases = (('authenticated', 'cold', 'warm') + (('renewed',) if self.renewal_seconds else ())
                  + (('fault_ready', 'fault_healthy', 'fault_recovered') if self.faults else ())
                  + ('changed',) + (('avatar_changed',) if self.avatar_replacement else ()) + ('bytes',))
        phase = command['phase']
        if not 0 <= index < self.processes or phase not in phases or attempts < 0:
            raise ValueError('invalid barrier state')
        expected = (index+1)*self.count//self.processes - index*self.count//self.processes
        if phase == 'fault_healthy':
            expected -= 1  # Exactly one separately paused connection per process.
        if participants != expected:
            raise ValueError('incomplete participant partition')
        with self.lock:
            previous = phases.index(phase) - 1
            if self.population is None or (previous >= 0 and not self.phases.get(phases[previous], {}).get('ready')):
                raise ValueError('barrier phase was skipped')
            if phase == 'avatar_changed' and self.replacement_media is None:
                raise ValueError('avatar replacement was not published')
            if phase == 'fault_healthy' and (self.fault_state['sequence'] is None or not self.profile_lock.is_held()):
                raise ValueError('healthy progress was not observed during the profile fault')
            if phase == 'fault_recovered' and not self.fault_state['released']:
                raise ValueError('fault release was skipped')
            value = self.phases.setdefault(phase, dict(arrivals={}, ready=False))
            report = dict(participants=participants, httpAttempts=attempts)
            if index in value['arrivals'] and value['arrivals'][index] != report:
                raise ValueError('barrier report changed')
            value['arrivals'][index] = report
            if len(value['arrivals']) == self.processes and not value['ready']:
                observed = time.monotonic()
                value['statistics'] = self.statistics()
                # All clients have finished this phase and none can enter the
                # next one yet. Capture each node once at this boundary, rather
                # than attributing a five-second sample spanning cold + history
                # to cold reads alone. Servers may still finish background work.
                if self.metrics_ports:
                    with ThreadPoolExecutor(max_workers=len(self.metrics_ports)) as readers:
                        nodes = list(readers.map(self.gateway_metrics, self.metrics_ports))
                    value['observation'] = dict(gatewayNodes=nodes,
                        metricsComplete=all('errorType' not in node for node in nodes),
                        captureSeconds=time.monotonic() - observed)
                value['participants'] = sum(v['participants'] for v in value['arrivals'].values())
                value['httpAttempts'] = sum(v['httpAttempts'] for v in value['arrivals'].values())
                value['ready'] = True
            # Diagnostic snapshots stay in the local artifact, not in every
            # client's fixture response. Existing elapsed logs include barrier
            # observation time; record that overhead instead of hiding it.
            return {k: v for k, v in value.items() if k not in ('arrivals', 'observation')}

    def message(self, command):
        if command:
            if set(command) != {'process', 'sequence'} or int(command['process']) != 0:
                raise ValueError('only the author process publishes a receipt')
            sequence = int(command['sequence'])
            if not 0 < sequence <= 2**63-1:
                raise ValueError('invalid receipt sequence')
            with self.lock:
                if not self.phases.get('cold', {}).get('ready') or self.message_sequence not in (None, sequence):
                    raise ValueError('invalid message publication phase')
                self.message_sequence = sequence
        with self.lock:
            return dict(ready=self.message_sequence is not None, sequence=self.message_sequence)

    def evidence(self):
        with self.lock:
            return {phase: {k: v for k, v in value.items() if k != 'arrivals'}
                    for phase, value in self.phases.items()}

    def fault(self, command):
        if not self.faults:
            raise ValueError('fault scenario is disabled')
        if command is None:
            with self.lock:
                return dict(self.fault_state)
        if command.get('process') != '0':
            raise ValueError('only the author process controls faults')
        action = command.get('action')
        expected = {'process', 'action', 'sequence'} if action == 'message' else {'process', 'action'}
        if set(command) != expected:
            raise ValueError('invalid fault fields')
        if action == 'start':
            with self.lock:
                if self.fault_state['started'] or not self.phases.get('fault_ready', {}).get('ready'):
                    raise ValueError('invalid fault start phase')
                self.fault_state['started'] = True
            self.fault_baseline = self._fault_metrics()
            self.profile_lock.start(10)
            for relay in self.relays:
                relay.pause(10)
            with self.lock:
                self.fault_state['active'] = True
        elif action in ('probe', 'message'):
            with self.lock:
                if not self.fault_state['active']:
                    raise ValueError('fault is not active')
            metrics = self._fault_metrics()
            proof = dict(lockHeld=self.profile_lock.is_held(),
                nonwritableDeferrals=metrics['nonwritableDeferrals'] - self.fault_baseline['nonwritableDeferrals'],
                controlFailures=metrics['controlFailures'] - self.fault_baseline['controlFailures'],
                relays=[relay.snapshot() for relay in self.relays], gatewayNodes=metrics['gatewayNodes'])
            ready = (proof['lockHeld'] and proof['nonwritableDeferrals'] > 0 and proof['controlFailures'] > 0
                     and all(row['paused'] and row['threadAlive'] and row['errorType'] is None for row in proof['relays']))
            if action == 'probe':
                return dict(ready=ready, lockHeld=proof['lockHeld'])
            sequence = int(command['sequence'])
            if not ready or not 0 < sequence <= 2**63-1:
                raise ValueError('message progress lacks simultaneous real fault evidence')
            with self.lock:
                if self.fault_state['sequence'] not in (None, sequence):
                    raise ValueError('fault receipt cannot change')
                self.fault_state['sequence'] = sequence
                self.fault_proof = proof
        elif action == 'release':
            with self.lock:
                if not self.phases.get('fault_healthy', {}).get('ready') or self.fault_state['released']:
                    raise ValueError('invalid fault release phase')
            for relay in self.relays:
                relay.resume()
            self.profile_lock.close()
            if self.profile_lock.snapshot()['errorType'] is not None:
                raise RuntimeError('owned profile fault failed')
            with self.lock:
                self.fault_state.update(active=False, released=True)
        else:
            raise ValueError('invalid fault action')
        return self.fault(None)

    def _fault_metrics(self):
        with ThreadPoolExecutor(max_workers=len(self.metrics_ports)) as readers:
            nodes = list(readers.map(self.gateway_metrics, self.metrics_ports))
        if any('errorType' in node for node in nodes):
            raise RuntimeError('fault metrics are incomplete')
        failures = ('im_v2_author_read_' + stage + '_control_failures_total' for stage in ('initial', 'final', 'delivery'))
        names = tuple(failures)
        limits = dict(pending_keys=128, pending_bytes=262144, reading_batches=4, writing_frames=4,
                      output_bytes=262144, ingress_pending=256, ingress_keys=1024)
        for node in nodes:
            for name, limit in limits.items():
                observed = node.get('authors', {}).get('im_v2_author_' + name)
                if observed is None or not 0 <= observed <= limit:
                    raise RuntimeError('author budget evidence is missing or exceeded')
        return dict(gatewayNodes=nodes,
            nonwritableDeferrals=sum(sum(node.get('headDelivery', {}).values()) for node in nodes),
            controlFailures=sum(node.get('authors', {}).get(name, 0) for node in nodes for name in names))

    def avatar(self, command):
        if not self.avatar_replacement:
            raise ValueError('avatar replacement is disabled')
        if command is not None:
            if set(command) != {'process', 'media'} or command['process'] != '0':
                raise ValueError('only the author process publishes a replacement')
            media = str(uuid.UUID(command['media']))
            with self.lock:
                if (not self.phases.get('changed', {}).get('ready') or self.population is None
                        or media == self.population['mediaID'] or self.replacement_media not in (None, media)):
                    raise ValueError('invalid avatar publication phase')
                self.replacement_media = media
        with self.lock:
            return dict(ready=self.replacement_media is not None, media=self.replacement_media)

    def run_clients(self, root, output, environment, stop, metrics_ports, gateway_ports, configuration):
        if not 1 <= len(metrics_ports) <= 4:
            raise ValueError('invalid capacity metrics topology')
        self.metrics_ports = tuple(metrics_ports)
        # Compile once, then run independent executables against one shared room.
        # No raw credential is written to a file or passed as a command argument.
        with (output / 'capacity-client-build.log').open('w') as log:
            # The opt-in suite shares @testable fixtures with normal tests.
            # Keep -O in release while allowing those internal imports.
            subprocess.run(['swift', 'build', '--configuration', configuration, '--build-tests',
                            '-Xswiftc', '-enable-testing', '--disable-automatic-resolution', '--jobs', '4'],
                cwd=root / 'IMV2ClientKit', env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
        from pathlib import Path
        swift = Path(subprocess.check_output(['xcrun', '--find', 'swift'], text=True).strip())
        helper = swift.parent.parent / 'libexec/swift/pm/swiftpm-testing-helper'
        platform = Path(subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-platform-path'], text=True).strip())
        binary = Path(subprocess.check_output(['swift', 'build', '--configuration', configuration, '--show-bin-path'],
            cwd=root / 'IMV2ClientKit', env=environment, text=True).strip())
        bundle = binary / 'IMV2ClientKitTests.xctest/Contents/MacOS/IMV2ClientKitTests'
        if not helper.is_file() or not bundle.is_file():
            raise RuntimeError('current native Swift Testing runner is unavailable')
        children, logs = [], []
        try:
            with self.monitor(metrics_ports, output):
                (output / 'capacity-topology.json').write_text(json.dumps(dict(
                    gatewayProcesses=len(gateway_ports),
                    renewalSeconds=self.renewal_seconds,
                    avatarReplacement=self.avatar_replacement,
                    profileFaultAndSlowConnections=self.faults,
                    clientAssignments=[dict(process=index, gateway=index % len(gateway_ports),
                        participants=(index + 1) * self.count // self.processes - index * self.count // self.processes)
                        for index in range(self.processes)]), indent=2) + '\n')
                for index in range(self.processes):
                    log = (output / f'client-{index}.log').open('w'); logs.append(log)
                    env = dict(environment, IMV2_LIVE_AUTHOR_PROCESS=str(index),
                               IMV2_LIVE_AUTHOR_PROCESSES=str(self.processes),
                               IMV2_LIVE_RESOURCE_GATEWAY_PORT=str(gateway_ports[index % len(gateway_ports)]),
                               DYLD_FRAMEWORK_PATH=str(platform / 'Developer/Library/Frameworks'),
                               DYLD_LIBRARY_PATH=str(platform / 'Developer/usr/lib'))
                    if self.faults:
                        relay = AuthorByteRelay(gateway_ports[index % len(gateway_ports)])
                        self.relays.append(relay)
                        env['IMV2_LIVE_AUTHOR_SLOW_GATEWAY_PORT'] = str(relay.port)
                    # SwiftPM holds its package lock through test execution.
                    # Invoke the same installed runner/bundle directly after
                    # the shared build so these really are concurrent clients.
                    child = subprocess.Popen([str(helper), '--test-bundle-path', str(bundle),
                        '--filter', 'V2LiveAuthorCapacityTests', str(bundle), '--testing-library', 'swift-testing',
                        '--no-parallel'], cwd=root / 'IMV2ClientKit',
                        env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                    child._owned_process_group = child.pid
                    children.append(child)
                (output / 'capacity-client-processes.json').write_text(json.dumps([p.pid for p in children]) + '\n')
                deadline = time.monotonic() + 1200
                while True:
                    codes = [p.poll() for p in children]
                    if all(code == 0 for code in codes) or any(code not in (None, 0) for code in codes):
                        break
                    if time.monotonic() >= deadline:
                        raise TimeoutError('owned capacity clients exceeded their run budget')
                    time.sleep(.2)
        finally:
            failures = []
            for child in reversed(children):
                try: stop(child)
                except Exception as error: failures.append(type(error).__name__)
            if self.profile_lock is not None:
                try: self.profile_lock.close()
                except Exception as error: failures.append(type(error).__name__)
            for relay in self.relays:
                try: relay.close()
                except Exception as error: failures.append(type(error).__name__)
            if self.faults:
                (output / 'capacity-faults.json').write_text(json.dumps(dict(
                    state=self.fault_state, proof=self.fault_proof,
                    profileLock=self.profile_lock.snapshot(), relays=[r.snapshot() for r in self.relays]), indent=2) + '\n')
            for log in logs: log.close()
            (output / 'capacity-phases.json').write_text(json.dumps(self.evidence(), indent=2) + '\n')
            with (output / 'client.log').open('w') as combined:
                for index in range(len(children)):
                    combined.write(f'Client process {index}\n' + (output / f'client-{index}.log').read_text())
            codes = [p.poll() for p in children]
            (output / 'capacity-client-cleanup.json').write_text(json.dumps(dict(
                exitCodes=codes, failureCount=len(failures), processGroupsDrained=not failures), indent=2) + '\n')
            if failures:
                raise RuntimeError('owned capacity client cleanup failed')
        return 0 if len(codes) == self.processes and all(code == 0 for code in codes) else 1

    @contextmanager
    def monitor(self, metrics_ports, output):
        """Keep bounded, payload-free evidence even when authentication fails."""
        stopped = threading.Event()
        started = time.monotonic()

        def sample():
            with (output / 'capacity-runtime-samples.jsonl').open('x') as log:
                while not stopped.is_set():
                    value = dict(elapsedSeconds=time.monotonic() - started)
                    with self.lock:
                        value['byteProxy'] = dict(self.byte_requests)
                    try:
                        value['database'] = json.loads(self.sql("""SELECT json_build_object(
                            'authenticationCalls',coalesce(sum(calls) FILTER (WHERE query LIKE 'SELECT token.user_id, LEAST(token.expires_at, device.session_expires_at)%'),0),
                            'authenticationExecutionMilliseconds',coalesce(sum(total_exec_time) FILTER (WHERE query LIKE 'SELECT token.user_id, LEAST(token.expires_at, device.session_expires_at)%'),0),
                            'activity',(SELECT coalesce(json_agg(s),'[]') FROM (
                                SELECT state,wait_event_type,wait_event,count(*) AS count
                                FROM pg_stat_activity WHERE datname=current_database()
                                GROUP BY state,wait_event_type,wait_event) s)
                            ) FROM pg_stat_statements;""", timeout=5))
                    except Exception as error:
                        value['databaseErrorType'] = type(error).__name__
                    nodes = [self.gateway_metrics(port) for port in metrics_ports]
                    value['gatewayNodes'] = nodes
                    value['metricsComplete'] = all('errorType' not in node for node in nodes)
                    for kind in ('gateway', 'authors', 'connectionClosures'):
                        value[kind] = self.aggregate_metric_nodes(nodes, kind)
                    log.write(json.dumps(value) + '\n'); log.flush()
                    stopped.wait(5)

        worker = threading.Thread(target=sample, name='owned-capacity-monitor')
        worker.start()
        try:
            yield
        finally:
            stopped.set()
            worker.join(timeout=6 + 6 * len(metrics_ports))
            if worker.is_alive():
                raise RuntimeError('owned capacity monitor did not drain')
            # A cold burst can fail between five-second samples. Capture the
            # still-live servers before fixture teardown without querying data.
            nodes = [self.gateway_metrics(port) for port in metrics_ports]
            (output / 'capacity-final-metrics.json').write_text(json.dumps(dict(
                elapsedSeconds=time.monotonic() - started, gatewayNodes=nodes,
                metricsComplete=all('errorType' not in node for node in nodes)), indent=2) + '\n')

    @staticmethod
    def aggregate_metric_nodes(nodes, kind):
        aggregate = {}
        for node in nodes:
            for name, number in node.get(kind, {}).items():
                # A maximum over nodes is not the sum of their maxima. Keep
                # per-node evidence alongside aggregate counters and gauges.
                if name.endswith('_max_lifetime'):
                    aggregate[name] = max(aggregate.get(name, 0), number)
                else:
                    aggregate[name] = aggregate.get(name, 0) + number
        return aggregate

    @staticmethod
    def gateway_metrics(port):
        connection = http.client.HTTPConnection('127.0.0.1', port, timeout=3)
        value = {}
        try:
            connection.request('GET', '/metrics')
            response = connection.getresponse()
            if response.status != 200:
                raise ValueError('metrics response failed')
            metrics, closures, rooms, heads = {}, {}, {}, {}
            # Keep owner pressure beside each gateway's measurements. Peaks
            # from different nodes are deliberately not added into a fake
            # global simultaneous peak. Only exact, unlabeled series qualify.
            room_series = {'im_v2_room_actor_' + suffix for suffix in (
                'pending_resolutions', 'active_resolutions', 'resolution_waiters',
                'active_rooms', 'pending_rooms', 'restoring_rooms', 'retiring_rooms',
                'activation_waiters', 'outstanding_commands', 'outstanding_bytes',
                'peak_outstanding_commands', 'peak_outstanding_bytes', 'reservations',
                'recovering_rooms', 'active_host_recoveries', 'cached_call_attempts_total',
                'cached_call_responses_total', 'cached_call_misses_total',
                'cached_local_calls_total', 'cached_remote_calls_total',
                'physical_lookups_total', 'business_invocations_total', 'reference_misses_total')}
            # Only the transport contract's finite reason set is retained.
            # Connection loss can otherwise look like an author-change timeout.
            closure_series = {
                'im_v2_gateway_connection_closures_total{reason="' + reason + '"}': reason
                for reason in ('peer_disconnected', 'connection_limit', 'authentication_timeout',
                    'idle_timeout', 'inbound_queue_limit', 'frame_limit_violation', 'request_failure',
                    'required_notification_backpressure', 'required_notification_write_timeout', 'device_revoked')
            }
            for line in response.read(2 * 1024 * 1024).decode().splitlines():
                if not line or line.startswith('#'):
                    continue
                name = line.split('{', 1)[0].split(' ', 1)[0]
                series, number = line.rsplit(' ', 1)
                if series == 'im_v2_room_subscription_head_delivery_total{stage="socketNotWritable"}':
                    heads['socketNotWritable'] = float(number)
                if series == 'im_v2_gateway_foreground_nonwritable_deferrals_total':
                    heads['foregroundNonwritable'] = float(number)
                if series in closure_series:
                    closures[closure_series[series]] = float(number)
                if series in room_series:
                    rooms[series] = float(number)
                # Different histogram bounds cannot be collapsed into one
                # scalar. Preserve their sum/count series, not summed buckets.
                if name.endswith('_bucket'):
                    continue
                if name.startswith(('im_v2_gateway_active_', 'im_v2_gateway_transport_',
                                    'im_v2_account_initialization_', 'im_v2_database_work_',
                                    'im_v2_database_pool_loan_', 'im_v2_gateway_journal_recovery_')):
                    # Strip all labels; evidence contains aggregate numbers only.
                    metrics[name] = metrics.get(name, 0) + float(line.rsplit(' ', 1)[1])
            value['gateway'] = metrics
            value['connectionClosures'] = closures
            value['rooms'] = rooms
            value['headDelivery'] = heads
            connection.request('GET', '/metrics/authors')
            response = connection.getresponse()
            if response.status != 200:
                raise ValueError('author metrics response failed')
            value['authors'] = {parts[0]: float(parts[1])
                for line in response.read(128 * 1024).decode().splitlines()
                if line.startswith('im_v2_author_') and len(parts := line.split()) == 2}
        except Exception as error:
            value['errorType'] = type(error).__name__
        finally:
            connection.close()
        return value

    def statistics(self):
        # pg_stat_statements stores normalized SQL, but only aggregate numbers
        # leave the owned database; no SQL text, token, URL or user ID is logged.
        result = json.loads(self.sql("""SELECT json_build_object(
            'publicSourceBatches',coalesce(sum(calls) FILTER (WHERE query LIKE 'SELECT p.user_id,p.revision,p.public_handle,p.display_name,p.account_kind%'),0),
            'publicSourceRows',coalesce(sum(rows) FILTER (WHERE query LIKE 'SELECT p.user_id,p.revision,p.public_handle,p.display_name,p.account_kind%'),0),
            'controlBatches',coalesce(sum(calls) FILTER (WHERE query LIKE 'WITH requested AS MATERIALIZED%' AND query LIKE '%identity.session_expires_at AS device_expires_at%'),0),
            'roomProfileBatches',coalesce(sum(calls) FILTER (WHERE query LIKE 'WITH requested AS MATERIALIZED (%' AND query LIKE '%nickname_revision%'),0),
            'roomProfileRows',coalesce(sum(rows) FILTER (WHERE query LIKE 'WITH requested AS MATERIALIZED (%' AND query LIKE '%nickname_revision%'),0),
            'roomProfileExecutionMilliseconds',coalesce(sum(total_exec_time) FILTER (WHERE query LIKE 'WITH requested AS MATERIALIZED (%' AND query LIKE '%nickname_revision%'),0)
            ) FROM pg_stat_statements;"""))
        with self.counts_lock:
            result['profileHTTP'] = sum(n for (m, p, s), n in self.counts.items()
                                        if p == '/v2/profile-presentations/batch')
            result['successfulByteHTTP'] = sum(n for (m, p, s), n in self.counts.items()
                                               if m == 'GET' and 200 <= s < 300
                                               and ('/resource-bytes/' in p or '/local-media/' in p))
        return result
