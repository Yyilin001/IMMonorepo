#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return parsed


def load_accounts(path: str) -> list[tuple[str, str]]:
    accounts: list[tuple[str, str]] = []
    with open(path, newline="") as file:
        for row in csv.reader(file):
            if not row:
                continue
            email = row[0].strip()
            if not email or email.startswith("#"):
                continue
            if len(row) < 2:
                raise SystemExit(f"account row is missing password: {row!r}")
            accounts.append((email, row[1].strip()))
    if not accounts:
        raise SystemExit(f"account file has no usable rows: {path}")
    return accounts


def login_one(
    base_url: str,
    login_index: int,
    email: str,
    password: str,
    device_id_prefix: str,
    timeout_seconds: float,
    retries: int,
    retry_delay_seconds: float,
) -> dict:
    device_id = f"{device_id_prefix}-{login_index}"
    payload = json.dumps(
        {
            "email": email,
            "password": password,
            "device": {
                "deviceID": device_id,
                "deviceName": device_id,
                "platform": "load-test",
                "appVersion": "load-test",
            },
        },
        separators=(",", ":"),
    ).encode()
    request = urllib.request.Request(
        f"{base_url.rstrip('/')}/api/auth/login",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    last_error = ""
    for attempt in range(retries + 1):
        try:
            with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
                body = response.read()
            data = json.loads(body)
            now_ms = int(time.time() * 1000)
            return {
                "loginIndex": login_index,
                "email": email,
                "deviceID": device_id,
                "deviceName": device_id,
                "userID": data["user"]["id"],
                "accessToken": data["accessToken"],
                "expiresAtMs": now_ms + int(data["expiresIn"]) * 1000,
            }
        except urllib.error.HTTPError as error:
            body = error.read().decode(errors="replace")[:500]
            last_error = f"http {error.code}: {body}"
        except Exception as error:
            last_error = repr(error)
        if attempt < retries:
            time.sleep(retry_delay_seconds)
    raise RuntimeError(f"login failed index={login_index} email={email}: {last_error}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Prewarm IM TCP login cache with bounded parallel HTTP logins.")
    parser.add_argument("--base-url", default="http://120.25.106.200:8080")
    parser.add_argument("--account-file", required=True)
    parser.add_argument("--connections", type=positive_int, required=True)
    parser.add_argument("--login-cache-file", required=True)
    parser.add_argument("--concurrency", type=positive_int, default=96)
    parser.add_argument("--request-timeout-seconds", type=float, default=30)
    parser.add_argument("--login-retries", type=int, default=2)
    parser.add_argument("--login-retry-delay-seconds", type=float, default=1)
    parser.add_argument("--load-generator-id", type=positive_int, default=1)
    parser.add_argument("--load-generator-count", type=positive_int, default=1)
    parser.add_argument("--account-shard-offset", type=int)
    parser.add_argument("--account-shard-limit", type=int)
    parser.add_argument("--device-id-prefix", default="tcp-load-driver")
    parser.add_argument("--progress-every", type=positive_int, default=100)
    args = parser.parse_args()

    accounts = load_accounts(args.account_file)
    shard_size = (len(accounts) + args.load_generator_count - 1) // args.load_generator_count
    offset = args.account_shard_offset
    if offset is None:
        offset = (args.load_generator_id - 1) * shard_size
    limit = args.account_shard_limit if args.account_shard_limit is not None else shard_size
    if offset < 0 or offset >= len(accounts):
        raise SystemExit(f"account shard offset is out of range: offset={offset}, total={len(accounts)}")
    if limit < args.connections:
        raise SystemExit(f"account shard limit {limit} is smaller than requested connections {args.connections}")
    if offset + args.connections > len(accounts):
        raise SystemExit(
            f"requested account range exceeds rows: offset={offset}, connections={args.connections}, total={len(accounts)}"
        )

    selected = accounts[offset : offset + args.connections]
    started = time.monotonic()
    print(
        "Prewarming login cache in parallel:\n"
        f"  baseURL={args.base_url.rstrip('/')}\n"
        f"  accountFile={args.account_file}\n"
        f"  connections={args.connections}\n"
        f"  shardOffset={offset}\n"
        f"  concurrency={args.concurrency}\n"
        f"  cacheFile={args.login_cache_file}",
        flush=True,
    )

    records: list[dict] = []
    errors: list[str] = []
    with ThreadPoolExecutor(max_workers=args.concurrency) as executor:
        futures = {
            executor.submit(
                login_one,
                args.base_url,
                offset + index,
                email,
                password,
                args.device_id_prefix,
                args.request_timeout_seconds,
                max(0, args.login_retries),
                max(0, args.login_retry_delay_seconds),
            ): offset + index
            for index, (email, password) in enumerate(selected)
        }
        for completed, future in enumerate(as_completed(futures), start=1):
            try:
                records.append(future.result())
            except Exception as error:
                errors.append(str(error))
            if completed % args.progress_every == 0 or completed == len(futures):
                elapsed = time.monotonic() - started
                print(
                    f"prewarm progress {completed}/{len(futures)} "
                    f"ok={len(records)} errors={len(errors)} elapsed={elapsed:.1f}s",
                    flush=True,
                )

    if errors:
        for error in errors[:20]:
            print(error, flush=True)
        raise SystemExit(f"login cache prewarm failed: errors={len(errors)}")

    records.sort(key=lambda item: int(item["loginIndex"]))
    tmp_path = f"{args.login_cache_file}.tmp"
    with open(tmp_path, "w") as file:
        json.dump(records, file, separators=(",", ":"))
        file.write("\n")
    import os

    os.replace(tmp_path, args.login_cache_file)
    now_ms = int(time.time() * 1000)
    min_valid = min(int(record["expiresAtMs"]) - now_ms for record in records) // 1000
    elapsed = time.monotonic() - started
    print(
        f"login-cache complete records={len(records)} cacheFile={args.login_cache_file} "
        f"minValidForSeconds={min_valid} elapsedSeconds={elapsed:.1f}",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
