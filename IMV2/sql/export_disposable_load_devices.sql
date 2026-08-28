\set ON_ERROR_STOP on
\if :{?capacity_profile_id}
\else
\set capacity_profile_id 'loadtest-v17'
\endif

-- Disposable load-test export only. It contains no credential material and
-- selects active devices whose users already own two currently sendable
-- direct rooms bound to the requested immutable capacity profile. Keeping the
-- profile predicate here prevents one legacy target from rolling back an
-- otherwise compatible atomic append batch; the executable preflight repeats
-- the same checks against the final credentials immediately before a run.
COPY (
    WITH direct_targets AS (
        SELECT membership.user_id,
               (array_agg(membership.room_id ORDER BY membership.room_id))[1]
                   AS first_room_id,
               (array_agg(membership.room_id ORDER BY membership.room_id))[2]
                   AS second_room_id
        FROM im_v2.room_memberships AS membership
        JOIN im_v2.rooms AS room USING (room_id)
        JOIN im_v2.shard_admission_pools AS shard
          ON shard.room_shard_id = room.room_shard_id
         AND shard.capacity_profile_id = room.capacity_profile_id
        JOIN im_v2.public_user_profiles AS profile
          ON profile.user_id = membership.user_id
         AND profile.state = 'active'
        JOIN im_v2.direct_room_pairs AS pair ON pair.room_id = room.room_id
        LEFT JOIN im_v2.account_disables AS disabled
          ON disabled.user_id = membership.user_id
        WHERE membership.left_revision IS NULL
          AND membership.joined_revision <= room.membership_revision
          AND room.room_kind = 'direct'
          AND room.capacity_profile_id = :'capacity_profile_id'
          AND room.frozen_at IS NULL
          AND shard.valid_until > now()
          AND disabled.user_id IS NULL
          AND membership.user_id IN (pair.lower_user_id, pair.higher_user_id)
          AND NOT EXISTS (
              SELECT 1
              FROM im_v2.room_member_mutes AS mute
              WHERE mute.room_id = membership.room_id
                AND mute.user_id = membership.user_id
                AND mute.mute_until > now()
          )
        GROUP BY membership.user_id
        HAVING count(*) >= 2
    )
    SELECT device.user_id,
           device.device_id,
           target.first_room_id,
           target.second_room_id
    FROM im_v2.auth_devices AS device
    JOIN direct_targets AS target USING (user_id)
    WHERE device.revoked_at IS NULL
    ORDER BY device.device_id
    LIMIT :load_count
) TO STDOUT WITH (FORMAT csv, DELIMITER E'\t');
