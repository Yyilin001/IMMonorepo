-- Expand-only prerequisite for physical room-store routing. Apply to the
-- control database before enabling IM_V2_ROOM_SHARD_STORES_JSON. Existing
-- rooms continue to resolve from im_v2.rooms until an explicit migration
-- records their route.
CREATE TABLE IF NOT EXISTS im_v2.room_owner_routes (
    room_id uuid PRIMARY KEY,
    room_shard_id text NOT NULL CHECK (length(btrim(room_shard_id)) > 0),
    route_epoch bigint NOT NULL DEFAULT 0 CHECK (route_epoch >= 0),
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);

CREATE TABLE IF NOT EXISTS im_v2.direct_room_owner_routes (
    lower_user_id uuid NOT NULL,
    higher_user_id uuid NOT NULL,
    room_id uuid NOT NULL UNIQUE,
    room_shard_id text NOT NULL CHECK (length(btrim(room_shard_id)) > 0),
    route_epoch bigint NOT NULL DEFAULT 0 CHECK (route_epoch >= 0),
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    PRIMARY KEY (lower_user_id, higher_user_id),
    CHECK (lower_user_id::text < higher_user_id::text)
);
