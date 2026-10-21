#!/usr/bin/env python3
"""Durably stage signed trust grants locally or in owned multi-server test VMs.

Receipts confirm file publication only, never runtime acceptance or membership.
Only the signed packet is transmitted; no deployment secrets are read.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

# Standalone worker sent over the existing Colima management channel. Atomic
# create-if-absent keeps retries safe after an ambiguous connection failure.
WORKER = r'''
import hashlib, json, os, stat, sys, uuid
directory, expected = sys.argv[1:]
data = sys.stdin.buffer.read(524289)
if not data or len(data) > 524288 or hashlib.sha256(data).hexdigest() != expected:
    raise ValueError("invalid or truncated authorization packet")
if not os.path.isabs(directory):
    raise ValueError("admission directory must be absolute")
root = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
temporary = ".admission-" + uuid.uuid4().hex + ".tmp"
destination = expected + ".pb"
created = False
try:
    output = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=root)
    try:
        with os.fdopen(output, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        try:
            os.link(temporary, destination, src_dir_fd=root, dst_dir_fd=root, follow_symlinks=False)
            created = True
        except FileExistsError:
            existing = os.open(destination, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=root)
            with os.fdopen(existing, "rb") as stream:
                if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode) or stream.read(524289) != data:
                    raise ValueError("existing authorization file differs or is not regular")
        os.fsync(root)
    finally:
        os.unlink(temporary, dir_fd=root)
        os.fsync(root)
finally:
    os.close(root)
print(json.dumps(dict(status="published" if created else "already_published", sha256=expected,
    bytes=len(data), path=os.path.join(directory, destination), runtimeAcceptance="unconfirmed")))
'''


def publish(data, directory, profile=None):
    if not 0 < len(data) <= 524288:
        raise ValueError("authorization packet must contain 1..524288 bytes")
    if not Path(directory).is_absolute():
        raise ValueError("admission directory must be absolute")
    digest = hashlib.sha256(data).hexdigest()
    if profile is not None and not re.fullmatch(r"imv2-growth-[a-z0-9-]+", profile):
        raise ValueError("remote publication requires an owned imv2-growth-* VM")
    command = (["colima", "-p", profile, "ssh", "--", "python3"] if profile else [sys.executable])
    result = subprocess.run(command + ["-c", WORKER, str(directory), digest], input=data,
                            capture_output=True, timeout=30, check=True)
    receipt = json.loads(result.stdout)
    if receipt.get("sha256") != digest or receipt.get("bytes") != len(data):
        raise ValueError("publication receipt does not match the submitted packet")
    return dict(receipt, profile=profile)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--packet", type=Path, required=True)
    parser.add_argument("--local-directory", action="append", default=[])
    parser.add_argument("--target", action="append", default=[], metavar="PROFILE:/ABSOLUTE/DIRECTORY")
    args = parser.parse_args()
    targets = [(None, directory) for directory in args.local_directory]
    for target in args.target:
        profile, separator, directory = target.partition(":")
        if not separator or not re.fullmatch(r"imv2-growth-[a-z0-9-]+", profile) or not Path(directory).is_absolute():
            parser.error("target must identify an owned imv2-growth-* profile and absolute directory")
        targets.append((profile, directory))
    if not targets or any(not Path(directory).is_absolute() for _, directory in targets):
        parser.error("provide at least one absolute target directory")
    with args.packet.open("rb") as stream:
        data = stream.read(524289)
    failed = False
    for profile, directory in targets:
        try:
            print(json.dumps(publish(data, directory, profile)), flush=True)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            # A timeout may occur after the durable write. Retrying the exact
            # packet converges; it must not trigger deletion or key rotation.
            failed = True
            print(json.dumps(dict(profile=profile, directory=directory, status="unconfirmed",
                                  error=type(error).__name__)), flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
