"""One live deployment, eight persistent load partitions, three certified expansions."""
import copy
import json
import math
from pathlib import Path
import time
from v2_benchmark_dynamic_membership import LiveExpansion
from v2_benchmark_ingress_growth import admit
from v2_benchmark_ingress import capture
from v2_benchmark_remote_process import gateway_metrics
from v2_benchmark_user_growth import measurement_end, cohort_quality

COHORTS = ((0,), (1,), (2, 3), (4, 5, 6, 7))


def partition_continuous_cohorts(lines, parts):
    if parts != 8 or len(lines) % 16:
        raise ValueError('continuous growth requires eight equal paired load partitions')
    rows = [json.loads(line) for line in lines]
    if len({row['userID'] for row in rows}) != len(rows):
        raise ValueError('continuous growth requires unique users')
    width = len(lines)//parts
    result = [lines[i*width:(i+1)*width] for i in range(parts)]
    seen = set()
    for group in COHORTS:
        rooms = {json.loads(line)['targetRoomIDs'][0] for i in group for line in result[i]}
        if seen & rooms:
            raise ValueError('continuous growth cohorts share foreground rooms')
        seen |= rooms
    return result


def cohort_duration(scenario, phase_name, minimum_seconds, prior_ends, now):
    warmup = measurement_end(scenario, phase_name) - next(
        p['durationSeconds'] for p in scenario['phases'] if p['name'] == phase_name)
    # Reserve connection establishment time. The actual release is checked again;
    # elapsed time alone is never proof that the earlier users are still online.
    duration = math.floor(min(prior_ends) - now - warmup - 180)
    if duration < minimum_seconds:
        raise RuntimeError('insufficient remaining measurement for continuous user growth')
    return duration


class ContinuousUserGrowth:
    initial_indices = (0,)
    late_indices = tuple(range(1, 8))

    def __init__(self, args, directory, counts, expansion, manifest, binary):
        if args.nodes != 1 or len(counts) != 8 or len(set(counts)) != 1:
            raise ValueError('continuous growth starts with one gateway and eight equal load partitions')
        self.args, self.directory, self.counts = args, Path(directory), counts
        self.expansion, self.manifest, self.binary = expansion, manifest, binary
        self.scenario = json.loads(args.scenario.read_text())
        self.stage = 1
        self.started = self.released = False
        self.ends = {}
        self.next_stage_at = None
        self.stages = []
        self.evidence = dict(status='scheduled', initialUsers=counts[0], addedUsers=sum(counts[1:]),
                             finalUsers=sum(counts), continuous=True, stages=self.stages)
        self.save()

    def save(self):
        path = self.directory/'user-growth.json'
        temporary = path.with_suffix('.tmp')
        temporary.write_text(json.dumps(self.evidence, indent=2)+'\n'); temporary.replace(path)

    def paths_for(self, index):
        return (self.directory/f'growth-scenario-{index}.json', self.directory/f'growth-start-barrier-{index}.json')

    def step(self, release, command, spawn, loaders, start_gateway):
        if not self.ends:
            self.ends[0] = release + measurement_end(self.scenario, self.args.measurement_phase)
        if self.released:
            if self.stage == 3 or time.time() < self.next_stage_at:
                return
            if any(process.poll() is not None for process in loaders):
                raise RuntimeError('an existing user cohort exited before the next expansion')
            old = self.expansion
            if self.stage == 1:
                (self.directory/'first-stage-live-expansion.json').write_bytes((old.directory/'live-expansion.json').read_bytes())
            previous = json.loads((old.directory/'membership-final-receipt.json').read_text())['membership']
            stage_args = copy.copy(self.args)
            stage_args.nodes = old.target_count
            stage_args.live_scale_out_at = max(1, time.time()-release)
            stage_args.active_credential_paths = [self.args.output_dir/f'part-{i}.jsonl' for i in range(old.target_count)]
            stage_directory = self.directory/f'expansion-{old.target_count}-to-{old.target_count*2}'
            stage_directory.mkdir(exist_ok=False)
            self.expansion = LiveExpansion(stage_args, old.expanded, stage_directory,
                                           self.manifest, self.binary, initial_membership=previous)
            self.stage += 1
            self.started = self.released = False
        self.expansion.step(release, start_gateway)
        if not self.expansion.done:
            return
        indices = COHORTS[self.stage]
        if not self.started:
            if any(process.poll() is not None for process in loaders):
                raise RuntimeError('an existing user cohort exited before ingress admission')
            admission = admit(self.args, self.directory, self.expansion.new_indices,
                              self.expansion.target_count, self.expansion.final_revision)
            duration = cohort_duration(self.scenario, self.args.measurement_phase,
                                       self.args.growth_measurement_seconds, self.ends.values(), time.time())
            scenario = copy.deepcopy(self.scenario)
            for phase in scenario['phases']:
                if phase['name'] == self.args.measurement_phase:
                    phase['durationSeconds'] = duration
            self.pending_scenario = scenario
            for index in indices:
                self.paths_for(index)[0].write_text(json.dumps(scenario, indent=2)+'\n')
                argv = command(index, self.counts[index])
                with (self.directory/f'command-{index}.json').open('x') as stream:
                    json.dump(argv, stream, indent=2)
                loaders.append(spawn(argv, f'load-{index}'))
            self.current = dict(initialNodes=self.expansion.initial_count, targetNodes=self.expansion.target_count,
                                initialRevision=self.expansion.initial_revision, finalRevision=self.expansion.final_revision,
                                parts=list(indices), ingressAdmission=admission, status='connecting')
            self.stages.append(self.current)
            self.started = True; self.evidence['status'] = 'connecting'; self.save()
            return
        ready_paths = [self.directory/f'part-{i}-ready.json' for i in indices]
        if not all(p.exists() for p in ready_paths):
            return
        for index, path in zip(indices, ready_paths):
            ready = json.loads(path.read_text())
            if ready['activeConnections'] != self.counts[index] or ready['requestedConnections'] != self.counts[index]:
                raise RuntimeError('new continuous cohort failed connection readiness')
        if any(process.poll() is not None for process in loaders):
            raise RuntimeError('continuous cohort exited before measurement release')
        new_release = int(time.time()*1000)+3000
        new_end = new_release/1000 + measurement_end(self.pending_scenario, self.args.measurement_phase)
        if new_end+20 > min(self.ends.values()):
            raise RuntimeError('continuous cohort cannot finish while earlier cohorts remain measuring')
        connections = {}
        for index in range(self.expansion.target_count):
            values = [int(line.split()[1]) for line in gateway_metrics(self.args, index).splitlines()
                      if line.startswith('im_v2_gateway_active_connections ')]
            if len(values) != 1:
                raise RuntimeError('missing continuous gateway connection count')
            connections[index] = values[0]
        if (sum(connections.values()) != sum(self.counts[:self.expansion.target_count])
                or any(connections[i] <= 0 for i in self.expansion.new_indices)):
            raise RuntimeError('continuous growth connections not active on every new gateway')
        rows = capture(self.args, self.directory, f'ingress-growth-connections-r{self.expansion.final_revision}.csv')
        serving = {r['svname']: r for r in rows if r.get('# pxname') == 'gateways'}
        if any(int(serving.get(f'gateway-{i}', {}).get('scur', '0')) <= 0 for i in self.expansion.new_indices):
            raise RuntimeError('continuous ingress did not route clients to every new gateway')
        for index in indices:
            path = self.paths_for(index)[1]; temporary = path.with_suffix('.tmp')
            temporary.write_text(json.dumps(dict(releaseAtUnixMilliseconds=new_release))+'\n'); temporary.replace(path)
            self.ends[index] = new_end
        warmup = measurement_end(self.pending_scenario, self.args.measurement_phase) - next(
            p['durationSeconds'] for p in self.pending_scenario['phases'] if p['name'] == self.args.measurement_phase)
        self.next_stage_at = new_release/1000 + warmup + 60
        self.current.update(status='measuring', releaseAtUnixMilliseconds=new_release,
                            measurementEndsAt=new_end, authenticatedConnectionsByGateway=connections)
        self.released = True; self.evidence['status'] = 'measuring'; self.save()

    def finish(self, result, reports, merge_latency):
        if self.stage != 3 or not self.released or not self.expansion.done:
            raise RuntimeError('continuous expansion did not reach eight live gateways')
        rate = next(p['messagesPerSecond'] for p in self.scenario['phases'] if p['name'] == self.args.measurement_phase)
        quality = {str(i): cohort_quality(reports, group, self.args.measurement_phase, rate*len(group), merge_latency)
                   for i, group in enumerate(COHORTS)}
        passed = (result['qualityPassed'] and all(q['passed'] for q in quality.values())
                  and result['steadyStateCommonWindowSeconds'] >= self.args.growth_measurement_seconds*.9)
        self.evidence.update(status='completed' if passed else 'failed', passed=passed, cohortQuality=quality,
                             commonMeasurementSeconds=result['steadyStateCommonWindowSeconds'])
        self.save()
        summary = dict(completed=True, initialNodes=1, targetNodes=8, initialRevision=1, finalRevision=7,
                       continuous=True, stages=self.stages,
                       evidencePaths=['first-stage-live-expansion.json', 'expansion-2-to-4/live-expansion.json',
                                      'expansion-4-to-8/live-expansion.json'])
        (self.directory/'live-expansion.json').write_text(json.dumps(summary, indent=2)+'\n')
        return self.evidence
