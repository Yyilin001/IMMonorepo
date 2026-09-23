"""Isolated capacity measurement planning and phase counter arithmetic.

This module does not start containers. The runner uses the same verified binaries
and fixture as its functional canary, and writes a separate derived scenario.
"""

from __future__ import annotations

from copy import deepcopy
import hashlib
import json
import math
from pathlib import Path
import statistics
from typing import Any


PHASES = ("warmup", "steady", "cooldown")
WORKLOADS = {
    "hot": ("hot", "IMV2/scripts/virtual-actor-fixtures/send-one-canary.json", None),
    "same-owner": ("same-owner", "IMV2/load-scenarios/direct-1500-message-only-900-server-saturation.json",
                   "ab74cd0d64d73040b7aba935cb2e0f33da32928fcdc806e3e55bf19d7e6bbfbe"),
    "mixed": ("mixed", "IMV2/load-scenarios/high-active-10000.json",
              "64c11814d90effe550f55f1affa496a8ca710c2d6a2d7fb432a844c647ce7909"),
    "cold": ("cold", None, None),
    "fault": ("cold", None, None),
}


class MeasurementFailure(Exception):
    pass


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def freeze_calibrations(runs: list[Path], thresholds: dict[str, float]) -> dict:
    """Build provenance for three successful frozen-main calibration runs."""
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
            result.get("source", {}).get("sourceSHA") != "f1cdd78d6a21bf0ae23da627c0710c65115236aa" or
            result.get("measurement", {}).get("phaseFiles", {}).get("steady") != digest(steady_file)):
            raise MeasurementFailure("main calibration evidence is incomplete")
        loader = steady.get("nativeLoader", {})
        duration = loader.get("observedDurationSeconds")
        acknowledged = loader.get("messagesAcknowledged")
        if (loader.get("completed") is not True or loader.get("workloadFailed") != 0 or
                not isinstance(duration, (int, float)) or not 290 <= duration <= 310 or
                not isinstance(acknowledged, int) or acknowledged <= 0):
            raise MeasurementFailure("main calibration steady phase is invalid")
        identity = (result.get("layout"), result.get("fixtureManifestSHA256"),
                    result.get("scenarioSHA256"),
                    result.get("productSHA256", {}).get("IMV2GatewayLoadGenerator"),
                    result.get("measurement", {}).get("scenario", {}).get("workload"))
        identities.append(identity)
        rates.append(acknowledged / duration)
        hashes.append(digest(result_file))
    if len(set(identities)) != 1 or len(set(hashes)) != 3:
        raise MeasurementFailure("main calibration fixture/scenario/loader differs")
    cv = statistics.pstdev(rates) / statistics.mean(rates)
    if cv > 0.10:
        raise MeasurementFailure("main calibration throughput coefficient of variation exceeds 10%")
    layout, fixture_hash, scenario_hash, loader_hash, workload = identities[0]
    return {"schemaVersion": 1, "mainRevision": "f1cdd78d6a21bf0ae23da627c0710c65115236aa",
            "workload": workload, "layout": layout, "fixtureManifestSHA256": fixture_hash,
            "scenarioSHA256": scenario_hash, "commonLoaderSHA256": loader_hash,
            "mainCalibrationResultSHA256": hashes,
            "mainSteadyMessagesAcknowledgedPerSecond": rates,
            "mainSteadyCoefficientOfVariation": cv,
            "thresholds": thresholds}


def verify_freeze(path: Path, *, workload: str, layout: str, fixture_hash: str,
                  scenario_hash: str, loader_hash: str) -> dict:
    freeze = json.loads(path.read_text())
    expected = {"schemaVersion": 1, "mainRevision": "f1cdd78d6a21bf0ae23da627c0710c65115236aa",
                "workload": workload, "layout": layout, "fixtureManifestSHA256": fixture_hash,
                "scenarioSHA256": scenario_hash, "commonLoaderSHA256": loader_hash}
    if any(freeze.get(key) != value for key, value in expected.items()):
        raise MeasurementFailure("freeze does not match workload, fixture, scenario or loader")
    hashes = freeze.get("mainCalibrationResultSHA256")
    rates = freeze.get("mainSteadyMessagesAcknowledgedPerSecond")
    thresholds = freeze.get("thresholds")
    if (not isinstance(hashes, list) or len(hashes) != 3 or len(set(hashes)) != 3 or
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
    if relative is None:
        raise MeasurementFailure("cold/fault workload has no implemented driver")
    if fixture["layouts"].get(layout) is None:
        raise MeasurementFailure("fixture lacks workload layout")
    if not 1 <= connections <= fixture["users"] or not 0 < rate_scale <= 100:
        raise MeasurementFailure("invalid connections or rate scale")
    rooms = fixture["layouts"][layout]["rooms"]
    if workload == "hot" and rooms != 1:
        raise MeasurementFailure("hot workload requires exactly one fixture room")
    if workload == "same-owner" and fixture["owners"] != 1:
        raise MeasurementFailure("same-owner workload requires one physical owner")
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
    measurement = protocol["measurement"]
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
                    "readReceiptsPerSecond"):
            if key in phase:
                phase[key] *= rate_scale
        result["phases"].append(phase)
    # Keep the original seed/personas/queue bounds. The scenario is a new
    # measured artifact with its own digest; the frozen source is unchanged.
    detail = {"workload": workload, "layout": layout, "connections": connections,
              "rateScale": rate_scale, "templatePath": relative,
              "templateSHA256": template_digest, "phaseDurationsSeconds": list(durations),
              "batchRecoveryQueriesCovered": False,
              "status": "partial-recovery-batch" if workload == "mixed" else "supported"}
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
    if len(rows) < 3:
        raise MeasurementFailure("incomplete cgroup sample")
    cpu = dict(row.split() for row in rows[0].split(";") if row)
    try:
        return {"cpuUsageUsec": int(cpu["usage_usec"]), "memoryCurrentBytes": int(rows[1]),
                "memoryPeakBytes": int(rows[2])}
    except (KeyError, ValueError) as error:
        raise MeasurementFailure("invalid cgroup v2 sample") from error


def phase_delta(before: dict, after: dict, samples: list[dict]) -> dict:
    if before["postgres"].keys() != after["postgres"].keys():
        raise MeasurementFailure("PostgreSQL service set changed within phase")
    sql: dict[str, dict] = {}
    for service, end in after["postgres"].items():
        start = before["postgres"][service]
        if end["statsReset"] != start["statsReset"]:
            raise MeasurementFailure("pg_stat_statements reset within phase")
        old = {row["key"]: row for row in start["statements"]}
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
        if cpu < 0:
            raise MeasurementFailure("container CPU counter decreased")
        memory = [item["cgroup"][service]["memoryCurrentBytes"] for item in samples
                  if service in item["cgroup"]]
        containers[service] = {"cpuUsageUsec": cpu,
                               "sampledPeakRSSBytes": max(memory + [start["memoryCurrentBytes"],
                                                              finish["memoryCurrentBytes"]]),
                               "lifetimeMemoryPeakBytes": finish["memoryPeakBytes"]}
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
            "sampleCount": len(samples), "sqlScope": "whole disposable databases including background and observer SQL",
            "rssScope": "sampled memory.current; lifetime memory.peak is separately reported"}


PG_SNAPSHOT_SQL = """SELECT json_build_object(
  'statsReset', (SELECT stats_reset::text FROM pg_stat_statements_info),
  'statements', COALESCE((SELECT json_agg(json_build_object(
    'key', userid::text || ':' || toplevel::text || ':' || queryid::text,
    'calls', calls, 'totalExecMs', total_exec_time, 'rows', rows, 'walBytes', wal_bytes))
    FROM pg_stat_statements WHERE dbid = (SELECT oid FROM pg_database
      WHERE datname = current_database()) AND queryid IS NOT NULL), '[]'::json))::text;"""


def capture_runtime(docker: list[str], container_ids: dict[str, str],
                    metrics_url: str, execute: Any) -> dict:
    """Sample process CPU/RSS and private Gateway metrics without SQL work."""
    import time

    capture_started = time.monotonic_ns()
    cgroup = {}
    script = "awk 'BEGIN{ORS=\";\"} {print $1, $2}' /sys/fs/cgroup/cpu.stat; " \
             "printf '\\n'; cat /sys/fs/cgroup/memory.current /sys/fs/cgroup/memory.peak"
    for service, container_id in container_ids.items():
        raw = execute(docker + ["exec", container_id, "sh", "-c", script],
                      "measurement-containers.log", 15, record_stdout=False)
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
            "cgroup": cgroup, "metrics": metrics}


def capture_snapshot(psql: Any, docker: list[str], compose: list[str],
                     services: dict[str, str], container_ids: dict[str, str],
                     metrics_url: str, execute: Any) -> dict:
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
    runtime = capture_runtime(docker, container_ids, metrics_url, execute)
    runtime["postgres"] = postgres
    runtime["captureStartedMonotonicNs"] = started
    runtime["captureDurationSeconds"] = (runtime["monotonicNs"] - started) / 1e9
    if runtime["captureDurationSeconds"] > 10:
        raise MeasurementFailure("phase SQL/metrics snapshot exceeded ten seconds")
    return runtime
