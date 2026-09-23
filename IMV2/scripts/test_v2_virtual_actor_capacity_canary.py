#!/usr/bin/env python3
"""Run a functional Gateway canary or explicit disposable capacity scenario.

The default one-send mode is not a throughput measurement. Measurement mode
needs separate calibration and does not build or modify a source checkout.
"""

from __future__ import annotations

import argparse
import base64
import binascii
from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import secrets
import shutil
import subprocess
import sys
import threading
import time
import uuid

from virtual_actor_capacity_measurement import (
    HARNESS_FILE_KEYS, MeasurementFailure, capture_runtime, capture_snapshot, create_scenario, phase_delta,
    supports_recovery_loader, verify_freeze,
)
from virtual_actor_capacity_lifecycle import (
    LEASE_COUNTS_SQL, OwnerFailureWindow, validate_cold_retirement,
    validate_fault_unavailable_results,
)


RUNNER_ROOT = Path(__file__).resolve().parents[2]
IMAGE = "swift:6.4-jammy@sha256:a6053d2de72091906bfa064f76f145e3f28830664cae250e1b84aa8c499a8ee6"
POSTGRES_IMAGE = "postgres:16-alpine"
LAYOUTS = ("hot", "same-owner", "mixed", "cold")
HEX64 = re.compile(r"[a-f0-9]{64}\Z")
HEX40 = re.compile(r"[a-f0-9]{40}\Z")


class CanaryFailure(Exception):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def capture_harness_provenance(*, require_clean: bool) -> dict:
    """Identify the runner checkout independently of the measured product."""
    revision = subprocess.run(["git", "-C", str(RUNNER_ROOT), "rev-parse", "HEAD"],
                              capture_output=True, text=True, timeout=10, check=True).stdout.strip()
    tracked_status = subprocess.run(
        ["git", "-C", str(RUNNER_ROOT), "status", "--porcelain", "--untracked-files=no"],
        capture_output=True, text=True, timeout=10, check=True).stdout
    clean = not tracked_status.strip()
    if not HEX40.fullmatch(revision) or (require_clean and not clean):
        raise MeasurementFailure("formal measurement requires a clean, committed harness checkout")
    return {"revision": revision, "trackedClean": clean,
            "filesSHA256": {key: sha256(RUNNER_ROOT / key) for key in HARNESS_FILE_KEYS}}


def capture_project_diagnostics(*, compose: list[str], service_names: list[str],
                                run: Path, environment: dict[str, str],
                                invoke: object = subprocess.run) -> dict:
    """Keep bounded, redacted project-local diagnostics before Compose teardown."""
    def call(args: list[str]) -> subprocess.CompletedProcess[str]:
        return invoke(compose + args, cwd=RUNNER_ROOT, env=environment,
                      capture_output=True, text=True, timeout=30, check=False)

    status = call(["ps", "--all", "--format", "json"])
    rows: list[dict] = []
    status_valid = status.returncode == 0
    if status.returncode == 0:
        try:
            body = status.stdout.strip()
            parsed = json.loads(body) if body.startswith("[") else [json.loads(line) for line in body.splitlines()]
            for row in parsed:
                if row.get("Service") in service_names:
                    rows.append({"service": row.get("Service"), "containerID": row.get("ID"),
                                 "state": row.get("State"), "health": row.get("Health"),
                                 "exitCode": row.get("ExitCode")})
        except (ValueError, AttributeError, TypeError):
            status_valid = False
            rows = []
    write_private(run / "services-status.json", json.dumps({
        "complete": status_valid, "containers": rows}, indent=2, sort_keys=True) + "\n")

    # The one-off loader already has a separately followed loader.log. Keep
    # Compose's service log query focused on the Gateway and databases.
    logs = call(["logs", "--no-color", "--tail", "120",
                 *(name for name in service_names if name != "loader")])
    sensitive = re.compile(r"password|token|secret|credential|authorization|bearer|private|access[_-]?key|database[_-]?url|postgres://|va1_|statement:|parameters:|binds:", re.I)
    lines = [line[:2048] for line in logs.stdout.splitlines()
             if not sensitive.search(line) and "://" not in line]
    tail = "\n".join(lines[-480:])[-131072:]
    write_private(run / "services-tail.log", tail + ("\n" if tail else ""))
    return {"statusSHA256": sha256(run / "services-status.json"),
            "logSHA256": sha256(run / "services-tail.log"),
            "statusAvailable": status_valid,
            "logsAvailable": logs.returncode == 0,
            "logScope": "project services, last 120 lines each, sensitive lines omitted, 128 KiB maximum"}


def require_regular(path: Path, label: str) -> None:
    if path.is_symlink() or not path.is_file():
        raise CanaryFailure(f"{label} must be a regular file")


def checked_uuid(raw: str, label: str) -> str:
    try:
        return str(uuid.UUID(raw))
    except ValueError as error:
        raise CanaryFailure(f"invalid {label}") from error


def verify_source(source: Path, expected_sha: str) -> dict[str, str]:
    if not HEX40.fullmatch(expected_sha):
        raise CanaryFailure("source SHA must be a full lowercase git SHA")
    head = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    root = Path(subprocess.check_output(["git", "-C", str(source), "rev-parse", "--show-toplevel"], text=True).strip()).resolve()
    status = subprocess.check_output(["git", "-C", str(source), "status", "--porcelain", "--untracked-files=no"], text=True)
    if head != expected_sha or root != source or status.strip():
        raise CanaryFailure("source checkout SHA, root or tracked cleanliness mismatch")
    required = [source / "IMV2/sql/schema.sql", source / "IMV2/docker-compose.local-account.yml",
                source / "IMV2Server/Package.resolved"]
    for path in required:
        require_regular(path, path.name)
    return {
        "sourceSHA": head,
        "schemaSHA256": sha256(required[0]),
        "composeSourceSHA256": sha256(required[1]),
        "packageResolvedSHA256": sha256(required[2]),
    }


def verify_product(release: Path, product: str, expected: str) -> str:
    if not HEX64.fullmatch(expected):
        raise CanaryFailure(f"{product} requires an independently supplied SHA-256")
    path = release / product
    require_regular(path, product)
    with path.open("rb") as stream:
        magic = stream.read(4)
    if not os.access(path, os.X_OK) or magic != b"\x7fELF":
        raise CanaryFailure(f"{product} is not an executable Linux ELF")
    actual = sha256(path)
    if actual != expected:
        raise CanaryFailure(f"{product} binary SHA-256 mismatch")
    return actual


def read_build_result(path: Path) -> dict:
    result = json.loads(path.read_text())
    if (result.get("passed") is not True or result.get("exitCode") != 0
            or result.get("image") != IMAGE or not HEX40.fullmatch(result.get("sourceSHA", ""))
            or not HEX64.fullmatch(result.get("lockfileSHA256", ""))):
        raise CanaryFailure("Linux Release build result is incomplete or uses another image")
    return result


def verify_fixture(fixture: Path, layout: str) -> tuple[dict, set[str], set[str], dict[str, str]]:
    manifest_file = fixture / "manifest.json"
    require_regular(manifest_file, "fixture manifest")
    manifest = json.loads(manifest_file.read_text())
    if manifest.get("schemaVersion") != 1 or layout not in manifest.get("layouts", {}):
        raise CanaryFailure("unsupported fixture manifest or layout")
    fixture_id = checked_uuid(manifest.get("fixtureID", ""), "fixture ID")
    info = manifest["layouts"][layout]
    owners = manifest.get("owners")
    targets = manifest.get("targetsPerConnection")
    users = manifest.get("users")
    if not isinstance(owners, int) or not 1 <= owners <= 8 or not isinstance(targets, int) or not 1 <= targets <= 32 or not isinstance(users, int) or users < targets + 1:
        raise CanaryFailure("fixture has invalid owner/target/user counts")
    shards = info.get("shardIDs")
    if not isinstance(shards, list) or len(shards) != owners or len(set(shards)) != owners:
        raise CanaryFailure("fixture shard list is invalid")
    files = {
        "common.sql": manifest["commonSQLSHA256"],
        "auth-control.sql": manifest["authControlSQLSHA256"],
        f"{layout}/control.sql": info["controlSQLSHA256"],
        f"{layout}/credentials.jsonl": info["credentialFileSHA256"],
    }
    for index in range(owners):
        filename = f"owner-{index:02d}.sql"
        files[f"{layout}/{filename}"] = info["ownerSQLSHA256"][filename]
    for filename, expected in files.items():
        path = fixture / filename
        require_regular(path, filename)
        if not HEX64.fullmatch(expected) or sha256(path) != expected:
            raise CanaryFailure(f"fixture artifact hash mismatch: {filename}")
    key_file = fixture / "access-token-hmac-key.base64"
    require_regular(key_file, "fixture key")
    key = key_file.read_text().strip()
    try:
        if len(base64.b64decode(key, validate=True)) < 32:
            raise ValueError()
    except (ValueError, binascii.Error) as error:
        raise CanaryFailure("fixture HMAC key is invalid") from error
    for private_file in (key_file, fixture / layout / "credentials.jsonl"):
        if private_file.stat().st_mode & 0o077:
            raise CanaryFailure("fixture credential or key is group/world accessible")
    room_ids: set[str] = set()
    user_ids: set[str] = set()
    credentials = (fixture / layout / "credentials.jsonl").read_text().splitlines()
    if len(credentials) != users:
        raise CanaryFailure("fixture credential count mismatch")
    for line in credentials:
        credential = json.loads(line)
        user_ids.add(checked_uuid(credential["userID"], "credential user ID"))
        rooms = credential["targetRoomIDs"]
        if len(rooms) != targets or len(set(rooms)) != targets:
            raise CanaryFailure("fixture targetRoomIDs do not match generator slots")
        room_ids.update(checked_uuid(room, "target room ID") for room in rooms)
    if len(user_ids) != users or len(room_ids) != info["rooms"]:
        raise CanaryFailure("fixture identity/room counts mismatch")
    return manifest, room_ids, user_ids, {"manifestSHA256": sha256(manifest_file), "fixtureID": fixture_id, "tokenKey": key}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-checkout", required=True, type=Path)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--release-dir", required=True, type=Path)
    parser.add_argument("--build-result", required=True, type=Path,
                        help="completed independent Linux Release build result.json")
    parser.add_argument("--loader-products-dir", type=Path,
                        help="corrected Linux Release loader product directory, for both revisions")
    parser.add_argument("--loader-build-result", type=Path,
                        help="independent corrected-loader build result.json")
    parser.add_argument("--legacy-loader-net-admin", action="store_true",
                        help="diagnostic only: run the frozen SOL_SOCKET/SO_DEBUG loader with NET_ADMIN")
    parser.add_argument("--fixture-dir", required=True, type=Path)
    parser.add_argument("--layout", required=True, choices=LAYOUTS)
    parser.add_argument("--docker-context", required=True)
    parser.add_argument("--artifact-dir", required=True, type=Path)
    parser.add_argument("--preflight-only", action="store_true")
    parser.add_argument("--canary-connections", type=int,
                        help="explicit functional canary connections; default preserves the original small canary")
    parser.add_argument("--canary-recovery", action="store_true",
                        help="ten-second 100-connection send and two recovery-batch functional canary")
    parser.add_argument("--measurement-workload", choices=("hot", "same-owner", "mixed", "cold", "fault"),
                        help="opt-in 120/300/60 capacity run with explicit lifecycle/fault evidence")
    parser.add_argument("--measurement-connections", type=int)
    parser.add_argument("--measurement-rate-scale", type=float, default=1.0)
    parser.add_argument("--measurement-freeze-file", type=Path,
                        help="required for candidate runs; created from three stable frozen-main calibrations")
    args = parser.parse_args()
    for name in ("source_checkout", "release_dir", "fixture_dir"):
        path = getattr(args, name).expanduser().resolve()
        if not path.is_dir():
            parser.error(f"{name} must be an existing directory")
        setattr(args, name, path)
    args.artifact_dir = args.artifact_dir.expanduser().resolve()
    args.build_result = args.build_result.expanduser().resolve()
    require_regular(args.build_result, "build result")
    if (args.loader_products_dir is None) != (args.loader_build_result is None):
        parser.error("loader-products-dir and loader-build-result must be provided together")
    if args.loader_products_dir is not None:
        if args.legacy_loader_net_admin:
            parser.error("legacy NET_ADMIN is only for the frozen checkout's own loader")
        args.loader_products_dir = args.loader_products_dir.expanduser().resolve()
        args.loader_build_result = args.loader_build_result.expanduser().resolve()
        if not args.loader_products_dir.is_dir() or args.loader_products_dir.is_relative_to(args.source_checkout):
            parser.error("loader-products-dir must be an independent directory outside source checkout")
        require_regular(args.loader_build_result, "loader build result")
    else:
        args.loader_products_dir = args.release_dir
        args.loader_build_result = args.build_result
    if args.artifact_dir.exists() or args.artifact_dir.is_relative_to(args.source_checkout):
        parser.error("artifact-dir must be new and outside source checkout")
    if args.release_dir.is_relative_to(args.source_checkout):
        parser.error("release-dir must be an independently built directory outside source checkout")
    if not args.docker_context or args.docker_context == "default":
        parser.error("an explicit non-default Docker context is required")
    if args.measurement_workload:
        if args.canary_recovery or args.canary_connections is not None:
            parser.error("canary controls cannot be combined with measurement")
        if args.legacy_loader_net_admin:
            parser.error("measurement never grants legacy NET_ADMIN")
        if args.loader_build_result == args.build_result:
            parser.error("measurement requires the separately verified common corrected loader")
        if args.measurement_connections is None:
            parser.error("measurement-connections is required")
        required_layout = "mixed" if args.measurement_workload == "fault" else args.measurement_workload
        if required_layout != args.layout:
            parser.error("measurement workload must match fixture layout")
        if args.source_sha != "f1cdd78d6a21bf0ae23da627c0710c65115236aa" and args.measurement_freeze_file is None:
            parser.error("candidate measurement requires a main calibration freeze file")
    elif args.measurement_connections is not None or args.measurement_rate_scale != 1.0:
        parser.error("measurement controls require measurement-workload")
    if args.canary_connections is not None and not 1 <= args.canary_connections <= 10_000:
        parser.error("canary-connections must be 1..10000")
    if args.canary_recovery and (args.layout != "mixed" or args.canary_connections != 100 or
                                 args.loader_build_result == args.build_result):
        parser.error("recovery canary requires mixed layout, 100 connections and a separate common loader")
    if args.measurement_freeze_file is not None:
        if not args.measurement_workload:
            parser.error("freeze file only applies to measurement")
        args.measurement_freeze_file = args.measurement_freeze_file.expanduser().resolve()
        require_regular(args.measurement_freeze_file, "measurement freeze file")
    return args


def write_private(path: Path, contents: str) -> None:
    with path.open("x", encoding="utf-8") as stream:
        os.fchmod(stream.fileno(), 0o600)
        stream.write(contents)


def capture_runtime_provenance(*, docker: list[str], compose: list[str],
                               services: dict[str, str], manifest: dict,
                               layout: str, execute: object, psql: object) -> dict:
    """Read only whitelisted machine, container and PostgreSQL settings."""
    template = '{"nCPU":{{json .NCPU}},"memTotal":{{json .MemTotal}},"kernelVersion":{{json .KernelVersion}}}'
    machine = json.loads(execute(docker + ["info", "--format", template],
                                 "provenance.log", 30, record_stdout=False))
    cpus, memory = machine.get("nCPU"), machine.get("memTotal")
    if not isinstance(cpus, int) or not isinstance(memory, int) or cpus <= 0 or memory <= 0:
        raise CanaryFailure("Docker machine envelope is unavailable")
    machine["memoryGiB"] = memory / (1024 ** 3)
    machine["matchesFormal4CPU16GiB"] = cpus == 4 and 15 <= machine["memoryGiB"] <= 17
    boot_id = execute(compose + ["exec", "-T", "gateway", "cat",
                                 "/proc/sys/kernel/random/boot_id"],
                      "provenance.log", 15, record_stdout=False).strip()
    checked_uuid(boot_id, "Docker host boot ID")
    started = {}
    for service in (*services.keys(), "gateway"):
        container_id = execute(compose + ["ps", "-q", service], "provenance.log", 15,
                               record_stdout=False).strip()
        if not re.fullmatch(r"[0-9a-f]{64}", container_id):
            raise CanaryFailure("project container identity unavailable")
        timestamp = execute(docker + ["inspect", "--format", "{{.State.StartedAt}}", container_id],
                            "provenance.log", 15, record_stdout=False).strip()
        if not timestamp or timestamp.startswith("0001-"):
            raise CanaryFailure("project container start time unavailable")
        started[service] = {"containerID": container_id, "startedAt": timestamp}
    names = ("max_connections", "shared_buffers", "work_mem", "synchronous_commit",
             "fsync", "full_page_writes", "statement_timeout", "lock_timeout",
             "track_io_timing", "shared_preload_libraries", "pg_stat_statements.track")
    sql = "SELECT coalesce(json_object_agg(name, setting), '{}'::json)::text FROM pg_settings WHERE name IN (" + \
          ",".join("'" + name + "'" for name in names) + ");"
    postgres = {}
    for service, database in services.items():
        selected = json.loads(psql(service, database, sql, log="provenance-pg.log", timeout=15))
        if any(name not in selected for name in names if name != "pg_stat_statements.track"):
            raise CanaryFailure("PostgreSQL whitelist settings are incomplete")
        postgres[service] = {name: selected.get(name) for name in names}
    return {"machineEnvelope": machine, "bootID": boot_id, "projectContainers": started,
            "postgresSettings": postgres, "fixtureCounts": {
                "users": manifest["users"], "targetsPerConnection": manifest["targetsPerConnection"],
                "owners": manifest["owners"], "rooms": manifest["layouts"][layout]["rooms"],
                "ownerRoomCounts": manifest["layouts"][layout]["ownerRoomCounts"],
                "ownerMembershipCounts": manifest["layouts"][layout]["ownerMembershipCounts"]}}


def make_tls(private: Path, execute: object) -> Path:
    tls = private / "tls"
    tls.mkdir(mode=0o700)
    execute(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes", "-days", "2",
             "-keyout", str(tls / "ca.key"), "-out", str(tls / "ca.pem"),
             "-subj", "/CN=VA capacity canary CA", "-addext", "basicConstraints=critical,CA:TRUE"], "tls.log", 30)
    execute(["openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-sha256",
             "-keyout", str(tls / "gateway.key"), "-out", str(tls / "gateway.csr"),
             "-subj", "/CN=localhost"], "tls.log", 30)
    write_private(tls / "gateway.ext", "subjectAltName=DNS:localhost\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\n")
    execute(["openssl", "x509", "-req", "-in", str(tls / "gateway.csr"),
             "-CA", str(tls / "ca.pem"), "-CAkey", str(tls / "ca.key"), "-CAcreateserial",
             "-days", "2", "-sha256", "-extfile", str(tls / "gateway.ext"),
             "-out", str(tls / "gateway.pem")], "tls.log", 30)
    for key in ("ca.key", "gateway.key"):
        (tls / key).chmod(0o600)
    return tls


def preserve_incomplete_measurement(*, run: Path, current: str | None,
                                    expected: list[str], boundaries: dict,
                                    observations: list[dict], scenario_detail: dict) -> None:
    """Retain observations already captured; never synthesize a missing phase."""
    write_private(run / "measurement-incomplete-snapshots.json", json.dumps({
        "complete": False, "failureStage": current or "before-first-phase",
        "expectedPhaseMarkersRemaining": expected,
        "observedUntilMonotonicNs": time.monotonic_ns(),
        "boundaries": boundaries, "periodic": observations,
        "scenario": scenario_detail}, indent=2, sort_keys=True) + "\n")


def run_measurement(*, args: argparse.Namespace, run: Path, compose: list[str], docker: list[str],
                    environment: dict[str, str], services: dict[str, str],
                    execute: object, psql: object, scenario_detail: dict) -> dict:
    """Run one detached native loader and observe exact phase markers.

    All snapshots remain within this private project. A missed marker, scrape,
    counter reset, timeout or failed loader makes the whole run fail closed.
    """
    gateway_id = execute(compose + ["ps", "-q", "gateway"], "measurement.log", 10).strip()
    if not gateway_id:
        raise MeasurementFailure("Gateway container ID unavailable")
    metrics_url = "http://127.0.0.1:9464/metrics"
    initial_metrics = capture_runtime(docker, {"gateway": gateway_id}, metrics_url, execute)["metrics"]
    if args.source_sha != "f1cdd78d6a21bf0ae23da627c0710c65115236aa":
        required = {"active_rooms", "pending_rooms", "restoring_rooms", "retiring_rooms",
                    "activation_waiters", "outstanding_commands", "outstanding_bytes",
                    "peak_outstanding_commands", "peak_outstanding_bytes", "reservations",
                    "command_rooms", "cached_locations", "pending_resolutions",
                    "active_resolutions", "resolution_waiters"}
        if not all("im_v2_room_actor_" + name in initial_metrics for name in required):
            raise MeasurementFailure("candidate room actor metrics are missing")
    fault = OwnerFailureWindow(compose, execute) if args.measurement_workload == "fault" else None
    if fault and set(services) != {"postgres", "owner00", "owner01"}:
        raise MeasurementFailure("fault requires exactly two owner databases")
    cold_before = None
    if args.measurement_workload == "cold" and args.source_sha != "f1cdd78d6a21bf0ae23da627c0710c65115236aa":
        cold_before = {service: json.loads(psql(service, database, LEASE_COUNTS_SQL,
                            log="measurement-cold-leases.log", timeout=15))
                       for service, database in services.items() if service.startswith("owner")}
    loader_id = execute(compose + ["run", "-d", "--no-deps", "loader"],
                        "measurement-loader-start.log", 60).strip()
    if not re.fullmatch(r"[a-f0-9]{64}", loader_id):
        raise MeasurementFailure("detached loader ID unavailable")
    containers = {**{name: execute(compose + ["ps", "-q", name], "measurement.log", 10).strip()
                     for name in services}, "gateway": gateway_id, "loader": loader_id}
    if any(not re.fullmatch(r"[a-f0-9]{64}", container) for container in containers.values()):
        raise MeasurementFailure("measurement container identity missing")
    observations: list[dict] = []
    boundaries: dict[str, dict] = {}
    current: str | None = None
    expected = ["warmup", "steady", "cooldown"]
    cooldown_deadline: float | None = None
    events: queue.Queue[tuple[str, float] | None] = queue.Queue(maxsize=1024)
    stderr_stream = (run / "loader.log").open("a", encoding="utf-8")
    follow = subprocess.Popen(docker + ["logs", "-f", loader_id], env=environment,
                              stdout=subprocess.PIPE, stderr=stderr_stream,
                              text=True, bufsize=1)

    def read_logs() -> None:
        assert follow.stdout is not None
        try:
            for line in follow.stdout:
                with (run / "loader.log").open("a", encoding="utf-8") as log:
                    log.write(line)
                try:
                    events.put((line, time.monotonic()), timeout=1)
                except queue.Full:
                    events.put(None)
                    return
        finally:
            events.put(None)

    reader = threading.Thread(target=read_logs, daemon=True)
    reader.start()
    deadline = time.monotonic() + 30 * 60
    next_sample = time.monotonic()
    completed = False
    try:
        while True:
            if time.monotonic() >= deadline:
                raise MeasurementFailure("measurement loader exceeded finite deadline")
            if cooldown_deadline is not None and "end" not in boundaries and time.monotonic() >= cooldown_deadline:
                boundaries["end"] = capture_snapshot(psql, docker, compose, services, containers,
                                                      metrics_url, execute,
                                                      allow_stopped_loader=True)
            try:
                item = events.get(timeout=0.5)
            except queue.Empty:
                item = ("", time.monotonic())
            if item is None:
                break
            line, observed_at = item
            if fault:
                fault.observe(line, at=observed_at)
            marker = re.search(r"^scenario phase=(warmup|steady|cooldown) seconds=(\d+)", line)
            if marker:
                name = marker.group(1)
                if not expected or expected.pop(0) != name:
                    raise MeasurementFailure("measurement phase markers missing or out of order")
                marker_ns = time.monotonic_ns()
                snapshot = capture_snapshot(psql, docker, compose, services, containers,
                                            metrics_url, execute)
                snapshot["markerMonotonicNs"] = marker_ns
                boundaries[name] = snapshot
                current = name
                if name == "steady" and fault:
                    fault.begin_steady(at=observed_at)
                if name == "cooldown":
                    cooldown_deadline = marker_ns / 1e9 + 60
                next_sample = time.monotonic() + 5
            if fault and current == "steady":
                fault.tick()
            if current and time.monotonic() >= next_sample:
                observations.append({"phase": current, **capture_runtime(
                    docker, containers, metrics_url, execute,
                    excluded_services={"owner00"} if fault and fault.stopped else None,
                    allow_stopped_loader=current == "cooldown")})
                next_sample = time.monotonic() + 5
        if expected:
            raise MeasurementFailure("measurement ended before all three phases")
        if "end" not in boundaries:
            raise MeasurementFailure("cooldown counter boundary was not observed")
        exit_code = int(execute(docker + ["wait", loader_id], "measurement.log", 30).strip())
        if exit_code != 0 or follow.wait(timeout=10) != 0:
            raise MeasurementFailure("native measurement loader failed")
        report_path = run / "load-report.json"
        require_regular(report_path, "measurement load report")
        report = json.loads(report_path.read_text())
        expected_connections = args.measurement_connections
        if (report.get("requestedConnections") != expected_connections or
                report.get("authenticated") != expected_connections or
                report.get("peakActive") != expected_connections):
            raise MeasurementFailure("single loader did not reach the frozen connection topology")
        phases = report.get("scenarioPhases")
        if not isinstance(phases, list) or [phase.get("name") for phase in phases] != ["warmup", "steady", "cooldown"]:
            raise MeasurementFailure("loader did not report three measurement phases")
        if any(not phase.get("completed") or phase.get("workloadFailed") for phase in phases):
            raise MeasurementFailure("native loader reports incomplete or failed phase")
        if fault:
            validate_fault_unavailable_results(phases)
        if report.get("directRoomAttempted") != 0 or report.get("failed") != 0:
            raise MeasurementFailure("measurement opened a new room or failed a connection")
        if ((report.get("scenarioDrain") or {}).get("drained") is not True or
                report.get("messagesSent") != report.get("messagesAcknowledged")):
            raise MeasurementFailure("measurement left native message outcomes unresolved")
        if args.measurement_workload == "fault" and (
            report.get("messagesSent") != 0 or report.get("messagesAcknowledged") != 0):
            raise MeasurementFailure("fault workload must contain only recovery queries")
        phase_results = {}
        order = (("warmup", "steady"), ("steady", "cooldown"), ("cooldown", "end"))
        for phase, next_phase in order:
            samples = [item for item in observations if item["phase"] == phase]
            delta = phase_delta(boundaries[phase], boundaries[next_phase], samples,
                                restarted_services={"owner00"} if fault and phase == "steady" else None)
            delta["nativeLoader"] = next(item for item in phases if item["name"] == phase)
            delta["observedWindowSeconds"] = (boundaries[next_phase]["monotonicNs"] -
                                               boundaries[phase]["monotonicNs"]) / 1e9
            expected_seconds = {"warmup": 120, "steady": 300, "cooldown": 60}[phase]
            if abs(delta["observedWindowSeconds"] - expected_seconds) > 10:
                raise MeasurementFailure("counter window missed the native phase boundary")
            delta["boundaryCaptureSeconds"] = [boundaries[phase]["captureDurationSeconds"],
                                               boundaries[next_phase]["captureDurationSeconds"]]
            phase_results[phase] = delta
            write_private(run / f"measurement-{phase}.json", json.dumps(delta, indent=2, sort_keys=True) + "\n")
        batch_covered = False
        if scenario_detail["workload"] in ("mixed", "fault"):
            steady = phase_results["steady"]["nativeLoader"]
            for family in ("roomSyncStateBatch", "roomLatestVisibleBatch"):
                value = steady.get(family) or {}
                if value.get("completed", 0) <= 0 or value.get("successfulRooms", 0) <= 0:
                    raise MeasurementFailure("mixed workload did not complete both recovery batch families")
            batch_covered = True
        cold_evidence = None
        if args.measurement_workload == "cold":
            if cold_before is None:
                cold_evidence = {"scope": "not-applicable-frozen-main-without-actor-leases"}
            else:
                cold_after = {service: json.loads(psql(service, database, LEASE_COUNTS_SQL,
                                   log="measurement-cold-leases.log", timeout=15))
                              for service, database in services.items() if service.startswith("owner")}
                cold_evidence = validate_cold_retirement(cold_before, cold_after)
                active_metric = "im_v2_room_actor_active_rooms"
                active_at_cooldown = boundaries["cooldown"]["metrics"].get(active_metric)
                active_at_end = boundaries["end"]["metrics"].get(active_metric)
                if (active_at_cooldown is None or active_at_end is None or
                        active_at_end >= active_at_cooldown):
                    raise MeasurementFailure("cold workload did not reduce active room gauge during cooldown")
                cold_evidence["activeRoomsAtCooldownStart"] = active_at_cooldown
                cold_evidence["activeRoomsAtEnd"] = active_at_end
        fault_evidence = fault.finish() if fault else None
        write_private(run / "measurement-snapshots.json", json.dumps({
            "boundaries": boundaries, "periodic": observations, "scenario": scenario_detail,
            "coldRetirement": cold_evidence, "ownerFailure": fault_evidence},
            indent=2, sort_keys=True) + "\n")
        completed = True
        return {"scenario": scenario_detail, "loadReportSHA256": sha256(report_path),
                "phaseFiles": {name: sha256(run / f"measurement-{name}.json") for name in phase_results},
                "snapshotSHA256": sha256(run / "measurement-snapshots.json"),
                "nativeConnectionsAuthenticated": report.get("authenticated"),
                "nativeMessagesAcknowledged": report.get("messagesAcknowledged"),
                "batchRecoveryQueriesCovered": batch_covered,
                "coldRetirement": cold_evidence, "ownerFailure": fault_evidence,
                "nativeFailed": report.get("failed"), "nativeDirectRoomAttempted": report.get("directRoomAttempted")}
    finally:
        if not completed:
            try:
                preserve_incomplete_measurement(run=run, current=current, expected=expected,
                    boundaries=boundaries, observations=observations,
                    scenario_detail=scenario_detail)
            except (OSError, TypeError, ValueError):
                pass
        if fault:
            fault.cleanup()
        if follow.poll() is None:
            follow.terminate()
        stderr_stream.close()
        try:
            execute(docker + ["rm", "-f", loader_id], "measurement-cleanup.log", 30)
        except (OSError, subprocess.SubprocessError):
            pass


def main() -> int:
    args = parse_args()
    phase = "preflight"
    source = verify_source(args.source_checkout, args.source_sha)
    build_result = read_build_result(args.build_result)
    if (build_result["sourceSHA"] != args.source_sha
            or build_result["lockfileSHA256"] != source["packageResolvedSHA256"]):
        raise CanaryFailure("Linux Release build result does not match source/lockfile/image")
    loader_build_result = read_build_result(args.loader_build_result)
    products = {
        "IMV2ServerApp": verify_product(args.release_dir, "IMV2ServerApp",
                                         build_result["products"]["IMV2ServerApp"]),
        "IMV2GatewayLoadGenerator": verify_product(args.loader_products_dir,
            "IMV2GatewayLoadGenerator", loader_build_result["products"]["IMV2GatewayLoadGenerator"]),
    }
    if (args.canary_recovery or args.measurement_workload in ("mixed", "fault")) and not supports_recovery_loader(
        args.loader_products_dir / "IMV2GatewayLoadGenerator",
        require_timeout=args.measurement_workload == "fault"):
        raise MeasurementFailure("common loader lacks native recovery-batch dispatch support")
    manifest, rooms, users, fixture_info = verify_fixture(args.fixture_dir, args.layout)
    harness = capture_harness_provenance(require_clean=bool(args.measurement_workload))
    if args.canary_recovery and (manifest["owners"] != 2 or manifest["users"] < 100 or
                                 manifest["targetsPerConnection"] < 2 or
                                 min(manifest["layouts"]["mixed"]["ownerRoomCounts"]) == 0):
        raise CanaryFailure("recovery canary requires two populated owners and 100 fixture users")
    scenario_name = "capacity-recovery-canary-v1.json" if args.canary_recovery else "send-one-canary.json"
    scenario = RUNNER_ROOT / "IMV2/scripts/virtual-actor-fixtures" / scenario_name
    require_regular(scenario, "functional canary scenario")
    scenario_document = None
    scenario_detail = None
    if args.measurement_workload:
        protocol_file = RUNNER_ROOT / "IMV2/scripts/virtual-actor-fixtures/capacity-main-v1.json"
        require_regular(protocol_file, "frozen capacity protocol")
        protocol = json.loads(protocol_file.read_text())
        if protocol.get("mainRevision") != "f1cdd78d6a21bf0ae23da627c0710c65115236aa":
            raise MeasurementFailure("frozen main revision changed")
        scenario_document, scenario_detail = create_scenario(
            args.source_checkout, protocol, manifest, args.measurement_workload,
            args.measurement_connections, args.measurement_rate_scale)
        scenario_detail["protocolSHA256"] = sha256(protocol_file)
        scenario_bytes = (json.dumps(scenario_document, indent=2, sort_keys=True) + "\n").encode()
        scenario_hash = hashlib.sha256(scenario_bytes).hexdigest()
        if args.measurement_freeze_file:
            verify_freeze(args.measurement_freeze_file, workload=args.measurement_workload,
                          layout=args.layout, fixture_hash=fixture_info["manifestSHA256"],
                          scenario_hash=scenario_hash,
                          loader_hash=products["IMV2GatewayLoadGenerator"],
                          connections_per_worker=args.measurement_connections,
                          harness_revision=harness["revision"], harness_files=harness["filesSHA256"])
    if args.preflight_only:
        kind = "MEASUREMENT" if scenario_document else "RECOVERY_CANARY" if args.canary_recovery else "CANARY"
        print("VA_CAPACITY_" + kind +
              "_PREFLIGHT_OK source=" + args.source_sha + " layout=" + args.layout)
        return 0
    old_umask = os.umask(0o077)
    args.artifact_dir.mkdir(mode=0o700, parents=False)
    os.umask(old_umask)
    run = args.artifact_dir
    private = run / "private"
    private.mkdir(mode=0o700)
    project = "imv2-va-cap-" + uuid.uuid4().hex[:16]
    docker = ["docker", "--context", args.docker_context]
    environment = {key: value for key, value in os.environ.items() if not key.startswith("IM_V2_")}
    environment["DOCKER_CONTEXT"] = args.docker_context
    env_file = private / ".env.local"
    compose_file = private / "compose.json"
    compose = docker + ["compose", "--project-name", project, "--env-file", str(env_file), "--file", str(compose_file)]
    result: dict[str, object] = {
        "passed": False, "project": project, "layout": args.layout, "source": source,
        "productSHA256": products, "buildResultSHA256": sha256(args.build_result),
        "loaderBuildResultSHA256": sha256(args.loader_build_result),
        "loaderSourceSHA": loader_build_result["sourceSHA"],
        "loaderLockfileSHA256": loader_build_result["lockfileSHA256"],
        "harness": harness,
        "fixtureManifestSHA256": fixture_info["manifestSHA256"],
        "fixtureID": fixture_info["fixtureID"],
        "dockerContext": args.docker_context,
        "credentialMappingSHA256": manifest["layouts"][args.layout]["credentialMappingSHA256"],
        "ownerRoomCounts": manifest["layouts"][args.layout]["ownerRoomCounts"],
        "ownerMembershipCounts": manifest["layouts"][args.layout]["ownerMembershipCounts"],
        "roomCount": manifest["layouts"][args.layout]["rooms"],
        "scenarioSHA256": sha256(scenario) if scenario_document is None else None,
        "mode": "measurement" if scenario_document else ("recovery-canary" if args.canary_recovery else "canary"),
        "swiftImage": IMAGE, "postgresImage": POSTGRES_IMAGE,
        "legacyLoaderNETADMIN": args.legacy_loader_net_admin,
        "mainCalibrationFreezeSHA256": sha256(args.measurement_freeze_file)
        if args.measurement_freeze_file else None,
        "startedAt": time.time(),
    }
    started = False

    def execute(command: list[str], log: str, timeout: int = 180, input_text: str | None = None,
                record_stdout: bool = True) -> str:
        with (run / log).open("a", encoding="utf-8") as output:
            completed = subprocess.run(command, cwd=args.source_checkout, env=environment,
                                       text=True, input=input_text, stdout=subprocess.PIPE,
                                       stderr=output, timeout=timeout, check=True)
            if record_stdout:
                output.write(completed.stdout)
        return completed.stdout

    def psql(service: str, database: str, sql: str, *, log: str = "database.log",
             timeout: int = 180) -> str:
        return execute(compose + ["exec", "-T", service, "psql", "-X", "-At", "-v", "ON_ERROR_STOP=1",
                                  "-U", "im_v2", "-d", database], log, timeout, sql, False)

    try:
        phase = "image inspection"
        result["swiftImageID"] = execute(docker + ["image", "inspect", IMAGE, "--format", "{{.Id}}"], "image.log", 30).strip()
        result["postgresImageID"] = execute(docker + ["image", "inspect", POSTGRES_IMAGE, "--format", "{{.Id}}"], "image.log", 30).strip()
        phase = "private configuration"
        runtime = private / "products"
        runtime.mkdir(mode=0o700)
        for product in products:
            source_directory = (args.release_dir if product == "IMV2ServerApp"
                                else args.loader_products_dir)
            shutil.copy2(source_directory / product, runtime / product)
            if sha256(runtime / product) != products[product]:
                raise CanaryFailure("copied product hash changed")
        shutil.copytree(args.source_checkout / "IMV2/sql", private / "sql")
        shutil.copytree(args.source_checkout / "IMV2/local", private / "local")
        if scenario_document is None:
            shutil.copy2(scenario, private / scenario_name)
        else:
            write_private(private / "measurement-scenario.json",
                          json.dumps(scenario_document, indent=2, sort_keys=True) + "\n")
            result["scenarioSHA256"] = sha256(private / "measurement-scenario.json")
            result["measurementPlan"] = scenario_detail
            result["measurementScenarioSHA256"] = result["scenarioSHA256"]
        password = secrets.token_urlsafe(24)
        secret_names = ["CREDENTIAL_REPLAY_ENVELOPE_KEY", "PUSH_ENDPOINT_ENVELOPE_KEY",
                        "ACCOUNT_EDGE_AUTHORIZATION_SECRET", "ACCOUNT_CLIENT_RATE_LIMIT_HMAC_KEY",
                        "ACCOUNT_ASSERTION_HMAC_KEY", "GROUP_INVITE_TOKEN_HMAC_KEY",
                        "LOCAL_MEDIA_SIGNING_KEY", "OPERATOR_REPLAY_BEARER_TOKEN",
                        "OPERATOR_ACCOUNT_DISABLE_BEARER_TOKEN"]
        write_private(env_file, "IM_V2_LOCAL_POSTGRES_PASSWORD=" + password + "\n"
                      + "IM_V2_ACCESS_TOKEN_HMAC_KEY_BASE64=" + fixture_info["tokenKey"] + "\n"
                      + "".join("IM_V2_" + name + "_BASE64=" + base64.b64encode(secrets.token_bytes(32)).decode() + "\n"
                                for name in secret_names))
        tls = make_tls(private, execute)
        shards = manifest["layouts"][args.layout]["shardIDs"]
        if "IMV2_ROOM_ACTOR_CONFIGURATION_FILE" in (args.source_checkout / "IMV2/docker-compose.local-account.yml").read_text():
            actor_tool = args.source_checkout / "IMV2/scripts/prepare_v2_room_actor_configuration.py"
            require_regular(actor_tool, "actor configuration generator")
            execute([sys.executable, str(actor_tool), "--output-dir", str(private / "local-room-actors"),
                     "--host", "gateway=gateway:7337", "--shards", ",".join(shards),
                     "--mount-root", "/run/im-v2-room-actor"], "actor-configuration.log", 60)
            # Compose normalization also resolves the unused Account mount.
            (private / "local-room-actors/account").mkdir(mode=0o700)
        phase = "compose configuration"
        config_command = docker + ["compose", "--project-directory", str(private), "--env-file", str(env_file),
                                   "--file", str(args.source_checkout / "IMV2/docker-compose.local-account.yml"),
                                   "config", "--format", "json"]
        document = json.loads(execute(config_command, "compose-config.log", 60, record_stdout=False))
        document["name"] = project
        base_pg = document["services"]["postgres"]
        gateway = document["services"]["gateway"]
        owners = manifest["owners"]
        db_names = {"postgres": "imv2_va_control"}
        services = {"postgres": base_pg, "gateway": gateway}
        for index in range(owners):
            service_name = f"owner{index:02d}"
            db_names[service_name] = f"imv2_va_owner{index:02d}"
            owner = deepcopy(base_pg)
            volume_name = f"owner{index:02d}-data"
            owner["volumes"][0]["source"] = volume_name
            document.setdefault("volumes", {})[volume_name] = {"name": project + "-" + volume_name}
            services[service_name] = owner
        for service_name in ["postgres"] + [f"owner{index:02d}" for index in range(owners)]:
            service = services[service_name]
            service["image"] = POSTGRES_IMAGE
            service["environment"]["POSTGRES_DB"] = db_names[service_name]
            service["healthcheck"]["test"] = ["CMD-SHELL", f"pg_isready -U im_v2 -d {db_names[service_name]}"]
            if scenario_document is not None:
                service["command"] = ["postgres", "-c", "shared_preload_libraries=pg_stat_statements",
                                      "-c", "compute_query_id=on", "-c", "pg_stat_statements.max=10000",
                                      "-c", "pg_stat_statements.track=all", "-c", "track_io_timing=on"]
        gateway["image"] = IMAGE
        gateway["command"] = ["/run/va-products/IMV2ServerApp"]
        gateway.pop("restart", None)
        gateway["depends_on"] = {name: {"condition": "service_healthy", "required": True}
                                 for name in db_names}
        gateway["ports"] = [{"mode": "ingress", "host_ip": "127.0.0.1", "target": 7443,
                             "published": "0", "protocol": "tcp"}]
        gateway["volumes"] = [mount for mount in gateway.get("volumes", []) if mount["target"] != "/caddy"]
        gateway["volumes"] += [
            {"type": "bind", "source": str(runtime), "target": "/run/va-products", "read_only": True},
            {"type": "bind", "source": str(tls), "target": "/run/va-tls", "read_only": True},
        ]
        control_url = f"postgres://im_v2:{password}@postgres:5432/{db_names['postgres']}"
        gateway_env = gateway["environment"]
        gateway_env.update({
            "IM_V2_DATABASE_URL": control_url,
            "IM_V2_ACCESS_TOKEN_HMAC_KEY_BASE64": fixture_info["tokenKey"],
            "IM_V2_TLS_CERTIFICATE_CHAIN_PATH": "/run/va-tls/gateway.pem",
            "IM_V2_TLS_PRIVATE_KEY_PATH": "/run/va-tls/gateway.key",
            "IM_V2_CAPACITY_PROFILE_ID": manifest["capacityProfileID"],
            "IM_V2_MAX_ELIGIBLE_MEMBERS": "100000",
            "IM_V2_MAX_COMMANDS_PER_WINDOW": str(manifest["commandWindowLimit"]),
            "IM_V2_USER_SHARD_BUCKET": manifest["userBucket"],
            "IM_V2_DIRECT_ROOM_SHARD_ID": shards[0],
            "IM_V2_GROUP_ROOM_SHARD_ID": ",".join(shards),
            "IM_V2_USER_SHARD_STORES_JSON": json.dumps([{"bucket": manifest["userBucket"],
                "database_url": control_url, "schema": "im_v2"}], separators=(",", ":")),
            "IM_V2_ROOM_SHARD_STORES_JSON": json.dumps([{"shard_id": shard,
                "database_url": f"postgres://im_v2:{password}@owner{index:02d}:5432/{db_names[f'owner{index:02d}']}",
                "schema": "im_v2"} for index, shard in enumerate(shards)], separators=(",", ":")),
        })
        connections = (args.measurement_connections if scenario_document is not None else
                       args.canary_connections if args.canary_connections is not None else
                       min(manifest["users"], max(4, manifest["targetsPerConnection"] + 1)))
        if connections > manifest["users"]:
            raise CanaryFailure("requested canary connections exceed fixture users")
        services["loader"] = {
            "image": IMAGE,
            "command": (["stdbuf", "-oL", "-eL"] if scenario_document is not None else []) +
                       ["/run/va-products/IMV2GatewayLoadGenerator", "--host", "gateway", "--port", "7443",
                        "--server-name", "localhost", "--ca-path", "/run/va-tls/ca.pem",
                        "--credentials", f"/run/va-fixture/{args.layout}/credentials.jsonl",
                        "--report", "/run/va-artifacts/load-report.json", "--revision", args.source_sha,
                        "--connections", str(connections), "--targets-per-connection", str(manifest["targetsPerConnection"]),
                        "--peer-topology", "ring", "--ramp-per-second", str(min(connections, 1000)),
                        "--ramp-batch-size", str(min(connections, 1000)),
                        "--workload-ramp-per-second", str(min(connections, 1000)),
                        "--sync-reads", "1" if args.measurement_workload == "mixed" else "0",
                        "--room-log-reads", "1" if args.measurement_workload == "mixed" else "0",
                        "--max-failure-percent", "0", "--recovery-batch-timeout-seconds",
                        "45" if args.measurement_workload == "fault" else "10", "--scenario",
                        "/run/va-scenario/measurement-scenario.json" if scenario_document is not None
                        else "/run/va-scenario/" + scenario_name],
            "volumes": [
                {"type": "bind", "source": str(runtime), "target": "/run/va-products", "read_only": True},
                {"type": "bind", "source": str(tls), "target": "/run/va-tls", "read_only": True},
                {"type": "bind", "source": str(args.fixture_dir), "target": "/run/va-fixture", "read_only": True},
                {"type": "bind", "source": str(private), "target": "/run/va-scenario", "read_only": True},
                {"type": "bind", "source": str(run), "target": "/run/va-artifacts"},
            ],
        }
        if args.legacy_loader_net_admin:
            # Diagnostic compatibility for the frozen main binary only. Its
            # socketOption(.tcp_nodelay) accidentally sets SO_DEBUG on Linux.
            # Formal canaries use one corrected Release loader for both builds
            # and do not grant NET_ADMIN to any service.
            services["loader"]["cap_add"] = ["NET_ADMIN"]
        document["services"] = services
        for key, volume in document.get("volumes", {}).items():
            volume["name"] = project + "-" + key
        for key, network in document.get("networks", {}).items():
            network["name"] = project + "-" + key
        write_private(compose_file, json.dumps(document, separators=(",", ":")))
        result["composeRuntimeSHA256"] = sha256(compose_file)
        if scenario_document is not None:
            safe_environment = {name: value for name, value in gateway_env.items()
                                if name in {"IM_V2_CAPACITY_PROFILE_ID", "IM_V2_MAX_ELIGIBLE_MEMBERS",
                                            "IM_V2_MAX_COMMANDS_PER_WINDOW", "IM_V2_USER_SHARD_BUCKET",
                                            "IM_V2_DIRECT_ROOM_SHARD_ID", "IM_V2_GROUP_ROOM_SHARD_ID",
                                            "IM_V2_METRICS_HOST", "IM_V2_METRICS_PORT",
                                            "IM_V2_DATABASE_EVENT_LOOP_THREADS",
                                            "IM_V2_DATABASE_MAX_TOTAL_CONNECTIONS"}}
            write_private(run / "measurement-compose-settings.json", json.dumps({
                "project": project, "databaseNames": db_names, "gatewayEnvironment": safe_environment,
                "services": {name: {"image": value.get("image"), "command": value.get("command"),
                                    "memLimit": value.get("mem_limit"), "pidsLimit": value.get("pids_limit")}
                             for name, value in services.items()},
                "swiftImageID": result["swiftImageID"], "postgresImageID": result["postgresImageID"]},
                indent=2, sort_keys=True) + "\n")
            result["measurementComposeSettingsSHA256"] = sha256(run / "measurement-compose-settings.json")
        phase = "database startup"
        started = True
        execute(compose + ["up", "-d", "--wait", "--wait-timeout", "120", *db_names], "startup.log", 180)
        for service, database in db_names.items():
            deadline = time.monotonic() + 90
            while True:
                try:
                    if psql(service, database, "SELECT count(*) FROM im_v2.schema_contract;", log="readiness.log").strip() == "1":
                        break
                except subprocess.SubprocessError:
                    pass
                if time.monotonic() > deadline:
                    raise CanaryFailure("canonical schema readiness timed out")
                time.sleep(1)
        phase = "fixture install"
        marker = fixture_info["fixtureID"]
        for service, database in db_names.items():
            psql(service, database, "CREATE TABLE public.imv2_disposable_fixture_guard (fixture_id uuid PRIMARY KEY); "
                 f"INSERT INTO public.imv2_disposable_fixture_guard VALUES ('{marker}');")
            psql(service, database, (args.fixture_dir / "common.sql").read_text())
            if service == "postgres":
                pieces = ["auth-control.sql", f"{args.layout}/control.sql"]
            else:
                pieces = [f"{args.layout}/{service.replace('owner', 'owner-')}.sql"]
            for piece in pieces:
                psql(service, database, (args.fixture_dir / piece).read_text())
            if scenario_document is not None:
                installed = psql(service, database,
                                 "SELECT count(*) FROM pg_extension WHERE extname = 'pg_stat_statements';")
                if installed.strip() != "1":
                    raise MeasurementFailure("pg_stat_statements not installed on disposable database")
        phase = "gateway startup"
        execute(compose + ["up", "-d", "--wait", "--wait-timeout", "120", "gateway"], "startup.log", 180)
        phase = "runtime provenance"
        provenance = capture_runtime_provenance(
            docker=docker, compose=compose, services=db_names, manifest=manifest,
            layout=args.layout, execute=execute, psql=psql)
        write_private(run / "runtime-provenance.json", json.dumps(provenance, indent=2,
                      sort_keys=True) + "\n")
        result["runtimeProvenanceSHA256"] = sha256(run / "runtime-provenance.json")
        result["machineEnvelope"] = provenance["machineEnvelope"]
        result["formalSamplingEligible"] = (scenario_document is not None and
            provenance["machineEnvelope"]["matchesFormal4CPU16GiB"])
        if scenario_document is not None and not provenance["machineEnvelope"]["matchesFormal4CPU16GiB"]:
            raise MeasurementFailure("formal capacity measurement requires a 4 CPU / 16 GiB Docker host")
        if scenario_document is not None and any(
            settings["pg_stat_statements.track"] != "all"
            for settings in provenance["postgresSettings"].values()):
            raise MeasurementFailure("formal measurement PostgreSQL tracking is not set to all")
        if scenario_document is not None:
            phase = "measurement"
            result["measurement"] = run_measurement(
                args=args, run=run, compose=compose, docker=docker, environment=environment,
                services=db_names, execute=execute, psql=psql, scenario_detail=scenario_detail)
            if result["measurement"]["nativeConnectionsAuthenticated"] != connections:
                raise MeasurementFailure("measurement did not authenticate all requested connections")
            durable_messages = 0
            for index in range(owners):
                actual = psql(f"owner{index:02d}", db_names[f"owner{index:02d}"],
                              "SELECT count(*)::text || '|' || (SELECT count(*)::text FROM im_v2.rooms) "
                              "FROM im_v2.messages;", log="measurement-effect.log", timeout=15).strip()
                count, room_count = map(int, actual.split("|"))
                durable_messages += count
                if room_count != manifest["layouts"][args.layout]["ownerRoomCounts"][index]:
                    raise MeasurementFailure("measurement changed fixture room cardinality")
            if durable_messages != result["measurement"]["nativeMessagesAcknowledged"]:
                raise MeasurementFailure("durable message count differs from native acknowledged count")
            if args.measurement_workload == "fault" and durable_messages != 0:
                raise MeasurementFailure("fault query-only workload wrote durable messages")
            result["measurement"]["durableMessages"] = durable_messages
            result["measurement"]["roomCardinalityUnchanged"] = True
            result["passed"] = True
            phase = "measurement completed"
        else:
            phase = "native recovery canary" if args.canary_recovery else "native one-send canary"
            execute(compose + ["run", "--rm", "--no-deps", "loader"], "loader.log", 180)
            report_file = run / "load-report.json"
            require_regular(report_file, "load report")
            report_file.chmod(0o600)
            report = json.loads(report_file.read_text())
            result["loadReportSHA256"] = sha256(report_file)
            if not (report.get("authenticated") == connections and report.get("workloadFailed") == 0
                    and report.get("directRoomAttempted") == 0 and report.get("failed") == 0):
                raise CanaryFailure("functional canary authentication or workload failed")
            if args.canary_recovery:
                if (report.get("messagesSent", 0) <= 0 or
                        report.get("messagesSent") != report.get("messagesAcknowledged") or
                        (report.get("scenarioDrain") or {}).get("drained") is not True):
                    raise CanaryFailure("recovery canary left messages unresolved")
                phases = report.get("scenarioPhases") or []
                if len(phases) != 1 or phases[0].get("name") != "recovery_canary" or not phases[0].get("completed"):
                    raise CanaryFailure("recovery canary did not complete its ten-second phase")
                for family in ("roomSyncStateBatch", "roomLatestVisibleBatch"):
                    batch = report.get(family) or {}
                    if batch.get("completed", 0) <= 0 or batch.get("successfulRooms", 0) <= 0 or batch.get("rejected", 0) or batch.get("timedOut", 0):
                        raise CanaryFailure("recovery canary did not verify both batch families")
            elif report.get("messagesSent") != 1 or report.get("messagesAcknowledged") != 1:
                raise CanaryFailure("native loader did not acknowledge exactly one preset-room send")
            phase = "durable SQL effect"
            messages: list[tuple[int, str, str, str, int]] = []
            owner_counts: list[int] = []
            for index in range(owners):
                service = f"owner{index:02d}"
                raw = psql(service, db_names[service], "SELECT message_id::text || '|' || room_id::text || '|' || sender_user_id::text || '|' || room_sequence::text FROM im_v2.messages ORDER BY room_id, room_sequence;")
                owner_counts.append(len(raw.splitlines()))
                for line in raw.splitlines():
                    message_id, room, user, sequence = line.split("|")
                    messages.append((index, message_id, room, user, int(sequence)))
                room_count = int(psql(service, db_names[service], "SELECT count(*) FROM im_v2.rooms;").strip())
                if room_count != manifest["layouts"][args.layout]["ownerRoomCounts"][index]:
                    raise CanaryFailure("functional canary created an unplanned room")
            if args.canary_recovery:
                if len(messages) != report["messagesAcknowledged"] or len({m[1] for m in messages}) != len(messages):
                    raise CanaryFailure("owner SQL effects differ from acknowledged recovery-canary sends")
                allowed: dict[str, set[str]] = {}
                with (args.fixture_dir / args.layout / "credentials.jsonl").open() as stream:
                    for index, line in enumerate(stream):
                        if index >= connections:
                            break
                        credential = json.loads(line)
                        allowed[credential["userID"]] = set(credential["targetRoomIDs"])
                if len(allowed) != connections:
                    raise CanaryFailure("recovery canary credential mapping is incomplete")
                sequences: dict[str, list[int]] = {}
                for owner_index, _, room, user, sequence in messages:
                    if room not in rooms or user not in users or room not in allowed.get(user, set()):
                        raise CanaryFailure("recovery canary persisted an unauthorized room send")
                    actual_shard = psql("postgres", db_names["postgres"],
                        f"SELECT room_shard_id FROM im_v2.room_owner_routes WHERE room_id = '{room}'::uuid;").strip()
                    if actual_shard != shards[owner_index]:
                        raise CanaryFailure("recovery canary message owner differs from authoritative route")
                    sequences.setdefault(room, []).append(sequence)
                if any(sorted(values) != list(range(1, len(values) + 1)) for values in sequences.values()):
                    raise CanaryFailure("recovery canary room sequences are not unique and contiguous")
                result["durableEffect"] = {"messageRows": len(messages), "ownerMessageCounts": owner_counts,
                                           "roomsWritten": len(sequences), "roomCardinalityUnchanged": True}
                result["loader"] = {"connections": connections, "messagesSent": report["messagesSent"],
                                    "messagesAcknowledged": report["messagesAcknowledged"],
                                    "roomSyncStateSuccessfulRooms": report["roomSyncStateBatch"]["successfulRooms"],
                                    "roomLatestVisibleSuccessfulRooms": report["roomLatestVisibleBatch"]["successfulRooms"],
                                    "directRoomAttempted": 0}
            else:
                if len(messages) != 1 or messages[0][2] not in rooms or messages[0][3] not in users or messages[0][4] != 1:
                    raise CanaryFailure("owner databases did not persist one authorized room message")
                owner_index, _, room_id, _, sequence = messages[0]
                actual_shard = psql("postgres", db_names["postgres"],
                    f"SELECT room_shard_id FROM im_v2.room_owner_routes WHERE room_id = '{room_id}'::uuid;").strip()
                if actual_shard != shards[owner_index]:
                    raise CanaryFailure("message owner does not match authoritative room route")
                result["durableEffect"] = {"roomID": room_id, "ownerIndex": owner_index,
                                           "roomSequence": sequence, "messageRows": 1}
                result["loader"] = {"connections": connections, "messagesSent": 1,
                                    "messagesAcknowledged": 1, "directRoomAttempted": 0}
            result["passed"] = True
    except (CanaryFailure, MeasurementFailure, subprocess.SubprocessError, OSError, ValueError,
            KeyError, json.JSONDecodeError) as error:
        result["failureType"] = type(error).__name__
        result["failurePhase"] = phase
    finally:
        incomplete = run / "measurement-incomplete-snapshots.json"
        if incomplete.is_file():
            result["incompleteMeasurementSnapshotsSHA256"] = sha256(incomplete)
        if started:
            try:
                result["projectDiagnostics"] = capture_project_diagnostics(
                    compose=compose, service_names=list(services), run=run,
                    environment=environment)
            except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError):
                result["projectDiagnosticsUnavailable"] = True
            try:
                execute(compose + ["down", "--volumes", "--remove-orphans", "--timeout", "180"], "cleanup.log", 240)
            except (subprocess.SubprocessError, OSError):
                result["cleanupFailed"] = True
                result["passed"] = False
        if not result.get("cleanupFailed"):
            shutil.rmtree(private)
        result["finishedAt"] = time.time()
        write_private(run / "result.json", json.dumps(result, indent=2, sort_keys=True) + "\n")
        print("VA_CAPACITY_" + ("MEASUREMENT" if scenario_document else "CANARY") +
              "_" + ("OK" if result["passed"] else "FAILED") + " evidence=" + str(run))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (CanaryFailure, MeasurementFailure, subprocess.SubprocessError, OSError, ValueError,
            KeyError, json.JSONDecodeError) as error:
        print("VA_CAPACITY_CANARY_PREFLIGHT_FAILED type=" + type(error).__name__, file=sys.stderr)
        raise SystemExit(1)
