#!/usr/bin/env python3
"""Prepare stable load-generator cohorts from actual committed room placements.

Inputs are disposable benchmark credentials, IMV2PlacementControlApp --inspect
JSON and a room_id<TAB>room_shard_id export of direct_room_owner_routes.
Only the client ingress changes between ratios. No host is sent in a message.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import uuid

from v2_native_placement_inspection import decode_placement_inspection, room_placement


def prepare(credentials, routes, placement, host_ids):
    if len(credentials) != 50_000 or len({c["userID"] for c in credentials}) != 50_000:
        raise ValueError("expected 50,000 distinct users")
    owners = {host_id.lower(): index for index, host_id in enumerate(host_ids)}
    if len(host_ids) != 2 or len(owners) != 2:
        raise ValueError("expected two distinct hosts")
    ready = [[], []]
    seen = set()
    # Prefer the same active set as the native 50k benchmark; fill small
    # imbalances from the idle users so both hosts get equal offered load.
    for c in credentials[36_000:] + credentials[:36_000]:
        room, = c["targetRoomIDs"]
        key = str(uuid.UUID(room))
        if key in seen:
            raise ValueError("duplicate target room")
        seen.add(key)
        state = room_placement(placement, key, routes[key])
        if state["retired"] or state["hostRetired"] or state["transfer"] is not None:
            raise ValueError("placement is not stable")
        cohort = ready[owners[state["hostID"].lower()]]
        if len(cohort) < 7_000:
            cohort.append(c)
    if [len(group) for group in ready] != [7_000, 7_000]:
        raise ValueError("each host must own at least 7,000 target rooms")
    active = {c["userID"] for group in ready for c in group}
    idle = [c for c in credentials if c["userID"] not in active]
    return ([idle[i:i + 9_000] for i in range(0, 36_000, 9_000)]
            + [group[i:i + 3_500] for group in ready for i in (0, 3_500)])


def ingress(worker, remote_percent):
    if remote_percent not in (0, 50, 100) or worker not in range(8):
        raise ValueError("invalid cohort")
    if worker < 4:
        return worker % 2
    owner = (worker - 4) // 2
    remote = remote_percent == 100 or (remote_percent == 50 and worker % 2 == 1)
    return 1 - owner if remote else owner


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    for key in ("credentials", "routes", "placement", "topology", "output"):
        cli.add_argument("--" + key, required=True, type=Path)
    cli.add_argument("--hosts", nargs=2, required=True, metavar=("HOST_A", "HOST_B"))
    cli.add_argument("--remote-percent", type=int, choices=(0, 50, 100), required=True)
    args = cli.parse_args()
    ids = json.loads(args.topology.read_text())["hostIDs"]
    credentials = [json.loads(line) for line in args.credentials.read_text().splitlines()]
    routes = dict(line.split("\t") for line in args.routes.read_text().splitlines())
    groups = prepare(credentials, routes, decode_placement_inspection(args.placement.read_text()),
                     [ids[name] for name in args.hosts])
    args.output.mkdir(mode=0o700, exist_ok=False)
    manifest = []
    for i, group in enumerate(groups):
        path = args.output / f"{i}.jsonl"
        with path.open("x", opener=lambda p, flags: os.open(p, flags, 0o600)) as output:
            for c in group:
                output.write(json.dumps(c) + "\n")
        membership = "\n".join(c["userID"] + "/" + c["targetRoomIDs"][0] for c in group)
        digest = hashlib.sha256(membership.encode())
        manifest.append(dict(worker=i, connections=len(group), active=i >= 4,
                             ingress=args.hosts[ingress(i, args.remote_percent)], membership_sha256=digest.hexdigest()))
    print(json.dumps(manifest))


if __name__ == "__main__":
    main()
