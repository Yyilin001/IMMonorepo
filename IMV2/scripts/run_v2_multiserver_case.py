#!/usr/bin/env python3
"""Run one explicit multi-VM growth point and preserve its complete evidence.

This does not create VMs, rebalance a live cluster, or infer untested capacity.
Use the same VM budgets, binary manifest and workload model across comparisons.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import threading
import time
import uuid
import signal

from run_v2_horizontal_scaling import extract_result
from v2_benchmark_remote_process import validate_deployment
from v2_benchmark_container_process import request
from v2_benchmark_visibility import summarize_visibility
from v2_benchmark_receiver_latency import assess_receiver_latency
from v2_benchmark_space_guard import observe_space
from v2_benchmark_diagnostic_scope import mark_observation_only

ROOT = Path(__file__).resolve().parents[2]


def save(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')
    temporary.chmod(0o600)
    temporary.replace(path)


def resource_summary(directory):
    reports = [json.loads(p.read_text()) for p in directory.glob('report-*.json')]
    phases = [p for r in reports for p in r.get('scenarioPhases', []) if p['name'] == 'measured']
    if not reports or len(phases) != len(reports):
        return dict(status='no_complete_measurement_window')
    start = max(p['startedAtUnixMilliseconds'] for p in phases) / 1000
    end = min(p['endedAtUnixMilliseconds'] for p in phases) / 1000
    rows = []
    for path in directory.glob('remote-*/resources.jsonl'):
        spec = json.loads((path.parent / 'spec.json').read_text())
        samples = [json.loads(line) for line in path.read_text().splitlines()]
        samples = [s for s in samples if start <= s['time'] <= end and s.get('processStat')]
        if len(samples) < 2:
            continue
        def cpu(sample):
            fields = sample['processStat'].rpartition(')')[2].split()
            return (int(fields[11]) + int(fields[12])) / sample['ticksPerSecond']
        rss = []
        for sample in samples:
            for line in (sample.get('processStatus') or '').splitlines():
                if line.startswith('VmRSS:'):
                    rss.append(int(line.split()[1]) * 1024)
        rows.append(dict(process=spec['name'], profile=spec['profile'],
            sampledSeconds=samples[-1]['time']-samples[0]['time'],
            cpuCoreEquivalents=(cpu(samples[-1])-cpu(samples[0]))/(samples[-1]['time']-samples[0]['time']),
            sampledPeakRSSBytes=max(rss) if rss else None))
    return dict(status='sampled', commonWindowSeconds=end-start, processes=rows,
        scope='Per-process /proc CPU deltas and sampled RSS; excludes hypervisor and does not measure unique physical memory')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--deployment', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--nodes', type=int, choices=(1,2,4,8), required=True)
    parser.add_argument('--users', type=int, required=True)
    parser.add_argument('--rate', type=int, required=True)
    parser.add_argument('--seconds', type=int, default=180)
    parser.add_argument('--warmup-seconds', type=int, default=120)
    parser.add_argument('--warmup-rate', type=int, default=100)
    parser.add_argument('--parts', type=int)
    parser.add_argument('--port-base', type=int, default=20000)
    parser.add_argument('--measure-visibility', action='store_true')
    parser.add_argument('--diagnostic-observe-through-failures', action='store_true',
                        help='continue fault observation after failure guards; always excluded from capacity acceptance')
    parser.add_argument('--dynamic-membership', action='store_true')
    parser.add_argument('--live-scale-out-at', type=float)
    parser.add_argument('--live-user-growth', action='store_true')
    parser.add_argument('--continuous-user-growth', action='store_true')
    parser.add_argument('--growth-measurement-seconds', type=int, default=120)
    parser.add_argument('--live-scale-out-partitions', type=int, default=4)
    parser.add_argument('--live-scale-out-rebalance', action='store_true')
    parser.add_argument('--server-log-level', choices=('trace','debug','info','notice','warning','error','critical'))
    parser.add_argument('--candidate-send-path-trace-mode', choices=('off', 'sampled', 'all'), default='off',
                        help='Opt-in send-path and synchronous host-maintenance diagnostics.')
    parser.add_argument('--connection-ramp-per-second', type=int, default=200,
                        help='aggregate across all loader partitions')
    parser.add_argument('--connection-ramp-batch-size', type=int, default=4,
                        help='batch size per loader partition')
    args = parser.parse_args()
    if args.live_scale_out_rebalance and args.live_scale_out_at is None:
        parser.error('full partition redistribution requires live scale-out')
    parts = args.parts or args.nodes
    if not parts <= args.connection_ramp_per_second <= parts*1000 or args.connection_ramp_per_second % parts or not 1 <= args.connection_ramp_batch_size <= 1000:
        parser.error('aggregate connection ramp must divide evenly across loader partitions; valid batch size required')
    if not 120 <= args.users <= 100000 or args.users % parts or args.users // parts > 10000:
        parser.error('users must be 120...100000, evenly partitioned, at most 10000 per loader')
    if args.rate < 1 or args.seconds < 10 or args.warmup_seconds < 1 or args.warmup_rate < 1:
        parser.error('invalid duration or offered load')
    if not 1024 <= args.port_base <= 64000:
        parser.error('port base must be 1024...64000')
    if args.continuous_user_growth:
        args.live_user_growth = True
        if args.nodes != 1 or parts != 8 or args.users % 16 or args.seconds < 1500 or args.live_scale_out_partitions < 4:
            parser.error('continuous growth requires one initial node, eight paired load partitions, >=1500s measurement and >=4 transfers')
    if args.live_user_growth and (args.live_scale_out_at is None or parts < 2 or parts % 2 or args.users % 4
            or args.growth_measurement_seconds < 60 or args.seconds < args.growth_measurement_seconds + 240):
        parser.error('growth needs live expansion, two equal paired cohorts, even parts, >=60s new-user measurement and >=240s additional initial measurement')
    deployment = json.loads(args.deployment.read_text())
    validate_deployment(deployment, args.nodes, parts)
    out = args.output_dir.resolve()
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    save(out/'deployment.json', deployment)
    runtime = Path(deployment['runtime'])/'bin'
    visibility_id = str(uuid.uuid4()) if args.measure_visibility else None
    binaries = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in runtime.iterdir() if p.is_file()}
    save(out/'case.json', dict(nodes=args.nodes, users=args.users, targetRate=args.rate,
        measurementSeconds=args.seconds, warmupSeconds=args.warmup_seconds, loaderParts=parts,
        binarySHA256=binaries, workload='paired direct ring; 128-byte messages; no injected reconnects',
        liveUserGrowth=args.live_user_growth, initialUsers=args.users//8 if args.continuous_user_growth else args.users//2 if args.live_user_growth else args.users, peakTargetRate=args.rate*8 if args.continuous_user_growth else args.rate*2 if args.live_user_growth else args.rate,
        continuousUserGrowth=args.continuous_user_growth,
        fullPartitionRebalance=args.live_scale_out_rebalance,
        diagnosticObserveThroughFailures=args.diagnostic_observe_through_failures,
        sendPathTraceMode=args.candidate_send_path_trace_mode,
        liveScaleOut=args.live_scale_out_at is not None, dynamicMembership=args.dynamic_membership, receiverVisibilityRunID=visibility_id,
        connectionRampAggregatePerSecond=args.connection_ramp_per_second,
        connectionRampPerPartition=args.connection_ramp_per_second//parts,
        connectionRampBatchPerPartition=args.connection_ramp_batch_size, startedAt=time.time()))
    fixture = out/'fixture'
    with (out/'fixture.log').open('w') as log:
        subprocess.run([sys.executable, str(ROOT/'IMV2/scripts/prepare_v2_actor_realtime_direct_fixture.py'),
            '--output-dir', str(fixture), '--users', str(args.users), '--foreground-paired',
            '--seed','d0239f7a-684e-4b9d-89f1-052674203150'], check=True, stdout=log, stderr=subprocess.STDOUT)
    scenario = json.loads((ROOT/'IMV2/load-scenarios/high-active-50000-uuid-ab-5000.json').read_text())
    scenario.update(name=out.name, roomWarmupTimeoutSeconds=600,
                    completionDrainSeconds=30, postDrainHoldSeconds=10)
    scenario['phases'] = [dict(name=name, durationSeconds=seconds, messagesPerSecond=rate,
        roomLogReadsPerSecond=0, syncPullsPerSecond=0, reconnectPercentPerMinute=0)
        for name, seconds, rate in [('warmup',args.warmup_seconds,args.warmup_rate),('settle',10,0),('measured',args.seconds,args.rate)]]
    scenario['phases'][0]['sendSelection'] = 'round_robin'
    save(out/'scenario.json', scenario)
    pg = deployment.get('postgresManagementHost', deployment['processes']['account']['managementHost'])
    command = [sys.executable, str(ROOT/'IMV2/scripts/run_v2_actor_realtime_benchmark.py'),
        '--kind','candidate','--nodes',str(args.nodes),'--loader-partitions',str(parts),
        '--fixture',str(fixture),'--output-dir',str(out/'run'),
        '--server-deployment',str(out/'deployment.json'),
        '--candidate-binary',str(runtime/'IMV2ServerApp'),
        '--candidate-account-binary',str(runtime/'IMV2AccountServerApp'),
        '--candidate-placement-binary',str(runtime/'IMV2PlacementControlApp'),
        '--loader-binary',str(runtime/'IMV2GatewayLoadGenerator'),
        '--scenario',str(out/'scenario.json'),'--measurement-phase','measured','--allow-scaled-diagnostic',
        '--candidate-message-write-connections','8','--candidate-event-loop-threads','1',
        '--candidate-tcp-event-loop-threads','1','--shared-postgres','--pg-host',pg,
        '--pg-port','5432','--pg-user','bench','--actor-identity-seed','cc50ac35-0881-4366-9502-08f8bb6c118a',
        '--actor-port',str(args.port_base),'--gateway-port',str(args.port_base+100),
        '--metrics-port',str(args.port_base+200),'--account-port',str(args.port_base+300),
        '--https-port',str(args.port_base+400),'--placement-port',str(args.port_base+500),
        '--timeout-seconds',str(max(1200,args.seconds+args.warmup_seconds+900)),
        '--loader-report-drain-seconds','45','--drop-disposable-databases',
        '--loader-ramp-per-second',str(args.connection_ramp_per_second//parts),
        '--loader-ramp-batch-size',str(args.connection_ramp_batch_size)]
    if args.diagnostic_observe_through_failures:
        command += ['--diagnostic-observe-through-failures']
    if args.live_scale_out_at is not None:
        command += ['--live-scale-out-at', str(args.live_scale_out_at),
                    '--live-scale-out-partitions', str(args.live_scale_out_partitions)]
    if args.live_scale_out_rebalance:
        command += ['--live-scale-out-rebalance']
    if args.continuous_user_growth:
        command += ['--continuous-user-growth']
    if args.live_user_growth:
        command += ['--live-user-growth', '--growth-measurement-seconds', str(args.growth_measurement_seconds)]
    if args.dynamic_membership:
        command += ['--dynamic-membership']
    if args.server_log_level:
        command += ['--server-log-level', args.server_log_level]
    command += ['--candidate-send-path-trace-mode', args.candidate_send_path_trace_mode]
    if visibility_id:
        command += ['--visibility-run-id', visibility_id]
    save(out/'command.json', command)
    stop = threading.Event()
    sampler = None
    runner = None
    space_limit = {}
    pg_container = deployment.get('postgres')
    if pg_container:
        context, name = pg_container['dockerContext'], pg_container['container']
        if not context.startswith('colima-imv2-growth-') or not name.startswith('imv2-growth-'):
            raise ValueError('PostgreSQL sampling must target an owned growth-test container')
        labels = json.loads(subprocess.check_output(['docker','--context',context,'inspect',name,
            '--format','{{json .Config.Labels}}'],text=True))
        if labels.get('imv2.growth.owner') != pg_container['owner']:
            raise ValueError('PostgreSQL ownership label mismatch')
        socket = subprocess.check_output(['docker','context','inspect',context,
            '--format','{{.Endpoints.docker.Host}}'],text=True).strip()
        if not socket.startswith('unix://'):
            raise ValueError('expected an owned local VM Docker socket')
        preflight = observe_space(out, pg_container)
        save(out/'space-preflight.json', preflight)
        if not preflight['passed']:
            raise RuntimeError('Insufficient disk reserve before starting the benchmark')
        def sample():
            last_space = 0
            space_failures = 0
            with (out/'postgres-container-resources.jsonl').open('w') as stream:
                while not stop.is_set():
                    row = dict(time=time.time())
                    try:
                        value = request('GET',f'/containers/{name}/stats?stream=false&one-shot=true',socket_path=socket[7:])
                        row.update(cpu=value['cpu_stats'],memory=value['memory_stats'],blkio=value.get('blkio_stats'))
                    except Exception as error:
                        row['error'] = type(error).__name__
                    if row['time'] - last_space >= 30:
                        last_space = row['time']
                        try:
                            row['space'] = observe_space(out, pg_container)
                            space_failures = 0
                            if not row['space']['passed'] and not space_limit:
                                space_limit.update(time=row['time'], **row['space'])
                        except Exception as error:
                            space_failures += 1
                            row['spaceObservationError'] = type(error).__name__
                            if space_failures >= 3 and not space_limit:
                                space_limit.update(time=row['time'], reasons=['space_observation_unavailable'])
                        if space_limit and not space_limit.get('stopRequested') and runner is not None and runner.poll() is None:
                            space_limit['stopRequested'] = True
                            save(out/'environment-limit.json', space_limit)
                            runner.send_signal(signal.SIGINT)
                    stream.write(json.dumps(row)+'\n');stream.flush()
                    stop.wait(5)
        sampler = threading.Thread(target=sample,daemon=True)
    try:
        with (out/'runner.log').open('w') as log:
            runner = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
            if sampler:
                sampler.start()
            returncode = runner.wait()
    finally:
        stop.set()
        if sampler and sampler.ident is not None:
            sampler.join(timeout=35)
    directory = out/'run/candidate'
    def read(name):
        path = directory/name
        return json.loads(path.read_text()) if path.exists() else {}
    raw, cleanup = read('result.json'), read('service-cleanup.json')
    target_rate = args.rate * 8 if args.continuous_user_growth else args.rate * 2 if args.live_user_growth else args.rate
    result = extract_result(raw, cleanup, args.nodes, target_rate, returncode)
    result['environmentLimit'] = space_limit or None
    actual = result['acknowledgedPerSecond']
    result['offeredRateReached'] = isinstance(actual,(int,float)) and actual >= target_rate*.98
    remote = list(directory.glob('remote-*/started.json'))
    exits = [json.loads((p.parent/'finished.json').read_text()) for p in remote if (p.parent/'finished.json').exists()]
    result['remoteLifecyclePassed'] = bool(remote) and len(exits)==len(remote) and all(
        r['exitCode']==0 and not r['forced'] and r['stopReason']!='controller_lost' for r in exits)
    result['passed'] = result['passed'] and result['offeredRateReached'] and result['remoteLifecyclePassed'] and not space_limit
    if visibility_id:
        reports = [json.loads(p.read_text()) for p in sorted(directory.glob('report-*.json'))]
        result['receiverVisibility'] = summarize_visibility(reports, 'measured', visibility_id)
        result['receiverLatency'] = assess_receiver_latency(result['receiverVisibility'])
        result['passed'] = (result['passed'] and result['receiverVisibility']['passed']
                            and result['receiverLatency']['passed'])
        events = result['receiverVisibility']['events']
        observation_limits = {key: events[key] for key in (
            'foreignClock', 'capacityExceeded', 'invalidClockSamples', 'unknownCohort') if events.get(key, 0)}
        if observation_limits:
            result['measurementLimit'] = observation_limits
    if args.live_user_growth:
        result['userGrowth'] = read('user-growth.json')
        result['initialUsers'] = args.users//8 if args.continuous_user_growth else args.users//2
        result['initialTargetRate'] = args.rate
        result['passed'] = result['passed'] and result['userGrowth'].get('passed') is True
    result['capacityComparable'] = args.live_scale_out_at is None
    if args.live_scale_out_at is not None:
        expansion = read('live-expansion.json')
        result['liveExpansion'] = expansion
        result['initialNodes'] = args.nodes
        result['verifiedFinalNodes'] = expansion.get('targetNodes') if expansion.get('completed') is True else None
        result['passed'] = result['passed'] and expansion.get('completed') is True
    if args.live_scale_out_rebalance:
        stages = [directory]
        if args.continuous_user_growth:
            stages += [directory/'expansion-2-to-4', directory/'expansion-4-to-8']
        balance_evidence = []
        for stage in stages:
            proof_path, plan_path = stage/'partition-balance-verified.json', stage/'partition-balance-plan.json'
            proof = json.loads(proof_path.read_text()) if proof_path.exists() else {}
            plan = json.loads(plan_path.read_text()) if plan_path.exists() else {}
            passed = (proof.get('passed') is True and bool(plan.get('quotas'))
                      and proof.get('counts') == plan['quotas'])
            balance_evidence.append(dict(stage=str(stage.relative_to(directory)), passed=passed,
                                         counts=proof.get('counts'), plannedQuotas=plan.get('quotas')))
        result['partitionRebalance'] = dict(passed=all(row['passed'] for row in balance_evidence),
                                           stages=balance_evidence)
        result['passed'] = result['passed'] and result['partitionRebalance']['passed']
    result.update(users=args.users, failure=read('failure.json'), resources=resource_summary(directory),
                  liveScaleOut=args.live_scale_out_at is not None, finishedAt=time.time())
    mark_observation_only(result, args.diagnostic_observe_through_failures)
    save(out/'assessment.json',result)
    print(json.dumps({k: result.get(k) for k in ('nodes','users','targetRate','passed','acknowledgedPerSecond','endToEnd','failure')},ensure_ascii=False),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':
    sys.exit(main())
