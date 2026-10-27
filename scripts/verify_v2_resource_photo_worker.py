#!/usr/bin/env python3
"""Black-box Linux preview regression, using generated pixels and runtime policy.

Run with --image <pinned runtime image>. No account, network or private photo is
used. Docker containers are temporary; fixtures and the JSON proof are retained.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import time
import zlib


def png(width, height):
    def chunk(kind, body):
        return (struct.pack('>I', len(body)) + kind + body
                + struct.pack('>I', zlib.crc32(kind + body) & 0xffffffff))
    compressor = zlib.compressobj()
    compressed = bytearray()
    for y in range(height):
        # Opaque RGBA is a common Photos export. Include actual transparency too.
        row = bytes([y % 256, 100, 180, 255]) * width
        if y == height // 2:
            row = b'\x00\x00\x00\x00' + row[4:]
        compressed.extend(compressor.compress(b'\0' + row))
    compressed.extend(compressor.flush())
    return (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', compressed) + chunk(b'IEND', b''))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', required=True)
    args = parser.parse_args()
    root = Path(tempfile.mkdtemp(prefix='im-resource-photo-worker-'))
    worker = '/workspace/IMV2Server/.build/release/IMV2ResourceImageWorker'
    cases = []
    for name, width, height, recipe, expected in [
        ('camera-rgba', 3072, 4096, 'preview', [(240, 320), (960, 1280)]),
        ('transparent-avatar', 300, 160, 'avatar', [(128, 128), (256, 256)]),
    ]:
        folder = root / name
        folder.mkdir()
        source = png(width, height)
        (folder / 'input.png').write_bytes(source)
        start = time.monotonic()
        command = ['docker', 'run', '--rm', '--network', 'none', '--memory',
                   '768m', '--cpus', '1', '--mount',
                   'type=bind,source=' + str(folder) + ',target=/fixture',
                   args.image, worker, '/fixture/input.png', '/fixture', recipe]
        result = subprocess.run(command, capture_output=True, timeout=35)
        (folder / 'stderr.log').write_bytes(result.stderr)
        assert result.returncode == 0, (name, result.returncode, str(folder))
        sizes = [320, 1280] if recipe == 'preview' else [128, 256]
        for size, dimensions in zip(sizes, expected):
            data = (folder / (str(size) + '.png')).read_bytes()
            assert data[:8] == b'\x89PNG\r\n\x1a\n'
            assert struct.unpack('>II', data[16:24]) == dimensions
            assert len(data) <= 8 * 1024 * 1024
        cases.append({'name': name, 'exitCode': 0, 'dimensions': expected,
                      'seconds': round(time.monotonic() - start, 3),
                      'sourceSHA256': hashlib.sha256(source).hexdigest()})
    proof = {'status': 'passed', 'image': args.image, 'cases': cases,
             'fixtures': str(root), 'network': 'none',
             'memoryBytes': 768 * 1024 * 1024, 'cpus': 1}
    (root / 'result.json').write_text(json.dumps(proof, indent=2) + '\n')
    print(json.dumps(proof))


if __name__ == '__main__':
    main()
