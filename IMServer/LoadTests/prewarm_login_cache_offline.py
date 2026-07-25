#!/usr/bin/env python3
"""Build TCP load-test credentials without consuming the HTTP login path.

This tool is deliberately limited to a host with Docker access to the local IM
test stack. It creates dedicated auth sessions in PostgreSQL and signs access
tokens with the gateway container's configured signing key. It never prints the
key or token values. Do not use it against a production database.
"""

from __future__ import annotations

import argparse
import base64
import csv
import hashlib
import hmac
import io
import json
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return parsed


def base64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def signed_access_token(*, user_id: str, session_id: str, email: str, issuer: str, expires_at: int, secret: str, kid: str | None) -> str:
    header = {"alg": "HS256", "typ": "JWT"}
    if kid:
        header["kid"] = kid
    payload = {
        "sub": user_id,
        "sid": session_id,
        "email": email,
        "iss": issuer,
        "exp": expires_at,
        "typ": "access",
    }
    signing_input = ".".join(
        (
            base64url(json.dumps(header, separators=(",", ":")).encode()),
            base64url(json.dumps(payload, separators=(",", ":")).encode()),
        )
    )
    signature = hmac.new(secret.encode(), signing_input.encode(), hashlib.sha256).digest()
    return f"{signing_input}.{base64url(signature)}"


def load_accounts(path: Path, connections: int) -> list[tuple[int, str]]:
    accounts: list[tuple[int, str]] = []
    with path.open(newline="") as handle:
        for row in csv.reader(handle):
            if not row or not row[0].strip() or row[0].lstrip().startswith("#"):
                continue
            accounts.append((len(accounts), row[0].strip().lower()))
            if len(accounts) == connections:
                break
    if len(accounts) != connections:
        raise SystemExit(f"account file has {len(accounts)} usable rows; need {connections}")
    return accounts


def container_env(container: str) -> dict[str, str]:
    output = subprocess.check_output(
        ["docker", "inspect", "--format", "{{range .Config.Env}}{{println .}}{{end}}", container],
        text=True,
    )
    return dict(line.split("=", 1) for line in output.splitlines() if "=" in line)


def signing_configuration(env: dict[str, str]) -> tuple[str, str | None, str, int]:
    active_kid = env.get("JWT_ACTIVE_KID") or None
    raw_secrets = env.get("JWT_SECRETS", "")
    if raw_secrets:
        secrets = dict(item.split(":", 1) for item in raw_secrets.split(",") if ":" in item)
        if not active_kid or active_kid not in secrets:
            raise SystemExit("gateway JWT_SECRETS/JWT_ACTIVE_KID configuration is invalid")
        secret = secrets[active_kid]
    else:
        secret = env.get("JWT_SECRET", "")
        if not secret:
            raise SystemExit("gateway does not expose a configured JWT signing key")
    issuer = env.get("JWT_ISSUER", "vapor-test")
    ttl_seconds = int(env.get("AUTH_ACCESS_TOKEN_TTL_SECONDS", "600"))
    return secret, active_kid, issuer, ttl_seconds


def psql_insert_and_resolve(
    *,
    postgres_container: str,
    database: str,
    username: str,
    rows: list[dict[str, str]],
    refresh_expires_at: str,
) -> list[dict[str, str]]:
    script = """\
CREATE TEMP TABLE im_load_cache_sessions (
  login_index integer NOT NULL,
  email text NOT NULL,
  session_id uuid NOT NULL,
  nonce text NOT NULL,
  device_id text NOT NULL,
  device_name text NOT NULL
);
COPY im_load_cache_sessions (login_index,email,session_id,nonce,device_id,device_name) FROM STDIN WITH (FORMAT csv);
"""
    csv_lines = []
    for row in rows:
        buffer = io.StringIO()
        writer = csv.writer(buffer, lineterminator="\n")
        writer.writerow([row["loginIndex"], row["email"], row["sessionID"], row["nonce"], row["deviceID"], row["deviceName"]])
        csv_lines.append(buffer.getvalue())
    script += "".join(csv_lines)
    script += "\\.\n"
    script += """
INSERT INTO auth_sessions (
  id, user_id, current_nonce, refresh_expires_at, device_id, device_name,
  platform, app_version, last_seen_at, created_at, updated_at
)
SELECT
  source.session_id, users.id, source.nonce, :'refresh_expires_at'::timestamptz,
  source.device_id, source.device_name, 'load-test', 'offline-cache', now(), now(), now()
FROM im_load_cache_sessions AS source
JOIN users ON users.email = source.email;
COPY (
  SELECT source.login_index, users.id, source.email, source.session_id,
         source.device_id, source.device_name
  FROM im_load_cache_sessions AS source
  JOIN users ON users.email = source.email
  ORDER BY source.login_index
) TO STDOUT WITH (FORMAT csv);
"""
    result = subprocess.run(
        [
            "docker", "exec", "-i", postgres_container,
            "psql", "-q", "-t", "-A", "-U", username, "-d", database,
            "-v", "ON_ERROR_STOP=1",
            "-v", f"refresh_expires_at={refresh_expires_at}",
        ],
        input=script,
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        raise SystemExit(f"offline session insert failed: {result.stderr.strip()[-1000:]}")
    resolved: list[dict[str, str]] = []
    for row in csv.reader(result.stdout.splitlines()):
        if len(row) != 6:
            continue
        login_index, user_id, email, session_id, device_id, device_name = row
        resolved.append(
            {
                "loginIndex": login_index,
                "userID": user_id,
                "email": email,
                "sessionID": session_id,
                "deviceID": device_id,
                "deviceName": device_name,
            }
        )
    return resolved


def main() -> int:
    parser = argparse.ArgumentParser(description="Create a test-only offline TCP login cache using the local Docker IM stack.")
    parser.add_argument("--account-file", required=True, type=Path)
    parser.add_argument("--connections", required=True, type=positive_int)
    parser.add_argument("--login-cache-file", required=True, type=Path)
    parser.add_argument("--gateway-container", default="imserver-production-smoke-gateway-1")
    parser.add_argument("--postgres-container", default="imserver-production-smoke-postgres-1")
    parser.add_argument("--postgres-database", default="imserver_smoke")
    parser.add_argument("--postgres-user", default="imserver")
    parser.add_argument("--device-id-prefix", default="offline-tcp-load")
    parser.add_argument("--refresh-ttl-seconds", type=positive_int, default=30 * 24 * 60 * 60)
    args = parser.parse_args()

    accounts = load_accounts(args.account_file, args.connections)
    env = container_env(args.gateway_container)
    secret, kid, issuer, access_ttl_seconds = signing_configuration(env)
    now = int(time.time())
    expires_at = now + access_ttl_seconds
    refresh_expires_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now + args.refresh_ttl_seconds))
    run_id = uuid.uuid4().hex[:12]
    pending = [
        {
            "loginIndex": str(index),
            "email": email,
            "sessionID": str(uuid.uuid4()),
            "nonce": uuid.uuid4().hex,
            "deviceID": f"{args.device_id_prefix}-{run_id}-{index}",
            "deviceName": f"{args.device_id_prefix}-{run_id}-{index}",
        }
        for index, email in accounts
    ]

    print(f"offline cache preparation connections={args.connections} devicePrefix={args.device_id_prefix}-{run_id}", flush=True)
    resolved = psql_insert_and_resolve(
        postgres_container=args.postgres_container,
        database=args.postgres_database,
        username=args.postgres_user,
        rows=pending,
        refresh_expires_at=refresh_expires_at,
    )
    if len(resolved) != args.connections:
        raise SystemExit(f"offline session insert resolved {len(resolved)} users; expected {args.connections}")

    records = [
        {
            "loginIndex": int(row["loginIndex"]),
            "email": row["email"],
            "deviceID": row["deviceID"],
            "deviceName": row["deviceName"],
            "userID": row["userID"],
            "accessToken": signed_access_token(
                user_id=row["userID"],
                session_id=row["sessionID"],
                email=row["email"],
                issuer=issuer,
                expires_at=expires_at,
                secret=secret,
                kid=kid,
            ),
            "expiresAtMs": expires_at * 1000,
        }
        for row in resolved
    ]
    args.login_cache_file.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = args.login_cache_file.with_suffix(args.login_cache_file.suffix + ".tmp")
    temporary_path.write_text(json.dumps(records, separators=(",", ":")) + "\n")
    os.replace(temporary_path, args.login_cache_file)
    print(
        f"offline login cache complete records={len(records)} cacheFile={args.login_cache_file} "
        f"validForSeconds={access_ttl_seconds}",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
