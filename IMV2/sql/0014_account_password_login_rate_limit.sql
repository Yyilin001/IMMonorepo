-- Authoritative, cross-replica failure state for the password fallback.
-- This is intentionally keyed by the canonical account handle rather than a
-- caller-supplied network header. Public ingress must additionally enforce
-- its own trusted-client/IP limit before it reaches the loopback account
-- service.

CREATE TABLE im_v2.account_password_login_rate_limits (
    account_handle TEXT PRIMARY KEY
        CHECK (octet_length(account_handle) BETWEEN 3 AND 64),
    window_started_at TIMESTAMPTZ NOT NULL,
    failure_count INTEGER NOT NULL
        CHECK (failure_count > 0),
    blocked_until TIMESTAMPTZ NULL,
    updated_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX account_password_login_rate_limits_blocked_until_idx
    ON im_v2.account_password_login_rate_limits (blocked_until)
    WHERE blocked_until IS NOT NULL;
