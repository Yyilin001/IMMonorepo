"""Owned plist selection only; no Xcode, simulator, socket or database."""
from pathlib import Path
import plistlib
import tempfile
from types import SimpleNamespace
import unittest
from v2_app_outbox_canary import prepare_xctestrun, targets, EXACT_TEST as OUTBOX_TEST
from v2_app_multi_device_canary import EXACT_TEST
from run_v2_actor_realtime_benchmark import settle_app_cleanup_result


class MultiDeviceSelectionTests(unittest.TestCase):
    def test_app_acceptance_waits_for_actual_app_service_and_postgres_cleanup(self):
        for product, app, services, postgres in [(True,True,True,True),
                (False,True,True,True),(True,False,True,True),(True,True,False,True),(True,True,True,False)]:
            result = dict(productQualityPassed=product,appFixtureCleanupPassed=app,
                          ownedServicesCleanupPassed=services,ownedPostgresCleanupPending=True,qualityPassed=False)
            settle_app_cleanup_result(result,postgres_passed=postgres)
            self.assertEqual(result['qualityPassed'],product and app and services and postgres)
            self.assertFalse(result['ownedPostgresCleanupPending'])
            self.assertEqual(result['productQualityPassed'],product)

    def test_multi_device_selects_exact_scope_test_without_ack_cut_environment(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root/'IMAppTests.xctest').mkdir()
            source = root/'built.xctestrun'
            source.write_bytes(plistlib.dumps({'IMAppTests':dict(BlueprintName='IMAppTests',
                TestBundlePath='__TESTROOT__/IMAppTests.xctest',
                EnvironmentVariables={'IMV2_APP_ACK_CUT_E2E':'1','IMV2_APP_ACK_CUT_PORT':'19443'})}))
            args = SimpleNamespace(app_xctestrun=source,gateway_port=18443)
            multi = prepare_xctestrun(args,root/'multi.xctestrun',exact_test=EXACT_TEST,
                environment_overrides={'IMV2_LOCAL_ACCOUNT_E2E':'1',
                    'IMV2_CROSS_GATEWAY_MULTI_DEVICE_E2E':'1','IMV2_CROSS_GATEWAY_PRIMARY_PORT':'18443',
                    'IMV2_ROOM_RECOVERY_SECONDARY_PORT':'18444'})
            target = targets(multi)[0]
            self.assertEqual(target['OnlyTestIdentifiers'],[EXACT_TEST.split('/',1)[1]])
            self.assertFalse(any(key.startswith('IMV2_APP_ACK_CUT_') for key in target['EnvironmentVariables']))
            self.assertEqual(target['EnvironmentVariables']['IMV2_ROOM_RECOVERY_SECONDARY_PORT'],'18444')
            outbox = targets(prepare_xctestrun(args,root/'outbox.xctestrun'))[0]
            self.assertEqual(outbox['OnlyTestIdentifiers'],[OUTBOX_TEST.split('/',1)[1]])
            self.assertEqual(outbox['EnvironmentVariables']['IMV2_APP_ACK_CUT_E2E'],'1')
