-- Expand-only control-plane prerequisite for routing new groups to a durable
-- room owner. Apply on the control database before enabling multi-owner group
-- creation. Existing group creation remains unchanged until the application
-- saga is enabled.
CREATE TABLE IF NOT EXISTS im_v2.group_room_creation_intents (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    room_id uuid NOT NULL,
    event_id uuid NOT NULL,
    plan_id uuid NOT NULL,
    room_shard_id text NOT NULL CHECK (length(btrim(room_shard_id)) > 0),
    route_epoch bigint NOT NULL DEFAULT 0 CHECK (route_epoch >= 0),
    request_fingerprint bytea NOT NULL CHECK (octet_length(request_fingerprint) = 32),
    audience_member_count integer NOT NULL CHECK (
        audience_member_count BETWEEN 1 AND 100000
    ),
    state text NOT NULL DEFAULT 'prepared' CHECK (state IN ('prepared', 'committed')),
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    PRIMARY KEY (actor_user_id, operation_id),
    UNIQUE (room_id),
    UNIQUE (event_id),
    UNIQUE (plan_id)
);

CREATE TABLE IF NOT EXISTS im_v2.group_room_creation_intent_members (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    user_id uuid NOT NULL,
    created_at timestamp with time zone NOT NULL,
    PRIMARY KEY (actor_user_id, operation_id, user_id),
    FOREIGN KEY (actor_user_id, operation_id)
        REFERENCES im_v2.group_room_creation_intents(actor_user_id, operation_id)
        ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS im_v2.group_room_creation_intent_pages (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    page_number integer NOT NULL CHECK (page_number >= 0),
    member_count integer NOT NULL CHECK (member_count BETWEEN 1 AND 512),
    page_digest bytea NOT NULL CHECK (octet_length(page_digest) = 32),
    is_final boolean NOT NULL,
    created_at timestamp with time zone NOT NULL,
    PRIMARY KEY (actor_user_id, operation_id, page_number),
    FOREIGN KEY (actor_user_id, operation_id)
        REFERENCES im_v2.group_room_creation_intents(actor_user_id, operation_id)
        ON DELETE CASCADE
);

CREATE UNIQUE INDEX IF NOT EXISTS group_room_creation_intent_pages_final_key
    ON im_v2.group_room_creation_intent_pages (actor_user_id, operation_id)
    WHERE is_final;
