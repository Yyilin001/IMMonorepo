-- Account-owned device metadata and durable, idempotent remote-session
-- commands. Device IDs stay opaque; no authentication material is exposed.
ALTER TABLE im_v2.auth_devices
    ADD COLUMN display_name TEXT NOT NULL DEFAULT 'This device',
    ADD COLUMN platform TEXT NOT NULL DEFAULT 'Unknown',
    ADD COLUMN last_active_at TIMESTAMPTZ NULL,
    ADD CONSTRAINT auth_devices_display_name_length CHECK (octet_length(display_name) BETWEEN 1 AND 128),
    ADD CONSTRAINT auth_devices_platform_length CHECK (octet_length(platform) BETWEEN 1 AND 64);

UPDATE im_v2.auth_devices
SET last_active_at = created_at
WHERE last_active_at IS NULL;

ALTER TABLE im_v2.auth_devices
    ALTER COLUMN last_active_at SET NOT NULL;

CREATE INDEX auth_devices_active_sessions_idx
    ON im_v2.auth_devices (user_id, last_active_at DESC, device_id)
    WHERE revoked_at IS NULL;

CREATE TABLE im_v2.device_session_operations (
    actor_user_id UUID NOT NULL,
    operation_id UUID NOT NULL,
    operation_kind TEXT NOT NULL CHECK (operation_kind IN ('revoke_device', 'revoke_other_devices')),
    target_device_id UUID NULL,
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (actor_user_id, operation_id),
    CHECK (
        (operation_kind = 'revoke_device' AND target_device_id IS NOT NULL)
        OR (operation_kind = 'revoke_other_devices' AND target_device_id IS NULL)
    )
);
