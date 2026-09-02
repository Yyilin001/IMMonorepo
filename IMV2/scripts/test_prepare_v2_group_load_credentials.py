#!/usr/bin/env python3

import json
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("prepare_v2_group_load_credentials.py")
ROOM_A = "00000000-0000-4000-8000-000000000014"
ROOM_B = "00000000-0000-4000-8000-0000000000c8"


class PrepareGroupLoadCredentialsTests(unittest.TestCase):
    def test_selects_slice_and_strips_refresh_credential(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.jsonl"
            output = root / "output.jsonl"
            expires = int(time.time() * 1000) + 3_600_000
            records = [
                {
                    "userID": f"00000000-0000-4000-8000-{index:012x}",
                    "deviceID": f"10000000-0000-4000-8000-{index:012x}",
                    "accessToken": f"token-{index}",
                    "accessTokenExpiresAtMilliseconds": expires,
                    "refreshCredential": f"refresh-{index}",
                }
                for index in range(1, 5)
            ]
            source.write_text(
                "".join(json.dumps(record) + "\n" for record in records),
                encoding="utf-8",
            )

            subprocess.run(
                [
                    str(SCRIPT),
                    "--input",
                    str(source),
                    "--output",
                    str(output),
                    "--offset",
                    "1",
                    "--limit",
                    "2",
                    "--target-room",
                    ROOM_A,
                    "--target-room",
                    ROOM_B,
                ],
                check=True,
            )

            prepared = [json.loads(line) for line in output.read_text().splitlines()]
            self.assertEqual([record["accessToken"] for record in prepared], ["token-2", "token-3"])
            self.assertEqual(prepared[0]["targetRoomIDs"], [ROOM_A, ROOM_B])
            self.assertNotIn("refreshCredential", prepared[0])
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
