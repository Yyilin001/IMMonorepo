#!/usr/bin/env python3
"""Run offline instrumentation on an explicitly selected Android device.

Build/install the APKs first. This script never clears application data or changes
device settings. Backend tests requiring explicit fixture arguments are skipped.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time


def parse_results(output):
    fields, results, expected = {}, [], None
    for line in output.splitlines():
        if line.startswith("INSTRUMENTATION_STATUS: "):
            key, separator, value = line[24:].partition("=")
            if separator:
                fields[key] = value
                if key == "numtests":
                    expected = int(value)
        elif line.startswith("INSTRUMENTATION_STATUS_CODE: "):
            code = int(line.split(": ", 1)[1])
            if code <= 0 and "class" in fields and "test" in fields:
                results.append({"class": fields["class"], "test": fields["test"], "code": code})
            fields = {}
    complete = bool(re.search(r"^INSTRUMENTATION_CODE: -1\s*$", output, re.MULTILINE))
    return {
        "expected": expected,
        "passed": sum(r["code"] == 0 for r in results),
        "skipped": sum(r["code"] in (-3, -4) for r in results),
        "failures": [r for r in results if r["code"] not in (0, -3, -4)],
        "complete": complete and expected is not None and len(results) == expected
        and "INSTRUMENTATION_FAILED" not in output and "shortMsg=" not in output,
        "results": results,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--api", type=int, default=31)
    parser.add_argument("--suite", choices=("platform", "app"), required=True)
    parser.add_argument("--classes", help="Optional comma-separated fully qualified test classes")
    parser.add_argument("--adb", default=shutil.which("adb") or str(
        Path(os.environ.get("ANDROID_HOME", Path.home() / "Library/Android/sdk")) / "platform-tools/adb"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout", type=int, default=3600)
    args = parser.parse_args()
    adb = [args.adb, "-s", args.serial]
    def shell(*command):
        return subprocess.check_output(adb + ["shell", *command], text=True, timeout=30).strip()
    api = int(shell("getprop", "ro.build.version.sdk"))
    if api != args.api or shell("getprop", "sys.boot_completed") != "1":
        parser.error(f"Device must be booted API {args.api}; observed API {api}")
    fingerprint = shell("getprop", "ro.build.fingerprint")
    package = "com.xmtx.im.platform.test" if args.suite == "platform" else "com.xmtx.im.android.test"
    command = adb + ["shell", "am", "instrument", "-w", "-r"]
    if args.classes:
        command += ["-e", "class", args.classes]
    command += [package + "/androidx.test.runner.AndroidJUnitRunner"]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    timed_out = False
    with args.output.open("w") as log:
        try:
            returncode = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=args.timeout).returncode
        except subprocess.TimeoutExpired:
            timed_out, returncode = True, None
            # Stop only this invocation's target, on the explicitly selected device.
            shell("am", "force-stop", "com.xmtx.im.android" if args.suite == "app" else package)
    summary = parse_results(args.output.read_text())
    summary.update(serial=args.serial, api=api, fingerprint=fingerprint, suite=args.suite,
                   seconds=round(time.monotonic() - started, 3), returncode=returncode, timed_out=timed_out)
    args.output.with_suffix(".json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({k: v for k, v in summary.items() if k != "results"}, ensure_ascii=False))
    return 0 if returncode == 0 and summary["complete"] and not summary["failures"] else 1


if __name__ == "__main__":
    sys.exit(main())
