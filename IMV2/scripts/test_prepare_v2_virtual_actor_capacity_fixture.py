#!/usr/bin/env python3
"""Lightweight contract checks for the disposable capacity fixture generator."""

import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("prepare_v2_virtual_actor_capacity_fixture.py")
SEED = "22f741c0-6ebe-4e35-9bc3-23e3c2c3b89a"


class CapacityFixtureTests(unittest.TestCase):
    def run_generator(self, output: Path, *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--output-dir", str(output), "--seed", SEED,
             "--users", "8", "--targets", "2", "--owners", "2",
             "--expires-at", "2030-01-01T00:00:00Z", "--members-per-room", "2",
             "--command-window-limit", "100000", *extra],
            capture_output=True, text=True, check=False,
        )

    def test_four_layouts_have_fixed_identity_and_valid_private_hmac_credentials(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first, second = root / "first", root / "second"
            self.assertEqual(self.run_generator(first).returncode, 0)
            self.assertEqual(self.run_generator(second).returncode, 0)
            one = json.loads((first / "manifest.json").read_text())
            two = json.loads((second / "manifest.json").read_text())
            self.assertNotEqual(one["authControlSQLSHA256"], two["authControlSQLSHA256"])
            one.pop("authControlSQLSHA256")
            two.pop("authControlSQLSHA256")
            for layout in ("hot", "same-owner", "mixed", "cold"):
                self.assertNotEqual(
                    one["layouts"][layout].pop("credentialFileSHA256"),
                    two["layouts"][layout].pop("credentialFileSHA256"),
                )
            self.assertEqual(one, two)
            self.assertEqual(set(one["layouts"]), {"hot", "same-owner", "mixed", "cold"})
            self.assertEqual(one["identityMappingSHA256"], two["identityMappingSHA256"])
            self.assertNotEqual(
                (first / "access-token-hmac-key.base64").read_bytes(),
                (second / "access-token-hmac-key.base64").read_bytes(),
            )
            key = base64.b64decode((first / "access-token-hmac-key.base64").read_text())
            auth = (first / "auth-control.sql").read_text()
            for layout in ("hot", "same-owner", "mixed", "cold"):
                detail = one["layouts"][layout]
                credentials_path = first / layout / "credentials.jsonl"
                credentials = [json.loads(line) for line in credentials_path.read_text().splitlines()]
                self.assertEqual(len(credentials), 8)
                self.assertEqual(detail["memberships"], 16)
                self.assertEqual(sum(detail["ownerRoomCounts"]), detail["rooms"])
                self.assertEqual(sum(detail["ownerMembershipCounts"]), 16)
                for credential in credentials:
                    self.assertEqual(len(credential["targetRoomIDs"]), 2)
                    self.assertEqual(len(set(credential["targetRoomIDs"])), 2)
                    digest = hmac.new(key, credential["accessToken"].encode(), hashlib.sha256).hexdigest()
                    self.assertIn(digest, auth)
                self.assertEqual(credentials[0]["targetRoomIDs"], credentials[1]["targetRoomIDs"])
                if layout != "hot":
                    self.assertNotEqual(credentials[0]["targetRoomIDs"], credentials[4]["targetRoomIDs"])
                self.assertEqual(os.stat(credentials_path).st_mode & 0o777, 0o600)
                self.assertEqual(os.stat(first / layout).st_mode & 0o777, 0o700)
            self.assertEqual(one["layouts"]["hot"]["rooms"], 2)
            self.assertEqual(one["layouts"]["cold"]["rooms"], 4)
            self.assertEqual(one["layouts"]["same-owner"]["ownerRoomCounts"], [8, 0])
            self.assertEqual(one["layouts"]["mixed"]["ownerRoomCounts"], [4, 4])
            self.assertEqual(os.stat(first).st_mode & 0o777, 0o700)
            self.assertEqual(os.stat(first / "access-token-hmac-key.base64").st_mode & 0o777, 0o600)

    def test_refuses_existing_output_and_bad_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "fixture"
            self.assertEqual(self.run_generator(output).returncode, 0)
            self.assertNotEqual(self.run_generator(output).returncode, 0)
            self.assertNotEqual(self.run_generator(root / "bad", "--shard-prefix", "x';DROP").returncode, 0)
            self.assertNotEqual(self.run_generator(root / "expired", "--expires-at", "2000-01-01T00:00:00Z").returncode, 0)
            self.assertNotEqual(self.run_generator(root / "oversized", "--users", "10001").returncode, 0)
            self.assertFalse((root / "bad").exists())

    def test_every_sql_file_requires_disposable_database_marker(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "fixture"
            self.assertEqual(self.run_generator(output).returncode, 0)
            sql_files = list(output.rglob("*.sql"))
            self.assertEqual(len(sql_files), 2 + 4 * 3)
            for path in sql_files:
                body = path.read_text()
                self.assertIn("imv2_disposable_fixture_guard", body)
                self.assertIn("^imv2_va_", body)
                self.assertTrue(body.endswith("COMMIT;\n"))
                self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
