-- Pseudonymous, cross-replica request budget for the authenticated account
-- HTTPS edge. `client_key` is an HMAC digest of a Caddy-validated source
-- address, never the address itself. This is an expensive-endpoint guard, not
-- an audit or identity record.

CREATE TABLE im_v2.account_edge_client_rate_limits (
    client_key TEXT PRIMARY KEY
        CHECK (octet_length(client_key) = 64),
    window_started_at TIMESTAMPTZ NOT NULL,
    request_count INTEGER NOT NULL
        CHECK (request_count > 0),
    updated_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX account_edge_client_rate_limits_updated_at_idx
    ON im_v2.account_edge_client_rate_limits (updated_at);
