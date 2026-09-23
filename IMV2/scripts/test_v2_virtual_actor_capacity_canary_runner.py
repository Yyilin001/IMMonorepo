#!/usr/bin/env python3
"""No-Docker validation of the isolated capacity canary runner's input fences."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
RUNNER = HERE / "test_v2_virtual_actor_capacity_canary.py"
PREPARE = HERE / "prepare_v2_virtual_actor_capacity_fixture.py"


class CanaryRunnerPreflightTests(unittest.TestCase):
    def test_source_binary_and_fixture_hashes_are_required_before_docker(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            (source / "IMV2/sql").mkdir(parents=True)
            (source / "IMV2Server").mkdir()
            (source / "IMV2/sql/schema.sql").write_text("-- test schema\n")
            (source / "IMV2/docker-compose.local-account.yml").write_text("services: {}\n")
            (source / "IMV2Server/Package.resolved").write_text("{}\n")
            subprocess.run(["git", "init", "-q", str(source)], check=True)
            subprocess.run(["git", "-C", str(source), "add", "."], check=True)
            subprocess.run(["git", "-C", str(source), "-c", "user.name=Fixture Test",
                            "-c", "user.email=fixture@example.invalid", "commit", "-qm", "source"], check=True)
            source_sha = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
            release = root / "release"
            release.mkdir()
            products = {}
            for name in ("IMV2ServerApp", "IMV2GatewayLoadGenerator"):
                path = release / name
                path.write_bytes(b"\x7fELF" + name.encode())
                path.chmod(0o700)
                products[name] = hashlib.sha256(path.read_bytes()).hexdigest()
            fixture = root / "fixture"
            subprocess.run([sys.executable, str(PREPARE), "--output-dir", str(fixture),
                            "--seed", "22f741c0-6ebe-4e35-9bc3-23e3c2c3b89a",
                            "--users", "8", "--targets", "2", "--owners", "2",
                            "--command-window-limit", "1000",
                            "--expires-at", "2030-01-01T00:00:00Z"],
                           check=True, capture_output=True)
            build_result = root / "build-result.json"
            build_result.write_text(json.dumps({
                "sourceSHA": source_sha,
                "lockfileSHA256": hashlib.sha256((source / "IMV2Server/Package.resolved").read_bytes()).hexdigest(),
                "image": "swift:6.4-jammy@sha256:a6053d2de72091906bfa064f76f145e3f28830664cae250e1b84aa8c499a8ee6",
                "passed": True, "exitCode": 0, "products": products,
            }))
            command = [sys.executable, str(RUNNER), "--source-checkout", str(source),
                       "--source-sha", source_sha, "--release-dir", str(release),
                       "--build-result", str(build_result),
                       "--fixture-dir", str(fixture), "--layout", "hot",
                       "--docker-context", "test-isolated", "--artifact-dir", str(root / "evidence"),
                       "--preflight-only"]
            passed = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(passed.returncode, 0, passed.stderr)
            self.assertIn("VA_CAPACITY_CANARY_PREFLIGHT_OK", passed.stdout)
            self.assertFalse((root / "evidence").exists())
            (release / "IMV2ServerApp").write_bytes(b"\x7fELFchanged")
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            (release / "IMV2ServerApp").write_bytes(b"\x7fELFIMV2ServerApp")
            corrected = root / "corrected-loader"
            corrected.mkdir()
            corrected_binary = corrected / "IMV2GatewayLoadGenerator"
            corrected_binary.write_bytes(b"\x7fELFcorrected-loader")
            corrected_binary.chmod(0o700)
            corrected_result = root / "corrected-result.json"
            corrected_result.write_text(json.dumps({
                "sourceSHA": "a" * 40, "lockfileSHA256": "b" * 64,
                "image": "swift:6.4-jammy@sha256:a6053d2de72091906bfa064f76f145e3f28830664cae250e1b84aa8c499a8ee6",
                "passed": True, "exitCode": 0,
                "products": {"IMV2GatewayLoadGenerator": hashlib.sha256(corrected_binary.read_bytes()).hexdigest()},
            }))
            with_corrected = command + ["--loader-products-dir", str(corrected),
                                        "--loader-build-result", str(corrected_result)]
            self.assertEqual(subprocess.run(with_corrected, capture_output=True).returncode, 0)
            corrected_binary.write_bytes(b"\x7fELFstale-loader")
            self.assertNotEqual(subprocess.run(with_corrected, capture_output=True).returncode, 0)
            (fixture / "hot/credentials.jsonl").write_text("{}\n")
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            (source / "IMV2/sql/schema.sql").write_text("-- changed\n")
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)


if __name__ == "__main__":
    unittest.main()
