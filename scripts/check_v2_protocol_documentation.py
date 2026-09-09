#!/usr/bin/env python3
"""Check current protocol claims, not historical benchmark documentation."""

import pathlib
import re
import sys


def check(root: pathlib.Path) -> None:
    version = (root / "Protocol/im_realtime/v2/protocol_version.txt").read_text().strip()
    if not re.fullmatch(r"[0-9]+", version):
        raise ValueError("protocol_version.txt must contain one integer")
    status = (root / "IMV2/docs/implementation-status.md").read_text()
    # Both the wire policy and the capability table are required claims.
    claims = re.findall(r"\bprotocol\s+(\d+)\b", status)
    if len(claims) < 2 or any(value != version for value in claims):
        raise ValueError(f"implementation-status.md protocol claims {claims!r} must match {version}")


if __name__ == "__main__":
    root = pathlib.Path(__file__).resolve().parents[1]
    try:
        check(root)
    except (OSError, ValueError) as error:
        print(f"V2 protocol documentation mismatch: {error}", file=sys.stderr)
        sys.exit(1)
    print("V2 current protocol documentation matches protocol_version.txt.")
