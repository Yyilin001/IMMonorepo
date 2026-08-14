-- Account disable is an identity lifecycle transition in addition to a
-- credential fence. Profile propagation carries the resulting state so
-- direct peers can invalidate cached presentation without publishing the
-- suspended identity as a fresh active profile.

ALTER TABLE im_v2.public_profile_update_outbox
    ADD COLUMN profile_state TEXT NOT NULL DEFAULT 'active'
        CHECK (profile_state IN ('active', 'deleted', 'suspended', 'hidden'));

CREATE INDEX public_user_profiles_active_handle_idx
    ON im_v2.public_user_profiles (public_handle)
    WHERE state = 'active';
