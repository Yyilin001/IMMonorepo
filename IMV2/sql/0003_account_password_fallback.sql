-- V2 fallback factor. Passkeys remain the preferred factor; this table stores
-- only a deliberately slow password verifier, never a recoverable password.
-- Account handles are canonical ASCII values enforced by the service boundary.

CREATE TABLE im_v2.account_password_credentials (
    account_handle TEXT PRIMARY KEY
        CHECK (octet_length(account_handle) BETWEEN 3 AND 64),
    user_id UUID NOT NULL UNIQUE,
    password_hash TEXT NOT NULL
        CHECK (length(password_hash) BETWEEN 60 AND 255),
    created_at TIMESTAMPTZ NOT NULL
);
