"""Owned Room host SIGKILL witness, independent of Journal partition recovery.

Read callbacks enforce read-only SQL and deadlines. Artifacts contain identities
and progress, never credentials or message bodies. This does not claim client
disconnect recovery: all client channels intentionally remain on a survivor.
"""
import json
import signal
import time
import uuid


def constraints(args, manifest, phases):
    target = getattr(args, 'room_host_restart_canary', None)
    if target is None:
        return
    if (args.kind != 'candidate' or not args.allow_small_canary or manifest['users'] > 500
            or args.shared_postgres or args.allow_scaled_diagnostic
            or args.realtime_host_restart_canary is not None
            or args.actor_partition_canary is not None or args.planned_reconnect_inflight_canary
            or args.app_outbox_canary or args.app_multi_device_canary
            or getattr(args, 'preclose_recovery_witness', False)):
        raise ValueError('room restart requires an owned candidate-only small fixture and no other fault')
    quiet = phases[0] if phases else {}
    if (quiet.get('name') != 'room-host-natural-recovery' or quiet.get('durationSeconds') != 120
            or any(quiet.get(key, 0) != 0 for key in
                   ('messagesPerSecond', 'roomLogReadsPerSecond', 'syncPullsPerSecond'))
            or any(phase.get('reconnectPercentPerMinute', 0) != 0 for phase in phases)
            or not any(phase.get('messagesPerSecond', 0) > 0 for phase in phases[1:])):
        raise ValueError('room restart requires 120s natural recovery followed by actual TCP sends')


def lease_snapshot(read, rooms):
    keys = ','.join("'" + str(uuid.UUID(room)) + "'::uuid" for room in sorted(set(rooms)))
    if not keys or len(rooms) > 500:
        raise ValueError('invalid room witness keys')
    return json.loads(read(f"""SELECT json_build_object(
      'databaseNow',extract(epoch FROM clock_timestamp()),
      'leases',coalesce((SELECT json_agg(json_build_object(
        'roomID',l.room_id::text,'epoch',l.activation_epoch,
        'ownerShard',l.owner_shard_id,'ownerEpoch',l.owner_epoch,
        'hostID',l.host_id,'incarnation',l.host_incarnation_id::text,
        'expiresAt',extract(epoch FROM l.expires_at),'head',r.room_sequence))
        FROM im_v2.room_activation_leases l JOIN im_v2.rooms r USING(room_id)
        WHERE l.room_id IN ({keys})), '[]'::json))"""))


def takeover_proven(initial, last_old, snapshot):
    rows = snapshot.get('leases', [])
    if len(rows) != 1:
        return False
    row = rows[0]
    return (row['roomID'] == initial['roomID'] and row['epoch'] > initial['epoch']
            and row['ownerShard'] == initial['ownerShard'] and row['ownerEpoch'] == initial['ownerEpoch']
            and row['incarnation'] is not None and row['incarnation'] != initial['incarnation']
            and row['expiresAt'] is not None and row['expiresAt'] > snapshot['databaseNow']
            and snapshot['databaseNow'] >= last_old['expiresAt'])


def physical_host_matches(value, expected):
    try:
        return uuid.UUID(value) == uuid.UUID(expected)
    except (ValueError, TypeError, AttributeError):
        return False


class RoomHostRestartCanary:
    def __init__(self, args, directory, counts, read, persist, matches_request, ready, continuity, target_host_id, host_ids=None):
        self.target = args.room_host_restart_canary
        self.survivor = (self.target + 1) % 6
        self.target_host_id = str(uuid.UUID(target_host_id))
        self.host_ids = host_ids if getattr(args, 'room_host_auto_target', False) else None
        if self.host_ids is not None and self.survivor not in self.host_ids:
            raise ValueError('room_restart_invalid_host_map')
        self.directory, self.counts, self.read = directory, counts, read
        self.save, self.matches_request, self.ready, self.continuity = persist, matches_request, ready, continuity
        self.before = self.after = None
        self.initial = self.last_old = self.higher = None
        self.candidates = {}
        self.last_old_by_room = {}
        self.selected_room = None
        self.old_process = self.restart_process = None
        self.request = None
        self.recovered = False
        self.deadline = self.kill_monotonic = None
        self.samples = []

    def permitted_exit(self, process):
        return process is self.old_process and process.poll() == -signal.SIGKILL

    def checkpoint(self):
        if self.request is None:
            nonce, stamp = str(uuid.uuid4()), int(time.time() * 1000)
            self.request = nonce, stamp, time.monotonic() + 10
            for index in range(len(self.counts)):
                self.save(self.directory / f'checkpoint-request-{index}.json',
                          dict(nonce=nonce, requestedAtUnixMilliseconds=stamp))
            return None
        nonce, stamp, deadline = self.request
        parts = []
        for index in range(len(self.counts)):
            path = self.directory / f'checkpoint-response-{index}.json'
            if not path.exists():
                break
            value = json.loads(path.read_text())
            if not self.matches_request(value, nonce, stamp):
                break
            parts.append(value)
        if len(parts) != len(self.counts):
            if time.monotonic() >= deadline:
                raise TimeoutError('room_restart_checkpoint_timeout')
            return None
        self.request = None
        return parts

    def persist(self):
        self.save(self.directory / 'room-host-restart-canary.json', dict(
            formatVersion=1, passed=self.recovered, targetGateway=self.target,
            confirmedSIGKILL=self.old_process is not None and self.old_process.returncode == -signal.SIGKILL,
            preKillPerConnectionReadyProven=self.before is not None,
            initial=self.initial, lastOld=self.last_old, firstHigher=self.higher, samples=self.samples,
            initialCandidates=list(self.candidates.values()),
            before=self.before, after=self.after, naturalLeaseExpiry=True, alteredTTL=False,
            clientDisconnectRecoveryProven=False, lateOldFenceInjectionProven=False,
            scope='actual Room activation takeover, survivor TCP continuity, renewed Ready and subsequent applied sequence'))

    def step(self, release_at, gateways, launch):
        if time.time() < release_at or self.recovered:
            return
        if self.deadline is None:
            self.deadline = time.monotonic() + 210
        if time.monotonic() >= self.deadline:
            self.persist()
            raise TimeoutError('room_restart_recovery_not_proven')
        if self.old_process is None:
            if time.time() >= release_at + 30:
                self.persist()
                raise TimeoutError('room_restart_arm_window_exhausted')
            parts = self.checkpoint()
            if parts is None or not self.ready(parts, self.counts, require_ready=True, minimum_room_head=0):
                return
            rooms = {str(uuid.UUID(scope['scopeID'])) for part in parts for slot in part['slots']
                     for scope in slot['coverage']['requestedScopes'] if scope['scope'] == 'room'}
            snapshot = lease_snapshot(self.read, rooms)
            self.samples.append(snapshot)
            self.samples = self.samples[-16:]
            self.persist()
            if self.host_ids is not None:
                choices = [(sum(physical_host_matches(row['hostID'], host) and
                                row['expiresAt'] - snapshot['databaseNow'] >= 5
                                for row in snapshot['leases']), index, host)
                           for index, host in self.host_ids.items() if index != self.survivor]
                count, index, host = max(choices, default=(0, self.target, self.target_host_id))
                if count == 0:
                    return
                self.target, self.target_host_id = index, str(uuid.UUID(host))
            eligible = [row for row in snapshot['leases'] if physical_host_matches(row['hostID'], self.target_host_id)
                        and row['expiresAt'] - snapshot['databaseNow'] >= 5]
            if not eligible:
                return
            self.before, self.initial = parts, eligible[0]
            self.last_old = self.initial
            # Freeze all foreground rooms on this exact killed physical host.
            # Persona traffic may leave an arbitrary first room completely idle.
            self.candidates = {row['roomID']: row for row in eligible}
            self.last_old_by_room = dict(self.candidates)
            process = gateways[self.target]
            if process.poll() is not None:
                raise RuntimeError('room_restart_target_already_exited')
            self.old_process = process
            self.persist()
            process.kill()
            if process.wait(timeout=5) != -signal.SIGKILL:
                raise RuntimeError('room_restart_sigkill_unconfirmed')
            self.kill_monotonic = time.monotonic()
            self.restart_process = launch(self.target)
            gateways[self.target] = self.restart_process
            self.persist()
            return
        rooms = [self.selected_room] if self.selected_room else list(self.candidates)
        snapshot = lease_snapshot(self.read, rooms)
        self.samples.append(snapshot)
        self.samples = self.samples[-128:]
        if {row['roomID'] for row in snapshot['leases']} != set(rooms):
            raise RuntimeError('room_restart_candidate_missing')
        active_candidate = None
        for row in snapshot['leases']:
            initial = self.candidates[row['roomID']]
            last_old = self.last_old_by_room[row['roomID']]
            if row['epoch'] < initial['epoch']:
                raise RuntimeError('room_restart_epoch_regression')
            if row['epoch'] == initial['epoch']:
                if (row['hostID'], row['incarnation']) != (initial['hostID'], initial['incarnation']):
                    raise RuntimeError('room_restart_same_epoch_identity_change')
                if row['expiresAt'] is not None:
                    self.last_old_by_room[row['roomID']] = row
                continue
            single = dict(databaseNow=snapshot['databaseNow'], leases=[row])
            if not takeover_proven(initial, last_old, single):
                raise RuntimeError('room_restart_invalid_takeover')
            if row['head'] > initial['head'] and active_candidate is None:
                active_candidate = row, initial, last_old, single
        if active_candidate is None:
            self.persist()
            return  # no recovery claim for an idle room
        row, self.initial, self.last_old, current = active_candidate
        self.selected_room = row['roomID']
        if self.higher is None:
            self.higher = current
        parts = self.checkpoint()
        if parts is None:
            return
        if not self.continuity(self.before, parts):
            raise RuntimeError('room_restart_survivor_channel_replaced')
        if not self.ready(parts, self.counts, require_ready=True, minimum_room_head=0):
            self.persist()
            return
        selected = [scope for part in parts for slot in part['slots']
                    for scope in slot['coverage']['requestedScopes']
                    if scope['scope'] == 'room' and str(uuid.UUID(scope['scopeID'])) == self.initial['roomID']]
        if selected and all(scope['appliedCursor'] > self.initial['head'] for scope in selected):
            self.after, self.recovered = parts, True
        self.persist()
