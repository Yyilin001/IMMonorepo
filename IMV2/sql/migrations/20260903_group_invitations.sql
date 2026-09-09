BEGIN;

CREATE TABLE im_v2.group_invite_links (
    invite_id uuid PRIMARY KEY,
    room_id uuid NOT NULL REFERENCES im_v2.group_rooms(room_id) ON DELETE CASCADE,
    created_by_user_id uuid NOT NULL REFERENCES im_v2.public_user_profiles(user_id),
    creation_operation_id uuid NOT NULL,
    token_digest bytea NOT NULL UNIQUE,
    requested_lifetime_seconds integer NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    maximum_approved_uses integer NOT NULL,
    approved_use_count integer NOT NULL DEFAULT 0,
    state text NOT NULL DEFAULT 'active',
    revocation_operation_id uuid,
    revoked_by_user_id uuid REFERENCES im_v2.public_user_profiles(user_id),
    revoked_at timestamp with time zone,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT group_invite_links_token_digest_check CHECK (octet_length(token_digest) = 32),
    CONSTRAINT group_invite_links_lifetime_check CHECK (requested_lifetime_seconds BETWEEN 300 AND 2592000),
    CONSTRAINT group_invite_links_expiry_check CHECK (expires_at > created_at),
    CONSTRAINT group_invite_links_use_count_check CHECK (maximum_approved_uses > 0 AND approved_use_count BETWEEN 0 AND maximum_approved_uses),
    CONSTRAINT group_invite_links_state_check CHECK (state IN ('active', 'revoked')),
    CONSTRAINT group_invite_links_revocation_check CHECK (
        (state = 'active' AND revocation_operation_id IS NULL AND revoked_by_user_id IS NULL AND revoked_at IS NULL)
        OR (state = 'revoked' AND revocation_operation_id IS NOT NULL AND revoked_by_user_id IS NOT NULL AND revoked_at IS NOT NULL)
    ),
    UNIQUE (created_by_user_id, creation_operation_id),
    CONSTRAINT group_invite_links_invite_room_key UNIQUE (invite_id, room_id)
);

CREATE INDEX group_invite_links_room_active_idx
    ON im_v2.group_invite_links (room_id, created_at DESC, invite_id DESC)
    WHERE state = 'active' AND approved_use_count < maximum_approved_uses;

CREATE TABLE im_v2.group_join_requests (
    request_id uuid PRIMARY KEY,
    invite_id uuid NOT NULL,
    room_id uuid NOT NULL REFERENCES im_v2.group_rooms(room_id) ON DELETE CASCADE,
    applicant_user_id uuid NOT NULL REFERENCES im_v2.public_user_profiles(user_id),
    submission_operation_id uuid NOT NULL,
    note text,
    state text NOT NULL DEFAULT 'pending',
    decision_operation_id uuid,
    decided_by_user_id uuid REFERENCES im_v2.public_user_profiles(user_id),
    approval_membership_revision bigint,
    decided_at timestamp with time zone,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT group_join_requests_note_check CHECK (note IS NULL OR octet_length(note) BETWEEN 1 AND 500),
    CONSTRAINT group_join_requests_state_check CHECK (state IN ('pending', 'approving', 'approved', 'rejected')),
    CONSTRAINT group_join_requests_decision_check CHECK (
        (state = 'pending' AND decision_operation_id IS NULL AND decided_by_user_id IS NULL AND approval_membership_revision IS NULL AND decided_at IS NULL)
        OR (state = 'approving' AND decision_operation_id IS NOT NULL AND decided_by_user_id IS NOT NULL AND approval_membership_revision IS NOT NULL AND decided_at IS NULL)
        OR (state = 'approved' AND decision_operation_id IS NOT NULL AND decided_by_user_id IS NOT NULL AND approval_membership_revision IS NOT NULL AND decided_at IS NOT NULL)
        OR (state = 'rejected' AND decision_operation_id IS NOT NULL AND decided_by_user_id IS NOT NULL AND approval_membership_revision IS NULL AND decided_at IS NOT NULL)
    ),
    CONSTRAINT group_join_requests_invite_room_fkey
        FOREIGN KEY (invite_id, room_id)
        REFERENCES im_v2.group_invite_links(invite_id, room_id) ON DELETE CASCADE,
    UNIQUE (applicant_user_id, submission_operation_id),
    UNIQUE (invite_id, applicant_user_id)
);

CREATE INDEX group_join_requests_room_pending_idx
    ON im_v2.group_join_requests (room_id, created_at, request_id)
    WHERE state IN ('pending', 'approving');
CREATE INDEX group_join_requests_applicant_pending_idx
    ON im_v2.group_join_requests (applicant_user_id, created_at)
    WHERE state IN ('pending', 'approving');
CREATE INDEX group_join_requests_invite_approving_idx
    ON im_v2.group_join_requests (invite_id)
    WHERE state = 'approving';

ALTER TABLE im_v2.schema_contract DROP CONSTRAINT schema_contract_schema_id_check;
ALTER TABLE im_v2.schema_contract ALTER COLUMN schema_id SET DEFAULT 'im-v2-current-5';
UPDATE im_v2.schema_contract SET schema_id = 'im-v2-current-5';
ALTER TABLE im_v2.schema_contract ADD CONSTRAINT schema_contract_schema_id_check CHECK (schema_id = 'im-v2-current-5');

COMMIT;
