-- Successful device issuance is independently budgeted per account. Edge/IP
-- limits remain useful for volumetric abuse, but only an account-scoped,
-- durable row can bound device/revocation/tombstone cardinality across account
-- service replicas and changing client addresses.

CREATE TABLE im_v2.device_registration_rate_limits (
    user_id UUID PRIMARY KEY,
    window_started_at TIMESTAMPTZ NOT NULL,
    successful_registrations INTEGER NOT NULL
        CHECK (successful_registrations > 0),
    updated_at TIMESTAMPTZ NOT NULL,
    CHECK (updated_at >= window_started_at)
);
