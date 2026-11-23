import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


class GatewayExtensionTests(unittest.TestCase):
    def test_extension_preserves_identity_and_refuses_authority_changes(self):
        script = Path(__file__).with_name("prepare_v2_room_actor_configuration.py")
        with tempfile.TemporaryDirectory() as path:
            root = Path(path)
            before, after = root / "initial", root / "expanded"
            base = [
                sys.executable,
                script,
                "--single-core",
                "--shards",
                "rooms",
                "--host",
                "room-core=room-core:7000",
                "--gateway",
                "gw-a=gw-a:7000",
            ]
            subprocess.run([*base, "--output-dir", before], check=True, capture_output=True)
            subprocess.run(
                [*base, "--extend-from", before, "--output-dir", after, "--gateway", "gw-b=gw-b:7000"],
                check=True,
                capture_output=True,
            )
            for node in ("room-core", "gw-a"):
                for asset in ("signing.key", "tls.key", "tls.pem", "ca.pem"):
                    self.assertEqual((before / node / asset).read_bytes(), (after / node / asset).read_bytes())
            initial = json.loads((before / "room-core/configuration.json").read_text())
            expanded = json.loads((after / "room-core/configuration.json").read_text())
            for field in ("peers", "policyPlacement", "hostID"):
                self.assertEqual(initial[field], expanded[field])
            self.assertEqual(len(expanded["realtimePeers"]), 3)
            rejected = subprocess.run(
                [*base, "--extend-from", after, "--output-dir", root / "invalid"], check=False, capture_output=True
            )
            self.assertNotEqual(rejected.returncode, 0)
            self.assertFalse((root / "invalid").exists())
