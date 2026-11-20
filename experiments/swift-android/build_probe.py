#!/usr/bin/env python3
"""Build the isolated arm64 Android probe. Does not select a global toolchain."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BUILD = HERE / "build"
VERSION = (ROOT / ".swift-version").read_text().strip()
SDK_ID = f"swift-{VERSION}-RELEASE_android"
SDK_RELATIVE_PATH = Path(SDK_ID + ".artifactbundle") / "swift-android"
SDK_INSTALL_DIRS = (
    Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "swiftpm/swift-sdks",
    Path.home() / "Library/org.swift.swiftpm/swift-sdks",
    Path.home() / ".swiftpm/swift-sdks",
)
ANDROID = Path(os.environ.get("ANDROID_HOME", Path.home() / "Library/Android/sdk"))
NDK = Path(os.environ.get("ANDROID_NDK_HOME", ANDROID / "ndk/30.0.16248370"))
TRIPLE = "aarch64-unknown-linux-android31"
SQLITE_SHA = "6e2a845a493026bdbad0618b2b5a0cf48584faab47384480ed9f592d912f23ec"


def run(args, **kwargs):
    print("+", " ".join(map(str, args)), flush=True)
    return subprocess.run(list(map(str, args)), check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reuse-capabilities", action="store_true", help="Reuse compiler API checks for the unchanged installed toolchain; still build search and the full probe")
    parser.add_argument("--shared-sdk", action="store_true", help="Build the production Kotlin-facing SDK instead of the probe")
    args = parser.parse_args()
    shared_sdk = args.shared_sdk
    BUILD.mkdir(exist_ok=True)
    sdk_install_dir = next((directory for directory in SDK_INSTALL_DIRS
                            if (directory / SDK_RELATIVE_PATH / "scripts/setup-android-sdk.sh").is_file()), None)
    if sdk_install_dir is None:
        searched = ", ".join(map(str, SDK_INSTALL_DIRS))
        raise SystemExit(f"Install {SDK_ID} first; it was not found in {searched}. See README.md.")
    if not NDK.is_dir():
        raise SystemExit(f"Install NDK 30.0.16248370 first; it was not found at {NDK}. See README.md.")
    sdk = sdk_install_dir / SDK_RELATIVE_PATH
    # SwiftBuild 6.4.2 on Linux fails to link this AArch64 Android product.
    build_system = ["--build-system", "native"] if sys.platform == "linux" else []
    run([sdk / "scripts/setup-android-sdk.sh"], env={**os.environ, "ANDROID_NDK_HOME": str(NDK)})
    prebuilt = next((NDK / "toolchains/llvm/prebuilt").iterdir())
    clang = prebuilt / "bin/aarch64-linux-android31-clang"
    archive = BUILD / "sqlite-amalgamation-3510200.zip"
    if not archive.exists():
        run(["curl", "-fL", "--retry", "2", "--connect-timeout", "20", "https://www.sqlite.org/2026/sqlite-amalgamation-3510200.zip", "-o", archive])
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SQLITE_SHA:
        raise SystemExit("SQLite archive checksum mismatch")
    with zipfile.ZipFile(archive) as zipped:
        zipped.extractall(BUILD)
    sqlite = BUILD / "sqlite-amalgamation-3510200"
    run([clang, "-O2", "-fPIC", "-DSQLITE_ENABLE_FTS5", "-DSQLITE_ENABLE_SNAPSHOT", "-DSQLITE_THREADSAFE=1",
         "-c", sqlite / "sqlite3.c", "-o", BUILD / "sqlite3.o"])
    run([prebuilt / "bin/llvm-ar", "rcs", BUILD / "libsqlite3.a", BUILD / "sqlite3.o"])
    generated = ROOT / "IMV2ClientKit/Sources/IMV2ClientKit/Generated/Protobuf/im_realtime/v2/im_v2.pb.swift"
    (BUILD / "Protocol").mkdir(exist_ok=True)
    shutil.copy2(generated, BUILD / "Protocol/im_v2.pb.swift")
    # Compile capability checks independently: expected failures must not prevent
    # testing the portable delegate fallback or be mistaken for successful APIs.
    capabilities = json.loads((BUILD / "capabilities.json").read_text()) if args.reuse_capabilities else {}
    snippets = {
        "foundation_baseline": "import Foundation\nimport FoundationNetworking\nfunc probe(_ r: URLRequest) { _ = URLSession.shared.dataTask(with: r) }\n",
        "urlsession_bytes": "import Foundation\nimport FoundationNetworking\nfunc probe(_ s: URLSession, _ r: URLRequest) async throws { _ = try await s.bytes(for: r) }\n",
        "waits_for_connectivity": "import Foundation\nimport FoundationNetworking\nfunc probe(_ c: URLSessionConfiguration) { c.waitsForConnectivity = true }\n",
        "background_urlsession": "import Foundation\nimport FoundationNetworking\nfunc probe() { _ = URLSessionConfiguration.background(withIdentifier: \"probe\") }\n",
    }
    for name, source in ({} if args.reuse_capabilities else snippets).items():
        file = BUILD / (name + ".swift")
        file.write_text(source)
        command = ["swiftly", "run", "swiftc", "-typecheck", "-target", TRIPLE, "-sdk", str(sdk / "ndk-sysroot"),
                   "-resource-dir", str(sdk / "swift-resources/usr/lib/swift-aarch64"), str(file), "+" + VERSION]
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (BUILD / (name + ".log")).write_text(result.stdout)
        capabilities[name] = {"compiles": result.returncode == 0, "exitCode": result.returncode}
    if not capabilities["foundation_baseline"]["compiles"]:
        raise SystemExit("Foundation baseline failed; API probe failures would not be meaningful")
    search = subprocess.run(["swiftly", "run", "swift", "build", *build_system, "--package-path", str(ROOT / "MessageSubstringSearch"),
                             "--scratch-path", str(BUILD / "search-check"), "--swift-sdks-path", str(sdk_install_dir),
                             "--swift-sdk", SDK_ID, "--triple", TRIPLE,
                             "--jobs", "4", "-Xcc", "-I" + str(sqlite), "+" + VERSION],
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (BUILD / "search-current.log").write_text(search.stdout)
    capabilities["current_search_package"] = {"compiles": search.returncode == 0, "exitCode": search.returncode}
    (BUILD / "capabilities.json").write_text(json.dumps(capabilities, indent=2) + "\n")
    args = ["swiftly", "run", "swift", "build", *build_system, "--package-path", ROOT / "IMV2ClientKit" if shared_sdk else HERE,
            "--swift-sdks-path", sdk_install_dir, "--swift-sdk", SDK_ID,
            "--triple", TRIPLE, "--skip-update", "-c", "release", "--jobs", "4", "--product", "IMV2SharedSDK" if shared_sdk else "IMSwiftProbe",
            "-Xcc", "-I" + str(sqlite), "-Xlinker", "-L" + str(BUILD),
            "-Xlinker", "--exclude-libs=libsqlite3.a", "+" + VERSION]
    if shared_sdk:
        args[-1:-1] = ["--scratch-path", str(BUILD / "shared-sdk")]
    run(args)
    binary_dir = Path(subprocess.check_output(list(map(str, args[:-1] + ["--show-bin-path", "+" + VERSION])), text=True).strip())
    output = ROOT / ("IMAndroid/sharedsdk/build/native/arm64-v8a" if shared_sdk else "IMAndroid/swiftprobe/build/native/arm64-v8a")
    output.mkdir(parents=True, exist_ok=True)
    # Remove only this probe's generated libraries so stale runtimes cannot mask missing dependencies.
    for file in output.glob("*.so"):
        file.unlink()
    candidates = {p.name: p for p in (sdk / "swift-resources/usr/lib/swift-aarch64/android").rglob("*.so")}
    candidates["libc++_shared.so"] = prebuilt / "sysroot/usr/lib/aarch64-linux-android/libc++_shared.so"
    candidates.update({p.name: p for p in binary_dir.glob("*.so")})
    pending = [binary_dir / ("libIMV2SharedSDK.so" if shared_sdk else "libIMSwiftProbe.so")]
    system = {"libc.so", "libm.so", "libdl.so", "liblog.so", "libandroid.so", "libz.so"}
    copied = set()
    import re
    while pending:
        file = pending.pop()
        if file.name in copied:
            continue
        shutil.copy2(file, output / file.name)
        copied.add(file.name)
        dynamic = subprocess.check_output([prebuilt / "bin/llvm-readelf", "-d", file], text=True)
        for name in re.findall(r"\(NEEDED\).*?\[(.*?)\]", dynamic):
            if name not in copied and name not in system:
                if name not in candidates:
                    raise SystemExit(f"Unresolved packaged dependency: {name}")
                pending.append(candidates[name])
    manifest = {"swift": VERSION, "swiftSDK": SDK_ID, "triple": TRIPLE, "ndk": NDK.name,
                "sqlite": "3.51.2", "sqliteArchiveSHA256": SQLITE_SHA,
                "protocolSHA256": hashlib.sha256(generated.read_bytes()).hexdigest(),
                "capabilities": capabilities,
                "libraries": {p.name: {"bytes": p.stat().st_size, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(output.glob("*.so"))}}
    (BUILD / ("shared-sdk-manifest.json" if shared_sdk else "native-manifest.json")).write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
