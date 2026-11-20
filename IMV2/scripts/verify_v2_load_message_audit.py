#!/usr/bin/env python3
"""Check every recorded TCP send outcome against the authoritative room databases."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

HEADER = b"room_id,sender_user_id,client_message_id,message_id,room_sequence,outcome"
CREATE = """
CREATE TEMP TABLE load_message_audit (
    room_id uuid NOT NULL, sender_user_id uuid NOT NULL, client_message_id uuid NOT NULL,
    message_id uuid, room_sequence bigint NOT NULL, outcome text NOT NULL,
    PRIMARY KEY (room_id, sender_user_id, client_message_id),
    CHECK ((outcome='accepted' AND message_id IS NOT NULL AND room_sequence>0)
        OR (outcome IN ('unknown','failed') AND message_id IS NULL AND room_sequence=0)))
"""
CHECK = """
SELECT json_build_object(
    'rows', count(*),
    'ack', count(*) FILTER (WHERE a.outcome='accepted'),
    'ack_mismatch', count(*) FILTER (WHERE a.outcome='accepted' AND (
        m.message_id IS DISTINCT FROM a.message_id OR m.room_sequence IS DISTINCT FROM a.room_sequence
        OR c.message_id IS DISTINCT FROM a.message_id OR c.room_sequence IS DISTINCT FROM a.room_sequence)),
    'stored_receipt_mismatch', count(*) FILTER (WHERE
        m.message_id IS DISTINCT FROM c.message_id OR m.room_sequence IS DISTINCT FROM c.room_sequence),
    'unknown', count(*) FILTER (WHERE a.outcome='unknown'),
    'unknown_committed', count(*) FILTER (WHERE a.outcome='unknown' AND m.message_id IS NOT NULL),
    'failed_committed', count(*) FILTER (WHERE a.outcome='failed' AND m.message_id IS NOT NULL))
FROM load_message_audit a JOIN im_v2.rooms r ON r.room_id=a.room_id
LEFT JOIN im_v2.messages m ON (m.room_id,m.sender_user_id,m.client_message_id)
    = (a.room_id,a.sender_user_id,a.client_message_id)
LEFT JOIN im_v2.message_send_completions c ON (c.room_id,c.sender_user_id,c.client_message_id)
    = (a.room_id,a.sender_user_id,a.client_message_id)
"""


def verify(ledgers, services, psql):
    rows = 0
    databases = {}
    expected_rooms = set()
    resolved_rooms = set()
    duplicate_rooms = set()
    # Send CSV as COPY data. Neither credentials nor filesystem paths become SQL.
    with tempfile.TemporaryFile() as data:
        for ledger in ledgers:
            with ledger.open("rb") as source:
                if source.readline().rstrip(b"\r\n") != HEADER:
                    raise ValueError(f"unexpected audit header in {ledger.name}")
                for line in source:
                    expected_rooms.add(str(uuid.UUID(line.partition(b",")[0].decode("ascii"))))
                    data.write(line)
                    rows += 1

        for service in services:
            data.seek(0)
            command = [psql, "-XqAt", "-v", "ON_ERROR_STOP=1", "-c", CREATE,
                       "-c", "COPY load_message_audit FROM STDIN WITH (FORMAT csv)",
                       "-c", "ANALYZE load_message_audit", "-c", CHECK,
                       "-c", "SELECT DISTINCT a.room_id FROM load_message_audit a JOIN im_v2.rooms r USING(room_id)"]
            result = subprocess.run(command, stdin=data, stdout=subprocess.PIPE, check=True,
                                    env=dict(os.environ, PGSERVICE=service))
            summary, *rooms = result.stdout.decode("ascii").splitlines()
            databases[service] = json.loads(summary)
            duplicate_rooms.update(resolved_rooms.intersection(rooms))
            resolved_rooms.update(rooms)

    totals = {key: sum(db[key] for db in databases.values()) for key in next(iter(databases.values()))}
    missing_rooms = expected_rooms - resolved_rooms
    return {"client_rows": rows, "totals": totals, "databases": databases,
            "missing_rooms": len(missing_rooms), "duplicate_rooms": len(duplicate_rooms),
            "passed": not missing_rooms and not duplicate_rooms and totals["rows"] == rows
                      and totals["ack"] > 0 and totals["ack_mismatch"] == 0
                      and totals["stored_receipt_mismatch"] == 0 and totals["failed_committed"] == 0}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ledger", type=Path, action="append", required=True,
                        help="report sidecar generated with --message-audit-max-rows")
    parser.add_argument("--room-service", action="append", required=True,
                        help="libpq service for each distinct authoritative room database")
    parser.add_argument("--psql", default="psql")
    args = parser.parse_args()
    if len(set(args.room_service)) != len(args.room_service):
        parser.error("room services must be distinct")
    result = verify(args.ledger, args.room_service, args.psql)
    print(json.dumps(result, indent=2))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
