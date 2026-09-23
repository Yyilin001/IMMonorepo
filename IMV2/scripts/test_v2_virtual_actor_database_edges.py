#!/usr/bin/env python3
"""Real two-Host/three-PostgreSQL DB-edge faults using an immutable Linux probe.

Each node/DB pair gets a private bridge. Disconnecting Host A from one bridge
cannot disconnect Host B or the caller. Only the affected SQL sessions are
terminated to make the severed link observable without waiting for TCP keepalive.
No database or Actor process is stopped during either fault.
"""
from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
IMAGE = "swift:6.4-jammy@sha256:a6053d2de72091906bfa064f76f145e3f28830664cae250e1b84aa8c499a8ee6"
NODES = ("host-a", "host-b", "client")
LINKS = {"host-a": ("control", "owner-a"), "host-b": ("control", "owner-b"),
         "client": ("control", "owner-a", "owner-b")}


def identifier(number: int) -> str:
    return f"00000000-0000-0000-0000-{number:012d}"


def run(args: list[str], *, data: bytes | None = None, timeout: int = 30,
        check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(args, input=data, capture_output=True, timeout=timeout, check=check)


class Probe:
    def __init__(self, args):
        self.args = args
        self.output = args.artifact_dir.resolve()
        self.output.mkdir(parents=True, exist_ok=False, mode=0o700)
        self.evidence = self.output / "evidence"
        self.evidence.mkdir(mode=0o700)
        self.prefix = "imv2-va-db-edge-" + uuid.uuid4().hex[:12]
        self.actor_network = self.prefix + "-actor"
        self.networks = {(node, db): self.prefix + "-" + node + "-" + db
                         for node, databases in LINKS.items() for db in databases}
        self.containers = {name: self.prefix + "-" + name for name in (*NODES, "control", "owner-a", "owner-b")}
        self.created_containers: list[str] = []
        self.created_networks: list[str] = []
        self.started: dict[str, str] = {}
        self.result = {"passed": False, "run": self.prefix, "faults": [],
                       "topology": {"hosts": 2, "callers": 1, "independentPostgreSQL": 3}}

    def docker(self, *args, **kwargs):
        return run(["docker", "--context", self.args.docker_context, *args], **kwargs)

    def save(self, name, value):
        path = self.output / name
        path.write_text(json.dumps(value, indent=2) + "\n")
        path.chmod(0o600)

    def inspect(self, name):
        return json.loads(self.docker("inspect", self.containers[name]).stdout)[0]

    def query(self, database, sql):
        return self.docker("exec", self.containers[database], "psql", "-XAt", "-v", "ON_ERROR_STOP=1",
                           "-U", "probe", "-d", "probe", "-c", sql).stdout.decode().strip()

    def mark(self, name):
        (self.evidence / name).write_text("ready\n")

    def wait(self, predicate, description, seconds=90, watched=NODES):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            value = predicate()
            if value:
                return value
            for name in watched:
                state = self.inspect(name)["State"]
                if not state["Running"]:
                    raise RuntimeError(f"{name} exited while waiting for {description}: {state['ExitCode']}")
            time.sleep(0.2)
        raise TimeoutError(description)

    def wait_file(self, name, seconds=90, watched=NODES):
        self.wait(lambda: (self.evidence / name).is_file(), name, seconds, watched)

    def same_processes(self):
        for name, started in self.started.items():
            state = self.inspect(name)["State"]
            if not state["Running"] or state["StartedAt"] != started:
                raise RuntimeError(f"{name} restarted or stopped during DB-edge fault")

    def prepare(self):
        metadata = json.loads(self.args.build_result.read_text())
        sha = run(["git", "-C", str(ROOT), "rev-parse", "HEAD"]).stdout.decode().strip()
        dirty = run(["git", "-C", str(ROOT), "status", "--porcelain", "--untracked-files=no"]).stdout
        binary = self.args.release_dir / "VirtualActorBusinessProbe"
        if dirty or not metadata.get("passed") or metadata.get("sourceSHA") != sha:
            raise RuntimeError("probe requires clean source matching successful build metadata")
        digest = hashlib.sha256(binary.read_bytes()).hexdigest()
        if metadata.get("products", {}).get(binary.name) != digest or metadata.get("image") != IMAGE:
            raise RuntimeError("probe product/image differs from build metadata")
        self.result.update(sourceSHA=sha, binarySHA256=digest, image=IMAGE)
        self.secrets = self.output / "private"
        run([sys.executable, str(ROOT / "IMV2/scripts/prepare_v2_room_actor_configuration.py"),
             "--output-dir", str(self.secrets), "--host", "host-a=host-a:7337", "--host", "host-b=host-b:7337",
             "--caller", "client=client:7337", "--shards", "room-a,room-b", "--mount-root", "/secrets"])
        for name in NODES:
            path = self.secrets / name / "configuration.json"
            document = json.loads(path.read_text())
            # Deterministic placement isolates the selected edge. The other Host
            # serves its own shard; this probe does not claim cross-shard takeover.
            for peer in document["peers"]:
                peer["shardIDs"] = ["room-" + peer["serviceID"][-1]]
            path.write_text(json.dumps(document, indent=2) + "\n")
        for network in [self.actor_network, *self.networks.values()]:
            self.docker("network", "create", network)
            self.created_networks.append(network)
        for database in ("control", "owner-a", "owner-b"):
            links = [network for (node, db), network in self.networks.items() if db == database]
            container = self.containers[database]
            self.docker("create", "--name", container, "--network", links[0], "--network-alias", "db-" + database,
                        "-e", "POSTGRES_USER=probe", "-e", "POSTGRES_PASSWORD=probe", "-e", "POSTGRES_DB=probe",
                        "postgres:16-alpine")
            self.created_containers.append(container)
            for network in links[1:]:
                self.docker("network", "connect", "--alias", "db-" + database, network, container)
            self.docker("start", container)
            self.wait(lambda: self.docker("exec", container, "pg_isready", "-U", "probe", check=False).returncode == 0,
                      database + " ready", seconds=45, watched=())
            install = self.docker("exec", "-i", container, "psql", "-X", "-v", "ON_ERROR_STOP=1", "-U", "probe",
                                 "-d", "probe", data=(ROOT / "IMV2/sql/schema.sql").read_bytes(), timeout=90)
            (self.output / (database + "-schema.log")).write_bytes(install.stdout + install.stderr)
            self.fixture(database)

    def fixture(self, database):
        user = identifier(12)
        statements = [f"""INSERT INTO im_v2.public_user_profiles
            (user_id, public_handle, display_name, revision, created_at, updated_at)
            VALUES ('{user}', 'db_edge_sender', 'DB edge sender', 1, clock_timestamp(), clock_timestamp());"""]
        if database == "control":
            for number, slot in ((1, "a"), (2, "b")):
                statements.append(f"""INSERT INTO im_v2.room_owner_routes
                    (room_id, room_shard_id, route_epoch, created_at, updated_at)
                    VALUES ('{identifier(10 + number)}', 'room-{slot}', 0, clock_timestamp(), clock_timestamp());""")
        else:
            slot = database[-1]
            number = 1 if slot == "a" else 2
            room, lease = identifier(10 + number), identifier(50 + number)
            statements.append(f"""
                INSERT INTO im_v2.rooms (room_id, room_shard_id, capacity_profile_id, capacity_class, membership_revision)
                    VALUES ('{room}', 'room-{slot}', 'standard', 'standard', 1);
                INSERT INTO im_v2.group_rooms (room_id, owner_user_id, title, created_at)
                    VALUES ('{room}', '{user}', 'DB edge room', clock_timestamp());
                INSERT INTO im_v2.room_memberships (room_id, user_id, role, joined_revision)
                    VALUES ('{room}', '{user}', 'owner', 1);
                INSERT INTO im_v2.shard_admission_pools
                    (room_shard_id, capacity_profile_id, lease_id, generation, valid_until, command_window_limit)
                    VALUES ('room-{slot}', 'standard', '{lease}', 1, clock_timestamp() + interval '1 hour', 1000);
                INSERT INTO im_v2.room_admission
                    (room_id, eligible_member_count, command_window_limit, shard_lease_id, shard_lease_generation)
                    VALUES ('{room}', 1, 1000, '{lease}', 1);
                INSERT INTO im_v2.user_shard_router_configuration
                    (configuration_key, router_epoch, default_write_bucket, updated_at)
                    VALUES (TRUE, 1, 'db-edge-users', clock_timestamp());
                """)
        self.query(database, "\n".join(statements))

    def start(self, name):
        args = ["create", "--name", self.containers[name], "--network", self.actor_network,
                "--network-alias", name, "--cpus", "1", "--memory", "1g",
                "-v", f"{self.args.release_dir.resolve()}:/products:ro",
                "-v", f"{self.secrets / name}:/secrets:ro", "-v", f"{self.evidence}:/evidence",
                "-e", "IMV2_ROOM_ACTOR_CONFIGURATION_FILE=/secrets/configuration.json",
                "-e", "VA_DB_EDGE_EVIDENCE=/evidence", "-e", f"VA_DB_EDGE_NODE={name}"]
        for database in LINKS[name]:
            key = "VA_DB_EDGE_" + database.upper().replace("-", "_") + "_URL"
            args += ["-e", f"{key}=postgres://probe:probe@db-{database}:5432/probe?sslmode=disable"]
        args += [IMAGE, "/products/VirtualActorBusinessProbe",
                 "database-edge-client" if name == "client" else "database-edge-host"]
        self.docker(*args)
        self.created_containers.append(self.containers[name])
        for database in LINKS[name]:
            self.docker("network", "connect", self.networks[name, database], self.containers[name])
        self.docker("start", self.containers[name])
        self.started[name] = self.inspect(name)["State"]["StartedAt"]

    def cut(self, database, phase):
        self.same_processes()
        before = self.inspect("host-a")["NetworkSettings"]["Networks"]
        network = self.networks["host-a", database]
        address = str(ipaddress.ip_address(before[network]["IPAddress"]))
        db_address = str(ipaddress.ip_address(self.inspect(database)["NetworkSettings"]["Networks"][network]["IPAddress"]))
        # Existing sessions must be observed before terminating just this Host's
        # severed link. No pg_terminate_backend call touches another caller.
        sessions = int(self.query(database, f"SELECT count(*) FROM pg_stat_activity WHERE client_addr = '{address}'::inet"))
        if sessions < 1:
            raise RuntimeError("target DB edge was never warmed")
        self.docker("network", "disconnect", network, self.containers["host-a"])
        terminated = self.query(database, f"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE client_addr = '{address}'::inet")
        after = self.inspect("host-a")["NetworkSettings"]["Networks"]
        if set(after) != set(before) - {network}:
            raise RuntimeError("fault removed an unintended network")
        tcp = self.docker("exec", self.containers["host-a"], "timeout", "3", "bash", "-c",
                          f"exec 3<>/dev/tcp/{db_address}/5432", check=False)
        if tcp.returncode == 0:
            raise RuntimeError("disconnected DB is still reachable through another network")
        self.result["faults"].append({"phase": phase, "database": database, "removedNetwork": network,
            "hostClientIP": address, "warmSQLSessions": sessions,
            "terminatedSessions": terminated.splitlines(), "severedTCPExit": tcp.returncode})
        self.save(phase + "-networks.json", {"before": before, "after": after})
        for name in ("host-a", "host-b"):
            self.mark(name + "-check-" + phase)
            self.wait_file(name + "-" + phase + "-healthy-edge.json", seconds=20)
        self.same_processes()

    def restore(self, database):
        self.docker("network", "connect", self.networks["host-a", database], self.containers["host-a"])
        self.same_processes()

    def hold_without_effect(self, database, query, seconds=35):
        end = time.monotonic() + seconds
        while True:
            if self.query(database, query) != "0":
                raise RuntimeError("failed request left a durable business effect")
            self.same_processes()
            if time.monotonic() >= end:
                return
            time.sleep(1)

    def execute(self):
        self.prepare()
        for name in ("host-a", "host-b"):
            self.start(name)
            self.wait_file(name + "-ready.json", watched=(name,))
        self.start("client")
        self.wait_file("warm.json")
        self.cut("control", "control-cut")
        self.mark("control-cut-start")
        self.wait_file("control-cut-result.json")
        self.hold_without_effect("owner-a", "SELECT count(*) FROM im_v2.message_edit_operations "
            f"WHERE operation_id = '{identifier(301)}'")
        if self.query("owner-a", "SELECT content_revision FROM im_v2.messages") != "2":
            raise RuntimeError("failed control-dependent edit changed content")
        self.restore("control")
        self.mark("control-restored")
        self.wait_file("control-recovered.json")
        if self.query("owner-a", "SELECT count(*) FROM im_v2.message_edit_operations "
                      f"WHERE operation_id = '{identifier(301)}'") != "1":
            raise RuntimeError("control recovery was not exactly once")

        self.cut("owner-a", "owner-cut")
        self.wait(lambda: self.query("owner-a", "SELECT (expires_at <= clock_timestamp())::text "
            f"FROM im_v2.room_activation_leases WHERE room_id = '{identifier(11)}'") == "true",
            "owner lease expiry by PostgreSQL clock", seconds=50)
        self.mark("owner-cut-expired")
        self.wait_file("owner-cut-result.json")
        self.hold_without_effect("owner-a", "SELECT count(*) FROM im_v2.messages "
            f"WHERE client_message_id = '{identifier(401)}'")
        self.restore("owner-a")
        self.mark("owner-restored")
        self.wait_file("client-result.json", watched=("host-a", "host-b"))
        for database, operation in (("owner-a", 401), ("owner-b", 402)):
            counts = self.query(database, "SELECT (SELECT count(*) FROM im_v2.messages "
                f"WHERE client_message_id = '{identifier(operation)}'), "
                "(SELECT count(*) FROM im_v2.message_send_completions "
                f"WHERE client_message_id = '{identifier(operation)}')")
            if counts != "1|1":
                raise RuntimeError("send recovery did not persist one message and completion")
        for database in ("owner-a", "owner-b"):
            if self.query(database, "SELECT count(*) FROM im_v2.messages") != "2":
                raise RuntimeError("unexpected final message count")
        self.mark("stop-hosts")
        for name in NODES:
            self.wait_file(name + "-stopped.json", seconds=70, watched=())
            self.wait(lambda: not self.inspect(name)["State"]["Running"], name + " exits", seconds=15, watched=())
            if self.inspect(name)["State"]["ExitCode"] != 0:
                raise RuntimeError(name + " failed shutdown")
        self.result["passed"] = True

    def cleanup(self):
        errors = []
        for name, container in self.containers.items():
            if container in self.created_containers:
                result = self.docker("logs", "--tail", "500", container, check=False)
                (self.output / (name + ".log")).write_bytes(result.stdout + result.stderr)
        for container in reversed(self.created_containers):
            if self.docker("rm", "-fv", container, check=False).returncode:
                errors.append(container)
        for network in reversed(self.created_networks):
            if self.docker("network", "rm", network, check=False).returncode:
                errors.append(network)
        self.result["cleanupErrors"] = errors
        if errors:
            self.result["passed"] = False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--docker-context", required=True)
    parser.add_argument("--release-dir", type=Path, required=True)
    parser.add_argument("--build-result", type=Path, required=True)
    parser.add_argument("--artifact-dir", type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    probe = Probe(args)
    try:
        probe.execute()
    except Exception as error:
        probe.result["error"] = str(error)
    finally:
        try:
            probe.cleanup()
        except Exception as error:
            probe.result.update(passed=False, cleanupError=str(error))
        probe.save("result.json", probe.result)
    print(json.dumps(probe.result, indent=2))
    return 0 if probe.result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
