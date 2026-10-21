"""Author immutable membership requests for live benchmark orchestration.

Configuration endpoints describe candidates, not committed membership. Callers
must supply the last committed record and the freshly inspected control revision.
Execution, convergence, and business correctness are separate runtime gates.
"""
import copy
import json
import os
from pathlib import Path
import uuid


def membership_record(configuration, current, revision, next_members=None):
    current = sorted(current)
    target = None if next_members is None else sorted(next_members)
    if (not current or len(current) != len(set(current)) or
            (target is not None and (not target or len(target) != len(set(target)))) or
            type(revision) is not int or not 0 < revision < 2**64):
        raise ValueError('invalid membership')
    members = set(current) | set(target or [])
    if len(members) > 64:
        raise ValueError('membership exceeds 64 hosts')
    peers = [p for p in configuration['realtimePeers'] if p['nodeID'] in members]
    if len(peers) != len(members) or {p['nodeID'] for p in peers} != members:
        raise ValueError('missing or duplicate realtime endpoint')
    services = {p['serviceID'] for p in peers}
    rooms = [copy.deepcopy(p) for p in configuration['peers'] if p['serviceID'] in services]
    for room in rooms:
        room['accessibleShardIDs'] = sorted(room.pop('shardIDs'))
        try:
            room['hostID'] = str(uuid.UUID(room['hostID'])).upper()
        except ValueError:
            pass
    if len(rooms) != len(members) or {p['serviceID'] for p in rooms} != services:
        raise ValueError('benchmark requires a room endpoint for every gateway')
    for room in rooms:
        if not any((p['serviceID'], p['address'], p['port']) ==
                   (room['serviceID'], room['address'], room['port']) for p in peers):
            raise ValueError('room and realtime endpoints disagree')
    for room in rooms:
        room['hostID'] = {'rawValue': room['hostID']}
        room['serviceID'] = {'rawValue': room['serviceID']}
    result = dict(revision=revision, current=current,
                  peers=sorted(peers, key=lambda p: p['nodeID']),
                  roomPeers=sorted(rooms, key=lambda p: p['hostID']['rawValue']))
    if target is not None:
        result['next'] = target
    return copy.deepcopy(result)


def membership_command(configuration, origin_revision, previous=None, target=None):
    if type(origin_revision) is not int or not 0 < origin_revision < 2**64:
        raise ValueError('a positive inspected control revision is required')
    if previous is None:
        if target is None:
            raise ValueError('initial members are required')
        record = membership_record(configuration, target, 1)
    elif previous.get('next') is not None:
        if target is not None and sorted(target) != previous['next']:
            raise ValueError('final membership must match committed joint target')
        record = membership_record(configuration, previous['next'], previous['revision'] + 1)
    else:
        if target is None or sorted(target) == previous['current']:
            raise ValueError('a changed membership target is required')
        record = membership_record(configuration, previous['current'], previous['revision'] + 1, target)
    if previous:
        retained_services = {p['serviceID'] for p in record['peers']}
        if any(p['serviceID']['rawValue'] in retained_services and p not in record['roomPeers']
               for p in previous['roomPeers']):
            raise ValueError('retained room authorization changed or disappeared')
        for field, key in [('peers', 'nodeID'), ('roomPeers', 'hostID')]:
            old = {(p[key]['rawValue'] if isinstance(p[key], dict) else p[key]): p for p in previous[field]}
            new = {(p[key]['rawValue'] if isinstance(p[key], dict) else p[key]): p for p in record[field]}
            if any(new[k] != old[k] for k in old.keys() & new.keys()):
                raise ValueError('retained endpoint authorization changed')
            if previous.get('next') is not None and any(k not in old for k in new):
                raise ValueError('finalization cannot introduce endpoints')
    return dict(deploymentID=configuration['placementControl']['clusterID'],
                shardID=configuration['serviceMembershipShard'], requestID=str(uuid.uuid4()),
                originRevision=origin_revision, membership=record)


def save_command(path, command):
    """Create once. Retry by reading this file; never replace an unknown result."""
    path = Path(path)
    payload = (json.dumps(command, sort_keys=True, indent=2) + '\n').encode()
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(payload)
        stream.flush()
        os.fsync(stream.fileno())
    parent = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(parent)
    finally:
        os.close(parent)
    return path


def main():
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configuration', type=Path, required=True)
    parser.add_argument('--origin-revision', type=int, required=True)
    parser.add_argument('--previous-receipt', type=Path)
    parser.add_argument('--target', action='append', help='Gateway node ID; repeat for the full target roster')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    configuration = json.loads(args.configuration.read_text())
    previous = None
    if args.previous_receipt:
        receipt = json.loads(args.previous_receipt.read_text())
        previous = receipt['membership']
        if previous is None or args.origin_revision < receipt['controlRevision']:
            parser.error('previous receipt requires committed membership and a non-stale control revision')
    command = membership_command(configuration, args.origin_revision, previous, args.target)
    save_command(args.output, command)
    print(json.dumps(dict(requestID=command['requestID'], output=str(args.output),
                          membershipRevision=command['membership']['revision'])))


if __name__ == '__main__':
    main()
