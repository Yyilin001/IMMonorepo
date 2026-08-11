-- Special accounts remain normal chat identities for routing and projection,
-- but their classification and sending authority are server-owned facts.
-- No device credential or public gateway command grants this authority.

ALTER TABLE im_v2.public_user_profiles
    ADD COLUMN account_kind TEXT NOT NULL DEFAULT 'regular'
        CHECK (account_kind IN ('regular', 'system', 'customer_support'));

ALTER TABLE im_v2.public_profile_update_outbox
    ADD COLUMN account_kind TEXT NOT NULL DEFAULT 'regular'
        CHECK (account_kind IN ('regular', 'system', 'customer_support'));

CREATE TABLE im_v2.special_accounts (
    account_user_id UUID PRIMARY KEY REFERENCES im_v2.public_user_profiles(user_id) ON DELETE RESTRICT,
    stable_key TEXT NOT NULL UNIQUE CHECK (stable_key ~ '^[a-z][a-z0-9_]{2,63}$'),
    account_kind TEXT NOT NULL CHECK (account_kind IN ('system', 'customer_support')),
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'paused', 'retired')),
    allows_customer_messages BOOLEAN NOT NULL,
    allows_service_messages BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    CHECK ((account_kind = 'system' AND allows_customer_messages = FALSE)
        OR account_kind = 'customer_support')
);

CREATE TABLE im_v2.support_conversation_sessions (
    room_id UUID PRIMARY KEY REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT,
    support_account_user_id UUID NOT NULL REFERENCES im_v2.special_accounts(account_user_id) ON DELETE RESTRICT,
    customer_user_id UUID NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('open', 'assigned', 'waiting_customer', 'resolved', 'closed')),
    assigned_operator_id TEXT NULL CHECK (assigned_operator_id IS NULL OR length(assigned_operator_id) BETWEEN 1 AND 128),
    opened_at TIMESTAMPTZ NOT NULL,
    last_activity_at TIMESTAMPTZ NOT NULL,
    closed_at TIMESTAMPTZ NULL,
    CHECK ((state IN ('resolved', 'closed')) = (closed_at IS NOT NULL))
);
CREATE INDEX support_conversation_sessions_customer_idx
    ON im_v2.support_conversation_sessions (customer_user_id, last_activity_at DESC);

-- A service operation can be retried indefinitely without producing a second
-- customer-visible message. The request fingerprint is deliberately a digest
-- supplied by the trusted service boundary, never message text.
CREATE TABLE im_v2.special_account_message_operations (
    account_user_id UUID NOT NULL REFERENCES im_v2.special_accounts(account_user_id) ON DELETE RESTRICT,
    operation_id UUID NOT NULL,
    request_fingerprint TEXT NOT NULL CHECK (length(request_fingerprint) BETWEEN 16 AND 128),
    room_id UUID NOT NULL REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT,
    message_id UUID NULL REFERENCES im_v2.messages(message_id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (account_user_id, operation_id)
);

CREATE TABLE im_v2.special_account_message_audit (
    message_id UUID PRIMARY KEY REFERENCES im_v2.messages(message_id) ON DELETE RESTRICT,
    account_user_id UUID NOT NULL REFERENCES im_v2.special_accounts(account_user_id) ON DELETE RESTRICT,
    service_principal TEXT NOT NULL CHECK (length(service_principal) BETWEEN 1 AND 128),
    operator_id TEXT NULL CHECK (operator_id IS NULL OR length(operator_id) BETWEEN 1 AND 128),
    support_session_room_id UUID NULL REFERENCES im_v2.support_conversation_sessions(room_id) ON DELETE RESTRICT,
    content_fingerprint TEXT NOT NULL CHECK (length(content_fingerprint) BETWEEN 16 AND 128),
    created_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX special_account_message_audit_account_created_idx
    ON im_v2.special_account_message_audit (account_user_id, created_at DESC);

-- `direct_message_restricted` pre-dates account policy. Preserve those rows
-- and make the account-specific denial equally private and non-message-like.
ALTER TABLE im_v2.room_timeline_activities
    DROP CONSTRAINT IF EXISTS room_timeline_activities_activity_type_check;
ALTER TABLE im_v2.room_timeline_activities
    ADD CONSTRAINT room_timeline_activities_activity_type_check
    CHECK (activity_type IN ('direct_message_restricted', 'system_account_read_only'));

ALTER TABLE im_v2.direct_message_denials
    ADD COLUMN reason TEXT NOT NULL DEFAULT 'generic'
        CHECK (reason IN ('generic', 'system_account_read_only'));
