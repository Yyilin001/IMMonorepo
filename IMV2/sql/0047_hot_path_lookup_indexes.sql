-- Reverse-direction and projection-expression indexes used by request paths.
-- Historical membership enumeration remains on the original room/revision
-- index; these indexes cover current-user authorization and direct/social
-- lookups without forcing scans that grow with total retained history.

CREATE INDEX room_memberships_current_user_rooms_idx
    ON im_v2.room_memberships (user_id, room_id, joined_revision DESC)
    INCLUDE (role)
    WHERE left_revision IS NULL;

CREATE INDEX direct_room_pairs_higher_user_idx
    ON im_v2.direct_room_pairs (higher_user_id, room_id, lower_user_id);

CREATE INDEX user_blocks_blocked_blocker_idx
    ON im_v2.user_blocks (blocked_user_id, blocker_user_id);
