"""Dynamic membership startup shared by the real multi-VM benchmark."""
import json
import os
import re
from pathlib import Path
import subprocess
from v2_benchmark_membership_commands import membership_command, save_command
from v2_benchmark_partition_balance import partition_balance_plan, verify_partition_balance
from v2_native_placement_inspection import decode_placement_inspection
from v2_benchmark_remote_process import hostname, remote_command


def authority_profile(deployment):
    profile = deployment.get('authorityProfile')
    if not isinstance(profile, str) or not re.fullmatch(r'imv2-growth-[a-z0-9-]+', profile):
        raise ValueError('online growth requires an explicit owned authorityProfile')
    if profile in {node['profile'] for node in deployment['processes'].values()}:
        raise ValueError('authorityProfile must be separate from all online service and loader VMs')
    return profile


def trust_authoring_command(deployment, actors, expanded, packet):
    runtime = Path(deployment['runtime'])
    return ['colima', '-p', authority_profile(deployment), 'ssh', '--',
            'sudo', '-n', 'unshare', '--net', '--',
            str(runtime/'lib/ld-linux-aarch64.so.1'), '--library-path',
            str(runtime/'usr/lib/swift/linux')+':'+str(runtime/'lib/aarch64-linux-gnu'),
            str(runtime/'bin/IMV2TrustAdmissionTool'), str(Path(actors)/'gateway-0/configuration.json'),
            str(Path(expanded)/'gateway-0/configuration.json'),
            str(Path(actors)/'.trust-admission/signing.pem'), str(packet)]


def verify_transfer_postconditions(inspection, directory, partitions):
    """The next fresh inspection certifies the preceding transfer before more work."""
    slots = {slot['partition']: slot for slot in inspection['partitions']}
    for index in partitions:
        command = json.loads((Path(directory)/f'transfer-{index}-request.json').read_text())
        successor = dict(hostID=command['successor']['hostID']['rawValue'],
                         incarnationID=command['successor']['incarnationID'])
        actual = slots[index]
        if (inspection['shardID'] != command['shardID'] or actual['owner'] != successor
                or actual['epoch'] != command['expectedEpoch']+1
                or actual['retired'] or actual.get('transfer')):
            raise RuntimeError('committed partition transfer postcondition failed')


def configuration_arguments(args, shard):
    result = ['--service-membership-shard', shard,
              '--trust-admission-authority', 'admission-authority']
    for name, offset, flag in [('membership-controller', 16, '--membership-controller'),
                               ('placement-controller', 20, '--placement-controller')]:
        result += ['--caller', f'{name}={hostname(args, name)}:{args.actor_port + offset}', flag, name]
    return result


class MembershipController:
    """Use saved requests and separate receipt logs for each control operation."""
    def __init__(self, args, actors, directory, binary, role="membership-controller"):
        self.args, self.directory, self.binary = args, Path(directory), binary
        self.role = role
        configuration_path = Path(actors) / role / 'configuration.json'
        self.configuration = json.loads(configuration_path.read_text())
        self.environment = {k: v for k, v in os.environ.items() if not k.startswith(('IMV2_', 'IM_V2_'))}
        self.environment['IMV2_ROOM_ACTOR_CONFIGURATION_FILE'] = str(configuration_path)
        self.environment['IMV2_PLACEMENT_SHARD_IDS'] = self.configuration['serviceMembershipShard']

    def invoke(self, arguments, label):
        command = [str(self.binary), *arguments]
        if self.args.server_deployment:
            command = remote_command(self.args.server_deployment, self.role, command,
                                     self.environment, self.directory)
        output_path = self.directory / (label + '.json')
        with output_path.open('xb') as output, (self.directory / (label + '.log')).open('xb') as errors:
            subprocess.run(command, env=self.environment, stdout=output, stderr=errors, check=True, timeout=90)
        return output_path.read_text()

    def inspect(self, label):
        return decode_placement_inspection(self.invoke(['--inspect'], label))[
            self.configuration['serviceMembershipShard']]

    def prepare(self, configuration, label, previous=None, target=None):
        if (configuration['placementControl']['clusterID'] != self.configuration['placementControl']['clusterID'] or
                configuration['serviceMembershipShard'] != self.configuration['serviceMembershipShard']):
            raise ValueError('membership command belongs to another deployment or shard')
        shard = self.inspect(label + '-inspection')
        command = membership_command(configuration, shard['revision'], previous, target)
        return save_command(self.directory / (label + '-request.json'), command)

    def submit(self, path, label):
        # On an unknown result retry this same path with a fresh evidence label.
        # Never reconstruct a request from a newly inspected origin revision.
        command = json.loads(Path(path).read_text())
        if (command['deploymentID'] != self.configuration['placementControl']['clusterID'] or
                command['shardID'] != self.configuration['serviceMembershipShard']):
            raise ValueError('saved membership command belongs to another deployment or shard')
        receipt = json.loads(self.invoke(['--install-membership', str(path)], label))
        if (receipt['requestID'].lower() != command['requestID'].lower() or
                receipt['membership'] != command['membership']):
            raise RuntimeError('membership receipt does not match the saved request')
        return receipt


def bootstrap(args, actors, directory, binary):
    """Commit the initial roster before Account/Gateway tries to read it."""
    controller = MembershipController(args, actors, directory, binary)
    path = controller.prepare(controller.configuration, 'membership-initial',
                              target=[p['nodeID'] for p in controller.configuration['realtimePeers']])
    return controller.submit(path, 'membership-initial-receipt')


def prepare_expansion(args, actors, output, manifest, target_count):
    """Create only new candidate configuration; leave live files untouched."""
    import sys
    topology = json.loads((Path(actors) / 'topology.json').read_text())
    count = len(topology['hosts'])
    if target_count not in (2, 4, 8) or target_count <= count:
        raise ValueError('expansion must increase the current gateway count to 2, 4, or 8')
    if {row[0] for row in topology['hosts']} != {f'gateway-{i}' for i in range(count)}:
        raise ValueError('expansion requires contiguous benchmark gateway identities')
    reference = json.loads((Path(actors) / 'gateway-0/configuration.json').read_text())
    capacity = next(p['maximumRooms'] for p in reference['peers'] if p['serviceID'] == 'gateway-0')
    command = [sys.executable, str(Path(__file__).with_name('prepare_v2_room_actor_configuration.py')),
               '--output-dir', str(output), '--extend-from', str(actors),
               '--shards', ','.join(topology['shards']), '--user-buckets', manifest['userBucket'],
               '--maximum-rooms-per-host', str(capacity),
               '--policy-partitions', str(topology['policyPlacement']['partitionCount']),
               '--service-membership-shard', reference['serviceMembershipShard']]
    for role, flag in [('hosts', '--host'), ('callers', '--caller'), ('voters', '--placement-voter')]:
        for name, address, port in topology[role]:
            command += [flag, f'{name}={address}:{port}']
    for role, flag in [('membershipControllers', '--membership-controller'),
                       ('placementControllers', '--placement-controller'),
                       ('exclusionSupervisors', '--exclusion-supervisor')]:
        for name in topology.get(role, []):
            command += [flag, name]
    for i in range(count, target_count):
        name = f'gateway-{i}'
        # Account occupies base + initial gateway count. Keep new actor sockets
        # away from all initial business and controller endpoints.
        command += ['--host', f'{name}={hostname(args, name)}:{args.actor_port + 32 + i}']
    log = Path(output).parent / (Path(output).name + '-prepare.log')
    with log.open('xb') as stream:
        subprocess.run(command, check=True, stdout=stream, stderr=subprocess.STDOUT, timeout=30)
    for i in range(count, target_count):
        node = Path(output) / f'gateway-{i}'
        with (node / 'candidate.json').open('x') as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write((node / 'configuration.json').read_text())
    return Path(output)


def stable_expansion_revision(membership, count):
    if (not isinstance(membership.get('revision'), int) or isinstance(membership['revision'], bool)
            or membership['revision'] < 1 or membership.get('next') is not None
            or len(membership.get('current', [])) != count
            or set(membership.get('current', [])) != {f'gateway-{i}' for i in range(count)}):
        raise ValueError('expansion requires the exact committed stable predecessor roster')
    return membership['revision']


class LiveExpansion:
    """Double 1, 2, or 4 live gateways with verified transfers to every new host."""
    def __init__(self, args, actors, directory, manifest, binary, *, initial_membership=None):
        import time
        self.args, self.actors, self.directory = args, Path(actors), Path(directory)
        self.initial_count, self.target_count = args.nodes, args.nodes * 2
        if self.initial_count not in (1, 2, 4) or args.live_scale_out_partitions < self.initial_count:
            raise ValueError('live doubling requires 1, 2, or 4 initial nodes and at least one partition per new node')
        self.initial_membership = initial_membership
        self.initial_revision = stable_expansion_revision(initial_membership, self.initial_count) if initial_membership is not None else 1
        self.joint_revision, self.final_revision = self.initial_revision + 1, self.initial_revision + 2
        self.new_indices = tuple(range(self.initial_count, self.target_count))
        self.controller = MembershipController(args, actors, directory, binary)
        self.expanded = prepare_expansion(args, actors, directory/f'expanded{self.target_count}', manifest, self.target_count)
        self.configuration = json.loads((self.expanded/'membership-controller/configuration.json').read_text())
        self.deployment = json.loads(args.server_deployment.read_text())
        self.packet = directory/'new-gateway-admission.pb'
        # Only the isolated offline signer receives the authority-key path.
        # Business nodes receive the signed grant through publication below.
        command = trust_authoring_command(self.deployment, actors, self.expanded, self.packet)
        with (directory/'admission-authoring.log').open('xb') as log:
            subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT, timeout=30)
        self.phase, self.consecutive, self.done = 'scheduled', 0, False
        self.deadline = None
        self.transferred = []
        self.balance_plan = None
        self.balance_targets = {}
        self.events = []
        self.record('prepared', time.time())

    def record(self, event, now, **values):
        self.events.append(dict(event=event, time=now, **values))
        temporary = self.directory/'live-expansion.tmp'
        temporary.write_text(json.dumps(dict(phase=self.phase, completed=self.done,
            transferredPartitions=self.transferred, initialNodes=self.initial_count, targetNodes=self.target_count,
            initialRevision=self.initial_revision, finalRevision=self.final_revision, events=self.events), indent=2)+'\n')
        temporary.replace(self.directory/'live-expansion.json')

    def step(self, release, start_gateway):
        import hashlib
        import time
        import uuid
        from publish_v2_trust_admission import publish
        from wait_v2_gateway_membership import parse_observation, matches
        from v2_benchmark_remote_process import gateway_metrics
        now = time.time()
        if self.done or now < release + self.args.live_scale_out_at:
            return
        if self.phase == 'scheduled':
            publications = []
            for path in sorted(self.actors.glob('*/configuration.json')):
                config = json.loads(path.read_text())
                publications.append(publish(self.packet.read_bytes(), config['trustAdmissionDirectory'],
                    self.deployment['processes'][path.parent.name]['profile']))
            (self.directory/'admission-publication.json').write_text(json.dumps(publications, indent=2))
            for index in self.new_indices:
                start_gateway(self.expanded, index)
            self.phase, self.deadline = 'standby-convergence', time.monotonic()+90
            self.record('standby-gateway-started', time.time())
            return
        if self.phase == 'standby-convergence':
            observations, active_rooms = {}, {}
            for index in range(self.target_count):
                try:
                    body = gateway_metrics(self.args, index)
                    observations[index] = parse_observation(body)
                    if index in self.new_indices:
                        active_rooms[index] = [line.split()[1] for line in body.splitlines()
                                        if line.startswith('im_v2_room_actor_active_rooms ')]
                except Exception as error:
                    observations[index] = dict(error=type(error).__name__)
            # The candidate knows the old certified roster but has no local
            # vote or serving qualification. The existing gateway stays ready.
            good = (all(matches(observations[i], self.initial_revision, self.initial_count, retired=i in self.new_indices)
                        for i in range(self.target_count))
                    and all(active_rooms.get(i) == ['0'] for i in self.new_indices))
            self.consecutive = self.consecutive+1 if good else 0
            if time.monotonic() > self.deadline:
                self.record('standby-timeout', now, observations=observations)
                raise TimeoutError('new gateway did not reach unqualified standby state')
            if self.consecutive < 3:
                return
            self.consecutive = 0
            self.record('standby-confirmed', now, observations=observations, newGatewayActiveRooms=0)
            previous = self.initial_membership or json.loads((self.directory/'membership-initial-receipt.json').read_text())['membership']
            if stable_expansion_revision(previous, self.initial_count) != self.initial_revision:
                raise RuntimeError('expansion base revision differs from its committed receipt')
            request = self.controller.prepare(self.configuration, 'membership-joint', previous, [f'gateway-{i}' for i in range(self.target_count)])
            self.joint = self.controller.submit(request, 'membership-joint-receipt')['membership']
            self.phase, self.deadline = 'joint-convergence', time.monotonic()+90
            self.record('joint-committed', time.time())
            return
        if self.phase in ('joint-convergence', 'final-convergence'):
            revision = self.joint_revision if self.phase == 'joint-convergence' else self.final_revision
            observations, raw_metrics = {}, {}
            for index in range(self.target_count):
                try:
                    raw_metrics[index] = gateway_metrics(self.args, index)
                    observations[index] = parse_observation(raw_metrics[index])
                except Exception as error:
                    observations[index] = dict(error=type(error).__name__)
            good = all(matches(value, revision, self.target_count) for value in observations.values())
            self.consecutive = self.consecutive+1 if good else 0
            if time.monotonic() > self.deadline:
                self.record('convergence-timeout', now, observations=observations)
                raise TimeoutError('expanded gateway membership did not converge')
            if self.consecutive < 3:
                return
            self.consecutive = 0
            self.record('membership-converged', now, revision=revision, observations=observations)
            if revision == self.final_revision:
                if getattr(self, 'balance_plan', None) is not None:
                    inspection = self.controller.inspect('balance-final-inspection')
                    verify_transfer_postconditions(inspection, self.directory, self.transferred)
                    counts = verify_partition_balance(inspection['partitions'], self.balance_plan)
                    (self.directory/'partition-balance-verified.json').write_text(
                        json.dumps(dict(passed=True, counts=counts), indent=2)+'\n')
                active = {}
                for index in self.new_indices:
                    values = [line.split()[1] for line in raw_metrics[index].splitlines()
                              if line.startswith('im_v2_room_actor_active_rooms ')]
                    if len(values) != 1 or int(values[0]) <= 0:
                        raise RuntimeError(f'expanded gateway-{index} has no active migrated rooms')
                    active[index] = int(values[0])
                for index, body in raw_metrics.items():
                    (self.directory/f'expansion-complete-gateway-{index}.prom').write_text(body)
                phases = json.loads(self.args.scenario.read_text())['phases']
                end = release
                measurement_end = None
                for phase in phases:
                    end += phase['durationSeconds']
                    if phase['name'] == self.args.measurement_phase:
                        measurement_end = end
                if measurement_end is None or time.time() + 20 > measurement_end:
                    raise RuntimeError('expansion left less than 20 seconds of measured business traffic')
                self.phase, self.done = 'completed', True
                self.record('completed', time.time(), newGatewayActiveRooms=active,
                            measurementEndsAt=measurement_end)
                return
            inspection = self.controller.inspect('transfer-selection')
            if getattr(self.args, 'live_scale_out_rebalance', False):
                hosts = [json.loads((self.expanded/f'gateway-{i}'/'configuration.json').read_text())['hostID']
                         for i in range(self.target_count)]
                self.balance_targets = {host.lower(): i for i, host in enumerate(hosts)}
                self.balance_plan = partition_balance_plan(inspection['partitions'], hosts)
                (self.directory/'partition-balance-plan.json').write_text(
                    json.dumps(self.balance_plan, indent=2)+'\n')
                self.pending = [move['partition'] for move in self.balance_plan['moves']]
                self.phase = 'transferring'
                return
            if getattr(self.args, 'continuous_user_growth', False):
                credential_paths = [self.args.output_dir/f'part-{i}.jsonl' for i in range(self.initial_count)]
            elif getattr(self.args, 'live_user_growth', False):
                credential_paths = [self.args.output_dir/f'part-{i}.jsonl' for i in range(self.args.loader_partitions//2)]
            else:
                credential_paths = [self.args.fixture/'credentials.jsonl']
            rooms = {json.loads(line)['targetRoomIDs'][0] for path in credential_paths
                     for line in path.read_text().splitlines()}
            partitions = sorted({int.from_bytes(hashlib.sha256(str(uuid.UUID(room)).upper().encode()).digest()[:8],
                                                'big') % len(inspection['partitions']) for room in rooms})
            self.pending = partitions[:self.args.live_scale_out_partitions]
            if len(self.pending) != self.args.live_scale_out_partitions:
                raise RuntimeError('not enough active foreground partitions for migration')
            self.phase = 'transferring'
            return
        if self.phase == 'transferring':
            if self.pending:
                index = self.pending[0]
                inspection = self.controller.inspect(f'transfer-{index}-inspection')
                verify_transfer_postconditions(inspection, self.directory, self.transferred[-1:])
                slot = next(p for p in inspection['partitions'] if p['partition'] == index)
                if getattr(self, 'balance_plan', None) is not None:
                    move = next(move for move in self.balance_plan['moves'] if move['partition'] == index)
                    if slot['owner']['hostID'].lower() != move['sourceHost'] or slot['epoch'] != move['expectedEpoch']:
                        raise RuntimeError('partition ownership changed after balance planning')
                    target_index = self.balance_targets[move['targetHost']]
                else:
                    target_index = self.new_indices[len(self.transferred) % len(self.new_indices)]
                new_host = json.loads((self.expanded/f'gateway-{target_index}/configuration.json').read_text())['hostID']
                successor = next(h['identity'] for h in inspection['hosts']
                                 if h['identity']['hostID'].lower() == new_host.lower() and not h['retired'])
                def identity(value):
                    return dict(hostID=dict(rawValue=value['hostID']), incarnationID=value['incarnationID'])
                command = dict(deploymentID=self.configuration['placementControl']['clusterID'],
                    shardID=inspection['shardID'], partition=index, expectedHost=identity(slot['owner']),
                    expectedEpoch=slot['epoch'], successor=identity(successor), transferID=str(uuid.uuid4()).upper(),
                    originRevision=inspection['revision'])
                if slot['retired'] or slot.get('transfer') or slot['owner']==successor:
                    raise RuntimeError('selected partition has no transferable old owner')
                path = save_command(self.directory/f'transfer-{index}-request.json', command)
                operator = MembershipController(self.args, self.actors, self.directory, self.controller.binary,
                                                role='placement-controller')
                receipt = json.loads(operator.invoke(['--transfer-room-partition', str(path)], f'transfer-{index}-receipt'))
                if receipt['status'] != 'completed' or receipt['command'] != dict(command,
                        deploymentID=command['deploymentID'].upper()):
                    raise RuntimeError('partition transfer receipt mismatch')
                self.transferred.append(index); self.pending.pop(0)
                self.record('partition-transferred', time.time(), partition=index, targetGateway=target_index)
                return
            # One fresh snapshot verifies the final receipt and all earlier
            # outcomes, as well as the complete plan. Intermediate snapshots
            # already verified the preceding receipt before each next transfer.
            inspection = self.controller.inspect('balance-transferred-inspection')
            verify_transfer_postconditions(inspection, self.directory, self.transferred)
            if getattr(self, 'balance_plan', None) is not None:
                verify_partition_balance(inspection['partitions'], self.balance_plan)
            path = self.controller.prepare(self.configuration, 'membership-final', self.joint)
            self.controller.submit(path, 'membership-final-receipt')
            self.phase, self.deadline = 'final-convergence', time.monotonic()+90
