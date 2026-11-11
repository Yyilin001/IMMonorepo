#!/usr/bin/env python3
"""Generate/check upload delegation JSON using the repository's actual Swift types.

Run on macOS with swiftc available. Compilation uses an isolated temporary module,
so a cached module built with a different Xcode version is never imported.
"""
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Compare without changing the checked-in fixture.")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("This fixture generator requires the repository's macOS Swift toolchain.")
    root = Path(__file__).resolve().parents[2]
    source = root / "IMV2Core/Sources/IMV2Core"
    fixture = root / "IMAndroid/clientkit/src/test/fixtures/resource-background.swift"
    expected = root / "IMAndroid/clientkit/src/test/resources/resource-background-swift.txt"
    names = ["Identifiers.swift", "ResourceIdentity.swift", "ResourceTransferPlan.swift",
             "ResourceBackgroundAuthorization.swift", "ResourceBackgroundDownloadAuthorization.swift",
             "ResourceUpload.swift", "ResourceDescriptor.swift", "MediaReference.swift", "ResourceVariant.swift"]
    with tempfile.TemporaryDirectory(prefix="imandroid-background-wire-") as directory:
        output = Path(directory)
        subprocess.run(["swiftc", "-emit-library", "-emit-module", "-module-name", "IMV2Core",
                        "-emit-module-path", str(output / "IMV2Core.swiftmodule"),
                        "-o", str(output / "libIMV2Core.dylib"), *[str(source / name) for name in names]], check=True)
        subprocess.run(["swiftc", "-I", str(output), "-L", str(output), "-lIMV2Core",
                        "-Xlinker", "-rpath", "-Xlinker", str(output), str(fixture),
                        "-o", str(output / "fixture")], check=True)
        generated = subprocess.check_output([str(output / "fixture")])
    if args.check:
        if not expected.exists() or expected.read_bytes() != generated:
            print("Upload delegation fixture differs from the actual Swift encoding.", file=sys.stderr)
            return 1
        print("Upload delegation fixture matches the actual Swift encoding.")
    else:
        expected.write_bytes(generated)
        print("Generated upload delegation fixture.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
