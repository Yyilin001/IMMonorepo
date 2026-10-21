"""Two disjoint user cohorts with explicit overlap and live ingress proof."""
import json
from pathlib import Path
import time
from v2_benchmark_ingress_growth import admit
from v2_benchmark_ingress import capture
from v2_benchmark_remote_process import gateway_metrics


def partition_cohorts(lines, parts):
    if parts < 2 or parts % 2 or len(lines) % parts or len(lines) % 4:
        raise ValueError('growth requires two equal, paired, evenly partitioned cohorts')
    middle = len(lines)//2
    records = [json.loads(line) for line in lines]
    if len({r['userID'] for r in records}) != len(records):
        raise ValueError('growth user identities must be unique')
    rooms = [{r['targetRoomIDs'][0] for r in group} for group in (records[:middle],records[middle:])]
    if rooms[0] & rooms[1]:
        raise ValueError('growth cohorts must have disjoint foreground rooms')
    result = [[] for _ in range(parts)]
    for index,line in enumerate(lines):
        cohort = int(index >= middle)
        result[cohort*(parts//2)+(index%middle)%(parts//2)].append(line)
    return result


def measurement_end(scenario, name):
    duration = 0
    for phase in scenario['phases']:
        duration += phase['durationSeconds']
        if phase['name'] == name:return duration
    raise ValueError('measurement phase missing')


class LiveUserGrowth:
    def __init__(self,args,directory,counts):
        self.args,self.directory,self.counts = args,Path(directory),counts
        self.initial_indices=tuple(range(len(counts)//2))
        self.late_indices=tuple(range(len(counts)//2,len(counts)))
        self.started=False;self.released=False
        self.initial_scenario=json.loads(args.scenario.read_text())
        late=json.loads(args.scenario.read_text())
        for phase in late['phases']:
            if phase['name']==args.measurement_phase:phase['durationSeconds']=args.growth_measurement_seconds
        self.late_scenario=late
        self.scenario_path=self.directory/'growth-scenario.json'
        self.scenario_path.write_text(json.dumps(late,indent=2)+'\n')
        self.barrier_path=self.directory/'growth-start-barrier.json'
        self.evidence=dict(status='scheduled',initialUsers=sum(counts[i] for i in self.initial_indices),
            addedUsers=sum(counts[i] for i in self.late_indices),finalUsers=sum(counts),
            initialParts=list(self.initial_indices),addedParts=list(self.late_indices),events=[])
        self.save()

    def save(self):
        p=self.directory/'user-growth.json';temporary=p.with_suffix('.tmp')
        temporary.write_text(json.dumps(self.evidence,indent=2)+'\n');temporary.replace(p)

    def step(self,release,expansion,command,spawn,loaders):
        if self.released or not expansion.done:return
        if not self.started:
            receipt=admit(self.args,self.directory,expansion.new_indices,expansion.target_count,expansion.final_revision)
            self.evidence['ingressAdmission']=receipt
            for i in self.late_indices:
                argv=command(i,self.counts[i])
                path=self.directory/f'command-{i}.json'
                with path.open('x') as stream:json.dump(argv,stream,indent=2)
                loaders.append(spawn(argv,f'load-{i}'))
            self.started=True;self.evidence['status']='connecting'
            self.evidence['events'].append(dict(event='new-users-started',time=time.time()))
            self.save();return
        paths=[self.directory/f'part-{i}-ready.json' for i in self.late_indices]
        if not all(path.exists() for path in paths):return
        ready=[json.loads(path.read_text()) for path in paths]
        if any(r['activeConnections']!=self.counts[i] or r['requestedConnections']!=self.counts[i]
               for i,r in zip(self.late_indices,ready)):
            raise RuntimeError('new user cohort did not become fully active')
        if any(loaders[i].poll() is not None for i in self.initial_indices):
            raise RuntimeError('original users exited before growth overlap')
        new_release=int(time.time()*1000)+3000
        old_end=release+measurement_end(self.initial_scenario,self.args.measurement_phase)
        new_end=new_release/1000+measurement_end(self.late_scenario,self.args.measurement_phase)
        if new_end+20 > old_end:
            raise RuntimeError('insufficient original-user measurement time for complete growth overlap')
        connections={}
        for i in range(expansion.target_count):
            body=gateway_metrics(self.args,i)
            values=[int(line.split()[1]) for line in body.splitlines() if line.startswith('im_v2_gateway_active_connections ')]
            if len(values)!=1:raise RuntimeError('missing authenticated connection count')
            connections[i]=values[0]
        if sum(connections.values())!=sum(self.counts) or any(connections[i]<=0 for i in expansion.new_indices):
            raise RuntimeError('growth connections not active across new gateways')
        rows=capture(self.args,self.directory,'ingress-growth-connections.csv')
        serving={r['svname']:r for r in rows if r.get('# pxname')=='gateways'}
        if any(int(serving.get(f'gateway-{i}',{}).get('scur','0'))<=0 for i in expansion.new_indices):
            raise RuntimeError('ingress did not route live connections to every new gateway')
        temporary=self.barrier_path.with_suffix('.tmp')
        temporary.write_text(json.dumps(dict(releaseAtUnixMilliseconds=new_release))+'\n');temporary.replace(self.barrier_path)
        self.released=True;self.evidence.update(status='measuring',authenticatedConnectionsByGateway=connections,
            initialMeasurementEnd=old_end,newMeasurementEnd=new_end,newReleaseAtUnixMilliseconds=new_release)
        self.evidence['events'].append(dict(event='new-users-measurement-released',time=time.time()))
        self.save()

    def finish(self,result,reports,merge_latency):
        if not self.released:raise RuntimeError('user growth never reached measurement')
        requested_rate = next(p['messagesPerSecond'] for p in self.initial_scenario['phases']
                              if p['name'] == self.args.measurement_phase)
        quality = {name: cohort_quality(reports, indices, self.args.measurement_phase, requested_rate, merge_latency)
                   for name, indices in [('initial', self.initial_indices), ('added', self.late_indices)]}
        passed=(result['qualityPassed'] and all(q['passed'] for q in quality.values())
                and result['steadyStateCommonWindowSeconds']>=.9*self.args.growth_measurement_seconds)
        self.evidence.update(status='completed' if passed else 'failed',passed=passed,
            cohortQuality=quality, commonMeasurementSeconds=result['steadyStateCommonWindowSeconds'],
            messageCohort=result['measurementMessageCohort'],latency=result['measurementLatency'])
        self.save()
        return self.evidence


def cohort_quality(reports, indices, phase_name, requested_rate, merge_latency):
    selected = [reports[i] for i in indices if i < len(reports)]
    phases = [p for report in selected for p in report.get('scenarioPhases', []) if p['name']==phase_name]
    cohorts = [report.get('messageSendCohorts', {}).get(phase_name) for report in selected]
    if len(selected)!=len(indices) or len(phases)!=len(indices) or any(c is None for c in cohorts):
        return dict(passed=False, status='incomplete_reports')
    latency = merge_latency([c.get('messageEndToEndLatency', {}) for c in cohorts])
    acknowledged_rate = sum(p['messagesAcknowledged']/p['observedDurationSeconds']
                            for p in phases if p['observedDurationSeconds']>0)
    sent = sum(c['messagesSent'] for c in cohorts)
    acknowledged = sum(c['messagesAcknowledged'] for c in cohorts)
    upper = (latency or {}).get('p99UpperBoundExclusiveMilliseconds')
    passed = (sent>0 and sent==acknowledged and all(p['completed'] for p in phases)
              and latency is not None and latency.get('count')==sent
              and isinstance(upper,(int,float)) and upper<=500
              and acknowledged_rate>=requested_rate*.98
              and all(not r.get('terminalError') and all(r.get(k,0)==0 for k in
                      ('failed','workloadFailed','heartbeatMissed','scenarioMessageQueueOverflowed',
                       'scenarioMessageQueueAbandoned','queuedScenarioMessagesAtEnd')) for r in selected))
    return dict(passed=passed, requestedRate=requested_rate, acknowledgedPerSecond=acknowledged_rate,
                messagesSent=sent,messagesAcknowledged=acknowledged,latency=latency)
