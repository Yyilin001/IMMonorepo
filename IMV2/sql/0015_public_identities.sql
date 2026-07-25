-- Public chat identity is separate from all account factors. Handles are
-- canonical lower-case values; no password/passkey/refresh data is joined
-- into this projection or returned by directory routes.

CREATE TABLE im_v2.public_user_profiles (
    user_id UUID PRIMARY KEY,
    public_handle TEXT NOT NULL UNIQUE
        CHECK (public_handle ~ '^[a-z0-9_]{3,32}$'),
    display_name TEXT NOT NULL
        CHECK (octet_length(display_name) BETWEEN 1 AND 80),
    revision BIGINT NOT NULL DEFAULT 1 CHECK (revision > 0),
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL
);

-- Cross-replica, authenticated directory lookup protection. The public HTTPS
-- edge must still enforce its own trusted client/IP policy before forwarding
-- to the loopback account service.
CREATE TABLE im_v2.public_identity_lookup_rate_limits (
    actor_user_id UUID PRIMARY KEY,
    window_started_at TIMESTAMPTZ NOT NULL,
    query_count INTEGER NOT NULL CHECK (query_count > 0),
    updated_at TIMESTAMPTZ NOT NULL
);
