#!/usr/bin/env python3
"""Measure 1/2/4 resource-isolated business nodes on one Linux Docker host.

Each simulated server owns one pinned vCPU and 3 GiB across Gateway/RoomHost
and its HTTPS edge. Four loader partitions, the PG primary and control plane
retain fixed independent CPU sets. Loopback transport is deliberately disclosed.
"""
import argparse
from collections import defaultdict
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import threading
import time
import urllib.parse
import uuid
from v2_benchmark_container_process import request

ROOT = Path(__file__).resolve().parents[2]
PRODUCTS = ('IMV2ServerApp','IMV2AccountServerApp','IMV2PlacementControlApp','IMV2GatewayLoadGenerator')
GIB = 1024**3


def write(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2)+'\n'); temporary.chmod(0o600)
    temporary.replace(path)


def extract_result(raw, cleanup, nodes, rate, exit_code):
    cohort = raw.get('measurementMessageCohort', {})
    latency = raw.get('measurementLatency', {}).get('messageEndToEndLatency')
    foreground = raw.get('foregroundDelivery', {})
    upper = (latency or {}).get('p99UpperBoundExclusiveMilliseconds')
    passed = (exit_code == 0 and raw.get('qualityPassed') is True and cohort.get('complete') is True
        and latency is not None and latency.get('count',0)>0
        and type(upper) in (int, float) and upper <= 500
        and raw.get('heartbeatMissed') == 0 and foreground.get('passed') is True
        and cleanup.get('settled') is True and cleanup.get('forcedKillCount') == 0
        and cleanup.get('exitFailureCount') == 0)
    return dict(nodes=nodes, targetRate=rate, passed=passed, exitCode=exit_code,
        acknowledgedPerSecond=raw.get('acknowledgedMessagesPerSecond'),
        messageCohort=cohort, endToEnd=latency, online=raw.get('peakActive'),
        businessFailures=raw.get('workloadFailed'), missedHeartbeats=raw.get('heartbeatMissed'),
        measurementStarted=cohort.get('messagesSent',0)>0,
        foreground=foreground, cleanup=cleanup)


def resource_summary(directory):
    phases=[]
    for report in (directory/'run/candidate').glob('report-*.json'):
        phases += [p for p in json.loads(report.read_text()).get('scenarioPhases',[]) if p['name']=='measured']
    if len(phases)!=4:return dict(status='measurement_window_missing')
    start=max(p['startedAtUnixMilliseconds'] for p in phases)/1000
    end=min(p['endedAtUnixMilliseconds'] for p in phases)/1000
    by_id=defaultdict(list)
    for line in (directory/'container-resources.jsonl').read_text().splitlines():
        row=json.loads(line)
        if 'id' in row:by_id[row['id']].append(row)
    totals=defaultdict(lambda:dict(cpuCoreEquivalents=0,memoryPeakBytes=0,throttledSeconds=0,containers=0))
    for samples in by_id.values():
        samples=sorted((s for s in samples if start<=s['time']<=end),key=lambda s:s['time'])
        if len(samples)<2:continue
        first,last=samples[0],samples[-1];seconds=last['time']-first['time']
        cpu=(last['cpu']['cpu_usage']['total_usage']-first['cpu']['cpu_usage']['total_usage'])/1e9/seconds
        role=first['role'];total=totals[role];total['cpuCoreEquivalents']+=cpu
        total['memoryPeakBytes']+=max(s['memory'].get('usage',0) for s in samples)
        total['throttledSeconds']+=max(0,last['cpu'].get('throttling_data',{}).get('throttled_time',0)-first['cpu'].get('throttling_data',{}).get('throttled_time',0))/1e9
        total['containers']+=1
    return dict(status='sampled_container_counters',commonWindowSeconds=end-start,roles=dict(totals),
        scope='CPU deltas between in-window samples; memory is summed per-container sampled peaks, not unique physical memory')


def scaling_rows(results):
    capacities={n:max((r['targetRate'] for r in results if r['nodes']==n and r['passed']),default=None) for n in (1,2,4)}
    baseline=capacities[1]
    return [dict(nodes=n, highestPassingNominalRate=capacities[n],
        firstFailingNominalRate=min((r['targetRate'] for r in results if r['nodes']==n and not r['passed'] and r.get('measurementStarted',True)),default=None),
        measuredSpeedup=capacities[n]/baseline if baseline and capacities[n] else None,
        scalingEfficiency=capacities[n]/baseline/n if baseline and capacities[n] else None)
        for n in (1,2,4)]


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--docker-context',default='colima-imv2-tests')
    parser.add_argument('--image',default='imv2-goal-capacity:20261015')
    parser.add_argument('--output-dir',required=True,type=Path)
    parser.add_argument('--users',type=int,default=10000)
    parser.add_argument('--binary-cache',default='imv2_swiftpm-build-cache')
    parser.add_argument('--maximum-rate',type=int,default=10000)
    parser.add_argument('--actor-identity-seed', type=uuid.UUID,
        default=uuid.UUID('cc50ac35-0881-4366-9502-08f8bb6c118a'))
    parser.add_argument('--case', action='append', default=[], metavar='NODES:MSG_PER_SECOND',
        help='Explicit diagnostic cases in order; skips capacity search')
    parser.add_argument('--smoke',action='store_true',help='120 users, one short 100 msg/s node; not a scaling result')
    args=parser.parse_args()
    cases=[]
    for value in args.case:
        try:
            nodes, rate=map(int,value.split(':'))
            if nodes not in (1,2,4) or not 1<=rate<=args.maximum_rate: raise ValueError()
        except ValueError:parser.error('case must be 1/2/4:rate within maximum-rate')
        cases.append((nodes,rate))
    if cases and args.smoke:parser.error('case and smoke are separate diagnostic modes')
    if args.output_dir.exists():parser.error('output directory must be new')
    if not 120<=args.users<=10000 or args.users%4:parser.error('users must be 120...10000 and divisible by four')
    out=args.output_dir.resolve();out.mkdir(mode=0o700,parents=True)
    docker=['docker','--context',args.docker_context]
    def cli(*command, **kw):return subprocess.run(docker+list(command),check=True,**kw)
    endpoint=subprocess.check_output(docker+['context','inspect',args.docker_context,'--format','{{.Endpoints.docker.Host}}'],text=True).strip()
    if not endpoint.startswith('unix://'):raise RuntimeError('requires an explicit local Linux Docker socket')
    def api(method,path,body=None):return request(method,path,body,socket_path=endpoint[7:])
    info=api('GET','/info')
    if info['NCPU']<12 or info['MemTotal']<28*GIB:raise RuntimeError('simulation requires 12 vCPUs and at least 28 GiB in the owned Linux host')
    family='imv2-scale-'+uuid.uuid4().hex[:10]
    controller=family+'-controller';postgres=family+'-postgres';volume=family+'-data'
    write(out/'environment.json',dict(familyID=family,volume=volume,controller=controller,postgres=postgres,
        dockerContext=args.docker_context,sourceRoot=str(ROOT),image=args.image))
    cli('volume','create',volume,stdout=subprocess.DEVNULL)
    labels={'imv2.scale.family':family}
    mounts=[dict(Type='bind',Source=str(ROOT),Target='/workspace',ReadOnly=True),
            dict(Type='volume',Source=volume,Target='/scale')]
    controller_spec=dict(Image=args.image,Entrypoint=[],Cmd=['sleep','infinity'],WorkingDir='/workspace',Labels=labels,
        HostConfig=dict(NetworkMode='none',Sysctls={'net.ipv4.ip_local_port_range':'42000 47999'},
            CpusetCpus='10,11',NanoCpus=2*10**9,Memory=2*GIB,
            Mounts=mounts+[dict(Type='bind',Source='/var/run/docker.sock',Target='/var/run/docker.sock'),
                dict(Type='volume',Source=args.binary_cache,Target='/build',ReadOnly=True)],
            Ulimits=[dict(Name='nofile',Soft=200000,Hard=200000)]))
    api('POST','/containers/create?name='+controller,controller_spec);api('POST','/containers/'+controller+'/start')
    results=[];ordinal=0;cancelled=False
    def terminate(signum,_):
        raise KeyboardInterrupt('scaling interrupted')
    signal.signal(signal.SIGTERM,terminate);signal.signal(signal.SIGINT,terminate)
    try:
        cli('exec',controller,'bash','-lc','mkdir -p /scale/binaries /scale/postgres /scale/runs; chown 1001:1001 /scale/postgres')
        cli('exec',controller,'python3','-c',
            "import shutil;assert shutil.disk_usage('/scale').free>=2*1024**3,'need at least 2 GiB free in owned VM'")
        for product in PRODUCTS:
            cli('exec',controller,'cp','/build/IMV2Server/release/'+product,'/scale/binaries/'+product)
            cli('exec',controller,'strip','--strip-debug','/scale/binaries/'+product)
        port_range=subprocess.check_output(docker+['exec',controller,'cat','/proc/sys/net/ipv4/ip_local_port_range'],text=True).split()
        if port_range!=['42000','47999']:raise RuntimeError('isolated ephemeral port range did not apply')
        binary_hashes=json.loads(subprocess.check_output(docker+['exec',controller,'python3','-c',
            "import hashlib,json,pathlib;print(json.dumps({p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in pathlib.Path('/scale/binaries').iterdir()}))"],text=True))
        users=120 if args.smoke else args.users
        cli('exec',controller,'python3','IMV2/scripts/prepare_v2_actor_realtime_direct_fixture.py',
            '--output-dir','/scale/fixture','--seed','d0239f7a-684e-4b9d-89f1-052674203150',
            '--users',str(users),'--foreground-paired',stdout=subprocess.DEVNULL)
        pg_spec=dict(Image=args.image,Entrypoint=[],User='1001:1001',Labels=dict(labels,**{'imv2.scale.role':'postgres'}),
            Cmd=['bash','-lc','initdb -D /scale/postgres/data -A trust -U bench --no-locale >/scale/postgres/init.log && exec postgres -D /scale/postgres/data -h 127.0.0.1 -p 49000 -k /scale/postgres -c max_connections=320 -c shared_buffers=512MB'],
            HostConfig=dict(NetworkMode='container:'+controller,Mounts=mounts,CpusetCpus='4,5',NanoCpus=2*10**9,Memory=4*GIB,MemorySwap=4*GIB))
        api('POST','/containers/create?name='+postgres,pg_spec);api('POST','/containers/'+postgres+'/start')
        for _ in range(60):
            if subprocess.run(docker+['exec',controller,'pg_isready','-h','127.0.0.1','-p','49000','-U','bench'],stdout=subprocess.DEVNULL).returncode==0:break
            time.sleep(.5)
        else:raise RuntimeError('owned database startup failed')
        metadata=dict(familyID=family,volume=volume,controller=controller,postgres=postgres,
            commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
            users=users,loaderPartitions=4,binarySHA256=binary_hashes,
            actorIdentitySeed=str(args.actor_identity_seed),diagnosticCases=cases,
            isolatedNetworkEphemeralPortRange=[42000,47999],explicitLoaderSourceRange=[1024,41023],
            resources=dict(businessServer=dict(vCPU=1,memoryGiB=3,writeConnections=8,databaseEventLoops=1,tcpEventLoops=1),
                sharedPostgres=dict(vCPU=2,memoryGiB=4,sharedBuffersMiB=512),
                loaders=dict(vCPU=4,partitions=4,memoryGiB=6),controlCPUSet='10,11'),
            limits=['single physical host and kernel','shared isolated loopback network, no cross-machine RTT',
                    'PG remains one fixed primary','capacity estimates are bounded by sampled offered rates'],smoke=args.smoke)
        write(out/'configuration.json',metadata)
        cli('cp',controller+':/scale/fixture/manifest.json',str(out/'fixture-manifest.json'))
        def run(nodes,rate,repeat=False):
            nonlocal ordinal
            ordinal+=1;run_id=family+f'-r{ordinal}-n{nodes}-{rate}'
            local=out/f'r{ordinal}-n{nodes}-{rate}';local.mkdir(mode=0o700)
            remote='/scale/runs/'+local.name
            scenario=json.loads((ROOT/'IMV2/load-scenarios/high-active-50000-uuid-ab-5000.json').read_text())
            scenario.update(name=local.name,roomWarmupTimeoutSeconds=600,completionDrainSeconds=30,postDrainHoldSeconds=10,
                schedulerTicksPerSecond=10)
            def phase(name,seconds,load,selection=None):
                value=dict(name=name,durationSeconds=seconds,messagesPerSecond=load,roomLogReadsPerSecond=0,syncPullsPerSecond=0,reconnectPercentPerMinute=0)
                if selection:value['sendSelection']=selection
                return value
            scenario['phases']=[phase('warmup',5 if args.smoke else 60,100 if args.smoke else 200,'round_robin'),
                phase('settle',2 if args.smoke else 10,0),phase('measured',10 if args.smoke else 60,rate)]
            launcher=dict(familyID=family,runID=run_id,image=args.image,networkContainer=controller,mounts=mounts,
                gatewayCPUs=[0,1,2,3],evidenceDirectory=remote+'/containers',
                roles=dict(gateway=dict(cpuset='',cpus=1,memoryBytes=2816*1024**2),
                    edge=dict(cpuset='',cpus=1,memoryBytes=256*1024**2),
                    loader=dict(cpuset='6,7,8,9',cpus=4,memoryBytes=1536*1024**2),
                    infrastructure=dict(cpuset='10,11',cpus=2,memoryBytes=GIB)))
            write(local/'scenario.json',scenario);write(local/'launcher.json',launcher)
            cli('exec',controller,'mkdir','-p',remote)
            for name in ('scenario.json','launcher.json'):cli('cp',str(local/name),controller+':'+remote+'/'+name)
            cli('exec',controller,'/scale/binaries/IMV2GatewayLoadGenerator','--validate-scenario',remote+'/scenario.json',stdout=subprocess.DEVNULL)
            base=50000+ordinal*200
            command=['python3','IMV2/scripts/run_v2_actor_realtime_benchmark.py','--kind','candidate',
                '--fixture','/scale/fixture','--output-dir',remote+'/run','--nodes',str(nodes),'--loader-partitions','4',
                '--maximum-rooms-per-host','20000','--process-launcher-config',remote+'/launcher.json',
                '--actor-identity-seed',str(args.actor_identity_seed),
                '--candidate-binary','/scale/binaries/IMV2ServerApp','--candidate-account-binary','/scale/binaries/IMV2AccountServerApp',
                '--candidate-placement-binary','/scale/binaries/IMV2PlacementControlApp','--loader-binary','/scale/binaries/IMV2GatewayLoadGenerator',
                '--scenario',remote+'/scenario.json','--measurement-phase','measured','--allow-scaled-diagnostic',
                '--candidate-message-write-connections','8','--candidate-event-loop-threads','1','--candidate-tcp-event-loop-threads','1',
                '--candidate-message-write-pipeline-depth','2','--candidate-send-path-trace-mode','off',
                '--shared-postgres','--pg-host','127.0.0.1','--pg-user','bench','--pg-port','49000',
                '--pg-bin-directory','/usr/lib/postgresql/16/bin','--gateway-port',str(base+20),'--actor-port',str(base),
                '--metrics-port',str(base+40),'--account-port',str(base+50),'--https-port',str(base+55),
                '--placement-port',str(base+100),'--loader-local-port-base','1024','--timeout-seconds','1000',
                '--loader-report-drain-seconds','45','--drop-disposable-databases']
            write(local/'command.json',command)
            stop=threading.Event()
            def monitor():
                with (local/'container-resources.jsonl').open('w') as stream:
                    while not stop.is_set():
                        filters=urllib.parse.quote(json.dumps({'label':['imv2.scale.run='+run_id]}))
                        try:
                            containers=api('GET','/containers/json?filters='+filters)
                            containers.append(dict(Id=postgres,Names=[postgres],Labels={'imv2.scale.role':'postgres'}))
                            for container in containers:
                                try:
                                    sample=api('GET','/containers/'+container['Id']+'/stats?stream=false&one-shot=true')
                                    stream.write(json.dumps(dict(time=time.time(),id=container['Id'],name=container['Names'][0],
                                        role=container['Labels']['imv2.scale.role'],cpu=sample['cpu_stats'],
                                        memory=sample['memory_stats'],blkio=sample.get('blkio_stats')))+'\n')
                                except Exception as error:stream.write(json.dumps(dict(time=time.time(),error=type(error).__name__))+'\n')
                            stream.flush()
                        except Exception:pass
                        stop.wait(5)
            thread=threading.Thread(target=monitor,daemon=True);thread.start()
            print(json.dumps(dict(event='start',nodes=nodes,rate=rate,run=local.name,repeat=repeat)),flush=True)
            try:
                with (local/'runner.log').open('w') as log:
                    process=subprocess.run(docker+['exec',controller]+command,stdout=log,stderr=subprocess.STDOUT,timeout=1250)
            finally:stop.set();thread.join(timeout=35)
            cli('cp',controller+':'+remote+'/run',str(local/'run'),stdout=subprocess.DEVNULL)
            cli('cp',controller+':'+remote+'/containers',str(local/'containers'),stdout=subprocess.DEVNULL)
            raw=json.loads((local/'run/candidate/result.json').read_text())
            cleanup=json.loads((local/'run/candidate/service-cleanup.json').read_text())
            result=extract_result(raw,cleanup,nodes,rate,process.returncode)
            topology=json.loads((local/f'run/actors{nodes}/topology.json').read_text())
            ordered=sorted(topology['hostIDs'],key=lambda name:topology['hostIDs'][name])
            owners=[ordered[p%nodes] for p in range(256)]
            placement=dict(identitySeed=topology['identitySeed'],hostIDs=topology['hostIDs'],
                partitionCount=256,sortedHostNames=ordered,
                partitionOwnerSHA256=hashlib.sha256(json.dumps(owners).encode()).hexdigest())
            write(local/'initial-placement.json',dict(placement,partitionOwners=owners))
            result.update(run=local.name,repeat=repeat,resources=resource_summary(local))
            result['placement']=placement
            results.append(result);write(local/'assessment.json',result)
            write(out/'progress.json',dict(results=results,scaling=None if cases else scaling_rows(results),finished=False))
            print(json.dumps(dict(event='result',**result)),flush=True)
            # Remove only this run's settled containers. Keep all logs and states.
            filters=urllib.parse.quote(json.dumps({'label':['imv2.scale.run='+run_id]}))
            for container in api('GET','/containers/json?all=1&filters='+filters):
                state=api('GET','/containers/'+container['Id']+'/json')['State']
                if state['Running']:raise RuntimeError('process remained alive after runner cleanup')
                api('DELETE','/containers/'+container['Id'])
            if not result['passed'] and not result['measurementStarted']:
                raise RuntimeError('premeasurement failure; not a capacity upper bound')
            return result
        if cases:
            for nodes,rate in cases:run(nodes,rate)
        elif args.smoke:
            if not run(1,100)['passed']: raise RuntimeError('simulation smoke quality failed')
        else:
            for nodes in (1,2,4):
                common=run(nodes,500)
                if not common['passed']:raise RuntimeError('common-rate baseline failed; inspect evidence before further expansion')
                best=500;failed=None;candidate=1000*nodes
                while candidate<=args.maximum_rate:
                    result=run(nodes,candidate)
                    if not result['passed']:failed=candidate;break
                    best=candidate;candidate*=2
                if failed is not None:
                    while failed-best>500:
                        middle=((best+failed)//1000)*500
                        if middle<=best:break
                        if run(nodes,middle)['passed']:best=middle
                        else:failed=middle
                confirmation=run(nodes,best,repeat=True)
                if not confirmation['passed']:raise RuntimeError('highest passing rate did not reproduce')
        write(out/'result.json',dict(results=results,scaling=None if cases else scaling_rows(results),finished=True,smoke=args.smoke,
            mode='fixed_cases' if cases else 'smoke' if args.smoke else 'capacity_search'))
    finally:
        signal.signal(signal.SIGINT,signal.SIG_IGN)
        signal.signal(signal.SIGTERM,signal.SIG_IGN)
        # All state belongs to this unique family; no other Docker workloads are touched.
        filters=urllib.parse.quote(json.dumps({'label':['imv2.scale.family='+family]}))
        owned=api('GET','/containers/json?all=1&filters='+filters)
        cleanup=[]
        owned.sort(key=lambda c: 2 if '/'+controller in c['Names'] else 1 if '/'+postgres in c['Names'] else 0)
        for container in owned:
            identifier=container['Id']
            try:
                state=api('GET','/containers/'+identifier+'/json')['State']
                if state['Running']:
                    api('POST','/containers/'+identifier+'/stop?t=10')
                    state=api('GET','/containers/'+identifier+'/json')['State']
                cleanup.append(dict(id=identifier,exitCode=state['ExitCode'],oomKilled=state['OOMKilled'],running=state['Running']))
            except Exception as error:cleanup.append(dict(id=identifier,error=type(error).__name__))
        write(out/'family-cleanup.json',cleanup)
        # Preserve the owned volume and stopped controller/DB for reproducibility.
        if any('/'+postgres in c['Names'] for c in owned):
            cli('cp',postgres+':/scale/postgres/init.log',str(out/'postgres-init.log'),stdout=subprocess.DEVNULL)
            with (out/'postgres.log').open('w') as log:
                cli('logs',postgres,stdout=log,stderr=subprocess.STDOUT)


if __name__=='__main__':main()
