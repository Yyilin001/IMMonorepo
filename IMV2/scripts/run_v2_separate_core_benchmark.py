#!/usr/bin/env python3
"""Run the 50k separate-Core, two-Gateway Release benchmark in an isolated Compose project."""

import argparse
import concurrent.futures
import csv
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import time
import uuid
from collections import Counter
from copy import copy
from pathlib import Path
from types import SimpleNamespace

from run_v2_actor_realtime_benchmark import (
    CANDIDATE_WIRE_VERSION,
    account_env,
    configure_topology,
    gateway_env,
    merge_latency_histograms,
    seed,
    summarize,
    verify_fixture,
    verify_foreground_cursors,
)
from run_v2_actor_realtime_benchmark import (
    private_json_snapshot as save,
)

from summarize_v2_send_traces import stage_summary

SCRIPTS = Path(__file__).resolve().parent
REPO = SCRIPTS.parents[1]
ASSETS = REPO / "IMV2/load-scenarios/separate-core"
USER = "imv2_sim"
IMAGE = "improject-facade-ci-tools:latest"


def window_ack_rate(phases):
    return sum(
        p["messagesAcknowledged"] / p["observedDurationSeconds"]
        for p in phases
        if p["observedDurationSeconds"] > 0
    )


def retry_wait_at_p99(cohorts, histogram):
    """Use the same ACK cohort and 1ms bucket as the merged end-to-end P99."""
    if not histogram or not histogram["count"] or any(
        "retryWaitByEndToEndMillisecond" not in cohort for cohort in cohorts
    ):
        return None
    lower = histogram["p99"]
    acknowledgements = 0
    waits = Counter()
    for cohort in cohorts:
        for bucket in cohort["messageEndToEndLatency"]["histogramBuckets"]:
            if bucket["lowerBoundMilliseconds"] == lower:
                acknowledgements += bucket["count"]
        waits.update(cohort["retryWaitByEndToEndMillisecond"].get(str(lower), {}))
    if not acknowledgements:
        return None
    return {
        "lowerBoundMilliseconds": lower,
        "upperBoundExclusiveMilliseconds": histogram["p99UpperBoundExclusiveMilliseconds"],
        "acknowledged": acknowledgements,
        "retried": waits["operations"],
        "withServerBusy": waits["withServerBusy"],
        "withDeferred": waits["withDeferred"],
        "meanServerBusyWaitMilliseconds": round(waits["busyMilliseconds"] / acknowledgements, 3),
        "meanDeferredWaitMilliseconds": round(waits["deferredMilliseconds"] / acknowledgements, 3),
        "meanOtherRetryWaitMilliseconds": round(waits["otherMilliseconds"] / acknowledgements, 3),
    }


def phase_summary(reports, name, target, duration, queue_limit):
    by_loader = [{p["name"]: p for p in report["scenarioPhases"]} for report in reports]
    phases = [p[name] for p in by_loader if name in p]
    cohorts = [r["messageSendCohorts"].get(name, {}) for r in reports]
    if not phases:
        return None
    scheduled = sum(p["scenarioMessagesScheduled"] for p in phases)
    acknowledged = sum(p["messagesAcknowledged"] for p in phases)
    cohort_acked = sum(c.get("messagesAcknowledged", 0) for c in cohorts)
    cohort_sent = sum(c.get("messagesSent", 0) for c in cohorts)
    start = max(p["startedAtUnixMilliseconds"] for p in phases) / 1000
    end = min(p["endedAtUnixMilliseconds"] for p in phases) / 1000
    complete = len(phases) == len(reports) and all(p["completed"] for p in phases)
    cohort_complete = all(
        c
        and c["messagesSent"] == c["messagesAcknowledged"]
        and c["messageEndToEndLatency"]["count"] == c["messagesSent"]
        for c in cohorts
    )
    histogram = merge_latency_histograms([c.get("messageEndToEndLatency", {}) for c in cohorts])
    window_histogram = merge_latency_histograms([p["messageEndToEndLatency"] for p in phases])
    rate = window_ack_rate(phases)
    overflow = sum(p["scenarioMessageQueueOverflowed"] for p in phases)
    queue_end = sum(p["queuedScenarioMessagesAtEnd"] for p in phases)
    failures = sum(p["workloadFailed"] for p in phases)
    transport_events = Counter()
    for phase in phases:
        transport_events.update(phase["messageTransportEvents"])
    wire_submissions = transport_events["WIRE_SUBMIT"]
    deferred = {name: count for name, count in transport_events.items() if name.startswith("DEFERRED_")}
    rejected = {name: count for name, count in transport_events.items() if name.startswith("SERVER_REJECTED_")}
    p99_upper = histogram and histogram["p99UpperBoundExclusiveMilliseconds"]
    return {
        "name": name,
        "target": target,
        "scheduled": scheduled,
        "windowSent": sum(p["messagesSent"] for p in phases),
        "windowAcked": acknowledged,
        "ackPerSecond": round(rate, 2),
        "cohortSent": cohort_sent,
        "cohortAcked": cohort_acked,
        "cohortComplete": cohort_complete,
        "sendWireSubmissions": wire_submissions,
        "sendDeferrals": deferred,
        "sendServerRejections": rejected,
        "cohortLatency": histogram,
        "retryWaitAtCohortP99": retry_wait_at_p99(cohorts, histogram),
        "windowLatency": window_histogram,
        "ackLatencyAfterSend": merge_latency_histograms([c.get("messageLatency", {}) for c in cohorts]),
        "syncPullLatency": merge_latency_histograms([p["syncPullLatency"] for p in phases]),
        "syncWireRetries": sum(p["syncRetryAttempts"] for p in phases),
        "roomReadRetryableRejections": sum(p["roomEventPullRetryableRejections"] for p in phases),
        "overflow": overflow,
        "endQueue": queue_end,
        "failures": failures,
        "syncFailures": sum(p["syncLogicalFailures"] for p in phases),
        "heartbeatsMissed": sum(p["heartbeatMissed"] for p in phases),
        "commonWindowSeconds": round(max(0, end - start), 3),
        "startTime": start,
        "endTime": end,
        "complete": complete,
        "meetsSendSLO": (
            complete
            and end - start >= 0.9 * duration
            and abs(scheduled / duration - target) <= 0.005 * target
            and abs(rate - target) <= 0.005 * target
            and cohort_complete
            and cohort_acked == scheduled
            and wire_submissions == sum(p["messagesSent"] for p in phases)
            and not any(deferred.values())
            and not any(rejected.values())
            and 0 < (p99_upper or 0) <= 100
            and not overflow
            and not failures
            and queue_end <= queue_limit
        ),
    }


def run(cmd, **kwargs):
    return subprocess.run(list(map(str, cmd)), check=True, **kwargs)


def read(path):
    return json.loads(path.read_text())


def volume(src, dst, writable=False):
    return {"type": "bind", "source": str(src), "target": dst, "read_only": not writable}


def schema_sql(db, statement):
    return db(
        "exec",
        "-T",
        "postgres",
        "psql",
        "-XAt",
        "-v",
        "ON_ERROR_STOP=1",
        "-d",
        db.database,
        "-U",
        USER,
        "-c",
        statement,
        capture_output=True,
        text=True,
        timeout=8,
    ).stdout.strip()


class Run:
    def __init__(self, options):
        self.dir = options.output_dir.resolve()
        self.runtime = options.runtime.resolve()
        self.trace_sends = options.trace_sends
        self.context = ["docker", "--context", options.context]
        self.pg_port = options.pg_port
        self.prefix = f"10.{options.subnet_octet}."
        label = uuid.uuid4().hex[:12]
        rates = options.rates
        population = 50000
        self.dir.mkdir(parents=True, mode=0o700)
        self.project = "imv2-perf-" + label
        self.database = "imv2_va_perf_" + label.replace("-", "_")
        self.population = population
        self.rates = rates
        self.core_write_connections = options.core_write_connections
        self.core_cross_room_limit = options.core_cross_room_limit
        self.core_policy_connections = options.core_policy_connections
        self.cpu_overrides = {
            "room-core": options.core_cpus,
            "postgres": options.postgres_cpus,
            "gateway-0": options.gateway_cpus,
            "gateway-1": options.gateway_cpus,
            "ingress": options.ingress_cpus,
        }
        self.sync_connections = int(os.environ.get("IMV2_PERF_SYNC_CONNECTIONS", "2"))
        self.front = self.prefix + "42."
        self.back = self.prefix + "43."
        self.parts = 6
        self.fixture = options.fixture.resolve()
        self.manifest = verify_fixture(self.fixture)
        if self.manifest["users"] != population or self.manifest["foregroundTopology"] != "paired-adjacent":
            raise ValueError("expected 50,000 paired foreground viewers")
        for binary in ("IMV2ServerApp", "IMV2AccountServerApp", "IMV2GatewayLoadGenerator"):
            if not (self.runtime / binary).is_file():
                raise FileNotFoundError(self.runtime / binary)
        self.args = SimpleNamespace(
            output_dir=self.dir,
            fixture=self.fixture,
            pg_port=self.pg_port,
            pg_host="127.0.0.1",
            pg_user=USER,
            single_core=True,
            server_deployment=None,
            baseline_checkout=None,
            gateway_port=7443,
            metrics_port=9660,
            account_port=8444,
            candidate_message_write_connections=8,
            candidate_event_loop_threads=4,
            candidate_tcp_event_loop_threads=2,
            candidate_send_path_trace_mode="sampled" if self.trace_sends else "off",
            server_log_level="notice" if self.trace_sends else "error",
        )
        configure_topology(2, self.parts)
        self.config = self.dir / "compose.json"
        self.loaders = [f"load-{i}" for i in range(self.parts)]
        self.password = secrets.token_hex(24)

    def __call__(self, *args, **kwargs):
        return run([*self.context, "compose", "--project-name", self.project, "-f", self.config, *args], **kwargs)

    def envfile(self, node, env, dburl):
        keys = {k: v for k, v in env.items() if k.startswith(("IM_V2_", "IMV2_ROOM_"))}
        keys.update(
            IM_V2_DATABASE_URL=dburl,
            IMV2_ROOM_ACTOR_CONFIGURATION_FILE="/run/imv2/actor/configuration.json",
            IM_V2_ROOM_SHARD_STORES_JSON=json.dumps(
                [{"shard_id": self.manifest["shardID"], "database_url": dburl, "schema": "im_v2"}]
            ),
            IM_V2_USER_SHARD_STORES_JSON=json.dumps(
                [{"bucket": self.manifest["userBucket"], "database_url": dburl, "schema": "im_v2"}]
            ),
        )
        (self.dir / f"{node}.env").write_text("".join(f"{k}={v}\n" for k, v in sorted(keys.items())))
        return keys

    def prepare(self):
        actors = self.dir / "actors"
        with (self.dir / "prepare.log").open("w") as log:
            run(
                [sys.executable, SCRIPTS / "prepare_local_edge_tls.py", self.dir / "edge-certificate"],
                stdout=log,
                stderr=subprocess.STDOUT,
            )
            provision = [
                sys.executable,
                SCRIPTS / "prepare_v2_room_actor_configuration.py",
                "--single-core",
                "--shards",
                self.manifest["shardID"],
                "--user-buckets",
                self.manifest["userBucket"],
                "--maximum-rooms-per-host",
                str(max(10000, (5 * self.manifest["rooms"] + 3) // 4)),
                "--mount-root",
                "/run/imv2/actor",
                "--host",
                "room-core=room-core:7337",
                "--gateway",
                "gateway-0=gateway-0:7337",
                "--caller",
                "account=account:7338",
            ]
            run([*provision, "--output-dir", actors], stdout=log, stderr=subprocess.STDOUT)
            expanded = self.dir / "expanded"
            run(
                [
                    *provision,
                    "--output-dir",
                    expanded,
                    "--extend-from",
                    actors,
                    "--gateway",
                    "gateway-1=gateway-1:7337",
                ],
                stdout=log,
                stderr=subprocess.STDOUT,
            )
            shutil.copytree(expanded / "gateway-1", actors / "gateway-1")
        password_path = self.dir / "postgres-password"
        password_path.write_text(self.password + "\n")
        dburl = f"postgresql://{USER}:{self.password}@postgres:5432/{self.database}?sslmode=disable"
        config = json.loads((ASSETS / "compose.json").read_text().replace("10.78.", self.prefix))
        services = config["services"]
        for node, cpus in self.cpu_overrides.items():
            if cpus is not None:
                services[node]["cpus"] = cpus
        shutil.copyfile(SCRIPTS / "v2_benchmark_https_edge.py", self.dir / "https.py")
        for service in services.values():
            for mount in service["volumes"]:
                if not isinstance(mount, dict):
                    continue
                if mount["target"] == "/run/imv2/bin":
                    mount["source"] = str(self.runtime)
        ha = (ASSETS / "haproxy.cfg").read_text().replace("10.78.", self.prefix)
        (self.dir / "haproxy.cfg").write_text(ha)
        (self.dir / "haproxy.cfg").chmod(0o644)
        if self.trace_sends:
            services["postgres"]["command"].extend(
                ["-c", "track_wal_io_timing=on", "-c", "track_io_timing=on", "-c", "shared_preload_libraries=pg_stat_statements"]
            )
        services["postgres"]["ports"] = [f"127.0.0.1:{self.pg_port}:5432"]

        env = account_env(self.args, "candidate", self.database, actors, self.manifest)
        a = self.envfile("account", env, dburl)
        save(
            self.dir / "https.json",
            {
                "listenPort": 8443,
                "upstreamPort": 8444,
                "listenHost": "0.0.0.0",
                "upstreamHost": "127.0.0.1",
                "certificate": "/run/imv2/client-tls/leaf.pem",
                "key": "/run/imv2/client-tls/leaf.key",
                "edgeAuthorizationSecret": a["IM_V2_ACCOUNT_EDGE_AUTHORIZATION_SECRET_BASE64"],
                "maximumUpstreamConnections": 128,
            },
        )
        for node, i in [("room-core", 0), ("gateway-0", 0), ("gateway-1", 1)]:
            node_args = copy(self.args)
            if node == "room-core":
                node_args.candidate_message_write_connections = self.core_write_connections
            else:
                node_args.candidate_sync_connections = self.sync_connections
            app = gateway_env(node_args, "candidate", self.database, i, actors, self.manifest)
            app.update(
                IM_V2_GATEWAY_NODE_ID=node,
                IM_V2_TLS_HOST="127.0.0.1" if node == "room-core" else "0.0.0.0",
                IM_V2_TLS_PORT="7443",
                IM_V2_TLS_CERTIFICATE_CHAIN_PATH="/run/imv2/client-tls/leaf.pem",
                IM_V2_TLS_PRIVATE_KEY_PATH="/run/imv2/client-tls/leaf.key",
                IM_V2_METRICS_HOST="127.0.0.1",
                IM_V2_METRICS_PORT="9660",
                IM_V2_MAX_CONNECTIONS=str(32000),
                IM_V2_RATE_LIMIT_MAX_TRACKED_IDENTITIES=str(2 * self.population),
                IM_V2_IDLE_TIMEOUT_MS="1800000",
            )
            if node == "room-core":
                app["IM_V2_MESSAGE_WRITE_CROSS_ROOM_LIMIT"] = str(self.core_cross_room_limit)
                app["IM_V2_DATABASE_POLICY_CONTROL_CONNECTIONS_PER_EVENT_LOOP"] = str(self.core_policy_connections)
            self.envfile(node, app, dburl)

        template = read(REPO / "IMV2/load-scenarios/single-room-core-baseline-3000.json")
        specs = (
            [("warm", 25, 100)]
            + [(f"rate-{rate}", int(os.environ.get("IMV2_PERF_STAGE_SECONDS", "60")), rate) for rate in self.rates]
            + [("recover", 35, 50)]
        )
        template.update(
            name="single-core-separated-haproxy-" + str(self.population),
            requiresSteadyStateDrain=False,
            roomWarmupTimeoutSeconds=900,
            completionDrainSeconds=60,
            postDrainHoldSeconds=int(os.environ.get("IMV2_PERF_DRAIN_HOLD_SECONDS", "10")),
        )
        template["phases"] = [
            dict(template["phases"][0], name=n, durationSeconds=seconds, messagesPerSecond=rate)
            for n, seconds, rate in specs
        ]
        save(self.dir / "scenario.json", template)
        flags = {
            "--benchmark-wire-version": str(CANDIDATE_WIRE_VERSION),
            "--server-name": "localhost",
            "--revision": "candidate",
            "--hold-seconds": "60",
            "--event-loops": "1",
            "--messages-per-second": "0",
            "--recovery-burst-workers": "128",
            "--max-inflight-messages-per-connection": "4",
            "--message-bytes": "128",
            "--targets-per-connection": "2",
            "--sync-reads": "1",
            "--room-log-reads": "1",
            "--room-log-initial-cursor": "tail",
            "--room-log-read-trigger": "availability_hint",
            "--peer-topology": "ring",
        }
        lines = (self.fixture / "credentials.jsonl").read_text().splitlines(True)
        self.counts = []
        for i, name in enumerate(self.loaders):
            part = lines[i :: self.parts]
            self.counts.append(len(part))
            (self.dir / f"part-{i}.jsonl").write_text("".join(part))
            opts = dict(flags)
            opts.update(
                {
                    "--host": self.front + "12",
                    "--port": "7443",
                    "--account-base-url": "https://account:8443",
                    "--ca-path": "/run/imv2/client-tls/root.crt",
                    "--credentials": f"/output/part-{i}.jsonl",
                    "--report": f"/output/report-{i}.json",
                    "--connections": str(len(part)),
                    "--scenario": "/output/scenario.json",
                    "--scenario-rate-scale": str(len(part) / self.population),
                    "--scenario-ready-path": f"/output/part-{i}-ready.json",
                    "--scenario-start-barrier-path": "/output/barrier.json",
                    "--max-rss-mb": "1050",
                    "--max-failure-percent": "100",
                    "--ramp-per-second": os.environ.get("IMV2_PERF_CONNECT_RAMP", "60"),
                    "--workload-ramp-per-second": os.environ.get("IMV2_PERF_WARM_RAMP", "80"),
                    "--ramp-batch-size": "8",
                }
            )
            command = [
                "/run/imv2/bin/IMV2GatewayLoadGenerator",
                *[item for k, v in opts.items() for item in (k, str(v))],
            ]
            services[name] = {
                "image": IMAGE,
                "init": True,
                "entrypoint": command,
                "mem_limit": "1250m",
                "ulimits": {"nofile": {"soft": 40000, "hard": 40000}},
                "volumes": [
                    volume(self.runtime, "/run/imv2/bin"),
                    volume(self.dir / "edge-certificate/tls", "/run/imv2/client-tls"),
                    volume(self.dir, "/output", True),
                ],
                "networks": ["frontend-fixed"],
                "extra_hosts": {"account": self.front + "13"},
                "logging": {"driver": "json-file", "options": {"max-size": "12m", "max-file": "2"}},
            }
        save(self.config, config)
        save(
            self.dir / "setup.json",
            {
                "population": self.population,
                "clientsPerPartition": self.counts,
                "warmupRatePerLoader": int(os.environ.get("IMV2_PERF_WARM_RAMP", "80")),
                "syncConnectionsPerGateway": self.sync_connections,
                "writeConnections": self.core_write_connections,
                "coreCrossRoomMessageLimit": self.core_cross_room_limit,
                "corePolicyConnectionsPerEventLoop": self.core_policy_connections,
                "dockerHostCPUs": json.loads(
                    run(
                        [*self.context, "info", "--format", "{{json .NCPU}}"], capture_output=True, text=True
                    ).stdout
                ),
                "roomCore": {"cpus": services["room-core"]["cpus"], "memory": services["room-core"]["mem_limit"]},
                "gatewayEach": {"cpus": services["gateway-0"]["cpus"], "memory": services["gateway-0"]["mem_limit"]},
                "postgres": {"cpus": services["postgres"]["cpus"], "memory": services["postgres"]["mem_limit"]},
                "haproxy": {"cpus": services["ingress"]["cpus"], "memory": services["ingress"]["mem_limit"]},
                "endpoints": {
                    "ingress": self.front + "12",
                    "core": self.back + "10",
                    "postgres": self.back + "14",
                },
                "load": specs,
                "platform": "One shared Docker host, separate front/back networks",
            },
        )
        self("config", "--services")
        self("up", "-d", "--wait", "postgres")
        os.environ["PGPASSWORD"] = self.password
        seed(self.args, "candidate", self.database, self.dir, self.manifest)
        if self.trace_sends:
            schema_sql(self, "CREATE EXTENSION IF NOT EXISTS pg_stat_statements")
        pg = schema_sql(
            self,
            "SELECT json_build_object('fsync',current_setting('fsync'),'synchronousCommit',current_setting('synchronous_commit'),'sharedBuffers',current_setting('shared_buffers'),'maxWalSize',current_setting('max_wal_size'),'walCompression',current_setting('wal_compression'),'fullPageWrites',current_setting('full_page_writes'),'version',current_setting('server_version'));",
        )
        save(self.dir / "postgres-settings.json", json.loads(pg))
        print(f"Seeded isolated fixture with {self.population:,} clients", flush=True)

    def metric(self, name):
        script = "from urllib.request import urlopen; print(urlopen('http://127.0.0.1:9660/metrics',timeout=3).read().decode())"
        raw = self("exec", "-T", name, "python3", "-c", script, capture_output=True, text=True, timeout=8).stdout

        def value(key):
            match = re.search("^" + re.escape(key) + " ([^\n ]+)$", raw, re.MULTILINE)
            return float(match[1]) if match else None

        keys = {
            "active": "im_v2_gateway_active_connections",
            "durableMetricsAvailable": "im_v2_durable_work_metrics_available",
            "nodeRevocationsPending": "im_v2_device_revocation_events_pending",
            "projectionCleanupPending": "im_v2_revoked_device_projection_cleanup_events_pending",
            "partitions": "im_v2_actor_realtime_installed_partitions",
            "reachableNodes": "im_v2_actor_realtime_reachable_nodes",
            "queuedTurns": "im_v2_send_operation_owner_queued_turns",
            "executingWrites": 'im_v2_message_write_workers{state="executing"}',
            "idleWrites": 'im_v2_message_write_workers{state="idle"}',
            "activeRooms": "im_v2_room_actor_active_rooms",
            "retiringRooms": "im_v2_room_actor_retiring_rooms",
            "idleRetirements": "im_v2_room_actor_completed_idle_retirements_total",
        }
        result = {k: value(v) for k, v in keys.items()}
        sync = result["sync"] = {}
        for line in raw.splitlines():
            if line.startswith('im_v2_database_loan_observation_stage_duration_') and '{source="policy_snapshot",' in line:
                label, count = line.rsplit(" ", 1)
                result.setdefault("policySnapshotLoans", {})[label] = float(count)
            if line.startswith('im_v2_send_operation_store_cross_room_commits_total{rooms="'):
                label, count = line.rsplit(" ", 1)
                rooms = label.split('"')[1]
                result.setdefault("commitsByRooms", {})[rooms] = int(count)
            if (
                line.startswith("im_v2_database_work_")
                and 'class="sync"' in line
                or line.startswith("im_v2_gateway_commands_total{")
                and ('command="sync_pull"' in line or 'command="sync_ack"' in line)
                or line.startswith("im_v2_sync_wake_")
                or line.startswith("im_v2_database_loan_")
                and ('class="sync"' in line or 'source="sync"' in line)
            ):
                key, value = line.rsplit(" ", 1)
                sync[key] = float(value)
            if line.startswith(("im_v2_gateway_message_operation_internal_failures_total{",
                                "im_v2_gateway_message_send_rejected_total{",
                                "im_v2_actor_transport_rpc_rejections_total{")):
                key, val = line.rsplit(" ", 1)
                if int(val):
                    result.setdefault("sendFailures", {})[key] = int(val)
            if line.startswith(
                (
                    "im_v2_room_subscription_owner_failures_total{",
                    "im_v2_room_subscription_acquisition_outcomes_total{",
                    "im_v2_room_subscription_head_delivery_total{",
                    "im_v2_actor_realtime_sender_capacity_rejected_total{",
                )
            ):
                key, val = line.rsplit(" ", 1)
                count = int(val)
                if count:
                    result.setdefault("subscription", {})[key] = count
        return result

    def haproxy(self):
        script = (
            "from urllib.request import urlopen; print(urlopen('http://"
            + self.front
            + "12:9661/stats;csv',timeout=3).read().decode())"
        )
        raw = self(
            "exec", "-T", "gateway-0", "python3", "-c", script, capture_output=True, text=True, timeout=8
        ).stdout
        rows = csv.DictReader(raw.removeprefix("# ").splitlines())
        return {
            r["svname"]: {
                k: (int(r[k]) if k in ("scur", "stot") and r.get(k) else r.get(k))
                for k in ("status", "scur", "stot", "econ", "eresp")
            }
            for r in rows
            if r.get("pxname") == "gateways" and r.get("svname", "").startswith("gateway-")
        }

    def wait_for_metrics(self, name, partition_count):
        until = time.monotonic() + 55
        while time.monotonic() < until:
            try:
                sample = self.metric(name)
                if sample["partitions"] == partition_count:
                    if sample["nodeRevocationsPending"] is None:
                        raise RuntimeError(f"{name} is missing its local device-revocation metric")
                    exports_global_metrics = sample["projectionCleanupPending"] is not None
                    if exports_global_metrics != (name == "room-core"):
                        raise RuntimeError(f"{name} exports unexpected durable-work metrics for its role")
                    if sample["durableMetricsAvailable"] == 1:
                        return
            except (subprocess.SubprocessError, OSError):
                pass
            time.sleep(0.6)
        raise TimeoutError(name + " did not become ready")

    def services_ready(self):
        self("up", "-d", "room-core")

        self.wait_for_metrics("room-core", 256)
        self("up", "-d", "gateway-0", "account", "https-edge", "ingress")
        self.wait_for_metrics("gateway-0", 0)
        # HAProxy initially assumes both configured servers are available. Wait
        # for checks to mark the absent Gateway down before the first TLS client.
        deadline = time.monotonic() + 45
        tls_probe = (
            "import socket,ssl; ctx=ssl.create_default_context(cafile='/run/imv2/client-tls/root.crt'); "
            "ctx.wrap_socket(socket.create_connection(('account',8443),3),server_hostname='account').close()"
        )
        while time.monotonic() < deadline:
            try:
                backends = self.haproxy()
                if backends["gateway-0"]["status"] == "UP" and backends["gateway-1"]["status"] == "DOWN":
                    self("exec", "-T", "gateway-0", "python3", "-c", tls_probe, capture_output=True, timeout=6)
                    break
            except (subprocess.SubprocessError, OSError, KeyError):
                pass
            time.sleep(0.5)
        else:
            raise TimeoutError("first Gateway and account HTTPS edge did not pass readiness")
        self("up", "-d", self.loaders[0])
        deadline = time.monotonic() + 90
        while self.metric("gateway-0")["active"] < 1:
            if time.monotonic() > deadline:
                raise TimeoutError("no authenticated connection before Gateway extension")
            time.sleep(1)
        writer_query = "SELECT json_build_array(epoch,incarnation)::text FROM im_v2.room_core_writer"
        writer_before = schema_sql(self, writer_query)
        initial_ids = self("ps", "-q", "gateway-0", "room-core", capture_output=True, text=True).stdout
        for node in ("room-core", "gateway-0", "account"):
            target = self.dir / "actors" / node / "configuration.json"
            shutil.copyfile(self.dir / "expanded" / node / "configuration.json", target.with_suffix(".new"))
            target.with_suffix(".new").replace(target)
        self("up", "-d", "gateway-1")
        self.wait_for_metrics("gateway-1", 0)
        writer_after = schema_sql(self, writer_query)
        same_processes = (
            initial_ids == self("ps", "-q", "gateway-0", "room-core", capture_output=True, text=True).stdout
        )
        save(
            self.dir / "live-extension.json",
            {
                "writerBefore": writer_before,
                "writerAfter": writer_after,
                "sameContainers": same_processes,
                "activeOnOriginalGateway": self.metric("gateway-0")["active"],
            },
        )
        if writer_before != writer_after or not same_processes:
            raise RuntimeError("existing Gateway or Core changed during extension")
        for name in ("gateway-0", "gateway-1"):
            self.wait_for_metrics(name, 0)
        end = time.monotonic() + 35
        while time.monotonic() < end:
            try:
                backends = self.haproxy()
                if len(backends) == 2 and all(v["status"] == "UP" for v in backends.values()):
                    return
            except (subprocess.SubprocessError, OSError):
                pass
            time.sleep(0.5)
        raise TimeoutError("HAProxy backends")

    def state(self):
        out = self("ps", "-a", "--format", "json", capture_output=True, text=True, timeout=8).stdout.strip()
        rows = json.loads(out) if out.startswith("[") else [json.loads(s) for s in out.splitlines()]
        return {r["Service"]: {"state": r["State"], "exit": r["ExitCode"]} for r in rows}

    def sample(self, executor, resources=False):
        queries = {n: executor.submit(self.metric, n) for n in ("gateway-0", "gateway-1", "room-core")}
        queries["haproxy"] = executor.submit(self.haproxy)
        append_stats = (
            "'appendExecution',(SELECT json_build_object('calls',sum(calls),'milliseconds',sum(total_exec_time)) "
            "FROM pg_stat_statements WHERE dbid=(SELECT oid FROM pg_database WHERE datname=current_database()) "
            "AND query LIKE '/* imv2_plain_direct_append */%')," if self.trace_sends else ""
        )
        queries["postgres"] = executor.submit(
            schema_sql,
            self,
            "SELECT json_build_object('writes',(SELECT n_tup_ins FROM pg_stat_user_tables WHERE schemaname='im_v2' AND relname='messages'),"
            "'walBytes',(SELECT wal_bytes FROM pg_stat_wal),'wal',(SELECT row_to_json(w) FROM pg_stat_wal w),"
            f"{append_stats}'checkpoints',(SELECT row_to_json(b) FROM pg_stat_bgwriter b),'waiting',(SELECT count(*) FROM pg_stat_activity WHERE wait_event='WALWrite'));",
        )
        if resources:

            def docker_stats():
                raw = run(
                    [*self.context, "stats", "--no-stream", "--format", "{{json .}}"],
                    capture_output=True,
                    text=True,
                    timeout=10,
                ).stdout
                return [
                    row for row in map(json.loads, raw.splitlines()) if row["Name"].startswith(self.project + "-")
                ]

            queries["containers"] = executor.submit(docker_stats)
        result = {"time": time.time()}
        for n, future in queries.items():
            try:
                value = future.result(timeout=12)
                result[n] = json.loads(value) if n == "postgres" else value
            except (OSError, ValueError, subprocess.SubprocessError, concurrent.futures.TimeoutError) as e:
                result[n] = {"error": type(e).__name__}
        with (self.dir / "samples.jsonl").open("a") as handle:
            handle.write(json.dumps(result) + "\n")
        return result

    def exercise(self):
        self("up", "-d", *self.loaders)
        print(f"Started {self.parts} Linux load generators through HAProxy", flush=True)
        started = time.monotonic()
        release = None
        stable_since = None
        stable_seconds = int(os.environ.get("IMV2_PERF_STABLE_SECONDS", "30"))
        samples = []
        workload_time = sum(p["durationSeconds"] for p in read(self.dir / "scenario.json")["phases"])
        last_sample = 0
        peak = 0
        unsustained = 0
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as executor:
            while True:
                elapsed = time.monotonic() - started
                state = self.state()
                load_states = [state.get(name, {}).get("state") for name in self.loaders]
                stopped = all(s in ("exited", "dead") for s in load_states)
                if stopped or (release is None and any(s in ("exited", "dead") for s in load_states)):
                    save(self.dir / "workload-states.json", state)
                    if release is None:
                        raise RuntimeError("load generator exited before the measurement barrier")
                    return
                if any(
                    state.get(name, {}).get("state") != "running"
                    for name in (
                        "room-core",
                        "gateway-0",
                        "gateway-1",
                        "ingress",
                        "postgres",
                        "account",
                        "https-edge",
                    )
                ):
                    save(self.dir / "workload-states.json", state)
                    raise RuntimeError("one of the benchmark servers stopped")
                if elapsed - last_sample >= 8 or not samples:
                    sample = self.sample(executor, resources=not samples or len(samples) % 3 == 0)
                    samples.append(sample)
                    last_sample = elapsed
                    active = [sample.get(n, {}).get("active") for n in ("gateway-0", "gateway-1")]
                    if all(isinstance(x, (int, float)) for x in active):
                        count = sum(active)
                        peak = max(peak, count)
                        unsustained = (
                            unsustained + 1 if peak >= self.population * 0.97 and count < peak * 0.98 else 0
                        )
                    if release is None and unsustained >= 3:
                        save(
                            self.dir / "warmup-failure.json",
                            {
                                "peakConnections": peak,
                                "lastActive": sum(active),
                                "reason": "Authenticated peers disconnected before room warmup completed",
                            },
                        )
                        raise RuntimeError("clients disconnected before the room warmup barrier")
                    if len(samples) % 3 == 1:
                        print(
                            "elapsed",
                            round(elapsed),
                            "gateways",
                            *[sample.get(n, {}).get("active") for n in ("gateway-0", "gateway-1")],
                            "PG inserted",
                            sample.get("postgres", {}).get("writes"),
                            flush=True,
                        )
                if release is None and all(
                    (self.dir / f"part-{i}-ready.json").exists() for i in range(self.parts)
                ):
                    values = [read(self.dir / f"part-{i}-ready.json") for i in range(self.parts)]
                    if [row["activeConnections"] for row in values] != self.counts:
                        raise RuntimeError("load partitions did not authenticate their full population")
                    proof = self.sample(executor)
                    gateways = [proof.get(f"gateway-{i}", {}) for i in range(2)]
                    observed = [gateway.get("active") for gateway in gateways]
                    backends = proof.get("haproxy", {})
                    if observed != [self.population // 2] * 2 or any(
                        backends.get(f"gateway-{i}", {}).get("scur") != self.population // 2 for i in range(2)
                    ):
                        stable_since = None
                    elif stable_since is None:
                        stable_since = time.monotonic()
                        print(
                            f"All {self.population:,} subscriptions warm; measuring {stable_seconds}s stability before sending",
                            flush=True,
                        )
                    if stable_since is not None and time.monotonic() - stable_since >= stable_seconds:
                        proof["preSendStableSeconds"] = round(time.monotonic() - stable_since, 2)
                        save(self.dir / "online-proof.json", proof)
                        release = time.time() + 3
                        save(self.dir / "barrier.json", {"releaseAtUnixMilliseconds": round(release * 1000)})
                        print(f"All {sum(self.counts):,} clients warm; stage barrier released", flush=True)
                if release is None and elapsed > 720:
                    raise TimeoutError("50k client warmup did not reach the barrier")
                if release is not None and time.time() > release + workload_time + 260:
                    raise TimeoutError("workload and drain exceeded allotted time")
                time.sleep(3)

    def collect(self):
        reports = []
        indexes = []
        state = self.state()
        for i, name in enumerate(self.loaders):
            path = self.dir / f"report-{i}.json"
            if path.is_file():
                indexes.append(i)
                reports.append(read(path))
        totals = summarize(
            reports,
            [state.get(n, {}).get("exit", 1) for n in self.loaders],
            self.population,
            measurement_phase=f"rate-{self.rates[0]}",
        )
        totals["reportsPresent"] = indexes
        totals["foregroundDelivery"] = verify_foreground_cursors(self.args, self.database, self.dir)
        data = read(self.dir / "scenario.json")
        rows = []
        sample_path = self.dir / "samples.jsonl"
        samples = (
            [json.loads(line) for line in sample_path.read_text().splitlines()] if sample_path.exists() else []
        )
        for p in data["phases"]:
            if not p["name"].startswith("rate-") or not reports:
                continue
            name = p["name"]
            summary = phase_summary(
                reports,
                name,
                p["messagesPerSecond"],
                p["durationSeconds"],
                data["maximumSteadyStateQueuedMessages"],
            )
            if summary:
                active = []
                for sample in samples:
                    if summary["startTime"] <= sample["time"] <= summary["endTime"]:
                        counts = [sample.get(f"gateway-{i}", {}).get("active") for i in range(2)]
                        active.append(sum(counts) if all(isinstance(n, (int, float)) for n in counts) else None)
                summary["connectionSamples"] = len(active)
                summary["allClientsOnline"] = len(active) >= 2 and all(
                    count == self.population for count in active
                )
                summary["meetsSendSLO"] = summary["meetsSendSLO"] and len(reports) == self.parts
                rows.append(summary)
        save(self.dir / "result.json", {"totals": totals, "phases": rows})
        if self.trace_sends:
            stages = stage_summary(self.dir / "send-traces.log", rows)
            for row in rows:
                points = [(s["time"], s["postgres"]["appendExecution"]) for s in samples
                          if row["startTime"] <= s["time"] <= row["endTime"]
                          and (s.get("postgres", {}).get("appendExecution") or {}).get("calls")]
                if len(points) >= 2:
                    start, end = points[0], points[-1]
                    calls = end[1]["calls"] - start[1]["calls"]
                    if calls > 0:
                        stages[row["name"]]["postgresAppendExecution"] = {
                            "sampleSeconds": round(end[0] - start[0], 2), "calls": calls,
                            "meanMilliseconds": round((end[1]["milliseconds"] - start[1]["milliseconds"]) / calls, 3),
                        }
            save(self.dir / "send-stages.json", stages)
        print(
            "Report counts", len(reports), "/", self.parts, "foreground", totals["foregroundDelivery"], flush=True
        )

    def verify_core_restart(self, previous):
        query = "SELECT json_build_object('epoch',epoch,'writer',incarnation) FROM im_v2.room_core_writer"
        if not previous["writerCleared"]:
            raise RuntimeError("Core retained its writer marker after TERM")
        self("up", "-d", "room-core")
        try:
            self.wait_for_metrics("room-core", 256)
            acquired = json.loads(schema_sql(self, query))
        finally:
            self("stop", "room-core", timeout=175)
        released = json.loads(schema_sql(self, query))
        save(
            self.dir / "restart-proof.json",
            {"before": previous, "afterRestart": acquired, "restoredPartitions": 256, "afterSecondTERM": released},
        )
        if (
            acquired["epoch"] != previous["epoch"] + 1
            or not acquired["writer"]
            or released != {"epoch": acquired["epoch"], "writer": None}
        ):
            raise RuntimeError("writer generation did not advance and drain on the same primary")

    def cleanup(self):
        here = {n for n, v in self.state().items() if v["state"] == "running"}
        for roles in [
            self.loaders,
            ["ingress"],
            ["gateway-0", "gateway-1", "https-edge", "account"],
            ["room-core"],
        ]:
            active = [n for n in roles if n in here]
            if active:
                self("stop", *active, timeout=175)
        if "postgres" in here:
            try:
                writer = schema_sql(
                    self,
                    "SELECT json_build_object('epoch',epoch,'writerCleared',incarnation IS NULL) FROM im_v2.room_core_writer",
                )
                previous = json.loads(writer)
                save(self.dir / "writer-after-stop.json", previous)
                if (self.dir / "online-proof.json").exists():
                    self.verify_core_restart(previous)
            finally:
                self("stop", "postgres", timeout=40)

    def execute(self):
        try:
            self.prepare()
            self.services_ready()
            self.exercise()
        except (RuntimeError, subprocess.SubprocessError, OSError, AssertionError) as error:
            save(self.dir / "error.json", {"kind": type(error).__name__, "message": str(error)})
            raise
        finally:
            if self.config.exists():
                if self.trace_sends:
                    with (self.dir / "send-traces.log").open("w") as output:
                        self("logs", "--no-color", "gateway-0", "gateway-1", "room-core", stdout=output)
                with (self.dir / "container.log").open("w") as log:
                    self("logs", "--tail", "100", stdout=log, stderr=subprocess.STDOUT)
                try:
                    if any((self.dir / f"report-{i}.json").exists() for i in range(self.parts)):
                        self.collect()
                finally:
                    try:
                        self.cleanup()
                    finally:
                        save(self.dir / "final-containers.json", self.state())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True, help="New private directory for this run")
    parser.add_argument("--fixture", type=Path, required=True, help="50,000-user virtual actor capacity fixture")
    parser.add_argument(
        "--runtime", type=Path, required=True, help="Linux Release binaries for the Docker host architecture"
    )
    parser.add_argument("--context", default="default")
    parser.add_argument("--pg-port", type=int, default=28532)
    parser.add_argument("--subnet-octet", type=int, choices=range(1, 255), metavar="1..254", default=92)
    parser.add_argument("--trace-sends", action="store_true", help="Collect correlated sampled send spans and PostgreSQL I/O timings")
    parser.add_argument("--rates", nargs="+", type=int, default=[1000])
    parser.add_argument("--core-write-connections", type=int, default=8,
                        help="Total physical message-write connections across the four Core database event loops")
    parser.add_argument("--core-cross-room-limit", type=int, choices=range(1, 17), default=1, metavar="1..16",
                        help="Maximum ready messages per same-shard commit without waiting to fill the batch")
    parser.add_argument("--core-policy-connections", type=int, default=4, metavar="N",
                        help="Core policy-control connections per non-message event loop")
    for name in ("core", "postgres", "gateway", "ingress"):
        parser.add_argument(f"--{name}-cpus", type=int, metavar="N", help="Override this service's CPU quota")
    os.umask(0o077)
    options = parser.parse_args()
    if not 4 <= options.core_write_connections <= 244 or options.core_write_connections % 4:
        parser.error("--core-write-connections must be a multiple of four between 4 and 244")
    if options.core_policy_connections < 1:
        parser.error("--core-policy-connections must be positive")
    if any(value is not None and value < 1 for value in (
        options.core_cpus, options.postgres_cpus, options.gateway_cpus, options.ingress_cpus
    )):
        parser.error("CPU quotas must be positive")
    benchmark = Run(options)
    benchmark.execute()
    result = read(benchmark.dir / "result.json")
    if not (
        result["totals"]["qualityPassed"]
        and result["totals"]["drained"]
        and result["totals"]["coverageProofPassed"]
        and result["totals"]["authenticated"] == benchmark.population
        and result["totals"]["foregroundDelivery"]["checkedForegroundViewers"] == benchmark.population
        and result["totals"]["foregroundDelivery"]["passed"]
        and result["totals"]["failed"] == 0
        and result["totals"]["workloadFailed"] == 0
        and len(result["phases"]) == len(benchmark.rates)
        and all(
            p["meetsSendSLO"]
            and p["allClientsOnline"]
            and not p["syncFailures"]
            and not p["syncWireRetries"]
            and not p["roomReadRetryableRejections"]
            for p in result["phases"]
        )
    ):
        sys.exit("Measurement failed the throughput, delivery or latency thresholds")
