"""Real App same-account device-scope canary; no proxy, ACK-cut or PG fact gate."""
import subprocess
import time
from v2_app_outbox_canary import (private_json, prepare_xctestrun, preflight as app_preflight,
                                  bounded_log_tail, selected_test_failure_signal)

EXACT_TEST = 'IMAppTests/V2CrossGatewayMultiDeviceIntegrationTests/oldSocketUnsubscribePreservesBothCurrentDeviceScopes()'
MARKER = 'IMV2_REAL_TLS_TWO_DEVICES_OLD_SCOPE_CLEANUP_PASSED'


def preflight(args, manifest):
    app_preflight(args, manifest, ack_cut=False)
    if args.gateway_port != 18443:
        raise ValueError('app_multi_device_requires_primary18443_secondary18444')


def run_canary(args, directory):
    prepared = directory/'app-multi-device.xctestrun'
    prepare_xctestrun(args, prepared, exact_test=EXACT_TEST, environment_overrides={
        'IMV2_LOCAL_ACCOUNT_E2E':'1', 'IMV2_CROSS_GATEWAY_MULTI_DEVICE_E2E':'1',
        'IMV2_CROSS_GATEWAY_PRIMARY_PORT':'18443', 'IMV2_ROOM_RECOVERY_SECONDARY_PORT':'18444'})
    private_json(directory/'app-multi-device-contract.json', dict(exactTest=EXACT_TEST,
        primaryPort=18443, secondaryPort=18444, caTrustRequired=True, trustModified=False,
        proxyUsed=False, ackCutUsed=False, postgresFactGateUsed=False, capacityAcceptance=False))
    result = dict(qualityPassed=False, appMultiDeviceCanary=True, capacityAcceptance=False)
    process = None
    log_path = directory/'app-multi-device-xcode.log'
    deadline = time.monotonic()+min(args.timeout_seconds, 300)
    with log_path.open('x') as log:
        try:
            process = subprocess.Popen(['xcodebuild','test-without-building','-xctestrun',str(prepared),
                '-derivedDataPath',str(args.app_derived_data),'-destination','id='+args.app_device_id,
                '-only-testing:'+EXACT_TEST,'-parallel-testing-enabled','NO',
                '-resultBundlePath',str(directory/'app-multi-device.xcresult')],stdout=log,stderr=log)
            while process.poll() is None:
                failure = selected_test_failure_signal(bounded_log_tail(log_path),exact_test=EXACT_TEST)
                if failure:
                    result.update(actualTestFailure=True,testFailureSignal=failure)
                    raise RuntimeError('actual_test_failed')
                if log_path.stat().st_size > 16*1024*1024: raise RuntimeError('test_log_bound')
                if time.monotonic() >= deadline: raise TimeoutError('test_timeout')
                time.sleep(.1)
            failure = selected_test_failure_signal(bounded_log_tail(log_path),exact_test=EXACT_TEST)
            if failure:
                result.update(actualTestFailure=True,testFailureSignal=failure)
                raise RuntimeError('actual_test_failed')
            if process.returncode != 0: raise RuntimeError('xcode_failed')
            if log_path.stat().st_size > 16*1024*1024: raise RuntimeError('test_log_bound')
            log.flush()
            marker_count = sum(line.strip()==MARKER for line in log_path.read_text().splitlines())
            result.update(xcodePassed=True,exactMarkerCount=marker_count,markerPassed=marker_count==1)
            result['productQualityPassed'] = result['markerPassed']
        except Exception as error:
            code = ('actual_test_failed' if result.get('actualTestFailure') else
                    'test_timeout' if isinstance(error,TimeoutError) else 'test_execution_failed')
            result.update(failureStage='app_multi_device_exact_test',failureCode=code,productQualityPassed=False)
        finally:
            if process is not None and process.poll() is None:
                result['xcodeTerminatedForCleanup']=True
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=5)
            settled = process is not None and process.poll() is not None
            result.update(xcodeActualExitCode=process.poll() if process else None,
                xcodeOwnedProcessSettled=settled, fixtureCleanupPassed=settled)
            result['qualityPassed'] = result.get('productQualityPassed') is True and settled
    private_json(directory/'app-multi-device-canary.json',result)
    return result
