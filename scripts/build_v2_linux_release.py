#!/usr/bin/env python3
"""Build Linux release executables with the native macOS Swift compiler.

No Docker daemon, guest compiler, deployment credentials or emulation required.
See docs/guides/native-linux-release.md for runtime verification and deployment.
"""

import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import struct
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
VERSION = "6.4.0"
SDK = "im-resource-swift64-jammy-x86_64"
TRIPLE = "x86_64-unknown-linux-gnu"
PATCH = ROOT / "scripts/linux-sdk/swift-nio-2.104.0-imports.json"
SDK_LOCK = ROOT / "scripts/linux-sdk/toolchain.json"
PRODUCTS = (
    "IMV2AccountServerApp", "IMV2ServerApp", "IMV2OperatorServerApp",
    "IMV2PlacementControlApp", "IMV2RoomHostSupervisorApp",
    "IMV2ResourceImageWorker", "IMV2LocalGatewayProbe",
)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def source_manifest():
    files = {}
    for package in ("IMV2Core", "IMV2Compression", "IMV2Server"):
        for directory, names, filenames in os.walk(ROOT / package):
            names[:] = sorted(n for n in names if not n.startswith("."))
            for name in sorted(filenames):
                path = Path(directory) / name
                if not name.startswith("."):
                    files[str(path.relative_to(ROOT))] = sha256(path)
    for path in (Path(__file__), PATCH, SDK_LOCK, ROOT / "IMV2/Dockerfile.account.prebuilt"):
        files[str(path.relative_to(ROOT))] = sha256(path)
    return files


def verify_linux_elf(path):
    """Reject wrong architecture/interpreter and truncated ELF tables.

    Dynamic library resolution is checked separately in the Linux runtime image.
    """
    with path.open("rb") as stream:
        size = path.stat().st_size
        header = stream.read(64)
        if len(header) != 64 or header[:7] != b"\x7fELF\x02\x01\x01":
            raise ValueError(f"Expected ELF64 little-endian: {path.name}")
        kind, machine = struct.unpack_from("<HH", header, 16)
        if machine != 62 or kind not in (2, 3):
            raise ValueError(f"Expected Linux x86_64 executable: {path.name}")
        offset = struct.unpack_from("<Q", header, 32)[0]
        stride, count = struct.unpack_from("<HH", header, 54)
        if stride < 56 or count == 0 or offset < 64 or offset + stride * count > size:
            raise ValueError("Invalid ELF program header table")
        interpreter = None
        for index in range(count):
            stream.seek(offset + stride * index)
            segment = stream.read(56)
            segment_type = struct.unpack_from("<I", segment)[0]
            start = struct.unpack_from("<Q", segment, 8)[0]
            length = struct.unpack_from("<Q", segment, 32)[0]
            if start + length > size:
                raise ValueError("Truncated ELF segment")
            if segment_type == 3:
                stream.seek(start)
                interpreter = stream.read(length).rstrip(b"\0").decode("ascii")
                if interpreter != "/lib64/ld-linux-x86-64.so.2":
                    raise ValueError("Unexpected Linux interpreter")
            if segment_type == 2:
                if length % 16:
                    raise ValueError("Invalid ELF dynamic table")
                stream.seek(start)
                for _ in range(length // 16):
                    tag, _ = struct.unpack("<qQ", stream.read(16))
                    if tag == 0:
                        break
    return {"format": "ELF64", "architecture": "x86_64", "static": interpreter is None,
            "interpreter": interpreter}


def verify_load_segments(original, stripped):
    def headers(path):
        with path.open("rb") as stream:
            header = stream.read(64)
            offset = struct.unpack_from("<Q", header, 32)[0]
            stride, count = struct.unpack_from("<HH", header, 54)
            result = []
            for index in range(count):
                stream.seek(offset + stride * index)
                result.append(struct.unpack("<IIQQQQQQ", stream.read(56)))
            return result

    def segment_hash(path, offset, length):
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            stream.seek(offset)
            while length:
                data = bytearray(stream.read(min(length, 1024 * 1024)))
                if not data:
                    raise ValueError("Truncated ELF load segment")
                # Only the non-runtime ELF section table metadata may change.
                for low, high in ((40, 48), (58, 64)):
                    begin, end = max(low, offset), min(high, offset + len(data))
                    if begin < end:
                        data[begin - offset:end - offset] = bytes(end - begin)
                digest.update(data)
                offset += len(data)
                length -= len(data)
        return digest.hexdigest()

    before = headers(original)
    if before != headers(stripped):
        raise ValueError("Stripping changed ELF program headers")
    for entry in before:
        if entry[0] == 1 and segment_hash(original, entry[2], entry[5]) != segment_hash(stripped, entry[2], entry[5]):
            raise ValueError("Stripping changed executable load segments")


def apply_dependency_patch(checkout, metadata):
    revision = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip()
    if revision != metadata["revision"]:
        raise ValueError("SwiftNIO revision changed; review the SDK patch before building")
    for relative, expected in metadata["files"].items():
        path = checkout / relative
        digest = sha256(path)
        if digest == expected["patchedSHA256"]:
            continue
        if digest != expected["originalSHA256"]:
            raise ValueError(f"Unrecognized SwiftNIO checkout change: {relative}")
        module = expected["module"]
        patched = f"#if os(Linux) && canImport({module})\nimport {module}\n#endif\n\n" + path.read_text()
        if hashlib.sha256(patched.encode()).hexdigest() != expected["patchedSHA256"]:
            raise ValueError("SDK patch checksum mismatch")
        path.chmod(path.stat().st_mode | 0o200)
        path.write_text(patched)


def verify_sdk(bundle):
    metadata = json.loads(SDK_LOCK.read_text())
    root = bundle / metadata["sdkRootRelativePath"]
    for relative, digest in metadata["runtimeLibrarySHA256"].items():
        if sha256(root / relative) != digest:
            raise ValueError(f"SDK runtime differs from pinned deployment image: {relative}")
    return metadata


def write_json(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--toolchain", type=Path, default=Path.home() / "Library/Developer/Toolchains" / f"swift-{VERSION}-RELEASE.xctoolchain")
    parser.add_argument("--scratch-path", type=Path, default=ROOT / f".build-linux-glibc-{VERSION}")
    parser.add_argument("--output", type=Path, default=ROOT / "build/native-linux-release")
    parser.add_argument("--jobs", type=int, default=min(8, os.cpu_count() or 1))
    parser.add_argument("--product", action="append", choices=PRODUCTS)
    parser.add_argument("--check", action="store_true", help="Check compiler and SDK without building")
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("This workflow requires a native arm64 macOS process")
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    swift = args.toolchain.resolve() / "usr/bin/swift"
    objcopy = swift.parent / "llvm-objcopy"
    env = os.environ.copy()
    for key in ("SDKROOT", "SWIFT_EXEC", "TOOLCHAINS", "PKG_CONFIG_PATH", "PKG_CONFIG_LIBDIR"):
        env.pop(key, None)
    env["PATH"] = str(swift.parent) + os.pathsep + env.get("PATH", "")
    version = subprocess.check_output([str(swift), "--version"], env=env, text=True)
    if "swift-6.4-RELEASE" not in version or "Target: arm64-apple-macosx" not in version:
        parser.error("Use the matching open-source arm64 Swift toolchain, not Xcode Swift")
    sdks = subprocess.check_output([str(swift), "sdk", "list"], env=env, text=True).splitlines()
    if SDK not in sdks or not objcopy.is_file():
        parser.error(f"Install matching {SDK} with scripts/prepare_v2_linux_sdk.py")
    sdk_metadata = verify_sdk(Path.home() / "Library/org.swift.swiftpm/swift-sdks" / (SDK + ".artifactbundle"))
    products = list(dict.fromkeys(args.product or PRODUCTS))
    base = [str(swift), "build", "--package-path", str(ROOT / "IMV2Server"),
            "--scratch-path", str(args.scratch_path.resolve()), "--swift-sdk", SDK,
            "--triple", TRIPLE, "--configuration", "release", "--jobs", str(args.jobs),
            "--disable-automatic-resolution"]
    if args.check:
        print(json.dumps({"compiler": version.strip(), "sdk": SDK, "triple": TRIPLE,
                          "products": products, "command": base}, indent=2))
        return
    args.scratch_path.mkdir(parents=True, exist_ok=True)
    # Prevent two release drivers from sharing and invalidating this cache.
    with (args.scratch_path / "native-release.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        started = datetime.datetime.now(datetime.timezone.utc)
        run = args.output.resolve() / "runs" / (started.strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:8])
        run.mkdir(parents=True)
        (run / "bin").mkdir()
        sources = source_manifest()
        write_json(run / "sources.json", sources)
        state = {"status": "building", "startedAt": started.isoformat(),
                 "compiler": version.strip(), "sdk": SDK, "triple": TRIPLE,
                 "sdkProvenance": sdk_metadata,
                 "jobs": args.jobs, "products": [], "sourceDrift": None}
        write_json(run / "manifest.json", state)
        print(f"Release evidence: {run}", flush=True)
        try:
            with (run / "resolve.log").open("w") as log:
                subprocess.run([str(swift), "package", "--package-path", str(ROOT / "IMV2Server"),
                    "--scratch-path", str(args.scratch_path.resolve()), "--force-resolved-versions", "resolve"],
                    env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
            metadata = json.loads(PATCH.read_text())
            apply_dependency_patch(args.scratch_path / "checkouts/swift-nio", metadata)
            state["dependencyPatch"] = metadata
            bin_path = None
            for product in products:
                begin = time.monotonic()
                print(f"Building {product}", flush=True)
                with (run / f"{product}.log").open("w") as log:
                    subprocess.run(base + ["--product", product], env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
                if bin_path is None:
                    bin_path = Path(subprocess.check_output(base + ["--show-bin-path"], env=env, text=True).strip())
                binary = bin_path / product
                elf = verify_linux_elf(binary)
                destination = run / "bin" / product
                subprocess.run([str(objcopy), "--strip-all", str(binary), str(destination)], check=True)
                verify_linux_elf(destination)
                verify_load_segments(binary, destination)
                destination.chmod(0o755)
                state["products"].append({"product": product, "seconds": round(time.monotonic() - begin, 3),
                    "binary": f"bin/{product}", "sha256": sha256(destination), "bytes": destination.stat().st_size,
                    "loadSegmentsVerified": True,
                    "unstrippedBinary": str(binary), "unstrippedSHA256": sha256(binary), **elf})
                write_json(run / "manifest.json", state)
            for bundle in sorted(bin_path.iterdir()):
                if bundle.is_dir() and bundle.suffix in (".resources", ".bundle"):
                    shutil.copytree(bundle, run / "bin" / bundle.name)
            after = source_manifest()
            state["sourceDrift"] = sorted(p for p in sources.keys() | after.keys() if sources.get(p) != after.get(p))
            if state["sourceDrift"]:
                raise RuntimeError("Source changed during release build; do not deploy this run")
            shutil.copy2(ROOT / "IMV2Server/Resources/imagemagick-policy.xml", run / "imagemagick-policy.xml")
            shutil.copy2(ROOT / "IMV2/Dockerfile.account.prebuilt", run / "Dockerfile")
            state["artifactFiles"] = {str(path.relative_to(run)): sha256(path)
                for path in sorted((run / "bin").rglob("*")) if path.is_file()}
            for name in ("imagemagick-policy.xml", "Dockerfile"):
                state["artifactFiles"][name] = sha256(run / name)
            state.update(status="verified-linux-release", linuxRuntimeVerified=False,
                         finishedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                         seconds=round((datetime.datetime.now(datetime.timezone.utc) - started).total_seconds(), 3))
            write_json(run / "manifest.json", state)
            if set(products) == set(PRODUCTS):
                write_json(args.output.resolve() / "current.json", {"run": str(run), "manifest": str(run / "manifest.json")})
            print(f"Verified Linux release (runtime check required): {run}", flush=True)
        except BaseException as error:
            state.update(status="failed", errorType=type(error).__name__, error=str(error))
            write_json(run / "manifest.json", state)
            raise


if __name__ == "__main__":
    main()
