#!/usr/bin/env python3
"""One-time generation of the glibc SDK from the pinned deployment base image."""

import argparse
import json
import os
from pathlib import Path
import platform
import subprocess

from build_v2_linux_release import SDK, SDK_LOCK, VERSION, verify_sdk


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--docker-context", help="Docker is only used to extract the SDK once")
    parser.add_argument("--cache", type=Path, default=Path.home() / "Library/Caches/IMProject/linux-sdk" / VERSION)
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("Run natively on an Apple Silicon Mac")
    bundle = Path.home() / "Library/org.swift.swiftpm/swift-sdks" / (SDK + ".artifactbundle")
    if bundle.exists():
        verify_sdk(bundle)
        print(f"Pinned Linux SDK is ready: {SDK}")
        return
    toolchain = Path.home() / "Library/Developer/Toolchains" / f"swift-{VERSION}-RELEASE.xctoolchain/usr/bin"
    swift = toolchain / "swift"
    version = subprocess.check_output([str(swift), "--version"], text=True)
    if "swift-6.4-RELEASE" not in version or "Target: arm64-apple-macosx" not in version:
        parser.error("Install the matching open-source Swift 6.4.0 arm64 toolchain first")
    metadata = json.loads(SDK_LOCK.read_text())
    args.cache.mkdir(parents=True, exist_ok=True)
    checkout = args.cache.resolve() / "generator"
    env = os.environ.copy()
    for key in ("SDKROOT", "SWIFT_EXEC", "TOOLCHAINS"):
        env.pop(key, None)
    env["PATH"] = str(toolchain) + os.pathsep + env.get("PATH", "")
    if args.docker_context:
        env["DOCKER_CONTEXT"] = args.docker_context
    if not checkout.exists():
        subprocess.run(["git", "clone", "--no-checkout", metadata["generatorRepository"], str(checkout)], check=True)
        subprocess.run(["git", "-C", str(checkout), "checkout", "--detach", metadata["generatorRevision"]], check=True)
    revision = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip()
    dirty = subprocess.check_output(["git", "-C", str(checkout), "status", "--porcelain", "--untracked-files=no"], text=True)
    if revision != metadata["generatorRevision"] or dirty:
        parser.error("SDK generator differs from the pinned source; use a fresh --cache directory")
    subprocess.run([str(swift), "run", "--scratch-path", str(args.cache.resolve() / "build"),
        "--configuration", "release", "--jobs", "8", "swift-sdk-generator", "make-linux-sdk",
        "--no-host-toolchain", "--swift-version", "6.4.0-RELEASE", "--with-docker",
        "--from-container-image", metadata["runtimeBase"], "--distribution-name", "ubuntu",
        "--distribution-version", "22.04", "--target", metadata["triple"], "--sdk-name", SDK],
        cwd=checkout, env=env, check=True)
    generated = checkout / "Bundles" / (SDK + ".artifactbundle")
    verify_sdk(generated)
    subprocess.run([str(swift), "sdk", "install", str(generated)], env=env, check=True)
    verify_sdk(bundle)
    print(f"Pinned Linux SDK is ready: {SDK}")


if __name__ == "__main__":
    main()
