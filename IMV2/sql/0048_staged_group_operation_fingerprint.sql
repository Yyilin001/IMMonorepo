-- Staged group creation keeps its immutable audience in the normalized draft
-- relation. Persist only the audience kind and authoritative count in the
-- operation ledger instead of duplicating up to 100k UUIDs in one array row.
ALTER TABLE im_v2.group_room_operations
    ADD COLUMN audience_kind TEXT NOT NULL DEFAULT 'inline',
    ADD COLUMN initial_member_count INTEGER;

UPDATE im_v2.group_room_operations
SET initial_member_count = cardinality(initial_member_user_ids) + 1
WHERE initial_member_count IS NULL;

ALTER TABLE im_v2.group_room_operations
    ALTER COLUMN initial_member_count SET NOT NULL,
    ADD CONSTRAINT group_room_operations_audience_kind_check
        CHECK (audience_kind IN ('inline', 'staged')),
    ADD CONSTRAINT group_room_operations_initial_member_count_check
        CHECK (initial_member_count BETWEEN 1 AND 100000),
    ADD CONSTRAINT group_room_operations_audience_fingerprint_check
        CHECK (
            (audience_kind = 'inline'
             AND initial_member_count = cardinality(initial_member_user_ids) + 1)
            OR
            (audience_kind = 'staged'
             AND cardinality(initial_member_user_ids) = 0)
        );
