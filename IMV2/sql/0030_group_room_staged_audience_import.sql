-- Bounded staged creation audience. A draft freezes before the existing
-- atomic group bootstrap runs, so a 100k audience never has to fit one frame.
CREATE TABLE im_v2.group_room_creation_drafts (
    actor_user_id UUID NOT NULL,
    operation_id UUID NOT NULL,
    title TEXT NOT NULL CHECK (octet_length(title) BETWEEN 1 AND 120),
    state TEXT NOT NULL CHECK (state IN ('staging', 'finalizing', 'completed')),
    room_id UUID NULL UNIQUE REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (actor_user_id, operation_id),
    CHECK ((state = 'completed') = (room_id IS NOT NULL))
);

CREATE TABLE im_v2.group_room_creation_draft_members (
    actor_user_id UUID NOT NULL,
    operation_id UUID NOT NULL,
    user_id UUID NOT NULL,
    PRIMARY KEY (actor_user_id, operation_id, user_id),
    FOREIGN KEY (actor_user_id, operation_id)
        REFERENCES im_v2.group_room_creation_drafts(actor_user_id, operation_id)
        ON DELETE CASCADE,
    CHECK (user_id <> actor_user_id)
);

-- Expiry cleanup is deliberately indexed independently from actor-local
-- admission. It lets maintenance workers reclaim abandoned draft audiences
-- without scanning completed or active imports.
CREATE INDEX group_room_creation_drafts_expiry_idx
    ON im_v2.group_room_creation_drafts (state, expires_at);
CREATE INDEX group_room_creation_drafts_actor_state_idx
    ON im_v2.group_room_creation_drafts (actor_user_id, state, expires_at);
