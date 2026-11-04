#!/usr/bin/env python3
"""Exercise the canonical message-head trigger in an isolated PostgreSQL schema.

IMV2_TRIGGER_TEST_PSQL_JSON may specify a psql command (including SSH/docker).
Only the uniquely named test schema is created and removed. No production rows
are used. PostgreSQL must be available; this test never silently skips.
"""
import json
import os
from pathlib import Path
import subprocess
import uuid


def main():
    command = json.loads(os.environ.get("IMV2_TRIGGER_TEST_PSQL_JSON", '["psql"]'))
    command += ["-X", "-qAt", "-v", "ON_ERROR_STOP=1"]
    schema = "head_probe_" + uuid.uuid4().hex
    source = (Path(__file__).resolve().parents[1] / "IMV2/sql/realtime-change-journal.sql").read_text()

    def run(sql):
        result = subprocess.run(command, input=sql, text=True, capture_output=True, timeout=30)
        if result.returncode:
            raise RuntimeError(result.stderr[-3000:])
        return result.stdout.strip()

    def function(name):
        start = source.index("CREATE OR REPLACE FUNCTION im_v2." + name + "(")
        return (source[start:].split("END $$;", 1)[0] + "END $$;").replace("im_v2.", schema + ".")

    rooms = [str(uuid.uuid4()) for _ in range(3)]
    a, b, c = rooms

    def insert(rows):
        values = ",".join(f"('{room}',{seq},'{storage}')" for room, seq, storage in rows)
        return f"INSERT INTO {schema}.messages VALUES {values};"

    def head(room):
        return json.loads(run(f"SELECT row_to_json(h) FROM {schema}.realtime_dirty_room_heads h WHERE room_id='{room}';"))

    checks = []
    try:
        run(f"""
            CREATE SCHEMA {schema};
            CREATE TABLE {schema}.rooms(room_id uuid PRIMARY KEY, owner_epoch bigint NOT NULL);
            CREATE TABLE {schema}.realtime_control_versions(topic_kind text,topic_id text,version bigint,PRIMARY KEY(topic_kind,topic_id));
            CREATE TABLE {schema}.realtime_dirty_room_heads(
                room_id uuid PRIMARY KEY,partition_id integer NOT NULL,room_sequence bigint NOT NULL,
                owner_epoch bigint NOT NULL,room_control_version bigint NOT NULL,
                revision bigint NOT NULL DEFAULT 1,pending boolean NOT NULL DEFAULT true);
            CREATE TABLE {schema}.messages(room_id uuid,room_sequence bigint,accepted_event_storage text);
            {function('realtime_topic_partition')}
            {function('capture_realtime_messages_heads')}
            CREATE TRIGGER capture AFTER INSERT ON {schema}.messages
              REFERENCING NEW TABLE AS new_realtime_rows FOR EACH STATEMENT
              EXECUTE FUNCTION {schema}.capture_realtime_messages_heads();
            INSERT INTO {schema}.rooms VALUES ('{a}',3),('{b}',5),('{c}',7);
            INSERT INTO {schema}.realtime_control_versions VALUES ('roomEvents','{a}',9);
        """)
        run(insert([(a, 10, "message_row"), (a, 12, "message_row"), (b, 4, "message_row")]))
        first = head(a)
        expected_partition = int(run(f"SELECT {schema}.realtime_topic_partition('roomEvents','{a}');"))
        assert (first['room_sequence'], first['owner_epoch'], first['room_control_version'], first['revision'], first['partition_id']) == (12, 3, 9, 1, expected_partition)
        assert head(b)['room_control_version'] == 0
        checks.append("missing heads, multi-room aggregation, partition and absent control version")

        run(f"UPDATE {schema}.realtime_dirty_room_heads SET pending=false WHERE room_id='{a}';")
        run(insert([(a, 11, "message_row"), (a, 13, "message_row")]))
        assert head(a)['revision'] == 2 and head(a)['room_sequence'] == 13 and head(a)['pending']
        checks.append("existing head: monotonic sequence and one revision per statement")
        cleared = run(f"UPDATE {schema}.realtime_dirty_room_heads SET pending=false WHERE room_id='{a}' AND revision=1 RETURNING room_id;")
        assert cleared == "" and head(a)['pending']
        run("BEGIN;" + insert([(b, 5, "message_row")]) + insert([(b, 6, "message_row")]) + "COMMIT;")
        assert head(b)['revision'] == 3 and head(b)['room_sequence'] == 6
        checks.append("stale publisher CAS cannot clear a newer head; each statement invalidates")

        run(f"UPDATE {schema}.rooms SET owner_epoch=8 WHERE room_id='{a}'; UPDATE {schema}.realtime_control_versions SET version=15;")
        run(insert([(a, 9, "message_row")]))
        assert (head(a)['owner_epoch'], head(a)['room_control_version'], head(a)['room_sequence']) == (8, 15, 13)
        run(f"UPDATE {schema}.rooms SET owner_epoch=2 WHERE room_id='{a}'; UPDATE {schema}.realtime_control_versions SET version=1;")
        run(insert([(a, 8, "message_row")]))
        assert (head(a)['owner_epoch'], head(a)['room_control_version']) == (8, 15)
        checks.append("current metadata and monotonic owner/control floors")

        before = head(a)
        run("BEGIN;" + insert([(a, 99, "message_row")]) + "ROLLBACK;")
        assert head(a) == before
        run(insert([(a, 100, "room_event")]))
        run(f"INSERT INTO {schema}.messages SELECT '{a}'::uuid,101,'message_row' WHERE false;")
        assert head(a) == before
        checks.append("rollback, non-message-row and empty INSERT")

        # Force the second writer to observe a missing head before the first
        # commits. Its fallback INSERT must converge through ON CONFLICT.
        one = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        one.stdin.write("BEGIN;" + insert([(c, 20, "message_row")]) + "SELECT 'ready';\n")
        one.stdin.flush()
        assert one.stdout.readline().strip() == "ready"
        two = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        two.stdin.write("SET statement_timeout='5s';" + insert([(c, 21, "message_row")]) + "\n")
        two.stdin.close()
        # First transaction commits only after the second backend is lock-waiting.
        import time
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            waiting = int(run(f"SELECT count(*) FROM pg_stat_activity WHERE pid<>pg_backend_pid() AND wait_event_type='Lock' AND query LIKE '%{schema}.messages%';"))
            if waiting:
                break
            time.sleep(0.05)
        else:
            raise AssertionError("second writer did not reach conflict wait")
        one.stdin.write("COMMIT;\n")
        one.stdin.close()
        assert one.wait(timeout=10) == 0 and two.wait(timeout=10) == 0
        assert head(c)['room_sequence'] == 21 and head(c)['revision'] == 2
        checks.append("concurrent missing-head writers preserve both invalidations")
        print(json.dumps({"passed": checks}, indent=2))
    finally:
        # Closing a failed probe also rolls back its uncommitted work.
        for process in [locals().get('one'), locals().get('two')]:
            if process is not None and process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
        run(f"DROP SCHEMA IF EXISTS {schema} CASCADE;")


if __name__ == "__main__":
    main()
