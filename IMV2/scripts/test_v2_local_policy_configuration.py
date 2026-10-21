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
                       "--placement-voter", "placement-a=placement-a:7336",
                       "--placement-voter", "placement-b=placement-b:7336",
                       "--placement-voter", "placement-c=placement-c:7336",
                       "--shards", "rooms-primary", "--user-buckets", "users-primary",
                       "--mount-root", "/run/im-v2-room-actor", "--policy-partitions", "16"]
        subprocess.run(cls.command, check=True, capture_output=True)
        cls.documents = {name: json.loads((cls.generated / name / "configuration.json").read_text())
                         for name in ("gateway", "account", "operator", "placement-a", "placement-b", "placement-c")}

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

    def test_expansion_reuses_explicit_deployment_identity(self):
        cluster_id = self.documents["gateway"]["placementControl"]["clusterID"]
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / "expanded"
            command = list(self.command)
            command[command.index("--output-dir") + 1] = str(target)
            command += ["--host", "gateway-2=gateway-2:7337", "--placement-cluster-id", cluster_id]
            subprocess.run(command, check=True, capture_output=True)
            for path in target.glob("*/configuration.json"):
                self.assertEqual(json.loads(path.read_text())["placementControl"]["clusterID"], cluster_id)
            self.assertEqual(json.loads((target / "topology.json").read_text())["placementClusterID"], cluster_id)

    def test_missing_placement_identity_is_rejected(self):
        documents = copy.deepcopy(self.documents)
        documents["gateway"]["placementControl"].pop("clusterID")
        with self.assertRaises(ValueError):
            self.validate_documents(documents)

    def test_different_placement_identity_is_rejected(self):
        documents = copy.deepcopy(self.documents)
        documents["account"]["placementControl"]["clusterID"] = "00000000-0000-0000-0000-000000000001"
        with self.assertRaises(ValueError):
            self.validate_documents(documents)

    def test_generated_readers_and_writers_share_gateway_owners(self):
        validate(self.generated)
        for name, document in self.documents.items():
            self.assertEqual(document["serviceID"], name)
            self.assertTrue((self.generated / name / "signing.key").is_file())
            if name in ("gateway", "account", "operator"):
                self.assertEqual(document["policyPlacement"], self.documents["gateway"]["policyPlacement"])
            else:
                self.assertNotIn("policyPlacement", document)

    def test_seeded_topology_keeps_fresh_private_keys(self):
        with tempfile.TemporaryDirectory() as temporary:
            roots=[Path(temporary)/name for name in ('a','b')]
            for root in roots:
                command=self.command.copy()
                command[command.index('--output-dir')+1]=str(root)
                command += ['--identity-seed','cc50ac35-0881-4366-9502-08f8bb6c118a']
                subprocess.run(command,check=True,capture_output=True)
                validate(root)
            first,second=[json.loads((root/'topology.json').read_text()) for root in roots]
            self.assertEqual(first,second)
            self.assertNotEqual((roots[0]/'gateway/signing.key').read_bytes(),
                                (roots[1]/'gateway/signing.key').read_bytes())

    def test_legacy_or_different_writer_placement_is_rejected(self):
        for name in ("gateway", "account", "operator"):
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
        for name in ("gateway", "account", "operator"):
            document = documents[name]
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

    def test_missing_or_cohosted_control_is_rejected(self):
        documents = copy.deepcopy(self.documents)
        documents["gateway"].pop("placementControl")
        with self.assertRaises(ValueError):
            self.validate_documents(documents)
        documents = copy.deepcopy(self.documents)
        documents["placement-a"]["hostID"] = documents["gateway"]["hostID"]
        with self.assertRaises(ValueError):
            self.validate_documents(documents)

    def test_reader_with_different_quorum_is_rejected(self):
        documents = copy.deepcopy(self.documents)
        documents["account"]["placementControl"]["voters"][0]["hostID"] = "different-voter"
        with self.assertRaises(ValueError):
            self.validate_documents(documents)


if __name__ == "__main__":
    unittest.main()
