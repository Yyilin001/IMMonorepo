-- Ephemeral activity has a narrow durable boundary: privacy preferences and
-- short device connection leases. Typing itself is never persisted here.
CREATE TABLE im_v2.user_live_activity_preferences (
    user_id UUID PRIMARY KEY,
    allows_online_presence BOOLEAN NOT NULL DEFAULT TRUE,
    allows_typing_indicators BOOLEAN NOT NULL DEFAULT TRUE,
    updated_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE im_v2.user_live_activity_preference_operations (
    actor_user_id UUID NOT NULL,
    operation_id UUID NOT NULL,
    allows_online_presence BOOLEAN NOT NULL,
    allows_typing_indicators BOOLEAN NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (actor_user_id, operation_id)
);

CREATE TABLE im_v2.user_live_presence_leases (
    connection_id UUID PRIMARY KEY,
    user_id UUID NOT NULL,
    device_id UUID NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    FOREIGN KEY (user_id, device_id)
        REFERENCES im_v2.auth_devices(user_id, device_id) ON DELETE RESTRICT
);

CREATE INDEX user_live_presence_leases_lookup_idx
    ON im_v2.user_live_presence_leases (user_id, expires_at DESC);
