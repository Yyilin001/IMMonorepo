#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
from pathlib import Path


TOKEN_CACHE_PARTS = {
    "login-cache",
    "login_cache",
    "token-cache",
    "token_cache",
}

ACCOUNT_ARTIFACT_PARTS = {
    "accounts",
    "load-accounts",
    "load_accounts",
    "provisioned-accounts",
    "provisioned_accounts",
    "account-credentials",
    "account_credentials",
}

ACCOUNT_ARTIFACT_NAMES = {
    "accounts.csv",
    "load-accounts.csv",
    "load_accounts.csv",
    "provisioned-accounts.csv",
    "provisioned_accounts.csv",
    "account-credentials.csv",
    "account_credentials.csv",
}

TOKEN_CACHE_PREFIXES = (
    "tcp-login-cache",
    "tcp_login_cache",
    "access-token-cache",
    "access_token_cache",
)


def forbidden_runtime_artifact_kinds(path_like: str | Path) -> list[str]:
    path = Path(str(path_like))
    parts = [part.lower() for part in path.parts]
    name = path.name.lower()
    kinds: list[str] = []

    if any(part in TOKEN_CACHE_PARTS for part in parts) or name.startswith(TOKEN_CACHE_PREFIXES):
        kinds.append("token_cache_artifact")

    if any(part in ACCOUNT_ARTIFACT_PARTS for part in parts):
        kinds.append("account_artifact")
    elif name in ACCOUNT_ARTIFACT_NAMES or re.fullmatch(r"load-\d+\.csv", name) is not None:
        kinds.append("account_artifact")

    if not (name.endswith(".env.example") or name.endswith(".example.env")):
        if name == ".env" or name.startswith(".env.") or name.endswith(".env") or ".env." in name:
            kinds.append("env_artifact")

    return kinds


def is_forbidden_runtime_artifact(path_like: str | Path) -> bool:
    return bool(forbidden_runtime_artifact_kinds(path_like))


def self_test() -> None:
    cases: tuple[tuple[str, tuple[str, ...]], ...] = (
        ("results/login-cache/lg1.json", ("token_cache_artifact",)),
        ("results/tcp-login-cache-1000.json", ("token_cache_artifact",)),
        ("IMServer/LoadTests/accounts/load-10000.csv", ("account_artifact",)),
        ("IMServer/LoadTests/provisioned_accounts/users.json", ("account_artifact",)),
        ("IMServer/LoadTests/account-credentials.csv", ("account_artifact",)),
        ("IMServer/LoadTests/load-5000.csv", ("account_artifact",)),
        ("deploy/runtime/.env", ("env_artifact",)),
        ("deploy/runtime/.env.production", ("env_artifact",)),
        ("deploy/runtime/command-api.env", ("env_artifact",)),
        ("IMServer/config/env/command-api.production.env.example", ()),
        ("IMServer/config/env/command-api.example.env", ()),
        ("IMServer/LoadTests/results/production-evidence.tar.gz", ()),
    )
    for raw_path, expected in cases:
        actual = tuple(forbidden_runtime_artifact_kinds(raw_path))
        if actual != expected:
            raise SystemExit(
                "perf_forbidden_artifacts_self_test result=fail "
                f"path={raw_path} expected={','.join(expected) or '-'} actual={','.join(actual) or '-'}"
            )
    print("perf_forbidden_artifacts_self_test result=pass")


def main() -> None:
    parser = argparse.ArgumentParser(description="Classify forbidden production runtime artifacts.")
    parser.add_argument("paths", nargs="*", help="Path(s) to classify.")
    parser.add_argument("--self-test", action="store_true", help="Run built-in classification checks.")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    for raw_path in args.paths:
        kinds = forbidden_runtime_artifact_kinds(raw_path)
        if kinds:
            print(f"{raw_path}:forbidden:{','.join(kinds)}")
        else:
            print(f"{raw_path}:allowed")


if __name__ == "__main__":
    main()
