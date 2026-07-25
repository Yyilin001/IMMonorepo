-- Security-audit facts for the password fallback factor.  This intentionally
-- contains neither an account handle nor a password/hash: a rejected request
-- remains non-enumerating even to ordinary audit readers.  `user_id` exists
-- only when the factor route already resolved a valid credential.

CREATE TABLE im_v2.account_password_authentication_audit (
    event_id UUID PRIMARY KEY,
    outcome TEXT NOT NULL CHECK (outcome IN (
        'registration_succeeded',
        'assertion_succeeded',
        'assertion_rejected'
    )),
    user_id UUID NULL,
    device_id UUID NOT NULL,
    occurred_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX account_password_authentication_audit_user_occurred_idx
    ON im_v2.account_password_authentication_audit (user_id, occurred_at DESC)
    WHERE user_id IS NOT NULL;

CREATE INDEX account_password_authentication_audit_device_occurred_idx
    ON im_v2.account_password_authentication_audit (device_id, occurred_at DESC);
