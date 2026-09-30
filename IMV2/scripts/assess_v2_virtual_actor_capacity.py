#!/usr/bin/env python3
"""Derive pre-candidate budgets from main, then assess immutable capacity runs."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import statistics
from pathlib import Path

from virtual_actor_capacity_measurement import (
    MEASUREMENT_SEMANTICS_VERSION, MeasurementFailure, freeze_calibrations,
    resource_scope, verify_freeze,
)


MAIN = "f1cdd78d6a21bf0ae23da627c0710c65115236aa"
# Integration-owner policy, fixed before any candidate capacity observation.
# Absolute values are derived only from three stable main calibrations.
POLICY = {
    "throughputMinimumRatio": 0.90,
    "p95MaximumRatio": 1.25, "p95AdditiveAllowanceMilliseconds": 10,
    "p99MaximumRatio": 1.50, "p99AdditiveAllowanceMilliseconds": 25,
    "sqlCallsMaximumRatio": 1.35, "sqlCallsAdditiveAllowancePerUnit": 2,
    "serverCPUMaximumRatio": 1.50,
    "serverRSSMaximumRatio": 1.50, "serverRSSAdditiveAllowanceBytes": 256 * 1024 * 1024,
    "serverRSSHardMaximumBytes": 2 * 1024 * 1024 * 1024,
    "actorOutstandingCommandsHardMaximum": 32768,
    "actorOutstandingBytesHardMaximum": 128 * 1024 * 1024,
}


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def number(value: object, label: str, *, positive: bool = False) -> float:
    if (not isinstance(value, (int, float)) or isinstance(value, bool) or
            not math.isfinite(value) or value < 0 or (positive and value <= 0)):
        raise MeasurementFailure("missing or invalid " + label)
    return float(value)


def read_run(directory: Path) -> dict:
    result = json.loads((directory / "result.json").read_text())
    phase_file = directory / "measurement-steady.json"
    if (result.get("passed") is not True or result.get("mode") != "measurement" or
            result.get("formalSamplingEligible") is not True or
            result.get("measurement", {}).get("phaseFiles", {}).get("steady") != sha(phase_file)):
        raise MeasurementFailure("unverified measurement result")
    phase = json.loads(phase_file.read_text())
    load = phase["nativeLoader"]
    if load.get("completed") is not True or load.get("workloadFailed") != 0:
        raise MeasurementFailure("incomplete or failed native workload")
    seconds = number(load.get("observedDurationSeconds"), "steady duration", positive=True)
    if not 290 <= seconds <= 310:
        raise MeasurementFailure("steady duration is outside the frozen window")
    workload = result["measurement"]["scenario"]["workload"]
    scope = list(resource_scope(workload))
    scenario = result["measurement"]["scenario"]
    if (scenario.get("measurementSemanticsVersion") != MEASUREMENT_SEMANTICS_VERSION or
            scenario.get("resourceScope") != scope):
        raise MeasurementFailure("measurement resource scope or semantics changed")
    fault = workload == "fault"
    families = ("roomSyncStateBatch", "roomLatestVisibleBatch")
    units = (sum(number(load.get(key, {}).get("successfulRooms"), key) for key in families)
             if fault else number(load.get("messagesAcknowledged"), "message ACKs"))
    number(units, "accepted units", positive=True)
    latency = ([load[key]["latency"] for key in families] if fault else [load["messageLatency"]])
    if any(number(row.get("count"), "latency sample count", positive=True) <= 0 for row in latency):
        raise MeasurementFailure("latency distribution has no samples")
    containers = phase["containers"]
    if not set(scope) <= containers.keys():
        raise MeasurementFailure("scoped server container counters are missing")
    loader = containers["loader"]
    server_cpu = sum(number(containers[name].get("cpuUsageUsec"), name + " CPU")
                     for name in scope)
    server_rss = sum(number(containers[name].get("sampledPeakProcessRSSBytes"),
                            name + " RSS", positive=True) for name in scope)
    measurements = {
        "acceptedUnitsPerSecond": units / seconds,
        "p95Milliseconds": max(number(row.get("p95"), "p95") for row in latency),
        "p99Milliseconds": max(number(row.get("p99"), "p99") for row in latency),
        "sqlCallsPerAcceptedUnit": sum(number(row.get("allStatementCalls"), "SQL calls")
                                       for row in phase["sql"].values()) / units,
        "serverCPUSecondsPerAcceptedUnit": server_cpu / 1e6 / units,
        "loaderCPUSecondsPerAcceptedUnit": number(loader.get("cpuUsageUsec"), "loader CPU") / 1e6 / units,
        "serverPeakRSSBytes": server_rss,
        "loaderPeakRSSBytes": number(loader.get("sampledPeakProcessRSSBytes"), "loader RSS", positive=True),
    }
    if workload in ("mixed", "fault"):
        if result["measurement"].get("batchRecoveryQueriesCovered") is not True:
            raise MeasurementFailure("required batch recovery traffic was not verified")
        for key in families:
            row = load[key]
            measurements[key + "SuccessfulRoomsPerSecond"] = number(row.get("successfulRooms"), key, positive=True) / seconds
            measurements[key + "P95Milliseconds"] = number(row["latency"].get("p95"), key + " p95")
            measurements[key + "P99Milliseconds"] = number(row["latency"].get("p99"), key + " p99")
    metrics = phase["metricsCounterDeltas"]
    batches = metrics.get("im_v2_direct_room_log_append_batch_completed_total")
    dequeued = metrics.get("im_v2_direct_room_log_append_batch_dequeued_requests_total")
    mean_batch = None
    if batches is not None and dequeued is not None and number(batches, "batches") > 0:
        mean_batch = number(dequeued, "batch requests") / batches
    peaks = phase["metricsSampledMaximum"]
    actor = {}
    if result["source"]["sourceSHA"] != MAIN:
        for suffix in ("peak_outstanding_commands", "peak_outstanding_bytes"):
            actor[suffix] = number(peaks.get("im_v2_room_actor_" + suffix), suffix)
    return {"directory": str(directory), "resultSHA256": sha(directory / "result.json"),
            "result": result, "workload": workload, "resourceScope": scope,
            "measurements": measurements,
            "acceptedUnit": "successful room query item" if fault else "acknowledged message",
            "meanPhysicalSendBatchSize": mean_batch, "actorOutstandingPeaks": actor}


def budgets(runs: list[dict]) -> dict[str, float]:
    if len(runs) != 3 or any(run["result"]["source"]["sourceSHA"] != MAIN for run in runs):
        raise MeasurementFailure("budgets require three main runs")
    keys = runs[0]["measurements"].keys()
    if any(run["measurements"].keys() != keys for run in runs):
        raise MeasurementFailure("calibration metric sets differ")
    medians = {key: statistics.median(run["measurements"][key] for run in runs) for key in keys}
    answer = {}
    for key, value in medians.items():
        if key.endswith("PerSecond"):
            answer[key + "Minimum"] = value * POLICY["throughputMinimumRatio"]
        elif key.lower().endswith("p95milliseconds"):
            answer[key + "Maximum"] = max(value * POLICY["p95MaximumRatio"], value + POLICY["p95AdditiveAllowanceMilliseconds"])
        elif key.lower().endswith("p99milliseconds"):
            answer[key + "Maximum"] = max(value * POLICY["p99MaximumRatio"], value + POLICY["p99AdditiveAllowanceMilliseconds"])
        elif key == "sqlCallsPerAcceptedUnit":
            answer[key + "Maximum"] = max(value * POLICY["sqlCallsMaximumRatio"], value + POLICY["sqlCallsAdditiveAllowancePerUnit"])
        elif key == "serverCPUSecondsPerAcceptedUnit":
            answer[key + "Maximum"] = value * POLICY["serverCPUMaximumRatio"]
        elif key == "serverPeakRSSBytes":
            answer[key + "Maximum"] = min(POLICY["serverRSSHardMaximumBytes"], max(
                value * POLICY["serverRSSMaximumRatio"], value + POLICY["serverRSSAdditiveAllowanceBytes"]))
    return answer


def assess(run: dict, thresholds: dict[str, float]) -> list[str]:
    failures = []
    for key, bound in thresholds.items():
        suffix = "Minimum" if key.endswith("Minimum") else "Maximum" if key.endswith("Maximum") else None
        if suffix is None:
            raise MeasurementFailure("unknown threshold direction")
        value = number(run["measurements"].get(key[:-len(suffix)]), key)
        if (suffix == "Minimum" and value < bound) or (suffix == "Maximum" and value > bound):
            failures.append(key)
    for key, bound in (("peak_outstanding_commands", POLICY["actorOutstandingCommandsHardMaximum"]),
                       ("peak_outstanding_bytes", POLICY["actorOutstandingBytesHardMaximum"])):
        if run["actorOutstandingPeaks"].get(key, 0) > bound:
            failures.append(key)
    return failures


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="mode", required=True)
    freeze = sub.add_parser("freeze")
    freeze.add_argument("--main-run", type=Path, action="append", required=True)
    freeze.add_argument("--output", type=Path, required=True)
    evaluate = sub.add_parser("assess")
    evaluate.add_argument("--freeze", type=Path, required=True)
    evaluate.add_argument("--run", type=Path, action="append", required=True)
    evaluate.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error("output must be new")
    if args.mode == "freeze":
        runs = [read_run(path) for path in args.main_run]
        output = freeze_calibrations(args.main_run, budgets(runs))
        output["regressionPolicy"] = POLICY
        output["policyMeaning"] = "integration-owner budget; frozen from main before candidate sampling"
    else:
        frozen = json.loads(args.freeze.read_text())
        if frozen.get("regressionPolicy") != POLICY:
            raise MeasurementFailure("frozen regression policy differs")
        rows = [read_run(path) for path in args.run]
        expected = frozen["thresholds"]
        for row in rows:
            result = row["result"]
            if (row["workload"] != frozen["workload"] or
                result["fixtureManifestSHA256"] != frozen["fixtureManifestSHA256"] or
                result["scenarioSHA256"] != frozen["scenarioSHA256"] or
                result["productSHA256"]["IMV2GatewayLoadGenerator"] != frozen["commonLoaderSHA256"] or
                result["mainCalibrationFreezeSHA256"] != sha(args.freeze)):
                raise MeasurementFailure("assessed run does not match frozen provenance")
            scenario = result["measurement"]["scenario"]
            harness = result["harness"]
            if harness.get("trackedClean") is not True or any(
                scenario.get(key) != frozen.get(key) for key in
                ("loaderWorkers", "connectionsPerWorker", "latencyScope",
                 "measurementSemanticsVersion", "resourceScope")
            ):
                raise MeasurementFailure("assessed run changed harness or measurement topology")
            verify_freeze(args.freeze, workload=row["workload"], layout=result["layout"],
                          fixture_hash=result["fixtureManifestSHA256"],
                          scenario_hash=result["scenarioSHA256"],
                          loader_hash=result["productSHA256"]["IMV2GatewayLoadGenerator"],
                          connections_per_worker=scenario["connectionsPerWorker"],
                          harness_revision=harness["revision"], harness_files=harness["filesSHA256"])
            row["failures"] = assess(row, expected)
            del row["result"]
        output = {"freezeSHA256": sha(args.freeze), "runs": rows,
                  "passed": all(not row["failures"] for row in rows),
                  "notes": ["SQL counts include all captured database statements and observer/background work.",
                            "Mixed SQL/CPU are normalized by acknowledged messages; batch query rates are separate.",
                            "Actor outstanding peaks include executing and reconciling permits, not just waiting queues.",
                            "Server CPU sums the containers in resourceScope; it includes bounded observer exec work.",
                            "Server RSS sums each scoped container's sampled PID 1 peak, a conservative upper bound rather than a simultaneous peak.",
                            "Per-container CPU, RSS and cgroup memory remain in raw phase evidence."]}
    args.output.write_text(json.dumps(output, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
