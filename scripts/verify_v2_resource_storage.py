#!/usr/bin/env python3
"""Run real directory-scale and ENOSPC checks on an owned 64 MiB disk image.

macOS only. All evidence and the unmounted image are retained in a new output
directory. The host data volume is never filled. These are native integration
checks, not iPhone Release performance or APFS/locked-device acceptance.
"""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]


def inputs():
    result = {}
    for package in ("IMV2ClientKit", "IMV2Core", "IMV2Compression"):
        base = ROOT / package
        paths = [base / "Package.swift", base / "Package.resolved"]
        for directory in ("Sources", "Tests"):
            paths.extend((base / directory).rglob("*.swift"))
        for path in paths:
            if path.is_file():
                result[str(path.relative_to(ROOT))] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def owned_device(image, mount):
    info = plistlib.loads(subprocess.check_output(["hdiutil", "info", "-plist"]))
    images = [entry for entry in info["images"]
              if Path(entry.get("image-path", "")).resolve() == image.resolve()]
    if not images:
        return None
    if len(images) != 1:
        raise RuntimeError("Cannot uniquely identify the owned disk image")
    entities = images[0]["system-entities"]
    mounted = [entry for entry in entities if "mount-point" in entry]
    if mounted:
        if len(mounted) != 1 or Path(mounted[0]["mount-point"]).resolve() != mount.resolve():
            raise RuntimeError("Owned image has an unexpected mount; refusing to eject it")
        return mounted[0]["dev-entry"]
    disks = [entry["dev-entry"] for entry in entities
             if entry.get("content-hint") == "GUID_partition_scheme"]
    if len(disks) != 1:
        raise RuntimeError("Cannot identify the owned unmounted image device")
    return disks[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-directory", type=Path,
                        help="New directory for retained logs, manifest and 64 MiB image")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("This verifier requires macOS disk images")
    if args.output_directory:
        output = args.output_directory.expanduser().resolve()
        output.mkdir(parents=True, exist_ok=False)
    else:
        output = Path(tempfile.mkdtemp(prefix="im-resource-storage-")).resolve()
    image, mount = output / "test-volume.dmg", output / "mount"
    mount.mkdir()
    before = inputs()
    record = {"status": "preparing", "startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "sourceSHA256": before, "image": str(image), "mount": str(mount),
              "volumeDetached": False, "hostVolumeFilled": False,
              "scope": "Native 10000-entry keyset walk and actual HFS+ ENOSPC recovery; not device performance"}
    manifest = output / "result.json"

    def save():
        manifest.write_text(json.dumps(record, indent=2) + "\n")

    code = 1
    save()
    try:
        with (output / "disk.log").open("wb") as log:
            subprocess.run(["hdiutil", "create", "-size", "64m", "-type", "UDIF", "-fs", "Journaled HFS+",
                            "-volname", "IMResourceStorageTest", str(image)],
                           stdout=log, stderr=subprocess.STDOUT, check=True)
            attached = subprocess.run(["hdiutil", "attach", "-nobrowse", "-mountpoint", str(mount),
                                       "-plist", str(image)], stdout=subprocess.PIPE, stderr=log, check=True)
        (output / "attach.plist").write_bytes(attached.stdout)
        record["device"] = owned_device(image, mount)
        if record["device"] is None or not os.path.ismount(mount):
            raise RuntimeError("The owned test volume is not mounted")
        stat = os.statvfs(mount)
        capacity = stat.f_blocks * stat.f_frsize
        if capacity <= 0 or capacity > 256 * 1024 * 1024:
            raise RuntimeError("Test filesystem exceeds the bounded-volume safety limit")
        command = ["swift", "test", "--package-path", "IMV2ClientKit", "--disable-automatic-resolution",
                   "--filter", "V2ResourceDirectoryScaleTests|V2ResourceDiskFullTests"]
        environment = dict(os.environ, IMV2_RESOURCE_SCALE_VERIFICATION="1", IMV2_RESOURCE_ENOSPC_VOLUME=str(mount))
        record.update(status="running", command=command, volumeCapacityBytes=capacity)
        save()
        start = time.monotonic()
        with (output / "tests.log").open("w") as log:
            code = subprocess.run(command, cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT).returncode
        text = (output / "tests.log").read_text()
        record.update(exitCode=code, seconds=time.monotonic() - start,
                      scaleDiagnostics=re.findall(r"^RESOURCE_SCALE .+$", text, re.MULTILINE))
        if code or "skipped." in text or not re.search(r"Test run with 2 tests in 2 suites passed", text):
            raise RuntimeError("Both required tests must actually execute and pass; inspect tests.log")
        record["status"] = "passed"
    except Exception as error:
        record.update(status="failed", errorType=type(error).__name__, error=str(error))
        code = 1
    finally:
        try:
            device = owned_device(image, mount) if image.exists() else None
            if device is not None:
                detached = subprocess.run(["hdiutil", "detach", device], stdout=subprocess.PIPE,
                                          stderr=subprocess.STDOUT, text=True)
                record.update(detachExitCode=detached.returncode, detachOutput=detached.stdout)
                detached.check_returncode()
            record["volumeDetached"] = owned_device(image, mount) is None if image.exists() else True
        except Exception as error:
            record.update(status="cleanup-failed", cleanupError=str(error))
            code = 1
        after = inputs()
        drift = sorted(name for name in before.keys() | after.keys() if before.get(name) != after.get(name))
        record.update(sourceDrift=drift, finishedAt=datetime.datetime.now(datetime.timezone.utc).isoformat())
        if drift:
            record["status"] = "source-drift"
            code = 1
        save()
    print(json.dumps({"status": record["status"], "evidence": str(manifest),
                      "volumeDetached": record["volumeDetached"], "sourceDrift": record["sourceDrift"]}))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
