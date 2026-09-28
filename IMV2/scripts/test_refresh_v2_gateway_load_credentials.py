#!/usr/bin/env python3
"""Offline contract check for the gateway load credential refresh helper."""

import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("refresh_v2_gateway_load_credentials.sh")
USER_ID = "00000000-0000-4000-8000-000000000001"
DEVICE_ID = "10000000-0000-4000-8000-000000000001"
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from verify_v2_live_account_authorization import has_canonical_revocation_binding


def revocation_credential(number: int) -> str:
    return "imv2-revoke-v1." + base64.urlsafe_b64encode(bytes([number]) * 32).decode("ascii").rstrip("=")


class RefreshGatewayLoadCredentialsTests(unittest.TestCase):
    def test_bad_response_drains_first_batch_without_starting_next(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            request_dir = root / "requests"
            request_dir.mkdir()
            fake_curl = fake_bin / "curl"
            fake_curl.write_text("""#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
body = json.load(sys.stdin)
index = int(body['userID'][-12:], 16)
requests = Path(os.environ['FAKE_REFRESH_REQUEST_DIR'])
if index == 15:
    time.sleep(0.2)
response = 'PRIVATE_BAD_RESPONSE_BODY' if str(index) == os.environ.get('FAKE_REFRESH_BAD_INDEX') else json.dumps({
    'userID': body['userID'], 'deviceID': body['deviceID'],
    'accessToken': 'access-new', 'accessTokenExpiresAtMilliseconds': 2000000000000,
    'refreshCredential': 'refresh-new',
    'revocationCredential': body['revocationCredential'],
    'revocationCredentialExpiresAtMilliseconds': 2000000000000,
})
Path(sys.argv[sys.argv.index('--output') + 1]).write_text(response)
(requests / ('request-' + str(index) + '.json')).write_text(json.dumps(body))
sys.stdout.write('200')
""", encoding="utf-8")
            fake_curl.chmod(0o700)
            ca = root / "ca.pem"
            ca.write_text("offline fixture", encoding="utf-8")
            source = root / "source.jsonl"
            output = root / "output.jsonl"
            source.write_text("".join(json.dumps({
                "userID": f"00000000-0000-4000-8000-{index:012x}",
                "deviceID": f"10000000-0000-4000-8000-{index:012x}",
                "accessToken": "access-old", "accessTokenExpiresAtMilliseconds": 2000000000000,
                "refreshCredential": "refresh-old",
                "revocationCredential": revocation_credential(index),
                "revocationCredentialExpiresAtMilliseconds": 2000000000000,
            }) + "\n" for index in range(17)), encoding="utf-8")
            environment = dict(os.environ, PATH=str(fake_bin) + os.pathsep + os.environ["PATH"],
                               FAKE_REFRESH_REQUEST_DIR=str(request_dir),
                               IM_V2_LOAD_CREDENTIAL_REFRESH_PARALLELISM="16")
            successful = subprocess.run(["bash", str(SCRIPT), "https://localhost.invalid", str(ca),
                                         str(source), str(output)], env=environment,
                                        capture_output=True, text=True)
            self.assertEqual(successful.returncode, 0)
            self.assertEqual([json.loads(line)["userID"] for line in output.read_text().splitlines()],
                             [f"00000000-0000-4000-8000-{index:012x}" for index in range(17)])
            self.assertEqual(len(list(request_dir.iterdir())), 17)
            for path in request_dir.iterdir():
                path.unlink()
            environment["FAKE_REFRESH_BAD_INDEX"] = "0"
            result = subprocess.run(["bash", str(SCRIPT), "https://localhost.invalid", str(ca),
                                     str(source), str(output)], env=environment,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(sorted(path.name for path in request_dir.iterdir()),
                             [f"request-{index}.json" for index in sorted(range(16), key=str)])
            self.assertIn("stage=response_parse category=invalid_shape http_status=200", result.stderr)
            self.assertIn("records=16 failed=1; all launched requests drained", result.stderr)
            self.assertNotIn("PRIVATE_BAD_RESPONSE_BODY", result.stdout + result.stderr)
            self.assertEqual(output.read_text(), "")

    def test_rotated_revocation_binding_is_sent_again(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            fake_curl = fake_bin / "curl"
            fake_curl.write_text("""#!/usr/bin/env python3
import base64, json, os, sys
from pathlib import Path
requests = Path(os.environ['FAKE_REFRESH_REQUESTS'])
body = json.load(sys.stdin)
with requests.open('a') as output:
    output.write(json.dumps(body) + '\\n')
number = len(requests.read_text().splitlines())
response = {
    'userID': body['userID'], 'deviceID': body['deviceID'],
    'accessToken': 'access-' + str(number),
    'accessTokenExpiresAtMilliseconds': 2000000000000,
    'refreshCredential': 'refresh-' + str(number),
    'revocationCredential': 'imv2-revoke-v1.' + base64.urlsafe_b64encode(bytes([number]) * 32).decode('ascii').rstrip('='),
    'revocationCredentialExpiresAtMilliseconds': 2000000000000,
}
Path(sys.argv[sys.argv.index('--output') + 1]).write_text(json.dumps(response))
sys.stdout.write('200')
""", encoding="utf-8")
            fake_curl.chmod(0o700)
            ca = root / "ca.pem"
            ca.write_text("offline fixture", encoding="utf-8")
            source = root / "initial.jsonl"
            first = root / "first.jsonl"
            second = root / "second.jsonl"
            requests = root / "requests.jsonl"
            source.write_text(json.dumps({
                "userID": USER_ID, "deviceID": DEVICE_ID,
                "accessToken": "access-0", "accessTokenExpiresAtMilliseconds": 2000000000000,
                "refreshCredential": "refresh-0",
                "revocationCredential": revocation_credential(0),
                "revocationCredentialExpiresAtMilliseconds": 2000000000000,
            }) + "\n", encoding="utf-8")
            environment = dict(os.environ, PATH=str(fake_bin) + os.pathsep + os.environ["PATH"],
                               FAKE_REFRESH_REQUESTS=str(requests),
                               IM_V2_LOAD_CREDENTIAL_REFRESH_PARALLELISM="1")
            for input_path, output_path in ((source, first), (first, second)):
                subprocess.run(["bash", str(SCRIPT), "https://localhost.invalid", str(ca),
                                str(input_path), str(output_path)], env=environment,
                               check=True, capture_output=True, text=True)

            sent = [json.loads(line) for line in requests.read_text().splitlines()]
            rotated = [json.loads(path.read_text().strip()) for path in (first, second)]
            self.assertEqual(len(sent), 2)
            self.assertEqual(sent[0]["refreshCredential"], "refresh-0")
            self.assertEqual(sent[0]["revocationCredential"], revocation_credential(0))
            self.assertEqual(rotated[0]["refreshCredential"], "refresh-1")
            self.assertEqual(rotated[0]["revocationCredential"], revocation_credential(1))
            self.assertEqual(sent[1]["refreshCredential"], "refresh-1")
            self.assertEqual(sent[1]["revocationCredential"], revocation_credential(1))
            self.assertEqual(rotated[1]["refreshCredential"], "refresh-2")
            self.assertEqual(rotated[1]["revocationCredential"], revocation_credential(2))
            self.assertEqual(rotated[1]["revocationCredentialExpiresAtMilliseconds"], 2000000000000)
            self.assertTrue(all(has_canonical_revocation_binding(record) for record in rotated))
            self.assertFalse(has_canonical_revocation_binding({"revocationCredential": {"proof": "old-wire"}}))
            self.assertEqual(first.stat().st_mode & 0o777, 0o600)
            self.assertEqual(second.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
