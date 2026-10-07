#!/usr/bin/env python3
"""Exercise local policy wiring with real generated process identities."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from validate_v2_local_policy_configuration import validate


SCRIPTS = Path(__file__).resolve().parent


class LocalPolicyConfigurationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.generated = Path(cls.temporary.name) / "generated"
        cls.command = [sys.executable, str(SCRIPTS / "prepare_v2_room_actor_configuration.py"),
                       "--output-dir", str(cls.generated), "--host", "gateway=gateway:7337",
                       "--caller", "account=account:7338", "--caller", "operator=operator:7339",
                       "--shards", "rooms-primary", "--user-buckets", "users-primary",
                       "--mount-root", "/run/im-v2-room-actor", "--policy-partitions", "16"]
        subprocess.run(cls.command, check=True, capture_output=True)
        cls.documents = {name: json.loads((cls.generated / name / "configuration.json").read_text())
                         for name in ("gateway", "account", "operator")}

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def validate_documents(self, documents):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name, document in documents.items():
                directory = root / name
                directory.mkdir()
                (directory / "configuration.json").write_text(json.dumps(document))
            validate(root)

    def test_generated_readers_and_writers_share_gateway_owners(self):
        validate(self.generated)
        for name, document in self.documents.items():
            self.assertEqual(document["serviceID"], name)
            self.assertTrue((self.generated / name / "signing.key").is_file())
            self.assertEqual(document["policyPlacement"], self.documents["gateway"]["policyPlacement"])

    def test_legacy_or_different_writer_placement_is_rejected(self):
        for name in self.documents:
            with self.subTest(process=name):
                documents = copy.deepcopy(self.documents)
                documents[name].pop("policyPlacement")
                with self.assertRaises(ValueError):
                    self.validate_documents(documents)
        documents = copy.deepcopy(self.documents)
        documents["operator"]["policyPlacement"]["revision"] += 1
        with self.assertRaises(ValueError):
            self.validate_documents(documents)

    def test_missing_writer_rpc_permission_is_rejected(self):
        for writer in ("account", "operator"):
            with self.subTest(writer=writer):
                documents = copy.deepcopy(self.documents)
                service = next(item for item in documents["gateway"]["services"] if item["id"] == writer)
                service["permissions"].remove("policyMutation")
                with self.assertRaises(ValueError):
                    self.validate_documents(documents)

    def test_incomplete_partition_ownership_is_rejected(self):
        documents = copy.deepcopy(self.documents)
        for document in documents.values():
            document["policyPlacement"]["owners"][0]["partitions"].pop()
        with self.assertRaises(ValueError):
            self.validate_documents(documents)

    def test_restart_does_not_rotate_existing_identities(self):
        before = {path.relative_to(self.generated): path.read_bytes()
                  for path in self.generated.rglob("*") if path.is_file()}
        result = subprocess.run(self.command, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        after = {path.relative_to(self.generated): path.read_bytes()
                 for path in self.generated.rglob("*") if path.is_file()}
        self.assertEqual(before, after)


if __name__ == "__main__":
    unittest.main()
