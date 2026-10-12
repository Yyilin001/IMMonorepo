"""Isolated capacity measurement planning and phase counter arithmetic.

This module does not start containers. The runner uses the same verified binaries
and fixture as its functional canary, and writes a separate derived scenario.
"""

from __future__ import annotations

from copy import deepcopy
import hashlib
import json
import math
import re
from pathlib import Path
import statistics
import subprocess
from typing import Any


PHASES = ("warmup", "steady", "cooldown")
MEASUREMENT_SEMANTICS_VERSION = "native-placement-single-loader-phase-counters-v4"
SEND_RESOURCE_SCOPE = ("gateway", "account", "caddy", "placement-a", "placement-b", "placement-c")
FAULT_RESOURCE_SCOPE = ("gateway", "placement-a", "placement-b", "placement-c")
HARNESS_FILE_KEYS = (
    "IMV2/scripts/test_v2_virtual_actor_capacity_canary.py",
    "IMV2/scripts/virtual_actor_capacity_measurement.py",
    "IMV2/scripts/virtual_actor_capacity_lifecycle.py",
    "IMV2/scripts/virtual-actor-fixtures/capacity-main-v1.json",
)
WORKLOADS = {
    "hot": ("hot", "IMV2/scripts/virtual-actor-fixtures/capacity-hot-write-v1.json", None),
    "same-owner": ("same-owner", "IMV2/load-scenarios/direct-1500-message-only-900-server-saturation.json",
                   "ab74cd0d64d73040b7aba935cb2e0f33da32928fcdc806e3e55bf19d7e6bbfbe"),
    "mixed": ("mixed", "IMV2/load-scenarios/high-active-10000.json",
              "64c11814d90effe550f55f1affa496a8ca710c2d6a2d7fb432a844c647ce7909"),
    "cold": ("cold", "IMV2/scripts/virtual-actor-fixtures/capacity-hot-write-v1.json", None),
    "fault": ("mixed", "IMV2/load-scenarios/high-active-10000.json",
              "64c11814d90effe550f55f1affa496a8ca710c2d6a2d7fb432a844c647ce7909"),
}


class MeasurementFailure(Exception):
    pass


def resource_scope(workload: str) -> tuple[str, ...]:
    if workload not in WORKLOADS:
        raise MeasurementFailure("unknown workload resource scope")
    return FAULT_RESOURCE_SCOPE if workload == "fault" else SEND_RESOURCE_SCOPE


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def supports_recovery_loader(binary: Path, *, require_timeout: bool = False) -> bool:
    """Refuse a binary that can parse but silently ignores the new rates."""
    needles = {b"room_sync_state_batches_per_second=",
               b"room_latest_visible_batches_per_second="}
    if require_timeout:
        needles.add(b"--recovery-batch-timeout-seconds")
        needles.add(b"room_sync_state_success_rooms=")
        needles.add(b"room_latest_visible_retry_rooms=")
    overlap = max(map(len, needles)) - 1
    tail = b""
    with binary.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            block = tail + chunk
            needles = {needle for needle in needles if needle not in block}
            if not needles:
                return True
            tail = block[-overlap:]
    return False


def require_revision(value: str) -> None:
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{40}", value) is None:
        raise MeasurementFailure("an explicit full native baseline revision is required")


def freeze_calibrations(runs: list[Path], thresholds: dict[str, float], *, main_revision: str) -> dict:
    """Build provenance for three successful native baseline runs."""
    require_revision(main_revision)
    if len(runs) != 3 or len(set(runs)) != 3 or not thresholds:
        raise MeasurementFailure("three distinct main calibrations and numeric thresholds required")
    if any(not isinstance(value, (int, float)) or isinstance(value, bool) or
           not math.isfinite(value) or value <= 0 for value in thresholds.values()):
        raise MeasurementFailure("thresholds must be positive finite numbers")
    identities = []
    rates = []
    hashes = []
    for directory in runs:
        result_file = directory / "result.json"
        steady_file = directory / "measurement-steady.json"
        result = json.loads(result_file.read_text())
        steady = json.loads(steady_file.read_text())
        if (result.get("passed") is not True or result.get("mode") != "measurement" or
            result.get("source", {}).get("sourceSHA") != main_revision or
            result.get("measurement", {}).get("phaseFiles", {}).get("steady") != digest(steady_file)):
            raise MeasurementFailure("main calibration evidence is incomplete")
        loader = steady.get("nativeLoader", {})
        duration = loader.get("observedDurationSeconds")
        workload = result.get("measurement", {}).get("scenario", {}).get("workload")
        if workload == "fault":
            if loader.get("messagesSent") != 0 or loader.get("messagesAcknowledged") != 0:
                raise MeasurementFailure("fault calibration must be query-only")
            acknowledged = sum((loader.get(family) or {}).get("successfulRooms", 0)
                               for family in ("roomSyncStateBatch", "roomLatestVisibleBatch"))
            if any((loader.get(family) or {}).get("successfulRooms", 0) <= 0
                   for family in ("roomSyncStateBatch", "roomLatestVisibleBatch")):
                raise MeasurementFailure("fault calibration lacks a recovery query family")
        else:
            acknowledged = loader.get("messagesAcknowledged")
        if (loader.get("completed") is not True or loader.get("workloadFailed") != 0 or
                not isinstance(duration, (int, float)) or not 290 <= duration <= 310 or
                not isinstance(acknowledged, int) or acknowledged <= 0):
            raise MeasurementFailure("main calibration steady phase is invalid")
        scenario = result.get("measurement", {}).get("scenario", {})
        workers = scenario.get("loaderWorkers")
        per_worker = scenario.get("connectionsPerWorker")
        latency_scope = scenario.get("latencyScope")
        if (workers != 1 or not isinstance(per_worker, int) or isinstance(per_worker, bool) or
                not 1 <= per_worker <= 10_000 or latency_scope != "single-process-phase-samples" or
                scenario.get("measurementSemanticsVersion") != MEASUREMENT_SEMANTICS_VERSION or
                scenario.get("resourceScope") != list(resource_scope(workload))):
            raise MeasurementFailure("main calibration loader topology is missing or invalid")
        containers = steady.get("containers", {})
        if not isinstance(containers, dict) or not set(resource_scope(workload)) <= containers.keys():
            raise MeasurementFailure("main calibration lacks scoped server containers")
        for name in resource_scope(workload):
            counters = containers[name]
            if (not isinstance(counters, dict) or
                    not isinstance(counters.get("cpuUsageUsec"), (int, float)) or
                    isinstance(counters["cpuUsageUsec"], bool) or
                    not math.isfinite(counters["cpuUsageUsec"]) or counters["cpuUsageUsec"] < 0 or
                    not isinstance(counters.get("sampledPeakProcessRSSBytes"), (int, float)) or
                    isinstance(counters["sampledPeakProcessRSSBytes"], bool) or
                    not math.isfinite(counters["sampledPeakProcessRSSBytes"]) or
                    counters["sampledPeakProcessRSSBytes"] <= 0):
                raise MeasurementFailure("main calibration has invalid scoped server counters")
        if scenario.get("workload") == "mixed" and per_worker != 10_000:
            raise MeasurementFailure("mixed calibration requires one 10000-connection loader")
        if result.get("measurement", {}).get("nativeConnectionsAuthenticated") != per_worker:
            raise MeasurementFailure("main calibration did not authenticate the frozen connection count")
        harness = result.get("harness", {})
        revision = harness.get("revision")
        files = harness.get("filesSHA256")
        if (harness.get("trackedClean") is not True or not isinstance(revision, str) or
                len(revision) != 40 or not isinstance(files, dict) or
                set(files) != set(HARNESS_FILE_KEYS) or
                any(not isinstance(value, str) or len(value) != 64 for value in files.values())):
            raise MeasurementFailure("main calibration harness provenance is incomplete")
        harness_identity = (revision, tuple(files[key] for key in HARNESS_FILE_KEYS))
        identity = (result.get("layout"), result.get("fixtureManifestSHA256"),
                    result.get("scenarioSHA256"),
                    result.get("productSHA256", {}).get("IMV2GatewayLoadGenerator"),
                    scenario.get("workload"), workers, per_worker, latency_scope,
                    scenario.get("measurementSemanticsVersion"),
                    tuple(scenario["resourceScope"]), harness_identity)
        identities.append(identity)
        rates.append(acknowledged / duration)
        hashes.append(digest(result_file))
    if len(set(identities)) != 1 or len(set(hashes)) != 3:
        raise MeasurementFailure("main calibration fixture/scenario/loader differs")
    cv = statistics.pstdev(rates) / statistics.mean(rates)
    if cv > 0.10:
        raise MeasurementFailure("main calibration throughput coefficient of variation exceeds 10%")
    (layout, fixture_hash, scenario_hash, loader_hash, workload, workers, per_worker,
     latency_scope, semantics_version, scoped_services, harness_identity) = identities[0]
    unit = "successfulRecoveryRoomItemsPerSecond" if workload == "fault" else "messagesAcknowledgedPerSecond"
    return {"schemaVersion": 1, "mainRevision": main_revision,
            "workload": workload, "layout": layout, "fixtureManifestSHA256": fixture_hash,
            "scenarioSHA256": scenario_hash, "commonLoaderSHA256": loader_hash,
            "loaderWorkers": workers, "connectionsPerWorker": per_worker,
            "latencyScope": latency_scope,
            "measurementSemanticsVersion": semantics_version,
            "resourceScope": list(scoped_services),
            "harnessRevision": harness_identity[0],
            "harnessFilesSHA256": dict(zip(HARNESS_FILE_KEYS, harness_identity[1])),
            "mainCalibrationResultSHA256": hashes,
            "acceptedUnit": unit, "mainSteadyAcceptedPerSecond": rates,
            "mainSteadyCoefficientOfVariation": cv,
            "thresholds": thresholds}


def verify_freeze(path: Path, *, main_revision: str, workload: str, layout: str, fixture_hash: str,
                  scenario_hash: str, loader_hash: str, connections_per_worker: int,
                  harness_revision: str, harness_files: dict[str, str]) -> dict:
    require_revision(main_revision)
    freeze = json.loads(path.read_text())
    expected = {"schemaVersion": 1, "mainRevision": main_revision,
                "workload": workload, "layout": layout, "fixtureManifestSHA256": fixture_hash,
                "scenarioSHA256": scenario_hash, "commonLoaderSHA256": loader_hash,
                "loaderWorkers": 1, "connectionsPerWorker": connections_per_worker,
                "latencyScope": "single-process-phase-samples",
                "measurementSemanticsVersion": MEASUREMENT_SEMANTICS_VERSION,
                "resourceScope": list(resource_scope(workload)),
                "harnessRevision": harness_revision, "harnessFilesSHA256": harness_files}
    if any(freeze.get(key) != value for key, value in expected.items()):
        raise MeasurementFailure("freeze does not match workload, fixture, scenario or loader")
    hashes = freeze.get("mainCalibrationResultSHA256")
    rates = freeze.get("mainSteadyAcceptedPerSecond")
    expected_unit = "successfulRecoveryRoomItemsPerSecond" if workload == "fault" else "messagesAcknowledgedPerSecond"
    thresholds = freeze.get("thresholds")
    if (freeze.get("acceptedUnit") != expected_unit or
            not isinstance(hashes, list) or len(hashes) != 3 or len(set(hashes)) != 3 or
            any(not isinstance(value, str) or len(value) != 64 for value in hashes) or
            not isinstance(rates, list) or len(rates) != 3 or
            any(not isinstance(value, (int, float)) or value <= 0 or not math.isfinite(value)
                for value in rates) or not isinstance(thresholds, dict) or not thresholds):
        raise MeasurementFailure("freeze calibration or thresholds are incomplete")
    cv = statistics.pstdev(rates) / statistics.mean(rates)
    if cv > 0.10 or abs(cv - freeze.get("mainSteadyCoefficientOfVariation", -1)) > 1e-9:
        raise MeasurementFailure("freeze calibration variation is invalid")
    if any(not isinstance(value, (int, float)) or isinstance(value, bool) or
           not math.isfinite(value) or value <= 0 for value in thresholds.values()):
        raise MeasurementFailure("freeze thresholds are invalid")
    return freeze


def create_scenario(source: Path, protocol: dict[str, Any], fixture: dict[str, Any],
                    workload: str, connections: int, rate_scale: float) -> tuple[dict, dict]:
    if workload not in WORKLOADS:
        raise MeasurementFailure("unknown workload")
    layout, relative, expected_digest = WORKLOADS[workload]
    if fixture["layouts"].get(layout) is None:
        raise MeasurementFailure("fixture lacks workload layout")
    if not 1 <= connections <= fixture["users"] or not 0 < rate_scale <= 100:
        raise MeasurementFailure("invalid connections or rate scale")
    measurement = protocol["measurement"]
    if (measurement.get("loaderWorkers") != 1 or
            measurement.get("latencyScope") != "single-process-phase-samples"):
        raise MeasurementFailure("single-loader measurement protocol is not frozen")
    if workload == "mixed" and connections != 10_000:
        raise MeasurementFailure("mixed measurement requires one 10000-connection loader")
    if workload in ("cold", "fault") and rate_scale != 1.0:
        raise MeasurementFailure("cold and fault rates are fixed for cross-revision evidence")
    rooms = fixture["layouts"][layout]["rooms"]
    if workload == "hot" and rooms != 1:
        raise MeasurementFailure("hot workload requires exactly one fixture room")
    if workload == "same-owner" and fixture["owners"] != 1:
        raise MeasurementFailure("same-owner workload requires one physical owner")
    if workload == "cold" and (rooms < 7_500 or connections != fixture["users"]):
        raise MeasurementFailure("cold requires at least 7500 reachable rooms and all fixture users")
    if workload == "fault" and (fixture["owners"] != 2 or
                                 fixture["targetsPerConnection"] < 2 or
                                 min(fixture["layouts"]["mixed"]["ownerRoomCounts"]) <= 0):
        raise MeasurementFailure("fault requires both physical owners in each target batch")
    # Actor-specific hot template belongs to the measurement harness; frozen
    # historical scenarios must come from the verified source checkout.
    template_path = (source if expected_digest else Path(__file__).resolve().parents[2]) / relative
    if not template_path.is_file():
        raise MeasurementFailure("missing workload template")
    template_digest = digest(template_path)
    if expected_digest is not None and template_digest != expected_digest:
        raise MeasurementFailure("frozen workload template digest mismatch")
    template = json.loads(template_path.read_text())
    if len(template["phases"]) < 1 or not template.get("personas"):
        raise MeasurementFailure("invalid workload template")
    if workload == "mixed":
        # The existing foreground recovery envelopes are new workload actions,
        # not a change to the historically frozen high-active scenario.
        for persona in template["personas"]:
            weight = persona["roomLogReadWeight"]
            persona["readReceiptWeight"] = weight
            persona["roomSyncStateBatchWeight"] = weight
            persona["roomLatestVisibleBatchWeight"] = weight
        template["phases"][0]["readReceiptsPerSecond"] = 20
        template["phases"][0]["roomSyncStateBatchesPerSecond"] = 20
        template["phases"][0]["roomLatestVisibleBatchesPerSecond"] = 20
    elif workload == "cold":
        template["seed"] = 20260924
        template["phases"][0]["messagesPerSecond"] = 20
        template["schedulerTicksPerSecond"] = 10
    elif workload == "fault":
        template["seed"] = 20260925
        for persona in template["personas"]:
            persona["sendWeight"] = 0
            persona["roomLogReadWeight"] = 0
            persona["syncPullWeight"] = 0
            persona["roomSyncStateBatchWeight"] = 1
            persona["roomLatestVisibleBatchWeight"] = 1
        first = template["phases"][0]
        first["messagesPerSecond"] = 0
        first["roomLogReadsPerSecond"] = 0
        first["syncPullsPerSecond"] = 0
        first["reconnectPercentPerMinute"] = 0
        first["roomSyncStateBatchesPerSecond"] = 20
        first["roomLatestVisibleBatchesPerSecond"] = 20
    durations = (measurement["warmupSeconds"], measurement["steadySeconds"],
                 measurement["cooldownSeconds"])
    if durations != (120, 300, 60):
        raise MeasurementFailure("capacity protocol phase lengths changed")
    first = template["phases"][0]
    result = deepcopy(template)
    result["name"] = f"va-capacity-{workload}-120-300-60-v1"
    result["phases"] = []
    for name, seconds in zip(PHASES, durations):
        phase = deepcopy(first)
        phase["name"] = name
        phase["durationSeconds"] = seconds
        for key in ("messagesPerSecond", "roomLogReadsPerSecond", "syncPullsPerSecond",
                    "readReceiptsPerSecond", "roomSyncStateBatchesPerSecond",
                    "roomLatestVisibleBatchesPerSecond"):
            if key in phase:
                phase[key] = 0 if name == "cooldown" else phase[key] * rate_scale
        if name == "cooldown":
            phase["reconnectPercentPerMinute"] = 0
        result["phases"].append(phase)
    # Keep the original seed/personas/queue bounds. The scenario is a new
    # measured artifact with its own digest; the frozen source is unchanged.
    detail = {"workload": workload, "layout": layout, "connections": connections,
              "loaderWorkers": 1, "connectionsPerWorker": connections,
              "latencyScope": "single-process-phase-samples",
              "measurementSemanticsVersion": MEASUREMENT_SEMANTICS_VERSION,
              "resourceScope": list(resource_scope(workload)),
              "rateScale": rate_scale, "templatePath": relative,
              "templateSHA256": template_digest, "phaseDurationsSeconds": list(durations),
              "batchRecoveryQueriesRequired": workload in ("mixed", "fault"),
              "batchRecoveryQueriesCovered": False,
              "status": "runtime-proof-required" if workload in ("cold", "mixed", "fault") else "supported"}
    return result, detail


def parse_prometheus(body: str) -> dict[str, float]:
    values: dict[str, float] = {}
    for line in body.splitlines():
        if not line or line.startswith("#"):
            continue
        pieces = line.split()
        if len(pieces) < 2:
            raise MeasurementFailure("malformed metrics sample")
        try:
            value = float(pieces[1])
            if not math.isfinite(value):
                raise ValueError("non-finite metric")
            values[pieces[0]] = value
        except ValueError as error:
            raise MeasurementFailure("non-numeric metrics sample") from error
    return values


def parse_cgroup(body: str) -> dict[str, int]:
    rows = body.splitlines()
    if len(rows) != 4:
        raise MeasurementFailure("incomplete cgroup sample")
    cpu = dict(row.split() for row in rows[0].split(";") if row)
    try:
        return {"cpuUsageUsec": int(cpu["usage_usec"]), "memoryCurrentBytes": int(rows[1]),
                "memoryPeakBytes": int(rows[2]), "processRSSBytes": int(rows[3])}
    except (KeyError, ValueError) as error:
        raise MeasurementFailure("invalid cgroup v2 sample") from error


def phase_delta(before: dict, after: dict, samples: list[dict],
                *, restarted_services: set[str] | None = None) -> dict:
    restarted_services = restarted_services or set()
    if not restarted_services <= before["cgroup"].keys():
        raise MeasurementFailure("unknown restarted container in phase")
    if before["postgres"].keys() != after["postgres"].keys():
        raise MeasurementFailure("PostgreSQL service set changed within phase")
    missing_containers = before["cgroup"].keys() - after["cgroup"].keys()
    if after["cgroup"].keys() - before["cgroup"].keys():
        raise MeasurementFailure("container set changed within phase")
    loader_exit = after.get("containerExitStates", {}).get("loader")
    if missing_containers and (missing_containers != {"loader"} or
                               not isinstance(loader_exit, dict) or
                               loader_exit.get("exitCode") != 0):
        raise MeasurementFailure("required container counter missing within phase")
    sql: dict[str, dict] = {}
    for service, end in after["postgres"].items():
        start = before["postgres"][service]
        if end["statsReset"] != start["statsReset"]:
            raise MeasurementFailure("pg_stat_statements reset within phase")
        old = {row["key"]: row for row in start["statements"]}
        observed_keys = {row["key"] for row in end["statements"]}
        if old.keys() - observed_keys:
            raise MeasurementFailure("PostgreSQL statement identity disappeared within phase")
        deltas = []
        for row in end["statements"]:
            previous = old.get(row["key"], {})
            values = {name: row[name] - previous.get(name, 0) for name in
                      ("calls", "totalExecMs", "rows", "walBytes")}
            if any(value < 0 for value in values.values()):
                raise MeasurementFailure("PostgreSQL statement counters decreased")
            if values["calls"]:
                deltas.append({"key": row["key"], **values})
        sql[service] = {"statements": deltas, "allStatementCalls": sum(row["calls"] for row in deltas)}
    containers = {}
    for service, finish in after["cgroup"].items():
        start = before["cgroup"].get(service)
        if start is None:
            raise MeasurementFailure("container set changed within phase")
        cpu = finish["cpuUsageUsec"] - start["cpuUsageUsec"]
        if cpu < 0 and service not in restarted_services:
            raise MeasurementFailure("container CPU counter decreased")
        memory = [item["cgroup"][service]["memoryCurrentBytes"] for item in samples
                  if service in item["cgroup"]]
        rss = [item["cgroup"][service]["processRSSBytes"] for item in samples
               if service in item["cgroup"]]
        containers[service] = {"cpuUsageUsec": None if service in restarted_services else cpu,
                               "cpuScope": "not comparable across graceful restart" if service in restarted_services else "whole phase",
                               "sampledPeakCgroupMemoryCurrentBytes": max(memory +
                                   [start["memoryCurrentBytes"], finish["memoryCurrentBytes"]]),
                               "lifetimeCgroupMemoryPeakBytes": None if service in restarted_services else finish["memoryPeakBytes"],
                               "sampledPeakProcessRSSBytes": max(rss +
                                   [start["processRSSBytes"], finish["processRSSBytes"]])}
    if missing_containers:
        start = before["cgroup"]["loader"]
        previous = [item["cgroup"]["loader"] for item in samples
                    if "loader" in item["cgroup"]]
        containers["loader"] = {
            "cpuUsageUsec": None,
            "cpuScope": "unavailable: loader exited before end snapshot",
            "sampledPeakCgroupMemoryCurrentBytes": max(
                item["memoryCurrentBytes"] for item in [start, *previous]),
            "lifetimeCgroupMemoryPeakBytes": None,
            "sampledPeakProcessRSSBytes": max(
                item["processRSSBytes"] for item in [start, *previous]),
            "sampleScope": "pre-exit samples only; final loader CPU/RSS unavailable",
            "exitState": loader_exit,
        }
    metrics = {}
    old_metrics = before["metrics"]
    for key, value in after["metrics"].items():
        if key in old_metrics and (key.endswith("_total") or "_total{" in key):
            delta = value - old_metrics[key]
            if delta < 0:
                raise MeasurementFailure("Prometheus counter decreased")
            metrics[key] = delta
    sampled_metrics: dict[str, float] = {}
    for sample in [before, *samples, after]:
        for key, value in sample["metrics"].items():
            if not key.endswith("_total") and "_total{" not in key:
                sampled_metrics[key] = max(value, sampled_metrics.get(key, value))
    return {"sql": sql, "containers": containers, "metricsCounterDeltas": metrics,
            "metricsAtStart": old_metrics, "metricsAtEnd": after["metrics"],
            "metricsSampledMaximum": sampled_metrics,
            "sampleCount": len(samples), "restartedServices": sorted(restarted_services),
            "unavailableEndContainers": sorted(missing_containers),
            "sqlScope": "whole disposable databases including background and observer SQL",
            "memoryScope": "cgroup memory.current includes cache; memory.peak covers container lifetime; process RSS is sampled /proc/1/status VmRSS only (PostgreSQL backend children excluded)"}


PG_SNAPSHOT_SQL = """SELECT json_build_object(
  'statsReset', (SELECT stats_reset::text FROM pg_stat_statements_info),
  'statements', COALESCE((SELECT json_agg(json_build_object(
    'key', userid::text || ':' || toplevel::text || ':' || queryid::text,
    'calls', calls, 'totalExecMs', total_exec_time, 'rows', rows, 'walBytes', wal_bytes))
    FROM pg_stat_statements WHERE dbid = (SELECT oid FROM pg_database
      WHERE datname = current_database()) AND queryid IS NOT NULL), '[]'::json))::text;"""


def capture_runtime(docker: list[str], container_ids: dict[str, str],
                    metrics_url: str, execute: Any,
                    *, excluded_services: set[str] | None = None,
                    allow_stopped_loader: bool = False) -> dict:
    """Sample cgroup CPU/memory, PID 1 RSS and private Gateway metrics."""
    import time

    capture_started = time.monotonic_ns()
    cgroup = {}
    exit_states = {}
    script = "awk 'BEGIN{ORS=\";\"} {print $1, $2}' /sys/fs/cgroup/cpu.stat; " \
             "printf '\\n'; cat /sys/fs/cgroup/memory.current /sys/fs/cgroup/memory.peak; " \
             "awk '/^VmRSS:/ {printf \"%.0f\\n\", $2 * 1024; exit}' /proc/1/status"
    for service, container_id in container_ids.items():
        if service in (excluded_services or set()):
            continue
        try:
            raw = execute(docker + ["exec", container_id, "sh", "-c", script],
                          "measurement-containers.log", 15, record_stdout=False)
        except subprocess.CalledProcessError:
            if service != "loader" or not allow_stopped_loader:
                raise
            state = json.loads(execute(docker + ["inspect", "--format", "{{json .State}}", container_id],
                                       "measurement-containers.log", 15, record_stdout=False))
            if state.get("Running") is not False or state.get("ExitCode") != 0:
                raise MeasurementFailure("loader cgroup unavailable without clean container exit")
            exit_states["loader"] = {"exitCode": 0, "finishedAt": state.get("FinishedAt")}
            continue
        cgroup[service] = parse_cgroup(raw)
    # Production configuration forbids a non-loopback metrics listener. The
    # pinned Swift image contains Python3; scrape inside the Gateway namespace.
    script = ("import sys,urllib.request; "
              "r=urllib.request.urlopen(sys.argv[1],timeout=3); "
              "sys.stdout.buffer.write(r.read(4194305))")
    body = execute(docker + ["exec", container_ids["gateway"], "python3", "-c", script,
                             metrics_url], "measurement-metrics.log", 5, record_stdout=False)
    if len(body.encode()) > 4 * 1024 * 1024:
        raise MeasurementFailure("Gateway private metrics scrape exceeds bounded size")
    metrics = parse_prometheus(body)
    capture_finished = time.monotonic_ns()
    if capture_finished - capture_started > 10_000_000_000:
        raise MeasurementFailure("phase counter snapshot exceeded ten seconds")
    return {"monotonicNs": capture_finished, "captureStartedMonotonicNs": capture_started,
            "captureDurationSeconds": (capture_finished - capture_started) / 1e9,
            "wallTime": time.time(),
            "cgroup": cgroup,
            "cgroupUnavailableServices": sorted((excluded_services or set()) | exit_states.keys()),
            "containerExitStates": exit_states,
            "metrics": metrics}


def capture_snapshot(psql: Any, docker: list[str], compose: list[str],
                     services: dict[str, str], container_ids: dict[str, str],
                     metrics_url: str, execute: Any,
                     *, allow_stopped_loader: bool = False) -> dict:
    """Read each disposable DB once at a phase boundary, without resetting it."""
    import time

    started = time.monotonic_ns()
    postgres = {}
    for service, database in services.items():
        raw = psql(service, database, PG_SNAPSHOT_SQL, log="measurement-sql.log", timeout=15)
        try:
            postgres[service] = json.loads(raw)
        except json.JSONDecodeError as error:
            raise MeasurementFailure("invalid pg_stat_statements snapshot") from error
    runtime = capture_runtime(docker, container_ids, metrics_url, execute,
                              allow_stopped_loader=allow_stopped_loader)
    runtime["postgres"] = postgres
    runtime["captureStartedMonotonicNs"] = started
    runtime["captureDurationSeconds"] = (runtime["monotonicNs"] - started) / 1e9
    if runtime["captureDurationSeconds"] > 10:
        raise MeasurementFailure("phase SQL/metrics snapshot exceeded ten seconds")
    return runtime
