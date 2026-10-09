"""Read one owned App scope's recovery metadata, never tokens or payloads."""
import argparse
from contextlib import closing
import json
from pathlib import Path
import sqlite3
import uuid


def snapshot(container, scope, title):
    root_name = "sync-local-e2e-" + str(uuid.UUID(scope)) + ".sqlite.accounts"
    roots = list(container.rglob(root_name))
    if len(roots) != 1:
        raise RuntimeError("expected one owned account root")
    paths = list(roots[0].rglob("V2.sqlite"))
    if len(paths) != 1:
        raise RuntimeError("expected one owned account database")
    with closing(sqlite3.connect(paths[0].as_uri() + "?mode=ro", uri=True, timeout=3)) as db:
        db.row_factory = sqlite3.Row
        db.execute("BEGIN")
        rooms = db.execute("SELECT room_id FROM v2_room_profile_projections WHERE title=?", (title,)).fetchall()
        if len(rooms) != 1:
            raise RuntimeError("expected one original invitation room")
        room = rooms[0]["room_id"]
        def rows(sql, args=(room,)):
            return [dict(row) for row in db.execute(sql, args)]
        return {
            "roomID": room,
            "profile": rows("SELECT membership_revision,is_group_event_authorized FROM v2_room_profile_projections WHERE room_id=?"),
            "membership": rows("SELECT membership_revision,is_member FROM v2_room_membership_states WHERE room_id=?"),
            "cursor": rows("SELECT applied_room_sequence,log_trimmed_through_room_sequence,history_incomplete FROM v2_group_event_cursors WHERE room_id=?"),
            "state": rows("SELECT owner_epoch,membership_revision,head,trimmed_through,read_through,latest_own_sequence,checked_at FROM v2_room_sync_states WHERE room_id=?"),
            "recoveryWork": rows("SELECT target_head,requires_state,requires_summary,priority,next_attempt_at,directory_membership_revision,directory_owner_epoch FROM v2_room_recovery_work WHERE room_id=?"),
            "messages": rows("SELECT message_id,room_sequence,message_revision,is_withdrawn FROM v2_message_projections WHERE room_id=? ORDER BY room_sequence"),
            "sendWork": rows("""SELECT w.work_id,w.execution_state,w.scheduling_state,w.attempt_count,
                w.next_action_kind,w.next_action_at,w.last_error_code,m.accepted_message_id,
                m.accepted_room_sequence,m.accepted_projection_observed
                FROM v2_operation_work w JOIN v2_message_send_operations m USING(work_id)
                WHERE m.room_id=? ORDER BY w.local_sequence"""),
            "personalCursor": rows("SELECT state,generation,applied_sequence,server_acknowledged_sequence FROM v2_sync_cursor", ()),
        }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("container", type=Path)
    parser.add_argument("scope")
    parser.add_argument("title")
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.write_text(json.dumps(snapshot(args.container, args.scope, args.title), indent=2) + "\n")


if __name__ == "__main__":
    main()
