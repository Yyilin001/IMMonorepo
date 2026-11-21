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
                      "--caller", "placement-controller=localhost:7362", "--placement-controller", "placement-controller",
                      "--placement-voter", "control-a=localhost:7340", "--placement-voter", "control-b=localhost:7341",
                      "--placement-voter", "control-c=localhost:7342", "--shards", "rooms-primary"]

            def generate(output, arguments, succeeds=True):
                result = subprocess.run([sys.executable, str(GENERATOR), "--output-dir", str(output), *arguments],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, succeeds, result.stderr)

            generate(initial, common)
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
            self.assertNotIn("serviceMembershipShard", joined)
            self.assertNotIn("trustAdmissionDirectory", joined)
            reduced = root / "reduced"
            only_new = [value.replace("gateway=localhost:7337", "new-gateway=localhost:7350") for value in common]
            generate(reduced, only_new + ["--extend-from", str(expanded)])
            reduced_config = json.loads((reduced / "new-gateway/configuration.json").read_text())
            self.assertNotIn("gateway", [service["id"] for service in reduced_config["services"]])
            self.assertEqual([peer["serviceID"] for peer in reduced_config["peers"]], ["new-gateway"])
            self.assertEqual({o["hostID"] for o in reduced_config["policyPlacement"]["owners"]}, {new["hostIDs"]["new-gateway"]})
            self.assertFalse((expanded / "new-gateway/signing.pem").exists())
            for name in ["gateway", "account", "control-a", "control-b", "control-c", "placement-controller"]:
                for filename in ["signing.key", "tls.key", "tls.pem", "ca.pem"]:
                    self.assertEqual((initial / name / filename).read_bytes(), (expanded / name / filename).read_bytes())
                old_config = json.loads((initial / name / "configuration.json").read_text())
                new_config = json.loads((expanded / name / "configuration.json").read_text())
                self.assertEqual(old_config["placementControl"]["port"], new_config["placementControl"]["port"])
                self.assertEqual(old_config["placementControl"]["storagePaths"], new_config["placementControl"]["storagePaths"])
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
