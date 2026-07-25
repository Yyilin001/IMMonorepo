-- Group creation is a first-class durable operation.  The operation record
-- captures canonical initial members so a lost gateway response can be replayed
-- without creating a second room or accepting altered membership input.
CREATE TABLE im_v2.group_rooms (
    room_id UUID PRIMARY KEY REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT,
    owner_user_id UUID NOT NULL,
    title TEXT NOT NULL CHECK (octet_length(title) BETWEEN 1 AND 120),
    created_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE im_v2.group_room_operations (
    actor_user_id UUID NOT NULL,
    operation_id UUID NOT NULL,
    room_id UUID NOT NULL UNIQUE REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT,
    title TEXT NOT NULL CHECK (octet_length(title) BETWEEN 1 AND 120),
    initial_member_user_ids UUID[] NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (actor_user_id, operation_id),
    CHECK (array_position(initial_member_user_ids, actor_user_id) IS NULL),
    CHECK (cardinality(initial_member_user_ids) >= 0)
);
