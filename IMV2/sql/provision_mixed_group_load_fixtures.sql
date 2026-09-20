\set ON_ERROR_STOP on

\if :{?capacity_profile_id}
\else
\set capacity_profile_id 'loadtest-v18'
\endif

\if :{?expected_sender_count}
\else
\set expected_sender_count 1000
\endif

-- The caller must create this session-local table and load the exact users
-- whose temporary access tokens will drive the test:
--
--   CREATE TEMP TABLE imv2_mixed_group_sender_ids (
--       ordinal bigint PRIMARY KEY,
--       user_id uuid UNIQUE NOT NULL
--   );
--
-- Keeping credential material outside this SQL makes the fixture repeatable
-- without ever persisting tokens or refresh credentials in PostgreSQL.
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';
SELECT pg_advisory_xact_lock(
    hashtextextended('im_v2.mixed_group_load_fixtures.v1', 0)
);

CREATE TEMP TABLE imv2_mixed_group_fixture_specs (
    fixture_name text PRIMARY KEY,
    room_id uuid UNIQUE NOT NULL,
    member_count bigint NOT NULL,
    capacity_class text NOT NULL,
    room_shard_id text NOT NULL
) ON COMMIT DROP;

CREATE TEMP TABLE imv2_mixed_group_fixture_config ON COMMIT DROP AS
SELECT :'capacity_profile_id'::text AS capacity_profile_id,
       :expected_sender_count::bigint AS expected_sender_count;

INSERT INTO imv2_mixed_group_fixture_specs
    (fixture_name, room_id, member_count, capacity_class, room_shard_id)
VALUES
    ('sf-20',   '00000000-0000-4000-8000-000000000014',     20, 'standard',   'rooms-load-00'),
    ('sf-200',  '00000000-0000-4000-8000-0000000000c8',    200, 'standard',   'rooms-load-01'),
    ('sf-1000', '00000000-0000-4000-8000-0000000003e8',   1000, 'standard',   'rooms-load-02'),
    ('sf-5000', '00000000-0000-4000-8000-000000001388',   5000, 'standard',   'rooms-load-03'),
    ('hy-5001', '00000000-0000-4000-8000-000000001389',   5001, 'large','rooms-load-04'),
    ('hy-10k-00','00000000-0000-4000-8000-000000002710',  10000, 'large','rooms-load-05'),
    ('hy-10k-01','00000000-0000-4001-8000-000000002710',  10000, 'large','rooms-load-06'),
    ('hy-10k-02','00000000-0000-4002-8000-000000002710',  10000, 'large','rooms-load-07'),
    ('hy-10k-03','00000000-0000-4003-8000-000000002710',  10000, 'large','rooms-load-04'),
    ('hy-10k-04','00000000-0000-4004-8000-000000002710',  10000, 'large','rooms-load-05'),
    ('hy-10k-05','00000000-0000-4005-8000-000000002710',  10000, 'large','rooms-load-06'),
    ('hy-10k-06','00000000-0000-4006-8000-000000002710',  10000, 'large','rooms-load-07'),
    ('hy-10k-07','00000000-0000-4007-8000-000000002710',  10000, 'large','rooms-load-04'),
    ('hy-10k-08','00000000-0000-4008-8000-000000002710',  10000, 'large','rooms-load-05'),
    ('hy-10k-09','00000000-0000-4009-8000-000000002710',  10000, 'large','rooms-load-06'),
    ('hy-50k',  '00000000-0000-4000-8000-00000000c350',  50000, 'large','rooms-load-06'),
    ('hy-100k', '00000000-0000-4000-8000-0000000186a0', 100000, 'large','rooms-load-07');

DO $guard$
DECLARE
    actual_senders bigint;
BEGIN
    IF to_regclass('pg_temp.imv2_mixed_group_sender_ids') IS NULL THEN
        RAISE EXCEPTION 'temporary sender table is required';
    END IF;

    SELECT count(*) INTO actual_senders
    FROM imv2_mixed_group_sender_ids;
    IF actual_senders <> (
        SELECT expected_sender_count FROM imv2_mixed_group_fixture_config
    ) THEN
        RAISE EXCEPTION 'sender count mismatch: expected %, found %',
            (SELECT expected_sender_count FROM imv2_mixed_group_fixture_config),
            actual_senders;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM imv2_mixed_group_sender_ids AS sender
        LEFT JOIN im_v2.public_user_profiles AS profile
          ON profile.user_id = sender.user_id
         AND profile.state = 'active'
        LEFT JOIN im_v2.account_disables AS disabled
          ON disabled.user_id = sender.user_id
        WHERE profile.user_id IS NULL OR disabled.user_id IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'every load sender must be an active account';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM imv2_mixed_group_fixture_specs AS fixture
        LEFT JOIN im_v2.shard_admission_pools AS pool
          ON pool.room_shard_id = fixture.room_shard_id
         AND pool.capacity_profile_id = (
             SELECT capacity_profile_id
             FROM imv2_mixed_group_fixture_config
         )
        WHERE pool.lease_id IS NULL OR pool.valid_until <= now()
    ) THEN
        RAISE EXCEPTION 'a required shard admission lease is missing or expired';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM imv2_mixed_group_fixture_specs AS fixture
        JOIN im_v2.rooms AS room USING (room_id)
    ) THEN
        RAISE EXCEPTION 'mixed-group v1 room IDs already exist; use a fresh fixture version';
    END IF;
END
$guard$;

-- The pool is deterministic, starts with every online sender, and fills the
-- remaining 100k audience from active non-sender accounts.  A large group is
-- therefore one shared canonical room with a realistic online/offline mix;
-- it is not synthesized as one room per connection.
CREATE TEMP TABLE imv2_mixed_group_member_pool ON COMMIT DROP AS
WITH sender_count AS (
    SELECT count(*)::bigint AS value FROM imv2_mixed_group_sender_ids
), additional AS (
    SELECT profile.user_id,
           row_number() OVER (ORDER BY profile.user_id)
             + (SELECT value FROM sender_count) AS ordinal
    FROM im_v2.public_user_profiles AS profile
    LEFT JOIN im_v2.account_disables AS disabled USING (user_id)
    WHERE profile.state = 'active'
      AND disabled.user_id IS NULL
      AND NOT EXISTS (
          SELECT 1 FROM imv2_mixed_group_sender_ids AS sender
          WHERE sender.user_id = profile.user_id
      )
    ORDER BY profile.user_id
    LIMIT (SELECT 100000 - value FROM sender_count)
)
SELECT sender.ordinal, sender.user_id
FROM imv2_mixed_group_sender_ids AS sender
UNION ALL
SELECT additional.ordinal, additional.user_id
FROM additional;

CREATE UNIQUE INDEX ON imv2_mixed_group_member_pool (ordinal);
CREATE UNIQUE INDEX ON imv2_mixed_group_member_pool (user_id);

DO $pool_guard$
BEGIN
    IF (SELECT count(*) FROM imv2_mixed_group_member_pool) <> 100000 THEN
        RAISE EXCEPTION 'not enough active accounts for the 100k fixture';
    END IF;
END
$pool_guard$;

INSERT INTO im_v2.rooms
    (room_id, room_kind, room_shard_id, room_sequence,
     membership_revision, capacity_profile_id, capacity_class, created_at)
SELECT fixture.room_id, 'group', fixture.room_shard_id, 0,
       1, :'capacity_profile_id', fixture.capacity_class, now()
FROM imv2_mixed_group_fixture_specs AS fixture;

INSERT INTO im_v2.group_rooms (room_id, owner_user_id, title, created_at)
SELECT fixture.room_id, owner.user_id,
       'Load fixture ' || fixture.fixture_name, now()
FROM imv2_mixed_group_fixture_specs AS fixture
CROSS JOIN LATERAL (
    SELECT user_id FROM imv2_mixed_group_member_pool WHERE ordinal = 1
) AS owner;

INSERT INTO im_v2.room_owner_routes
    (room_id, room_shard_id, route_epoch, created_at, updated_at)
SELECT room_id, room_shard_id, 0, now(), now()
FROM imv2_mixed_group_fixture_specs;

INSERT INTO im_v2.room_memberships
    (room_id, user_id, role, joined_revision)
SELECT fixture.room_id, member.user_id,
       CASE WHEN member.ordinal = 1 THEN 'owner' ELSE 'member' END,
       1
FROM imv2_mixed_group_fixture_specs AS fixture
JOIN imv2_mixed_group_member_pool AS member
  ON member.ordinal <= fixture.member_count;

INSERT INTO im_v2.room_admission
    (room_id, eligible_member_count, command_window_limit, command_window_used, shard_lease_id, shard_lease_generation)
SELECT fixture.room_id, fixture.member_count, pool.command_window_limit, 0, pool.lease_id, pool.generation
FROM imv2_mixed_group_fixture_specs AS fixture
JOIN im_v2.shard_admission_pools AS pool
  ON pool.room_shard_id = fixture.room_shard_id
 AND pool.capacity_profile_id = :'capacity_profile_id';

COMMIT;

SELECT fixture.fixture_name, room.room_id, room.capacity_class,
       room.room_shard_id, room.capacity_profile_id,
       count(membership.user_id) AS active_members
FROM (VALUES
    ('sf-20',   '00000000-0000-4000-8000-000000000014'::uuid),
    ('sf-200',  '00000000-0000-4000-8000-0000000000c8'::uuid),
    ('sf-1000', '00000000-0000-4000-8000-0000000003e8'::uuid),
    ('sf-5000', '00000000-0000-4000-8000-000000001388'::uuid),
    ('hy-5001', '00000000-0000-4000-8000-000000001389'::uuid),
    ('hy-10k-00','00000000-0000-4000-8000-000000002710'::uuid),
    ('hy-10k-01','00000000-0000-4001-8000-000000002710'::uuid),
    ('hy-10k-02','00000000-0000-4002-8000-000000002710'::uuid),
    ('hy-10k-03','00000000-0000-4003-8000-000000002710'::uuid),
    ('hy-10k-04','00000000-0000-4004-8000-000000002710'::uuid),
    ('hy-10k-05','00000000-0000-4005-8000-000000002710'::uuid),
    ('hy-10k-06','00000000-0000-4006-8000-000000002710'::uuid),
    ('hy-10k-07','00000000-0000-4007-8000-000000002710'::uuid),
    ('hy-10k-08','00000000-0000-4008-8000-000000002710'::uuid),
    ('hy-10k-09','00000000-0000-4009-8000-000000002710'::uuid),
    ('hy-50k',  '00000000-0000-4000-8000-00000000c350'::uuid),
    ('hy-100k', '00000000-0000-4000-8000-0000000186a0'::uuid)
) AS fixture(fixture_name, room_id)
JOIN im_v2.rooms AS room USING (room_id)
JOIN im_v2.room_memberships AS membership USING (room_id)
WHERE membership.left_revision IS NULL
GROUP BY fixture.fixture_name, room.room_id, room.capacity_class,
         room.room_shard_id, room.capacity_profile_id
ORDER BY active_members;
