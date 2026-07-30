-- Profile writes are whole-state, revision-fenced operations. The ledger
-- preserves an exact successful outcome for an HTTP retry after response
-- loss; it does not store a media URL or any copied presentation data.

CREATE TABLE im_v2.public_profile_update_operations (
    actor_user_id UUID NOT NULL,
    operation_id UUID NOT NULL,
    expected_revision BIGINT NOT NULL CHECK (expected_revision > 0),
    requested_display_name TEXT NOT NULL CHECK (octet_length(requested_display_name) BETWEEN 1 AND 240),
    requested_avatar_media_id UUID NULL,
    result_revision BIGINT NOT NULL CHECK (result_revision > 0),
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (actor_user_id, operation_id)
);
