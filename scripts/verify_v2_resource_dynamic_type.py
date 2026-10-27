#!/usr/bin/env python3
"""Drive a real, reversible system-font change on the owned resource simulator.

The matching XCTest measures live text frames and persisted preferences. Without
this driver that external-control test explicitly skips; this command rejects
skips, missing handshakes, source drift, and any related test failure.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import uuid


def output(command):
    return subprocess.check_output(command, text=True, stderr=subprocess.DEVNULL).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", default="498FF560-838F-4D56-B5CC-F63B74B229A3")
    parser.add_argument("--output-prefix", required=True)
    args = parser.parse_args()
    devices = json.loads(output(["xcrun", "simctl", "list", "devices", "--json"]))
    device = next(d for group in devices["devices"].values() for d in group if d["udid"] == args.device)
    if device["name"] != "IM Resource Center Verification" or device["state"] != "Booted":
        raise SystemExit("Use the booted, dedicated IM Resource Center Verification simulator.")
    repository = Path(__file__).resolve().parents[1]
    prefix = Path(args.output_prefix).resolve()
    result_path = Path(str(prefix) + ".xcresult")
    if result_path.exists():
        raise SystemExit("Result path already exists; choose a fresh output prefix.")
    original_size = output(["xcrun", "simctl", "ui", args.device, "content_size"])
    if original_size in {"unknown", "unsupported"}:
        raise SystemExit("The simulator does not expose a restorable system text size.")
    sources = [p for relative in ["IMApp/IMApp", "IMV2ClientKit/Sources", "IMV2Core/Sources"]
               for p in (repository / relative).rglob("*.swift")]
    sources.append(repository / "IMApp/IMAppUITests/IMAppResourceCenterUITests.swift")
    sources.append(Path(__file__).resolve())
    digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    before = {str(p.relative_to(repository)): digest(p) for p in sources}
    report = {"startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "device": args.device, "originalContentSize": original_size,
              "sourceSHA256": before, "actions": []}
    command = ["xcodebuild", "-project", "IMApp/IMApp.xcodeproj", "-scheme", "IMApp",
               "-configuration", "Debug", "-destination", "platform=iOS Simulator,id=" + args.device,
               "-derivedDataPath", "/tmp/IMResourceCenterDerivedData",
               "-clonedSourcePackagesDirPath", "/tmp/IMResourceCenterDerivedData/SourcePackages",
               "-jobs", "2", "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
               "-resultBundlePath", str(result_path),
               "-only-testing:IMAppUITests/IMAppResourceCenterUITests/testDownloadSettingsRespondToSystemTextSize",
               "-only-testing:IMAppUITests/IMAppResourceCenterUITests/testUnavailableRetentionManagementSupportsLargeTextAndDarkMode",
               "-only-testing:IMAppUITests/IMAppLaunchUITests/testPausedRevocationAtLargestTextInRTL",
               "CODE_SIGNING_ALLOWED=NO", "test"]
    started = time.time()
    handled = set()
    process = None
    try:
        with Path(str(prefix) + ".log").open("w") as log:
            process = subprocess.Popen(command, cwd=repository, stdout=log, stderr=subprocess.STDOUT)
            while process.poll() is None:
                try:
                    container = Path(output(["xcrun", "simctl", "get_app_container", args.device,
                                             "com.codex.imappUITests.xctrunner", "data"]))
                    request = container / "tmp/im-resource-system-type-request.json"
                    if request.is_symlink() or not request.exists() or request.stat().st_mtime < started:
                        time.sleep(0.25)
                        continue
                    if request.stat().st_size > 4096:
                        raise RuntimeError("Unbounded font-control request")
                    data = json.loads(request.read_text())
                    token = str(uuid.UUID(data["token"]))
                    if token.upper() != data["token"].upper():
                        raise RuntimeError("Noncanonical test token")
                    phase = data["phase"]
                    key = (token, phase)
                    if key in handled:
                        time.sleep(0.25)
                        continue
                    if phase == "await-controller":
                        acknowledgment = container / "tmp/im-resource-system-type-ack.txt"
                        temporary = acknowledgment.with_suffix(".pending")
                        temporary.write_text(data["token"])
                        os.replace(temporary, acknowledgment)
                    elif phase in {"grow", "restore"}:
                        size = "accessibility-extra-extra-extra-large" if phase == "grow" else original_size
                        subprocess.run(["xcrun", "simctl", "ui", args.device, "content_size", size], check=True)
                        report["actions"].append({"phase": phase, "size": size, "token": token})
                        print(json.dumps({"phase": phase, "size": size}), flush=True)
                    else:
                        raise RuntimeError("Unknown font-control phase")
                    handled.add(key)
                except (FileNotFoundError, json.JSONDecodeError, subprocess.CalledProcessError):
                    pass
                time.sleep(0.25)
            report["exitCode"] = process.returncode
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            report["exitCode"] = process.returncode
        subprocess.run(["xcrun", "simctl", "ui", args.device, "content_size", original_size], check=True)
        report["restoredContentSize"] = output(["xcrun", "simctl", "ui", args.device, "content_size"])
        report["sourceDrift"] = [name for name, sha in before.items() if digest(repository / name) != sha]
        report["finishedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        Path(str(prefix) + ".json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    summary = json.loads(output(["xcrun", "xcresulttool", "get", "test-results", "summary",
                                 "--path", str(result_path), "--format", "json"]))
    Path(str(prefix) + "-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    if (process.returncode or {a["phase"] for a in report["actions"]} != {"grow", "restore"}
            or report["sourceDrift"] or summary.get("failedTests") or summary.get("skippedTests")):
        raise SystemExit(1)
    print(json.dumps({"result": "passed", "actions": report["actions"], "systemSizeRestored": True}), flush=True)


if __name__ == "__main__":
    main()
