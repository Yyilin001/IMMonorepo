import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

GENERATOR = Path(__file__).with_name("prepare_v2_room_actor_configuration.py")


class DeploymentExtensionTests(unittest.TestCase):
    def test_extension_preserves_credentials_and_rejects_identity_changes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            initial, expanded = root / "initial", root / "expanded"
            common = ["--host", "gateway=localhost:7337", "--caller", "account=localhost:7338",
                      "--caller", "membership-controller=localhost:7360", "--membership-controller", "membership-controller",
                      "--caller", "placement-controller=localhost:7362", "--placement-controller", "placement-controller",
                      "--placement-voter", "control-a=localhost:7340", "--placement-voter", "control-b=localhost:7341",
                      "--placement-voter", "control-c=localhost:7342", "--shards", "rooms-primary",
                      "--service-membership-shard", "rooms-primary"]

            def generate(output, arguments, succeeds=True):
                result = subprocess.run([sys.executable, str(GENERATOR), "--output-dir", str(output), *arguments],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, succeeds, result.stderr)

            generate(initial, common + ["--trust-admission-authority", "admission-authority"])
            document = json.loads((initial / "gateway/configuration.json").read_text())
            controller = json.loads((initial / "membership-controller/configuration.json").read_text())
            own = next(service for service in controller["services"] if service["id"] == "membership-controller")
            self.assertEqual(set(own["permissions"]), {"placementRead", "placementWrite", "placementMembership"})
            self.assertEqual(own["gatewayNodeIDs"], [])
            self.assertNotIn("policyPlacement", controller)
            self.assertFalse(any(peer["nodeID"] == "membership-controller" for peer in controller["realtimePeers"]))
            transfer_config = json.loads((initial / "placement-controller/configuration.json").read_text())
            transfer_identity = next(service for service in transfer_config["services"] if service["id"] == "placement-controller")
            self.assertEqual(set(transfer_identity["permissions"]), {"placementRead", "placementWrite", "roomCoordination"})
            self.assertEqual(transfer_identity["gatewayNodeIDs"], [])
            self.assertNotIn("policyPlacement", transfer_config)
            self.assertFalse(any(peer["serviceID"] == "placement-controller" for peer in transfer_config["realtimePeers"]))
            authority = next(service for service in document["services"] if service["id"] == "admission-authority")
            public_der = subprocess.run(["openssl", "pkey", "-in", str(initial / ".trust-admission/signing.pem"),
                                         "-pubout", "-outform", "DER"], check=True, capture_output=True).stdout
            self.assertEqual(base64.b64decode(authority["publicKeyBase64"]), public_der[-32:])
            for field in ["permissions", "hostIDs", "shardIDs", "userBucketIDs", "gatewayNodeIDs"]:
                self.assertEqual(authority[field], [])
            admission_directory = Path(document["trustAdmissionDirectory"])
            self.assertTrue(admission_directory.is_dir())
            self.assertEqual(admission_directory.stat().st_mode & 0o777, 0o700)
            # Deployment staging copies opaque signed packets; verification
            # is owned by the runtime, not by the configuration generator.
            (admission_directory / "retained.pb").write_bytes(b"opaque-signed-packet")
            before = {str(path.relative_to(initial)): hashlib.sha256(path.read_bytes()).hexdigest()
                      for path in initial.rglob("*") if path.is_file()}
            generate(expanded, common + ["--extend-from", str(initial), "--host", "new-gateway=localhost:7350"])
            old = json.loads((initial / "topology.json").read_text())
            new = json.loads((expanded / "topology.json").read_text())
            self.assertEqual(old["placementClusterID"], new["placementClusterID"])
            self.assertEqual(old["voterIDs"], new["voterIDs"])
            self.assertEqual(old["hostIDs"]["gateway"], new["hostIDs"]["gateway"])
            self.assertEqual(old["policyPlacement"], new["policyPlacement"])
            joined = json.loads((expanded / "new-gateway/configuration.json").read_text())
            self.assertEqual(joined["trustAdmissionAuthorityServiceID"], authority["id"])
            self.assertIn(authority, joined["services"])
            self.assertEqual(joined["serviceMembershipShard"], "rooms-primary")
            self.assertTrue(Path(joined["trustAdmissionDirectory"]).is_dir())
            self.assertEqual((expanded / "gateway/trust-admissions/retained.pb").read_bytes(), b"opaque-signed-packet")
            self.assertEqual((initial / ".trust-admission/signing.pem").read_bytes(),
                             (expanded / ".trust-admission/signing.pem").read_bytes())
            self.assertEqual((expanded / ".trust-admission/signing.pem").stat().st_mode & 0o777, 0o600)
            self.assertFalse((expanded / "new-gateway/signing.pem").exists())
            for name in ["gateway", "account", "control-a", "control-b", "control-c", "membership-controller", "placement-controller"]:
                for filename in ["signing.key", "tls.key", "tls.pem", "ca.pem"]:
                    self.assertEqual((initial / name / filename).read_bytes(), (expanded / name / filename).read_bytes())
                old_config = json.loads((initial / name / "configuration.json").read_text())
                new_config = json.loads((expanded / name / "configuration.json").read_text())
                self.assertEqual(old_config["placementControl"]["port"], new_config["placementControl"]["port"])
                self.assertEqual(old_config["placementControl"]["storagePaths"], new_config["placementControl"]["storagePaths"])
                self.assertEqual(old_config["trustAdmissionDirectory"], new_config["trustAdmissionDirectory"])
                for service in old_config["services"]:
                    self.assertIn(service, new_config["services"])
            for filename in ["cert.pem", "key.pem"]:
                self.assertEqual((initial / "ca" / filename).read_bytes(), (expanded / "ca" / filename).read_bytes())
            subprocess.run(["openssl", "verify", "-CAfile", str(initial / "ca/cert.pem"),
                            str(expanded / "new-gateway/tls.pem")], check=True, capture_output=True)
            after = {str(path.relative_to(initial)): hashlib.sha256(path.read_bytes()).hexdigest()
                     for path in initial.rglob("*") if path.is_file()}
            self.assertEqual(before, after)
            moved = [value.replace("gateway=localhost:7337", "gateway=localhost:7336") for value in common]
            generate(root / "moved", moved + ["--extend-from", str(initial)], succeeds=False)
            self.assertFalse((root / "moved").exists())
            generate(root / "wrong-cluster", common + ["--extend-from", str(initial), "--placement-cluster-id",
                     "00000000-0000-0000-0000-000000000001"], succeeds=False)
            self.assertFalse((root / "wrong-cluster").exists())
            generate(root / "wrong-authority", common + ["--extend-from", str(initial),
                     "--trust-admission-authority", "replacement-authority"], succeeds=False)
            self.assertFalse((root / "wrong-authority").exists())
            generate(root / "shared-authority", common + ["--trust-admission-authority", "gateway"], succeeds=False)
            self.assertFalse((root / "shared-authority").exists())


if __name__ == "__main__":
    unittest.main()
