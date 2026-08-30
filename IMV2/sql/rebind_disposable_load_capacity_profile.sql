\set ON_ERROR_STOP on

\if :{?old_profile_id}
\else
\echo 'old_profile_id is required'
\quit 64
\endif
\if :{?new_profile_id}
\else
\echo 'new_profile_id is required'
\quit 64
\endif
\if :{?expected_rooms}
\else
\echo 'expected_rooms is required'
\quit 64
\endif
\if :{?expected_shards}
\else
\echo 'expected_shards is required'
\quit 64
\endif
\if :{?command_window_limit}
\else
\echo 'command_window_limit is required'
\quit 64
\endif

-- This is intentionally not a production capacity-profile migration. It is
-- a guarded fixture operation for a fully drained, disposable load-test data
-- set whose durable message/event state has already been cleared. Production
-- rooms retain the immutable capacity profile selected at creation time.
BEGIN;
SELECT pg_advisory_xact_lock(hashtextextended('im_v2.disposable_load_profile_rebind', 0));

CREATE TEMP TABLE disposable_profile_rebind_config ON COMMIT DROP AS
SELECT :'old_profile_id'::text AS old_profile_id,
       :'new_profile_id'::text AS new_profile_id,
       :expected_rooms::bigint AS expected_rooms,
       :expected_shards::bigint AS expected_shards,
       :command_window_limit::bigint AS command_window_limit;

DO $guard$
BEGIN
  IF (SELECT old_profile_id = new_profile_id
      FROM disposable_profile_rebind_config) THEN
    RAISE EXCEPTION 'old and new capacity profiles must differ';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM disposable_profile_rebind_config
    WHERE old_profile_id !~ '^loadtest-[A-Za-z0-9._-]+$'
       OR new_profile_id !~ '^loadtest-[A-Za-z0-9._-]+$'
       OR expected_rooms <= 0
       OR expected_shards <= 0
       OR command_window_limit <= 0
  ) THEN
    RAISE EXCEPTION 'invalid disposable load profile configuration';
  END IF;
  IF (SELECT count(*)
      FROM im_v2.rooms
      WHERE capacity_profile_id = (
        SELECT old_profile_id FROM disposable_profile_rebind_config
      )) <> (SELECT expected_rooms FROM disposable_profile_rebind_config) THEN
    RAISE EXCEPTION 'old-profile room count changed';
  END IF;
  IF (SELECT count(*)
      FROM im_v2.shard_admission_pools
      WHERE capacity_profile_id = (
        SELECT new_profile_id FROM disposable_profile_rebind_config
      )) <> (SELECT expected_shards FROM disposable_profile_rebind_config) THEN
    RAISE EXCEPTION 'new-profile shard count is invalid';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM im_v2.shard_admission_pools
    WHERE capacity_profile_id = (
      SELECT new_profile_id FROM disposable_profile_rebind_config
    )
      AND (command_window_limit <> (
             SELECT command_window_limit FROM disposable_profile_rebind_config
           )
           OR command_window_used <> 0
           OR fanout_window_used <> 0
           OR outstanding_fanout_units <> 0
           OR outstanding_plans <> 0
           OR valid_until <= CURRENT_TIMESTAMP)
  ) THEN
    RAISE EXCEPTION 'new-profile pools are not fresh and compatible';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM im_v2.rooms AS room
    WHERE room.capacity_profile_id = (
      SELECT old_profile_id FROM disposable_profile_rebind_config
    )
      AND (room.room_sequence <> 0 OR room.timeline_sequence <> 0)
  ) THEN
    RAISE EXCEPTION 'old-profile rooms still contain timeline state';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM im_v2.rooms AS room
    JOIN im_v2.room_admission AS admission USING (room_id)
    WHERE room.capacity_profile_id = (
      SELECT old_profile_id FROM disposable_profile_rebind_config
    )
      AND (admission.command_window_used <> 0
           OR admission.fanout_window_used <> 0
           OR admission.outstanding_fanout_units <> 0
           OR admission.outstanding_plans <> 0)
  ) THEN
    RAISE EXCEPTION 'old-profile room admission is not drained';
  END IF;
END
$guard$;

UPDATE im_v2.room_admission AS admission
SET command_window_limit = pool.command_window_limit,
    command_window_used = 0,
    fanout_window_limit = pool.fanout_window_limit,
    fanout_window_used = 0,
    max_outstanding_fanout_units = pool.max_outstanding_fanout_units,
    outstanding_fanout_units = 0,
    max_outstanding_plans = pool.max_outstanding_plans,
    outstanding_plans = 0,
    shard_lease_id = pool.lease_id,
    shard_lease_generation = pool.generation
FROM im_v2.rooms AS room
JOIN im_v2.shard_admission_pools AS pool
  ON pool.room_shard_id = room.room_shard_id
 AND pool.capacity_profile_id = (
   SELECT new_profile_id FROM disposable_profile_rebind_config
 )
WHERE admission.room_id = room.room_id
  AND room.capacity_profile_id = (
    SELECT old_profile_id FROM disposable_profile_rebind_config
  );

UPDATE im_v2.rooms
SET capacity_profile_id = (
  SELECT new_profile_id FROM disposable_profile_rebind_config
)
WHERE capacity_profile_id = (
  SELECT old_profile_id FROM disposable_profile_rebind_config
);

DO $verify$
BEGIN
  IF (SELECT count(*)
      FROM im_v2.rooms
      WHERE capacity_profile_id = (
        SELECT new_profile_id FROM disposable_profile_rebind_config
      )) < (SELECT expected_rooms FROM disposable_profile_rebind_config) THEN
    RAISE EXCEPTION 'not every disposable room was rebound';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM im_v2.rooms AS room
    JOIN im_v2.room_admission AS admission USING (room_id)
    JOIN im_v2.shard_admission_pools AS pool
      ON pool.room_shard_id = room.room_shard_id
     AND pool.capacity_profile_id = room.capacity_profile_id
    WHERE room.capacity_profile_id = (
      SELECT new_profile_id FROM disposable_profile_rebind_config
    )
      AND (admission.shard_lease_id <> pool.lease_id
           OR admission.shard_lease_generation <> pool.generation
           OR admission.command_window_limit <> pool.command_window_limit)
  ) THEN
    RAISE EXCEPTION 'rebound room admission fence is inconsistent';
  END IF;
END
$verify$;

COMMIT;

SELECT capacity_profile_id, count(*) AS rooms,
       count(DISTINCT room_shard_id) AS shards
FROM im_v2.rooms
WHERE capacity_profile_id IN (:'old_profile_id', :'new_profile_id')
GROUP BY capacity_profile_id
ORDER BY capacity_profile_id;
