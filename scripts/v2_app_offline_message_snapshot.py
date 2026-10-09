"""Read one owned acceptance scope's original offline send and projections.

Only test identities and content digests are exported, never credentials or
full command/receipt payloads. The database is opened read-only.
"""
import argparse
from contextlib import closing
import hashlib
import json
from pathlib import Path
import sqlite3
import uuid


def snapshot(container, scope, sender, original):
    filename = "sync-local-e2e-" + str(uuid.UUID(scope)) + ".sqlite.accounts"
    roots = list(container.rglob(filename))
    if len(roots) != 1:
        raise RuntimeError("expected exactly one owned acceptance account root")
    paths = list(roots[0].rglob("V2.sqlite"))
    if len(paths) != 1:
        raise RuntimeError("expected exactly one owned acceptance database")
    with closing(sqlite3.connect(paths[0].as_uri() + "?mode=ro", uri=True, timeout=3)) as database:
        database.row_factory = sqlite3.Row
        result = {}
        if sender:
            rows = database.execute("""SELECT intent_id, client_message_id, room_id,
                text, mentions, entities, reply_to, admission_deadline, work_id
                FROM v2_send_intents WHERE text = ? AND stage <> 'cancelled'""", ("q",)).fetchall()
            if len(rows) != 1:
                raise RuntimeError("expected one original offline intent")
            row = rows[0]
            immutable = {key: row[key] for key in ("client_message_id", "room_id", "text",
                "mentions", "entities", "reply_to", "admission_deadline")}
            digest = hashlib.sha256(json.dumps(immutable, sort_keys=True).encode()).hexdigest()
            result["intent"] = {"intentID": str(uuid.UUID(row["intent_id"])),
                "clientMessageID": str(uuid.UUID(row["client_message_id"])),
                "roomID": str(uuid.UUID(row["room_id"])), "immutableDigest": digest}
            if row["work_id"]:
                work = database.execute("""SELECT w.execution_state, w.scheduling_state,
                    m.accepted_message_id, m.accepted_room_sequence, m.command
                    FROM v2_operation_work w JOIN v2_message_send_operations m USING(work_id)
                    WHERE w.work_id = ?""", (row["work_id"],)).fetchone()
                if work is None:
                    raise RuntimeError("original intent references missing send work")
                result["work"] = {key: work[key] for key in ("execution_state", "scheduling_state",
                    "accepted_message_id", "accepted_room_sequence")}
                result["work"]["commandDigest"] = hashlib.sha256(work["command"]).hexdigest()
            if original and result["intent"] != original["intent"]:
                raise RuntimeError("offline send identity or immutable intent changed")
            if original and "work" in original and result.get("work", {}).get("commandDigest") != original["work"]["commandDigest"]:
                raise RuntimeError("frozen offline command changed")
            room = result["intent"]["roomID"]
        else:
            if not original:
                raise RuntimeError("receiver needs the original send identity")
            room = original["intent"]["roomID"]
        rows = database.execute("""SELECT message_id, room_sequence, message_revision,
            is_withdrawn FROM v2_message_projections
            WHERE lower(room_id) = ? AND text_body = ?""", (room, "q")).fetchall()
        result["projections"] = [dict(row) for row in rows]
        return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("container", type=Path)
    parser.add_argument("scope")
    parser.add_argument("output", type=Path)
    parser.add_argument("--sender", action="store_true")
    parser.add_argument("--original", type=Path)
    args = parser.parse_args()
    original = json.loads(args.original.read_text()) if args.original else None
    result = snapshot(args.container, args.scope, args.sender, original)
    args.output.write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main()
