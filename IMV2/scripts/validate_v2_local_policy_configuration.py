#!/usr/bin/env python3
"""Check that all local policy readers and writers use the same owner placement."""
from __future__ import annotations

import argparse
import json
from pathlib import Path


def validate(root: Path) -> None:
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
                required |= {"policyRegistration", "policyRevocation"}
            if not required.issubset(services.get(service, {}).get("permissions", [])):
                raise ValueError(f"{name} does not authorize {service}'s policy calls")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    try:
        validate(args.directory)
    except (OSError, ValueError, KeyError, TypeError):
        # Configuration includes key paths and identities. Keep diagnostics bounded.
        parser.exit(1, "Local policy configuration is incomplete or inconsistent. "
                    "Retained legacy configurations are not rewritten automatically; "
                    "prepare a separate configuration directory with gateway, account, operator "
                    "and --policy-partitions 16 before switching the local stack.\n")


if __name__ == "__main__":
    main()
