#!/usr/bin/env python3
"""Bounded local SQLite cost probe; extracts current query and relevant schema.

Uses a disposable database, real CHECKs and indexes, synthetic rows (not an App
load test). Reports warm-cache timings and SQLite VM steps. No thresholds.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import statistics
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = ROOT / 'IMV2ClientKit/Sources/IMV2ClientKit/V2LocalSchema.swift'
SOURCE = ROOT / 'IMV2ClientKit/Sources/IMV2ClientKit/GRDBV2LocalSyncStore.swift'
TABLES = ['group_event_cursors', 'group_events', 'message_projections', 'reaction_versions',
          'group_pinned_messages', 'group_announcements', 'group_role_policies', 'group_member_roles']


def create_table(schema, table):
    start = schema.index('CREATE TABLE ' + table + ' (')
    pos = schema.index('(', start)
    depth = 0
    quoted = False
    for end in range(pos, len(schema)):
        char = schema[end]
        if char == "'":
            quoted = not quoted
        elif not quoted:
            depth += (char == '(') - (char == ')')
            if depth == 0:
                return schema[start:end + 1]
    raise ValueError(table)


def measure(db, query, params, repeats):
    result = db.execute(query, params).fetchone()[0]
    samples = []
    for _ in range(repeats):
        start = time.perf_counter()
        assert db.execute(query, params).fetchone()[0] == result
        samples.append((time.perf_counter() - start) * 1000)
    ticks = 0
    def step():
        nonlocal ticks
        ticks += 1
        return 0
    db.set_progress_handler(step, 1000)
    db.execute(query, params).fetchone()
    db.set_progress_handler(None, 0)
    return {'result': result, 'median_ms': statistics.median(samples), 'max_ms': max(samples),
            'vm_steps_lower_bound': ticks * 1000,
            'plan': [row[3] for row in db.execute('EXPLAIN QUERY PLAN ' + query, params)]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sizes', type=int, nargs='+', default=[1000, 10000, 100000])
    parser.add_argument('--repeats', type=int, default=7)
    parser.add_argument('--without-sequence-indexes', action='store_true', help='cost comparison only: omit the 11 new indexes')
    args = parser.parse_args()
    if not all(1 <= size <= 1000000 for size in args.sizes) or not 1 <= args.repeats <= 30:
        parser.error('sizes 1..1000000; repeats 1..30')
    source, schema = SOURCE.read_text(), SCHEMA.read_text()
    body = source.split('public func roomAppliedRoomSequence', 1)[1].split('public func markRoomEventUnauthorized', 1)[0]
    query = body.split('sql: """', 1)[1].split('"""', 1)[0]
    # Reconstruct the former eight-source nested MAX for a cost-only comparison.
    legacy = 'SELECT MAX(value) FROM (' + ' UNION ALL '.join(
        ('SELECT applied_room_sequence AS value' if name == 'group_event_cursors' else 'SELECT MAX(room_sequence) AS value')
        + ' FROM v2_' + name + ' WHERE room_id = ?' for name in TABLES) + ')'
    report = {'sqlite': sqlite3.sqlite_version, 'scope': 'synthetic warm-cache SQLite, schema subset; no App/device or cold-cache validation',
              'source_sha256': hashlib.sha256(source.encode()).hexdigest(),
              'schema_sha256': hashlib.sha256(schema.encode()).hexdigest(), 'cases': []}
    for size in args.sizes:
        with tempfile.TemporaryDirectory(prefix='imv2-room-applied-cost-') as temporary:
            db = sqlite3.connect(str(Path(temporary) / 'cost.sqlite'))
            db.execute('PRAGMA journal_mode=WAL')
            for suffix in TABLES:
                db.execute(create_table(schema, 'v2_' + suffix))
            for match in re.finditer(r'CREATE (?:UNIQUE )?INDEX\s+\w+\s+ON\s+(\w+)\s*\([^;]+;', schema):
                if match.group(1) in ['v2_' + name for name in TABLES]:
                    if args.without_sequence_indexes and re.search(r'INDEX v2_\w+_(?:invalid_)?sequence_idx ', match.group(0)):
                        continue
                    db.execute(match.group(0))
            insert_start = time.perf_counter()
            # Include an equally large unrelated room to reveal unbounded scans.
            for room in ['target', 'unrelated']:
                db.execute('INSERT INTO v2_group_event_cursors(room_id,applied_room_sequence) VALUES (?,?)', (room, size))
                db.executemany('INSERT INTO v2_group_events VALUES (?,?,?,?,?)',
                    ((room, i, f'{room}-{i}', 'message', b'x' * 1024) for i in range(1, size + 1)))
                db.executemany('INSERT INTO v2_message_projections(message_id,source_event_id,room_id,room_sequence,message_revision,sender_user_id,text_body,server_created_at,timeline_sequence) VALUES (?,?,?,?,?,?,?,?,?)',
                    ((f'{room}-{i}', f'{room}-{i}', room, i, 1, 'sender', 'x' * 256, 1.0, i) for i in range(1, size + 1)))
                db.executemany('INSERT INTO v2_reaction_versions VALUES (?,?,?,?,?,?,?,?)',
                    ((f'{room}-{i}', room, 'actor', 'like', i, f'{room}-{i}', 'add', b'x' * 32) for i in range(1, size + 1)))
                db.executemany('INSERT INTO v2_group_member_roles VALUES (?,?,?,?,?)',
                    ((room, str(i), 'member', 1, i) for i in range(1, min(size, 10000) + 1)))
                db.execute('INSERT INTO v2_group_pinned_messages(room_id,message_id,is_pinned,room_sequence,updated_at) VALUES (?,?,1,NULL,1)', (room, 'pin'))
                db.execute('INSERT INTO v2_group_announcements(room_id,body,revision,room_sequence,updated_at) VALUES (?,\'body\',1,NULL,1)', (room,))
                db.execute("INSERT INTO v2_group_role_policies(room_id,role,permissions,revision,room_sequence) VALUES (?,'member',?,1,NULL)", (room, b'[]'))
            db.commit()
            insert_ms = (time.perf_counter() - insert_start) * 1000
            database_bytes = db.execute('PRAGMA page_count').fetchone()[0] * db.execute('PRAGMA page_size').fetchone()[0]
            db.execute('ANALYZE')
            params = ['target'] * query.count('?')
            report['cases'].append({'rows_per_event_message_reaction_table_per_room': size, 'rooms': 2, 'new_indexes': not args.without_sequence_indexes, 'insert_ms': insert_ms, 'database_bytes': database_bytes,
                'legacy_cost_only': measure(db, legacy, ['target'] * 8, args.repeats),
                'current': measure(db, query, params, args.repeats)})
            db.close()
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
