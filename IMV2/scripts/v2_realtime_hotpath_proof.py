"""Offline proof of zero observed address-source SQL in a real publish window.

Only route_lookup/realtime_owner_snapshot SQL-future counters are covered.
Business authorization, registration, recovery heads, persistence and control
leases remain SQL-backed. No ACK counter or obsolete route-query zero is proof.
This never changes benchmark quality, rewrites old results, or accesses a DB.
"""
import argparse
from decimal import Decimal, InvalidOperation
import json
import math
import os
from pathlib import Path
import re

NODES = 6
PARTS = 12
MINIMUM_PUBLISHES = 10000
SOURCES = ('route_lookup','realtime_owner_snapshot')
PHASES = ('fence','read_body','transaction_control','other')
STAGES = ('gate_queued','awaiting_driver','between_sql','sql')
PREFIX = 'im_v2_database_loan_observation'
PUBLISH = 'im_v2_actor_realtime_publish_settled_total'
SCOPE = 'Observed route_lookup/realtime_owner_snapshot actual SQL futures only; excludes business registration/authorization/recovery heads/persistence/control leases and unclassified SQL. No ACK substitution.'


class Incomplete(ValueError): pass


def number(value):
    if type(value) not in (int,float) or not math.isfinite(value): raise Incomplete('timestamp_invalid')
    return value


def integer(value):
    try: parsed = Decimal(value)
    except InvalidOperation: raise Incomplete('metric_value_invalid') from None
    if not parsed.is_finite() or parsed < 0 or parsed != parsed.to_integral_value():
        raise Incomplete('metric_value_invalid')
    return int(parsed)


def metrics(body):
    selected = {}
    for line in body.splitlines():
        if line.startswith('#'): continue
        match = re.fullmatch(r'([^ {]+)(?:\{([^}]*)\})?\s+([^ ]+)(?:\s+[^ ]+)?',line)
        if not match: continue
        name,raw_labels,value=match.groups()
        if name not in (PUBLISH,PREFIX+'_sql_duration_count',PREFIX+'_active'): continue
        labels = dict(re.findall(r'(\w+)="([^"\\]*)"',raw_labels or ''))
        if name==PUBLISH:
            if labels: continue
            key='publish'
        elif labels.get('source') in SOURCES:
            if name==PREFIX+'_sql_duration_count' and labels.get('phase') in PHASES:
                key=('sql',labels['source'],labels['phase'])
            elif name==PREFIX+'_active' and labels.get('stage') in STAGES:
                key=('active',labels['source'],labels['stage'])
            else: continue
        else: continue
        if key in selected: raise Incomplete('duplicate_metric')
        selected[key]=integer(value)
    required={'publish'} | {('sql',s,p) for s in SOURCES for p in PHASES} | {('active',s,p) for s in SOURCES for p in STAGES}
    if selected.keys()!=required: raise Incomplete('required_metrics_missing')
    return selected


def phase_intersection(reports, phase):
    if len(reports)!=PARTS: raise Incomplete('reports_missing')
    spans=[]
    for report in reports:
        matches=[item for item in report.get('scenarioPhases',[]) if item.get('name')==phase]
        if len(matches)!=1 or matches[0].get('completed') is not True: raise Incomplete('phase_missing_or_incomplete')
        item=matches[0]
        start,end=item.get('startedAtUnixMilliseconds'),item.get('endedAtUnixMilliseconds')
        if type(start) is not int or type(end) is not int or end<=start: raise Incomplete('phase_timestamps_invalid')
        spans.append((start/1000,end/1000))
    start,end=max(x[0] for x in spans),min(x[1] for x in spans)
    if end<=start: raise Incomplete('phase_intersection_empty')
    return start,end


def sample_metrics(sample):
    start=number(sample.get('samplingStartedAtUnixSeconds'))
    end=number(sample.get('samplingCompletedAtUnixSeconds'))
    if end<start: raise Incomplete('sampling_clock_invalid')
    nodes={}
    for item in sample.get('samples',[]):
        node=item.get('node')
        if type(node) is not int or node not in range(NODES) or node in nodes: raise Incomplete('node_set_invalid')
        if 'error' in item or not isinstance(item.get('body'),str): raise Incomplete('node_read_failed')
        a=number(item.get('samplingStartedAtUnixSeconds'))
        b=number(item.get('samplingCompletedAtUnixSeconds'))
        if not start<=a<=b<=end: raise Incomplete('node_sampling_clock_invalid')
        nodes[node]=metrics(item['body'])
    if set(nodes)!=set(range(NODES)): raise Incomplete('nodes_missing')
    return start,end,nodes


def prove(reports,samples,phase):
    result=dict(formatVersion=1,status='incomplete',passed=False,scope=SCOPE,
                requiredPublishSettledDelta=MINIMUM_PUBLISHES,phase=phase,
                benchmarkQualityModified=False,historicalResultsModified=False)
    try:
        phase_start,phase_end=phase_intersection(reports,phase)
        result['commonPhase']=dict(start=phase_start,end=phase_end)
        selected=[]
        for sample in samples:
            # Never silently use legacy batch-end timestamps as HTTP read start.
            if 'samplingStartedAtUnixSeconds' not in sample:
                if phase_start<=number(sample.get('time'))<=phase_end:
                    raise Incomplete('actual_sampling_timestamps_missing')
                continue
            start=number(sample.get('samplingStartedAtUnixSeconds'))
            end=number(sample.get('samplingCompletedAtUnixSeconds'))
            if phase_start<=start<=end<=phase_end:
                selected.append(sample_metrics(sample))
        if len(selected)<2: raise Incomplete('phase_complete_samples_insufficient')
        for previous,current in zip(selected,selected[1:]):
            if current[0]<previous[1]: raise Incomplete('sampling_overlap_or_clock_regression')
            for node in range(NODES):
                for key,value in previous[2][node].items():
                    if key=='publish' or isinstance(key,tuple) and key[0]=='sql':
                        if current[2][node][key]<value: raise Incomplete('counter_reset')
        first,last=selected[0],selected[-1]
        publishes=sum(last[2][node]['publish']-first[2][node]['publish'] for node in range(NODES))
        deltas={source:sum(last[2][node][('sql',source,p)]-first[2][node][('sql',source,p)]
            for node in range(NODES) for p in PHASES) for source in SOURCES}
        pending=sum(sample[2][node][('active',source,stage)] for sample in (first,last)
            for node in range(NODES) for source in SOURCES for stage in STAGES)
        result.update(window=dict(firstSamplingStart=first[0],firstSamplingEnd=first[1],
            lastSamplingStart=last[0],lastSamplingEnd=last[1],completeSamples=len(selected)),
            publishSettledDelta=publishes,addressSQLDeltas=deltas,addressBoundaryActive=pending)
        if publishes<MINIMUM_PUBLISHES: raise Incomplete('publish_window_below_10000')
        reasons=[]
        if any(deltas.values()): reasons.append('address_sql_observed')
        if pending: reasons.append('address_work_pending_at_boundary')
        result.update(status='failed' if reasons else 'passed',passed=not reasons,reasons=reasons)
    except (Incomplete,KeyError,TypeError,ValueError) as error:
        result['reasons']=[str(error) if isinstance(error,Incomplete) else 'input_invalid']
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory',type=Path,required=True,help='one revision report/metrics directory')
    parser.add_argument('--phase',required=True)
    parser.add_argument('--output',type=Path,required=True,help='new dedicated proof; must not exist')
    args=parser.parse_args()
    try:
        reports=[json.loads((args.directory/f'report-{i}.json').read_text()) for i in range(PARTS)]
        samples=[json.loads(line) for line in (args.directory/'gateway-metrics.jsonl').read_text().splitlines()]
        result=prove(reports,samples,args.phase)
    except (OSError,ValueError):
        result=dict(status='incomplete',passed=False,reasons=['input_read_failed'],scope=SCOPE)
    with args.output.open('x') as stream:
        os.fchmod(stream.fileno(),0o600); json.dump(result,stream,indent=2);stream.write('\n')
    print(json.dumps(result))
    raise SystemExit(0 if result['passed'] else 2 if result['status']=='incomplete' else 1)


if __name__=='__main__': main()
