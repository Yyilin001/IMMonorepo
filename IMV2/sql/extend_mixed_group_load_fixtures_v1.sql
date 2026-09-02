\set ON_ERROR_STOP on

\if :{?capacity_profile_id}
\else
\set capacity_profile_id 'loadtest-v18'
\endif

-- Extends an already-provisioned mixed-group v1 fixture with nine additional
-- 10k hybrid rooms.  The rooms reuse the exact active membership of hy-10k-00
-- so a distributed hot-room test does not require or persist new credentials.
-- This migration is intentionally guarded and one-shot: partial or repeated
-- execution fails instead of silently producing a non-comparable fixture.
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '10min';
SELECT pg_advisory_xact_lock(
    hashtextextended('im_v2.mixed_group_load_fixtures.v1', 0)
);

CREATE TEMP TABLE imv2_mixed_group_extension_specs (
    fixture_name text PRIMARY KEY,
    room_id uuid UNIQUE NOT NULL,
    room_shard_id text NOT NULL
) ON COMMIT DROP;

CREATE TEMP TABLE imv2_mixed_group_extension_config ON COMMIT DROP AS
SELECT :'capacity_profile_id'::text AS capacity_profile_id;

INSERT INTO imv2_mixed_group_extension_specs
    (fixture_name, room_id, room_shard_id)
VALUES
    ('hy-10k-01', '00000000-0000-4001-8000-000000002710', 'rooms-load-06'),
    ('hy-10k-02', '00000000-0000-4002-8000-000000002710', 'rooms-load-07'),
    ('hy-10k-03', '00000000-0000-4003-8000-000000002710', 'rooms-load-04'),
    ('hy-10k-04', '00000000-0000-4004-8000-000000002710', 'rooms-load-05'),
    ('hy-10k-05', '00000000-0000-4005-8000-000000002710', 'rooms-load-06'),
    ('hy-10k-06', '00000000-0000-4006-8000-000000002710', 'rooms-load-07'),
    ('hy-10k-07', '00000000-0000-4007-8000-000000002710', 'rooms-load-04'),
    ('hy-10k-08', '00000000-0000-4008-8000-000000002710', 'rooms-load-05'),
    ('hy-10k-09', '00000000-0000-4009-8000-000000002710', 'rooms-load-06');

DO $guard$
DECLARE
    source_room_id constant uuid :=
        '00000000-0000-4000-8000-000000002710';
    source_members bigint;
BEGIN
    SELECT count(*) INTO source_members
    FROM im_v2.room_memberships
    WHERE room_id = source_room_id
      AND left_revision IS NULL;

    IF source_members <> 10000 OR NOT EXISTS (
        SELECT 1
        FROM im_v2.rooms
        WHERE room_id = source_room_id
          AND delivery_mode = 'large_group_hybrid'
          AND capacity_profile_id = (
              SELECT capacity_profile_id
              FROM imv2_mixed_group_extension_config
          )
    ) THEN
        RAISE EXCEPTION
            'hy-10k-00 must be a complete 10k hybrid fixture for profile %',
            (SELECT capacity_profile_id
             FROM imv2_mixed_group_extension_config);
    END IF;

    IF EXISTS (
        SELECT 1
        FROM imv2_mixed_group_extension_specs AS fixture
        JOIN im_v2.rooms AS room USING (room_id)
    ) THEN
        RAISE EXCEPTION 'one or more mixed-group v1 extension IDs already exist';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM imv2_mixed_group_extension_specs AS fixture
        LEFT JOIN im_v2.shard_admission_pools AS pool
          ON pool.room_shard_id = fixture.room_shard_id
         AND pool.capacity_profile_id = (
             SELECT capacity_profile_id
             FROM imv2_mixed_group_extension_config
         )
        WHERE pool.lease_id IS NULL OR pool.valid_until <= now()
    ) THEN
        RAISE EXCEPTION 'a required shard admission lease is missing or expired';
    END IF;
END
$guard$;

INSERT INTO im_v2.rooms
    (room_id, room_kind, room_shard_id, room_sequence,
     membership_revision, capacity_profile_id, delivery_mode, created_at)
SELECT fixture.room_id, 'group', fixture.room_shard_id, 0,
       1, :'capacity_profile_id', 'large_group_hybrid', now()
FROM imv2_mixed_group_extension_specs AS fixture;

INSERT INTO im_v2.group_rooms (room_id, owner_user_id, title, created_at)
SELECT fixture.room_id, source.owner_user_id,
       'Load fixture ' || fixture.fixture_name, now()
FROM imv2_mixed_group_extension_specs AS fixture
CROSS JOIN (
    SELECT owner_user_id
    FROM im_v2.group_rooms
    WHERE room_id = '00000000-0000-4000-8000-000000002710'
) AS source;

INSERT INTO im_v2.room_owner_routes
    (room_id, room_shard_id, route_epoch, created_at, updated_at)
SELECT room_id, room_shard_id, 0, now(), now()
FROM imv2_mixed_group_extension_specs;

INSERT INTO im_v2.room_memberships
    (room_id, user_id, role, joined_revision, left_revision)
SELECT fixture.room_id, source.user_id, source.role,
       source.joined_revision, source.left_revision
FROM imv2_mixed_group_extension_specs AS fixture
CROSS JOIN im_v2.room_memberships AS source
WHERE source.room_id = '00000000-0000-4000-8000-000000002710'
  AND source.left_revision IS NULL;

INSERT INTO im_v2.room_admission
    (room_id, eligible_member_count,
     command_window_limit, command_window_used,
     fanout_window_limit, fanout_window_used,
     max_outstanding_fanout_units, outstanding_fanout_units,
     max_outstanding_plans, outstanding_plans,
     shard_lease_id, shard_lease_generation)
SELECT fixture.room_id, 10000,
       pool.command_window_limit, 0,
       pool.fanout_window_limit, 0,
       pool.max_outstanding_fanout_units, 0,
       pool.max_outstanding_plans, 0,
       pool.lease_id, pool.generation
FROM imv2_mixed_group_extension_specs AS fixture
JOIN im_v2.shard_admission_pools AS pool
  ON pool.room_shard_id = fixture.room_shard_id
 AND pool.capacity_profile_id = :'capacity_profile_id';

DO $verify$
BEGIN
    IF EXISTS (
        SELECT fixture.room_id
        FROM imv2_mixed_group_extension_specs AS fixture
        LEFT JOIN im_v2.room_memberships AS membership
          ON membership.room_id = fixture.room_id
         AND membership.left_revision IS NULL
        GROUP BY fixture.room_id
        HAVING count(membership.user_id) <> 10000
    ) THEN
        RAISE EXCEPTION 'an extension room does not have exactly 10k members';
    END IF;
END
$verify$;

COMMIT;

SELECT room.room_id, room.room_shard_id, room.delivery_mode,
       count(membership.user_id) AS active_members
FROM im_v2.rooms AS room
JOIN im_v2.room_memberships AS membership USING (room_id)
WHERE room.room_id::text ~ '^00000000-0000-400[1-9]-8000-000000002710$'
  AND membership.left_revision IS NULL
GROUP BY room.room_id, room.room_shard_id, room.delivery_mode
ORDER BY room.room_id;
