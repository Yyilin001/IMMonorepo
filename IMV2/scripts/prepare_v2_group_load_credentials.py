#!/usr/bin/env python3
"""Build a secret-minimal JSONL credential slice for a group load run."""

from __future__ import annotations

import argparse
import json
import os
import tempfile
import time
import uuid
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--offset", type=int, default=0)
    parser.add_argument("--limit", type=int, required=True)
    parser.add_argument("--target-room", action="append", required=True)
    return parser.parse_args()


def normalized_room_ids(raw_values: list[str]) -> list[str]:
    if not 1 <= len(raw_values) <= 32:
        raise ValueError("target room count must be 1...32")
    values = [str(uuid.UUID(raw)) for raw in raw_values]
    if len(set(values)) != len(values):
        raise ValueError("target room IDs must be unique")
    return values


def main() -> None:
    args = parse_args()
    if args.offset < 0 or args.limit <= 0:
        raise ValueError("offset must be non-negative and limit must be positive")
    rooms = normalized_room_ids(args.target_room)
    selected: list[dict[str, object]] = []
    seen_users: set[str] = set()
    seen_devices: set[str] = set()
    with args.input.open("r", encoding="utf-8") as source:
        for index, line in enumerate(source):
            if index < args.offset:
                continue
            if len(selected) == args.limit:
                break
            record = json.loads(line)
            user_id = str(uuid.UUID(record["userID"]))
            device_id = str(uuid.UUID(record["deviceID"]))
            token = record["accessToken"]
            expiry = int(record["accessTokenExpiresAtMilliseconds"])
            if not token or expiry <= int(time.time() * 1000):
                raise ValueError(f"expired or empty access token at input line {index + 1}")
            if user_id in seen_users or device_id in seen_devices:
                raise ValueError("credential slice contains duplicate user or device IDs")
            seen_users.add(user_id)
            seen_devices.add(device_id)
            selected.append(
                {
                    "userID": user_id,
                    "deviceID": device_id,
                    "accessToken": token,
                    "accessTokenExpiresAtMilliseconds": expiry,
                    "targetRoomIDs": rooms,
                }
            )
    if len(selected) != args.limit:
        raise ValueError(f"requested {args.limit} credentials, found {len(selected)}")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".group-load-", dir=args.output.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as destination:
            for record in selected:
                destination.write(json.dumps(record, separators=(",", ":")))
                destination.write("\n")
        os.replace(temporary, args.output)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise

    print(
        f"group load credentials prepared: {len(selected)} records, "
        f"{len(rooms)} target room(s)"
    )


if __name__ == "__main__":
    main()
