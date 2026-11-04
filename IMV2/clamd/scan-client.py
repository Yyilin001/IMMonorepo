#!/usr/bin/python3
"""Implement the resource worker's bounded clamscan CLI against its private resident daemon."""
import datetime
import email.utils
import re
import socket
import struct
import sys
from pathlib import Path

CONFIG = Path("/etc/imv2/clamd.conf")


def configuration():
    entries = {}
    for line in CONFIG.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            key, value = line.split(None, 1)
            if key in entries:
                raise ValueError("duplicate daemon setting")
            entries[key] = value
    return entries


def reply(conn):
    buf = bytearray()
    while len(buf) < 4096:
        chunk = conn.recv(4096 - len(buf))
        if not chunk:
            break
        buf.extend(chunk)
        if b"\0" in chunk:
            break
    if not buf.endswith(b"\0") or buf.count(b"\0") != 1:
        raise ValueError("incomplete daemon reply")
    return buf[:-1].decode("ascii")


def connect(path):
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.settimeout(95)
    try:
        conn.connect(path)
        return conn
    except BaseException:
        conn.close()
        raise


def version(path):
    with connect(path) as conn:
        conn.sendall(b"zVERSION\0")
        text = reply(conn)
    match = re.fullmatch(r"ClamAV ([0-9][0-9A-Za-z.-]*)/([0-9]+)/(.+)", text)
    if not match:
        raise ValueError("missing loaded signature version")
    # The daemon runs with TZ=UTC. VERSION describes its loaded database, not the files on disk.
    date = email.utils.parsedate_to_datetime(match[3]).replace(tzinfo=datetime.timezone.utc)
    age = (datetime.datetime.now(datetime.timezone.utc) - date).total_seconds()
    if not -300 <= age <= 2 * 86400:
        raise ValueError("unusable loaded signature date")
    return text


def scan(args, source):
    config = configuration()
    path = config["LocalSocket"]
    db_arg = "--database=" + config["DatabaseDirectory"]
    if args == ["--version", db_arg]:
        print(version(path))
        return 0

    # Reject options we cannot enforce. Daemon limits must match the policy
    # promised by the receipt, including nested files and encrypted archives.
    maximum = int(config["MaxFileSize"])
    if maximum <= 0 or int(config["StreamMaxLength"]) != maximum:
        raise ValueError("invalid stream limit")
    static = {"OfficialDatabaseOnly": "yes", "BytecodeUnsigned": "no", "HeuristicAlerts": "yes",
              "AlertEncrypted": "yes", "AlertExceedsMax": "yes", "FollowDirectorySymlinks": "no",
              "FollowFileSymlinks": "no"}
    if any(config[k] != v for k, v in static.items()):
        raise ValueError("unsafe scan policy")
    expected = {"--stdout", "--no-summary", db_arg, "--official-db-only=yes", "--fail-if-cvd-older-than=2",
                "--bytecode-unsigned=no", "--heuristic-alerts=yes", "--alert-encrypted=yes", "--alert-exceeds-max=yes",
                "--max-filesize=" + str(maximum), "--max-scansize=" + config["MaxScanSize"],
                "--max-files=" + config["MaxFiles"], "--max-recursion=" + config["MaxRecursion"],
                "--max-scantime=" + config["MaxScanTime"], "--follow-dir-symlinks=0", "--follow-file-symlinks=0", "-"}
    # Files are streamed. The caller's spool directory is never sent to clamd.
    if len(args) != len(expected) + 1 or set(a for a in args if not a.startswith("--tempdir=/")) != expected:
        raise ValueError("unsupported scan arguments")
    version(path)
    with connect(path) as conn:
        conn.sendall(b"zINSTREAM\0")
        total = 0
        while True:
            block = source.read(65536)
            if not block:
                break
            total += len(block)
            if total > maximum:
                raise ValueError("oversized input")
            conn.sendall(struct.pack("!I", len(block)) + block)
        conn.sendall(b"\0\0\0\0")
        result = reply(conn)
    if result == "stream: OK":
        print("stdin: OK")
        return 0
    if re.fullmatch(r"stream: [^\r\n\0]+ FOUND", result):
        print("stdin: " + result[len("stream: "):])
        return 1
    raise ValueError("no definitive scan verdict")


if __name__ == "__main__":
    try:
        sys.exit(scan(sys.argv[1:], sys.stdin.buffer))
    except (OSError, ValueError, KeyError, TypeError, OverflowError):
        print("scan service unavailable or invalid response", file=sys.stderr)
        sys.exit(2)
