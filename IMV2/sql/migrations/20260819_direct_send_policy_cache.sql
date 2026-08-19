BEGIN;

ALTER TABLE im_v2.direct_room_pairs
    ADD COLUMN IF NOT EXISTS lower_has_replied boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS higher_has_replied boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS direct_policy_revision bigint NOT NULL DEFAULT 1;

ALTER TABLE im_v2.direct_room_pairs
    DROP CONSTRAINT IF EXISTS direct_room_pairs_direct_policy_revision_check,
    ADD CONSTRAINT direct_room_pairs_direct_policy_revision_check
        CHECK (direct_policy_revision > 0);

CREATE TABLE IF NOT EXISTS im_v2.user_direct_send_policy_versions (
    user_id uuid PRIMARY KEY,
    revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
    updated_at timestamp with time zone NOT NULL DEFAULT now()
);

-- Preserve the current stranger-message semantics for existing rooms before
-- the hot path starts reading pair-local markers instead of scanning messages.
UPDATE im_v2.direct_room_pairs AS pair
SET lower_has_replied = EXISTS (
        SELECT 1 FROM im_v2.messages AS message
        WHERE message.room_id = pair.room_id
          AND message.sender_user_id = pair.lower_user_id
    ),
    higher_has_replied = EXISTS (
        SELECT 1 FROM im_v2.messages AS message
        WHERE message.room_id = pair.room_id
          AND message.sender_user_id = pair.higher_user_id
    );

INSERT INTO im_v2.user_direct_send_policy_versions (user_id)
SELECT user_id
FROM (
    SELECT lower_user_id AS user_id FROM im_v2.direct_room_pairs
    UNION
    SELECT higher_user_id AS user_id FROM im_v2.direct_room_pairs
) AS direct_users
ON CONFLICT (user_id) DO NOTHING;

COMMIT;
