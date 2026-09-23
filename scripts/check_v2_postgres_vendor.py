#!/usr/bin/env python3
"""Verify the reviewed PostgresNIO source snapshot without fetching dependencies."""

import hashlib
import json
from pathlib import Path


root = Path(__file__).resolve().parent.parent
vendor = root / "IMV2Server/Vendor/postgres-nio"
metadata = json.loads((vendor / "UPSTREAM.json").read_text())
expected = metadata["files"]
actual = set()
for item in metadata["included"]:
    path = vendor / item
    paths = path.rglob("*") if path.is_dir() else [path]
    actual.update(str(file.relative_to(vendor)) for file in paths if file.is_file())
if actual != set(expected):
    raise SystemExit("PostgresNIO vendor file set differs from UPSTREAM.json")
for relative, digest in expected.items():
    if hashlib.sha256((vendor / relative).read_bytes()).hexdigest() != digest:
        raise SystemExit(f"PostgresNIO vendor checksum mismatch: {relative}")
print(f"PostgresNIO {metadata['release']} vendor checksums passed ({len(expected)} files).")
