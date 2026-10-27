#!/usr/bin/env python3
"""Verify a completed, explicitly selected simulator export and its exact bytes.

Run after IMAppMediaFileUsageUITests/testProductionShareSavesNamedAudioCopyToFiles.
The UI test exports one UUID-named synthetic WAV. Never inspect other files or
remove anything unless its basename, location and full payload all match.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator', required=True, type=uuid.UUID)
    parser.add_argument('--test-log', required=True, type=Path)
    parser.add_argument('--evidence', required=True, type=Path)
    parser.add_argument('--cleanup', action='store_true')
    args = parser.parse_args()
    text = args.test_log.read_text()
    method = 'testProductionShareSavesNamedAudioCopyToFiles'
    if '** TEST SUCCEEDED **' not in text or not re.search(r"Test Case .*" + method + r".* passed \(", text):
        raise RuntimeError('the selected UI export test has not passed')
    names = re.findall(r'^System Files export completed: (资源导出-[0-9A-Fa-f-]{36}\.wav)$', text, re.M)
    if len(names) != 1:
        raise RuntimeError('expected exactly one scoped export completion')
    name = names[0]
    uuid.UUID(name.removeprefix('资源导出-').removesuffix('.wav'))
    groups = subprocess.check_output(['xcrun', 'simctl', 'get_app_container', str(args.simulator),
                                     'com.apple.DocumentsApp', 'groups'], text=True)
    roots = [Path(line.split('\t', 1)[1]) for line in groups.splitlines()
             if line.startswith('group.com.apple.FileProvider.LocalStorage\t')]
    if len(roots) != 1:
        raise RuntimeError('the selected simulator has no unambiguous local file provider')
    base = roots[0] / 'File Provider Storage'
    target = base / name
    for component in [roots[0], base, target]:
        if component.is_symlink():
            raise RuntimeError('refusing a symbolic link in the export location')
    if not base.is_dir() or not target.is_file():
        raise RuntimeError('the local system export is missing')
    # Keep this byte contract paired with FileUsageUIBytes.wave in the App.
    expected = (b'RIFF' + struct.pack('<I', 32036) + b'WAVEfmt ' +
                struct.pack('<IHHIIHH', 16, 1, 1, 16000, 32000, 2, 16) +
                b'data' + struct.pack('<I', 32000) + bytes(32000))
    if target.stat().st_size != len(expected):
        raise RuntimeError('unexpected export length; no file was removed')
    payload = target.read_bytes()
    if payload != expected:
        raise RuntimeError('unexpected export contents; no file was removed')
    evidence = {'simulator': str(args.simulator), 'fileName': name, 'byteCount': len(payload),
                'sha256': hashlib.sha256(payload).hexdigest(), 'matchesActualFixture': True,
                'removedOwnedExport': False}
    # Reserve the evidence destination before allowing cleanup. Never overwrite
    # an existing result or delete bytes if evidence cannot be preserved.
    with args.evidence.open('x') as destination:
        json.dump(evidence, destination, ensure_ascii=False, indent=2)
        destination.flush()
        if args.cleanup:
            target.unlink()
            evidence['removedOwnedExport'] = not target.exists()
            destination.seek(0)
            json.dump(evidence, destination, ensure_ascii=False, indent=2)
            destination.truncate()
    print(json.dumps(evidence, ensure_ascii=False))


if __name__ == '__main__':
    main()
