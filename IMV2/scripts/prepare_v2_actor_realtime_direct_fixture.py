#!/usr/bin/env python3
"""Freeze a private direct-ring fixture for both revisions; never connects to a DB."""
import argparse
import base64
import hashlib
import hmac
import json
import os
import secrets
import uuid
from datetime import datetime, timezone
from pathlib import Path
from prepare_v2_virtual_actor_capacity_fixture import guard, private_write, quoted, sql_insert, stable_uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', required=True, type=Path)
    parser.add_argument('--seed', required=True, type=uuid.UUID)
    parser.add_argument('--users', type=int, default=50000)
    parser.add_argument('--foreground-paired', action='store_true',
                        help='adjacent even/odd users share their first foreground target; requires an even population')
    args = parser.parse_args()
    if not 3 <= args.users <= 50000:
        parser.error('users must be 3..50000')
    if args.foreground_paired and args.users % 2:
        parser.error('foreground-paired requires an even user count')
    os.umask(0o077)
    args.output_dir.mkdir(mode=0o700)
    seed = args.seed
    fixture = stable_uuid(seed, 'direct-ring-fixture')
    users = [stable_uuid(seed, f'user/{i}') for i in range(args.users)]
    devices = [stable_uuid(seed, f'device/{i}') for i in range(args.users)]
    rooms = [stable_uuid(seed, f'direct-ring/{i}') for i in range(args.users)]
    key = secrets.token_bytes(32)
    tokens = ['va1_' + secrets.token_urlsafe(32) for _ in users]
    expiry = '2030-01-01T00:00:00+00:00'
    if datetime.fromisoformat(expiry) <= datetime.now(timezone.utc):
        raise ValueError('fixture expiry needs renewal')
    expiry_ms = int(datetime.fromisoformat(expiry).timestamp() * 1000)
    shard, bucket, profile = 'va-capacity-owner-00', 'va-capacity-users', 'va-capacity'
    limit = 10000000
    lease = stable_uuid(seed, 'direct-ring-admission-lease')
    header = guard(fixture)
    hashes = {}
    def write(name, content):
        hashes[name] = private_write(args.output_dir / name, content)
    write('access-token-hmac-key.base64', base64.b64encode(key).decode() + '\n')
    common = sql_insert('public_user_profiles', 'user_id, public_handle, display_name, revision, created_at, updated_at', [
        f"({quoted(u)}, 'va_capacity_{i}', 'VA Capacity {i}', 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)" for i, u in enumerate(users)])
    common += sql_insert('user_direct_send_policy_versions', 'user_id,revision,updated_at', [f"({quoted(u)},1,CURRENT_TIMESTAMP)" for u in users])
    common += f"INSERT INTO im_v2.user_shard_router_configuration (configuration_key,router_epoch,default_write_bucket,updated_at) VALUES (TRUE,1,{quoted(bucket)},CURRENT_TIMESTAMP);\n"
    write('common.sql', header + common + 'COMMIT;\n')
    auth = sql_insert('auth_devices', 'user_id,device_id,created_at,session_expires_at,last_active_at,display_name,platform', [
        f"({quoted(u)},{quoted(d)},CURRENT_TIMESTAMP,{quoted(expiry)}::timestamptz,CURRENT_TIMESTAMP,'Capacity device','Load generator')" for u, d in zip(users, devices)])
    auth += sql_insert('device_access_tokens', 'token_hmac,user_id,device_id,issued_at,expires_at', [
        f"({quoted(hmac.new(key,t.encode(),hashlib.sha256).hexdigest())},{quoted(u)},{quoted(d)},CURRENT_TIMESTAMP,{quoted(expiry)}::timestamptz)" for u,d,t in zip(users,devices,tokens)])
    write('auth-control.sql', header + auth + 'COMMIT;\n')
    route_rows, pair_routes, pairs, memberships = [], [], [], []
    for i, room in enumerate(rooms):
        low, high = sorted((users[i], users[(i+1)%args.users]))
        route_rows.append(f"({quoted(room)},{quoted(shard)},0,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)")
        pair_routes.append(f"({quoted(low)},{quoted(high)},{quoted(room)},{quoted(shard)},0,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)")
        # Mutual send permission avoids stranger-message policy becoming the workload.
        pairs.append(f"({quoted(low)},{quoted(high)},{quoted(room)},CURRENT_TIMESTAMP,TRUE,TRUE,TRUE,TRUE,TRUE,TRUE)")
        memberships.extend(f"({quoted(room)},{quoted(u)},'member',1)" for u in (low,high))
    control = sql_insert('room_owner_routes','room_id,room_shard_id,route_epoch,created_at,updated_at',route_rows)
    control += sql_insert('direct_room_owner_routes','lower_user_id,higher_user_id,room_id,room_shard_id,route_epoch,created_at,updated_at',pair_routes)
    write('control.sql',header + control + 'COMMIT;\n')
    owner = f"INSERT INTO im_v2.shard_admission_pools (room_shard_id,capacity_profile_id,lease_id,generation,valid_until,command_window_limit) VALUES ({quoted(shard)},{quoted(profile)},{quoted(lease)},1,{quoted(expiry)}::timestamptz,{limit});\n"
    owner += sql_insert('rooms','room_id,room_kind,room_shard_id,room_sequence,membership_revision,capacity_profile_id,capacity_class',[
        f"({quoted(r)},'direct',{quoted(shard)},0,1,{quoted(profile)},'standard')" for r in rooms])
    owner += sql_insert('room_admission','room_id,eligible_member_count,command_window_limit,shard_lease_id,shard_lease_generation',[
        f"({quoted(r)},2,{limit},{quoted(lease)},1)" for r in rooms])
    owner += sql_insert('direct_room_pairs','lower_user_id,higher_user_id,room_id,created_at,lower_profile_visible_to_higher,higher_profile_visible_to_lower,lower_can_send,higher_can_send,lower_has_replied,higher_has_replied',pairs)
    owner += sql_insert('room_memberships','room_id,user_id,role,joined_revision',memberships)
    write('owner.sql',header + owner + 'COMMIT;\n')
    credentials = []
    for i, (u, d, t) in enumerate(zip(users, devices, tokens)):
        targets = [rooms[i], rooms[(i-1)%args.users]]
        if args.foreground_paired and i % 2:
            targets.reverse()
        credentials.append(dict(userID=u,deviceID=d,accessToken=t,
                                accessTokenExpiresAtMilliseconds=expiry_ms,targetRoomIDs=targets))
    write('credentials.jsonl',''.join(json.dumps(c,separators=(',',':'))+'\n' for c in credentials))
    private_write(args.output_dir/'manifest.json',json.dumps(dict(schemaVersion=1,fixtureID=fixture,uuidSeed=str(seed),users=args.users,rooms=args.users,memberships=args.users*2,topology='direct-ring',foregroundTopology='paired-adjacent' if args.foreground_paired else 'forward-ring',activeForegroundRooms=args.users//2 if args.foreground_paired else args.users,foregroundSubscribersPerRoom=2 if args.foreground_paired else 1,targetsPerConnection=2,shardID=shard,userBucket=bucket,capacityProfileID=profile,commandWindowLimit=limit,expiresAt=expiry,filesSHA256=hashes),indent=2)+'\n')
    print(f'DIRECT_RING_FIXTURE_READY users={args.users} rooms={args.users} output={args.output_dir}')

if __name__ == '__main__':
    main()
