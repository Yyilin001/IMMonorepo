#!/usr/bin/env python3
"""Restore an owned PostgreSQL 16 cluster from a physical backup and archived WAL.

Requires local PostgreSQL binaries; never connects to an existing server. The
report measures this small local fixture, not production RPO/RTO or key recovery.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
SCHEMA = ROOT / "IMV2/sql/schema.sql"
CONTRACT = ROOT / "IMV2/scripts/current_v2_schema_contract.sql"
ROLE = "im_v2_pitr"
PORT = "55478"  # Separate private Unix-socket directories; no TCP listeners.
AUDIT = "SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY operation_id),'[]')::text FROM im_v2.durable_work_replay_audit a"


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def sql_literal(value):
    return "'" + str(value).replace("'", "''") + "'"


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def wait_until(predicate, label, timeout=30):
    deadline = time.monotonic() + timeout
    while not predicate():
        require(time.monotonic() < deadline, f"Timed out waiting for {label}")
        time.sleep(0.1)


class Drill:
    def __init__(self, binaries, output):
        sources = {str(p.relative_to(ROOT)): digest(p) for p in (SCHEMA, CONTRACT, Path(__file__).resolve())}
        self.binaries = binaries
        self.output = output
        self.work = Path(tempfile.mkdtemp(prefix="imv2-pitr-", dir="/tmp"))
        self.source = self.work / "source"
        self.backup = self.work / "backup"
        self.recovered = self.work / "recovered"
        self.archive = self.work / "archive"
        self.archive.mkdir()
        # Ignore ambient database credentials, services and options. Every client
        # receives an explicit private socket, role, port and database.
        self.environment = {k: v for k, v in os.environ.items() if not k.startswith("PG")}
        self.environment["PGCONNECT_TIMEOUT"] = "5"
        self.report = {
            "status": "running",
            "scope": "local PostgreSQL 16 physical backup and WAL time-target recovery",
            "excludes": ["production scale", "cross-region transport", "encryption/key recovery",
                         "failover routing", "writes during outage", "approved RPO/RTO"],
            "sources": sources,
        }

    def run(self, tool, *arguments, timeout=90, check=True):
        command = [str(self.binaries / tool), *map(str, arguments)]
        with (self.output / "commands.log").open("a") as log:
            log.write("$ " + shlex.join(command) + "\n")
            log.flush()
            result = subprocess.run(command, env=self.environment, text=True,
                                    stdout=subprocess.PIPE, stderr=log, timeout=timeout)
            log.write(result.stdout + f"\nexit={result.returncode}\n")
        if check:
            require(result.returncode == 0, f"{tool} exited {result.returncode}; see commands.log")
        return result.stdout.strip()

    def socket(self, name):
        return self.work / f"{name}-socket"

    def sql(self, name, statement=None, file=None):
        args = ["-XqAtw", "-v", "ON_ERROR_STOP=1", "-h", self.socket(name),
                "-p", PORT, "-U", ROLE, "-d", "postgres"]
        args.extend(["-f", file] if file else ["-c", statement])
        return self.run("psql", *args)

    def configure(self, directory, name, **settings):
        self.socket(name).mkdir()
        values = {
            "listen_addresses": "", "unix_socket_directories": str(self.socket(name)),
            "port": PORT, "timezone": "UTC", "fsync": "on", "full_page_writes": "on",
            "synchronous_commit": "on", "hot_standby": "on", **settings,
        }
        with (directory / "postgresql.conf").open("a") as config:
            config.write("\n# Owned disposable PITR drill settings.\n")
            for key, value in values.items():
                config.write(f"{key} = {sql_literal(value)}\n")

    def start(self, directory, name):
        self.run("pg_ctl", "-D", directory, "-l", self.output / f"{name}.postgres.log",
                 "-w", "-t", "30", "start", timeout=40)

    def stop(self, directory):
        if (directory / "postmaster.pid").exists():
            self.run("pg_ctl", "-D", directory, "-m", "fast", "-w", "-t", "20", "stop", timeout=30)

    def mark(self, name, phase, suffix):
        self.sql(name, f"""
            INSERT INTO im_v2.durable_work_replay_audit
                (operation_id, operator_principal, target_kind, source_event_id,
                 target_user_id, projection_kind, reason_code, requested_at, outcome)
            VALUES ('00000000-0000-0000-0000-00000000{suffix}', {sql_literal(phase)},
                'user_state_event', '00000000-0000-0000-0000-00000000d720',
                '00000000-0000-0000-0000-00000000d721', 'membership',
                'dependency_recovered', clock_timestamp(), 'requeued')
            """)

    def execute(self):
        version = self.run("postgres", "--version")
        require(re.search(r"PostgreSQL\) 16\.", version), "This drill requires PostgreSQL 16 binaries")
        self.report["postgresVersion"] = version
        self.run("initdb", "-D", self.source, "-U", ROLE, "--auth-local=trust",
                 "--auth-host=reject", "--no-locale", "--encoding=UTF8", "--data-checksums")
        archive_template = shlex.quote(str(self.archive / "%f"))
        self.configure(self.source, "source", wal_level="replica", archive_mode="on",
                       archive_command=f"test ! -f {archive_template} && cp '%p' {archive_template}")
        self.start(self.source, "source")
        self.sql("source", file=SCHEMA)
        require(self.sql("source", file=CONTRACT) == "t", "Canonical source schema failed readiness")
        self.report["schemaID"] = self.sql("source", "SELECT schema_id FROM im_v2.schema_contract")
        self.mark("source", "before_backup", "d711")

        backup_started = time.monotonic()
        # No streamed or copied WAL in the base backup: recovery must use the
        # archive. This also prevents mistaking a standalone backup for PITR.
        self.run("pg_basebackup", "-D", self.backup, "-h", self.socket("source"),
                 "-p", PORT, "-U", ROLE, "--no-password", "--format=plain",
                 "--wal-method=none", "--checkpoint=fast", "--manifest-checksums=SHA256")
        self.report["baseBackupSeconds"] = round(time.monotonic() - backup_started, 3)
        require(not any(p.is_file() for p in (self.backup / "pg_wal").iterdir()),
                "Base backup unexpectedly contains WAL segments")
        self.mark("source", "before_target", "d712")
        expected = json.loads(self.sql("source", AUDIT))
        target = self.sql("source", "SELECT clock_timestamp()::text")
        self.report["recoveryTargetTime"] = target
        require(self.sql("source", f"SELECT clock_timestamp() > {sql_literal(target)}::timestamptz") == "t",
                "Source clock did not advance beyond recovery target")
        self.mark("source", "after_target", "d713")
        original = json.loads(self.sql("source", AUDIT))
        require(len(original) == 3 and len(expected) == 2, "Unexpected audit fixture rows")
        target_wal = self.sql("source", "SELECT pg_walfile_name(pg_current_wal_insert_lsn())")
        self.sql("source", "SELECT pg_switch_wal()")
        wait_until(lambda: (self.source / "pg_wal/archive_status" / f"{target_wal}.done").exists(),
                   "the completed target WAL archive")
        require(digest(self.source / "pg_wal" / target_wal) == digest(self.archive / target_wal),
                "Archived target WAL differs from the source")
        self.report["archiveStats"] = json.loads(self.sql("source", """
            SELECT json_build_object('archivedCount', archived_count, 'failedCount', failed_count)::text
            FROM pg_stat_archiver
            """))
        require(self.report["archiveStats"]["failedCount"] == 0, "WAL archiving failed during the drill")
        self.run("pg_verifybackup", "--wal-directory", self.archive, self.backup)
        self.report["backupVerified"] = True
        self.report["baseBackupManifestSHA256"] = digest(self.backup / "backup_manifest")
        self.report["archivedWAL"] = [
            {"name": p.name, "bytes": p.stat().st_size, "sha256": digest(p)}
            for p in sorted(self.archive.iterdir()) if re.fullmatch(r"[0-9A-F]{24}", p.name)
        ]
        require(self.report["archivedWAL"], "No WAL segments were archived")
        self.stop(self.source)
        shutil.rmtree(self.source)
        self.report["sourceRemovedBeforeRecovery"] = True

        # Includes copying the local backup, startup, time-target inspection and
        # the first committed recovered write. It excludes incident detection,
        # remote transfer and key retrieval, so is not a production RTO.
        recovery_started = time.monotonic()
        shutil.copytree(self.backup, self.recovered)
        self.configure(self.recovered, "recovered", archive_mode="off", archive_command="",
                       restore_command=f"cp {archive_template} '%p'",
                       recovery_target_time=target, recovery_target_timeline="1",
                       recovery_target_action="pause", recovery_target_inclusive="on")
        (self.recovered / "recovery.signal").touch()
        self.start(self.recovered, "recovered")
        wait_until(lambda: self.sql("recovered", "SELECT pg_is_in_recovery() AND pg_is_wal_replay_paused()") == "t",
                   "recovery to pause at the requested time")
        restored = json.loads(self.sql("recovered", AUDIT))
        require(restored == expected, "Recovered durable audit does not match the time-target snapshot")
        require(self.sql("recovered", file=CONTRACT) == "t", "Recovered schema failed readiness")
        require(self.sql("recovered", "SELECT schema_id FROM im_v2.schema_contract") == self.report["schemaID"],
                "Recovered schema contract row differs")
        self.report["replayPosition"] = json.loads(self.sql("recovered", """
            SELECT json_build_object('lsn', pg_last_wal_replay_lsn(),
                'lastTransactionTime', pg_last_xact_replay_timestamp())::text
            """))
        self.report["retainedAuditRows"] = restored
        self.report["excludedAuditRows"] = [row for row in original if row not in restored]
        self.sql("recovered", "SELECT pg_wal_replay_resume()")
        wait_until(lambda: self.sql("recovered", "SELECT NOT pg_is_in_recovery()") == "t", "recovery to end")
        self.mark("recovered", "after_recovery", "d714")
        final = json.loads(self.sql("recovered", AUDIT))
        require(len(final) == 3 and final[:2] == expected and final[-1]["operator_principal"] == "after_recovery",
                "Post-recovery write failed or excluded transaction reappeared")
        self.report["localRecoverySeconds"] = round(time.monotonic() - recovery_started, 3)
        self.report["postRecoveryWriteCommitted"] = True
        self.report["status"] = "passed"

    def cleanup(self):
        errors = []
        for directory in (self.recovered, self.source):
            try:
                self.stop(directory)
            except Exception as error:
                errors.append(str(error))
        if errors:
            self.report.update(status="failed", cleanupErrors=errors, ownedDirectoryRetained=str(self.work))
        else:
            shutil.rmtree(self.work)
        self.report["ownedDirectoryRemoved"] = not self.work.exists()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pg-bin", type=Path, required=True, help="PostgreSQL 16 binary directory")
    parser.add_argument("--output-dir", type=Path, required=True, help="New directory for JSON evidence and logs")
    args = parser.parse_args()
    for tool in ("postgres", "initdb", "pg_ctl", "psql", "pg_basebackup", "pg_verifybackup", "pg_waldump"):
        if not os.access(args.pg_bin / tool, os.X_OK):
            parser.error(f"Missing executable: {args.pg_bin / tool}")
    args.output_dir.mkdir(parents=True, exist_ok=False)
    drill = Drill(args.pg_bin.resolve(), args.output_dir.resolve())
    started = time.monotonic()

    def interrupted(signum, frame):
        raise KeyboardInterrupt(f"signal {signum}")

    signal.signal(signal.SIGTERM, interrupted)
    try:
        drill.execute()
    except BaseException as error:
        drill.report.update(status="failed", error=f"{type(error).__name__}: {error}")
    finally:
        drill.cleanup()
        drill.report["totalSeconds"] = round(time.monotonic() - started, 3)
        report_path = drill.output / "report.json"
        report_path.write_text(json.dumps(drill.report, indent=2) + "\n")
    print(f"PostgreSQL PITR drill {drill.report['status']}: {report_path}")
    return 0 if drill.report["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
