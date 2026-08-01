-- Conversation/message metadata and group capability model.
--
-- User-owned state is deliberately separate from room events: pinning a
-- conversation, archiving it, muting it and favouriting a message must never
-- create work for every other room member.  Group-owned state uses room
-- events and fan-out plans in its command store so every member observes one
-- ordered, auditable result.

CREATE TABLE im_v2.user_room_preferences (
    user_id UUID NOT NULL,
    room_id UUID NOT NULL REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT,
    pinned_at TIMESTAMPTZ NULL,
    archived_at TIMESTAMPTZ NULL,
    mute_until TIMESTAMPTZ NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (user_id, room_id)
);
CREATE INDEX user_room_preferences_visible_idx
    ON im_v2.user_room_preferences (user_id, archived_at, pinned_at DESC, updated_at DESC);

CREATE TABLE im_v2.user_room_preference_operations (
    actor_user_id UUID NOT NULL,
    operation_id UUID NOT NULL,
    room_id UUID NOT NULL REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT,
    pinned_at TIMESTAMPTZ NULL,
    archived_at TIMESTAMPTZ NULL,
    mute_until TIMESTAMPTZ NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (actor_user_id, operation_id)
);

CREATE TABLE im_v2.user_message_favorites (
    user_id UUID NOT NULL,
    message_id UUID NOT NULL REFERENCES im_v2.messages(message_id) ON DELETE RESTRICT,
    room_id UUID NOT NULL REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (user_id, message_id)
);
CREATE INDEX user_message_favorites_room_idx
    ON im_v2.user_message_favorites (user_id, room_id, created_at DESC, message_id);

CREATE TABLE im_v2.user_message_favorite_operations (
    actor_user_id UUID NOT NULL,
    operation_id UUID NOT NULL,
    message_id UUID NOT NULL REFERENCES im_v2.messages(message_id) ON DELETE RESTRICT,
    room_id UUID NOT NULL REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT,
    is_favorited BOOLEAN NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (actor_user_id, operation_id)
);

CREATE TABLE im_v2.room_pinned_messages (
    room_id UUID NOT NULL REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT,
    message_id UUID NOT NULL REFERENCES im_v2.messages(message_id) ON DELETE RESTRICT,
    pinned_by_user_id UUID NOT NULL,
    pinned_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (room_id, message_id)
);
CREATE INDEX room_pinned_messages_order_idx
    ON im_v2.room_pinned_messages (room_id, pinned_at DESC, message_id);

CREATE TABLE im_v2.room_pinned_message_operations (
    actor_user_id UUID NOT NULL,
    operation_id UUID NOT NULL,
    room_id UUID NOT NULL REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT,
    message_id UUID NOT NULL REFERENCES im_v2.messages(message_id) ON DELETE RESTRICT,
    is_pinned BOOLEAN NOT NULL,
    room_sequence BIGINT NOT NULL CHECK (room_sequence > 0),
    event_id UUID NOT NULL UNIQUE,
    plan_id UUID NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (actor_user_id, operation_id)
);

CREATE TABLE im_v2.group_announcements (
    room_id UUID PRIMARY KEY REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT,
    body TEXT NOT NULL CHECK (length(body) > 0 AND octet_length(body) <= 4096),
    revision BIGINT NOT NULL CHECK (revision > 0),
    updated_by_user_id UUID NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE im_v2.group_announcement_operations (
    actor_user_id UUID NOT NULL,
    operation_id UUID NOT NULL,
    room_id UUID NOT NULL REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT,
    body TEXT NOT NULL CHECK (length(body) > 0 AND octet_length(body) <= 4096),
    expected_revision BIGINT NOT NULL CHECK (expected_revision >= 0),
    resulting_revision BIGINT NOT NULL CHECK (resulting_revision > 0),
    room_sequence BIGINT NOT NULL CHECK (room_sequence > 0),
    event_id UUID NOT NULL UNIQUE,
    plan_id UUID NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (actor_user_id, operation_id)
);

ALTER TABLE im_v2.rooms
    ADD COLUMN group_permission_revision BIGINT NOT NULL DEFAULT 1 CHECK (group_permission_revision > 0);

CREATE TABLE im_v2.group_role_permissions (
    room_id UUID NOT NULL REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT,
    role TEXT NOT NULL CHECK (role IN ('admin', 'member')),
    permission TEXT NOT NULL CHECK (permission IN (
        'send_messages', 'invite_members', 'remove_members', 'change_member_roles',
        'pin_messages', 'manage_announcements', 'moderate_messages', 'mute_members'
    )),
    PRIMARY KEY (room_id, role, permission)
);

CREATE TABLE im_v2.group_permission_operations (
    actor_user_id UUID NOT NULL,
    operation_id UUID NOT NULL,
    room_id UUID NOT NULL REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT,
    expected_revision BIGINT NOT NULL CHECK (expected_revision > 0),
    resulting_revision BIGINT NOT NULL CHECK (resulting_revision > expected_revision),
    role TEXT NOT NULL CHECK (role IN ('admin', 'member')),
    permissions JSONB NOT NULL,
    room_sequence BIGINT NOT NULL CHECK (room_sequence > 0),
    event_id UUID NOT NULL UNIQUE,
    plan_id UUID NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (actor_user_id, operation_id)
);

CREATE TABLE im_v2.group_role_operations (
    actor_user_id UUID NOT NULL,
    operation_id UUID NOT NULL,
    room_id UUID NOT NULL REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT,
    target_user_id UUID NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('admin', 'member')),
    expected_membership_revision BIGINT NOT NULL CHECK (expected_membership_revision > 0),
    resulting_membership_revision BIGINT NOT NULL CHECK (resulting_membership_revision > expected_membership_revision),
    room_sequence BIGINT NOT NULL CHECK (room_sequence > 0),
    event_id UUID NOT NULL UNIQUE,
    plan_id UUID NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (actor_user_id, operation_id),
    CHECK (actor_user_id <> target_user_id)
);

-- Defaults preserve the established product behaviour while moving future
-- authorization checks onto a data-driven capability matrix.
INSERT INTO im_v2.group_role_permissions (room_id, role, permission)
SELECT room_id, role, permission
FROM im_v2.rooms
CROSS JOIN (VALUES
    ('admin'::TEXT, 'send_messages'::TEXT), ('admin', 'invite_members'),
    ('admin', 'remove_members'), ('admin', 'pin_messages'),
    ('admin', 'manage_announcements'), ('admin', 'moderate_messages'),
    ('admin', 'mute_members'), ('member', 'send_messages')
) AS defaults(role, permission)
WHERE room_kind = 'group';

-- Forwarded content remains a new message with a new sender and sequence.
-- Attribution is immutable metadata; it never grants future access to the
-- source room, its members, or the source attachment object.
ALTER TABLE im_v2.messages
    ADD COLUMN forwarded_from_message_id UUID NULL REFERENCES im_v2.messages(message_id) ON DELETE RESTRICT,
    ADD COLUMN forwarded_from_user_id UUID NULL;
CREATE INDEX messages_forwarded_from_idx
    ON im_v2.messages (forwarded_from_message_id) WHERE forwarded_from_message_id IS NOT NULL;

CREATE TABLE im_v2.message_forward_operations (
    actor_user_id UUID NOT NULL,
    operation_id UUID NOT NULL,
    source_message_id UUID NOT NULL REFERENCES im_v2.messages(message_id) ON DELETE RESTRICT,
    target_room_id UUID NOT NULL REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT,
    target_client_message_id UUID NOT NULL,
    result_message_id UUID NULL REFERENCES im_v2.messages(message_id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (actor_user_id, operation_id, source_message_id, target_room_id),
    UNIQUE (actor_user_id, target_client_message_id)
);
