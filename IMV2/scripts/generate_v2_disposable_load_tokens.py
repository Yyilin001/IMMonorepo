#!/usr/bin/env python3
"""Generate short-lived, device-bound access tokens for disposable load tests.

Input is a tab-separated file with four columns per row:

    user_uuid<TAB>device_uuid<TAB>first_room_uuid<TAB>second_room_uuid

The credentials output contains clear tokens and must exist only on the load
host with mode 0600. The database output contains HMACs, never clear tokens;
it can be COPYed into a staging table and retained until cleanup so precisely
this campaign's token rows can be revoked or deleted.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import tempfile
import time
import uuid

TOKEN_KEY_ENV = "IM_V2_ACCESS_TOKEN_HMAC_KEY_BASE64"
DISPOSABLE_FENCE_ENV = "IMV2_DISPOSABLE_LOAD_TOKEN_GENERATION"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--credentials-output", required=True, type=Path)
    parser.add_argument("--database-output", required=True, type=Path)
    parser.add_argument("--count", required=True, type=int)
    parser.add_argument("--lifetime-seconds", required=True, type=int)
    parser.add_argument("--token-key-file", type=Path)
    return parser.parse_args()


def load_key(path: Path | None) -> bytes:
    try:
        encoded = path.read_text(encoding="utf-8").strip() if path else os.environ[TOKEN_KEY_ENV]
        key = base64.b64decode(encoded, validate=True)
    except (KeyError, OSError, ValueError) as error:
        source = str(path) if path else TOKEN_KEY_ENV
        raise ValueError(f"{source} must contain valid Base64") from error
    if len(key) < 32:
        raise ValueError(f"{TOKEN_KEY_ENV} must decode to at least 32 bytes")
    return key


def validated_uuid(raw: str) -> str:
    return str(uuid.UUID(raw))


def load_rows(path: Path, expected_count: int) -> list[tuple[str, str, str, str]]:
    if expected_count <= 0:
        raise ValueError("count must be positive")
    rows: list[tuple[str, str, str, str]] = []
    devices: set[str] = set()
    with path.open("r", encoding="utf-8") as source:
        for line_number, line in enumerate(source, start=1):
            columns = line.rstrip("\n").split("\t")
            if len(columns) != 4:
                raise ValueError(f"line {line_number} must contain four TSV columns")
            user_id, device_id, first_room_id, second_room_id = map(validated_uuid, columns)
            if first_room_id == second_room_id:
                raise ValueError(f"line {line_number} repeats one target room")
            if device_id in devices:
                raise ValueError(f"line {line_number} repeats one device")
            devices.add(device_id)
            rows.append((user_id, device_id, first_room_id, second_room_id))
    if len(rows) != expected_count:
        raise ValueError(f"expected {expected_count} rows, found {len(rows)}")
    return rows


def temporary_output(destination: Path):
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, raw_path = tempfile.mkstemp(
        prefix=f".{destination.name}.", dir=destination.parent, text=True
    )
    os.fchmod(descriptor, 0o600)
    return os.fdopen(descriptor, "w", encoding="utf-8"), Path(raw_path)


def generate(args: argparse.Namespace) -> None:
    if os.environ.get(DISPOSABLE_FENCE_ENV) != "1":
        raise ValueError(f"{DISPOSABLE_FENCE_ENV}=1 is required")
    if args.lifetime_seconds < 300 or args.lifetime_seconds > 86_400:
        raise ValueError("lifetime-seconds must be between 300 and 86400")
    if args.credentials_output == args.database_output:
        raise ValueError("credential and database outputs must differ")
    if args.credentials_output.exists() or args.database_output.exists():
        raise ValueError("refusing to overwrite an existing output")

    key = load_key(args.token_key_file)
    rows = load_rows(args.input, args.count)
    issued_at = int(time.time())
    expires_at = issued_at + args.lifetime_seconds
    credentials_file, credentials_temporary = temporary_output(args.credentials_output)
    database_file, database_temporary = temporary_output(args.database_output)
    try:
        with credentials_file, database_file:
            for user_id, device_id, first_room_id, second_room_id in rows:
                token = secrets.token_urlsafe(32)
                token_hmac = hmac.new(key, token.encode("utf-8"), hashlib.sha256).hexdigest()
                credentials_file.write(json.dumps({
                    "userID": user_id,
                    "deviceID": device_id,
                    "accessToken": token,
                    "accessTokenExpiresAtMilliseconds": expires_at * 1_000,
                    "targetRoomIDs": [first_room_id, second_room_id],
                }, separators=(",", ":")) + "\n")
                database_file.write(
                    f"{token_hmac}\t{user_id}\t{device_id}\t{issued_at}\t{expires_at}\n"
                )
        os.replace(credentials_temporary, args.credentials_output)
        os.replace(database_temporary, args.database_output)
        os.chmod(args.credentials_output, 0o600)
        os.chmod(args.database_output, 0o600)
    except BaseException:
        credentials_temporary.unlink(missing_ok=True)
        database_temporary.unlink(missing_ok=True)
        args.credentials_output.unlink(missing_ok=True)
        args.database_output.unlink(missing_ok=True)
        raise


def main() -> int:
    try:
        generate(parse_args())
    except (OSError, ValueError) as error:
        print(f"load-token generation failed: {error}", file=os.sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
