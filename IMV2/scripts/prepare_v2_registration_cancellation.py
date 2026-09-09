#!/usr/bin/env python3
"""Persist purpose-limited authority before a shell caller issues credentials."""
import argparse
import json
import os
from pathlib import Path
import secrets
import time
import uuid


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('device_id', type=uuid.UUID)
    parser.add_argument('operation_id', type=uuid.UUID)
    parser.add_argument('recovery_directory', type=Path)
    args = parser.parse_args()
    request = dict(deviceID={'rawValue': str(args.device_id).upper()}, operationID=str(args.operation_id).upper(),
        proof='imv2-cancel-registration-v1.' + secrets.token_urlsafe(32),
        issueBeforeMilliseconds=time.time_ns() // 1000000 + 600000)
    encoded = json.dumps(request, separators=(',', ':')) + '\n'
    directory = args.recovery_directory
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory.chmod(0o700)
    # Do not overwrite authority for an operation already sent to the server.
    path = directory / (request['operationID'] + '.json')
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w') as output:
        output.write(encoded)
        output.flush()
        os.fsync(output.fileno())
    # Persist the newly created directory entry as well as the request file.
    for target in [directory, directory.parent]:
        descriptor = os.open(target, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    print(encoded, end='')


if __name__ == '__main__':
    main()
