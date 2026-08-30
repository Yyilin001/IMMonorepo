\set ON_ERROR_STOP on

\if :{?capacity_profile_id}
\else
\echo 'capacity_profile_id is required'
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
\if :{?lease_hours}
\else
\echo 'lease_hours is required'
\quit 64
\endif

BEGIN;
SELECT pg_advisory_xact_lock(hashtextextended(
  'im_v2.disposable_load_pool_provision', 0
));

CREATE TEMP TABLE disposable_pool_provision_config ON COMMIT DROP AS
SELECT :'capacity_profile_id'::text AS capacity_profile_id,
       :expected_shards::integer AS expected_shards,
       :command_window_limit::bigint AS command_window_limit,
       :lease_hours::integer AS lease_hours;

DO $guard$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM disposable_pool_provision_config
    WHERE capacity_profile_id !~ '^loadtest-[A-Za-z0-9._-]+$'
       OR expected_shards <= 0 OR expected_shards > 1024
       OR command_window_limit <= 0
       OR lease_hours <= 0 OR lease_hours > 168
  ) THEN
    RAISE EXCEPTION 'invalid disposable load pool configuration';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM im_v2.shard_admission_pools AS pool
    WHERE pool.capacity_profile_id = (
      SELECT capacity_profile_id FROM disposable_pool_provision_config
    )
  ) THEN
    RAISE EXCEPTION 'capacity profile already exists; issue a new immutable id';
  END IF;
END
$guard$;

INSERT INTO im_v2.shard_admission_pools
    (room_shard_id, capacity_profile_id, lease_id, generation, valid_until,
     command_window_limit, fanout_window_limit,
     max_outstanding_fanout_units, max_outstanding_plans)
SELECT 'rooms-load-' || lpad(shard_number::text, 2, '0'),
       config.capacity_profile_id,
       gen_random_uuid(),
       1,
       CURRENT_TIMESTAMP + make_interval(hours => config.lease_hours),
       config.command_window_limit,
       100000,
       1000000,
       10000
FROM disposable_pool_provision_config AS config
CROSS JOIN LATERAL generate_series(0, config.expected_shards - 1)
  AS shard_number;

COMMIT;

SELECT capacity_profile_id, count(*) AS shards,
       min(command_window_limit) AS minimum_command_window_limit,
       max(command_window_limit) AS maximum_command_window_limit,
       sum(command_window_used) AS commands_used,
       min(EXTRACT(EPOCH FROM valid_until - CURRENT_TIMESTAMP))::bigint
         AS minimum_lease_seconds
FROM im_v2.shard_admission_pools
WHERE capacity_profile_id = :'capacity_profile_id'
GROUP BY capacity_profile_id;
