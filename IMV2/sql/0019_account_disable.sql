-- A human-approved account disable is an account-wide credential fence, not
-- deletion. Retained identity and message data remain subject to the separate
-- recovery/retention policy; this record makes authentication denial and the
-- operator audit fact durable and idempotent.
CREATE TABLE im_v2.account_disables (
    user_id UUID PRIMARY KEY,
    operation_id UUID NOT NULL UNIQUE,
    reason TEXT NOT NULL CHECK (reason IN ('user_requested', 'credential_compromise', 'policy_enforcement')),
    operator_principal TEXT NOT NULL CHECK (operator_principal ~ '^[A-Za-z0-9._:-]{1,128}$'),
    disabled_at TIMESTAMPTZ NOT NULL
);
