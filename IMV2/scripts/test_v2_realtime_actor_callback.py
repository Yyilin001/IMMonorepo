#!/usr/bin/env python3
"""Two independent native mTLS Cluster processes using production callback code.

Pass an already-built VirtualActorBusinessProbe. Never builds or changes shared
certificates/deployment configuration. Optional outbox mode uses only an explicitly
named fresh disposable PostgreSQL database on a loopback port other than 5432.
"""
import argparse
import base64
import json
import os
import signal
import uuid
from urllib.parse import urlparse, unquote
from pathlib import Path
import socket
import subprocess
import tempfile
import time


def command(*args):
    return subprocess.run(args, check=True, capture_output=True, timeout=20).stdout


def ports():
    sockets = [socket.socket(), socket.socket()]
    try:
        for sock in sockets:
            sock.bind(("127.0.0.1", 0))
        return [sock.getsockname()[1] for sock in sockets]
    finally:
        for sock in sockets:
            sock.close()


class DisposablePostgres:
    def __init__(self, url):
        parsed = urlparse(url)
        database = unquote(parsed.path.removeprefix("/"))
        if (parsed.scheme not in ("postgres", "postgresql") or parsed.hostname != "127.0.0.1"
                or not parsed.port or parsed.port == 5432 or not parsed.username
                or not database.startswith("imv2_callback_kill_")
                or not database.replace("_", "").isalnum() or parsed.fragment):
            raise ValueError("outbox database must be an explicitly owned fresh imv2_callback_kill_* database on 127.0.0.1, non-5432 port")
        self.environment = os.environ.copy()
        self.environment.update(PGHOST="127.0.0.1", PGPORT=str(parsed.port),
                                PGUSER=unquote(parsed.username), PGPASSWORD=unquote(parsed.password or ""),
                                PGDATABASE=database, PGSSLMODE="disable", PGCONNECT_TIMEOUT="5")
        self.database = database
        if self.query("SELECT pg_get_userbyid(datdba)=current_user FROM pg_database WHERE datname=current_database()") != "t":
            raise ValueError("disposable database must be owned by the supplied PostgreSQL role")
        # Reject any existing application objects before installing schema or data.
        count = self.query("SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_toast%' AND n.nspname NOT LIKE 'pg_temp%'")
        if count != "0" or self.query("SELECT count(*) FROM pg_namespace WHERE nspname='im_v2'") != "0":
            raise ValueError("outbox database is not fresh; no application objects may exist")

    def query(self, sql):
        result = subprocess.run(["psql", "-XAt", "-v", "ON_ERROR_STOP=1"],
                                input=sql, text=True, capture_output=True, timeout=60,
                                env=self.environment)
        # Do not echo SQL, connection strings, or arbitrary error descriptions.
        if result.returncode:
            raise RuntimeError("disposable PostgreSQL operation failed; exit=" + str(result.returncode))
        return result.stdout.strip()

    def prepare(self, kind, topic_id):
        schema = Path(__file__).resolve().parents[1] / "sql/schema.sql"
        self.query(schema.read_text())
        event_id = str(uuid.uuid4())
        if kind == "room":
            self.query(f"""BEGIN;
                INSERT INTO im_v2.rooms(room_id,room_shard_id,room_kind,capacity_profile_id,room_sequence)
                VALUES ('{topic_id}','room-a','direct','callback-contract',1);
                INSERT INTO im_v2.room_events(event_id,room_id,room_sequence,event_type,payload,committed_membership_revision,created_at)
                VALUES ('{event_id}','{topic_id}',1,'relay.contract.fixture','{{}}',0,clock_timestamp());
                COMMIT;""")
        else:
            # The production INSERT trigger creates the user wake in this COMMIT.
            self.query(f"""BEGIN;
                INSERT INTO im_v2.user_sync_sequences(user_id,next_sequence) VALUES ('{topic_id}',1);
                INSERT INTO im_v2.user_sync_log(user_id,user_sync_sequence,source_event_id,projection_kind,payload,created_at)
                VALUES ('{topic_id}',1,'{event_id}','relay.contract.fixture','{{}}',clock_timestamp()); COMMIT;""")

    def snapshot(self, kind, topic_id):
        if kind != "user":
            raise ValueError("durable outbox relay is user-only; room recovery uses the Owner dirty-head source")
        table, key, facts, head = "user_sync_wake_outbox", "user_id", "user_sync_log", "(SELECT next_sequence FROM im_v2.user_sync_sequences WHERE user_id='%s')" % topic_id
        return json.loads(self.query(f"""SELECT json_build_object(
            'facts',(SELECT count(*) FROM im_v2.{facts} WHERE {key}='{topic_id}'),
            'head',{head},'wakeCount',(SELECT count(*) FROM im_v2.{table} WHERE {key}='{topic_id}'),
            'wakeState',(SELECT state FROM im_v2.{table} WHERE {key}='{topic_id}'),
            'attemptCount',(SELECT attempt_count FROM im_v2.{table} WHERE {key}='{topic_id}'),
            'leaseExpired',(SELECT lease_expires_at<=clock_timestamp() FROM im_v2.{table} WHERE {key}='{topic_id}'))"""))


def wait_marker(path, processes, timeout=25):
    deadline = time.monotonic() + timeout
    while not path.is_file():
        if any(process.poll() is not None for process in processes.values()):
            raise RuntimeError("outbox process exited before required barrier " + path.name)
        if time.monotonic() >= deadline:
            raise TimeoutError("outbox barrier timed out " + path.name)
        time.sleep(0.02)


def recover_killed_publisher(*, processes, files, configs, args, evidence, postgres, topic_id):
    wait_marker(evidence / "offer-held", processes)
    before = postgres.snapshot(args.outbox_kill, topic_id)
    assert before["facts"] == before["head"] == before["wakeCount"] == 1 and before["wakeState"] == "leased" and before["attemptCount"] == 1, before
    processes["sender"].kill()  # actual SIGKILL: no cancellation/markPublished cleanup
    assert processes["sender"].wait(timeout=5) == -signal.SIGKILL
    after_kill = postgres.snapshot(args.outbox_kill, topic_id)
    assert after_kill["wakeState"] == "leased" and after_kill["wakeCount"] == 1 and after_kill["facts"] == after_kill["head"] == 1, after_kill
    (evidence / "outbox-after-kill.json").write_text(json.dumps({"beforeKill": before, "afterKill": after_kill,
        "sourceKilledBySignal": "SIGKILL", "claimLeaseSeconds": 15, "kind": args.outbox_kill}, indent=2))
    (evidence / "offer-release").write_text("release")
    # Keep the real production 15-second claim lease. Never mutate persistence or advance clocks.
    deadline = time.monotonic() + 25
    while not postgres.snapshot(args.outbox_kill, topic_id)["leaseExpired"]:
        if processes["receiver"].poll() is not None or time.monotonic() >= deadline:
            raise TimeoutError("real persisted claim lease did not expire")
        time.sleep(0.1)
    config, environment = configs["sender"]
    value = json.loads(config.read_text())
    # The source process has exited; restart the same configured listener.
    # Changing its port would violate the receiver's immutable discovery roster.
    value.update(name="realtime-sender-successor")
    successor_config = config.with_name("sender-successor.json")
    successor_config.write_text(json.dumps(value))
    environment = environment.copy()
    environment["VA_REALTIME_CONFIGURATION"] = str(successor_config)
    log = open(evidence / "sender-successor.log", "wb")
    files.append(log)
    processes["sender"] = subprocess.Popen([str(args.binary.resolve()), "realtime-sender"], env=environment,
                                           stdout=log, stderr=subprocess.STDOUT)




def recover_partition_host(*, processes, files, configs, args, evidence, postgres):
    wait_marker(evidence / "gateway-before-kill.json", processes, timeout=35)
    initial = json.loads((evidence / "host-installed-initial.json").read_text())
    ready = json.loads((evidence / "gateway-before-kill.json").read_text())
    assert ready["token"] == initial and ready["highWatermark"] >= 1, "initial actual Ready fence mismatch"
    partition = initial["partitionID"]
    epoch = initial["epoch"]
    host = initial["host"]
    # Closed values only; no arbitrary SQL/config text is interpolated.
    assert type(partition) is int and 0 <= partition < 256
    assert type(epoch) is int and epoch > 0
    assert host["nodeID"] == host["serviceID"] == "receiver"
    incarnation = str(uuid.UUID(host["incarnationID"]))
    lease_token = str(uuid.UUID(initial["leaseToken"]))
    processes["receiver"].kill()
    assert processes["receiver"].wait(timeout=5) == -signal.SIGKILL
    # A controlled expiry ONLY after actual process exit. The successor still
    # uses production claim to allocate epoch/token; no ownership is fabricated.
    expired = postgres.query(f"""WITH expired AS (UPDATE im_v2.realtime_partition_leases
        SET expires_at=clock_timestamp()
        WHERE partition_id={partition} AND host_id='receiver' AND service_id='receiver'
          AND process_incarnation='{incarnation}' AND lease_epoch={epoch}
          AND lease_token='{lease_token}' RETURNING partition_id) SELECT count(*) FROM expired""")
    assert expired == "1", "old lease exact CAS did not expire one row"
    config, environment = configs["receiver"]
    value = json.loads(config.read_text())
    value["name"] = "realtime-receiver-successor"
    successor_config = config.with_name("receiver-successor.json")
    successor_config.write_text(json.dumps(value))
    environment = environment.copy()
    environment["VA_REALTIME_CONFIGURATION"] = str(successor_config)
    log = open(evidence / "receiver-successor.log", "wb")
    files.append(log)
    processes["receiver"] = subprocess.Popen([str(args.binary.resolve()), "realtime-receiver"], env=environment,
                                             stdout=log, stderr=subprocess.STDOUT)
    (evidence / "partition-handoff-scope.json").write_text(json.dumps({
        "confirmedHostSIGKILL": True, "sameConfiguredPort": True,
        "acceleratedLeaseExpiryAfterConfirmedSIGKILL": True,
        "productionControllerUsed": False, "fixtureRenewalUsed": True,
        "naturalLeaseRecoveryLatencyMeasured": False,
        "fullAppCursorRecoveryProven": False, "lateReplyFromKilledHostProven": False,
        "scope": "real signed discovery, PostgreSQL epoch fencing, unchanged desired coordinator, actual callback and drain"
    }, indent=2))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--inflight-drain", action="store_true", help="Hold a real remote offer while testing actual dispatch drain")
    parser.add_argument("--duplex-pressure", action="store_true", help="Hold real publications in both directions while control and reverse callbacks advance")
    parser.add_argument("--partition-handoff", action="store_true", help="Kill the real shard host, expire its exact lease after process exit, restart same port and observe surviving desired recovery")
    parser.add_argument("--outbox-kill", choices=("user",), help="Kill an in-flight production relay and recover it from its real PostgreSQL claim")
    parser.add_argument("--postgres-disposable-url", help="Fresh owned imv2_callback_kill_* database, loopback non-5432 port; URL kept only in private temp config")
    args = parser.parse_args()
    if sum((bool(args.outbox_kill), args.inflight_drain, args.partition_handoff, args.duplex_pressure)) > 1:
        parser.error("outbox, inflight drain, partition handoff and duplex pressure are separate probe modes")
    if bool(args.outbox_kill or args.partition_handoff) != bool(args.postgres_disposable_url):
        parser.error("outbox or partition handoff requires --postgres-disposable-url, used only in those modes")
    binary = args.binary.resolve()
    evidence = args.evidence.resolve()
    if not binary.is_file():
        raise SystemExit("--binary must be an already-built VirtualActorBusinessProbe")
    evidence.mkdir(parents=True, exist_ok=False)
    postgres = DisposablePostgres(args.postgres_disposable_url) if args.outbox_kill or args.partition_handoff else None
    topic_id = str(uuid.uuid4())
    if postgres:
        postgres.prepare(args.outbox_kill or "room", topic_id)
    with tempfile.TemporaryDirectory(prefix="imv2-realtime-callback-secrets-") as temporary:
        secrets = Path(temporary)
        command("openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
                "-nodes", "-days", "1", "-subj", "/CN=imv2-callback-ca", "-addext",
                "basicConstraints=critical,CA:TRUE", "-keyout", str(secrets / "ca.key"),
                "-out", str(secrets / "ca.pem"))
        extension = secrets / "extension.cnf"
        extension.write_text("subjectAltName=DNS:localhost\nextendedKeyUsage=serverAuth,clientAuth\n")
        public_keys = {}
        for role in ("receiver", "sender"):
            command("openssl", "req", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes",
                    "-subj", "/CN=localhost", "-keyout", str(secrets / f"{role}.key"),
                    "-out", str(secrets / f"{role}.csr"))
            command("openssl", "x509", "-req", "-in", str(secrets / f"{role}.csr"), "-CA",
                    str(secrets / "ca.pem"), "-CAkey", str(secrets / "ca.key"), "-CAcreateserial",
                    "-days", "1", "-extfile", str(extension), "-out", str(secrets / f"{role}.pem"))
            command("openssl", "genpkey", "-algorithm", "ED25519", "-out", str(secrets / f"{role}-sign.pem"))
            raw = command("openssl", "pkey", "-in", str(secrets / f"{role}-sign.pem"), "-outform", "DER")[-32:]
            (secrets / f"{role}-sign.raw").write_bytes(raw)
            public_keys[role] = base64.b64encode(command("openssl", "pkey", "-in", str(secrets / f"{role}-sign.pem"),
                                                        "-pubout", "-outform", "DER")[-32:]).decode()
        processes = {}
        files = []
        configs = {}
        try:
            node_ports = dict(zip(("receiver", "sender"), ports()))
            for role, port in node_ports.items():
                other = "sender" if role == "receiver" else "receiver"
                config = secrets / f"{role}.json"
                config.write_text(json.dumps({
                    "name": "realtime-" + role, "port": port, "serviceID": role, "peerServiceID": other, "peerPort": node_ports[other],
                    "signingKeyPath": str(secrets / f"{role}-sign.raw"), "peerPublicKeyBase64": public_keys[other],
                    "certificatePath": str(secrets / f"{role}.pem"), "privateKeyPath": str(secrets / f"{role}.key"),
                    "trustRootPath": str(secrets / "ca.pem"),
                    "databaseURL": args.postgres_disposable_url, "outboxKind": args.outbox_kill,
                    "topicID": topic_id if postgres else None, "partitionHandoff": args.partition_handoff
                }))
                environment = os.environ.copy()
                environment.update(VA_REALTIME_CONFIGURATION=str(config), VA_REALTIME_EVIDENCE=str(evidence),
                                   VA_REALTIME_INFLIGHT_DRAIN="1" if args.inflight_drain else "0",
                                   VA_REALTIME_DUPLEX_PRESSURE="1" if args.duplex_pressure else "0")
                log = open(evidence / f"{role}.log", "wb")
                files.append(log)
                configs[role] = (config, environment)
                processes[role] = subprocess.Popen([str(binary), "realtime-" + role], env=environment,
                                                     stdout=log, stderr=subprocess.STDOUT)
            if args.partition_handoff:
                recover_partition_host(processes=processes, files=files, configs=configs, args=args,
                                       evidence=evidence, postgres=postgres)
            elif postgres:
                recover_killed_publisher(processes=processes, files=files, configs=configs, args=args,
                                         evidence=evidence, postgres=postgres, topic_id=topic_id)
            deadline = time.monotonic() + 60
            while any(process.poll() is None for process in processes.values()):
                failed = {name: process.returncode for name, process in processes.items()
                          if process.returncode is not None and process.returncode != 0}
                if failed:
                    raise RuntimeError(f"callback probe failed {failed}; logs in {evidence}")
                if time.monotonic() > deadline:
                    raise TimeoutError(f"callback probe exceeded 60 seconds; logs in {evidence}")
                time.sleep(0.1)
            if any(process.returncode for process in processes.values()):
                raise RuntimeError(f"callback process failed; logs in {evidence}")
            receiver = json.loads((evidence / ("duplex-b-result.json" if args.duplex_pressure else "receiver-result.json")).read_text())
            sender = json.loads((evidence / ("duplex-a-result.json" if args.duplex_pressure else "sender-result.json")).read_text())
            if args.duplex_pressure:
                required = ("realTwoProcessRPC", "mutualSignedQualification", "renewedDuringPressure",
                            "subscriptionUpdatedDuringPressure", "reverseCallbackDuringPressure",
                            "cancelRetainedLocalInvocation", "remoteMethodsActuallySettled", "repeatedDrain",
                            "remoteTimeoutIsNotRemoteCompletion", "signedRemoteBackpressureReply",
                            "nonCapacityFailureNotConverted", "localPredispatchPeerBackpressure")
                for role, result in (("receiver", receiver), ("sender", sender)):
                    assert all(result.get(field) is True for field in required), (role, result)
                    assert result.get("postgresLeaseAdmissionTest") is False, (role, result)
                    for field, expected in (("publishPeerCeiling", 2), ("controlPeerCeiling", 2),
                                            ("heldPublicationsEachDirection", 2), ("localControlStarted", 3),
                                            ("localControlSettled", 3), ("localPublishStarted", 4),
                                            ("localPublishSettled", 4)):
                        assert result.get(field) == expected, (role, field, result)
                (evidence / "duplex-pressure-result.json").write_text(json.dumps({
                    "passed": True, "actualChildExitCodes": {role: process.returncode for role, process in processes.items()},
                    "receiver": receiver, "sender": sender}, indent=2))
            elif args.partition_handoff:
                assert all(receiver.get(key) is True for key in ("higherEpoch", "newIncarnation", "oldLeaseRenewRejected", "actualLeaseReleased")), receiver
                assert all(sender.get(key) is True for key in ("singleDesiredActivation", "automaticDesiredRecovery", "lostCoverageObserved", "freshHeadBarrier", "oldDeliveryRejected", "oldReferenceRejectedBeforeDispatch", "actualDrain")), sender
                assert sender["hotAcceptedCallbacks"] == 10_000 and sender["hotCacheHits"] >= 10_000 and sender["hotCacheMisses"] == 0 and sender["hotCacheInvalidations"] == 0 and sender["hotForegroundReceptionistLookups"] == 0 and sender["perCallReceptionistMeasured"] is True
                assert sender["productionControllerUsed"] is False and sender["fabricatedLateReply"] is False
                initial = json.loads((evidence / "gateway-before-kill.json").read_text())
                rebuilt = json.loads((evidence / "gateway-rebuilt.json").read_text())
                successor = json.loads((evidence / "host-installed-successor.json").read_text())
                assert rebuilt["token"] == successor and successor["epoch"] > initial["token"]["epoch"]
                assert rebuilt["sessionID"] != initial["sessionID"] and rebuilt["interestGeneration"] > initial["interestGeneration"]
                assert postgres.query("SELECT count(*) FROM im_v2.realtime_partition_leases WHERE expires_at>clock_timestamp()") == "0", "partition lease remained active after stop"
                (evidence / "partition-handoff-result.json").write_text(json.dumps({"passed": True, "initial": initial, "rebuilt": rebuilt, "receiver": receiver, "sender": sender}, indent=2))
            elif postgres:
                assert receiver == {"accepted": 2, "callerOnly": True, "mtls": True, "fencedRegistration": True}, receiver
                assert sender == {"claimed": 1, "published": 1, "retryScheduled": 0, "productionRelay": True}, sender
                final = postgres.snapshot(args.outbox_kill, topic_id)
                assert final["facts"] == final["head"] == 1 and final["wakeCount"] == 0, final
                assert postgres.query("SELECT count(*) FROM im_v2.realtime_partition_leases WHERE expires_at>clock_timestamp()") == "0", "receiver partition lease remained active after stop"
                (evidence / "outbox-recovery-result.json").write_text(json.dumps({"passed": True,
                    "kind": args.outbox_kill, "final": final, "scope": "durable notification, not full App body commit"}, indent=2))
            elif args.inflight_drain:
                assert receiver == {"accepted": 1, "callerOnly": True, "mtls": True, "controlledOfferCompleted": True}, receiver
                assert sender == {"journalAdmissionRejected": True, "mixedCallbackAdmissionRejected": True, "inflightStopTimedOut": True, "newCallsRejected": True,
                                  "dispatchCompleted": True, "finalDrainCompleted": True}, sender
            else:
                assert receiver == {"accepted": 32, "callerOnly": True, "mtls": True}, receiver
                assert all(sender[field] for field in ("ownerRejected", "oldIncarnationRejected", "closedRejected")), sender
                assert sender["concurrentCalls"] == 32, sender
            print(json.dumps({"passed": True, "evidence": str(evidence), "receiver": receiver, "sender": sender}))
        finally:
            for process in processes.values():
                if process.poll() is None:
                    process.terminate()
            for process in processes.values():
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            for handle in files:
                handle.close()


if __name__ == "__main__":
    main()
