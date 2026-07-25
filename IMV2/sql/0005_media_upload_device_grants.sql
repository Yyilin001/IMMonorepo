-- Upload authorization is device-bound before an object-provider target can
-- be issued. This is separate from the durable media object: provider targets
-- and signed headers remain memory-only at the media edge.
ALTER TABLE im_v2.media_upload_operations
    ADD COLUMN requesting_device_id UUID NOT NULL;

ALTER TABLE im_v2.media_upload_operations
    ADD CONSTRAINT media_upload_operations_requesting_device_fk
    FOREIGN KEY (actor_user_id, requesting_device_id)
    REFERENCES im_v2.auth_devices(user_id, device_id) ON DELETE RESTRICT;

CREATE TABLE im_v2.media_upload_grants (
    upload_session_id UUID PRIMARY KEY REFERENCES im_v2.media_objects(upload_session_id) ON DELETE CASCADE,
    media_id UUID NOT NULL REFERENCES im_v2.media_objects(media_id) ON DELETE CASCADE,
    user_id UUID NOT NULL,
    device_id UUID NOT NULL,
    content_type TEXT NOT NULL CHECK (octet_length(content_type) > 0 AND octet_length(content_type) <= 127),
    byte_count BIGINT NOT NULL CHECK (byte_count > 0),
    expires_at TIMESTAMPTZ NOT NULL,
    state TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'claimed', 'consumed')),
    claim_token UUID NULL,
    lease_expires_at TIMESTAMPTZ NULL,
    retry_count BIGINT NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
    redeemed_at TIMESTAMPTZ NULL,
    created_at TIMESTAMPTZ NOT NULL,
    FOREIGN KEY (user_id, device_id)
        REFERENCES im_v2.auth_devices(user_id, device_id) ON DELETE RESTRICT,
    CHECK (expires_at > created_at),
    CHECK ((state = 'claimed') = (claim_token IS NOT NULL)),
    CHECK ((state = 'claimed') = (lease_expires_at IS NOT NULL)),
    CHECK ((state = 'consumed') = (redeemed_at IS NOT NULL))
);
CREATE INDEX media_upload_grants_claim_idx
    ON im_v2.media_upload_grants (state, lease_expires_at, expires_at)
    WHERE state <> 'consumed';
