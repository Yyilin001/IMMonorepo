"""Read native quorum state through a dedicated disposable Compose caller."""
import hashlib
import json
import subprocess
import uuid


def inspect_placement(*, compose, root, environment):
    output = subprocess.check_output(compose + [
        'run', '--rm', '--no-deps', '--use-aliases', '-T', 'placement-inspector',
        '/workspace/IMV2Server/.build/release/IMV2PlacementControlApp', '--inspect'],
        cwd=root, env=environment, text=True, timeout=45)
    return decode_placement_inspection(output)


def decode_placement_inspection(output):
    """Validate CLI output from either Compose or an owned Docker caller."""
    shards = json.loads(output)
    if not isinstance(shards, list) or not shards:
        raise RuntimeError('native control inspection returned no shards')
    result = {}
    for shard in shards:
        name = shard['shardID']
        if name in result or not 1 <= len(shard['partitions']) <= 4096:
            raise RuntimeError('invalid native control inspection topology')
        result[name] = shard
    return result


def room_placement(shards, room_id, shard_id='rooms-primary'):
    shard = shards[shard_id]
    # Foundation UUID identifiers use uppercase canonical spelling. Swift's
    # placement hash uses the first eight SHA256 bytes, interpreted big-endian.
    canonical = str(uuid.UUID(room_id)).upper()
    index = int.from_bytes(hashlib.sha256(canonical.encode()).digest()[:8], 'big') % len(shard['partitions'])
    slot = shard['partitions'][index]
    if slot['partition'] != index:
        raise RuntimeError('native control partition ordering mismatch')
    owner = slot['owner']
    registration = next((entry for entry in shard['hosts'] if entry['identity'] == owner), None)
    if registration is None or (registration['retired'] and not slot['retired']):
        raise RuntimeError('native control owner has no matching registration')
    return dict(roomID=canonical, shardID=shard_id, clusterID=shard['clusterID'],
                revision=shard['revision'], partition=index, hostID=owner['hostID'],
                incarnationID=owner['incarnationID'], epoch=slot['epoch'],
                retired=slot['retired'], hostRetired=registration['retired'],
                transfer=slot.get('transfer'))


def require_live_owner(state, host_id):
    if (state['hostID'].lower() != host_id.lower() or state['retired'] or
            state['hostRetired'] or state['transfer'] is not None):
        raise RuntimeError('room partition has no active native Actor Host')


def same_owner(before, after):
    return all(before[key] == after[key] for key in
               ('clusterID', 'partition', 'hostID', 'incarnationID', 'epoch'))
