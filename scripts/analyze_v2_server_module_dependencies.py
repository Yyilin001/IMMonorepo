#!/usr/bin/env python3
"""Approximate Swift dependency graph for the server split.

Reads the proposed target inventory, indexes unique top-level type/function
names, then scans code with comments and string literals removed. This is a
migration aid rather than a Swift compiler; dynamic dispatch and typealiases
are not resolved.
"""
from __future__ import annotations

import argparse
import collections
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = ROOT / "IMV2Server/Sources"
SPLIT_TARGETS = (
    "IMV2Server",
    "IMV2ServerContracts",
    "IMV2ServerApplication",
    "IMV2ServerInfrastructure",
    "IMV2ServerGateway",
    "IMV2ServerHTTP",
)
ACTOR_TARGETS = ("IMV2ActorContracts", "IMV2ActorRuntime", "IMV2ActorCluster", "IMV2ActorApplication")
INVENTORY = ROOT / "docs/proposals/server-module-inventory.json"
DECL = re.compile(r"^(?:(?:public|package|internal|fileprivate|private|open|final|indirect|nonisolated|isolated|distributed) +)*(?:struct|enum|protocol|class|actor|typealias|func) +([A-Za-z_]\w*)", re.M)
IDENT = re.compile(r"\b[A-Za-z_]\w*\b")
FILE_TARGET_OVERRIDES = {
    "V2AccountRoomChangeBuffer.swift": "IMV2ServerGateway",
    "V2AccountRoomMembershipChange.swift": "IMV2ServerGateway",
    "V2DeviceConnectionRegistry.swift": "IMV2ServerGateway",
    "V2DirectRoomLogPayloadCodec.swift": "IMV2ServerApplication",
    "V2DurableWorkFailureClassification.swift": "IMV2ServerApplication",
    "V2LivePresenceRenewalBatcher.swift": "IMV2ServerApplication",
    "V2PreparedGroupEventPageCache.swift": "IMV2ServerGateway",
    "V2RoomLatestVisibleCommandService.swift": "IMV2ServerGateway",
    "V2RoomRecoveryCommandService.swift": "IMV2ServerGateway",
}


def code_only(text: str) -> str:
    """Blank Swift comments/strings while preserving newlines and offsets."""
    out = list(text)
    i = 0
    n = len(text)
    while i < n:
        if text.startswith("//", i):
            start = i
            i = text.find("\n", i)
            if i < 0: i = n
            for k in range(start, i): out[k] = " "
        elif text.startswith("/*", i):
            start = i
            depth = 1
            i += 2
            while i < n and depth:
                if text.startswith("/*", i): depth += 1; i += 2
                elif text.startswith("*/", i): depth -= 1; i += 2
                else: i += 1
            for k in range(start, i):
                if out[k] != "\n": out[k] = " "
        elif text[i] == '"':
            start = i
            triple = text.startswith('"""', i)
            delimiter = '"""' if triple else '"'
            i += len(delimiter)
            while i < n:
                if text[i] == "\\": i += 2
                elif text.startswith(delimiter, i): i += len(delimiter); break
                else: i += 1
            for k in range(start, min(i, n)):
                if out[k] != "\n": out[k] = " "
        else:
            i += 1
    return "".join(out)


def scc(graph: dict[str, set[str]]) -> list[list[str]]:
    index = 0
    stack: list[str] = []
    on_stack: set[str] = set()
    indices: dict[str, int] = {}
    low: dict[str, int] = {}
    groups: list[list[str]] = []
    def visit(v: str) -> None:
        nonlocal index
        indices[v] = low[v] = index; index += 1
        stack.append(v); on_stack.add(v)
        for w in graph.get(v, ()):
            if w not in indices: visit(w); low[v] = min(low[v], low[w])
            elif w in on_stack: low[v] = min(low[v], indices[w])
        if low[v] == indices[v]:
            group = []
            while True:
                w = stack.pop(); on_stack.remove(w); group.append(w)
                if w == v: break
            groups.append(sorted(group))
    for node in graph:
        if node not in indices: visit(node)
    return groups


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--output", type=Path, default=ROOT / "docs/proposals/server-dependency-graph.json")
    ap.add_argument("--sync-inventory", action="store_true", help="refresh the source inventory after file moves")
    ap.add_argument("--include-actor-layers", action="store_true", help="also audit the four physical Actor modules; does not rewrite the original split inventory")
    args = ap.parse_args()
    if args.include_actor_layers and args.sync_inventory:
        ap.error("Actor audit and legacy inventory refresh must be separate operations")
    inventory = json.loads(INVENTORY.read_text())
    planned = {x["source"]: x["proposedTarget"] for x in inventory["files"]}
    files = sorted(
        p.relative_to(SOURCE_ROOT).as_posix()
        for name in SPLIT_TARGETS + (ACTOR_TARGETS if args.include_actor_layers else ())
        for p in (SOURCE_ROOT / name).rglob("*.swift")
        if (SOURCE_ROOT / name).is_dir()
    )
    raw = {f: (SOURCE_ROOT / f).read_text() for f in files}
    target: dict[str, str] = {}
    classification_overrides = []
    for file in files:
        imports = set(re.findall(r"^import +([A-Za-z_]\w*)", raw[file], re.M))
        actual_target, _, legacy = file.partition("/")
        planned_target = planned.get(file, planned.get(legacy))
        if actual_target != "IMV2Server":
            inferred = actual_target
        elif legacy.startswith("Generated/Protobuf/im_realtime/internal/"):
            inferred = "IMV2ServerInfrastructure"
        elif legacy in FILE_TARGET_OVERRIDES: inferred = FILE_TARGET_OVERRIDES[legacy]
        elif legacy.startswith("Contracts/"): inferred = "IMV2ServerContracts"
        elif legacy.startswith("Application/"): inferred = "IMV2ServerApplication"
        elif legacy.startswith("Infrastructure/"): inferred = "IMV2ServerInfrastructure"
        elif legacy.startswith("Gateway/"): inferred = "IMV2ServerGateway"
        elif legacy.startswith("Composition/"): inferred = "IMV2Server"
        elif legacy.startswith("Resources/") and "/Contracts/" in legacy: inferred = "IMV2ServerContracts"
        elif legacy.startswith("Resources/") and "/Application/" in legacy: inferred = "IMV2ServerApplication"
        elif legacy.startswith("Resources/") and "/Infrastructure/" in legacy: inferred = "IMV2ServerInfrastructure"
        elif legacy.startswith("RoomDomain/") or legacy.startswith("RoomCoordination/") or legacy.startswith("RoomMaintenance/"):
            inferred = "IMV2ServerInfrastructure"
        elif legacy.startswith("RoomClients/"): inferred = "IMV2ServerInfrastructure"
        elif planned_target == "IMV2Server": inferred = "IMV2Server"
        elif legacy.rsplit("/", 1)[-1].startswith(("Postgres", "V2Postgres")) or imports & {"SQLKit", "FluentKit", "PostgresNIO"}:
            inferred = "IMV2ServerInfrastructure"
        else: inferred = planned_target or "IMV2ServerApplication"
        target[file] = inferred
        if planned_target != inferred:
            classification_overrides.append({"source": file, "inventoryTarget": planned_target, "effectiveTarget": inferred})
    if args.sync_inventory:
        previous = {item["source"]: item for item in inventory["files"]}
        refreshed = []
        for file in files:
            _, _, legacy = file.partition("/")
            original = previous.get(file) or previous.get(legacy)
            if original is None and file.startswith("IMV2ServerContracts/"):
                original = previous.get("Contracts/" + legacy)
            item = dict(original) if original else {"migrationNote": "candidate target; verify before physical move"}
            item["source"] = file
            item["proposedTarget"] = target[file]
            item["imports"] = sorted(set(re.findall(r"^import +([A-Za-z_]\w*)", raw[file], re.M)))
            refreshed.append(item)
        inventory["scope"] = "IMV2Server/Sources/{IMV2Server,IMV2ServerContracts,IMV2ServerApplication,IMV2ServerInfrastructure,IMV2ServerGateway,IMV2ServerHTTP}/**/*.swift"
        inventory["sourceCount"] = len(refreshed)
        inventory["classification"] = dict(sorted(collections.Counter(item["proposedTarget"] for item in refreshed).items()))
        inventory["files"] = refreshed
        INVENTORY.write_text(json.dumps(inventory, indent=2, ensure_ascii=False) + "\n")
        classification_overrides = []
    code = {f: code_only(raw[f]) for f in files}
    declarations: dict[str, set[str]] = collections.defaultdict(set)
    for file, body in code.items():
        for match in DECL.finditer(body):
            name = match.group(1)
            if name[0].isupper() or name.startswith(("v2", "roomWrite")):
                declarations[name].add(file)
    unique = {name: next(iter(owners)) for name, owners in declarations.items() if len(owners) == 1}
    edges: dict[tuple[str, str], set[str]] = collections.defaultdict(set)
    for file, body in code.items():
        for symbol in set(IDENT.findall(body)):
            owner = unique.get(symbol)
            if owner and owner != file: edges[(file, owner)].add(symbol)
    def reference_lines(src: str, symbols: set[str]) -> dict[str, int]:
        body = code[src]
        return {symbol: body.count("\n", 0, re.search(r"\b" + re.escape(symbol) + r"\b", body).start()) + 1 for symbol in symbols}
    graph = {f: set() for f in files}
    for a, b in edges: graph[a].add(b)
    groups = [g for g in scc(graph) if len(g) > 1]
    group_of = {file: i for i, group in enumerate(groups) for file in group}
    forbidden_targets = {
        "IMV2ServerContracts": {"IMV2ServerApplication", "IMV2ServerInfrastructure", "IMV2ServerGateway", "IMV2ServerHTTP", "IMV2Server"},
        "IMV2ServerApplication": {"IMV2ServerInfrastructure", "IMV2ServerGateway", "IMV2ServerHTTP", "IMV2Server"},
        "IMV2ServerInfrastructure": {"IMV2ServerGateway", "IMV2ServerHTTP", "IMV2Server"},
        "IMV2ServerGateway": {"IMV2ServerInfrastructure", "IMV2ServerHTTP", "IMV2Server"},
        "IMV2ServerHTTP": {"IMV2ServerInfrastructure", "IMV2ServerGateway", "IMV2Server"},
    }
    if args.include_actor_layers:
        all_targets = set(SPLIT_TARGETS + ACTOR_TARGETS)
        actor_allowed = {
            "IMV2ActorContracts": set(),
            "IMV2ActorRuntime": {"IMV2ActorContracts"},
            "IMV2ActorCluster": {"IMV2ActorContracts", "IMV2ActorRuntime"},
            "IMV2ActorApplication": {"IMV2ActorContracts", "IMV2ActorRuntime", "IMV2ActorCluster",
                "IMV2ServerContracts", "IMV2ServerApplication", "IMV2ServerInfrastructure", "IMV2Server"},
        }
        for module, allowed in actor_allowed.items():
            forbidden_targets[module] = all_targets - allowed - {module}
        for module in SPLIT_TARGETS:
            allowed = {"IMV2ActorContracts"}
            if module in {"IMV2Server", "IMV2ServerInfrastructure"}:
                allowed.add("IMV2ActorRuntime")
            forbidden_targets.setdefault(module, set()).update(set(ACTOR_TARGETS) - allowed)
    forbidden = []
    for (src, dst), symbols in sorted(edges.items()):
        if target[dst] in forbidden_targets.get(target[src], set()):
            forbidden.append({"from": src, "fromTarget": target[src], "to": dst, "toTarget": target[dst], "symbols": sorted(symbols), "referenceLines": reference_lines(src, symbols), "sameSCC": group_of.get(src) is not None and group_of.get(src) == group_of.get(dst)})
    cross_edges = [
        {"from": src, "fromTarget": target[src], "to": dst, "toTarget": target[dst], "symbols": sorted(symbols), "referenceLines": reference_lines(src, symbols)}
        for (src, dst), symbols in sorted(edges.items()) if target[src] != target[dst]
    ]
    def path_back(start: str, end: str, members: set[str]) -> list[str] | None:
        queue = collections.deque([[start]])
        seen = {start}
        while queue:
            path = queue.popleft()
            for nxt in graph[path[-1]]:
                if nxt not in members: continue
                if nxt == end: return path + [end]
                if nxt not in seen: seen.add(nxt); queue.append(path + [nxt])
        return None
    cross_scc = []
    for group in groups:
        targets = {target[f] for f in group}
        if len(targets) < 2: continue
        members = set(group)
        witness = None
        for (src, dst), symbols in edges.items():
            if src not in members or dst not in members or target[src] == target[dst]: continue
            back = path_back(dst, src, members)
            if back and (witness is None or len(back) < len(witness["files"])):
                witness = {"files": [src] + back, "firstEdgeSymbols": sorted(symbols)}
        cross_scc.append({"size": len(group), "targets": sorted(targets), "files": group, "witnessCycle": witness})
    cross_scc.sort(key=lambda x: -x["size"])
    data = {"sourceCount": len(files), "fileTargets": target, "classificationOverrides": classification_overrides, "indexedUniqueDeclarations": len(unique), "fileEdges": len(edges), "forbiddenEdges": forbidden, "crossTargetEdges": cross_edges, "crossTargetSCCs": cross_scc,
            "auditedTargets": list(SPLIT_TARGETS + (ACTOR_TARGETS if args.include_actor_layers else ())),
            "analysisLimitations": "unique declaration references only; does not resolve dynamic dispatch or typealiases; package compilation remains authoritative"}
    args.output.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    print(f"files={len(files)} overrides={len(classification_overrides)} symbols={len(unique)} edges={len(edges)} forbidden={len(forbidden)} cross-target-SCCs={len(cross_scc)}")
    for e in forbidden[:40]:
        print(f"{e['from']} -> {e['to']}: {', '.join(e['symbols'])}")
    for g in cross_scc[:5]: print(f"SCC size={g['size']} targets={','.join(g['targets'])}")

if __name__ == "__main__": main()
