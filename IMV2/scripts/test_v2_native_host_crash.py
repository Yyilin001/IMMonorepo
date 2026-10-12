#!/usr/bin/env python3
"""Actual owned Docker exclusion, supervisor restart and unknown-send replay.

Runs only against an explicitly supplied disposable Docker context and frozen
Linux products. Never pauses, restarts or removes the developer's services.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import time
import uuid

from v2_native_placement_inspection import decode_placement_inspection, room_placement, require_live_owner, same_owner

IMAGE = "swift:6.4-jammy@sha256:a6053d2de72091906bfa064f76f145e3f28830664cae250e1b84aa8c499a8ee6"
ROOM = "00000000-0000-0000-0000-000000000011"
PRODUCTS = ("VirtualActorBusinessProbe", "IMV2PlacementControlApp", "IMV2RoomHostSupervisorApp")
VOTERS = ("placement-a", "placement-b", "placement-c")


def source_digest(root: Path) -> str:
    digest = hashlib.sha256()
    for package in ("IMV2", "IMV2Compression", "IMV2Core", "IMV2Server"):
        for path in sorted((root / package).rglob("*")):
            relative = path.relative_to(root)
            if any(part in (".git", ".build", ".swiftpm", "__pycache__") for part in relative.parts) or not path.is_file():
                continue
            name = str(relative).encode(); content = path.read_bytes()
            digest.update(len(name).to_bytes(8, "big")); digest.update(name)
            digest.update(len(content).to_bytes(8, "big")); digest.update(content)
    return digest.hexdigest()


def recovery_operation(path: Path, incarnation: str) -> tuple[str, bool]:
    """Inspect the actual small PB journal; do not derive an ID from observations."""
    def fields(data):
        cursor = 0
        def varint():
            nonlocal cursor
            value = 0
            for shift in range(0, 70, 7):
                byte = data[cursor]; cursor += 1; value |= (byte & 127) << shift
                if byte < 128:
                    return value
            raise ValueError("invalid journal varint")
        result = {}
        while cursor < len(data):
            key = varint(); wire = key & 7
            if wire == 0:
                value = varint()
            elif wire == 2:
                length = varint(); value = data[cursor:cursor + length]; cursor += length
                if len(value) != length:
                    raise ValueError("truncated journal")
            else:
                raise ValueError("unexpected journal field")
            result.setdefault(key >> 3, []).append(value)
        return result
    data = path.read_bytes()
    if not 0 < len(data) <= 128 * 1024:
        raise ValueError("invalid journal size")
    envelope = fields(data); journal = envelope[1][0]
    if hashlib.sha256(journal).digest() != envelope[2][0]:
        raise ValueError("journal digest mismatch")
    for record in fields(journal).get(4, []):
        operation = fields(record)
        if operation[2][0] == uuid.UUID(incarnation).bytes:
            return str(uuid.UUID(bytes=operation[3][0])), bool(operation.get(4, [0])[0])
    raise ValueError("expected recovery operation missing")


class CrashProbe:
    def __init__(self, args):
        self.args = args
        self.output = args.artifact_dir.resolve()
        self.output.mkdir(parents=True, exist_ok=False, mode=0o700)
        self.private = self.output / "private"
        self.evidence = self.output / "evidence"; self.evidence.mkdir(mode=0o700)
        self.prefix = "imv2-native-crash-" + uuid.uuid4().hex[:12]
        self.network = self.prefix + "-network"
        self.owned = []
        self.stage = "prepare"
        self.result = {"passed": False, "crashTakeoverVerified": False, "run": self.prefix}

    def docker(self, *args, timeout=30, check=True, data=None):
        return subprocess.run(["docker", "--context", self.args.docker_context, *args], input=data,
            capture_output=True, timeout=timeout, check=check)

    def name(self, node):
        return self.prefix + "-" + node

    def state(self, container):
        return json.loads(self.docker("inspect", container).stdout)[0]["State"]

    def wait(self, check, seconds=90):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            value = check()
            if value:
                return value
            time.sleep(0.1)
        raise TimeoutError(self.stage)

    def create(self, node, command, environment, mounts, *, start=True, alias=None):
        container = self.name(node); self.owned.append(container)
        flags = ["create", "--name", container, "--network", self.network, "--network-alias", alias or node,
                 "--restart", "no", "--memory", "1g"]
        for key, value in environment.items():
            flags += ["-e", key + "=" + value]
        for mount in mounts:
            flags += ["-v", mount]
        self.docker(*flags, IMAGE, *command)
        if start:
            self.docker("start", container)
        return container

    def run_once(self, node, command, environment, mounts):
        container = self.create(node, command, environment, mounts, start=False)
        output = self.docker("start", "--attach", container, timeout=60, check=False)
        (self.output / (node + ".log")).write_bytes(output.stdout + output.stderr)
        state = self.state(container)
        if output.returncode or state["Running"] or state["ExitCode"]:
            raise RuntimeError("owned command failed: " + node)

    def query(self, sql):
        return self.docker("exec", self.name("postgres"), "psql", "-XAt", "-v", "ON_ERROR_STOP=1",
            "-U", "probe", "-d", "probe", "-c", sql).stdout.decode().strip()

    def inspect(self):
        node = "inspect-" + uuid.uuid4().hex[:8]
        container = self.create(node, ["/products/IMV2PlacementControlApp", "--inspect"],
            {"IMV2_ROOM_ACTOR_CONFIGURATION_FILE": "/secrets/configuration.json", "IMV2_PLACEMENT_SHARD_IDS": "room-a"},
            [str(self.args.release_dir.resolve()) + ":/products:ro", str(self.private / "inspector") + ":/secrets:ro"], start=False, alias="inspector")
        output = self.docker("start", "--attach", container, timeout=45)
        if self.state(container)["ExitCode"]:
            raise RuntimeError("fresh quorum inspection failed")
        return decode_placement_inspection(output.stdout)

    def supervisor(self, node, argument=None):
        command = ["/products/IMV2RoomHostSupervisorApp"] + ([argument] if argument else [])
        environment = {"IMV2_HOST_SUPERVISOR_CONFIGURATION_FILE": str(self.output / "supervisor.json")}
        mounts = [str(self.output) + ":" + str(self.output), str(self.private / "supervisor") + ":/secrets:ro",
                  str(self.args.release_dir.resolve()) + ":/products:ro", "/var/run/docker.sock:/var/run/docker.sock"]
        if argument:
            self.run_once(node, command, environment, mounts)
            return self.name(node)
        return self.create(node, command, environment, mounts, alias="supervisor")

    def execute(self):
        metadata = json.loads(self.args.build_result.read_text())
        if not metadata.get("passed") or metadata.get("image") != IMAGE:
            raise RuntimeError("successful frozen Linux build required")
        if metadata.get("sourceDigest") != source_digest(self.args.source_dir):
            raise RuntimeError("frozen source differs from build evidence")
        for product in PRODUCTS:
            digest = hashlib.sha256((self.args.release_dir / product).read_bytes()).hexdigest()
            if metadata.get("products", {}).get(product) != digest:
                raise RuntimeError("product differs from build evidence")
        self.result.update(productsSHA256=metadata["products"], sourceDigest=metadata["sourceDigest"], image=IMAGE)
        self.docker("network", "create", self.network)
        config = [sys.executable, str(self.args.source_dir / "IMV2/scripts/prepare_v2_room_actor_configuration.py"),
            "--output-dir", str(self.private), "--host", "host-a=host-a:7337", "--host", "host-b=host-b:7337",
            "--caller", "client=client:7337", "--caller", "inspector=inspector:7337", "--caller", "supervisor=supervisor:7337",
            "--exclusion-supervisor", "supervisor", "--shards", "room-a", "--user-buckets", "g4-users", "--mount-root", "/secrets"]
        for voter in VOTERS:
            config += ["--placement-voter", voter + "=" + voter + ":7336"]
        subprocess.run(config, check=True, capture_output=True, timeout=30)
        for path in self.private.glob("*/configuration.json"):
            document = json.loads(path.read_text()); document.pop("policyPlacement", None)
            path.write_text(json.dumps(document)); path.chmod(0o600)
        topology = json.loads((self.private / "topology.json").read_text())
        self.owned.append(self.name("postgres"))
        self.docker("create", "--name", self.name("postgres"), "--network", self.network, "--network-alias", "postgres",
            "-e", "POSTGRES_USER=probe", "-e", "POSTGRES_PASSWORD=probe", "-e", "POSTGRES_DB=probe", "postgres:16-alpine", timeout=60)
        self.docker("start", self.name("postgres"))
        self.wait(lambda: self.docker("exec", self.name("postgres"), "psql", "-h", "127.0.0.1", "-U", "probe", "-d", "probe",
            "-Atc", "SELECT 1", check=False).stdout.strip() == b"1", seconds=45)
        for sql in ("IMV2/sql/schema.sql", "IMV2/scripts/native_actor_business_fixture.sql"):
            self.docker("exec", "-i", self.name("postgres"), "psql", "-X", "-v", "ON_ERROR_STOP=1", "-U", "probe", "-d", "probe",
                data=(self.args.source_dir / sql).read_bytes(), timeout=60)
        products = str(self.args.release_dir.resolve()) + ":/products:ro"
        for voter in VOTERS:
            environment = {"IMV2_ROOM_ACTOR_CONFIGURATION_FILE": "/secrets/configuration.json", "IMV2_PLACEMENT_SHARD_IDS": "room-a"}
            mounts = [products, str(self.private / voter) + ":/secrets:ro", str(self.private / voter / "placement") + ":/secrets/placement"]
            self.run_once(voter + "-provision", ["/products/IMV2PlacementControlApp", "--provision"], environment, mounts)
            self.create(voter, ["/products/IMV2PlacementControlApp"], environment, mounts)
        self.stage = "initial quorum"
        for voter in VOTERS:
            self.wait(lambda voter=voter: self.docker("exec", self.name(voter), "bash", "-c", ": > /dev/tcp/" + voter + "/7336", check=False).returncode == 0, seconds=30)
        genesis = room_placement(self.inspect(), ROOM, "room-a")
        failed_node = next(name for name in ("host-a", "host-b") if topology["hostIDs"][name].lower() == genesis["hostID"].lower())
        healthy_node = "host-b" if failed_node == "host-a" else "host-a"
        daemon = self.docker("info", "--format", "{{.ID}}").stdout.decode().strip()
        launches = []
        for node in (healthy_node, failed_node):
            gate = self.output / (node + "-gate")
            template = {"Image": IMAGE, "Cmd": ["/products/VirtualActorBusinessProbe", "host-crash-after-commit" if node == failed_node else "host"],
                "Env": ["IMV2_ROOM_ACTOR_CONFIGURATION_FILE=/secrets/configuration.json", "VA_G4_DATABASE_URL=postgres://probe:probe@postgres:5432/probe?sslmode=disable",
                        "VA_G4_EVIDENCE_DIR=/evidence", "VA_G4_HOST_MARKER_PREFIX=" + node], "Labels": {},
                "HostConfig": {"RestartPolicy": {"Name": "no"}, "Privileged": False, "PidMode": "", "AutoRemove": False, "NetworkMode": self.network,
                    "Mounts": [{"Type": "bind", "Source": str(source), "Target": target, "ReadOnly": readonly} for source, target, readonly in
                        [(self.args.release_dir.resolve(), "/products", True), (self.private / node, "/secrets", True),
                         (self.evidence, "/evidence", False), (gate, "/imv2-startup", False)]]},
                "NetworkingConfig": {"EndpointsConfig": {self.network: {"Aliases": [node]}}}}
            path = self.output / (node + "-template.json"); path.write_text(json.dumps(template))
            launches.append({"hostID": topology["hostIDs"][node], "serviceID": node, "gateDirectory": str(gate),
                "journalPath": str(self.output / (node + "-launch.pb")), "inventoryPath": str(self.output / (node + "-inventory.pb")), "createTemplatePath": str(path)})
        document = {"actorConfigurationFile": str(self.private / "supervisor/configuration.json"), "shardIDs": ["room-a"],
            "daemonID": daemon, "socketPath": "/var/run/docker.sock", "recoveryJournalPath": str(self.output / "recovery.pb"),
            "launches": launches, "retiredLaunches": [], "databases": {"owner": "postgres://probe:probe@postgres:5432/probe?sslmode=disable"}, "shardDatabaseTargets": {"room-a": "owner"}}
        (self.output / "supervisor.json").write_text(json.dumps(document))
        self.supervisor("supervisor-provision", "--provision")
        supervisor = self.supervisor("supervisor")
        self.stage = "supervised Hosts ready"
        def hosts_ready():
            if not self.state(supervisor)["Running"]:
                raise RuntimeError("supervisor exited before Hosts became ready")
            return all((self.evidence / (node + "-ready")).is_file() for node in ("host-a", "host-b"))
        self.wait(hosts_ready)
        before = room_placement(self.inspect(), ROOM, "room-a"); require_live_owner(before, topology["hostIDs"][failed_node])
        self.result["placementBefore"] = before
        def host_container(node):
            return self.docker("ps", "-aq", "--filter", "label=com.imv2.actor.host-id=" + str(uuid.UUID(topology["hostIDs"][node])).upper()).stdout.decode().strip()
        failed_container = host_container(failed_node); healthy_container = host_container(healthy_node)
        if not failed_container or not healthy_container or failed_container == healthy_container:
            raise RuntimeError("owned supervised instance bindings missing")
        healthy_started = self.state(healthy_container)["StartedAt"]
        self.stage = "network loss does not authorize takeover"
        original_started = self.state(failed_container)["StartedAt"]
        original_ip = json.loads(self.docker("inspect", failed_container).stdout)[0]["NetworkSettings"]["Networks"][self.network]["IPAddress"]
        journal_before = (self.output / "recovery.pb").read_bytes()
        self.docker("network", "disconnect", self.network, failed_container)
        # The concrete monitor remains running through this short partition.
        # Three real quorum reads observe the original owner, not a new grant.
        for _ in range(3):
            partitioned = room_placement(self.inspect(), ROOM, "room-a")
            if not same_owner(before, partitioned) or partitioned["hostRetired"] or partitioned["retired"]:
                raise RuntimeError("network loss advanced ownership")
            time.sleep(1)
        if (self.output / "recovery.pb").read_bytes() != journal_before or not self.state(failed_container)["Running"]:
            raise RuntimeError("network loss was treated as process exclusion")
        self.docker("network", "connect", "--ip", original_ip, "--alias", failed_node, self.network, failed_container)
        if self.state(failed_container)["StartedAt"] != original_started:
            raise RuntimeError("partitioned Host restarted")
        self.result["networkLossDidNotGrantOwnership"] = True
        client = self.create("client", ["/products/VirtualActorBusinessProbe", "client-crash-replay"],
            {"IMV2_ROOM_ACTOR_CONFIGURATION_FILE": "/secrets/configuration.json", "VA_G4_DATABASE_URL": "postgres://probe:probe@postgres:5432/probe?sslmode=disable",
             "VA_G4_EVIDENCE_DIR": "/evidence", "VA_G4_STALE_CALLER_PORT": "7341"},
            [products, str(self.private / "client") + ":/secrets:ro", str(self.evidence) + ":/evidence"])
        self.wait(lambda: (self.evidence / "crash-client-ready").is_file())
        self.docker("kill", "--signal=STOP", supervisor)
        self.wait(lambda: b"State:\tT" in self.docker("exec", supervisor, "cat", "/proc/1/status").stdout, seconds=10)
        (self.evidence / "crash-send").touch(mode=0o600)
        self.stage = "committed send without ACK"
        self.wait(lambda: (self.evidence / "crash-unknown").is_file(), seconds=20)
        if self.state(failed_container)["Running"] or self.state(failed_container)["ExitCode"] != 137:
            raise RuntimeError("Host did not physically crash after commit")
        if self.query("SELECT count(*) FROM im_v2.messages") != "1" or self.query("SELECT count(*) FROM im_v2.message_send_completions") != "1":
            raise RuntimeError("unknown send is not durably complete")
        self.result["unknownSendDurable"] = True
        committed = json.loads((self.evidence / "crash-committed-token.json").read_text())
        if committed["host"]["incarnationID"].lower() != before["incarnationID"].lower():
            raise RuntimeError("commit came from a different incarnation")
        self.docker("pause", self.name("postgres"))
        self.docker("kill", "--signal=CONT", supervisor)
        self.stage = "irreversible exclusion before database settlement"
        self.wait(lambda: self.docker("inspect", failed_container, check=False).returncode != 0, seconds=40)
        operation, completed = recovery_operation(self.output / "recovery.pb", before["incarnationID"])
        if completed:
            raise RuntimeError("recovery completed while PostgreSQL was paused")
        self.result["recoveryOperationID"] = operation
        pending = room_placement(self.inspect(), ROOM, "room-a")
        if pending["hostRetired"] or pending["incarnationID"] != before["incarnationID"]:
            raise RuntimeError("ownership advanced without database settlement")
        self.result["placementPending"] = pending
        self.docker("kill", "--signal=KILL", supervisor)
        self.wait(lambda: not self.state(supervisor)["Running"], seconds=10)
        self.docker("unpause", self.name("postgres"))
        supervisor = self.supervisor("supervisor-resumed")
        self.stage = "restart resumes durable recovery"
        def recovered():
            if not self.state(supervisor)["Running"]:
                raise RuntimeError("resumed supervisor exited before recovery")
            return recovery_operation(self.output / "recovery.pb", before["incarnationID"])[1]
        # Poll the owned durable completion instead of repeatedly creating and
        # shutting down cluster callers while recovery is in flight. Independently
        # confirm the committed quorum state once recovery reports completion.
        self.wait(recovered, seconds=60)
        after = room_placement(self.inspect(), ROOM, "room-a")
        if after["hostID"].lower() != topology["hostIDs"][healthy_node].lower() or after["retired"] or after["epoch"] <= before["epoch"]:
            raise RuntimeError("completed recovery did not transfer ownership")
        resumed, completed = recovery_operation(self.output / "recovery.pb", before["incarnationID"])
        if resumed != operation or not completed:
            raise RuntimeError("restart replaced the durable recovery identity")
        if self.query("SELECT count(*) FROM pg_stat_activity WHERE application_name = 'imva:" + before["incarnationID"].replace("-", "").lower() + "'") != "0":
            raise RuntimeError("old incarnation still has database sessions")
        (self.evidence / "crash-recover").touch(mode=0o600)
        self.stage = "same caller replays unknown send"
        self.wait(lambda: (self.evidence / "crash-result.json").is_file(), seconds=60)
        self.wait(lambda: not self.state(client)["Running"], seconds=40)
        business = json.loads((self.evidence / "crash-result.json").read_text())
        if self.state(client)["ExitCode"] or business["messageRows"] != 1 or not business["originalResultUnknown"]:
            raise RuntimeError("business replay failed")
        if not self.state(healthy_container)["Running"] or self.state(healthy_container)["StartedAt"] != healthy_started:
            raise RuntimeError("healthy Host restarted during recovery")
        self.stage = "replace supervised Host generation"
        self.docker("kill", "--signal=TERM", supervisor)
        self.wait(lambda: not self.state(supervisor)["Running"], seconds=40)
        if self.state(supervisor)["ExitCode"] != 0:
            raise RuntimeError("supervisor did not drain control and durable resources")
        if not self.state(healthy_container)["Running"]:
            raise RuntimeError("supervisor shutdown stopped an owned Host")
        old_launch = next(item for item in launches if item["serviceID"] == healthy_node)
        new_gate = self.output / (healthy_node + "-replacement-gate")
        template = json.loads(Path(old_launch["createTemplatePath"]).read_text())
        template["Env"] = [value for value in template["Env"] if not value.startswith("VA_G4_HOST_MARKER_PREFIX=")]
        template["Env"].append("VA_G4_HOST_MARKER_PREFIX=" + healthy_node + "-replacement")
        for mount in template["HostConfig"]["Mounts"]:
            if mount["Target"] == "/imv2-startup":
                mount["Source"] = str(new_gate)
        new_template = self.output / (healthy_node + "-replacement-template.json")
        new_template.write_text(json.dumps(template))
        document["launches"].append(dict(old_launch, gateDirectory=str(new_gate),
            journalPath=str(self.output / (healthy_node + "-replacement-launch.pb")),
            inventoryPath=str(self.output / (healthy_node + "-replacement-inventory.pb")), createTemplatePath=str(new_template)))
        (self.output / "supervisor.json").write_text(json.dumps(document))
        self.supervisor("supervisor-append", "--provision-launches")
        supervisor = self.supervisor("supervisor-replaced")
        def replacement_ready():
            if not self.state(supervisor)["Running"]:
                raise RuntimeError("supervisor exited during generation replacement")
            return (self.evidence / (healthy_node + "-replacement-ready")).is_file()
        self.wait(replacement_ready, seconds=90)
        self.wait(lambda: recovery_operation(self.output / "recovery.pb", after["incarnationID"])[1], seconds=60)
        replaced = room_placement(self.inspect(), ROOM, "room-a")
        if replaced["hostID"] != after["hostID"] or replaced["incarnationID"] == after["incarnationID"] or replaced["epoch"] <= after["epoch"] or replaced["retired"]:
            raise RuntimeError("replacement did not register a fresh incarnation and epoch")
        if self.docker("inspect", healthy_container, check=False).returncode == 0:
            raise RuntimeError("replacement left its predecessor container")
        self.stage = "verify old generation metadata reclamation"
        def generation_reclaimed():
            retained = json.loads((self.output / "supervisor.json").read_text())
            return (not retained["retiredLaunches"] and old_launch not in retained["launches"]
                    and len(retained["launches"]) == len(launches) - 1
                    and not Path(old_launch["journalPath"]).exists()
                    and not Path(old_launch["inventoryPath"]).exists()
                    and not Path(old_launch["gateDirectory"]).exists())
        self.wait(generation_reclaimed, seconds=60)
        self.result.update(generationReplacementVerified=True, generationRetentionVerified=True, placementReplaced=replaced)
        self.result.update(passed=True, crashTakeoverVerified=True, placementBefore=before, placementPending=pending,
            placementAfter=after, recoveryOperationID=operation, supervisorRestartResumed=True, business=business)

    def cleanup(self):
        errors = []
        if self.docker("info", check=False).returncode:
            raise RuntimeError("cannot confirm cleanup while Docker daemon is unavailable")
        # Dynamic Host names are owned by the unique network. Record/remove
        # them even when create returned an unknown result before local tracking.
        listing = self.docker("ps", "-aq", "--filter", "network=" + self.network, check=False)
        containers = list(dict.fromkeys(self.owned + listing.stdout.decode().split()))
        for container in containers:
            self.docker("unpause", container, check=False)
            logs = self.docker("logs", "--tail", "300", container, check=False)
            if logs.returncode == 0:
                (self.output / (container + ".log")).write_bytes(logs.stdout + logs.stderr)
            self.docker("rm", "-f", "-v", container, check=False)
            if self.docker("inspect", container, check=False).returncode == 0:
                errors.append("container remains: " + container)
        self.docker("network", "rm", self.network, check=False)
        if self.docker("network", "inspect", self.network, check=False).returncode == 0:
            errors.append("owned network remains")
        shutil.rmtree(self.private, ignore_errors=True)
        for path in self.output.glob("*-gate"):
            shutil.rmtree(path, ignore_errors=True)
        for pattern in ("*.pb", "*.pb.lock", "*-template.json", "supervisor.json", "supervisor.json.lock"):
            for path in self.output.glob(pattern):
                path.unlink(missing_ok=True)
        self.result["cleanupErrors"] = errors
        self.result["resourcesRemoved"] = not errors and not self.private.exists()
        if errors:
            self.result["passed"] = False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--docker-context", required=True)
    parser.add_argument("--artifact-dir", type=Path, required=True)
    parser.add_argument("--source-dir", type=Path, required=True)
    parser.add_argument("--release-dir", type=Path, required=True)
    parser.add_argument("--build-result", type=Path, required=True)
    args = parser.parse_args()
    if not args.docker_context.startswith("colima-imv2-native-"):
        parser.error("requires a separately owned disposable native validation context")
    probe = CrashProbe(args)
    try:
        probe.execute()
    except Exception as error:
        probe.result.update(failureType=type(error).__name__, failedStage=probe.stage)
        if type(error) in (RuntimeError, TimeoutError, ValueError):
            # These are fixed local validation messages. Never stringify a
            # subprocess exception whose command may contain deployment URLs.
            probe.result["failureReason"] = str(error)[:300]
    finally:
        try:
            probe.cleanup()
        except Exception as error:
            probe.result.update(passed=False, resourcesRemoved=False, cleanupFailureType=type(error).__name__)
        (probe.output / "result.json").write_text(json.dumps(probe.result, indent=2) + "\n")
    print(json.dumps(probe.result, indent=2))
    return 0 if probe.result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
