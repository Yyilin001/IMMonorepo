#!/usr/bin/env bash
set -Eeuo pipefail

profile_id="${1:-}"
database_url="${IM_V2_PROFILE_DATABASE_URL:-}"
expected_shards="${IM_V2_LOAD_EXPECTED_SHARDS:-8}"
lease_hours="${IM_V2_LOAD_LEASE_HOURS:-24}"

fail() {
  printf 'disposable admission reset failed: %s\n' "$1" >&2
  exit 1
}

[[ "${IMV2_DISPOSABLE_LOAD_ADMISSION_RESET:-}" == '1' ]] \
  || fail 'IMV2_DISPOSABLE_LOAD_ADMISSION_RESET=1 is required'
[[ "${IMV2_DISPOSABLE_LOAD_GATEWAY_DRAIN_CONFIRMED:-}" == '1' ]] \
  || fail 'confirm zero active Gateway connections before resetting a lease'
[[ -n "${database_url}" ]] || fail 'IM_V2_PROFILE_DATABASE_URL is required'
[[ "${profile_id}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] \
  || fail 'capacity-profile-id is missing or invalid'
[[ "${expected_shards}" =~ ^[1-9][0-9]*$ ]] || fail 'expected shard count is invalid'
[[ "${lease_hours}" =~ ^[1-9][0-9]*$ ]] || fail 'lease hours is invalid'
(( expected_shards <= 1024 )) || fail 'expected shard count is too large'
(( lease_hours <= 168 )) || fail 'lease duration must not exceed seven days'
command -v psql >/dev/null 2>&1 || fail 'psql is required'

psql "${database_url}" -v ON_ERROR_STOP=1 \
  -v profile_id="${profile_id}" \
  -v expected_shards="${expected_shards}" \
  -v lease_hours="${lease_hours}" <<'SQL'
BEGIN;

CREATE TEMP TABLE disposable_pool_reset_config ON COMMIT DROP AS
SELECT :'profile_id'::text AS profile_id,
       :expected_shards::bigint AS expected_shards,
       :lease_hours::integer AS lease_hours;

CREATE TEMP TABLE disposable_pool_reset_before ON COMMIT DROP AS
SELECT room_shard_id, capacity_profile_id, lease_id, generation,
       command_window_limit, command_window_used,
       fanout_window_limit, fanout_window_used,
       outstanding_fanout_units, outstanding_plans
FROM im_v2.shard_admission_pools
WHERE capacity_profile_id = (
  SELECT profile_id FROM disposable_pool_reset_config
)
ORDER BY room_shard_id
FOR UPDATE;

DO $guard$
BEGIN
  IF (SELECT count(*) FROM disposable_pool_reset_before)
       <> (SELECT expected_shards FROM disposable_pool_reset_config) THEN
    RAISE EXCEPTION 'unexpected disposable shard count';
  END IF;
  IF EXISTS (
    SELECT 1 FROM disposable_pool_reset_before
    WHERE outstanding_fanout_units <> 0 OR outstanding_plans <> 0
  ) THEN
    RAISE EXCEPTION 'durable fanout work is still outstanding';
  END IF;
END
$guard$;

UPDATE im_v2.shard_admission_pools AS pool
SET lease_id = gen_random_uuid(),
    generation = pool.generation + 1,
    valid_until = CURRENT_TIMESTAMP + make_interval(hours => (
      SELECT lease_hours FROM disposable_pool_reset_config
    )),
    command_window_used = 0,
    fanout_window_used = 0
WHERE pool.capacity_profile_id = (
  SELECT profile_id FROM disposable_pool_reset_config
);

DO $verify$
BEGIN
  IF (SELECT count(*) FROM im_v2.shard_admission_pools
      WHERE capacity_profile_id = (
        SELECT profile_id FROM disposable_pool_reset_config
      )
        AND command_window_used = 0
        AND fanout_window_used = 0)
       <> (SELECT expected_shards FROM disposable_pool_reset_config) THEN
    RAISE EXCEPTION 'not every disposable pool was reset';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM im_v2.rooms AS room
    JOIN im_v2.room_admission AS admission USING (room_id)
    JOIN im_v2.shard_admission_pools AS pool
      ON pool.room_shard_id = room.room_shard_id
     AND pool.capacity_profile_id = room.capacity_profile_id
    WHERE room.capacity_profile_id = (
      SELECT profile_id FROM disposable_pool_reset_config
    )
      AND (admission.shard_lease_id <> pool.lease_id
           OR admission.shard_lease_generation <> pool.generation)
  ) THEN
    RAISE EXCEPTION 'room admission fences did not follow the new shard lease';
  END IF;
END
$verify$;

COMMIT;

SELECT count(*) AS reset_shards,
       min(command_window_limit - command_window_used) AS minimum_command_credit,
       min(EXTRACT(EPOCH FROM valid_until - CURRENT_TIMESTAMP))::bigint
         AS minimum_lease_seconds
FROM im_v2.shard_admission_pools
WHERE capacity_profile_id = :'profile_id';
SQL
