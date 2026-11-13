#!/usr/bin/env python3
"""Run an already-built probe on one explicit device; reject skipped/partial runs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
PACKAGE = "com.xmtx.im.swiftprobe"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--serial", required=True)
    parser.add_argument("--api", type=int, required=True)
    parser.add_argument("--variant", choices=["debug", "release"], default="debug")
    args = parser.parse_args()
    android = Path(os.environ.get("ANDROID_HOME", Path.home() / "Library/Android/sdk"))
    adb = [str(android / "platform-tools/adb"), "-s", args.serial]

    def call(*command, **kwargs):
        return subprocess.check_output(adb + list(command), text=True, timeout=180, **kwargs)

    actual_api = int(call("shell", "getprop", "ro.build.version.sdk").strip())
    if actual_api != args.api:
        raise SystemExit(f"Expected API {args.api}, found {actual_api}")
    output = HERE / "build" / f"api{args.api}-{args.variant}"
    output.mkdir(parents=True, exist_ok=True)
    apk_root = ROOT / "IMAndroid/swiftprobe/build/outputs/apk"
    apk = apk_root / args.variant / f"swiftprobe-{args.variant}.apk"
    test = apk_root / "androidTest" / args.variant / f"swiftprobe-{args.variant}-androidTest.apk"
    for file in [apk, test]:
        print(call("install", "-r", str(file)), flush=True)
    # The release harness is intentionally debuggable for exporting test evidence.
    call("shell", "run-as", PACKAGE, "rm", "-f", "files/probe-results.json")
    command = adb + ["shell", "am", "instrument", "-w", "-r", "-e", "class", PACKAGE + ".SwiftProbeTests",
                     PACKAGE + ".test/androidx.test.runner.AndroidJUnitRunner"]
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
    (output / "instrumentation.log").write_text(result.stdout)
    print(result.stdout)
    raw = call("shell", "run-as", PACKAGE, "cat", "files/probe-results.json")
    report = json.loads(raw)
    report["apkSHA256"] = hashlib.sha256(apk.read_bytes()).hexdigest()
    report["variant"] = args.variant
    report["serial"] = args.serial
    device_path = call("shell", "pm", "path", PACKAGE).strip().removeprefix("package:")
    installed_hash = call("shell", "sha256sum", device_path).split()[0]
    report["installedApkSHA256"] = installed_hash
    source = ROOT / "IMAndroid/swiftprobe/src/androidTest/kotlin/com/xmtx/im/swiftprobe/SwiftProbeTests.kt"
    expected = set(re.findall(r"@Test fun (\w+)\(", source.read_text()))
    actual = report["tests"]
    passed = result.returncode == 0 and f"OK ({len(expected)} tests)" in result.stdout
    passed = passed and set(actual) == expected and all(t["status"] == "passed" for t in actual.values())
    passed = passed and installed_hash == report["apkSHA256"]
    report["verified"] = passed
    (output / "results.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    if not passed:
        raise SystemExit("Probe failed or incomplete; inspect results.json and instrumentation.log")


if __name__ == "__main__":
    main()
