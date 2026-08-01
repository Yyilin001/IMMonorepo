-- IM V2 initial PostgreSQL schema.
-- This schema is an independent implementation baseline and deliberately does
-- not share V1 tables, event payloads, or cursor semantics.

CREATE SCHEMA IF NOT EXISTS im_v2;

-- Authentication is V2-owned and device-bound. Access tokens are high-entropy
-- opaque credentials, only an HMAC digest is persisted, so an ordinary DB
-- read cannot be replayed as a bearer token.
CREATE TABLE im_v2.auth_devices (
    user_id UUID NOT NULL,
    device_id UUID NOT NULL,
    revoked_at TIMESTAMPTZ NULL,
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (user_id, device_id),
    UNIQUE (device_id)
);

CREATE TABLE im_v2.device_access_tokens (
    token_hmac TEXT PRIMARY KEY CHECK (length(token_hmac) = 64),
    user_id UUID NOT NULL,
    device_id UUID NOT NULL,
    issued_at TIMESTAMPTZ NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ NULL,
    FOREIGN KEY (user_id, device_id) REFERENCES im_v2.auth_devices(user_id, device_id) ON DELETE RESTRICT,
    CHECK (expires_at > issued_at)
);
CREATE INDEX device_access_tokens_active_idx
    ON im_v2.device_access_tokens (device_id, expires_at)
    WHERE revoked_at IS NULL;

-- Device revocation must reach every gateway replica holding a live socket.
-- Each replica consumes this append-only stream with its own durable cursor.
CREATE TABLE im_v2.device_revocation_events (
    event_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id UUID NOT NULL,
    device_id UUID NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL,
    FOREIGN KEY (user_id, device_id) REFERENCES im_v2.auth_devices(user_id, device_id) ON DELETE RESTRICT
);

CREATE TABLE im_v2.gateway_worker_cursors (
    worker_name TEXT NOT NULL,
    node_id TEXT NOT NULL,
    last_event_id BIGINT NOT NULL DEFAULT 0 CHECK (last_event_id >= 0),
    updated_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (worker_name, node_id)
);

CREATE TABLE im_v2.rooms (
    room_id UUID PRIMARY KEY,
    room_kind TEXT NOT NULL DEFAULT 'group' CHECK (room_kind IN ('group', 'direct')),
    room_shard_id TEXT NOT NULL,
    room_sequence BIGINT NOT NULL DEFAULT 0 CHECK (room_sequence >= 0),
    membership_revision BIGINT NOT NULL DEFAULT 0 CHECK (membership_revision >= 0),
    capacity_profile_id TEXT NOT NULL,
    frozen_at TIMESTAMPTZ NULL,
    frozen_by_user_id UUID NULL,
    CHECK ((frozen_at IS NULL AND frozen_by_user_id IS NULL) OR (frozen_at IS NOT NULL AND frozen_by_user_id IS NOT NULL)),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- A direct room is unique per unordered pair. The pair is intentionally
-- separate from rooms so room routing/admission remains a room concern while
-- direct-message policy can lock one canonical pair.
CREATE TABLE im_v2.direct_room_pairs (
    lower_user_id UUID NOT NULL,
    higher_user_id UUID NOT NULL,
    room_id UUID NOT NULL UNIQUE REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (lower_user_id, higher_user_id),
    CHECK (lower_user_id < higher_user_id)
);

CREATE TABLE im_v2.direct_room_operations (
    actor_user_id UUID NOT NULL,
    operation_id UUID NOT NULL,
    target_user_id UUID NOT NULL,
    room_id UUID NOT NULL REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (actor_user_id, operation_id)
);

-- Relationship and block state are authoritative input to direct-message
-- admission. Pair mutations use durable per-actor operations so a lost reply
-- cannot duplicate a request, acceptance, removal, block, or unblock.
CREATE TABLE im_v2.user_relationships (
    lower_user_id UUID NOT NULL,
    higher_user_id UUID NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('pending', 'accepted')),
    requested_by_user_id UUID NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (lower_user_id, higher_user_id),
    CHECK (lower_user_id < higher_user_id),
    CHECK (requested_by_user_id = lower_user_id OR requested_by_user_id = higher_user_id)
);

CREATE TABLE im_v2.user_relationship_operations (
    actor_user_id UUID NOT NULL,
    operation_id UUID NOT NULL,
    target_user_id UUID NOT NULL,
    action TEXT NOT NULL CHECK (action IN ('request', 'accept', 'reject', 'remove')),
    resulting_state TEXT NOT NULL CHECK (resulting_state IN ('none', 'pending', 'accepted')),
    updated_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (actor_user_id, operation_id),
    CHECK (actor_user_id <> target_user_id)
);

CREATE TABLE im_v2.user_blocks (
    blocker_user_id UUID NOT NULL,
    blocked_user_id UUID NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (blocker_user_id, blocked_user_id),
    CHECK (blocker_user_id <> blocked_user_id)
);

CREATE TABLE im_v2.user_block_operations (
    actor_user_id UUID NOT NULL,
    operation_id UUID NOT NULL,
    target_user_id UUID NOT NULL,
    action TEXT NOT NULL CHECK (action IN ('block', 'unblock')),
    is_blocked BOOLEAN NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (actor_user_id, operation_id),
    CHECK (actor_user_id <> target_user_id),
    CHECK ((action = 'block' AND is_blocked) OR (action = 'unblock' AND NOT is_blocked))
);

CREATE TABLE im_v2.user_stranger_message_preferences (
    user_id UUID PRIMARY KEY,
    allows_stranger_messages BOOLEAN NOT NULL DEFAULT TRUE,
    updated_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE im_v2.stranger_message_preference_operations (
    actor_user_id UUID NOT NULL,
    operation_id UUID NOT NULL,
    allows_stranger_messages BOOLEAN NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (actor_user_id, operation_id)
);

-- One mutable window per directed stranger pair. The accepted-message
-- transaction increments it, so a lost response cannot consume quota twice.
CREATE TABLE im_v2.stranger_message_windows (
    sender_user_id UUID NOT NULL,
    recipient_user_id UUID NOT NULL,
    window_started_at TIMESTAMPTZ NOT NULL,
    message_count INTEGER NOT NULL CHECK (message_count > 0),
    PRIMARY KEY (sender_user_id, recipient_user_id),
    CHECK (sender_user_id <> recipient_user_id)
);

CREATE TABLE im_v2.room_memberships (
    room_id UUID NOT NULL REFERENCES im_v2.rooms(room_id),
    user_id UUID NOT NULL,
    role TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('owner', 'admin', 'member')),
    joined_revision BIGINT NOT NULL CHECK (joined_revision >= 0),
    left_revision BIGINT NULL CHECK (left_revision IS NULL OR left_revision >= joined_revision),
    PRIMARY KEY (room_id, user_id, joined_revision)
);
CREATE INDEX room_memberships_eligible_at_revision_idx
    ON im_v2.room_memberships (room_id, joined_revision, left_revision, user_id);

-- A mute is authoritative admission state rather than a notification/UI hint.
-- Expired rows are harmless to the hot path (which checks `mute_until > now`)
-- and can be pruned by the retention worker after the audit replay window.
CREATE TABLE im_v2.room_member_mutes (
    room_id UUID NOT NULL REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT,
    user_id UUID NOT NULL,
    mute_until TIMESTAMPTZ NOT NULL,
    actor_user_id UUID NOT NULL,
    operation_id UUID NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (room_id, user_id),
    UNIQUE (actor_user_id, operation_id),
    CHECK (mute_until > created_at)
);
CREATE INDEX room_member_mutes_active_idx
    ON im_v2.room_member_mutes (room_id, user_id, mute_until);

-- A membership mutation is a durable client operation. Its canonical result
-- survives a lost gateway response and is checked before current authorization
-- so an actor who later loses room access can still replay the completed operation.
CREATE TABLE im_v2.room_membership_operations (
    actor_user_id UUID NOT NULL,
    operation_id UUID NOT NULL,
    room_id UUID NOT NULL REFERENCES im_v2.rooms(room_id),
    target_user_id UUID NOT NULL,
    action TEXT NOT NULL CHECK (action IN ('add', 'remove')),
    expected_membership_revision BIGINT NOT NULL CHECK (expected_membership_revision >= 0),
    resulting_membership_revision BIGINT NOT NULL CHECK (resulting_membership_revision >= 0),
    room_sequence BIGINT NOT NULL CHECK (room_sequence > 0),
    event_id UUID NOT NULL UNIQUE,
    plan_id UUID NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (actor_user_id, operation_id)
);

CREATE TABLE im_v2.shard_admission_pools (
    room_shard_id TEXT NOT NULL,
    capacity_profile_id TEXT NOT NULL,
    lease_id UUID NOT NULL,
    generation BIGINT NOT NULL CHECK (generation > 0),
    valid_until TIMESTAMPTZ NOT NULL,
    command_window_limit BIGINT NOT NULL CHECK (command_window_limit >= 0),
    command_window_used BIGINT NOT NULL DEFAULT 0 CHECK (command_window_used >= 0),
    fanout_window_limit BIGINT NOT NULL CHECK (fanout_window_limit >= 0),
    fanout_window_used BIGINT NOT NULL DEFAULT 0 CHECK (fanout_window_used >= 0),
    max_outstanding_fanout_units BIGINT NOT NULL CHECK (max_outstanding_fanout_units >= 0),
    outstanding_fanout_units BIGINT NOT NULL DEFAULT 0 CHECK (outstanding_fanout_units >= 0),
    max_outstanding_plans BIGINT NOT NULL CHECK (max_outstanding_plans >= 0),
    outstanding_plans BIGINT NOT NULL DEFAULT 0 CHECK (outstanding_plans >= 0),
    PRIMARY KEY (room_shard_id, capacity_profile_id),
    UNIQUE (lease_id, generation),
    CHECK (command_window_used <= command_window_limit),
    CHECK (fanout_window_used <= fanout_window_limit),
    CHECK (outstanding_fanout_units <= max_outstanding_fanout_units),
    CHECK (outstanding_plans <= max_outstanding_plans)
);

CREATE TABLE im_v2.room_admission (
    room_id UUID PRIMARY KEY REFERENCES im_v2.rooms(room_id),
    eligible_member_count BIGINT NOT NULL DEFAULT 0 CHECK (eligible_member_count >= 0),
    command_window_limit BIGINT NOT NULL CHECK (command_window_limit >= 0),
    command_window_used BIGINT NOT NULL DEFAULT 0 CHECK (command_window_used >= 0),
    fanout_window_limit BIGINT NOT NULL CHECK (fanout_window_limit >= 0),
    fanout_window_used BIGINT NOT NULL DEFAULT 0 CHECK (fanout_window_used >= 0),
    max_outstanding_fanout_units BIGINT NOT NULL CHECK (max_outstanding_fanout_units >= 0),
    outstanding_fanout_units BIGINT NOT NULL DEFAULT 0 CHECK (outstanding_fanout_units >= 0),
    max_outstanding_plans BIGINT NOT NULL CHECK (max_outstanding_plans >= 0),
    outstanding_plans BIGINT NOT NULL DEFAULT 0 CHECK (outstanding_plans >= 0),
    shard_lease_id UUID NOT NULL,
    shard_lease_generation BIGINT NOT NULL CHECK (shard_lease_generation > 0),
    FOREIGN KEY (shard_lease_id, shard_lease_generation)
        REFERENCES im_v2.shard_admission_pools (lease_id, generation)
        ON UPDATE CASCADE,
    CHECK (command_window_used <= command_window_limit),
    CHECK (fanout_window_used <= fanout_window_limit),
    CHECK (outstanding_fanout_units <= max_outstanding_fanout_units),
    CHECK (outstanding_plans <= max_outstanding_plans)
);

CREATE TABLE im_v2.messages (
    message_id UUID PRIMARY KEY,
    room_id UUID NOT NULL REFERENCES im_v2.rooms(room_id),
    room_sequence BIGINT NOT NULL CHECK (room_sequence > 0),
    sender_user_id UUID NOT NULL,
    client_message_id UUID NOT NULL,
    -- Core validates that a message has text or at least one media reference.
    -- SQL permits an empty text body so an attachment-only message can commit.
    text_body TEXT NOT NULL,
    content_revision BIGINT NOT NULL DEFAULT 1 CHECK (content_revision > 0),
    withdrawn_at TIMESTAMPTZ NULL,
    withdrawn_by_user_id UUID NULL,
    created_at TIMESTAMPTZ NOT NULL,
    UNIQUE (room_id, room_sequence),
    UNIQUE (sender_user_id, client_message_id),
    CHECK ((withdrawn_at IS NULL AND withdrawn_by_user_id IS NULL) OR (withdrawn_at IS NOT NULL AND withdrawn_by_user_id IS NOT NULL))
);
CREATE INDEX messages_room_sender_idx ON im_v2.messages (room_id, sender_user_id);

-- Media bytes live behind a separate upload/download edge. The chat database
-- keeps only ownership, scan lifecycle, and opaque upload-session identity.
CREATE TABLE im_v2.media_objects (
    media_id UUID PRIMARY KEY,
    owner_user_id UUID NOT NULL,
    content_type TEXT NOT NULL CHECK (octet_length(content_type) > 0 AND octet_length(content_type) <= 127),
    byte_count BIGINT NOT NULL CHECK (byte_count > 0),
    state TEXT NOT NULL CHECK (state IN ('pending_upload', 'scanning', 'available', 'failed', 'expired')),
    upload_session_id UUID NOT NULL UNIQUE,
    expires_at TIMESTAMPTZ NOT NULL,
    state_updated_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX media_objects_owner_state_idx ON im_v2.media_objects (owner_user_id, state, expires_at);

CREATE TABLE im_v2.media_upload_operations (
    actor_user_id UUID NOT NULL,
    operation_id UUID NOT NULL,
    media_id UUID NOT NULL REFERENCES im_v2.media_objects(media_id),
    content_type TEXT NOT NULL,
    byte_count BIGINT NOT NULL CHECK (byte_count > 0),
    upload_session_id UUID NOT NULL UNIQUE,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (actor_user_id, operation_id)
);

-- Upload completion cannot make bytes referenceable on its own. It creates a
-- retryable scanner job; only the scanner worker can transition `scanning` to
-- `available` or `failed`.
CREATE TABLE im_v2.media_scan_outbox (
    media_id UUID PRIMARY KEY REFERENCES im_v2.media_objects(media_id),
    state TEXT NOT NULL CHECK (state IN ('pending', 'claimed', 'completed')),
    claim_token UUID NULL,
    lease_expires_at TIMESTAMPTZ NULL,
    retry_count BIGINT NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
    created_at TIMESTAMPTZ NOT NULL,
    completed_at TIMESTAMPTZ NULL,
    CHECK ((state = 'claimed') = (claim_token IS NOT NULL)),
    CHECK ((state = 'claimed') = (lease_expires_at IS NOT NULL)),
    CHECK ((state = 'completed') = (completed_at IS NOT NULL))
);
CREATE INDEX media_scan_outbox_claim_idx
    ON im_v2.media_scan_outbox (state, lease_expires_at, created_at)
    WHERE state <> 'completed';

-- A grant is an opaque hand-off to the separate media edge. It contains no
-- provider URL or object token. Grant issuance re-authorizes the active
-- device, current room membership, and delivered message visibility; old
-- grants naturally expire and are not an object-URL revocation mechanism.
CREATE TABLE im_v2.media_download_grants (
    download_session_id UUID PRIMARY KEY,
    media_id UUID NOT NULL REFERENCES im_v2.media_objects(media_id),
    user_id UUID NOT NULL,
    device_id UUID NOT NULL,
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
CREATE INDEX media_download_grants_expiry_idx
    ON im_v2.media_download_grants (expires_at);
CREATE INDEX media_download_grants_claim_idx
    ON im_v2.media_download_grants (state, lease_expires_at, expires_at)
    WHERE state <> 'consumed';

-- Provider-byte deletion is an independently retryable side effect. The
-- outbox carries only an opaque media ID and a policy reason, never an object
-- key, URL, filename, or bearer credential.
CREATE TABLE im_v2.media_purge_outbox (
    media_id UUID PRIMARY KEY REFERENCES im_v2.media_objects(media_id),
    reason TEXT NOT NULL CHECK (reason IN ('unreferenced_expired', 'withdrawn_retention_elapsed')),
    state TEXT NOT NULL CHECK (state IN ('pending', 'claimed', 'completed')),
    claim_token UUID NULL,
    lease_expires_at TIMESTAMPTZ NULL,
    retry_count BIGINT NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
    created_at TIMESTAMPTZ NOT NULL,
    completed_at TIMESTAMPTZ NULL
);
CREATE INDEX media_purge_outbox_claim_idx
    ON im_v2.media_purge_outbox (state, lease_expires_at, created_at)
    WHERE state <> 'completed';

-- Added by the message acceptance transaction only after it has verified the
-- media object is available. Withdrawal prevents later download grants but
-- does not erase a device that already downloaded the byte object.
CREATE TABLE im_v2.message_media_references (
    message_id UUID NOT NULL REFERENCES im_v2.messages(message_id),
    media_id UUID NOT NULL REFERENCES im_v2.media_objects(media_id),
    ordinal SMALLINT NOT NULL CHECK (ordinal >= 0),
    referenced_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ NULL,
    PRIMARY KEY (message_id, media_id),
    UNIQUE (message_id, ordinal)
);

-- Mention targets are frozen at message acceptance. `everyone` has no user
-- ID; individual targets are the only rows that can drive a private notice.
CREATE TABLE im_v2.message_mentions (
    message_id UUID NOT NULL REFERENCES im_v2.messages(message_id),
    ordinal SMALLINT NOT NULL CHECK (ordinal >= 0),
    mention_kind TEXT NOT NULL CHECK (mention_kind IN ('user', 'everyone')),
    mentioned_user_id UUID NULL,
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (message_id, ordinal),
    CHECK ((mention_kind = 'user' AND mentioned_user_id IS NOT NULL) OR (mention_kind = 'everyone' AND mentioned_user_id IS NULL))
);
CREATE UNIQUE INDEX message_mentions_unique_user_idx
    ON im_v2.message_mentions (message_id, mentioned_user_id)
    WHERE mentioned_user_id IS NOT NULL;
CREATE UNIQUE INDEX message_mentions_one_everyone_idx
    ON im_v2.message_mentions (message_id)
    WHERE mention_kind = 'everyone';

-- Durable withdrawal replay stores the canonical tombstone result separately
-- from message content. A retry after a lost response never authorizes or
-- modifies the message for a second time.
CREATE TABLE im_v2.message_withdrawal_operations (
    actor_user_id UUID NOT NULL,
    operation_id UUID NOT NULL,
    room_id UUID NOT NULL REFERENCES im_v2.rooms(room_id),
    message_id UUID NOT NULL REFERENCES im_v2.messages(message_id),
    expected_message_revision BIGINT NOT NULL CHECK (expected_message_revision > 0),
    resulting_message_revision BIGINT NOT NULL CHECK (resulting_message_revision > 0),
    room_sequence BIGINT NOT NULL CHECK (room_sequence > 0),
    event_id UUID NOT NULL UNIQUE,
    plan_id UUID NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (actor_user_id, operation_id)
);

-- Moderation is a distinct, auditable authority path. The command result is
-- replayed independently from an author's ordinary withdrawal operation; the
-- audit row deliberately stores identifiers and a bounded policy code only.
CREATE TABLE im_v2.moderation_operations (
    actor_user_id UUID NOT NULL,
    operation_id UUID NOT NULL,
    room_id UUID NOT NULL REFERENCES im_v2.rooms(room_id),
    action TEXT NOT NULL CHECK (action IN ('redact_message', 'remove_member', 'mute_member', 'freeze_room', 'unfreeze_room')),
    target_user_id UUID NULL,
    message_id UUID NULL REFERENCES im_v2.messages(message_id),
    resulting_message_revision BIGINT NULL CHECK (resulting_message_revision > 0),
    resulting_membership_revision BIGINT NULL CHECK (resulting_membership_revision > 0),
    mute_until TIMESTAMPTZ NULL,
    reason_code TEXT NOT NULL CHECK (octet_length(reason_code) > 0 AND octet_length(reason_code) <= 64),
    room_sequence BIGINT NOT NULL CHECK (room_sequence > 0),
    event_id UUID NOT NULL UNIQUE,
    plan_id UUID NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (actor_user_id, operation_id),
    CHECK (
        (action = 'redact_message' AND target_user_id IS NULL AND message_id IS NOT NULL AND mute_until IS NULL)
        OR (action IN ('remove_member', 'mute_member') AND target_user_id IS NOT NULL AND message_id IS NULL)
        OR (action IN ('freeze_room', 'unfreeze_room') AND target_user_id IS NULL AND message_id IS NULL AND mute_until IS NULL)
    ),
    CHECK ((action = 'mute_member' AND mute_until IS NOT NULL) OR (action <> 'mute_member' AND mute_until IS NULL)),
    CHECK ((action = 'redact_message' AND resulting_message_revision IS NOT NULL) OR (action <> 'redact_message' AND resulting_message_revision IS NULL)),
    CHECK ((action = 'remove_member' AND resulting_membership_revision IS NOT NULL) OR (action <> 'remove_member' AND resulting_membership_revision IS NULL))
);
CREATE TABLE im_v2.moderation_audit_entries (
    actor_user_id UUID NOT NULL,
    operation_id UUID NOT NULL,
    room_id UUID NOT NULL REFERENCES im_v2.rooms(room_id),
    action TEXT NOT NULL,
    target_user_id UUID NULL,
    message_id UUID NULL,
    reason_code TEXT NOT NULL,
    occurred_at TIMESTAMPTZ NOT NULL,
    retain_until TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (actor_user_id, operation_id),
    FOREIGN KEY (actor_user_id, operation_id)
        REFERENCES im_v2.moderation_operations (actor_user_id, operation_id)
);
CREATE INDEX moderation_audit_retention_idx ON im_v2.moderation_audit_entries (retain_until);

-- Durable edit replay stores both the immutable request fence and canonical
-- resulting content.  A retry returns the first committed result instead of
-- re-authorizing or applying a second edit.
CREATE TABLE im_v2.message_edit_operations (
    actor_user_id UUID NOT NULL,
    operation_id UUID NOT NULL,
    room_id UUID NOT NULL REFERENCES im_v2.rooms(room_id),
    message_id UUID NOT NULL REFERENCES im_v2.messages(message_id),
    expected_message_revision BIGINT NOT NULL CHECK (expected_message_revision > 0),
    text_body TEXT NOT NULL CHECK (octet_length(text_body) > 0),
    resulting_message_revision BIGINT NOT NULL CHECK (resulting_message_revision > 0),
    room_sequence BIGINT NOT NULL CHECK (room_sequence > 0),
    event_id UUID NOT NULL UNIQUE,
    plan_id UUID NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (actor_user_id, operation_id)
);

-- Explicit human-viewing state. It is never updated by SYNC_ACK and is
-- monotonic per user/room, and operation rows make lost client responses safe.
CREATE TABLE im_v2.room_read_receipts (
    room_id UUID NOT NULL REFERENCES im_v2.rooms(room_id),
    user_id UUID NOT NULL,
    read_through_room_sequence BIGINT NOT NULL CHECK (read_through_room_sequence > 0),
    updated_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (room_id, user_id)
);
CREATE TABLE im_v2.read_receipt_operations (
    user_id UUID NOT NULL,
    operation_id UUID NOT NULL,
    room_id UUID NOT NULL REFERENCES im_v2.rooms(room_id),
    requested_room_sequence BIGINT NOT NULL CHECK (requested_room_sequence > 0),
    resulting_room_sequence BIGINT NOT NULL CHECK (resulting_room_sequence > 0),
    recorded_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (user_id, operation_id)
);

-- Reactions are independent set members. The three-column key allows
-- concurrent actors/reactions without a message-content revision conflict.
CREATE TABLE im_v2.message_reactions (
    message_id UUID NOT NULL REFERENCES im_v2.messages(message_id),
    actor_user_id UUID NOT NULL,
    reaction TEXT NOT NULL CHECK (octet_length(reaction) > 0 AND octet_length(reaction) <= 64),
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (message_id, actor_user_id, reaction)
);

-- A retry returns the same room event even after membership changes. Reusing
-- an operation ID for different immutable reaction input is a conflict.
CREATE TABLE im_v2.message_reaction_operations (
    actor_user_id UUID NOT NULL,
    operation_id UUID NOT NULL,
    room_id UUID NOT NULL REFERENCES im_v2.rooms(room_id),
    message_id UUID NOT NULL REFERENCES im_v2.messages(message_id),
    reaction TEXT NOT NULL,
    action TEXT NOT NULL CHECK (action IN ('add', 'remove')),
    room_sequence BIGINT NOT NULL CHECK (room_sequence > 0),
    event_id UUID NOT NULL UNIQUE,
    plan_id UUID NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (actor_user_id, operation_id)
);

CREATE TABLE im_v2.room_events (
    event_id UUID PRIMARY KEY,
    room_id UUID NOT NULL REFERENCES im_v2.rooms(room_id),
    room_sequence BIGINT NOT NULL CHECK (room_sequence > 0),
    event_type TEXT NOT NULL,
    actor_user_id UUID NULL,
    payload JSONB NOT NULL,
    committed_membership_revision BIGINT NOT NULL CHECK (committed_membership_revision >= 0),
    created_at TIMESTAMPTZ NOT NULL,
    UNIQUE (room_id, room_sequence, event_type)
);

CREATE TABLE im_v2.fanout_plans (
    plan_id UUID PRIMARY KEY,
    source_event_id UUID NOT NULL UNIQUE REFERENCES im_v2.room_events(event_id),
    room_id UUID NOT NULL REFERENCES im_v2.rooms(room_id),
    source_room_sequence BIGINT NOT NULL CHECK (source_room_sequence > 0),
    committed_membership_revision BIGINT NOT NULL CHECK (committed_membership_revision >= 0),
    target_rule JSONB NOT NULL,
    enumeration_checkpoint JSONB NOT NULL,
    target_count BIGINT NULL CHECK (target_count IS NULL OR target_count >= 0),
    reserved_fanout_cost BIGINT NOT NULL CHECK (reserved_fanout_cost >= 0),
    state TEXT NOT NULL CHECK (state IN ('planning', 'planned', 'terminal')),
    created_at TIMESTAMPTZ NOT NULL,
    terminal_at TIMESTAMPTZ NULL
);
CREATE INDEX fanout_plans_pending_idx
    ON im_v2.fanout_plans (state, created_at) WHERE state <> 'terminal';

-- Some room events, notably a removal notification, have an immutable audience
-- that is not identical to membership at their committed revision. The source
-- transaction freezes those target users here before asynchronous planning.
CREATE TABLE im_v2.fanout_plan_targets (
    source_event_id UUID NOT NULL REFERENCES im_v2.room_events(event_id),
    target_user_id UUID NOT NULL,
    PRIMARY KEY (source_event_id, target_user_id)
);

CREATE TABLE im_v2.fanout_completion_units (
    source_event_id UUID NOT NULL REFERENCES im_v2.room_events(event_id),
    completion_unit_id UUID NOT NULL,
    target_boundary JSONB NOT NULL,
    target_count BIGINT NOT NULL CHECK (target_count >= 0),
    committed_target_count BIGINT NOT NULL DEFAULT 0 CHECK (committed_target_count >= 0),
    policy_skipped_target_count BIGINT NOT NULL DEFAULT 0 CHECK (policy_skipped_target_count >= 0),
    state TEXT NOT NULL CHECK (state IN ('pending', 'terminal', 'released')),
    lease_expires_at TIMESTAMPTZ NULL,
    retry_count BIGINT NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
    released_at TIMESTAMPTZ NULL,
    PRIMARY KEY (source_event_id, completion_unit_id),
    CHECK (committed_target_count + policy_skipped_target_count <= target_count),
    CHECK ((state = 'pending') OR (committed_target_count + policy_skipped_target_count = target_count)),
    CHECK ((state <> 'released') OR released_at IS NOT NULL)
);

CREATE TABLE im_v2.fanout_deliveries (
    source_event_id UUID NOT NULL,
    target_user_id UUID NOT NULL,
    projection_kind TEXT NOT NULL,
    completion_unit_id UUID NOT NULL,
    target_shard_bucket TEXT NOT NULL,
    observed_router_epoch BIGINT NOT NULL CHECK (observed_router_epoch >= 0),
    state TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'terminal')),
    claim_token UUID NULL,
    lease_expires_at TIMESTAMPTZ NULL,
    retry_count BIGINT NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
    diagnostic_terminal_reason TEXT NULL,
    PRIMARY KEY (source_event_id, target_user_id, projection_kind),
    FOREIGN KEY (source_event_id, completion_unit_id)
        REFERENCES im_v2.fanout_completion_units (source_event_id, completion_unit_id)
);
CREATE TABLE im_v2.room_outbox (
    source_event_id UUID PRIMARY KEY REFERENCES im_v2.room_events(event_id),
    plan_id UUID NOT NULL UNIQUE REFERENCES im_v2.fanout_plans(plan_id),
    state TEXT NOT NULL CHECK (state IN ('pending', 'published', 'terminal')),
    claim_token UUID NULL,
    lease_expires_at TIMESTAMPTZ NULL,
    retry_count BIGINT NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
    created_at TIMESTAMPTZ NOT NULL,
    terminal_at TIMESTAMPTZ NULL
);
CREATE INDEX room_outbox_claim_idx
    ON im_v2.room_outbox (state, lease_expires_at, created_at) WHERE state <> 'terminal';

CREATE TABLE im_v2.consumer_inbox (
    consumer_name TEXT NOT NULL,
    source_event_id UUID NOT NULL,
    target_user_id UUID NOT NULL,
    projection_kind TEXT NOT NULL,
    committed_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (consumer_name, source_event_id, target_user_id, projection_kind)
);

CREATE TABLE im_v2.user_sync_log (
    user_id UUID NOT NULL,
    user_sync_sequence BIGINT NOT NULL CHECK (user_sync_sequence > 0),
    source_event_id UUID NOT NULL,
    projection_kind TEXT NOT NULL,
    -- Fan-out rows may refer to one immutable payload held once per user
    -- shard.  Other projections remain self-contained inline rows.
    payload JSONB NULL,
    payload_storage TEXT NOT NULL DEFAULT 'inline'
        CHECK (payload_storage IN ('inline', 'fanout_shared')),
    created_at TIMESTAMPTZ NOT NULL,
    CHECK (
        (payload_storage = 'inline' AND payload IS NOT NULL)
        OR (payload_storage = 'fanout_shared' AND payload IS NULL)
    ),
    PRIMARY KEY (user_id, user_sync_sequence)
);
-- Fan-out has `consumer_inbox` as its durable semantic idempotency fence.
-- Keep source-event uniqueness for every other projection kind, whose writers
-- do not own that inbox record. New kinds default to this safer unique path.
CREATE UNIQUE INDEX user_sync_log_nonfanout_identity_idx
    ON im_v2.user_sync_log (user_id, source_event_id, projection_kind)
    WHERE projection_kind NOT IN ('message', 'membership', 'moderation', 'room');

-- The physical user shard owns this payload copy.  A fan-out sync row keeps
-- only its ordered per-user reference, while pull/snapshot joins the immutable
-- body back by the stable source-event projection identity.
CREATE TABLE im_v2.fanout_sync_payloads (
    source_event_id UUID NOT NULL,
    projection_kind TEXT NOT NULL,
    payload JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (source_event_id, projection_kind)
);

CREATE TABLE im_v2.user_sync_sequences (
    user_id UUID PRIMARY KEY,
    next_sequence BIGINT NOT NULL CHECK (next_sequence > 0)
);

-- Push is best-effort and never becomes a prerequisite for user_sync_log.
CREATE TABLE im_v2.push_campaigns (
    campaign_id TEXT PRIMARY KEY,
    state TEXT NOT NULL CHECK (state IN ('enabled', 'disabled')),
    updated_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE im_v2.push_device_budgets (
    device_id UUID NOT NULL,
    campaign_id TEXT NOT NULL REFERENCES im_v2.push_campaigns(campaign_id),
    window_started_at TIMESTAMPTZ NOT NULL,
    max_work_units BIGINT NOT NULL CHECK (max_work_units >= 0),
    used_work_units BIGINT NOT NULL DEFAULT 0 CHECK (used_work_units >= 0),
    max_new_key_operations BIGINT NOT NULL CHECK (max_new_key_operations >= 0),
    used_new_key_operations BIGINT NOT NULL DEFAULT 0 CHECK (used_new_key_operations >= 0),
    PRIMARY KEY (device_id, campaign_id, window_started_at),
    CHECK (used_work_units <= max_work_units),
    CHECK (used_new_key_operations <= max_new_key_operations)
);

CREATE TABLE im_v2.push_wake_outbox (
    dispatch_id UUID PRIMARY KEY,
    source_event_id UUID NOT NULL REFERENCES im_v2.room_events(event_id),
    target_user_id UUID NOT NULL,
    target_device_id UUID NOT NULL,
    campaign_id TEXT NOT NULL REFERENCES im_v2.push_campaigns(campaign_id),
    budget_window_started_at TIMESTAMPTZ NOT NULL,
    requires_new_key_operation BOOLEAN NOT NULL DEFAULT FALSE,
    state TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'claimed', 'sent', 'suppressed')),
    claim_token UUID NULL,
    lease_expires_at TIMESTAMPTZ NULL,
    retry_count BIGINT NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
    suppression_reason TEXT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    sent_at TIMESTAMPTZ NULL
);
CREATE INDEX push_wake_outbox_claim_idx
    ON im_v2.push_wake_outbox (state, lease_expires_at, created_at) WHERE state IN ('pending', 'claimed');

CREATE TABLE im_v2.device_sync_cursors (
    user_id UUID NOT NULL,
    device_id UUID NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('ready', 'reset_pending')),
    reset_generation BIGINT NOT NULL CHECK (reset_generation > 0),
    acknowledged_sequence BIGINT NOT NULL DEFAULT 0 CHECK (acknowledged_sequence >= 0),
    pending_snapshot_id UUID NULL,
    pending_base_sequence BIGINT NULL CHECK (pending_base_sequence IS NULL OR pending_base_sequence >= 0),
    pending_snapshot_expires_at TIMESTAMPTZ NULL,
    completed_snapshot_id UUID NULL,
    completed_snapshot_ack_receipt TEXT NULL,
    PRIMARY KEY (user_id, device_id),
    CHECK (
        (state = 'ready' AND pending_snapshot_id IS NULL AND pending_base_sequence IS NULL)
        OR
        (state = 'reset_pending' AND pending_snapshot_id IS NOT NULL AND pending_base_sequence IS NOT NULL)
    )
);

CREATE TABLE im_v2.sync_snapshots (
    snapshot_id UUID PRIMARY KEY,
    user_id UUID NOT NULL,
    device_id UUID NOT NULL,
    reset_generation BIGINT NOT NULL CHECK (reset_generation > 0),
    base_user_sync_sequence BIGINT NOT NULL CHECK (base_user_sync_sequence >= 0),
    manifest_digest TEXT NOT NULL,
    schema_version INTEGER NOT NULL CHECK (schema_version > 0),
    capability_profile TEXT NOT NULL,
    next_sync_token TEXT NOT NULL,
    sync_receipt TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('staged', 'acknowledged', 'invalidated')),
    created_at TIMESTAMPTZ NOT NULL,
    UNIQUE (user_id, device_id, reset_generation)
);

CREATE TABLE im_v2.sync_snapshot_pages (
    snapshot_id UUID NOT NULL REFERENCES im_v2.sync_snapshots(snapshot_id) ON DELETE RESTRICT,
    page_index INTEGER NOT NULL CHECK (page_index >= 0),
    page_digest TEXT NOT NULL,
    payload BYTEA NOT NULL,
    PRIMARY KEY (snapshot_id, page_index),
    UNIQUE (snapshot_id, page_digest)
);

-- Opaque, device-scoped capabilities. They are persisted rather than decoded
-- from client input, which keeps token/receipt validation fail-closed.
CREATE TABLE im_v2.sync_tokens (
    token TEXT PRIMARY KEY,
    user_id UUID NOT NULL,
    device_id UUID NOT NULL,
    reset_generation BIGINT NOT NULL CHECK (reset_generation > 0),
    watermark BIGINT NOT NULL CHECK (watermark >= 0),
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX sync_tokens_scope_idx
    ON im_v2.sync_tokens (user_id, device_id, reset_generation, expires_at);

CREATE TABLE im_v2.sync_receipts (
    receipt TEXT PRIMARY KEY,
    user_id UUID NOT NULL,
    device_id UUID NOT NULL,
    reset_generation BIGINT NOT NULL CHECK (reset_generation > 0),
    first_sequence BIGINT NOT NULL CHECK (first_sequence >= 0),
    last_sequence BIGINT NOT NULL CHECK (last_sequence >= first_sequence),
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX sync_receipts_scope_idx
    ON im_v2.sync_receipts (user_id, device_id, reset_generation, expires_at);

CREATE TABLE im_v2.public_profile_update_outbox (
    source_event_id UUID PRIMARY KEY,
    source_user_id UUID NOT NULL,
    public_handle TEXT NOT NULL,
    display_name TEXT NOT NULL,
    revision BIGINT NOT NULL CHECK (revision > 0),
    profile_updated_at TIMESTAMPTZ NOT NULL,
    state TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'claimed', 'completed')),
    claim_token UUID NULL,
    lease_expires_at TIMESTAMPTZ NULL,
    enumeration_checkpoint UUID NULL,
    retry_count BIGINT NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
    created_at TIMESTAMPTZ NOT NULL,
    completed_at TIMESTAMPTZ NULL,
    CHECK ((state = 'claimed') = (claim_token IS NOT NULL)),
    CHECK ((state = 'claimed') = (lease_expires_at IS NOT NULL)),
    CHECK ((state = 'completed') = (completed_at IS NOT NULL))
);
CREATE INDEX public_profile_update_outbox_claim_idx
    ON im_v2.public_profile_update_outbox (state, lease_expires_at, created_at)
    WHERE state <> 'completed';

-- The message command path locks rooms, room_admission, and the matching
-- shard_admission_pools row, validates an unexpired lease, and writes messages,
-- room_events, fanout_plans, and room_outbox in the same transaction.
