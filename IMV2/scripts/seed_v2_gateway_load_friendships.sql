\set ON_ERROR_STOP on

-- Disposable load-test fixture only.  This derives its scope from existing
-- direct-room pairs, so it must never be run against a production database.
-- A policy revision bump fences any direct-send policy cache that predates the
-- relationship transition; start or restart the Gateway after applying it.
BEGIN;

WITH changed_pairs AS (
    INSERT INTO im_v2.user_relationships (
        lower_user_id,
        higher_user_id,
        state,
        requested_by_user_id,
        updated_at
    )
    SELECT pair.lower_user_id,
           pair.higher_user_id,
           'accepted',
           pair.lower_user_id,
           now()
    FROM im_v2.direct_room_pairs AS pair
    ON CONFLICT (lower_user_id, higher_user_id) DO UPDATE
        SET state = 'accepted',
            requested_by_user_id = EXCLUDED.requested_by_user_id,
            updated_at = EXCLUDED.updated_at
        WHERE im_v2.user_relationships.state IS DISTINCT FROM 'accepted'
    RETURNING lower_user_id, higher_user_id
)
UPDATE im_v2.direct_room_pairs AS pair
SET direct_policy_revision = pair.direct_policy_revision + 1
FROM changed_pairs AS changed
WHERE pair.lower_user_id = changed.lower_user_id
  AND pair.higher_user_id = changed.higher_user_id;

COMMIT;

SELECT count(*) AS accepted_direct_pair_count
FROM im_v2.user_relationships
WHERE state = 'accepted';
