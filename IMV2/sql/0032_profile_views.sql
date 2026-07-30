-- A viewer reads a normalized profile fact; it never receives a mutable name
-- copied into a message or a group membership row. Avatar media IDs point to
-- immutable, scanned media objects and are authorized at the media edge.

ALTER TABLE im_v2.public_user_profiles
    ADD COLUMN IF NOT EXISTS avatar_media_id UUID NULL REFERENCES im_v2.media_objects(media_id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS state TEXT NOT NULL DEFAULT 'active'
        CHECK (state IN ('active', 'deleted', 'suspended', 'hidden')),
    ADD COLUMN IF NOT EXISTS visibility_revision BIGINT NOT NULL DEFAULT 1
        CHECK (visibility_revision > 0);

CREATE INDEX IF NOT EXISTS public_user_profiles_active_avatar_idx
    ON im_v2.public_user_profiles (avatar_media_id)
    WHERE avatar_media_id IS NOT NULL;
