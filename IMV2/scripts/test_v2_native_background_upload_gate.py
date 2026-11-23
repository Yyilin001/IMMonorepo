"""Keep owned upload observation aligned with ResourceBackgroundAuthorization.swift."""
import base64
import json
import unittest
import uuid
from v2_native_background_upload_gate import NativeBackgroundUploadGate, BACKGROUND_FIXTURE_BYTES


class UploadObservationContractTests(unittest.TestCase):
    def target(self, grant):
        claims = {'backgroundAuthorization': grant} if grant else {}
        payload = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip('=')
        return '/v2/local-media/upload/owned?target=fixture.' + payload + '.fixture'

    def test_current_part_scope_is_counted_as_background(self):
        media = str(uuid.uuid4())
        gate = NativeBackgroundUploadGate()
        grant = {'mediaID': {'rawValue': media}, 'scope': {'part': {'number': 1}}}
        self.assertTrue(gate.claim(self.target(grant), len(BACKGROUND_FIXTURE_BYTES)))
        self.assertEqual(gate.media_id, media)
        self.assertEqual(gate.part_number, 1)
        self.assertEqual(gate.snapshot()['backgroundRequests'], 1)
        self.assertEqual(gate.snapshot()['foregroundHits'], 0)
        self.assertFalse(gate.claim(self.target(grant), len(BACKGROUND_FIXTURE_BYTES)))
        self.assertEqual(gate.snapshot()['hits'], 1)

    def test_foreground_and_wrong_size_do_not_open_observation_gate(self):
        gate = NativeBackgroundUploadGate()
        self.assertFalse(gate.claim(self.target(None), len(BACKGROUND_FIXTURE_BYTES)))
        grant = {'mediaID': {'rawValue': str(uuid.uuid4())}, 'scope': {'part': {'number': 1}}}
        self.assertFalse(gate.claim(self.target(grant), 1))
        self.assertEqual(gate.snapshot()['hits'], 0)


if __name__ == '__main__':
    unittest.main()
