-- A message is reviewable only after its acceptance transaction commits. The
-- job carries a content revision so a late verdict can never redact an edit.
CREATE TABLE im_v2.content_review_jobs (
    message_id UUID PRIMARY KEY REFERENCES im_v2.messages(message_id) ON DELETE CASCADE,
    room_id UUID NOT NULL REFERENCES im_v2.rooms(room_id) ON DELETE CASCADE,
    expected_content_revision BIGINT NOT NULL CHECK (expected_content_revision > 0),
    state TEXT NOT NULL CHECK (state IN ('pending', 'claimed', 'completed', 'superseded')),
    decision TEXT NULL CHECK (decision IS NULL OR decision IN ('clear', 'review_required', 'violation')),
    claim_token UUID NULL,
    lease_expires_at TIMESTAMPTZ NULL,
    retry_count INTEGER NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
    created_at TIMESTAMPTZ NOT NULL,
    completed_at TIMESTAMPTZ NULL,
    CHECK ((state = 'claimed') = (claim_token IS NOT NULL AND lease_expires_at IS NOT NULL))
);
CREATE INDEX content_review_jobs_claim_idx ON im_v2.content_review_jobs (state, lease_expires_at, created_at, message_id);

CREATE TABLE im_v2.content_review_decisions (
    message_id UUID PRIMARY KEY REFERENCES im_v2.messages(message_id) ON DELETE CASCADE,
    decision TEXT NOT NULL CHECK (decision IN ('clear', 'review_required', 'violation')),
    policy_version TEXT NOT NULL CHECK (octet_length(policy_version) BETWEEN 1 AND 64),
    decided_at TIMESTAMPTZ NOT NULL
);
CREATE TABLE im_v2.content_review_findings (
    message_id UUID NOT NULL REFERENCES im_v2.messages(message_id) ON DELETE CASCADE,
    category TEXT NOT NULL CHECK (octet_length(category) BETWEEN 1 AND 64),
    severity SMALLINT NOT NULL CHECK (severity BETWEEN 0 AND 4),
    confidence DOUBLE PRECISION NOT NULL CHECK (confidence >= 0 AND confidence <= 1),
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (message_id, category)
);
CREATE TABLE im_v2.content_review_cases (
    message_id UUID PRIMARY KEY REFERENCES im_v2.messages(message_id) ON DELETE CASCADE,
    status TEXT NOT NULL CHECK (status IN ('open', 'resolved')),
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL
);
