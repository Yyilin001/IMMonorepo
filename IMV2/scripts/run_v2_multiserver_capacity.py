#!/usr/bin/env python3
"""Measure user growth across equal-sized business servers.

The default scales users and traffic with server count. The explicit throughput
profile searches a fixed-user throughput boundary. Neither profile injects faults
or proves online migration; use the continuous-growth case for that evidence.
"""
import argparse
import ast
import concurrent.futures
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent


def validate_runtime(runtime):
    required = ['IMV2ServerApp', 'IMV2AccountServerApp', 'IMV2PlacementControlApp',
                'IMV2GatewayLoadGenerator', 'IMV2TrustAdmissionTool']
    missing = [name for name in required if not (runtime/'bin'/name).is_file()
               or not os.access(runtime/'bin'/name, os.X_OK)]
    if missing:
        raise RuntimeError('Runtime missing executable binaries: '+', '.join(missing))


def local_inputs(paths):
    found, pending = set(), list(paths)
    while pending:
        path = pending.pop().resolve()
        if path in found:
            continue
        found.add(path)
        if path.suffix != '.py':
            continue
        for node in ast.walk(ast.parse(path.read_text())):
            names = ([alias.name for alias in node.names] if isinstance(node, ast.Import)
                     else [node.module] if isinstance(node, ast.ImportFrom) and node.module else [])
            for name in names:
                dependency = HERE/(name.split('.')[0]+'.py')
                if dependency.is_file():
                    pending.append(dependency)
    return sorted(found)


def resource_configuration(deployment, maximum_nodes=8, *, include_authority=False):
    postgres = deployment['postgres']
    profiles = {p['profile'] for role, p in deployment['processes'].items()
                if not role.startswith(('gateway-', 'edge-')) or int(role.rsplit('-', 1)[1]) < maximum_nodes}
    profiles.add(postgres['dockerContext'].removeprefix('colima-'))
    if include_authority:
        from v2_benchmark_dynamic_membership import authority_profile
        profiles.add(authority_profile(deployment))
    rows = [json.loads(line) for line in subprocess.check_output(['colima','list','--json'],text=True).splitlines()]
    selected = {row['name']: {k: row.get(k) for k in ('status','cpus','memory','disk','arch','address')}
                for row in rows if row['name'] in profiles}
    if set(selected) != profiles or any(row['status'] != 'Running' for row in selected.values()):
        raise RuntimeError('All required benchmark VMs must be running')
    pg = json.loads(subprocess.check_output(['docker','--context',postgres['dockerContext'],
        'inspect',postgres['container'],'--format','{{json .HostConfig}}'],text=True))
    settings = subprocess.check_output(['psql','-h',deployment['postgresManagementHost'],'-U','bench','-d','postgres','-Atc',
        "select name,setting from pg_settings where name in ('max_connections','shared_buffers','synchronous_commit','fsync','full_page_writes') order by name"],text=True)
    def network_limits(profile):
        output = subprocess.check_output(['colima','-p',profile,'ssh','--','sudo','-n','cat',
            '/proc/sys/net/netfilter/nf_conntrack_max','/sys/module/nf_conntrack/parameters/hashsize'],text=True,timeout=10)
        maximum, buckets = map(int, output.split())
        return profile, dict(conntrackMaximum=maximum, conntrackBuckets=buckets)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        network = dict(pool.map(network_limits, sorted(profiles)))
    return dict(vms=selected, postgresContainer={k:pg.get(k) for k in ('NanoCpus','Memory','CpusetCpus')},
                postgresSettings=settings, networkLimits=network)


def save(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')
    temporary.chmod(0o600)
    temporary.replace(path)



def measurement_integrity_failure(result, process_exit_code):
    """Only intact, fully observed runs may bracket a latency/rate boundary."""
    cohort = result.get('messageCohort') or {}
    cleanup = result.get('cleanup') or {}
    checks = {
        'case_process': process_exit_code == (0 if result.get('passed') is True else 1),
        'runner_exit': result.get('exitCode') == 0,
        'fixed_topology': result.get('capacityComparable') is True,
        'remote_lifecycle': result.get('remoteLifecyclePassed') is True,
        'message_cohort': (cohort.get('complete') is True
            and type(cohort.get('messagesSent')) is int and cohort['messagesSent'] > 0
            and cohort.get('messagesAcknowledged') == cohort['messagesSent']),
        'business_failures': result.get('businessFailures') == 0,
        'heartbeat': result.get('missedHeartbeats') == 0,
        'foreground': (result.get('foreground') or {}).get('passed') is True,
        'receiver_visibility': (result.get('receiverVisibility') or {}).get('passed') is True,
        'cleanup': (cleanup.get('settled') is True and cleanup.get('forcedKillCount') == 0
            and cleanup.get('exitFailureCount') == 0),
        'reported_failure': not result.get('failure'),
    }
    return [name for name, passed in checks.items() if not passed]


def growth_summary(cases, nodes, repeats, users_per_node, rate_per_node):
    """Report demonstrated load, never turn configured growth into capacity efficiency."""
    rows = []
    for n in nodes:
        runs = [c for c in cases if c['nodes'] == n]
        qualified = (len(runs) == repeats and all(c['result'].get('passed') is True
            and not measurement_integrity_failure(c['result'], c['exitCode']) for c in runs))
        rows.append(dict(nodes=n, users=n*users_per_node, targetRate=n*rate_per_node,
            verified=qualified, completedRuns=len(runs), requiredRuns=repeats,
            demonstratedUsers=n*users_per_node if qualified else None,
            acknowledgedPerSecond=[c['result'].get('acknowledgedPerSecond') for c in runs],
            sendLatency=[c['result'].get('endToEnd') for c in runs],
            receiverLatency=[c['result'].get('receiverVisibility', {}).get('latency') for c in runs],
            businessFailures=[c['result'].get('businessFailures') for c in runs],
            foreground=[c['result'].get('foreground') for c in runs],
            cases=[c['name'] for c in runs]))
    return dict(scope='Fixed per-user activity; users and traffic grow with server count.',
        capacityEstimateKind='demonstrated_load_only', liveScaleOut=False,
        capacityEfficiency=None, rows=rows,
        limitations=['Passing points demonstrate these loads, not maximum user capacity or linear capacity growth.',
            'Separate fixed-topology cases do not prove uninterrupted online expansion.',
            'VMs on a shared physical host do not establish independent-server performance.'])


def save_growth_report(out, summary):
    save(out/'user-growth.json', summary)
    def latency_text(values):
        parts = []
        for value in values:
            if not value or value.get('p99') is None:
                parts.append('—')
            elif value.get('p99UpperBoundExclusiveMilliseconds') is None:
                parts.append('≥'+str(value.get('overflowLowerBoundMilliseconds', value['p99'])))
            else:
                parts.append(str(value['p99']))
        return ' / '.join(parts) or '—'
    lines = ['# 用户增长与水平扩容验证', '',
        '每节点用户数及每用户发送频率固定；逐档增加业务服务器、用户和消息量。', '',
        '| 节点 | 用户 | 目标消息/秒 | 实际确认/秒，各轮 | 发送 P99 ms | 接收 P99 ms | 完成轮次 | 验证通过 |',
        '|---|---|---|---|---|---|---|---|']
    for row in summary['rows']:
        actual = ' / '.join(f'{v:.1f}' if isinstance(v, (int,float)) else '—'
                            for v in row['acknowledgedPerSecond']) or '—'
        lines.append(f'| {row["nodes"]} | {row["users"]} | {row["targetRate"]} | '
                     f'{actual} | {latency_text(row["sendLatency"])} | {latency_text(row["receiverLatency"])} | '
                     f'{row["completedRuns"]}/{row["requiredRuns"]} | {"是" if row["verified"] else "否"} |')
    lines += ['', '结果只证明已测负载，不代表用户容量上限或线性扩容效率。',
        '在线迁移单独验收；同宿主机 VM 的结果仅代表当前共享资源环境。',
        '逐轮发送/接收延迟、业务失败及前台一致性见 user-growth.json 和原始 assessment.json。', '']
    (out/'user-growth.md').write_text('\n'.join(lines))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--deployment', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--profile', choices=('user-growth', 'throughput'), default='user-growth')
    parser.add_argument('--nodes', type=int, nargs='+', choices=(1,2,4,8), default=[1,2,4,8])
    parser.add_argument('--users-per-node', type=int, default=1200)
    parser.add_argument('--rate-per-node', type=int, default=150)
    parser.add_argument('--measurement-seconds', type=int, default=600)
    parser.add_argument('--repeat', type=int, default=2)
    parser.add_argument('--maximum-rate', type=int, default=20000)
    parser.add_argument('--soak-seconds', type=int, default=7200)
    args = parser.parse_args()
    if args.profile == 'throughput' and (args.maximum_rate < 2000 or args.soak_seconds < 3600):
        parser.error('maximum rate must be >=2000; soak must be >=3600 seconds')
    if sorted(set(args.nodes)) != args.nodes:
        parser.error('nodes must be unique and increasing')
    if args.profile == 'user-growth' and (args.users_per_node < 120 or args.users_per_node % 16
            or args.users_per_node*max(args.nodes) > 80000 or args.rate_per_node < 1
            or args.measurement_seconds < 60 or args.repeat < 2):
        parser.error('growth requires users/node >=120 divisible by16, total users <=80000, positive rate, >=60s and >=2 repeats')
    out = args.output_dir.resolve()
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    deployment = json.loads(args.deployment.read_text())
    save(out/'deployment.json', deployment)
    files = [HERE/name for name in ('run_v2_multiserver_capacity.py', 'run_v2_multiserver_case.py',
        'run_v2_horizontal_scaling.py',
        'run_v2_actor_realtime_benchmark.py', 'v2_benchmark_remote_process.py',
        'v2_benchmark_ingress.py', 'v2_benchmark_https_edge.py', 'v2_native_placement_processes.py',
        'v2_benchmark_visibility.py', 'v2_benchmark_receiver_latency.py', 'v2_benchmark_space_guard.py',
        'v2_benchmark_diagnostic_scope.py')]
    files += [HERE/name for name in ('prepare_v2_actor_realtime_direct_fixture.py',
        'prepare_v2_virtual_actor_capacity_fixture.py', 'prepare_v2_room_actor_configuration.py',
        'v2_actor_realtime_fact_proof.py')]
    files += [HERE.parent/'load-scenarios/high-active-50000-uuid-ab-5000.json']
    files = local_inputs(files) + list((Path(deployment['runtime'])/'bin').iterdir())
    frozen = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in files if p.is_file()}
    save(out/'frozen-files.json', frozen)
    archived = {}
    for name in frozen:
        source = Path(name)
        if source.suffix in ('.py', '.json'):
            target = out/'frozen-sources'/source.relative_to(HERE.parents[1])
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(source.read_bytes())
            target.chmod(0o600)
            archived[name] = str(target.relative_to(out))
    save(out/'archived-source-files.json', archived)
    state = dict(status='preflight', startedAt=time.time(), users=10000, loaderParts=8,
        warmupSeconds=120, explorationSeconds=180, confirmationSeconds=600,
        confirmationRuns=3, relativeSearchResolution=.10, capacity={}, cases=[],
        liveScaleOut=False)
    state['profile'] = args.profile
    if args.profile == 'user-growth':
        state.update(users=None, usersPerNode=args.users_per_node, ratePerNode=args.rate_per_node,
            measurementSeconds=args.measurement_seconds, requiredRuns=args.repeat)
        for key in ('explorationSeconds', 'confirmationSeconds', 'confirmationRuns', 'relativeSearchResolution'):
            state.pop(key)

    def run(stage, nodes, rate, seconds, users=10000):
        for name, expected in frozen.items():
            if hashlib.sha256(Path(name).read_bytes()).hexdigest() != expected:
                raise RuntimeError('Frozen input changed: '+name)
        if resource_configuration(deployment, max(args.nodes)) != resources:
            raise RuntimeError('Resource configuration changed; do not mix incomparable cases')
        name = f'{len(state["cases"])+1:03d}-{stage}-n{nodes}-r{rate}'
        directory = out/name
        state['current'] = dict(name=name, nodes=nodes, users=users, targetRate=rate,
                                measurementSeconds=seconds, startedAt=time.time())
        save(out/'campaign.json', state)
        print('START '+name, flush=True)
        command = [sys.executable, str(HERE/'run_v2_multiserver_case.py'),
            '--deployment',str(out/'deployment.json'),'--output-dir',str(directory),
            '--nodes',str(nodes),'--parts','8','--users',str(users),'--rate',str(rate),
            '--seconds',str(seconds),'--warmup-seconds','120','--warmup-rate','500',
            '--server-log-level','warning','--measure-visibility']
        with (out/(name+'.log')).open('w') as log:
            completed = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
        path = directory/'assessment.json'
        result = json.loads(path.read_text()) if path.exists() else {}
        row = dict(name=name, stage=stage, nodes=nodes, users=users, rate=rate, seconds=seconds,
            exitCode=completed.returncode, result=result)
        state['cases'].append(row)
        state.pop('current', None)
        save(out/'campaign.json', state)
        print('FINISH '+name+' '+str(result.get('passed')), flush=True)
        if not result.get('measurementStarted'):
            raise RuntimeError('Measurement did not start; investigate admission/infrastructure: '+name)
        if result.get('environmentLimit'):
            raise RuntimeError('Storage/observation limit; do not infer a throughput boundary: '+name)
        if result.get('measurementLimit'):
            raise RuntimeError('Receiver observation limit; do not infer a service capacity boundary: '+name)
        integrity_failures = measurement_integrity_failure(result, completed.returncode)
        if integrity_failures:
            raise RuntimeError('Measurement integrity failed; investigate before capacity inference: '
                               + name + ': ' + ', '.join(integrity_failures))
        return bool(result.get('passed'))

    nodes = args.nodes
    try:
        save(out/'campaign.json', state)
        validate_runtime(Path(deployment['runtime']))
        resources = resource_configuration(deployment, max(nodes))
        save(out/'frozen-resource-configuration.json', resources)
        state['status'] = 'running'
        if args.profile == 'user-growth':
            for round_number in range(args.repeat):
                # Repeat in reverse order to expose time/order effects.
                for n in (nodes if round_number % 2 == 0 else list(reversed(nodes))):
                    if not run('growth', n, n*args.rate_per_node, args.measurement_seconds,
                               users=n*args.users_per_node):
                        raise RuntimeError('User-growth validation failed; inspect the failing point')
            state['status'] = 'completed'
            return
        # Identical offered rates, users, load processes and fixed PG resources.
        for rate in (500,1000,1500):
            for n in nodes:
                run('fixed', n, rate, 180)
        for n in nodes:
            measured = [c for c in state['cases'] if c['nodes'] == n]
            passes = [c['rate'] for c in measured if c['result']['passed']]
            if not passes:
                raise RuntimeError(f'No passing common-load baseline for {n} nodes')
            low = max(passes)
            failures = [c['rate'] for c in measured if not c['result']['passed'] and c['rate'] > low]
            high = min(failures) if failures else None
            while high is None and low < args.maximum_rate:
                rate = min(args.maximum_rate, max(low+50, math.ceil(low*1.25/50)*50))
                if run('search', n, rate, 180):
                    low = rate
                else:
                    high = rate
            while high is not None and high-low > max(50, low*.10):
                rate = max(low+50, ((low+high)//100)*50)
                if run('refine', n, rate, 180):
                    low = rate
                else:
                    high = rate
            state['capacity'][str(n)] = dict(candidate=low, nearestFailedAbove=high,
                searchCeilingReached=high is None, confirmations=[])
            save(out/'campaign.json', state)
        # Interleave sizes; a failed confirmation requires all three again at a lower rate.
        for round_number in range(1, 16):
            remaining = [n for n in nodes if len(state['capacity'][str(n)]['confirmations']) < 3]
            if not remaining:
                break
            offset = round_number % len(nodes)
            order = nodes[offset:] + nodes[:offset]
            for n in order:
                if n not in remaining:
                    continue
                cap = state['capacity'][str(n)]
                rate = cap['candidate']
                if run('confirm', n, rate, 600):
                    cap['confirmations'].append(state['cases'][-1]['name'])
                else:
                    cap['nearestFailedAbove'] = rate
                    cap['searchCeilingReached'] = False
                    cap['candidate'] = math.floor(rate*.9/50)*50
                    cap['confirmations'] = []
                    if cap['candidate'] < 100:
                        raise RuntimeError('No stable confirmation range remains')
                save(out/'campaign.json', state)
        if any(len(c['confirmations']) != 3 for c in state['capacity'].values()):
            raise RuntimeError('Confirmation budget exhausted; capacity remains unproven')
        base_node = nodes[0]
        base = state['capacity'][str(base_node)]['candidate']
        for n in nodes:
            cap = state['capacity'][str(n)]
            cap['confirmedRate'] = cap['candidate']
            cap['capacityEstimateKind'] = 'lower_bound' if cap['searchCeilingReached'] else 'bracketed'
            cap['confirmedRateRatio'] = cap['confirmedRate']/base
            # A search ceiling gives only a demonstrated lower bound. Ratios
            # of such bounds do not identify capacity speedup or efficiency.
            comparable = not (cap['searchCeilingReached'] or state['capacity'][str(base_node)]['searchCeilingReached'])
            cap['speedup'] = cap['confirmedRateRatio'] if comparable else None
            cap['efficiency'] = cap['speedup']/(n/base_node) if comparable else None
        soak_node = nodes[-1]
        soak_rate = max(50, math.floor(state['capacity'][str(soak_node)]['confirmedRate']*.6/50)*50)
        state['soakPassed'] = run('soak', soak_node, soak_rate, args.soak_seconds)
        if not state['soakPassed']:
            raise RuntimeError('Sustained-load validation failed; capacity campaign remains unproven')
        state['status'] = 'completed'
    except Exception as error:
        state['status'] = 'needs_investigation'
        state['error'] = str(error)
        raise
    finally:
        if args.profile == 'user-growth':
            save_growth_report(out, growth_summary(state['cases'], nodes, args.repeat,
                args.users_per_node, args.rate_per_node))
        state['updatedAt'] = time.time()
        save(out/'campaign.json', state)


if __name__ == '__main__':
    main()
