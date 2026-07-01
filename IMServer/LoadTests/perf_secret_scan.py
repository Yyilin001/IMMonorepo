#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import re
import stat
import tempfile
from pathlib import Path
from typing import Iterable

from perf_forbidden_artifacts import forbidden_runtime_artifact_kinds


DEFAULT_ENV_NAMES = [
    "IM_INTERNAL_SECRET",
    "IM_INTERNAL_SHARED_SECRET",
    "IM_COMMAND_INTERNAL_SHARED_SECRET",
    "IM_METRICS_SECRET",
    "IM_METRICS_INTERNAL_SECRET",
    "IM_PASSWORD",
    "IM_ACCOUNT_VERIFICATION_CODE",
    "IM_ACCOUNT_PASSWORD_RESET_CODE",
    "JWT_SECRET",
    "JWT_SECRETS",
    "DATABASE_PASSWORD",
    "DATABASE_PRIMARY_PASSWORD",
    "IM_KAFKA_SASL_PASSWORD",
    "MEDIA_STORAGE_S3_SECRET_ACCESS_KEY",
    "AUDIT_ALERT_WEBHOOK_URL",
    "AUDIT_ALERT_WEBHOOK_HEADER",
    "SEED_USER_PASSWORD",
]

COMMON_PLACEHOLDER_VALUES = {
    "",
    "-",
    "<redacted>",
    "<set-in-shell-when-required>",
    "redacted",
    "null",
    "none",
    "true",
    "false",
    "password",
    "account_password",
    "password1234",
}

SENSITIVE_KEY_RE = re.compile(
    r"""(?ix)
    ["']?(?P<key>
      access[_-]?token|refresh[_-]?token|id[_-]?token|
      authorization|password|secret|secrets|jwt[_-]?secret|jwt[_-]?secrets|
      private[_-]?key|access[_-]?key
    )["']?
    (?P<sep>\s*[:=]\s*)
    (?P<quote>["'`]?)(?P<value>[^"'`\s,}\]]{8,})(?P=quote)
    """
)

PRIVATE_KEY_RE = re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----")


def forbidden_token_cache_path(path: Path) -> bool:
    return "token_cache_artifact" in forbidden_runtime_artifact_kinds(path)


def forbidden_account_artifact_path(path: Path) -> bool:
    return "account_artifact" in forbidden_runtime_artifact_kinds(path)


def forbidden_env_artifact_path(path: Path) -> bool:
    return "env_artifact" in forbidden_runtime_artifact_kinds(path)


def iter_files(roots: Iterable[Path]) -> Iterable[Path]:
    for root in roots:
        if root.is_symlink():
            yield root
            continue
        if root.is_file():
            yield root
            continue
        if not root.exists():
            continue
        if not root.is_dir():
            yield root
            continue
        for path in root.rglob("*"):
            if path.is_symlink():
                yield path
                continue
            try:
                mode = path.stat().st_mode
            except OSError:
                continue
            if stat.S_ISDIR(mode):
                continue
            if path.is_file() or not stat.S_ISREG(mode):
                yield path


def read_text(path: Path) -> str | None:
    try:
        data = path.read_bytes()
    except OSError:
        return None
    if b"\x00" in data:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return data.decode("utf-8", errors="replace")


def safe_value(value: str) -> bool:
    normalized = value.strip()
    lowered = normalized.lower()
    if lowered in COMMON_PLACEHOLDER_VALUES:
        return True
    if normalized.startswith("<") and normalized.endswith(">"):
        return True
    if normalized.startswith("${") and normalized.endswith("}"):
        return True
    if normalized.startswith("$"):
        return True
    if "${" in normalized:
        return True
    if "sys.argv" in normalized:
        return True
    if "password1234" in normalized:
        return True
    if normalized in DEFAULT_ENV_NAMES:
        return True
    return False


def collected_secret_values(env_names: list[str], explicit_values: list[str], min_length: int) -> dict[str, str]:
    values: dict[str, str] = {}
    for name in env_names:
        value = os.environ.get(name, "")
        if len(value) >= min_length and not safe_value(value):
            values[name] = value
    for index, value in enumerate(explicit_values, start=1):
        if len(value) >= min_length and not safe_value(value):
            values[f"explicit[{index}]"] = value
    return values


def scan_paths(args: argparse.Namespace) -> tuple[list[str], int]:
    roots = [Path(item) for item in args.root]
    secret_values = collected_secret_values(args.env_name, args.secret_value, args.min_secret_length)
    findings: list[str] = []
    scanned = 0

    for path in iter_files(roots):
        if path.is_symlink():
            findings.append(f"{path}: symlink_artifact")
            continue
        try:
            mode = path.stat().st_mode
        except OSError as error:
            findings.append(f"{path}: unreadable_artifact error={error.__class__.__name__}")
            continue
        if not stat.S_ISREG(mode):
            findings.append(f"{path}: special_file_artifact")
            continue
        if forbidden_token_cache_path(path):
            findings.append(f"{path}: token_cache_artifact")
        if forbidden_account_artifact_path(path):
            findings.append(f"{path}: account_artifact")
        if forbidden_env_artifact_path(path):
            findings.append(f"{path}: env_artifact")
        text = read_text(path)
        if text is None:
            continue
        scanned += 1
        if not args.allow_private_key and PRIVATE_KEY_RE.search(text):
            findings.append(f"{path}: private_key_marker")

        for name, value in secret_values.items():
            if value in text:
                findings.append(f"{path}: explicit_secret_value name={name}")

        if not args.disable_key_value_scan:
            for line_number, line in enumerate(text.splitlines(), start=1):
                for match in SENSITIVE_KEY_RE.finditer(line):
                    value = match.group("value").strip()
                    if safe_value(value):
                        continue
                    key = match.group("key")
                    findings.append(f"{path}:{line_number}: sensitive_key_value key={key}")
    return findings, scanned


def run_self_test() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        good = root / "good"
        bad = root / "bad"
        good.mkdir()
        bad.mkdir()
        (good / "runbook.md").write_text(
            "IM_INTERNAL_SECRET=${IM_INTERNAL_SECRET:?set-IM_INTERNAL_SECRET}\n"
            "IM_INTERNAL_SHARED_SECRET=${IM_INTERNAL_SHARED_SECRET:-${IM_INTERNAL_SECRET:?set-IM_INTERNAL_SECRET}}\n"
            "internal_secret: IM_INTERNAL_SECRET is not set\n"
            '"accessToken":"<redacted>"\n',
            encoding="utf-8",
        )
        (good / "production-acceptance.env.example").write_text(
            "BASE_URL=${PRODUCTION_ACCEPTANCE_BASE_URL:?set-PRODUCTION_ACCEPTANCE_BASE_URL}\n",
            encoding="utf-8",
        )
        (bad / "leak.json").write_text(
            '{"accessToken":"raw-access-token-012345","note":"ok"}\n',
            encoding="utf-8",
        )
        (bad / "key.pem").write_text(
            "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n",
            encoding="utf-8",
        )
        os.environ["PERF_SECRET_SCAN_TEST_SECRET"] = "scan-self-test-secret-012345"
        (bad / "production.env").write_text("BASE_URL=https://chat.prod.company.com\n", encoding="utf-8")
        (bad / ".env.local").write_text("BASE_URL=https://chat.prod.company.com\n", encoding="utf-8")
        (bad / "explicit.txt").write_text("scan-self-test-secret-012345\n", encoding="utf-8")
        login_cache = bad / "login-cache"
        login_cache.mkdir()
        (login_cache / "tcp-login-cache-lg1-1000.json").write_text("[]\n", encoding="utf-8")
        custom_cache = bad / "custom"
        custom_cache.mkdir()
        (custom_cache / "tcp_login_cache-lg1-1000.json").write_text("[]\n", encoding="utf-8")
        (custom_cache / "access-token-cache-lg1-1000.json").write_text("[]\n", encoding="utf-8")
        binary_cache = bad / "token_cache"
        binary_cache.mkdir()
        (binary_cache / "cache.bin").write_bytes(b"\x00\x01token")
        accounts = bad / "accounts"
        accounts.mkdir()
        (accounts / "load-10000.csv").write_text(
            "email,password\nload000001@example.com,do-not-package\n",
            encoding="utf-8",
        )
        (bad / "provisioned-accounts.csv").write_text(
            "email,password\nload000002@example.com,do-not-package\n",
            encoding="utf-8",
        )
        external_secret = root / "external-secret.txt"
        external_secret.write_text("IM_INTERNAL_SECRET=linked-secret-012345\n", encoding="utf-8")
        symlink_expected = True
        try:
            (bad / "linked-secret.txt").symlink_to(external_secret)
        except OSError:
            symlink_expected = False
        special_file_expected = True
        try:
            os.mkfifo(bad / "evidence.fifo")
        except (AttributeError, OSError):
            special_file_expected = False

        good_args = argparse.Namespace(
            root=[str(good)],
            env_name=["PERF_SECRET_SCAN_TEST_SECRET"],
            secret_value=[],
            min_secret_length=8,
            allow_private_key=False,
            disable_key_value_scan=False,
        )
        findings, _ = scan_paths(good_args)
        if findings:
            raise SystemExit("perf_secret_scan_self_test result=fail reason=good_fixture_flagged")

        bad_args = argparse.Namespace(
            root=[str(bad)],
            env_name=["PERF_SECRET_SCAN_TEST_SECRET"],
            secret_value=[],
            min_secret_length=8,
            allow_private_key=False,
            disable_key_value_scan=False,
        )
        findings, _ = scan_paths(bad_args)
        expected = [
            "explicit_secret_value",
            "private_key_marker",
            "sensitive_key_value",
            "token_cache_artifact",
            "account_artifact",
            "env_artifact",
        ]
        if symlink_expected:
            expected.append("symlink_artifact")
        if special_file_expected:
            expected.append("special_file_artifact")
        if not all(any(marker in finding for finding in findings) for marker in expected):
            raise SystemExit(
                "perf_secret_scan_self_test result=fail reason=bad_fixture_not_detected "
                + " findings="
                + repr(findings)
            )
    print("perf_secret_scan_self_test result=pass")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Fail if performance artifacts contain secret material.")
    parser.add_argument("--root", action="append", required=False, default=[])
    parser.add_argument("--env-name", action="append", default=list(DEFAULT_ENV_NAMES))
    parser.add_argument("--secret-value", action="append", default=[])
    parser.add_argument("--min-secret-length", type=int, default=8)
    parser.add_argument("--allow-private-key", action="store_true")
    parser.add_argument("--disable-key-value-scan", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        return run_self_test()
    if not args.root:
        parser.error("--root is required unless --self-test is used")

    findings, scanned = scan_paths(args)
    if findings:
        for finding in findings[:200]:
            print(f"perf_secret_scan finding={finding}")
        if len(findings) > 200:
            print(f"perf_secret_scan finding=truncated remaining={len(findings) - 200}")
        raise SystemExit(f"perf_secret_scan result=fail findings={len(findings)} scanned={scanned}")
    print(f"perf_secret_scan result=pass scanned={scanned}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
