#!/usr/bin/env python3
"""Static source/ownership sanity checks for the C0 virtual-actor inventory.

This verifies claims in the inventory, not runtime routing, authorization or
activation-fence coverage. Run from any directory; no database is needed.
"""

from __future__ import annotations

import json
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parent.parent
INVENTORY = ROOT / "docs/reviews/virtual-actor"


def read_json(name: str) -> dict:
    return json.loads((INVENTORY / name).read_text(encoding="utf-8"))


def main() -> int:
    errors: list[str] = []
    owners = read_json("file-ownership.json")
    claims = read_json("writer-evidence.json")
    dto_index = read_json("dto-types.json")
    if owners.get("base") != claims.get("base"):
        errors.append("inventory files disagree on business base commit")

    paths: dict[str, str] = {}
    valid_owners = {"C0", "R1", "R2", "R3", "D1", "D2", "D3", "D4", "D5", "D6", "V1", "I1"}
    retired_paths: set[str] = set()
    for item in owners["files"]:
        if "retiredPath" in item:
            retired = item["retiredPath"]
            if retired in retired_paths or retired in paths:
                errors.append(f"duplicate retired owner: {retired}")
            retired_paths.add(retired)
            if (ROOT / retired).exists():
                errors.append(f"retired owned source still exists: {retired}")
            if item["owner"] not in valid_owners:
                errors.append(f"unknown retired owner: {retired}: {item['owner']}")
            if not item.get("replacedBy"):
                errors.append(f"retired owner lacks replacements: {retired}")
            continue
        path, owner = item["path"], item["owner"]
        if path in paths:
            errors.append(f"duplicate owner: {path}: {paths[path]} and {owner}")
        paths[path] = owner
        if owner not in valid_owners:
            errors.append(f"unknown owner: {path}: {owner}")
        if not (ROOT / path).is_file():
            errors.append(f"missing owned source: {path}")
    for item in owners["files"]:
        if "retiredPath" in item:
            for replacement in item["replacedBy"]:
                if replacement not in paths:
                    errors.append(f"retired owner replacement lacks ownership: {item['retiredPath']} -> {replacement}")
                elif not (ROOT / replacement).is_file():
                    errors.append(f"missing retired owner replacement: {replacement}")

    ledger = (INVENTORY / "writer-ledger.md").read_text(encoding="utf-8")
    catalog = (INVENTORY / "capability-catalog.md").read_text(encoding="utf-8")
    writer_ids = set(re.findall(r"^\| (W\d\d)\b", ledger, re.M))
    capability_ids = re.findall(r"^\| ((?:C|Q|K|W)\d+(?:[–-](?:C|Q|K|W)?\d+)?)\b", catalog, re.M)
    if len(capability_ids) != len(set(capability_ids)):
        errors.append("duplicate capability ID in catalog")
    claim_ids = {item["id"] for item in claims["claims"]}
    for writer_id in sorted(writer_ids ^ claim_ids):
        errors.append(f"ledger/evidence ID mismatch: {writer_id}")
    seen_claims: set[tuple[str, str, str]] = set()
    for item in claims["claims"]:
        key = item["id"], item["path"], item["symbol"]
        if key in seen_claims:
            errors.append(f"duplicate writer claim: {key}")
        seen_claims.add(key)
        path = item["path"]
        if path not in paths:
            errors.append(f"writer source lacks ownership: {path}")
        source = ROOT / path
        if not source.is_file():
            errors.append(f"missing writer source: {path}")
            continue
        text = source.read_text(encoding="utf-8")
        for field in ("symbol", "table_or_marker"):
            if item[field] not in text:
                errors.append(f"missing {field} in {path}: {item[field]}")

    signatures = "\n".join(
        line for line in catalog.splitlines() if line.startswith("- `func ")
    )
    signature_types = set(
        re.findall(r"\b(?:V2|IMV2)[A-Za-z0-9_]+\b|\b[A-Z][A-Za-z0-9_]*ID\b", signatures)
    )
    dto_names: set[str] = set()
    active_dto_names: set[str] = set()
    for item in dto_index["types"]:
        name, path = item["name"], item["path"]
        if name in dto_names:
            errors.append(f"duplicate DTO type: {name}")
        dto_names.add(name)
        if item.get("status") == "retired":
            if (ROOT / path).is_file() and re.search(
                rf"\b(?:struct|enum|actor|class|protocol|typealias)\s+{re.escape(name)}\b",
                (ROOT / path).read_text(encoding="utf-8"),
            ):
                errors.append(f"retired DTO still declared: {name}: {path}")
            if not item.get("replacedBy"):
                errors.append(f"retired DTO lacks replacements: {name}")
            continue
        active_dto_names.add(name)
        source = ROOT / path
        if not source.is_file():
            errors.append(f"missing DTO source: {path}")
            continue
        if source.parts[-2] != item["target"] and item["target"] not in source.parts:
            errors.append(f"DTO target mismatch: {name}: {path}")
        if not re.search(
            rf"(?m)^(?:public |internal |package |nonisolated |indirect |final )*"
            rf"(?:struct|enum|actor|class|protocol|typealias)\s+{re.escape(name)}\b",
            source.read_text(encoding="utf-8"),
        ):
            errors.append(f"missing DTO declaration: {name}: {path}")
    for item in dto_index["types"]:
        if item.get("status") == "retired":
            for replacement in item["replacedBy"]:
                if replacement not in active_dto_names:
                    errors.append(f"retired DTO replacement absent from index: {item['name']} -> {replacement}")
    for name in sorted(signature_types - active_dto_names):
        errors.append(f"signature type absent from DTO index: {name}")

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(
        f"OK: {len(paths)} unique owned files, {len(writer_ids)} writer IDs, "
        f"{len(claims['claims'])} static source claims, {len(capability_ids)} catalog rows, "
        f"{len(dto_names)} indexed DTO types"
    )
    print("Static checks do not establish runtime writer coverage or fencing.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
