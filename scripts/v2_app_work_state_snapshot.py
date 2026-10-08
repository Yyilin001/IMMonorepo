"""Read only durable work status from an owned simulator's App container.

Never export command payloads, receipts, credentials or account identifiers.
"""
import argparse
import json
from pathlib import Path
import sqlite3


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('container', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    snapshots = []
    for path in sorted(args.container.rglob('*.sqlite')):
        connection = None
        try:
            connection = sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=3)
            if not connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='v2_operation_work'").fetchone():
                continue
            connection.row_factory = sqlite3.Row
            rows = connection.execute('''SELECT local_sequence, operation_kind,
                execution_state, scheduling_state, attempt_count, next_action_kind,
                next_action_at, last_error_code FROM v2_operation_work
                ORDER BY local_sequence''').fetchall()
            snapshots.append({'databaseIndex': len(snapshots), 'work': [dict(row) for row in rows]})
        except sqlite3.Error as error:
            snapshots.append({'databaseIndex': len(snapshots), 'errorType': type(error).__name__})
        finally:
            if connection is not None:
                connection.close()
    args.output.write_text(json.dumps(snapshots, indent=2) + '\n')


if __name__ == '__main__':
    main()
