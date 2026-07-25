-- Repair the direct-profile propagation source as its own immutable
-- migration.  A pre-release revision had accidentally appended this table to
-- `0001_core.sql`; retained local volumes had already recorded 0001 and
-- could therefore never receive the table.  The IF NOT EXISTS forms make this
-- repair safe for those short-lived pre-release databases while all new
-- schemas receive the same final shape through this migration.

CREATE TABLE IF NOT EXISTS im_v2.public_profile_update_outbox (
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

CREATE INDEX IF NOT EXISTS public_profile_update_outbox_claim_idx
    ON im_v2.public_profile_update_outbox (state, lease_expires_at, created_at)
    WHERE state <> 'completed';
