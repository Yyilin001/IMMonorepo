"""Real App decoded-room-loss proof with independent committed PostgreSQL facts.

Owns only the exact test-without-building process. The parent owns service and
PostgreSQL cleanup; no certificates, trust settings, messages or cursors are altered.
"""
import json
import plistlib
import re
import subprocess
import time
import uuid
from pathlib import Path
from v2_app_outbox_canary import (
    private_json, prepare_xctestrun, preflight as app_preflight,
    bounded_log_tail, selected_test_failure_signal, fact_sql as operation_fact_sql,
    accepted_fact,
    targets,
)

EXACT_TEST = 'IMAppTests/V2RoomProgressNotificationLossIntegrationTests/decodedRoomNotificationLossRecoversThroughHeartbeat()'
PROOF_PREFIX = 'IMV2_APP_ROOM_PROGRESS_PROOF '
MAX_SEQUENCE = (1 << 63)-1


def canonical_uuid(value):
    if not isinstance(value, str) or not re.fullmatch(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}', value):
        raise ValueError('app_room_progress_uuid_invalid')
    return str(uuid.UUID(value))


def sequence(value, *, positive=False):
    if type(value) is not int or not (int(positive) <= value <= MAX_SEQUENCE):
        raise ValueError('app_room_progress_sequence_invalid')
    return value


def normalized_operations(proof):
    sender = canonical_uuid(proof['senderAccountID'])
    room = canonical_uuid(proof['roomID'])
    receiver = canonical_uuid(proof['accountID'])
    if sender == receiver: raise ValueError('app_room_progress_distinct_accounts_required')
    operations = proof['operations']
    if not isinstance(operations, list) or len(operations) != 3:
        raise ValueError('app_room_progress_exact_three_operations_required')
    normalized = []
    for operation in operations:
        client = canonical_uuid(operation['clientMessageID'])
        message = canonical_uuid(operation['messageID'])
        parts = operation['operationIdentity'].split('/')
        if (len(parts) != 5 or parts[1] != 'room' or parts[3] != 'sendMessage'
                or canonical_uuid(parts[0]) != sender or canonical_uuid(parts[2]) != room
                or canonical_uuid(parts[4]) != client):
            raise ValueError('app_room_progress_operation_identity_invalid')
        digest = operation['fingerprintHex']
        if type(operation['fingerprintVersion']) is not int or operation['fingerprintVersion'] != 1 or not isinstance(digest, str) or not re.fullmatch('[0-9a-fA-F]{64}', digest):
            raise ValueError('app_room_progress_operation_fingerprint_invalid')
        normalized.append(dict(accountID=sender, roomID=room, clientMessageID=client,
            messageID=message, roomSequence=sequence(operation['roomSequence'], positive=True),
            fingerprintVersion=1, fingerprintHex=digest.lower()))
    if len({item['clientMessageID'] for item in normalized}) != 3 or len({item['messageID'] for item in normalized}) != 3:
        raise ValueError('app_room_progress_duplicate_operation')
    if [item['roomSequence'] for item in normalized] != sorted({item['roomSequence'] for item in normalized}):
        raise ValueError('app_room_progress_operation_order_invalid')
    return normalized


def fact_sql(proof):
    """All interpolated values are validated UUIDs or bounded hexadecimal digests."""
    room = canonical_uuid(proof['roomID'])
    operations = normalized_operations(proof)
    # Reuse the outbox gate's exact identity, public/domain fingerprint, receipt,
    # message, completion, and closure join. Each scalar returns its own fact.
    facts = ','.join('('+operation_fact_sql(item)+')' for item in operations)
    return f"""SELECT json_build_object('roomID','{room}',
      'roomCount',(SELECT count(*) FROM im_v2.rooms WHERE room_id='{room}'::uuid),
      'committedHead',(SELECT room_sequence FROM im_v2.rooms WHERE room_id='{room}'::uuid),
      'operations',json_build_array({facts}))"""


def proof_matches(nonce, fact, proof):
    try:
        if canonical_uuid(proof['nonce']) != canonical_uuid(nonce): return False
        operations = normalized_operations(proof)
        canonical_uuid(proof['deviceID'])
        if canonical_uuid(fact['roomID']) != canonical_uuid(proof['roomID']) or type(fact['roomCount']) is not int or fact['roomCount'] != 1: return False
        if canonical_uuid(proof['connectionGeneration']) != canonical_uuid(proof['finalConnectionGeneration']): return False
        scope = sequence(proof['scopeGeneration'], positive=True)
        if sequence(proof['finalScopeGeneration'], positive=True) != scope: return False
        arm = sequence(proof['armCursor'])
        if sequence(proof['firstHeartbeatBeforeCursor']) != arm: return False
        final = sequence(proof['finalRoomSequence'], positive=True)
        if not arm < operations[0]['roomSequence'] or operations[-1]['roomSequence'] != final: return False
        for key in ('committedHead',):
            if sequence(fact[key], positive=True) != final: return False
        for key in ('reopenedSQLiteCursor', 'heartbeatHighWatermark'):
            if sequence(proof[key], positive=True) != final: return False
        for key in ('heartbeatRecoveries', 'discardedNotifications', 'discardedBodies'):
            if type(proof[key]) is not int or not (1 <= proof[key] <= 1_000_000): return False
        if type(proof['manualPullCount']) is not int or proof['manualPullCount'] != 0: return False
        for key in ('realAppRuntime', 'realDetailRecoveryLoop', 'directoryCompleteBeforeArm', 'samePhysicalConnection'):
            if proof[key] is not True: return False
        if proof['unresolvedHistoryGap'] is not False: return False
        facts = fact['operations']
        if not isinstance(facts, list) or len(facts) != 3: return False
        for expected, actual in zip(operations, facts):
            if not accepted_fact(actual): return False
            if canonical_uuid(actual['messageID']) != expected['messageID'] or sequence(actual['roomSequence'], positive=True) != expected['roomSequence']: return False
        return True
    except (ValueError, TypeError, KeyError, AttributeError):
        return False


def preflight(args, manifest):
    app_preflight(args, manifest, ack_cut=False)
    if (getattr(args, 'room_host_restart_canary', None) is not None
            or getattr(args, 'room_notification_loss_canary', False)
            or getattr(args, 'preclose_recovery_witness', False)):
        raise ValueError('app_room_progress_requires_no_other_fault')
    if args.gateway_port != 18443:
        raise ValueError('app_room_progress_requires_bundle_gateway18443')
    data = plistlib.loads(args.app_xctestrun.read_bytes())
    app_targets = [item for item in targets(data) if item.get('BlueprintName') == 'IMAppTests']
    if len(app_targets) != 1:
        raise ValueError('app_room_progress_exact_target_missing')
    host = Path(app_targets[0]['TestHostPath'].replace('__TESTROOT__', str(args.app_xctestrun.parent)))
    app = next((parent for parent in (host, *host.parents) if parent.suffix == '.app'), None)
    if app is None:
        raise ValueError('app_room_progress_host_bundle_missing')
    info = plistlib.loads((app/'Info.plist').read_bytes())
    if str(info.get('IMV2GatewayPort')) != str(args.gateway_port):
        raise ValueError('app_room_progress_built_gateway_port_mismatch')


def run_canary(args, directory, query, *, gateway_crash=None):
    nonce = str(uuid.uuid4())
    prepared = directory/'app-room-progress.xctestrun'
    prepare_xctestrun(args, prepared, exact_test=EXACT_TEST, environment_overrides={
        'IMV2_LOCAL_ACCOUNT_E2E': '1', 'IMV2_APP_ROOM_PROGRESS_E2E': '1',
        'IMV2_APP_ROOM_PROGRESS_NONCE': nonce, 'IMV2_ROOM_RECOVERY_SECONDARY_PORT': '18444',
        'IMV2_APP_GATEWAY_CRASH_E2E': '1' if gateway_crash else '0'})
    private_json(directory/'app-room-progress-contract.json', dict(exactTest=EXACT_TEST, nonce=nonce,
        caTrustRequired=True, trustModified=False, realAppSQLite=True, actualDecodedRoomLoss=True,
        manualPullAllowed=False, capacityAcceptance=False))
    result = dict(qualityPassed=False, appRoomProgressCanary=True, capacityAcceptance=False)
    process = None
    log_path = directory/'app-room-progress-xcode.log'
    deadline = time.monotonic()+min(args.timeout_seconds, 300)
    stage = 'app_room_progress_exact_test'
    with log_path.open('x') as log:
        try:
            process = subprocess.Popen(['xcodebuild','test-without-building','-xctestrun',str(prepared),
                '-derivedDataPath',str(args.app_derived_data),'-destination','id='+args.app_device_id,
                '-only-testing:'+EXACT_TEST,'-parallel-testing-enabled','NO',
                '-resultBundlePath',str(directory/'app-room-progress.xcresult')],stdout=log,stderr=log)
            crash_injected = False
            while process.poll() is None:
                if gateway_crash and not crash_injected and 'IMV2_APP_GATEWAY_CRASH_REQUESTED' in bounded_log_tail(log_path):
                    stage = 'app_room_progress_gateway_crash_injection'
                    result['gatewayCrashInjection'] = gateway_crash()
                    stage = 'app_room_progress_exact_test'
                    crash_injected = True
                failure = selected_test_failure_signal(bounded_log_tail(log_path), exact_test=EXACT_TEST)
                if failure:
                    result.update(actualTestFailure=True, testFailureSignal=failure)
                    raise RuntimeError('actual_test_failed')
                if log_path.stat().st_size > 16*1024*1024: raise RuntimeError('test_log_bound')
                if time.monotonic() >= deadline: raise TimeoutError('test_timeout')
                time.sleep(.1)
            failure = selected_test_failure_signal(bounded_log_tail(log_path), exact_test=EXACT_TEST)
            if failure:
                result.update(actualTestFailure=True, testFailureSignal=failure)
                raise RuntimeError('actual_test_failed')
            if process.returncode != 0: raise RuntimeError('xcode_failed')
            if log_path.stat().st_size > 16*1024*1024: raise RuntimeError('test_log_bound')
            log.flush()
            reconnect_markers = len(re.findall(r'(?m)^IMV2_APP_UNOPENED_ROOM_RECONNECT_PASSED(?=$|\s|\d{4}-\d{2}-\d{2})', log_path.read_text()))
            result['unopenedRoomReconnectPassed'] = reconnect_markers == 1
            if reconnect_markers != 1: raise RuntimeError('unopened_reconnect_proof_missing_or_duplicate')
            automatic_markers = len(re.findall(r'(?m)^IMV2_APP_AUTOMATIC_TCP_RECONNECT_PASSED(?=$|\s|\d{4}-\d{2}-\d{2})', log_path.read_text()))
            result['automaticTCPReconnectPassed'] = automatic_markers == 1
            if automatic_markers != 1: raise RuntimeError('automatic_tcp_reconnect_proof_missing_or_duplicate')
            sender_markers = len(re.findall(r'(?m)^IMV2_APP_DURABLE_SEND_TCP_RECONNECT_PASSED(?=$|\s|\d{4}-\d{2}-\d{2})', log_path.read_text()))
            result['durableSenderTCPReconnectPassed'] = sender_markers == 1
            if sender_markers != 1: raise RuntimeError('durable_sender_tcp_reconnect_proof_missing_or_duplicate')
            if gateway_crash:
                crash_markers = len(re.findall(r'(?m)^IMV2_APP_GATEWAY_CRASH_RECOVERY_PASSED(?=$|\s|\d{4}-\d{2}-\d{2})', log_path.read_text()))
                result['gatewayCrashRecoveryPassed'] = crash_injected and crash_markers == 1
                if not result['gatewayCrashRecoveryPassed']: raise RuntimeError('gateway_crash_recovery_proof_missing_or_duplicate')
                if getattr(args, 'app_journal_trim_canary', False):
                    trim = result['gatewayCrashInjection'].get('journalTrim', {})
                    result['journalTrimColdRecoveryPassed'] = (trim.get('advancedPartitions', 0) > 0
                        and trim.get('removedEntries', 0) > 0 and trim.get('consumerCursorsPreserved') is True
                        and result['gatewayCrashRecoveryPassed'] and result['unopenedRoomReconnectPassed'])
                    if not result['journalTrimColdRecoveryPassed']: raise RuntimeError('journal_trim_cold_recovery_proof_missing')
            membership_markers = len(re.findall(r'(?m)^IMV2_APP_ONLINE_MEMBERSHIP_CHANGES_PASSED(?=$|\s|\d{4}-\d{2}-\d{2})', log_path.read_text()))
            result['onlineMembershipChangesPassed'] = membership_markers == 1
            if membership_markers != 1: raise RuntimeError('online_membership_proof_missing_or_duplicate')
            cross_markers = len(re.findall(r'(?m)^IMV2_APP_CROSS_GATEWAY_MEMBERSHIP_PASSED(?=$|\s|\d{4}-\d{2}-\d{2})', log_path.read_text()))
            result['crossGatewayMembershipPassed'] = cross_markers == 1
            if cross_markers != 1: raise RuntimeError('cross_gateway_membership_proof_missing_or_duplicate')
            lines = [line[len(PROOF_PREFIX):] for line in log_path.read_text().splitlines() if line.startswith(PROOF_PREFIX)]
            if len(lines) != 1: raise RuntimeError('exact_proof_missing_or_duplicate')
            proof = json.loads(lines[0])
            if canonical_uuid(proof['nonce']) != nonce: raise RuntimeError('proof_nonce_mismatch')
            stage = 'app_room_progress_database_facts'
            fact = json.loads(query(fact_sql(proof)))
            private_json(directory/'app-room-progress-local-store-proof.json', proof)
            private_json(directory/'app-room-progress-database-fact.json', fact)
            passed = proof_matches(nonce, fact, proof)
            result.update(xcodePassed=True, appProofPassed=passed, exactFactPassed=passed, productQualityPassed=passed)
            if not passed: raise RuntimeError('proof_fact_mismatch')
        except Exception as error:
            # Only fixed fault-run codes may enter the public diagnostic artifact.
            fault_codes = {'app_journal_trim_database_not_owned', 'app_journal_trim_failed',
                'app_journal_trim_no_history_removed', 'app_journal_trim_no_consumer_cursors_checked',
                'app_journal_trim_consumer_cursors_changed'}
            if isinstance(error, RuntimeError) and str(error) in fault_codes:
                result['failureReason'] = str(error)
            result.update(failureStage=stage, failureCode='actual_test_failed' if result.get('actualTestFailure') else
                'test_timeout' if isinstance(error, TimeoutError) else 'canary_failed', productQualityPassed=False)
        finally:
            if process is not None and process.poll() is None:
                result['xcodeTerminatedForCleanup'] = True
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=5)
            settled = process is not None and process.poll() is not None
            result.update(xcodeActualExitCode=process.poll() if process else None,
                xcodeOwnedProcessSettled=settled, fixtureCleanupPassed=settled)
            result['qualityPassed'] = result.get('productQualityPassed') is True and settled
    private_json(directory/'app-room-progress-canary.json', result)
    return result
