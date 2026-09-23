#!/usr/bin/env python3
"""Generate disposable, reproducible Gateway-load room fixtures without touching a DB."""

from __future__ import annotations

import argparse
import base64
from datetime import datetime, timezone
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import sys
import uuid


LAYOUTS = ("hot", "same-owner", "mixed", "cold")
IDENTIFIER = re.compile(r"[a-z][a-z0-9_-]{0,63}\Z")
SQL_BATCH = 500


def fail(message: str) -> None:
    raise ValueError(message)


def checked_identifier(value: str, name: str) -> str:
    if not IDENTIFIER.fullmatch(value):
        fail(f"{name} must match {IDENTIFIER.pattern}")
    return value


def quoted(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def stable_uuid(namespace: uuid.UUID, label: str) -> str:
    return str(uuid.uuid5(namespace, label))


def digest_json(value: object) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def private_write(path: Path, body: str) -> str:
    with path.open("x", encoding="utf-8") as stream:
        os.fchmod(stream.fileno(), 0o600)
        stream.write(body)
    return hashlib.sha256(body.encode()).hexdigest()


def sql_insert(table: str, columns: str, rows: list[str], *, suffix: str = "") -> str:
    return "".join(
        f"INSERT INTO im_v2.{table} ({columns}) VALUES\n  "
        + ",\n  ".join(rows[start : start + SQL_BATCH])
        + suffix
        + ";\n"
        for start in range(0, len(rows), SQL_BATCH)
    )


def guard(fixture_id: str) -> str:
    # The script deliberately has no database connection option. The SQL also
    # refuses an unmarked database, including a production DB reached by a
    # mistaken psql URL or Compose project.
    return f"""\\set ON_ERROR_STOP on
BEGIN;
DO $va_fixture_guard$
DECLARE marked boolean;
BEGIN
  IF current_database() !~ '^imv2_va_[a-z0-9_]+$'
     OR to_regclass('public.imv2_disposable_fixture_guard') IS NULL THEN
    RAISE EXCEPTION 'VA capacity fixture requires a marked disposable imv2_va_ database';
  END IF;
  EXECUTE 'SELECT EXISTS (SELECT 1 FROM public.imv2_disposable_fixture_guard WHERE fixture_id = $1)'
    INTO marked USING {quoted(fixture_id)}::uuid;
  IF NOT marked THEN
    RAISE EXCEPTION 'VA capacity fixture marker does not match this seed';
  END IF;
END
$va_fixture_guard$;
"""


def sql_end() -> str:
    return "COMMIT;\n"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--seed", type=uuid.UUID, required=True, help="frozen UUID namespace")
    parser.add_argument("--users", type=int, required=True, help="1..10000 load connections")
    parser.add_argument("--targets", type=int, required=True, help="1..32 targetRoomIDs per connection")
    parser.add_argument("--owners", type=int, required=True, help="1..8 physical owner databases")
    parser.add_argument("--expires-at", required=True, help="fixed future UTC timestamp, e.g. 2030-01-01T00:00:00Z")
    parser.add_argument("--capacity-profile", default="va-capacity")
    parser.add_argument("--shard-prefix", default="va-capacity-owner")
    parser.add_argument("--user-bucket", default="va-capacity-users")
    parser.add_argument("--command-window-limit", type=int, required=True,
                        help="must match IM_V2_MAX_COMMANDS_PER_WINDOW")
    parser.add_argument("--members-per-room", type=int, default=32, help="same-owner/mixed group size")
    parser.add_argument("--cold-members-per-room", type=int, default=4)
    parser.add_argument("--layouts", nargs="+", choices=LAYOUTS, default=list(LAYOUTS))
    args = parser.parse_args()
    if not 2 <= args.users <= 10_000 or not 1 <= args.targets <= 32 or not 1 <= args.owners <= 8:
        fail("users must be 2..10000, targets 1..32, owners 1..8")
    if args.command_window_limit < 1 or args.command_window_limit > 2_000_000_000:
        fail("command-window-limit must be 1..2000000000")
    if not 1 <= args.members_per_room <= 100_000 or not 1 <= args.cold_members_per_room <= 100_000:
        fail("member counts must be 1..100000")
    for key in ("capacity_profile", "shard_prefix", "user_bucket"):
        checked_identifier(getattr(args, key), key)
    if len(set(args.layouts)) != len(args.layouts):
        fail("duplicate layout")
    try:
        expiry = datetime.fromisoformat(args.expires_at.replace("Z", "+00:00"))
    except ValueError:
        fail("expires-at must be an ISO 8601 UTC timestamp")
    if expiry.tzinfo is None or expiry.utcoffset().total_seconds() != 0:
        fail("expires-at must be UTC")
    if expiry <= datetime.now(timezone.utc):
        fail("expires-at must be in the future")
    args.expiry = expiry
    if args.output_dir.exists():
        fail("output-dir already exists; preserve one generated fixture for both revisions")
    return args


def layout_member_count(args: argparse.Namespace, layout: str) -> int:
    if layout == "hot":
        return args.users
    if layout == "cold":
        return min(args.users, args.cold_members_per_room)
    return min(args.users, args.members_per_room)


def main() -> None:
    args = parse_args()
    old_umask = os.umask(0o077)
    created = False
    try:
        args.output_dir.mkdir(mode=0o700, parents=False)
        created = True
        fixture_id = stable_uuid(args.seed, "fixture-id")
        users = [stable_uuid(args.seed, f"user/{index}") for index in range(args.users)]
        devices = [stable_uuid(args.seed, f"device/{index}") for index in range(args.users)]
        key = secrets.token_bytes(32)
        tokens = ["va1_" + secrets.token_urlsafe(32) for _ in users]
        private_write(args.output_dir / "access-token-hmac-key.base64", base64.b64encode(key).decode() + "\n")
        expiry_sql = quoted(args.expiry.isoformat()) + "::timestamptz"
        expiry_ms = int(args.expiry.timestamp() * 1000)
        header = guard(fixture_id)
        common_rows = [
            f"({quoted(user)}, {quoted('va_capacity_' + str(index))}, {quoted('VA Capacity ' + str(index))}, 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
            for index, user in enumerate(users)
        ]
        common_sql = header + sql_insert(
            "public_user_profiles", "user_id, public_handle, display_name, revision, created_at, updated_at",
            common_rows,
        ) + (
            "INSERT INTO im_v2.user_shard_router_configuration "
            "(configuration_key, router_epoch, default_write_bucket, updated_at) "
            f"VALUES (TRUE, 1, {quoted(args.user_bucket)}, CURRENT_TIMESTAMP);\n"
        ) + sql_end()
        common_sha = private_write(args.output_dir / "common.sql", common_sql)
        auth_rows = [
            f"({quoted(user)}, {quoted(device)}, CURRENT_TIMESTAMP, {expiry_sql}, CURRENT_TIMESTAMP, 'Capacity device', 'Load generator')"
            for user, device in zip(users, devices)
        ]
        token_rows = [
            f"({quoted(hmac.new(key, token.encode(), hashlib.sha256).hexdigest())}, {quoted(user)}, {quoted(device)}, CURRENT_TIMESTAMP, {expiry_sql})"
            for user, device, token in zip(users, devices, tokens)
        ]
        auth_sql = header + sql_insert(
            "auth_devices", "user_id, device_id, created_at, session_expires_at, last_active_at, display_name, platform", auth_rows,
        ) + sql_insert(
            "device_access_tokens", "token_hmac, user_id, device_id, issued_at, expires_at", token_rows,
        ) + sql_end()
        auth_sha = private_write(args.output_dir / "auth-control.sql", auth_sql)
        manifest: dict[str, object] = {
            "schemaVersion": 1, "fixtureID": fixture_id, "uuidSeed": str(args.seed),
            "users": args.users, "targetsPerConnection": args.targets, "owners": args.owners,
            "expiresAt": args.expiry.isoformat(), "capacityProfileID": args.capacity_profile,
            "userBucket": args.user_bucket, "commandWindowLimit": args.command_window_limit,
            "commonSQLSHA256": common_sha, "authControlSQLSHA256": auth_sha,
            "identityMappingSHA256": digest_json(list(zip(users, devices))),
            "layouts": {},
        }
        for layout in args.layouts:
            member_count = layout_member_count(args, layout)
            layout_dir = args.output_dir / layout
            layout_dir.mkdir(mode=0o700)
            cohort_count = (args.users + member_count - 1) // member_count
            room_ids = [
                [stable_uuid(args.seed, f"room/{layout}/{cohort}/{slot}") for slot in range(args.targets)]
                for cohort in range(cohort_count)
            ]
            routes: list[str] = []
            owners: list[dict[str, list[str]]] = [
                {"rooms": [], "groups": [], "admissions": [], "memberships": []}
                for _ in range(args.owners)
            ]
            target_map: list[tuple[str, list[str]]] = []
            owner_room_counts = [0] * args.owners
            owner_member_counts = [0] * args.owners
            for cohort, cohort_rooms in enumerate(room_ids):
                start = cohort * member_count
                end = min(args.users, start + member_count)
                count = end - start
                capacity_class = "large" if count > 5_000 else "standard"
                owner_user = users[start]
                for slot, room in enumerate(cohort_rooms):
                    serial = cohort * args.targets + slot
                    owner_index = 0 if layout == "same-owner" else serial % args.owners
                    shard = f"{args.shard_prefix}-{owner_index:02d}"
                    group = owners[owner_index]
                    owner_room_counts[owner_index] += 1
                    owner_member_counts[owner_index] += count
                    routes.append(f"({quoted(room)}, {quoted(shard)}, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)")
                    group["rooms"].append(f"({quoted(room)}, 'group', {quoted(shard)}, 0, 1, {quoted(args.capacity_profile)}, {quoted(capacity_class)})")
                    group["groups"].append(f"({quoted(room)}, {quoted(owner_user)}, {quoted(f'VA {layout} {cohort} {slot}')}, CURRENT_TIMESTAMP)")
                    lease = stable_uuid(args.seed, f"lease/{layout}/{owner_index}")
                    group["admissions"].append(f"({quoted(room)}, {count}, {args.command_window_limit}, {quoted(lease)}, 1)")
                    for index in range(start, end):
                        role = "owner" if index == start else "member"
                        group["memberships"].append(f"({quoted(room)}, {quoted(users[index])}, {quoted(role)}, 1)")
            credential_lines = []
            for index, (user, device, token) in enumerate(zip(users, devices, tokens)):
                targets = room_ids[index // member_count]
                target_map.append((user, targets))
                credential_lines.append(json.dumps({
                    "userID": user, "deviceID": device, "accessToken": token,
                    "accessTokenExpiresAtMilliseconds": expiry_ms,
                    "targetRoomIDs": targets,
                }, separators=(",", ":")))
            credential_sha = private_write(layout_dir / "credentials.jsonl", "\n".join(credential_lines) + "\n")
            control_sql = header + sql_insert(
                "room_owner_routes", "room_id, room_shard_id, route_epoch, created_at, updated_at", routes,
            ) + sql_end()
            control_sha = private_write(layout_dir / "control.sql", control_sql)
            owner_sha: dict[str, str] = {}
            for owner_index, rows in enumerate(owners):
                shard = f"{args.shard_prefix}-{owner_index:02d}"
                lease = stable_uuid(args.seed, f"lease/{layout}/{owner_index}")
                owner_sql = header + (
                    "INSERT INTO im_v2.shard_admission_pools "
                    "(room_shard_id, capacity_profile_id, lease_id, generation, valid_until, command_window_limit) "
                    f"VALUES ({quoted(shard)}, {quoted(args.capacity_profile)}, {quoted(lease)}, 1, {expiry_sql}, {args.command_window_limit});\n"
                )
                owner_sql += sql_insert("rooms", "room_id, room_kind, room_shard_id, room_sequence, membership_revision, capacity_profile_id, capacity_class", rows["rooms"])
                owner_sql += sql_insert("group_rooms", "room_id, owner_user_id, title, created_at", rows["groups"])
                owner_sql += sql_insert("room_admission", "room_id, eligible_member_count, command_window_limit, shard_lease_id, shard_lease_generation", rows["admissions"])
                owner_sql += sql_insert("room_memberships", "room_id, user_id, role, joined_revision", rows["memberships"])
                owner_sql += sql_end()
                filename = f"owner-{owner_index:02d}.sql"
                owner_sha[filename] = private_write(layout_dir / filename, owner_sql)
            manifest["layouts"][layout] = {
                "credentialMappingSHA256": digest_json(target_map),
                "credentialFileSHA256": credential_sha,
                "rooms": len(routes), "memberships": sum(owner_member_counts),
                "membersPerRoom": member_count,
                "maximumRoomMembers": min(member_count, args.users),
                "ownerRoomCounts": owner_room_counts,
                "ownerMembershipCounts": owner_member_counts,
                "shardIDs": [f"{args.shard_prefix}-{index:02d}" for index in range(args.owners)],
                "controlSQLSHA256": control_sha, "ownerSQLSHA256": owner_sha,
            }
        private_write(args.output_dir / "manifest.json", json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        print(f"VA_CAPACITY_FIXTURE_READY fixture_id={fixture_id} users={args.users} layouts={','.join(args.layouts)} output={args.output_dir}")
    except BaseException:
        if created:
            shutil.rmtree(args.output_dir)
        raise
    finally:
        os.umask(old_umask)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        print(f"VA_CAPACITY_FIXTURE_FAILED {error}", file=sys.stderr)
        sys.exit(1)
