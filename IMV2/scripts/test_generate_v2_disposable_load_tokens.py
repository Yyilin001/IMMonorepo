#!/usr/bin/env python3

import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("generate_v2_disposable_load_tokens.py")


class DisposableLoadTokenGeneratorTests(unittest.TestCase):
    def test_generates_device_bound_credentials_and_hmac_only_database_rows(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.tsv"
            credentials = root / "credentials.jsonl"
            database = root / "database.tsv"
            key_file = root / "token-key"
            source.write_text(
                "00000000-0000-0000-0000-000000000001\t"
                "00000000-0000-0000-0000-000000000002\t"
                "00000000-0000-0000-0000-000000000003\t"
                "00000000-0000-0000-0000-000000000004\n",
                encoding="utf-8",
            )
            key = bytes(range(32))
            key_file.write_text(base64.b64encode(key).decode(), encoding="utf-8")
            environment = os.environ | {
                "IMV2_DISPOSABLE_LOAD_TOKEN_GENERATION": "1",
            }
            subprocess.run([
                str(SCRIPT), "--input", str(source),
                "--credentials-output", str(credentials),
                "--database-output", str(database),
                "--count", "1", "--lifetime-seconds", "3600",
                "--token-key-file", str(key_file),
            ], check=True, env=environment)

            credential = json.loads(credentials.read_text(encoding="utf-8"))
            database_columns = database.read_text(encoding="utf-8").rstrip().split("\t")
            expected_hmac = hmac.new(
                key, credential["accessToken"].encode(), hashlib.sha256
            ).hexdigest()
            self.assertEqual(database_columns[0], expected_hmac)
            self.assertNotIn(credential["accessToken"], database.read_text(encoding="utf-8"))
            self.assertEqual(len(credential["targetRoomIDs"]), 2)
            self.assertEqual(credentials.stat().st_mode & 0o777, 0o600)
            self.assertEqual(database.stat().st_mode & 0o777, 0o600)

    def test_rejects_duplicate_devices_without_creating_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.tsv"
            row = (
                "00000000-0000-0000-0000-000000000001\t"
                "00000000-0000-0000-0000-000000000002\t"
                "00000000-0000-0000-0000-000000000003\t"
                "00000000-0000-0000-0000-000000000004\n"
            )
            source.write_text(row + row, encoding="utf-8")
            credentials = root / "credentials.jsonl"
            database = root / "database.tsv"
            environment = os.environ | {
                "IMV2_DISPOSABLE_LOAD_TOKEN_GENERATION": "1",
                "IM_V2_ACCESS_TOKEN_HMAC_KEY_BASE64": base64.b64encode(bytes(32)).decode(),
            }
            result = subprocess.run([
                str(SCRIPT), "--input", str(source),
                "--credentials-output", str(credentials),
                "--database-output", str(database),
                "--count", "2", "--lifetime-seconds", "3600",
            ], env=environment, capture_output=True, text=True)

            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(credentials.exists())
            self.assertFalse(database.exists())
            self.assertNotIn("accessToken", result.stderr)


if __name__ == "__main__":
    unittest.main()
