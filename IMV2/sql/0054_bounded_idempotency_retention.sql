-- Protocol V18 defines a finite first-party retry window. Keep server replay
-- results beyond that window, then clean them in rotating, SKIP LOCKED
-- batches. These indexes prevent retention from becoming a full-table scan.

CREATE INDEX device_credential_operations_expiry_idx
    ON im_v2.device_credential_operations (replay_expires_at);
CREATE INDEX user_live_presence_leases_expiry_idx
    ON im_v2.user_live_presence_leases (expires_at, connection_id);
CREATE INDEX user_projection_effects_cleanup_idx
    ON im_v2.user_projection_effects
       (created_at, user_id, user_sync_sequence, source_event_id);

CREATE INDEX direct_room_operations_cleanup_idx ON im_v2.direct_room_operations (created_at);
CREATE INDEX user_relationship_operations_cleanup_idx ON im_v2.user_relationship_operations (updated_at);
CREATE INDEX user_block_operations_cleanup_idx ON im_v2.user_block_operations (updated_at);
CREATE INDEX stranger_message_preference_operations_cleanup_idx ON im_v2.stranger_message_preference_operations (updated_at);
CREATE INDEX room_membership_operations_cleanup_idx ON im_v2.room_membership_operations (created_at);
CREATE INDEX media_upload_operations_cleanup_idx ON im_v2.media_upload_operations (created_at);
CREATE INDEX message_withdrawal_operations_cleanup_idx ON im_v2.message_withdrawal_operations (created_at);
CREATE INDEX moderation_operations_cleanup_idx ON im_v2.moderation_operations (created_at);
CREATE INDEX message_edit_operations_cleanup_idx ON im_v2.message_edit_operations (created_at);
CREATE INDEX read_receipt_operations_cleanup_idx ON im_v2.read_receipt_operations (recorded_at);
CREATE INDEX message_reaction_operations_cleanup_idx ON im_v2.message_reaction_operations (created_at);
CREATE INDEX group_room_operations_cleanup_idx ON im_v2.group_room_operations (created_at);
CREATE INDEX public_profile_update_operations_cleanup_idx ON im_v2.public_profile_update_operations (created_at);
CREATE INDEX user_add_preference_operations_cleanup_idx ON im_v2.user_add_preference_operations (updated_at);
CREATE INDEX read_receipt_preference_operations_cleanup_idx ON im_v2.read_receipt_preference_operations (updated_at);
CREATE INDEX user_live_activity_preference_operations_cleanup_idx ON im_v2.user_live_activity_preference_operations (updated_at);
CREATE INDEX user_room_preference_operations_cleanup_idx ON im_v2.user_room_preference_operations (updated_at);
CREATE INDEX user_message_favorite_operations_cleanup_idx ON im_v2.user_message_favorite_operations (updated_at);
CREATE INDEX room_pinned_message_operations_cleanup_idx ON im_v2.room_pinned_message_operations (created_at);
CREATE INDEX group_announcement_operations_cleanup_idx ON im_v2.group_announcement_operations (created_at);
CREATE INDEX group_permission_operations_cleanup_idx ON im_v2.group_permission_operations (created_at);
CREATE INDEX group_role_operations_cleanup_idx ON im_v2.group_role_operations (created_at);
CREATE INDEX message_forward_operations_cleanup_idx ON im_v2.message_forward_operations (created_at);
CREATE INDEX device_session_operations_cleanup_idx ON im_v2.device_session_operations (created_at);
CREATE INDEX special_account_message_operations_cleanup_idx ON im_v2.special_account_message_operations (created_at);
CREATE INDEX user_contact_alias_operations_cleanup_idx ON im_v2.user_contact_alias_operations (created_at);
CREATE INDEX room_member_nickname_operations_cleanup_idx ON im_v2.room_member_nickname_operations (created_at);
