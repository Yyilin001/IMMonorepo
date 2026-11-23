#!/usr/bin/env python3
"""Check that all local policy readers and writers use the same owner placement."""
from __future__ import annotations

import argparse
import json
import uuid
from pathlib import Path


def validate(root: Path, *, single_core: bool = False) -> None:
    documents = {}
    for name in ("gateway", "account", "operator"):
        document = json.loads((root / name / "configuration.json").read_text(encoding="utf-8"))
        if document.get("serviceID") != name:
            raise ValueError(f"{name} has an unexpected service identity")
        documents[name] = document
    placement = documents["gateway"].get("policyPlacement")
    if not isinstance(placement, dict):
        raise ValueError("gateway has no memory policy owner placement")
    count = placement.get("partitionCount")
    if type(count) is not int or count < 1 or count > 4096 or count & (count - 1):
        raise ValueError("policy partition count is invalid")
    gateway_id = documents["gateway"].get("hostID")
    owners = placement.get("owners")
    if not gateway_id or not isinstance(owners, list) or len(owners) != 1:
        raise ValueError("local policy placement must have one gateway owner")
    owner = owners[0]
    if (owner.get("hostID") != gateway_id or owner.get("endpoint") != "rooms-primary"
            or sorted(owner.get("partitions", [])) != list(range(count))):
        raise ValueError("gateway must own every local policy partition")
    for name, document in documents.items():
        if document.get("policyPlacement") != placement:
            raise ValueError(f"{name} has a different policy placement")
        services = {item["id"]: item for item in document.get("services", [])}
        for service in documents:
            required = {"policyMutation"}
            if service == "gateway":
                required |= {"policyRegistration"}
            if not required.issubset(services.get(service, {}).get("permissions", [])):
                raise ValueError(f"{name} does not authorize {service}'s policy calls")
    if single_core:
        peers = documents["gateway"].get("peers")
        if not isinstance(peers, list) or len(peers) != 1:
            raise ValueError("local configuration requires one Room Core")
        peer = peers[0]
        if (not isinstance(peer, dict) or peer.get("hostID") != gateway_id
                or peer.get("serviceID") != "gateway"
                or peer.get("shardIDs") != ["rooms-primary"]):
            raise ValueError("the local Gateway must own rooms-primary")
        for name, document in documents.items():
            if (document.get("singleCore") is not True or "placementControl" in document
                    or document.get("peers") != peers
                    or (name != "gateway" and document.get("hostID") is not None)):
                raise ValueError(f"{name} uses a different Room Core")
    else:
        validate_placement(root, documents)


def validate_placement(root: Path, documents: dict) -> None:
    names = ("placement-a", "placement-b", "placement-c")
    try:
        cluster_id = str(uuid.UUID(documents["gateway"].get("placementControl", {}).get("clusterID", "")))
    except (ValueError, TypeError, AttributeError):
        raise ValueError("placement requires a persistent deployment cluster ID") from None
    voters = documents["gateway"].get("placementControl", {}).get("voters")
    if not isinstance(voters, list) or len(voters) != 3:
        raise ValueError("local actors require three independent placement voters")
    if ({item.get("serviceID") for item in voters} != set(names)
            or len({item.get("hostID") for item in voters}) != 3
            or any(not item.get("hostID") or item.get("address") != item.get("serviceID")
                   or item.get("port") != 7336 or set(item.get("shardIDs", [])) != {"rooms-primary", "rooms-01"} for item in voters)):
        raise ValueError("placement voter identities, endpoints or shards are inconsistent")
    identities = {item["serviceID"]: item["hostID"] for item in voters}
    for name in names:
        document = json.loads((root / name / "configuration.json").read_text(encoding="utf-8"))
        if document.get("serviceID") != name or document.get("hostID") is not None or "policyPlacement" in document:
            raise ValueError("placement voter must be an independent control-only process")
        documents[name] = document
    for name, document in documents.items():
        control = document.get("placementControl", {})
        if control.get("clusterID") != cluster_id:
            raise ValueError(f"{name} uses a different placement cluster identity")
        if control.get("voters") != voters:
            raise ValueError(f"{name} uses a different placement quorum")
        if name in names:
            if (control.get("localVoterID") != identities[name] or control.get("port") != 7336
                    or control.get("storagePaths") != {"rooms-primary": "/run/im-v2-room-actor/placement/0.pb",
                                                       "rooms-01": "/run/im-v2-room-actor/placement/1.pb"}):
                raise ValueError(f"{name} has inconsistent durable voter configuration")
        elif control.get("localVoterID") is not None or control.get("storagePaths") != {}:
            raise ValueError("room applications must not own voting files")
        services = {item["id"]: item for item in document.get("services", [])}
        for voter in names:
            service = services.get(voter, {})
            if (service.get("hostIDs") != [identities[voter]]
                    or not {"placementVote", "placementRead"}.issubset(service.get("permissions", []))):
                raise ValueError(f"{name} does not trust the fixed placement voter")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--single-core", action="store_true")
    args = parser.parse_args()
    try:
        validate(args.directory, single_core=args.single_core)
    except (OSError, ValueError, KeyError, TypeError):
        # Configuration includes key paths and identities. Keep diagnostics bounded.
        parser.exit(1, "Local Actor configuration is incomplete or inconsistent. "
                    "Regenerate gateway, account and operator identities for this deployment.\n")


if __name__ == "__main__":
    main()
