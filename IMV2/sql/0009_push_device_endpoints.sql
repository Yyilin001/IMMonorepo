-- Opaque Push provider endpoints are device-bound and encrypted by the
-- application. A provider rejection disables only the exact generation that
-- was sent, so a concurrent fresh registration is never accidentally removed.
CREATE TABLE im_v2.push_device_endpoints (
    device_id UUID NOT NULL REFERENCES im_v2.auth_devices(device_id) ON DELETE RESTRICT,
    provider TEXT NOT NULL CHECK (provider IN ('apns')),
    environment TEXT NOT NULL CHECK (environment IN ('development', 'production')),
    endpoint_generation UUID NOT NULL,
    encrypted_token TEXT NOT NULL CHECK (length(encrypted_token) > 0),
    updated_at TIMESTAMPTZ NOT NULL,
    disabled_at TIMESTAMPTZ NULL,
    PRIMARY KEY (device_id, provider)
);

CREATE INDEX push_device_endpoints_active_idx
    ON im_v2.push_device_endpoints (device_id, updated_at DESC)
    WHERE disabled_at IS NULL;
