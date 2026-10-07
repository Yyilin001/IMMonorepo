"""Pure proof and SQL-input validation; no Xcode, socket or database."""
import copy
from pathlib import Path
import plistlib
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import uuid
from v2_app_outbox_canary import prepare_xctestrun, targets
from v2_app_room_progress_canary import EXACT_TEST, fact_sql, proof_matches, normalized_operations, preflight


def fixture():
    nonce, receiver, sender, device, room, connection = [str(uuid.uuid4()) for _ in range(6)]
    operations = []
    for index in range(3):
        client, message = str(uuid.uuid4()), str(uuid.uuid4())
        operations.append(dict(clientMessageID=client, messageID=message, roomSequence=5+index,
            operationIdentity=f'{sender}/room/{room}/sendMessage/{client}', fingerprintVersion=1, fingerprintHex='ab'*32))
    proof = dict(nonce=nonce, accountID=receiver, senderAccountID=sender, deviceID=device, roomID=room,
        connectionGeneration=connection, finalConnectionGeneration=connection, scopeGeneration=2, finalScopeGeneration=2,
        armCursor=4, firstHeartbeatBeforeCursor=4, heartbeatHighWatermark=7, reopenedSQLiteCursor=7, finalRoomSequence=7,
        heartbeatRecoveries=1, discardedNotifications=3, discardedBodies=3, manualPullCount=0,
        realAppRuntime=True, realDetailRecoveryLoop=True, directoryCompleteBeforeArm=True,
        samePhysicalConnection=True, unresolvedHistoryGap=False, operations=operations)
    fact = dict(roomID=room, roomCount=1, committedHead=7, operations=[dict(messages=1,receipts=1,
        completions=1,closures=0,exactAccepted=True,messageID=operation['messageID'],roomSequence=operation['roomSequence']) for operation in operations])
    return nonce, fact, proof


class RoomProgressProofTests(unittest.TestCase):
    def test_preflight_checks_actual_built_gateway_port(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root/'IMApp.app'
            app.mkdir()
            source = root/'tests.xctestrun'
            source.write_bytes(plistlib.dumps({'IMAppTests': {
                'BlueprintName': 'IMAppTests', 'TestHostPath': '__TESTROOT__/IMApp.app/IMApp'}}))
            args = SimpleNamespace(app_xctestrun=source, gateway_port=18443)
            with patch('v2_app_room_progress_canary.app_preflight'):
                (app/'Info.plist').write_bytes(plistlib.dumps({'IMV2GatewayPort': '7443'}))
                with self.assertRaisesRegex(ValueError, 'built_gateway_port_mismatch'):
                    preflight(args, {})
                (app/'Info.plist').write_bytes(plistlib.dumps({'IMV2GatewayPort': '18443'}))
                preflight(args, {})
                source.write_bytes(plistlib.dumps({'IMAppTests': {
                    'BlueprintName': 'IMAppTests', 'TestHostPath': '__TESTROOT__/IMApp.app'}}))
                preflight(args, {})

    def test_complete_proof_normalizes_uuid_case(self):
        nonce,fact,proof = fixture()
        self.assertTrue(proof_matches(nonce,fact,proof))
        upper = copy.deepcopy(proof)
        for key in ('nonce','accountID','senderAccountID','deviceID','roomID','connectionGeneration','finalConnectionGeneration'):
            upper[key] = upper[key].upper()
        for operation in upper['operations']:
            operation['clientMessageID'] = operation['clientMessageID'].upper()
            operation['messageID'] = operation['messageID'].upper()
            operation['operationIdentity'] = '/'.join(part.upper() if index in (0,2,4) else part for index,part in enumerate(operation['operationIdentity'].split('/')))
        self.assertTrue(proof_matches(nonce.upper(),fact,upper))

    def test_required_witnesses_cannot_be_forged(self):
        nonce,fact,proof = fixture()
        changes = dict(nonce=str(uuid.uuid4()),discardedNotifications=0,discardedBodies=0,heartbeatRecoveries=0,
            firstHeartbeatBeforeCursor=5,reopenedSQLiteCursor=6,heartbeatHighWatermark=8,finalRoomSequence=6,
            manualPullCount=1,connectionGeneration=str(uuid.uuid4()),finalScopeGeneration=3,realAppRuntime=False,
            realDetailRecoveryLoop=False,directoryCompleteBeforeArm=False,samePhysicalConnection=False,
            unresolvedHistoryGap=True,senderAccountID=proof['accountID'],scopeGeneration=True)
        for key,value in changes.items():
            with self.subTest(key=key): self.assertFalse(proof_matches(nonce,fact,dict(proof,**{key:value})))
        for key in ('discardedBodies','heartbeatRecoveries','heartbeatHighWatermark'):
            for invalid in (True,1<<63):
                self.assertFalse(proof_matches(nonce,fact,dict(proof,**{key:invalid})))

    def test_receipt_identity_fingerprint_message_completion_facts_required(self):
        nonce,fact,proof = fixture()
        for key,value in dict(exactAccepted=False,messages=2,receipts=0,completions=2,closures=1,
            messageID=str(uuid.uuid4()),roomSequence=6).items():
            tampered = copy.deepcopy(fact); tampered['operations'][0][key] = value
            with self.subTest(key=key): self.assertFalse(proof_matches(nonce,tampered,proof))
        for field,value in [('roomCount',0),('committedHead',8),('roomID',str(uuid.uuid4()))]:
            self.assertFalse(proof_matches(nonce,dict(fact,**{field:value}),proof))
        tampered = copy.deepcopy(fact); tampered['operations'].pop()
        self.assertFalse(proof_matches(nonce,tampered,proof))
        tampered = copy.deepcopy(fact); tampered['operations'][0]['closures'] = False
        self.assertFalse(proof_matches(nonce,tampered,proof))

    def test_identity_sql_injection_and_duplicate_operations_rejected(self):
        nonce,fact,proof = fixture()
        invalids = [('operationIdentity',f"{proof['accountID']}/room/{proof['roomID']}/sendMessage/{proof['operations'][0]['clientMessageID']}"),
            ('fingerprintVersion',True),('fingerprintHex','z'*64),('clientMessageID',"';SELECT pg_sleep(99);--"),
            ('operationIdentity',proof['operations'][0]['operationIdentity']+'/extra')]
        for field,value in invalids:
            tampered = copy.deepcopy(proof); tampered['operations'][0][field] = value
            with self.subTest(field=field):
                self.assertFalse(proof_matches(nonce,fact,tampered))
                with self.assertRaises((ValueError,TypeError,KeyError)): fact_sql(tampered)
        duplicate = copy.deepcopy(proof); duplicate['operations'][1] = duplicate['operations'][0]
        self.assertFalse(proof_matches(nonce,fact,duplicate))
        with self.assertRaises(ValueError): normalized_operations(duplicate)

    def test_sql_exact_three_fact_joins_and_independent_committed_head(self):
        _,_,proof = fixture(); sql = fact_sql(proof)
        for table in ('message_send_completions','message_operation_closures'):
            self.assertEqual(sql.count('FROM im_v2.'+table),3)
        self.assertEqual(sql.count('request_fingerprint=decode'),3)
        self.assertEqual(sql.count('c.request_fingerprint=r.domain_fingerprint'),3)
        self.assertEqual(sql.count('identity,operation,sendMessage,_0,rawValue'),3)
        self.assertIn('SELECT room_sequence FROM im_v2.rooms',sql)
        self.assertNotIn('INSERT ',sql); self.assertNotIn('UPDATE ',sql)

    def test_exact_selection_replaces_ack_cut_environment(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); (root/'IMAppTests.xctest').mkdir(); source = root/'built.xctestrun'
            source.write_bytes(plistlib.dumps({'IMAppTests':dict(BlueprintName='IMAppTests',
                TestBundlePath='__TESTROOT__/IMAppTests.xctest',EnvironmentVariables={'IMV2_APP_ACK_CUT_E2E':'1'})}))
            nonce = str(uuid.uuid4())
            data = prepare_xctestrun(SimpleNamespace(app_xctestrun=source),root/'new.xctestrun',exact_test=EXACT_TEST,
                environment_overrides={'IMV2_LOCAL_ACCOUNT_E2E':'1','IMV2_APP_ROOM_PROGRESS_E2E':'1','IMV2_APP_ROOM_PROGRESS_NONCE':nonce})
            target = targets(data)[0]
            self.assertEqual(target['OnlyTestIdentifiers'],[EXACT_TEST.split('/',1)[1]])
            self.assertEqual(target['EnvironmentVariables']['IMV2_APP_ROOM_PROGRESS_NONCE'],nonce)
            self.assertNotIn('IMV2_APP_ACK_CUT_E2E',target['EnvironmentVariables'])


if __name__ == '__main__': unittest.main()
