-- V2 Auth service: device-bound refresh-session families and bounded replay
-- records. The raw access/refresh values are never stored in cleartext. The
-- issuer persists only HMAC digests for validation and envelope-encrypted
-- successor values for the exact refresh-operation replay window.

CREATE TABLE im_v2.device_refresh_sessions (
    user_id UUID NOT NULL,
    device_id UUID PRIMARY KEY,
    family_generation BIGINT NOT NULL DEFAULT 1 CHECK (family_generation > 0),
    refresh_hmac TEXT NOT NULL CHECK (length(refresh_hmac) = 64),
    issued_at TIMESTAMPTZ NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ NULL,
    FOREIGN KEY (user_id, device_id)
        REFERENCES im_v2.auth_devices(user_id, device_id) ON DELETE RESTRICT,
    CHECK (expires_at > issued_at)
);
CREATE UNIQUE INDEX device_refresh_sessions_active_refresh_hmac_idx
    ON im_v2.device_refresh_sessions (refresh_hmac)
    WHERE revoked_at IS NULL;

CREATE TABLE im_v2.device_credential_operations (
    device_id UUID NOT NULL REFERENCES im_v2.auth_devices(device_id) ON DELETE RESTRICT,
    operation_id UUID NOT NULL,
    operation_kind TEXT NOT NULL CHECK (operation_kind IN ('registration', 'refresh')),
    user_id UUID NOT NULL,
    request_refresh_hmac TEXT NULL CHECK (request_refresh_hmac IS NULL OR length(request_refresh_hmac) = 64),
    resulting_access_token_hmac TEXT NOT NULL CHECK (length(resulting_access_token_hmac) = 64),
    encrypted_access_token TEXT NOT NULL,
    encrypted_refresh_credential TEXT NOT NULL,
    access_token_expires_at TIMESTAMPTZ NOT NULL,
    replay_expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (device_id, operation_id),
    CHECK (replay_expires_at >= created_at)
);
CREATE INDEX device_credential_operations_replay_idx
    ON im_v2.device_credential_operations (device_id, replay_expires_at);
