#!/usr/bin/env python3
"""Disposable two-Host Virtual Actor probe. Requires an explicit DOCKER_CONTEXT.

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
ACTOR_NETWORK = RUN + "-actor-net"
DB_NETWORKS = {name: RUN + f"-db-{name}-net"
               for name in ("host-a", "host-b", "client-a", "client-b")}
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
    if MODE == "native":
        docker("network", "create", NETWORK)
    else:
        docker("network", "create", ACTOR_NETWORK)
        for db_network in DB_NETWORKS.values():
            docker("network", "create", db_network)
    args = ["run", "-d", "--name", PG, "--network",
            NETWORK if MODE == "native" else DB_NETWORKS["host-a"], "--network-alias", "va-pg"]
    if MODE == "native":
        args += ["-p", "127.0.0.1::5432"]
    args += ["-e", "POSTGRES_USER=probe", "-e", "POSTGRES_PASSWORD=probe",
             "-e", "POSTGRES_DB=probe", "postgres:16-alpine"]
    docker(*args)
    if MODE == "linux":
        for name, db_network in DB_NETWORKS.items():
            if name != "host-a":
                docker("network", "connect", "--alias", "va-pg", db_network, PG)
    wait(lambda: pg_ready(), seconds=45, description="isolated PostgreSQL ready")
    if MODE == "linux":
        return "postgres://probe:probe@va-pg:5432/probe"
    port = docker("port", PG, "5432/tcp").stdout.strip().split(":")[-1]
    return "postgres://probe:probe@127.0.0.1:" + port + "/probe"

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
INSERT INTO im_v2.rooms
 (room_id, room_shard_id, capacity_profile_id, capacity_class, membership_revision)
 VALUES ('00000000-0000-0000-0000-000000000031', 'room-a', 'standard', 'standard', 1);
INSERT INTO im_v2.room_owner_routes
 (room_id, room_shard_id, route_epoch, created_at, updated_at)
 VALUES ({ROOM_SQL}, 'room-a', 0, clock_timestamp(), clock_timestamp());
INSERT INTO im_v2.room_owner_routes
 (room_id, room_shard_id, route_epoch, created_at, updated_at)
 VALUES ('{LEASE_RACE_ROOM}', 'room-a', 0, clock_timestamp(), clock_timestamp());
INSERT INTO im_v2.room_owner_routes
 (room_id, room_shard_id, route_epoch, created_at, updated_at)
 VALUES ('00000000-0000-0000-0000-000000000031', 'room-a', 0, clock_timestamp(), clock_timestamp());
INSERT INTO im_v2.group_rooms (room_id, owner_user_id, title, created_at)
 VALUES ({ROOM_SQL}, '00000000-0000-0000-0000-000000000012', 'G6 room', clock_timestamp());
INSERT INTO im_v2.group_rooms (room_id, owner_user_id, title, created_at)
 VALUES ('00000000-0000-0000-0000-000000000031',
         '00000000-0000-0000-0000-000000000012', 'G6 healthy peer room', clock_timestamp());
INSERT INTO im_v2.shard_admission_pools
 (room_shard_id, capacity_profile_id, lease_id, generation, valid_until, command_window_limit)
 VALUES ('room-a', 'standard', '00000000-0000-0000-0000-000000000014', 1,
         clock_timestamp() + interval '10 minutes', 10);
INSERT INTO im_v2.room_admission
 (room_id, eligible_member_count, command_window_limit, shard_lease_id, shard_lease_generation)
 VALUES ({ROOM_SQL}, 1, 10, '00000000-0000-0000-0000-000000000014', 1);
INSERT INTO im_v2.room_admission
 (room_id, eligible_member_count, command_window_limit, shard_lease_id, shard_lease_generation)
 VALUES ('00000000-0000-0000-0000-000000000031', 1, 10,
         '00000000-0000-0000-0000-000000000014', 1);
INSERT INTO im_v2.room_memberships (room_id, user_id, role, joined_revision)
 VALUES ({ROOM_SQL}, '00000000-0000-0000-0000-000000000012', 'owner', 1);
INSERT INTO im_v2.room_memberships (room_id, user_id, role, joined_revision)
 VALUES ('00000000-0000-0000-0000-000000000031',
         '00000000-0000-0000-0000-000000000012', 'owner', 1);
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
        if not (scratch / "debug/VirtualActorBusinessProbe").is_file():
            raise RuntimeError("Linux business probe binary missing from task scratch")
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
        docker("create", "--name", container, "--network", ACTOR_NETWORK,
               "--network-alias", f"va-{name}", "-v", f"{os.environ['VA_G6_LINUX_SCRATCH_DIR']}:/build:ro",
               "-v", f"{SECRETS}:/secrets:ro", "-v", f"{EVIDENCE}:/evidence",
               "-e", f"IMV2_ROOM_ACTOR_CONFIGURATION_FILE=/secrets/{name}.json",
               "-e", f"VA_G6_DATABASE_URL={database_url}", "-e", "VA_G6_EVIDENCE_DIR=/evidence",
               "-e", f"VA_G6_SLOT={slot}", image, str(binary), mode)
        CONTAINERS[name] = container
        # Each Actor gets a private DB link to the same multi-homed PG. Only
        # ACTOR_NETWORK is shared between Actors, so removing it cuts every
        # peer path while keeping this process's owner-DB connection alive.
        docker("network", "connect", "--alias", f"va-db-{name}", DB_NETWORKS[name], container)
        docker("start", container)
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

def network_attachments(name):
    container = CONTAINERS[name]
    raw = docker("inspect", "-f", "{{json .NetworkSettings.Networks}}", container).stdout
    return json.loads(raw)

def peer_tls(owner_name, other_slot):
    port = 19081 if other_slot == "a" else 19082
    owner_slot = owner_name[-1]
    script = (f"timeout 4 openssl s_client -tls1_3 -brief "
              f"-connect va-host-{other_slot}:{port} -servername va-host-{other_slot} "
              f"-verify_hostname va-host-{other_slot} -verify_return_error "
              f"-CAfile /secrets/ca.pem -cert /secrets/host-{owner_slot}.pem "
              f"-key /secrets/host-{owner_slot}.key </dev/null")
    result = docker("exec", CONTAINERS[owner_name], "bash", "-c", script, check=False)
    details = result.stdout + result.stderr
    return result.returncode, details, "Protocol version: TLSv1.3" in details

def partition_peer_only(first, old_slot, database_url, binary):
    if MODE != "linux":
        return
    owner_name = f"host-{old_slot}"
    other_slot = "b" if old_slot == "a" else "a"
    other_name = f"host-{other_slot}"
    owner_db_network = DB_NETWORKS[owner_name]
    other_db_network = DB_NETWORKS[other_name]
    original = network_attachments(owner_name)
    if set(original) != {ACTOR_NETWORK, owner_db_network}:
        raise RuntimeError(f"owner missing Actor/DB attachments before partition: {original}")
    original_ip = original[ACTOR_NETWORK]["IPAddress"]
    if not original_ip:
        raise RuntimeError("owner Actor IP missing before partition")
    (EVIDENCE / "partition-networks-before.json").write_text(json.dumps(original, indent=2))
    before_code, before_tls, before_ok = peer_tls(owner_name, other_slot)
    (EVIDENCE / "partition-peer-tls-before.txt").write_text(
        f"exit={before_code}\n{before_tls}")
    if before_code != 0 or not before_ok or "Verification: OK" not in before_tls:
        raise RuntimeError("peer TLS baseline was unavailable before network partition")
    (EVIDENCE / "partition-token.json").write_text((EVIDENCE / "old-token.json").read_text())
    docker("network", "disconnect", ACTOR_NETWORK, CONTAINERS[owner_name])
    isolated = wait(lambda: network_attachments(owner_name)
                    if set(network_attachments(owner_name)) == {owner_db_network} else None,
                    seconds=10, description="owner detached only from Actor network",
                    watched=(owner_name, other_name))
    (EVIDENCE / "partition-networks-isolated.json").write_text(json.dumps(isolated, indent=2))
    if set(network_attachments(other_name)) != {ACTOR_NETWORK, other_db_network}:
        raise RuntimeError("survivor lost an attachment during peer partition")
    peer_dns = docker("exec", CONTAINERS[owner_name], "getent", "hosts",
                      f"va-host-{other_slot}", check=False)
    db_dns = docker("exec", CONTAINERS[owner_name], "getent", "hosts", "va-pg", check=False)
    peer_ip = network_attachments(other_name)[ACTOR_NETWORK]["IPAddress"]
    pg_networks = json.loads(docker("inspect", "-f", "{{json .NetworkSettings.Networks}}", PG).stdout)
    db_ip = pg_networks[owner_db_network]["IPAddress"]
    peer_addresses = {line.split()[0] for line in peer_dns.stdout.splitlines() if line.split()}
    db_addresses = {line.split()[0] for line in db_dns.stdout.splitlines() if line.split()}
    after_code, after_tls, after_ok = peer_tls(owner_name, other_slot)
    (EVIDENCE / "partition-peer-tls-isolated.txt").write_text(
        f"exit={after_code}\n{after_tls}")
    (EVIDENCE / "partition-dns.txt").write_text(
        f"peer_lookup_exit={peer_dns.returncode}\n"
        f"peer_lookup={peer_dns.stdout.strip()}\n"
        f"peer_expected_actor_ip={peer_ip}\n"
        f"peer_tls_before={before_ok}\npeer_tls_isolated={after_ok}\n"
        f"db_lookup_exit={db_dns.returncode}\n"
        f"db_lookup={db_dns.stdout.strip()}\n"
        f"db_expected_ip={db_ip}\n")
    # Colima's external DNS may synthesize a 198.18.x address for an unknown
    # short name. Compare against the peer's actual Actor IP and verify the
    # transport port is unreachable instead of trusting getent's exit code.
    if peer_ip in peer_addresses or after_ok or db_ip not in db_addresses:
        raise RuntimeError("partition retained peer transport or lost DB DNS")
    (EVIDENCE / f"host-{old_slot}-check-partition").write_text("Actor link absent; DB retained\n")
    wait(lambda: file_ready(f"host-{old_slot}-partition.json"), seconds=20,
         description="partitioned owner PG reachability and token renew",
         watched=(owner_name,))
    owner_check = json.loads((EVIDENCE / f"host-{old_slot}-partition.json").read_text())
    if not owner_check["databaseReachable"] or not owner_check["originalTokenRenewed"] or \
            owner_check["activationEpoch"] != int(first[2]):
        raise RuntimeError(f"owner lost DB renewal while Actor peer link severed: {owner_check}")
    live_before = lease()
    if live_before[:3] != first[:3] or live_before[3] != "f":
        raise RuntimeError(f"old lease no longer live at partition start: {live_before}")
    (EVIDENCE / "partition-db-before.txt").write_text("|".join(live_before) + "\n")
    # The survivor's fresh client must still serve another room. Resolving the
    # isolated owner's room must fail without creating a replacement lease.
    client_name = f"client-{other_slot}"
    start(client_name, "multi-partition-client", database_url, binary)
    wait(lambda: file_ready("partition-client-result.json"), seconds=55,
         description="survivor healthy-room send and isolated-room refusal",
         watched=(client_name, owner_name, other_name))
    exit_success(client_name)
    partition_result = json.loads((EVIDENCE / "partition-client-result.json").read_text())
    if partition_result["healthyRoomToken"]["host"]["hostID"]["rawValue"].lower() != \
            HOST_IDS[other_slot].lower() or not partition_result["isolatedRoomRejected"]:
        raise RuntimeError(f"survivor failed independent room or isolation: {partition_result}")
    live_after = lease()
    if live_after[:3] != first[:3] or live_after[3] != "f":
        raise RuntimeError(f"partition created second writer or expired lease: {live_after}")
    (EVIDENCE / "partition-db-after.txt").write_text("|".join(live_after) + "\n")
    if pg_query("SELECT count(*) FROM im_v2.room_activation_leases WHERE room_id = " + ROOM_SQL) != "1":
        raise RuntimeError("partition produced duplicate lease rows")
    if pg_query("SELECT count(*) FROM im_v2.messages WHERE room_id = " + ROOM_SQL) != "1" or \
            pg_query("SELECT count(*) FROM im_v2.messages WHERE room_id = '00000000-0000-0000-0000-000000000031'") != "1":
        raise RuntimeError("partition message rows were not one per room")
    docker("network", "connect", "--ip", original_ip,
           "--alias", f"va-host-{old_slot}", ACTOR_NETWORK, CONTAINERS[owner_name])
    restored = wait(lambda: network_attachments(owner_name)
                    if set(network_attachments(owner_name)) == {ACTOR_NETWORK, owner_db_network} else None,
                    seconds=10, description="owner Actor network reattached",
                    watched=(owner_name, other_name))
    if restored[ACTOR_NETWORK]["IPAddress"] != original_ip:
        raise RuntimeError("owner Actor IP changed on rejoin")
    (EVIDENCE / "partition-networks-restored.json").write_text(json.dumps(restored, indent=2))
    start(f"client-{old_slot}", "multi-partition-rejoin", database_url, binary)
    wait(lambda: file_ready("partition-rejoin-result.json"), seconds=65,
         description="restored owner idempotent replay", watched=(f"client-{old_slot}",))
    exit_success(f"client-{old_slot}")
    rejoin = json.loads((EVIDENCE / "partition-rejoin-result.json").read_text())
    race = json.loads((EVIDENCE / f"race-{old_slot}-result.json").read_text())
    if rejoin["token"] != race["token"] or rejoin["messageID"] != race["messageID"] or \
            rejoin["primaryMessageRows"] != 1 or lease()[:3] != first[:3]:
        raise RuntimeError(f"network rejoin changed durable operation or owner: {rejoin}")
    (EVIDENCE / "partition-result.json").write_text(json.dumps({
        "ownerSlot": old_slot, "survivorSlot": other_slot,
        "ownerCheck": owner_check, "survivorClient": partition_result,
        "rejoin": rejoin, "before": live_before, "after": live_after}, indent=2))

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
    # Typed operations return the same permanent receipt for first commit and replay.
    # SQL uniqueness and identical message IDs below prove one durable effect.
    assert race_a["outcome"] == race_b["outcome"] == "originalReceipt"
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
    assert pg_query("SELECT COUNT(*) FROM im_v2.messages") == ("2" if MODE == "linux" else "1")
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
    partition_peer_only(first, old_slot, database_url, binary)
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
    for network in (NETWORK, ACTOR_NETWORK, *DB_NETWORKS.values()):
        docker("network", "rm", network, check=False)
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
