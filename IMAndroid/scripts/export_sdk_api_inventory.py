#!/usr/bin/env python3
"""Normalize the compiler's Swift public API graph; never infer Android parity.

Export only after rebuilding/extracting the current module. --check detects source
drift after export, not whether the original compiler invocation was up to date.
Uses only the Python standard library. See sdk-parity/README.md for extraction.
"""

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
from urllib.parse import unquote, urlparse


MODULE = "IMV2ClientKit"
MODULES = {MODULE, "IMV2ClientRuntime", "IMV2ClientNetwork", "IMV2ClientPlatform", "IMV2ClientApple"}
SOURCE_ROOT = Path("IMV2ClientKit/Sources")
CONTRACT_FILES = ("IMV2ClientKit/Package.swift", "IMV2ClientKit/Package.resolved",
                  "Protocol/im_realtime/v2/im_v2.proto")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def source_hashes(repo):
    paths = sorted((repo / SOURCE_ROOT).rglob("*.swift"))
    if not paths:
        raise ValueError("Swift module source directory is empty")
    paths += [repo / name for name in CONTRACT_FILES if (repo / name).is_file()]
    return {str(p.relative_to(repo)): digest(p.read_bytes()) for p in paths}


def normalize_graph(graph, repo):
    if graph["module"]["name"] not in MODULES:
        raise ValueError("Unexpected Swift module")
    records, seen = [], set()
    for symbol in graph["symbols"]:
        identity = symbol["identifier"]["precise"]
        if identity in seen:
            raise ValueError(f"Duplicate symbol: {identity}")
        seen.add(identity)
        if symbol["accessLevel"] not in ("public", "open"):
            raise ValueError(f"Non-public symbol: {identity}")
        record = {
            "id": identity,
            "module": graph["module"]["name"],
            "kind": symbol["kind"]["identifier"],
            "path": symbol["pathComponents"],
            "declaration": "".join(f["spelling"] for f in symbol["declarationFragments"]),
            "category": "unlocated",
        }
        location = symbol.get("location")
        if location and location.get("uri"):
            uri = urlparse(location["uri"])
            if uri.scheme != "file" or uri.netloc not in ("", "localhost"):
                raise ValueError(f"Non-local source: {identity}")
            source = Path(unquote(uri.path)).resolve()
            relative = source.relative_to(repo)
            relative.relative_to(SOURCE_ROOT)  # Reject dependencies and external paths.
            if not source.is_file():
                raise ValueError(f"Missing source: {relative}")
            record.update(source=str(relative), line=location["position"]["line"] + 1,
                          column=location["position"]["character"] + 1)
            if record["line"] < 1 or record["column"] < 1:
                raise ValueError(f"Invalid source position: {identity}")
            record["category"] = "generated" if "Generated" in relative.parts else "handwritten"
        records.append(record)
    return sorted(records, key=lambda r: (r.get("source", ""), r["path"], r["id"]))


def encode_records(records):
    return "".join(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n"
                   for r in records).encode("utf-8")


def export_inventory(graph_path, repo, output):
    paths = sorted(graph_path.glob("*.symbols.json")) if graph_path.is_dir() else [graph_path]
    graphs = [(path, path.read_bytes()) for path in paths]
    names = {json.loads(raw)["module"]["name"] for _, raw in graphs}
    if names != MODULES:
        raise ValueError("Export all package modules together: " + ", ".join(sorted(MODULES)))
    records, identities = [], set()
    platform = None
    for path, raw in graphs:
        graph = json.loads(raw)
        if platform is not None and platform != graph["module"].get("platform"):
            raise ValueError("Mixed symbol graph targets")
        platform = graph["module"].get("platform")
        for record in normalize_graph(graph, repo):
            if record["id"] in identities:
                raise ValueError("Duplicate symbol across graphs: " + record["id"])
            identities.add(record["id"])
            records.append(record)
    records.sort(key=lambda r: (r.get("source", ""), r["path"], r["id"]))
    if not records:
        raise ValueError("Empty public API inventory")
    data = encode_records(records)
    manifest = {
        "format": 2,
        "module": MODULE,
        "modules": sorted(MODULES),
        "scope": "Public symbols of the facade and its owned package modules for this target; not Android behavior coverage",
        "target": graph["module"].get("platform"),
        "generator": graph["metadata"].get("generator"),
        "symbol_graph_sha256": {path.name: digest(raw) for path, raw in graphs},
        "inventory_sha256": digest(data),
        "symbol_count": len(records),
        "categories": dict(sorted(Counter(r["category"] for r in records).items())),
        "kinds": dict(sorted(Counter(r["kind"] for r in records).items())),
        "declarations_by_source": dict(sorted(Counter(r.get("source", "<unlocated>") for r in records).items())),
        "source_sha256": source_hashes(repo),
    }
    output.mkdir(parents=True, exist_ok=True)
    (output / "swift-public-api.jsonl").write_bytes(data)
    (output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return manifest


def check_inventory(repo, output):
    manifest = json.loads((output / "manifest.json").read_text(encoding="utf-8"))
    if manifest["format"] != 2 or manifest["module"] != MODULE or set(manifest["modules"]) != MODULES:
        raise ValueError("Unexpected inventory format/module")
    data = (output / "swift-public-api.jsonl").read_bytes()
    if digest(data) != manifest["inventory_sha256"]:
        raise ValueError("Inventory changed; regenerate from the compiler graph")
    current, saved = source_hashes(repo), manifest["source_sha256"]
    changed = sorted(k for k in current.keys() | saved.keys() if current.get(k) != saved.get(k))
    if changed:
        raise ValueError("Source inventory is stale; rebuild and export again:\n" + "\n".join(changed))
    records = [json.loads(line) for line in data.splitlines()]
    if len(records) != manifest["symbol_count"] or dict(Counter(r["category"] for r in records)) != manifest["categories"]:
        raise ValueError("Inventory counts disagree with manifest")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "sdk-parity")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--graph", type=Path, help="Directory of fresh symbol graphs for all package modules (including extension graphs)")
    mode.add_argument("--check", action="store_true", help="Check current source hashes and inventory integrity")
    args = parser.parse_args()
    try:
        manifest = (check_inventory(args.repo.resolve(), args.output) if args.check else
                    export_inventory(args.graph, args.repo.resolve(), args.output))
    except (ValueError, KeyError, OSError) as error:
        parser.exit(1, f"{error}\n")
    print(json.dumps({"module": MODULE, "symbols": manifest["symbol_count"],
                      "categories": manifest["categories"], "check": args.check}))


if __name__ == "__main__":
    main()
