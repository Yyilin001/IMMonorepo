#!/usr/bin/env python3
"""Verify release integrity, Linux loaders and the actual image worker in isolation."""

import argparse
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import uuid
import zlib

from build_v2_linux_release import PRODUCTS, sha256, write_json


def png_fixture():
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 640, 480, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress((b"\0" + b"\x25\x78\xb4" * 640) * 480)) + chunk(b"IEND", b""))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("release", type=Path)
    parser.add_argument("--docker-context")
    parser.add_argument("--runtime-image", required=True, help="Packaged image containing this release and its runtime dependencies")
    args = parser.parse_args()
    release = args.release.resolve()
    manifest = json.loads((release / "manifest.json").read_text())
    if manifest["status"] != "verified-linux-release" or manifest["sourceDrift"] != []:
        parser.error("Release build is incomplete or its sources changed")
    if {p["product"] for p in manifest["products"]} != set(PRODUCTS):
        parser.error("Runtime acceptance requires all seven products")
    for relative, digest in manifest["artifactFiles"].items():
        path = (release / relative).resolve()
        if release not in path.parents or sha256(path) != digest:
            parser.error(f"Release artifact changed: {relative}")
    docker = ["docker"] + (["--context", args.docker_context] if args.docker_context else [])

    def run(arguments, **kwargs):
        return subprocess.check_output(docker + arguments, text=True, timeout=120, **kwargs).strip()

    image = json.loads(run(["image", "inspect", args.runtime_image]))[0]
    if image["Architecture"] != "amd64" or image["Os"] != "linux":
        parser.error("Verification requires a Linux amd64 image")
    container = "im-native-release-verify-" + uuid.uuid4().hex[:12]
    state = {"status": "running", "runtimeImageID": image["Id"],
             "manifestSHA256": sha256(release / "manifest.json"), "products": []}
    created = False
    try:
        run(["create", "--name", container, "--network", "none", "--memory", "512m", "--cpus", "2",
             "--entrypoint", "/bin/sleep", image["Id"], "600"])
        created = True
        run(["start", container])
        binary_root = "/workspace/IMV2Server/.build/release/"
        expected_files = {binary_root + name[len("bin/"):]: digest
            for name, digest in manifest["artifactFiles"].items() if name.startswith("bin/")}
        expected_files["/etc/ImageMagick-6/policy.xml"] = manifest["artifactFiles"]["imagemagick-policy.xml"]
        shipped = run(["exec", container, "sha256sum", *expected_files])
        actual_files = {line.split(maxsplit=1)[1].lstrip(" *"): line.split(maxsplit=1)[0]
            for line in shipped.splitlines()}
        if expected_files != actual_files:
            raise ValueError("Packaged executables, resources or ImageMagick policy differ from the release")
        for relative, digest in manifest["sdkProvenance"]["runtimeLibrarySHA256"].items():
            actual = run(["exec", container, "sha256sum", "/" + relative]).split()[0]
            if actual != digest:
                raise ValueError(f"Linux runtime differs from SDK: {relative}")
        for product in manifest["products"]:
            binary = binary_root + product["product"]
            actual = actual_files[binary]
            dependencies = run(["exec", container, "ldd", binary])
            if actual != product["sha256"] or "not found" in dependencies:
                raise ValueError(f"Linux binary or loader check failed: {product['product']}")
            state["products"].append({"product": product["product"], "sha256": actual, "librariesResolved": True})
        worker = binary_root + "IMV2ResourceImageWorker"
        run(["exec", container, worker, "--check"])
        with tempfile.TemporaryDirectory(prefix="im-native-worker-") as folder:
            folder = Path(folder)
            (folder / "input.png").write_bytes(png_fixture())
            run(["cp", str(folder / "input.png"), container + ":/tmp/input.png"])
            run(["exec", container, "mkdir", "/tmp/preview"])
            run(["exec", container, worker, "/tmp/input.png", "/tmp/preview", "preview"])
            run(["cp", container + ":/tmp/preview", str(folder / "result")])
            dimensions = json.loads((folder / "result/source-dimensions.json").read_text())
            if dimensions != {"width": 640, "height": 480}:
                raise ValueError("Worker reported incorrect source dimensions")
            previews = {}
            for size, expected in ((320, (320, 240)), (1280, (640, 480))):
                data = (folder / "result" / f"{size}.png").read_bytes()
                actual = struct.unpack(">II", data[16:24])
                if data[:8] != b"\x89PNG\r\n\x1a\n" or actual != expected:
                    raise ValueError("Worker produced incorrect preview dimensions")
                previews[str(size)] = {"width": actual[0], "height": actual[1], "bytes": len(data)}
            state["worker"] = {"sourceDimensions": dimensions, "previews": previews}
        state.update(status="passed-linux-loader-and-worker", network="none", serviceEndToEndTest=False)
    except BaseException as error:
        state.update(status="failed", error=str(error))
        raise
    finally:
        write_json(release / "runtime-verification.json", state)
        if created:
            subprocess.run(docker + ["rm", "--force", container], stdout=subprocess.DEVNULL, check=True)
    print(json.dumps(state, indent=2))


if __name__ == "__main__":
    main()
