"""Pure closed proof predicates; no Xcode, socket, PostgreSQL or simulator."""
import unittest
import uuid
from v2_app_outbox_canary import accepted_fact, proof_matches, selected_test_failure_signal


class AppOutboxCanaryProofTests(unittest.TestCase):
    def test_actual_selected_test_failure_is_terminal_before_xcode_process_exit(self):
        actual = '✘ Test unexpectedTCPDisconnectReplaysDurableWorkAcrossGateway() failed after 2.747 seconds with 1 issue.'
        self.assertEqual(selected_test_failure_signal(actual), 'selected_test_failed')
        self.assertEqual(selected_test_failure_signal('✘ Test run with 1 test in 1 suite failed after 2.748 seconds with 1 issue.'), 'single_test_run_failed')
        self.assertIsNone(selected_test_failure_signal('✘ Test unrelatedTest() failed after 2.747 seconds with 1 issue.'))
        self.assertIsNone(selected_test_failure_signal('✘ Test unexpectedTCPDisconnectReplaysDurableWorkAcrossGateway() recorded an issue at file.swift:131'))
        self.assertIsNone(selected_test_failure_signal('✘ Test run with 2 tests in 1 suite failed after 2.748 seconds with 1 issue.'))

    def test_exact_lost_ack_proof_requires_same_fact_and_actual_replacement(self):
        identity = {key:str(uuid.uuid4()) for key in ('nonce','workID','roomID','connectionGeneration')}
        fact = dict(messages=1,receipts=1,completions=1,closures=0,exactAccepted=True,
                    messageID=str(uuid.uuid4()),roomSequence=2)
        proof = dict(nonce=identity['nonce'].upper(),workID=identity['workID'].upper(),
            roomID=identity['roomID'].upper(),messageID=fact['messageID'].upper(),roomSequence=2,
            oldConnectionGeneration=identity['connectionGeneration'].upper(),
            newConnectionGeneration=str(uuid.uuid4()),sameIdentity=True,unknownObserved=True,
            automaticReconnect=True,senderReadyHighWatermark=2,senderAppliedCursor=2,receiverCursor=2)
        self.assertTrue(accepted_fact(fact))
        self.assertTrue(proof_matches(identity,fact,proof))
        self.assertFalse(accepted_fact(dict(fact,closures=1)))
        self.assertFalse(accepted_fact(dict(fact,exactAccepted=False)))
        self.assertFalse(proof_matches(identity,fact,dict(proof,newConnectionGeneration=identity['connectionGeneration'])))
        self.assertFalse(proof_matches(identity,fact,dict(proof,senderAppliedCursor=1)))
        self.assertFalse(proof_matches(identity,fact,dict(proof,messageID=str(uuid.uuid4()))))
