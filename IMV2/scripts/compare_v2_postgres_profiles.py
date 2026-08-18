#!/usr/bin/env python3
"""Produce counter deltas without mutating PostgreSQL statistics."""

from __future__ import annotations

import csv
import sys
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import NoReturn


def fail(message: str) -> NoReturn:
    raise SystemExit(message)


def read_rows(directory: Path, filename: str) -> list[dict[str, str]]:
    path = directory / filename
    if not path.is_file():
        fail(f"missing profile input: {path}")
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def decimal(value: str | None) -> Decimal:
    if value in (None, ""):
        return Decimal(0)
    try:
        return Decimal(value)
    except InvalidOperation as error:
        fail(f"non-numeric profile counter: {value!r} ({error})")


def formatted(value: Decimal) -> str:
    if value == value.to_integral_value():
        return str(value.quantize(Decimal(1)))
    return format(value.normalize(), "f")


def write_rows(path: Path, fieldnames: list[str], rows: list[dict[str, str]]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def keyed(rows: list[dict[str, str]], keys: tuple[str, ...]) -> dict[tuple[str, ...], dict[str, str]]:
    result: dict[tuple[str, ...], dict[str, str]] = {}
    for row in rows:
        key = tuple(row[column] for column in keys)
        if key in result:
            fail(f"duplicate profile key {key}")
        result[key] = row
    return result


def verify_counter_epochs(before: Path, after: Path) -> None:
    before_epochs = keyed(read_rows(before, "counter_epochs.csv"), ("counter",))
    after_epochs = keyed(read_rows(after, "counter_epochs.csv"), ("counter",))
    if before_epochs.keys() != after_epochs.keys():
        fail("profile counter sets differ between baseline and report")
    changed = [
        counter[0]
        for counter in before_epochs
        if before_epochs[counter]["stats_reset"] != after_epochs[counter]["stats_reset"]
    ]
    if changed:
        fail(
            "PostgreSQL counters were reset between baseline and report: "
            + ", ".join(sorted(changed))
        )


def counter_delta(
    before: Path,
    after: Path,
    filename: str,
    keys: tuple[str, ...],
    gauges: tuple[str, ...] = (),
    sort_column: str | None = None,
) -> None:
    before_rows = keyed(read_rows(before, filename), keys)
    current_rows = read_rows(after, filename)
    if not current_rows:
        fail(f"empty profile input: {after / filename}")
    source_columns = list(current_rows[0].keys())
    numeric_columns = [column for column in source_columns if column not in keys + gauges]
    fields = list(keys) + list(gauges) + [f"delta_{column}" for column in numeric_columns]
    output: list[dict[str, str]] = []
    for current in current_rows:
        key = tuple(current[column] for column in keys)
        previous = before_rows.get(key, {})
        row = {column: current[column] for column in keys + gauges}
        for column in numeric_columns:
            change = decimal(current.get(column)) - decimal(previous.get(column))
            if change < 0:
                fail(f"counter moved backwards in {filename} for {key}: {column}")
            row[f"delta_{column}"] = formatted(change)
        output.append(row)
    if sort_column is not None:
        output.sort(key=lambda row: decimal(row[sort_column]), reverse=True)
    write_rows(after / f"delta_{filename}", fields, output)


def statement_delta(before: Path, after: Path) -> None:
    filename = "statements.csv"
    previous = keyed(read_rows(before, filename), ("queryid",))
    current_rows = read_rows(after, filename)
    counter_columns = (
        "calls", "rows", "total_plan_ms", "total_exec_ms",
        "shared_blks_hit", "shared_blks_read", "shared_blks_dirtied",
        "shared_blks_written", "temp_blks_read", "temp_blks_written",
        "wal_records", "wal_fpi", "wal_bytes",
    )
    fields = ["queryid"] + [f"delta_{column}" for column in counter_columns]
    fields += ["interval_mean_exec_ms", "normalized_query"]
    output: list[dict[str, str]] = []
    for current in current_rows:
        old = previous.get((current["queryid"],), {})
        row = {"queryid": current["queryid"], "normalized_query": current["normalized_query"]}
        for column in counter_columns:
            change = decimal(current.get(column)) - decimal(old.get(column))
            if change < 0:
                fail(f"statement counter moved backwards for queryid {current['queryid']}: {column}")
            row[f"delta_{column}"] = formatted(change)
        calls = decimal(row["delta_calls"])
        total_exec = decimal(row["delta_total_exec_ms"])
        row["interval_mean_exec_ms"] = formatted(total_exec / calls) if calls else "0"
        if calls:
            output.append(row)
    output.sort(key=lambda row: decimal(row["delta_total_exec_ms"]), reverse=True)
    write_rows(after / f"delta_{filename}", fields, output)


def relation_delta(before: Path, after: Path) -> None:
    filename = "relations.csv"
    keys = ("schemaname", "relname")
    previous = keyed(read_rows(before, filename), keys)
    current_rows = read_rows(after, filename)
    counter_columns = (
        "seq_scan", "idx_scan", "n_tup_ins", "n_tup_upd", "n_tup_del",
        "heap_blks_read", "heap_blks_hit", "idx_blks_read", "idx_blks_hit",
    )
    fields = list(keys) + [
        "current_total_bytes", "delta_total_bytes", "current_n_live_tup",
        "current_n_dead_tup",
    ] + [f"delta_{column}" for column in counter_columns]
    output: list[dict[str, str]] = []
    for current in current_rows:
        key = tuple(current[column] for column in keys)
        old = previous.get(key, {})
        current_size = decimal(current["total_bytes"])
        old_size = decimal(old.get("total_bytes"))
        row = {
            "schemaname": current["schemaname"],
            "relname": current["relname"],
            "current_total_bytes": formatted(current_size),
            # Relation size may shrink because of truncation or maintenance;
            # unlike monotonic statistics, a signed delta is meaningful here.
            "delta_total_bytes": formatted(current_size - old_size),
            "current_n_live_tup": current["n_live_tup"],
            "current_n_dead_tup": current["n_dead_tup"],
        }
        for column in counter_columns:
            change = decimal(current.get(column)) - decimal(old.get(column))
            if change < 0:
                fail(f"relation counter moved backwards for {key}: {column}")
            row[f"delta_{column}"] = formatted(change)
        output.append(row)
    output.sort(key=lambda row: abs(decimal(row["delta_total_bytes"])), reverse=True)
    write_rows(after / f"delta_{filename}", fields, output)


def main() -> None:
    if len(sys.argv) != 3:
        fail(f"usage: {Path(sys.argv[0]).name} BASELINE_DIRECTORY REPORT_DIRECTORY")
    before = Path(sys.argv[1])
    after = Path(sys.argv[2])
    verify_counter_epochs(before, after)
    counter_delta(before, after, "database.csv", ("datname",), ("numbackends",))
    counter_delta(before, after, "wal.csv", (), sort_column="delta_wal_bytes")
    counter_delta(
        before, after, "io.csv", ("backend_type", "object", "context"),
        sort_column="delta_write_time",
    )
    statement_delta(before, after)
    relation_delta(before, after)


if __name__ == "__main__":
    main()
