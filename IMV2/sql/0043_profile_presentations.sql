-- Contact aliases are private to their owner. A group nickname belongs to a
-- member in one room and is readable only by that room's active membership.

CREATE TABLE im_v2.user_contact_aliases (
    owner_user_id UUID NOT NULL REFERENCES im_v2.public_user_profiles(user_id) ON DELETE CASCADE,
    target_user_id UUID NOT NULL REFERENCES im_v2.public_user_profiles(user_id) ON DELETE CASCADE,
    remark_name TEXT NULL CHECK (remark_name IS NULL OR octet_length(remark_name) BETWEEN 1 AND 80),
    revision BIGINT NOT NULL CHECK (revision > 0),
    updated_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (owner_user_id, target_user_id),
    CHECK (owner_user_id <> target_user_id)
);

CREATE TABLE im_v2.user_contact_alias_operations (
    owner_user_id UUID NOT NULL,
    operation_id UUID NOT NULL,
    target_user_id UUID NOT NULL,
    expected_revision BIGINT NULL CHECK (expected_revision IS NULL OR expected_revision > 0),
    requested_remark_name TEXT NULL CHECK (requested_remark_name IS NULL OR octet_length(requested_remark_name) BETWEEN 1 AND 80),
    result_revision BIGINT NOT NULL CHECK (result_revision > 0),
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (owner_user_id, operation_id)
);

CREATE TABLE im_v2.room_member_nicknames (
    room_id UUID NOT NULL REFERENCES im_v2.rooms(room_id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES im_v2.public_user_profiles(user_id) ON DELETE CASCADE,
    nickname TEXT NULL CHECK (nickname IS NULL OR octet_length(nickname) BETWEEN 1 AND 80),
    revision BIGINT NOT NULL CHECK (revision > 0),
    updated_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (room_id, user_id)
);

CREATE TABLE im_v2.room_member_nickname_operations (
    actor_user_id UUID NOT NULL,
    operation_id UUID NOT NULL,
    room_id UUID NOT NULL,
    expected_revision BIGINT NULL CHECK (expected_revision IS NULL OR expected_revision > 0),
    requested_nickname TEXT NULL CHECK (requested_nickname IS NULL OR octet_length(requested_nickname) BETWEEN 1 AND 80),
    result_revision BIGINT NOT NULL CHECK (result_revision > 0),
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (actor_user_id, operation_id)
);
