#!/usr/bin/env python3
"""Atomically refresh a private ECS role credential file without logging secrets."""
import argparse
import datetime
import json
import os
import pathlib
import re
import tempfile
import urllib.request


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--role-name', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', args.role_name):
        raise ValueError('Invalid role name')
    output = pathlib.Path(args.output)
    if not output.is_absolute():
        raise ValueError('Output must be absolute')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    base = 'http://100.100.100.200/latest/'
    token = opener.open(urllib.request.Request(base + 'api/token', method='PUT',
        headers={'X-aliyun-ecs-metadata-token-ttl-seconds': '300'}), timeout=5).read(4096).decode()
    with opener.open(urllib.request.Request(base + 'meta-data/ram/security-credentials/' + args.role_name,
        headers={'X-aliyun-ecs-metadata-token': token}), timeout=5) as response:
        data = response.read(16_385)
    if len(data) > 16_384:
        raise ValueError('Credential response too large')
    value = json.loads(data)
    fields = ['AccessKeyId', 'AccessKeySecret', 'SecurityToken', 'Expiration']
    if value.get('Code') != 'Success' or any(not isinstance(value.get(k), str) or not value[k] for k in fields):
        raise ValueError('Credential unavailable')
    expires = datetime.datetime.fromisoformat(value['Expiration'].replace('Z', '+00:00'))
    if expires <= datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=10):
        raise ValueError('Credential too close to expiration')
    fd, temporary = tempfile.mkstemp(dir=output.parent, prefix='.credentials-')
    try:
        with os.fdopen(fd, 'w') as stream:
            os.fchmod(stream.fileno(), 0o600)
            json.dump({k: value[k] for k in fields}, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, output)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print('OSS role credentials refreshed; expires=' + value['Expiration'])


if __name__ == '__main__':
    try:
        main()
    except Exception:
        raise SystemExit('OSS role credential refresh failed; prior credential file retained')
