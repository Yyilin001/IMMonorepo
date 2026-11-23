#!/usr/bin/env python3
"""Copy one stopped logical shard into an empty database. No routing or source mutations."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile


def connection(service):
    if not re.fullmatch(r"[A-Za-z0-9_-]+", service):
        raise ValueError("use a libpq service name")
    return "service=" + service


def query(service, sql):
    return subprocess.check_output(["psql", "-XwqAt", "-v", "ON_ERROR_STOP=1",
                                    "-d", connection(service), "-c", sql], text=True).strip()


def assert_drained(service):
    if query(service, """SELECT current_setting('transaction_read_only') = 'on'
        AND NOT EXISTS (SELECT FROM pg_stat_activity WHERE datname=current_database()
                        AND backend_type='client backend' AND pid<>pg_backend_pid())
        AND NOT EXISTS (SELECT FROM pg_prepared_xacts WHERE database=current_database())""") != "t":
        raise ValueError("fence the source, stop clients, settle transactions and set the source database read-only")


def fingerprint(service):
    # Compare all application rows in a canonical order, irrespective of heap order.
    tables = query(service, """SELECT quote_ident(n.nspname)||'.'||quote_ident(c.relname)
        FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE n.nspname='im_v2' AND c.relkind='r' ORDER BY 1""").splitlines()
    if not tables:
        raise ValueError("missing shard schema")
    digest = hashlib.sha256()
    for table in tables:
        digest.update((table + "\n").encode())
        sql = ("COPY (SELECT encode(sha256(convert_to(row_to_json(t)::text,'UTF8')),'hex') "
               f'COLLATE "C" AS digest FROM ONLY {table} t ORDER BY digest) TO STDOUT')
        with subprocess.Popen(["psql", "-XwqAt", "-v", "ON_ERROR_STOP=1", "-d",
                               connection(service), "-c", sql], stdout=subprocess.PIPE) as proc:
            for block in iter(lambda: proc.stdout.read(1024 * 1024), b""):
                digest.update(block)
            if proc.wait():
                raise ValueError("table verification failed")
    for seq in query(service, """SELECT format('%I.%I',schemaname,sequencename) FROM pg_sequences
                                WHERE schemaname='im_v2' ORDER BY 1""").splitlines():
        digest.update((seq + ":" + query(service, f"SELECT last_value,is_called FROM {seq}") + "\n").encode())
    return digest.hexdigest()


def copy(args):
    if not re.fullmatch(r"(?:user:)?[A-Za-z0-9_.-]{1,128}", args.shard):
        raise ValueError("invalid logical shard ID")
    expected = query(args.control, "SELECT source_id FROM im_v2.deployment_shard_sources "
                     f"WHERE logical_id='{args.shard}'")
    identity_sql = "SELECT source_id FROM im_v2.realtime_journal_source_identity WHERE singleton"
    if not expected or query(args.source, identity_sql) != expected:
        raise ValueError("source identity differs from control directory")
    assert_drained(args.source)
    if query(args.target, """SELECT NOT EXISTS (SELECT FROM pg_namespace WHERE nspname NOT LIKE 'pg_%'
                     AND nspname NOT IN ('information_schema','public'))
            AND NOT EXISTS (SELECT FROM pg_class WHERE relnamespace='public'::regnamespace)
            AND NOT EXISTS (SELECT FROM pg_proc WHERE pronamespace='public'::regnamespace)
            AND NOT EXISTS (SELECT FROM pg_type WHERE typnamespace='public'::regnamespace)""") != "t":
        raise ValueError("target must be a dedicated empty database")
    with tempfile.TemporaryDirectory(prefix="imv2-shard-") as tmp:
        archive = Path(tmp) / "shard.dump"
        subprocess.run(["pg_dump", "-w", "-Fc", "-d", connection(args.source), "-f", archive], check=True)
        subprocess.run(["pg_restore", "-w", "--exit-on-error", "--single-transaction",
                        "-d", connection(args.target), archive], check=True)
    assert_drained(args.source)
    if query(args.target, identity_sql) != expected or fingerprint(args.source) != fingerprint(args.target):
        raise ValueError("restored shard did not pass verification; keep traffic stopped")
    assert_drained(args.source)
    print(f"Verified {args.shard} ({expected}). Source remains fenced; routing has not changed.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("control", "source", "target"):
        parser.add_argument("--" + option, required=True, help="libpq service name")
    parser.add_argument("--shard", required=True, help="room shard ID or user:<bucket>")
    os.environ["PGOPTIONS"] = (os.environ.get("PGOPTIONS", "") +
        " -c timezone=UTC -c datestyle=ISO,YMD -c intervalstyle=postgres -c bytea_output=hex -c extra_float_digits=3").strip()
    try:
        copy(parser.parse_args())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error) + "\n")
