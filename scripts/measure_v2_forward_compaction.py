#!/usr/bin/env python3
"""Measure the actual Swift compactor SQL in one script-owned disposable database.

Requires explicit PGHOST/PGPORT/PGUSER with CREATE DATABASE permission. No server
settings are changed. This is an SQL cost probe, not production capacity evidence.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import textwrap
import uuid

ROOT = Path(__file__).resolve().parents[1]
NOW = "TIMESTAMPTZ '2026-09-19 00:00:00+00'"
CUTOFF = "TIMESTAMPTZ '2026-09-12 00:00:00+00'"
SOURCES = {
    "source": ROOT / "IMV2Server/Sources/IMV2ServerInfrastructure/PostgresV2ForwardExportCompactor.swift",
    "target": ROOT / "IMV2Server/Sources/IMV2ServerInfrastructure/PostgresV2ForwardInboxCompactor.swift",
}


def query(side, limit):
    # Fail closed if the SQL gains new bindings; never measure a stale copy.
    source = SOURCES[side].read_text()
    opening, closing = 'sql.raw("""', '""")'
    assert source.count(opening) == 1
    sql = textwrap.dedent(source.split(opening, 1)[1].split(closing, 1)[0]).strip()
    for binding, value in [("cutoff", CUTOFF), ("now", NOW), ("limit", str(limit))]:
        sql = sql.replace("\\(bind: " + binding + ")", value)
    assert "\\(" not in sql, "Unrecognized Swift SQL interpolation"
    return sql


def run(database, sql):
    result = subprocess.run(["psql", "-X", "-v", "ON_ERROR_STOP=1", "-A", "-t", "-q", "-d", database],
                            input=sql, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result.stdout.strip()


def seed(rows, text_bytes):
    assert rows >= 1000 and text_bytes % 32 == 0
    return f"""
CREATE TABLE im_v2.compaction_cost_fixture AS
SELECT n, n % 20 AS bucket, gen_random_uuid() AS export_id, gen_random_uuid() AS actor_id,
       gen_random_uuid() AS operation_id, gen_random_uuid() AS source_room,
       gen_random_uuid() AS source_message, gen_random_uuid() AS target_room,
       gen_random_uuid() AS client_id, gen_random_uuid() AS result_id,
       CASE WHEN n % 20 = 1 THEN {NOW} - interval '1 day' ELSE {NOW} - interval '10 days' END AS terminal_at,
       NULL::bytea AS payload, NULL::bytea AS digest
FROM generate_series(1, {rows}) AS n;
UPDATE im_v2.compaction_cost_fixture f SET payload = convert_to(jsonb_build_object(
    'version',1,'exportID',export_id,'actorUserID',actor_id,'operationID',operation_id,
    'sourceRoomID',source_room,'sourceMessageID',source_message,'sourceRevision',1,
    'sourceSenderUserID',actor_id,'sourceShardID','source','sourceEpoch',0,
    'targetRoomID',target_room,'targetClientMessageID',client_id,'targetShardID','target','targetEpoch',0,
    'text',(SELECT string_agg(md5(f.n::text || ':' || g::text), '' ORDER BY g)
            FROM generate_series(1, {text_bytes // 32}) g), 'entities','[]'::jsonb,'media','[]'::jsonb)::text,'UTF8');
UPDATE im_v2.compaction_cost_fixture SET digest = sha256(payload);
INSERT INTO im_v2.rooms(room_id,room_shard_id,capacity_profile_id)
SELECT source_room,'source','cost' FROM im_v2.compaction_cost_fixture
UNION ALL SELECT target_room,'target','cost' FROM im_v2.compaction_cost_fixture;
ANALYZE im_v2.rooms;
INSERT INTO im_v2.message_forward_exports
(export_id,actor_user_id,operation_id,source_room_id,source_message_id,source_content_revision,
 source_shard_id,source_epoch,target_room_id,target_client_message_id,target_shard_id,target_epoch,
 payload,payload_digest,media_ids,created_at)
SELECT export_id,actor_id,operation_id,source_room,source_message,1,'source',0,target_room,client_id,
 'target',0,payload,digest,'{{}}',{NOW} - interval '11 days' FROM im_v2.compaction_cost_fixture;
INSERT INTO im_v2.message_forward_export_receipts
SELECT export_id,digest,CASE WHEN (n / 20) % 2 = 0 THEN 'completed' ELSE 'rejected' END,
 CASE WHEN (n / 20) % 2 = 0 THEN result_id END,CASE WHEN (n / 20) % 2 = 0 THEN 1::bigint END,
 CASE WHEN (n / 20) % 2 <> 0 THEN 'FORBIDDEN' END,terminal_at
FROM im_v2.compaction_cost_fixture WHERE bucket NOT IN (2,3,4);
INSERT INTO im_v2.message_forward_delivery_jobs
(export_id,state,claim_token,lease_expires_at,next_attempt_at,retry_count,created_at,completed_at)
SELECT export_id,CASE bucket WHEN 2 THEN 'pending' WHEN 3 THEN 'claimed' WHEN 4 THEN 'paused' ELSE 'completed' END,
 CASE WHEN bucket=3 THEN gen_random_uuid() END,CASE WHEN bucket=3 THEN {NOW} + interval '1 hour' END,
 CASE WHEN bucket=2 THEN {NOW} END,0,{NOW} - interval '11 days',
 CASE WHEN bucket NOT IN (2,3,4) THEN terminal_at END FROM im_v2.compaction_cost_fixture;
INSERT INTO im_v2.message_forward_inbox
(export_id,actor_user_id,operation_id,source_message_id,target_room_id,target_client_message_id,
 target_shard_id,target_epoch,payload,payload_digest,state,result_message_id,result_room_sequence,
 error_code,created_at,accepted_at,completed_at)
SELECT export_id,actor_id,operation_id,source_message,target_room,client_id,'target',0,payload,digest,
 CASE WHEN bucket IN (2,3) THEN 'pending' WHEN bucket=4 THEN 'accepted'
      WHEN (n / 20)%2=0 THEN 'completed' ELSE 'rejected' END,
 CASE WHEN bucket=4 OR (bucket NOT IN (2,3) AND (n / 20)%2=0) THEN result_id END,
 CASE WHEN bucket=4 OR (bucket NOT IN (2,3) AND (n / 20)%2=0) THEN 1::bigint END,
 CASE WHEN bucket NOT IN (2,3,4) AND (n / 20)%2<>0 THEN 'FORBIDDEN' END,{NOW} - interval '11 days',
 CASE WHEN bucket=4 OR (bucket NOT IN (2,3) AND (n / 20)%2=0) THEN terminal_at END,
 CASE WHEN bucket NOT IN (2,3,4) THEN terminal_at END FROM im_v2.compaction_cost_fixture;
UPDATE im_v2.message_forward_exports e SET payload=NULL,payload_compacted_at={NOW}
FROM im_v2.compaction_cost_fixture f WHERE e.export_id=f.export_id AND f.bucket>=5;
UPDATE im_v2.message_forward_inbox i SET payload=NULL,payload_compacted_at={NOW}
FROM im_v2.compaction_cost_fixture f WHERE i.export_id=f.export_id AND f.bucket>=5;
VACUUM ANALYZE im_v2.message_forward_exports;
VACUUM ANALYZE im_v2.message_forward_export_receipts;
VACUUM ANALYZE im_v2.message_forward_delivery_jobs;
VACUUM ANALYZE im_v2.message_forward_inbox;
"""


def nodes(plan):
    yield plan
    for child in plan.get("Plans", []):
        yield from nodes(child)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    for name in ("PGHOST", "PGPORT", "PGUSER"):
        if not os.environ.get(name):
            parser.error(f"Set {name} explicitly")
    if args.output.exists():
        parser.error("Output already exists; preserve prior evidence")
    database = "imv2_compaction_cost_" + uuid.uuid4().hex[:16]
    subprocess.run(["createdb", "--template=template0", database], check=True)
    report = {"scope": "single-host warm SQL probe; no Swift/runtime/network/production capacity claim",
              "sql_sha256": {side: hashlib.sha256(path.read_bytes()).hexdigest() for side, path in SOURCES.items()},
              "schema_sha256": hashlib.sha256((ROOT / "IMV2/sql/schema.sql").read_bytes()).hexdigest(),
              "probe_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              "method": "VACUUM ANALYZE per fixture; each EXPLAIN UPDATE rolls back; later runs may encounter aborted versions; no cold-cache or percentile claim",
              "cases": []}
    try:
        report["postgres_version"] = run(database, "SELECT version();")
        for rows, text_bytes in [(1000, 1024), (10000, 1024), (1000, 65536)]:
            run(database, "DROP SCHEMA IF EXISTS im_v2 CASCADE;\n" + (ROOT / "IMV2/sql/schema.sql").read_text())
            run(database, seed(rows, text_bytes))
            for side in SOURCES:
                for limit in (1, 128, 1024):
                    plan = json.loads(run(database, "BEGIN;\nEXPLAIN (ANALYZE, BUFFERS, WAL, FORMAT JSON) " + query(side, limit) + ";\nROLLBACK;"))[0]
                    actual = plan["Plan"]["Actual Rows"]
                    assert actual == min(limit, rows // 20), (side, rows, limit, actual)
                    if side == "source" and rows == 10000 and limit <= 128:
                        assert not any(node["Node Type"] == "Seq Scan" and node.get("Relation Name") in (
                            "message_forward_export_receipts", "message_forward_delivery_jobs")
                            for node in nodes(plan["Plan"])), "Historical receipt/job full scan returned"
                    assert not any(node["Node Type"] == "Seq Scan" and node.get("Relation Name") == "rooms"
                                   for node in nodes(plan["Plan"])), "Room full scan introduced by migration fence"
                    scans = [{k: node[k] for k in ("Node Type", "Relation Name", "Index Name", "Actual Rows", "Actual Loops", "Rows Removed by Filter", "Shared Hit Blocks", "Shared Read Blocks") if k in node}
                             for node in nodes(plan["Plan"]) if "Scan" in node["Node Type"]]
                    entry = {"side": side, "rows": rows, "text_bytes": text_bytes, "limit": limit, "updated_rows": actual,
                             "execution_ms": plan["Execution Time"], "wal_bytes": plan["Plan"].get("WAL Bytes"),
                             "scans": scans, "plan": plan}
                    report["cases"].append(entry)
                    print(json.dumps({key: entry[key] for key in ("side", "rows", "text_bytes", "limit", "updated_rows", "execution_ms", "wal_bytes")}), flush=True)
        with args.output.open("x") as output:
            json.dump(report, output, indent=2)
    finally:
        subprocess.run(["dropdb", "--if-exists", database], check=True)


if __name__ == "__main__":
    main()
