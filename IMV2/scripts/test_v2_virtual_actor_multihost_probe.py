#!/usr/bin/env python3
"""Disposable two-Host Virtual Actor probe. Requires DOCKER_CONTEXT and native Swift.

All waits use file, process, or PostgreSQL state barriers with explicit deadlines.
No shared PostgreSQL, SwiftPM scratch, or Docker resource is modified.
"""
import base64
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
ROOM = "00000000-0000-0000-0000-000000000011"
LEASE_RACE_ROOM = "00000000-0000-0000-0000-000000000021"
HOST_IDS = {"a": "10000000-0000-0000-0000-000000000001",
            "b": "10000000-0000-0000-0000-000000000002"}
CONTEXT = os.environ.get("DOCKER_CONTEXT")
if not CONTEXT:
    raise SystemExit("DOCKER_CONTEXT must explicitly name the disposable Docker context")
MODE = os.environ.get("VA_G6_MODE", "native")
if MODE not in ("native", "linux"):
    raise SystemExit("VA_G6_MODE must be native or linux")
RUN = f"imv2-va-g6-{os.getpid()}-{uuid.uuid4().hex[:8]}"
if MODE == "linux":
    run_root = Path(os.environ.get(
        "VA_G6_LINUX_RUN_ROOT", str(Path.home() / ".codex/virtual-actor-builds/g6-runs"))).resolve()
    run_root.mkdir(parents=True, exist_ok=True)
    default_evidence = run_root / f"{RUN}-evidence"
    SECRETS = run_root / f"{RUN}-secrets"
    SECRETS.mkdir(mode=0o700)
else:
    default_evidence = Path(f"/tmp/{RUN}-evidence")
    SECRETS = Path(tempfile.mkdtemp(prefix=RUN + "-secrets-"))
EVIDENCE = Path(os.environ.get("VA_G6_EVIDENCE_DIR", str(default_evidence))).resolve()
EVIDENCE.mkdir(parents=True, exist_ok=False)
PG = RUN + "-pg"
NETWORK = RUN + "-net"
PROCESSES = {}
CONTAINERS = {}
ROOM_SQL = "'" + ROOM + "'"

def command(args, *, timeout=30, input=None, output=None, check=True):
    if output:
        with open(output, "wb") as handle:
            return subprocess.run(args, input=input, stdout=handle, stderr=subprocess.STDOUT,
                                  timeout=timeout, check=check)
    return subprocess.run(args, input=input, capture_output=True, timeout=timeout,
                          check=check, text=input is None)

def docker(*args, **kwargs):
    return command(["docker", "--context", CONTEXT, *args], **kwargs)

def pg_query(sql):
    return docker("exec", PG, "psql", "-XAt", "-v", "ON_ERROR_STOP=1", "-U", "probe",
                  "-d", "probe", "-c", sql).stdout.strip()

def wait(predicate, *, seconds, description, watched=()):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        for name in watched:
            if MODE == "native":
                proc = PROCESSES[name]
                if proc.poll() is not None:
                    raise RuntimeError(f"{name} exited {proc.returncode}; see {EVIDENCE / (name + '.log')}")
            elif docker("inspect", "-f", "{{.State.Running}}", CONTAINERS[name],
                        check=False).stdout.strip() != "true":
                raise RuntimeError(f"{name} container stopped")
        time.sleep(0.1)
    raise TimeoutError(f"timed out waiting for {description}")

def free_ports(n):
    held = [socket.socket() for _ in range(n)]
    try:
        for sock in held:
            sock.bind(("127.0.0.1", 0))
        return [sock.getsockname()[1] for sock in held]
    finally:
        for sock in held:
            sock.close()

def openssl(*args):
    command(["openssl", *args], timeout=20, output=EVIDENCE / "last-openssl.log")

def setup_certs_and_configs(ports):
    openssl("req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes", "-days", "2",
            "-keyout", str(SECRETS / "ca.key"), "-out", str(SECRETS / "ca.pem"),
            "-subj", "/CN=imv2-va-g6-ca", "-addext", "basicConstraints=critical,CA:TRUE")
    names = ("host-a", "host-b", "client-a", "client-b")
    for name in names:
        openssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-sha256",
                "-keyout", str(SECRETS / f"{name}.key"),
                "-out", str(SECRETS / f"{name}.csr"), "-subj", f"/CN={name}")
        alias = "localhost" if MODE == "native" else f"va-{name}"
        extension = SECRETS / f"{name}.ext"
        extension.write_text(f"subjectAltName=DNS:{alias}\n")
        openssl("x509", "-req", "-in", str(SECRETS / f"{name}.csr"),
                "-CA", str(SECRETS / "ca.pem"), "-CAkey", str(SECRETS / "ca.key"),
                "-CAcreateserial", "-days", "2", "-sha256", "-extfile", str(extension),
                "-out", str(SECRETS / f"{name}.pem"))
        openssl("genpkey", "-algorithm", "Ed25519", "-out", str(SECRETS / f"{name}-signing.pem"))
        with open(SECRETS / f"{name}-signing.key", "wb") as handle:
            subprocess.run(["openssl", "pkey", "-in", str(SECRETS / f"{name}-signing.pem"),
                            "-outform", "DER"], stdout=handle, check=True)
        raw = (SECRETS / f"{name}-signing.key").read_bytes()[-32:]
        (SECRETS / f"{name}-signing.key").write_bytes(raw)
        with open(SECRETS / f"{name}-signing.pub", "wb") as handle:
            subprocess.run(["openssl", "pkey", "-in", str(SECRETS / f"{name}-signing.pem"),
                            "-pubout", "-outform", "DER"], stdout=handle, check=True)
        (SECRETS / f"{name}-signing.pub").write_bytes(
            (SECRETS / f"{name}-signing.pub").read_bytes()[-32:])
    services = []
    for name in names:
        services.append({"id": f"g6-{name}-service",
                         "publicKeyBase64": base64.b64encode(
                             (SECRETS / f"{name}-signing.pub").read_bytes()).decode(),
                         "permissions": ["roomCoordination", "userRoomCalls"],
                         "hostIDs": [HOST_IDS[name[-1]]] if name.startswith("host") else [],
                         "shardIDs": ["room-a"]})
    for name in names:
        peers = []
        for slot in ("a", "b"):
            peer_name = f"host-{slot}"
            # Opposing client preferences force independent first attempts.
            maximum = 10000 if name.startswith("host") or name[-1] == slot else 1
            peers.append({"hostID": HOST_IDS[slot], "serviceID": f"g6-{peer_name}-service",
                          "address": "localhost" if MODE == "native" else f"va-{peer_name}",
                          "port": ports[peer_name], "shardIDs": ["room-a"],
                          "maximumRooms": maximum})
        path = lambda suffix: str(SECRETS / suffix) if MODE == "native" else "/secrets/" + suffix
        doc = {"name": "imv2-va-g6", "address": "localhost" if MODE == "native" else f"va-{name}",
               "port": ports[name], "threadPoolSize": 2,
               "serviceID": f"g6-{name}-service",
               "hostID": HOST_IDS[name[-1]] if name.startswith("host") else None,
               "signingKeyPath": path(f"{name}-signing.key"),
               "certificatePath": path(f"{name}.pem"), "privateKeyPath": path(f"{name}.key"),
               "trustRootPath": path("ca.pem"), "services": services, "peers": peers}
        (SECRETS / f"{name}.json").write_text(json.dumps(doc))
    (EVIDENCE / "peer-preferences.json").write_text(json.dumps({
        "client-a": {"host-a": 10000, "host-b": 1},
        "client-b": {"host-a": 1, "host-b": 10000}}, indent=2))

def start_pg():
    docker("network", "create", NETWORK)
    args = ["run", "-d", "--name", PG, "--network", NETWORK, "--network-alias", "va-pg"]
    if MODE == "native":
        args += ["-p", "127.0.0.1::5432"]
    args += ["-e", "POSTGRES_USER=probe", "-e", "POSTGRES_PASSWORD=probe",
             "-e", "POSTGRES_DB=probe", "postgres:16-alpine"]
    docker(*args)
    wait(lambda: pg_ready(), seconds=45, description="isolated PostgreSQL ready")
    port = docker("port", PG, "5432/tcp").stdout.strip().split(":")[-1]
    return ("postgres://probe:probe@127.0.0.1:" + port + "/probe") if MODE == "native" else \
           "postgres://probe:probe@va-pg:5432/probe"

def pg_ready():
    try:
        return pg_query("SELECT 1") == "1"
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return False

FIXTURE = f"""
INSERT INTO im_v2.public_user_profiles
 (user_id, public_handle, display_name, revision, created_at, updated_at)
 VALUES ('00000000-0000-0000-0000-000000000012', 'g6_sender', 'G6 Sender', 1, clock_timestamp(), clock_timestamp());
INSERT INTO im_v2.rooms
 (room_id, room_shard_id, capacity_profile_id, capacity_class, membership_revision)
 VALUES ({ROOM_SQL}, 'room-a', 'standard', 'standard', 1);
INSERT INTO im_v2.rooms
 (room_id, room_shard_id, capacity_profile_id, capacity_class, membership_revision)
 VALUES ('{LEASE_RACE_ROOM}', 'room-a', 'standard', 'standard', 0);
INSERT INTO im_v2.room_owner_routes
 (room_id, room_shard_id, route_epoch, created_at, updated_at)
 VALUES ({ROOM_SQL}, 'room-a', 0, clock_timestamp(), clock_timestamp());
INSERT INTO im_v2.room_owner_routes
 (room_id, room_shard_id, route_epoch, created_at, updated_at)
 VALUES ('{LEASE_RACE_ROOM}', 'room-a', 0, clock_timestamp(), clock_timestamp());
INSERT INTO im_v2.group_rooms (room_id, owner_user_id, title, created_at)
 VALUES ({ROOM_SQL}, '00000000-0000-0000-0000-000000000012', 'G6 room', clock_timestamp());
INSERT INTO im_v2.shard_admission_pools
 (room_shard_id, capacity_profile_id, lease_id, generation, valid_until, command_window_limit)
 VALUES ('room-a', 'standard', '00000000-0000-0000-0000-000000000014', 1,
         clock_timestamp() + interval '10 minutes', 10);
INSERT INTO im_v2.room_admission
 (room_id, eligible_member_count, command_window_limit, shard_lease_id, shard_lease_generation)
 VALUES ({ROOM_SQL}, 1, 10, '00000000-0000-0000-0000-000000000014', 1);
INSERT INTO im_v2.room_memberships (room_id, user_id, role, joined_revision)
 VALUES ({ROOM_SQL}, '00000000-0000-0000-0000-000000000012', 'owner', 1);
INSERT INTO im_v2.user_shard_router_configuration
 (configuration_key, router_epoch, default_write_bucket, updated_at)
 VALUES (TRUE, 1, 'g6-users', clock_timestamp());
"""

def install_schema():
    with open(ROOT / "IMV2/sql/schema.sql", "rb") as source:
        data = source.read()
    command(["docker", "--context", CONTEXT, "exec", "-i", PG, "psql", "-v",
             "ON_ERROR_STOP=1", "-U", "probe", "-d", "probe"], input=data,
            output=EVIDENCE / "schema-install.log", timeout=90)
    command(["docker", "--context", CONTEXT, "exec", "-i", PG, "psql", "-v",
             "ON_ERROR_STOP=1", "-U", "probe", "-d", "probe"], input=FIXTURE.encode(),
            output=EVIDENCE / "fixture-install.log", timeout=30)

def build():
    if MODE == "native":
        scratch = Path(os.environ.get("VA_G6_NATIVE_SCRATCH_DIR", "/tmp/va-receipt-metrics-build"))
        binary = scratch / "debug/VirtualActorBusinessProbe"
        command(["swift", "build", "--package-path", str(ROOT / "IMV2Server"),
                 "--scratch-path", str(scratch), "-j", "2", "--product",
                 "VirtualActorBusinessProbe"], timeout=1200, output=EVIDENCE / "build.log")
    else:
        scratch = Path(os.environ["VA_G6_LINUX_SCRATCH_DIR"])
        if not scratch.is_absolute() or not scratch.is_dir() or ROOT in scratch.parents or \
                scratch == ROOT or scratch == EVIDENCE or scratch in EVIDENCE.parents or \
                EVIDENCE in scratch.parents:
            raise RuntimeError("Linux scratch must be an existing absolute directory outside source")
        image = os.environ.get("VA_G6_SWIFT_IMAGE", "swift:6.4-jammy@sha256:a6053d2de72091906bfa064f76f145e3f28830664cae250e1b84aa8c499a8ee6")
        docker("run", "--rm", "-v", f"{ROOT}:/repo:ro", "-v", f"{scratch}:/build",
               "-w", "/repo/IMV2Server", image, "timeout", "2400", "swift", "build",
               "--scratch-path", "/build", "-c", "debug", "--product",
               "VirtualActorBusinessProbe", "-j", "2", timeout=2450,
               output=EVIDENCE / "build.log")
        binary = Path("/build/debug/VirtualActorBusinessProbe")
    if MODE == "native" and not binary.is_file():
        raise RuntimeError("probe binary missing")
    return binary

def start(name, mode, database_url, binary):
    slot = name[-1] if name[-1] in ("a", "b") else "b"
    log = EVIDENCE / f"{name}.log"
    if MODE == "native":
        env = os.environ.copy()
        env.update({"IMV2_ROOM_ACTOR_CONFIGURATION_FILE": str(SECRETS / f"{name}.json"),
                    "VA_G6_DATABASE_URL": database_url, "VA_G6_EVIDENCE_DIR": str(EVIDENCE),
                    "VA_G6_SLOT": slot})
        handle = open(log, "wb")
        proc = subprocess.Popen([str(binary), mode], env=env, stdout=handle,
                                stderr=subprocess.STDOUT, start_new_session=True)
        handle.close()
        PROCESSES[name] = proc
    else:
        image = os.environ.get("VA_G6_SWIFT_IMAGE", "swift:6.4-jammy@sha256:a6053d2de72091906bfa064f76f145e3f28830664cae250e1b84aa8c499a8ee6")
        container = RUN + "-" + name
        docker("run", "-d", "--name", container, "--network", NETWORK,
               "--network-alias", f"va-{name}", "-v", f"{os.environ['VA_G6_LINUX_SCRATCH_DIR']}:/build:ro",
               "-v", f"{SECRETS}:/secrets:ro", "-v", f"{EVIDENCE}:/evidence",
               "-e", f"IMV2_ROOM_ACTOR_CONFIGURATION_FILE=/secrets/{name}.json",
               "-e", f"VA_G6_DATABASE_URL={database_url}", "-e", "VA_G6_EVIDENCE_DIR=/evidence",
               "-e", f"VA_G6_SLOT={slot}", image, str(binary), mode)
        CONTAINERS[name] = container
    (EVIDENCE / "processes.txt").open("a").write(
        f"{name}=" + (str(PROCESSES[name].pid) if MODE == "native" else CONTAINERS[name]) + "\n")

def file_ready(name):
    return (EVIDENCE / name).is_file()

def lease():
    sql = f"SELECT host_id, host_incarnation_id, activation_epoch, expires_at <= clock_timestamp() FROM im_v2.room_activation_leases WHERE room_id = {ROOM_SQL}"
    raw = pg_query(sql)
    return raw.split("|") if raw else None

def save_lease(name):
    value = lease()
    (EVIDENCE / name).write_text("|".join(value) + "\n")
    return value

def competing_host_acquires():
    # The task-owned SQL session holds the second room's row lock. Both real
    # Host processes must be observed blocked inside acquire before release;
    # this proves a concurrent first-acquire race rather than two serial calls.
    # pg_sleep is only the lock holder's fail-safe lifetime. Every stage is
    # gated on pg_stat_activity/pg_locks and the holder is terminated as soon
    # as both blocked Host backends are observed.
    holder_sql = ("BEGIN; SELECT room_id FROM im_v2.rooms WHERE room_id = '" +
                  LEASE_RACE_ROOM + "' FOR NO KEY UPDATE; SELECT pg_sleep(30)")
    holder = subprocess.Popen(
        ["docker", "--context", CONTEXT, "exec", PG, "psql", "-XAt", "-v",
         "ON_ERROR_STOP=1", "-U", "probe", "-d", "probe", "-c", holder_sql],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    holder_pid = None
    try:
        holder_pid = wait(
            lambda: pg_query("SELECT pid FROM pg_stat_activity WHERE wait_event = 'PgSleep' "
                             "AND query LIKE '%SELECT pg_sleep(30)%' AND datname = 'probe' "
                             "ORDER BY pid LIMIT 1"), seconds=5,
            description="PG row-lock holder reached sleep after row lock")
        assert pg_query("SELECT count(*) FROM im_v2.room_activation_leases WHERE room_id = '" +
                        LEASE_RACE_ROOM + "'") == "0"
        (EVIDENCE / "lease-race-start").write_text("row lock held; both Hosts ready\n")
        def waiters():
            sql = ("SELECT pid, wait_event_type, wait_event FROM pg_stat_activity "
                   "WHERE wait_event_type = 'Lock' AND query LIKE '%FOR NO KEY UPDATE%' "
                   "AND datname = 'probe' ORDER BY pid")
            rows = pg_query(sql).splitlines()
            return rows if len(rows) >= 2 else None
        blocked = wait(waiters, seconds=5, description="two Host SQL acquisitions blocked",
                       watched=("host-a", "host-b"))
        (EVIDENCE / "lease-race-blocked-backends.txt").write_text("\n".join(blocked) + "\n")
        if pg_query(f"SELECT pg_terminate_backend({int(holder_pid)})") != "t":
            raise RuntimeError("PG lock holder termination failed")
        holder.wait(timeout=5)
    finally:
        if holder_pid and holder.poll() is None:
            pg_query(f"SELECT pg_terminate_backend({int(holder_pid)})")
        if holder.poll() is None:
            holder.kill()
            holder.wait(timeout=5)
    for slot in ("a", "b"):
        wait(lambda s=slot: file_ready(f"host-{s}-lease-race.json"), seconds=20,
             description=f"Host {slot} lease acquisition outcome", watched=(f"host-{slot}",))
    a = json.loads((EVIDENCE / "host-a-lease-race.json").read_text())
    b = json.loads((EVIDENCE / "host-b-lease-race.json").read_text())
    if {a["outcome"], b["outcome"]} != {"acquired", "occupied"} or a["token"] != b["token"]:
        raise RuntimeError(f"Host acquisition collision not single-winner: {a}, {b}")
    lease_row = pg_query("SELECT host_id, activation_epoch, count(*) OVER() "
                         "FROM im_v2.room_activation_leases WHERE room_id = '" +
                         LEASE_RACE_ROOM + "'")
    host_id, epoch, rows = lease_row.split("|")
    if host_id.lower() != a["token"]["host"]["hostID"]["rawValue"].lower() or \
            epoch != "1" or rows != "1":
        raise RuntimeError(f"Host acquisition SQL row mismatch: {lease_row}")
    (EVIDENCE / "lease-race-result.json").write_text(json.dumps({
        "hostA": a, "hostB": b, "leaseRow": lease_row,
        "blockedBackends": blocked}, indent=2))

def exit_success(name, seconds=60):
    if MODE == "native":
        proc = PROCESSES[name]
        if proc.wait(timeout=seconds) != 0:
            raise RuntimeError(f"{name} failed; see {EVIDENCE / (name + '.log')}")
    else:
        container = CONTAINERS[name]
        code = docker("wait", container, timeout=seconds).stdout.strip()
        docker("logs", container, output=EVIDENCE / f"{name}.log", check=False)
        if code != "0":
            raise RuntimeError(f"{name} exited {code}")
        docker("rm", container, check=False)
        del CONTAINERS[name]

def pause(name):
    if MODE == "native":
        os.kill(PROCESSES[name].pid, signal.SIGSTOP)
    else:
        docker("pause", CONTAINERS[name])

def resume(name):
    if MODE == "native":
        os.kill(PROCESSES[name].pid, signal.SIGCONT)
    else:
        docker("unpause", CONTAINERS[name])

def verify(first, second, owner, old_host):
    race_a = json.loads((EVIDENCE / "race-a-result.json").read_text())
    race_b = json.loads((EVIDENCE / "race-b-result.json").read_text())
    replay = json.loads((EVIDENCE / "replay-result.json").read_text())
    stale = json.loads((EVIDENCE / f"host-{old_host}-stale.json").read_text())
    tokens = [race_a["token"], race_b["token"]]
    assert race_a["messageID"] == race_b["messageID"] == replay["messageID"]
    assert {race_a["outcome"], race_b["outcome"]} == {"accepted", "idempotent"}
    assert all(t["activationEpoch"] == int(first[2]) for t in tokens)
    assert all(t["host"]["hostID"]["rawValue"].lower() == owner.lower() for t in tokens)
    assert second[0].lower() != first[0].lower()
    assert int(second[2]) == int(first[2]) + 1
    assert replay["token"]["activationEpoch"] == int(second[2])
    assert replay["token"]["host"]["hostID"]["rawValue"].lower() == second[0].lower()
    assert replay["messageRows"] == stale["messageRows"] == 1
    assert all(stale[key] is True for key in
               ("renewRejected", "releaseRejected", "businessWriteRejected"))
    final = save_lease("final-lease.txt")
    assert final[:3] == second[:3]
    assert pg_query("SELECT COUNT(*) FROM im_v2.messages") == "1"
    assert pg_query(f"SELECT COUNT(DISTINCT message_id) FROM im_v2.messages WHERE room_id = {ROOM_SQL}") == "1"
    (EVIDENCE / "result.json").write_text(json.dumps({
        "firstLease": first, "replacementLease": second, "finalLease": final,
        "firstOwnerSlot": old_host, "raceA": race_a, "raceB": race_b,
        "replay": replay, "stale": stale, "uniqueMessageRows": 1}, indent=2))

def main():
    database_url = start_pg()
    install_schema()
    ports = dict(zip(("host-a", "host-b", "client-a", "client-b"),
                     free_ports(4) if MODE == "native" else (19081, 19082, 19083, 19084)))
    setup_certs_and_configs(ports)
    binary = build()
    (EVIDENCE / "source-sha.txt").write_text(command(["git", "-C", str(ROOT),
                                                       "rev-parse", "HEAD"]).stdout)
    for slot in ("a", "b"):
        start(f"host-{slot}", "multi-host", database_url, binary)
    for slot in ("a", "b"):
        wait(lambda s=slot: file_ready(f"host-{s}-ready"), seconds=40,
             description=f"host {slot} ready", watched=(f"host-{slot}",))
    competing_host_acquires()
    if lease() is not None:
        raise RuntimeError("lease exists before first access")
    for slot in ("a", "b"):
        start(f"client-{slot}", "multi-race", database_url, binary)
    for slot in ("a", "b"):
        wait(lambda s=slot: file_ready(f"race-{s}-ready"), seconds=40,
             description=f"race {slot} ready", watched=(f"client-{slot}",))
    if lease() is not None:
        raise RuntimeError("lease exists before race barrier")
    (EVIDENCE / "race-start").write_text("both clients ready; initial lease absent\n")
    for slot in ("a", "b"):
        wait(lambda s=slot: file_ready(f"race-{s}-result.json"), seconds=75,
             description=f"race {slot} result", watched=(f"client-{slot}",))
    for slot in ("a", "b"):
        exit_success(f"client-{slot}")
    first = save_lease("first-lease.txt")
    if not first or first[3] != "f" or int(first[2]) != 1:
        raise RuntimeError(f"expected one live first lease, got {first}")
    owner = first[0]
    old_slot = next((slot for slot, host_id in HOST_IDS.items() if host_id == owner), None)
    if old_slot is None:
        raise RuntimeError(f"unexpected owner {owner}")
    old_race = json.loads((EVIDENCE / f"race-{old_slot}-result.json").read_text())
    (EVIDENCE / "old-token.json").write_text(json.dumps(old_race["token"]))
    pause(f"host-{old_slot}")
    (EVIDENCE / "owner-paused.txt").write_text(f"slot={old_slot} host_id={owner}\n")
    wait(lambda: (current := lease()) and current[:3] == first[:3] and current[3] == "t",
         seconds=55, description="old lease expiry by PostgreSQL clock",
         watched=(f"host-{'b' if old_slot == 'a' else 'a'}",))
    (EVIDENCE / "db-expired-lease.txt").write_text("|".join(lease()) + "\n")
    # Client of the surviving Host has that Host as its first candidate.
    new_slot = "b" if old_slot == "a" else "a"
    start(f"client-{new_slot}", "multi-replay", database_url, binary)
    wait(lambda: file_ready("replay-result.json"), seconds=80,
         description="surviving host takeover and replay", watched=(f"client-{new_slot}",))
    exit_success(f"client-{new_slot}")
    second = save_lease("replacement-lease.txt")
    if second[0] != HOST_IDS[new_slot] or int(second[2]) != int(first[2]) + 1:
        raise RuntimeError(f"unexpected replacement lease: {second}")
    resume(f"host-{old_slot}")
    (EVIDENCE / f"host-{old_slot}-check-stale").write_text("new Host acquired\n")
    wait(lambda: file_ready(f"host-{old_slot}-stale.json"), seconds=45,
         description="resumed old Host stale-token checks", watched=(f"host-{old_slot}",))
    verify(first, second, owner, old_slot)
    print(f"G6_MULTIHOST_OK evidence={EVIDENCE} first={old_slot} replacement={new_slot}")

def cleanup():
    for proc in PROCESSES.values():
        if proc.poll() is None:
            try:
                os.killpg(proc.pid, signal.SIGCONT)
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    for proc in PROCESSES.values():
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            pass
    for name, container in CONTAINERS.items():
        docker("unpause", container, check=False)
        docker("logs", container, output=EVIDENCE / f"{name}.log", check=False)
        docker("rm", "-f", container, check=False)
    docker("rm", "-f", PG, check=False)
    docker("network", "rm", NETWORK, check=False)
    import shutil
    shutil.rmtree(SECRETS, ignore_errors=True)

if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"G6_MULTIHOST_FAILED: {error}; evidence={EVIDENCE}", file=sys.stderr)
        sys.exit(1)
    finally:
        cleanup()
