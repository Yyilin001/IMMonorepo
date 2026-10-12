#!/usr/bin/env python3
"""No-Docker validation of the isolated capacity canary runner's input fences."""

import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from unittest.mock import patch

from assess_v2_virtual_actor_capacity import read_run
from virtual_actor_capacity_measurement import MeasurementFailure

from test_v2_virtual_actor_capacity_canary import (
    CAPACITY_NOFILE, CADDY_IMAGE, IMAGE, PLACEMENT_VOTERS, CanaryFailure, install_account_services,
    install_placement_services,
    capture_detached_loader_open_file_limits,
    capture_pid1_open_file_limits, capture_project_diagnostics,
    capture_runtime_provenance, measurement_service_settings,
    formal_sampling_eligible, parse_args, parse_pid1_open_file_limits, result_mode,
    preserve_incomplete_measurement, set_capacity_open_file_limits,
)


HERE = Path(__file__).resolve().parent
RUNNER = HERE / "test_v2_virtual_actor_capacity_canary.py"
PREPARE = HERE / "prepare_v2_virtual_actor_capacity_fixture.py"


class CanaryRunnerPreflightTests(unittest.TestCase):
    def test_native_placement_keeps_three_separate_durable_voters(self) -> None:
        original = {"services": {name: {"environment": {}, "restart": "on-failure",
            "ports": ["7336:7336"], "volumes": [
                {"source": name, "target": "/run/im-v2-room-actor", "read_only": True},
                {"source": name + "/placement", "target": "/run/im-v2-room-actor/placement"}]}
            for name in PLACEMENT_VOTERS}}
        services = {"gateway": {"depends_on": {"owner00": {"condition": "service_healthy"}}},
                    "account": {"depends_on": {"postgres": {"condition": "service_healthy"}}}}
        install_placement_services(document=original, services=services,
            runtime=Path("/owned/products"), shards=["room-a", "room-b"])
        for name in PLACEMENT_VOTERS:
            voter = services[name]
            self.assertEqual(voter["image"], IMAGE)
            self.assertEqual(voter["command"], ["/run/va-products/IMV2PlacementControlApp"])
            self.assertEqual(voter["environment"]["IMV2_PLACEMENT_SHARD_IDS"], "room-a,room-b")
            self.assertEqual(voter["volumes"][:2], original["services"][name]["volumes"])
            self.assertNotIn("ports", voter)
            self.assertNotIn("restart", voter)
            self.assertIn("restart", original["services"][name])
            for application in ("gateway", "account"):
                self.assertEqual(services[application]["depends_on"][name]["condition"], "service_healthy")
        self.assertIn("owner00", services["gateway"]["depends_on"])
        self.assertIn("postgres", services["account"]["depends_on"])
        del original["services"]["placement-c"]
        with self.assertRaises(CanaryFailure):
            install_placement_services(document=original, services=services,
                runtime=Path("/owned/products"), shards=["room-a"])

    def test_http_send_stack_shares_fixture_routes_and_keeps_account_private(self) -> None:
        keys = ("IM_V2_DATABASE_URL", "IM_V2_ACCESS_TOKEN_HMAC_KEY_BASE64",
                "IM_V2_CAPACITY_PROFILE_ID", "IM_V2_MAX_ELIGIBLE_MEMBERS",
                "IM_V2_MAX_COMMANDS_PER_WINDOW", "IM_V2_USER_SHARD_BUCKET",
                "IM_V2_DIRECT_ROOM_SHARD_ID", "IM_V2_GROUP_ROOM_SHARD_ID",
                "IM_V2_USER_SHARD_STORES_JSON", "IM_V2_ROOM_SHARD_STORES_JSON")
        gateway = {key: "fixture-" + key for key in keys}
        original = {"services": {
            "account": {"environment": {"edge-secret": "private", "IM_V2_ACCOUNT_CLIENT_RATE_LIMIT_MAX_REQUESTS": "240"},
                "ports": ["127.0.0.1:8443:8443"], "volumes": [], "restart": "on-failure"},
            "caddy": {"environment": {"edge-secret": "private"}, "volumes": []}}}
        services = {}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            install_account_services(document=original, services=services, private=root,
                runtime=root / "products", tls=root / "tls", gateway_environment=gateway,
                database_names={"postgres": "control", "owner00": "owner"})
            account, edge = services["account"], services["caddy"]
            self.assertNotIn("ports", account)
            self.assertNotIn("restart", account)
            self.assertEqual(account["command"], ["/run/va-products/IMV2AccountServerApp"])
            self.assertEqual({key: account["environment"][key] for key in keys}, gateway)
            self.assertEqual(account["environment"]["IM_V2_ACCOUNT_LISTEN_HOST"], "127.0.0.1")
            self.assertEqual(set(account["depends_on"]), {"postgres", "owner00"})
            self.assertEqual(edge["image"], CADDY_IMAGE)
            self.assertEqual(edge["network_mode"], "service:account")
            config = (root / "Caddyfile").read_text()
            self.assertIn("https://account:8443", config)
            self.assertIn("reverse_proxy 127.0.0.1:8444", config)
            self.assertIn("X-IM-V2-Account-Edge-Authorization", config)
            self.assertEqual((root / "Caddyfile").stat().st_mode & 0o777, 0o600)
            self.assertEqual(original["services"]["account"]["environment"]["IM_V2_ACCOUNT_CLIENT_RATE_LIMIT_MAX_REQUESTS"], "240")

    def test_owner_fault_functional_cli_cannot_be_assessed_as_formal(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, release, fixture, loader = (root / name for name in
                                                ("source", "release", "fixture", "loader"))
            for directory in (source, release, fixture, loader):
                directory.mkdir()
            build = root / "build-result.json"
            loader_build = root / "loader-result.json"
            freeze = root / "freeze.json"
            for path in (build, loader_build, freeze):
                path.write_text("{}\n")
            base = [str(RUNNER), "--source-checkout", str(source), "--source-sha", "a" * 40,
                    "--release-dir", str(release), "--build-result", str(build),
                    "--loader-products-dir", str(loader), "--loader-build-result", str(loader_build),
                    "--fixture-dir", str(fixture), "--layout", "mixed",
                    "--docker-context", "test-isolated", "--artifact-dir", str(root / "evidence")]

            def parsed(extra: list[str], *, layout: str = "mixed", separate_loader: bool = True):
                command = base.copy()
                command[command.index("--layout") + 1] = layout
                if not separate_loader:
                    offset = command.index("--loader-products-dir")
                    del command[offset:offset + 4]
                with patch.object(sys, "argv", command + extra), redirect_stderr(io.StringIO()):
                    return parse_args()

            functional = parsed(["--functional-owner-fault"])
            self.assertEqual(functional.measurement_workload, "fault")
            self.assertEqual(functional.measurement_connections, 100)
            self.assertIsNone(functional.measurement_freeze_file)
            self.assertEqual(result_mode(functional, {}), "owner-fault-functional")
            self.assertFalse(formal_sampling_eligible(
                functional, {}, {"matchesFormal4CPU16GiB": True}))
            for extra in (["--canary-recovery"], ["--canary-connections", "100"],
                          ["--measurement-workload", "fault"], ["--measurement-connections", "100"],
                          ["--measurement-rate-scale", "0.5"],
                          ["--measurement-freeze-file", str(freeze)], ["--legacy-loader-net-admin"]):
                with self.subTest(extra=extra), self.assertRaises(SystemExit):
                    parsed(["--functional-owner-fault", *extra])
            for layout, separate_loader in (("hot", True), ("mixed", False)):
                with self.subTest(layout=layout, separate_loader=separate_loader), self.assertRaises(SystemExit):
                    parsed(["--functional-owner-fault"], layout=layout, separate_loader=separate_loader)

            with self.assertRaises(SystemExit):
                parsed(["--measurement-workload", "fault", "--measurement-connections", "100"])
            formal = parsed(["--measurement-workload", "fault", "--measurement-connections", "100",
                             "--measurement-main-revision", "1" * 40,
                             "--measurement-freeze-file", str(freeze)])
            self.assertEqual(result_mode(formal, {}), "measurement")
            self.assertTrue(formal_sampling_eligible(
                formal, {}, {"matchesFormal4CPU16GiB": True}))

            run = root / "functional-run"
            run.mkdir()
            steady = run / "measurement-steady.json"
            steady.write_text("{}\n")
            result = {"passed": True, "mode": "owner-fault-functional",
                      "formalSamplingEligible": False,
                      "measurement": {"phaseFiles": {"steady": hashlib.sha256(
                          steady.read_bytes()).hexdigest()}}}
            (run / "result.json").write_text(json.dumps(result))
            with self.assertRaises(MeasurementFailure):
                read_run(run)

    def test_capacity_nofile_configuration_does_not_change_postgres(self) -> None:
        postgres = {"image": "postgres:16-alpine", "ulimits": {"nofile": {"soft": 1024, "hard": 2048}}}
        services = {"postgres": postgres.copy(), "gateway": {"image": "swift",
                    "ulimits": {"nproc": 4096}},
                    "loader": {"image": "swift"}}
        set_capacity_open_file_limits(services)
        expected = {"soft": CAPACITY_NOFILE, "hard": CAPACITY_NOFILE}
        self.assertEqual(services["gateway"]["ulimits"]["nofile"], expected)
        self.assertEqual(services["loader"]["ulimits"]["nofile"], expected)
        self.assertEqual(services["gateway"]["ulimits"]["nproc"], 4096)
        self.assertEqual(services["postgres"], postgres)
        services["gateway"]["environment"] = {"PASSWORD": "must-not-appear"}
        listed = measurement_service_settings(services)
        self.assertEqual(listed["gateway"]["nofile"], expected)
        self.assertEqual(listed["loader"]["nofile"], expected)
        self.assertEqual(listed["postgres"]["nofile"], postgres["ulimits"]["nofile"])
        self.assertNotIn("environment", listed["gateway"])

    def test_pid1_nofile_evidence_and_fail_closed_loader_cleanup(self) -> None:
        row = "Max open files            65536                65536                files"
        self.assertEqual(parse_pid1_open_file_limits("Limit Soft Limit Hard Limit Units\n" + row + "\n")["soft"],
                         CAPACITY_NOFILE)
        with self.assertRaises(CanaryFailure):
            parse_pid1_open_file_limits("Limit Soft Limit Hard Limit Units\n")
        with self.assertRaises(CanaryFailure):
            parse_pid1_open_file_limits(row + "\n" + row + "\n")
        with self.assertRaises(CanaryFailure):
            parse_pid1_open_file_limits("Max open files unlimited unlimited files\n")
        with tempfile.TemporaryDirectory() as temporary:
            run = Path(temporary)
            commands = []
            def execute(command, log, timeout, record_stdout=True):
                commands.append(command)
                return row + "\n"
            gateway_id = "b" * 64
            evidence_hash = capture_pid1_open_file_limits(run=run, service="gateway",
                container_id=gateway_id,
                command=["docker", "exec", gateway_id], execute=execute)
            self.assertEqual(commands, [["docker", "exec", gateway_id, "cat", "/proc/1/limits"]])
            evidence = run / "gateway-open-file-limits.json"
            self.assertEqual(hashlib.sha256(evidence.read_bytes()).hexdigest(), evidence_hash)
            self.assertEqual(evidence.stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(evidence.read_text())["hard"], CAPACITY_NOFILE)
            self.assertEqual(json.loads(evidence.read_text())["containerID"], gateway_id)
            loader = "a" * 64
            for bad_output in ("Max open files 1024 65536 files\n", "no limit row\n"):
                commands.clear()
                def failing_execute(command, log, timeout, record_stdout=True):
                    commands.append(command)
                    return bad_output
                with self.assertRaises(CanaryFailure):
                    capture_detached_loader_open_file_limits(run=run, docker=["docker"],
                        loader_id=loader, execute=failing_execute)
                self.assertEqual(commands[-2], ["docker", "logs", loader])
                self.assertEqual(commands[-1], ["docker", "rm", "-f", loader])
            self.assertEqual(json.loads((run / "loader-open-file-limits.json").read_text())["soft"], 1024)
            self.assertEqual((run / "loader-open-file-limits.json").stat().st_mode & 0o777, 0o600)
            commands.clear()
            def failed_exec_and_cleanup(command, log, timeout, record_stdout=True):
                commands.append(command)
                if "exec" in command:
                    raise subprocess.CalledProcessError(1, command)
                raise CanaryFailure("cleanup unavailable")
            with self.assertRaises(subprocess.CalledProcessError):
                capture_detached_loader_open_file_limits(run=run, docker=["docker"],
                    loader_id=loader, execute=failed_exec_and_cleanup)
            self.assertEqual(commands[-2], ["docker", "logs", loader])
            self.assertEqual(commands[-1], ["docker", "rm", "-f", loader])

    def test_failure_artifacts_are_private_bounded_and_not_complete_phases(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            run = Path(temporary)
            commands = []
            def invoke(command, **kwargs):
                commands.append(command)
                if "ps" in command:
                    return subprocess.CompletedProcess(command, 0, stdout=json.dumps({
                        "Service": "gateway", "ID": "a" * 64, "State": "running",
                        "Health": "healthy", "ExitCode": 0,
                        "Command": "must-not-appear"}) + "\n" + json.dumps({
                        "Service": "unrelated", "ID": "b" * 64}) + "\n", stderr="")
                return subprocess.CompletedProcess(command, 0,
                    stdout="gateway | admission queue full\n"
                           "gateway | accessToken=must-not-appear\n"
                           "gateway | postgres://must-not-appear\n", stderr="")
            evidence = capture_project_diagnostics(compose=["docker", "compose", "-p", "private"],
                service_names=["gateway"], run=run, environment={}, invoke=invoke)
            self.assertTrue(evidence["statusAvailable"])
            self.assertEqual(len(json.loads((run / "services-status.json").read_text())["containers"]), 1)
            self.assertEqual((run / "services-tail.log").read_text(), "gateway | admission queue full\n")
            self.assertTrue(all((run / name).stat().st_mode & 0o777 == 0o600 for name in
                                ("services-status.json", "services-tail.log")))
            self.assertTrue(all(command[:4] == ["docker", "compose", "-p", "private"]
                                for command in commands))
            preserve_incomplete_measurement(run=run, current="warmup",
                expected=["steady", "cooldown"], boundaries={"warmup": {"sample": 1}},
                observations=[{"phase": "warmup", "sample": 2}], scenario_detail={"workload": "hot"})
            incomplete = json.loads((run / "measurement-incomplete-snapshots.json").read_text())
            self.assertFalse(incomplete["complete"])
            self.assertEqual(incomplete["failureStage"], "warmup")
            self.assertEqual(set(incomplete["boundaries"]), {"warmup"})
            self.assertEqual(incomplete["expectedPhaseMarkersRemaining"], ["steady", "cooldown"])

    def test_runtime_provenance_reads_only_project_and_setting_whitelists(self) -> None:
        container = "a" * 64
        calls = []
        def execute(command, log, timeout, record_stdout=False):
            calls.append(command)
            if "info" in command:
                return '{"nCPU":4,"memTotal":17179869184,"kernelVersion":"test-kernel"}'
            if "cat" in command:
                return "22f741c0-6ebe-4e35-9bc3-23e3c2c3b89a\n"
            if "ps" in command:
                return container + "\n"
            if "inspect" in command:
                return "2026-09-24T00:00:00Z\n"
            raise AssertionError(command)
        def psql(service, database, sql, **kwargs):
            self.assertIn("FROM pg_settings", sql)
            return json.dumps({name: "on" for name in (
                "max_connections", "shared_buffers", "work_mem", "synchronous_commit",
                "fsync", "full_page_writes", "statement_timeout", "lock_timeout",
                "track_io_timing", "shared_preload_libraries", "pg_stat_statements.track")})
        manifest = {"users": 100, "targetsPerConnection": 2, "owners": 2,
                    "layouts": {"mixed": {"rooms": 4, "ownerRoomCounts": [2, 2],
                                          "ownerMembershipCounts": [100, 100]}}}
        result = capture_runtime_provenance(docker=["docker"], compose=["docker", "compose"],
                    services={"postgres": "control", "owner00": "owner"}, manifest=manifest,
                    layout="mixed", execute=execute, psql=psql)
        self.assertTrue(result["machineEnvelope"]["matchesFormal4CPU16GiB"])
        self.assertEqual(set(result["projectContainers"]), {"postgres", "owner00", "gateway"})
        self.assertEqual(result["fixtureCounts"]["users"], 100)
        self.assertTrue(all("credentials" not in " ".join(call).lower() for call in calls))

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
            for name in ("IMV2ServerApp", "IMV2AccountServerApp", "IMV2PlacementControlApp", "IMV2GatewayLoadGenerator"):
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
            (release / "IMV2PlacementControlApp").write_bytes(b"\x7fELFstale-control")
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            (release / "IMV2PlacementControlApp").write_bytes(b"\x7fELFIMV2PlacementControlApp")
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
            recovery_fixture = root / "recovery-fixture"
            subprocess.run([sys.executable, str(PREPARE), "--output-dir", str(recovery_fixture),
                            "--seed", "22f741c0-6ebe-4e35-9bc3-23e3c2c3b89a",
                            "--users", "100", "--targets", "2", "--owners", "2",
                            "--command-window-limit", "1000",
                            "--expires-at", "2030-01-01T00:00:00Z"],
                           check=True, capture_output=True)
            corrected_binary.write_bytes(b"\x7fELFroom_sync_state_batches_per_second=" +
                                         b"room_latest_visible_batches_per_second=")
            corrected_document = json.loads(corrected_result.read_text())
            corrected_document["products"]["IMV2GatewayLoadGenerator"] = hashlib.sha256(
                corrected_binary.read_bytes()).hexdigest()
            corrected_result.write_text(json.dumps(corrected_document))
            recovery_command = [value if value != str(fixture) else str(recovery_fixture)
                                for value in with_corrected]
            recovery_command = ["mixed" if value == "hot" else value for value in recovery_command]
            recovery_command += ["--canary-connections", "100", "--canary-recovery"]
            recovery = subprocess.run(recovery_command, capture_output=True, text=True)
            self.assertEqual(recovery.returncode, 0, recovery.stderr)
            self.assertIn("VA_CAPACITY_RECOVERY_CANARY_PREFLIGHT_OK", recovery.stdout)
            self.assertNotEqual(subprocess.run(recovery_command[:-3] +
                                ["--canary-connections", "99", "--canary-recovery"],
                                capture_output=True).returncode, 0)
            corrected_binary.write_bytes(b"\x7fELFstale-loader")
            self.assertNotEqual(subprocess.run(with_corrected, capture_output=True).returncode, 0)
            (fixture / "hot/credentials.jsonl").write_text("{}\n")
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            (source / "IMV2/sql/schema.sql").write_text("-- changed\n")
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)


if __name__ == "__main__":
    unittest.main()
