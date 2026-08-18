#!/usr/bin/env python3

import csv
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("compare_v2_postgres_profiles.py")


def write_csv(directory: Path, name: str, rows: list[dict[str, object]]) -> None:
    path = directory / name
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def read_csv(directory: Path, name: str) -> list[dict[str, str]]:
    with (directory / name).open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def fixture(directory: Path, multiplier: int, reset: str = "epoch-a") -> None:
    write_csv(directory, "counter_epochs.csv", [
        {"counter": counter, "stats_reset": reset}
        for counter in ("database", "io", "statements", "wal")
    ])
    write_csv(directory, "database.csv", [{
        "datname": "im_v2", "numbackends": 3,
        "xact_commit": 10 * multiplier, "temp_bytes": 2 * multiplier,
    }])
    write_csv(directory, "wal.csv", [{
        "wal_records": 11 * multiplier, "wal_bytes": 101 * multiplier,
    }])
    write_csv(directory, "io.csv", [{
        "backend_type": "client backend", "object": "relation", "context": "normal",
        "reads": 3 * multiplier, "write_time": 5 * multiplier,
    }])
    write_csv(directory, "statements.csv", [{
        "queryid": "7", "calls": 2 * multiplier, "rows": 4 * multiplier,
        "total_plan_ms": 1 * multiplier, "total_exec_ms": 8 * multiplier,
        "mean_exec_ms": 4, "shared_blks_hit": 6 * multiplier,
        "shared_blks_read": 0, "shared_blks_dirtied": 0,
        "shared_blks_written": 0, "temp_blks_read": 0,
        "temp_blks_written": 0, "wal_records": 2 * multiplier,
        "wal_fpi": 0, "wal_bytes": 10 * multiplier,
        "normalized_query": "SELECT $1",
    }])
    write_csv(directory, "relations.csv", [{
        "schemaname": "im_v2", "relname": "user_sync_log",
        "total_bytes": 1_000 - 100 * multiplier, "n_live_tup": 20,
        "n_dead_tup": 2, "seq_scan": 1 * multiplier,
        "idx_scan": 2 * multiplier, "n_tup_ins": 3 * multiplier,
        "n_tup_upd": 0, "n_tup_del": 0, "heap_blks_read": 0,
        "heap_blks_hit": 4 * multiplier, "idx_blks_read": 0,
        "idx_blks_hit": 5 * multiplier,
    }])


class ProfileDeltaTests(unittest.TestCase):
    def test_computes_monotonic_counters_and_signed_relation_size(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            before, after = root / "before", root / "after"
            before.mkdir()
            after.mkdir()
            fixture(before, 1)
            fixture(after, 3)

            subprocess.run(
                [sys.executable, str(SCRIPT), str(before), str(after)], check=True
            )

            self.assertEqual(read_csv(after, "delta_wal.csv")[0]["delta_wal_bytes"], "202")
            statement = read_csv(after, "delta_statements.csv")[0]
            self.assertEqual(statement["delta_calls"], "4")
            self.assertEqual(statement["interval_mean_exec_ms"], "4")
            relation = read_csv(after, "delta_relations.csv")[0]
            self.assertEqual(relation["delta_total_bytes"], "-200")

    def test_rejects_counter_reset_between_snapshots(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            before, after = root / "before", root / "after"
            before.mkdir()
            after.mkdir()
            fixture(before, 1)
            fixture(after, 2, reset="epoch-b")

            result = subprocess.run(
                [sys.executable, str(SCRIPT), str(before), str(after)],
                text=True, capture_output=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("counters were reset", result.stderr)


if __name__ == "__main__":
    unittest.main()
