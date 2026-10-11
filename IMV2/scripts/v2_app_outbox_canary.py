"""Explicit real App durable-outbox ACK-cut proof; no production compatibility.

The parent supplies the existing six-Gateway/Account assembly and a bounded
read-only query callback. This helper owns only the proxy and exact Xcode test.
It never imports certificates, alters trust, builds products, or seeds messages.
"""
import json
import os
from pathlib import Path
import plistlib
import re
import selectors
import signal
import subprocess
import time
import urllib.request
import uuid

EXACT_TEST = 'IMAppTests/IMAppLocalAccountIntegrationTests/unexpectedTCPDisconnectReplaysDurableWorkAcrossGateway()'
PROOF_PREFIX = 'IMV2_APP_ACK_CUT_PROOF '


def private_json(path, value):
    with path.open('x') as stream:
        os.fchmod(stream.fileno(), 0o600)
        json.dump(value, stream, indent=2)
        stream.write('\n')


def targets(plist):
    if 'TestConfigurations' in plist:
        return [target for config in plist['TestConfigurations'] for target in config.get('TestTargets', [])]
    return [value for key, value in plist.items() if not key.startswith('__') and isinstance(value, dict)]


def prepare_xctestrun(args, destination, *, exact_test=EXACT_TEST, environment_overrides=None):
    source = args.app_xctestrun
    data = plistlib.loads(source.read_bytes())
    matched = [item for item in targets(data) if item.get('BlueprintName') == 'IMAppTests'
               or Path(item.get('TestBundlePath', '')).name == 'IMAppTests.xctest']
    if len(matched) != 1:
        raise ValueError('app_fixture_exact_target_missing')
    target = matched[0]
    bundle = target.get('TestBundlePath', '').replace('__TESTROOT__', str(source.parent))
    host = target.get('TestHostPath', '').replace('__TESTROOT__', str(source.parent))
    bundle = bundle.replace('__TESTHOST__', host)
    if not bundle or not Path(bundle).is_dir():
        raise ValueError('app_fixture_built_test_bundle_missing')
    # __TESTROOT__ is relative to the original .xctestrun, not its private copy.
    def relocate(value):
        if isinstance(value, str): return value.replace('__TESTROOT__', str(source.parent))
        if isinstance(value, list): return [relocate(item) for item in value]
        if isinstance(value, dict): return {key: relocate(item) for key, item in value.items()}
        return value
    data = relocate(data)
    target = next(item for item in targets(data) if item.get('BlueprintName') == 'IMAppTests'
                  or Path(item.get('TestBundlePath', '')).name == 'IMAppTests.xctest')
    environment = dict(target.get('EnvironmentVariables', {}))
    if environment_overrides is None:
        environment.update(IMV2_LOCAL_ACCOUNT_E2E='1', IMV2_APP_ACK_CUT_E2E='1',
            IMV2_APP_ACK_CUT_PORT='19443', IMV2_APP_ACK_CUT_CONTROL_PORT='19444',
            IMV2_APP_ACK_CUT_RECEIVER_PORT=str(args.gateway_port+1))
    else:
        environment = {key:value for key,value in environment.items() if not key.startswith('IMV2_APP_ACK_CUT_')}
        environment.update(environment_overrides)
    target['EnvironmentVariables'] = environment
    target['OnlyTestIdentifiers'] = [exact_test.split('/', 1)[1]]
    target.pop('SkipTestIdentifiers', None)
    with destination.open('xb') as stream:
        os.fchmod(stream.fileno(), 0o600)
        plistlib.dump(data, stream)
    return data


def preflight(args, manifest, *, ack_cut=True):
    if (args.kind != 'candidate' or not args.allow_small_canary or manifest['users'] > 500
            or args.allow_scaled_diagnostic or args.shared_postgres
            or args.actor_partition_canary is not None or args.realtime_host_restart_canary is not None
            or args.planned_reconnect_inflight_canary or args.https_port != 8443):
        raise ValueError('app_outbox_requires_owned_candidate_small_canary_https8443_no_other_fault')
    for name in ('app_xctestrun', 'app_derived_data', 'app_trusted_ca', 'app_tls_certificate', 'app_tls_key'):
        value = getattr(args, name)
        if value is None or not value.exists(): raise ValueError('app_fixture_required_input_'+name)
    if not args.app_device_id:
        raise ValueError('app_fixture_required_device')
    uuid.UUID(args.app_device_id)
    if not args.app_derived_data.is_dir() or not args.app_xctestrun.is_file():
        raise ValueError('app_fixture_input_type')
    data = plistlib.loads(args.app_xctestrun.read_bytes())
    if len([item for item in targets(data) if item.get('BlueprintName') == 'IMAppTests'
            or Path(item.get('TestBundlePath', '')).name == 'IMAppTests.xctest']) != 1:
        raise ValueError('app_fixture_exact_target_missing')
    if ack_cut and any(19443 <= port <= 19444 for port in
           [args.pg_port, args.account_port]+[args.gateway_port+i for i in range(6)]
           +[args.actor_port+i for i in range(7)]+[args.metrics_port+i for i in range(6)]):
        raise ValueError('app_fixture_port_overlap')
    for name in ('app_trusted_ca', 'app_tls_certificate'):
        if '-----BEGIN CERTIFICATE-----' not in getattr(args, name).read_text():
            raise ValueError('app_fixture_certificate_invalid')
    if 'PRIVATE KEY-----' not in args.app_tls_key.read_text():
        raise ValueError('app_fixture_key_invalid')
    # Trust installation/validation belongs to the explicitly owned simulator.
    # Providing a CA never bypasses URLSession or socket certificate validation.


def control(path, body=None):
    encoded = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request('http://127.0.0.1:19444'+path, data=encoded,
        headers={'Content-Type':'application/json'}, method='GET' if body is None else 'POST')
    with urllib.request.urlopen(request, timeout=5) as response:
        data = response.read(65_537)
    if len(data) > 65_536: raise RuntimeError('app_proxy_response_bound')
    return json.loads(data)


def fact_sql(identity):
    values = {key: str(uuid.UUID(identity[key])) for key in ('accountID','roomID','clientMessageID')}
    digest = identity['fingerprintHex']
    if not re.fullmatch('[0-9a-fA-F]{64}', digest) or identity['fingerprintVersion'] != 1:
        raise ValueError('app_armed_fingerprint_invalid')
    return f"""WITH m AS MATERIALIZED (
      SELECT * FROM im_v2.messages WHERE room_id='{values['roomID']}'::uuid
        AND sender_user_id='{values['accountID']}'::uuid AND client_message_id='{values['clientMessageID']}'::uuid
    ), c AS MATERIALIZED (
      SELECT * FROM im_v2.message_send_completions WHERE room_id='{values['roomID']}'::uuid
        AND sender_user_id='{values['accountID']}'::uuid AND client_message_id='{values['clientMessageID']}'::uuid
    ) SELECT json_build_object('databaseNow',extract(epoch FROM clock_timestamp()),
      'messages',(SELECT count(*) FROM m),'receipts',(SELECT count(*) FROM c),'completions',(SELECT count(*) FROM c),
      'exactAccepted',coalesce((SELECT c.operation_fingerprint=decode('{digest}','hex')
        AND c.operation_resolved_at_ms>0 AND c.fingerprint_version=3
        AND c.message_id=m.message_id AND c.room_sequence=m.room_sequence
        AND c.timeline_sequence=m.timeline_sequence
        FROM m CROSS JOIN c),false),
      'messageID',(SELECT message_id::text FROM m),'roomSequence',(SELECT room_sequence FROM m))"""



def accepted_fact(value):
    return (all(type(value.get(key)) is int and value[key] == 1 for key in ('messages','receipts','completions'))
            and value.get('exactAccepted') is True)


def proof_matches(armed, fact, proof):
    try:
        same = all(uuid.UUID(armed[key]) == uuid.UUID(proof[key]) for key in ('nonce','workID','roomID'))
        return (same and uuid.UUID(proof['messageID']) == uuid.UUID(fact['messageID'])
            and uuid.UUID(proof['oldConnectionGeneration']) == uuid.UUID(armed['connectionGeneration'])
            and uuid.UUID(proof['newConnectionGeneration']) != uuid.UUID(armed['connectionGeneration'])
            and proof['roomSequence'] == fact['roomSequence']
            and proof.get('sameIdentity') is True and proof.get('unknownObserved') is True
            and proof.get('automaticReconnect') is True
            and type(proof.get('senderReadyHighWatermark')) is int
            and proof['senderReadyHighWatermark'] >= fact['roomSequence']
            and proof['senderAppliedCursor'] >= proof['senderReadyHighWatermark']
            and proof['receiverCursor'] >= fact['roomSequence'])
    except (ValueError, TypeError, KeyError): return False


def read_line(process, timeout):
    selector = selectors.DefaultSelector()
    try:
        selector.register(process.stdout, selectors.EVENT_READ)
        if not selector.select(timeout): raise TimeoutError('app_proxy_status_timeout')
        line = process.stdout.readline(65_537)
        if not line or len(line) > 65_536: raise RuntimeError('app_proxy_status_invalid')
        return json.loads(line)
    finally: selector.close()


def selected_test_failure_signal(tail, *, exact_test=EXACT_TEST):
    """Only explicit terminal failure of the selected one-test execution."""
    name = re.escape(exact_test.rsplit('/', 1)[1])
    if re.search(r'^\s*✘ Test '+name+r' failed after [^\r\n]+$', tail, re.M):
        return 'selected_test_failed'
    if re.search(r'^\s*✘ Test run with 1 test in 1 suite failed after [^\r\n]+$', tail, re.M):
        return 'single_test_run_failed'
    return None


def bounded_log_tail(path):
    with path.open('rb') as stream:
        stream.seek(0, os.SEEK_END)
        stream.seek(max(0, stream.tell()-65_536))
        return stream.read(65_536).decode('utf-8', errors='replace')


def run_canary(args, directory, query):
    prepared = directory/'app-canary.xctestrun'
    prepare_xctestrun(args, prepared)
    private_json(directory/'app-canary-contract.json', dict(exactTest=EXACT_TEST,
        caTrustRequired=True, trustModified=False, realAppSQLite=True, capacityAcceptance=False))
    result = dict(qualityPassed=False, appOutboxCanary=True, capacityAcceptance=False)
    proxy = xcode = None
    stage = 'proxy_start'
    stderr = (directory/'app-proxy-stderr.log').open('x')
    log = (directory/'app-xcode.log').open('x')
    deadline = time.monotonic()+min(args.timeout_seconds, 300)
    armed = before = after = app_proof = None
    try:
        proxy = subprocess.Popen(['python3',str(Path(__file__).with_name('v2_app_tcp_ack_cut_proxy.py')),
            '--listen-port','19443','--control-port','19444','--gateway-a',str(args.gateway_port),
            '--gateway-b',str(args.gateway_port+1)], stdout=subprocess.PIPE, stderr=stderr, text=True)
        if read_line(proxy, 5).get('ready') is not True: raise RuntimeError('app_proxy_not_ready')
        stage = 'xcode_exact_test'
        xcode = subprocess.Popen(['xcodebuild','test-without-building','-xctestrun',str(prepared),
            '-derivedDataPath',str(args.app_derived_data),'-destination','id='+args.app_device_id,
            '-only-testing:'+EXACT_TEST,'-parallel-testing-enabled','NO',
            '-resultBundlePath',str(directory/'app-canary.xcresult')], stdout=log, stderr=log)
        while xcode.poll() is None:
            signal_code = selected_test_failure_signal(bounded_log_tail(directory/'app-xcode.log'))
            if signal_code is not None:
                result.update(actualTestFailure=True, testFailureSignal=signal_code, xcodePassed=False)
                raise RuntimeError('app_selected_test_terminal_failure')
            if (directory/'app-xcode.log').stat().st_size > 16*1024*1024:
                raise RuntimeError('app_test_log_bound')
            if proxy.poll() is not None: raise RuntimeError('app_proxy_exited')
            if time.monotonic() >= deadline: raise TimeoutError('app_canary_deadline')
            status = control('/status')
            if status.get('held') and armed is None:
                armed = status['fixture']
                for key in ('nonce','accountID','roomID','clientMessageID','workID','connectionGeneration'):
                    uuid.UUID(armed[key])
                private_json(directory/'app-armed-identity.json', armed)
                stage = 'exact_commit_gate'
            if armed is not None and before is None:
                observed = json.loads(query(fact_sql(armed)))
                if accepted_fact(observed):
                    before = observed
                    private_json(directory/'app-precut-fact.json', before)
                    switched = control('/switch',dict(nonce=armed['nonce'],databaseFactConfirmed=True))
                    if not switched.get('switched') or switched.get('closeFailures') != 0 or switched.get('drained',0)<1:
                        raise RuntimeError('app_proxy_old_flow_not_drained')
                    private_json(directory/'app-proxy-switch.json', switched)
                    stage = 'app_reconnect_and_sqlite_proof'
            time.sleep(.1)
        signal_code = selected_test_failure_signal(bounded_log_tail(directory/'app-xcode.log'))
        if signal_code is not None:
            result.update(actualTestFailure=True, testFailureSignal=signal_code, xcodePassed=False)
            raise RuntimeError('app_selected_test_terminal_failure')
        if xcode.returncode != 0: raise RuntimeError('app_exact_xcode_failed')
        if before is None: raise RuntimeError('app_commit_gate_not_reached')
        if log.tell() > 16*1024*1024: raise RuntimeError('app_test_log_bound')
        log.flush()
        lines = [line.split(PROOF_PREFIX,1)[1] for line in (directory/'app-xcode.log').read_text().splitlines() if PROOF_PREFIX in line]
        if len(lines)!=1: raise RuntimeError('app_exact_proof_missing_or_duplicate')
        app_proof = json.loads(lines[0]); after = json.loads(query(fact_sql(armed)))
        private_json(directory/'app-final-fact.json',after)
        private_json(directory/'app-local-store-proof.json',app_proof)
        result.update(xcodePassed=True, exactFactPassed=accepted_fact(after),
            appProofPassed=proof_matches(armed,after,app_proof),
            stableCommittedFact=before['messageID']==after.get('messageID')
                and before['roomSequence']==after.get('roomSequence'))
        result['productQualityPassed']=result['exactFactPassed'] and result['appProofPassed'] and result['stableCommittedFact']
    except Exception as error:
        result.update(failureStage=stage,
                      failureCode='actual_test_failed' if result.get('actualTestFailure') else
                          'timeout' if isinstance(error,TimeoutError) else 'canary_failed',
                      productQualityPassed=False)
    finally:
        if xcode is not None and xcode.poll() is None:
            result['xcodeTerminatedForCleanup'] = True
            xcode.terminate()
            try: xcode.wait(timeout=5)
            except subprocess.TimeoutExpired: xcode.kill(); xcode.wait(timeout=5)
        if xcode is not None:
            result.update(xcodeActualExitCode=xcode.poll(), xcodeOwnedProcessSettled=xcode.poll() is not None)
        cleanup = dict(passed=False, ownedProcessSettled=proxy is None)
        if proxy is not None:
            try:
                proxy.send_signal(signal.SIGTERM)
                terminal=read_line(proxy,10); proxy.wait(timeout=5)
                cleanup=dict(passed=proxy.returncode==0 and terminal.get('stopped') is True
                    and terminal.get('closed') is True and terminal.get('flows')==[]
                    and terminal.get('closeFailures')==0, ownedProcessSettled=True, terminal=terminal)
            except Exception:
                if proxy.poll() is None: proxy.kill()
                try: proxy.wait(timeout=5)
                except subprocess.TimeoutExpired: pass
                cleanup=dict(passed=False,ownedProcessSettled=proxy.poll() is not None,failureCode='proxy_cleanup_failed')
            proxy.stdout.close()
        stderr.close(); log.close()
        private_json(directory/'app-fixture-cleanup.json',cleanup)
        result['fixtureCleanupPassed']=cleanup['passed']
        result['qualityPassed']=result.get('productQualityPassed') is True and cleanup['passed']
        private_json(directory/'app-outbox-canary.json',result)
    return result
