import Fluent
import Foundation
import SQLKit

/// The media edge may issue a transfer target only for a message projection
/// that was durably assigned to the requester, or for an avatar whose profile
/// is currently visible to that requester. A shared message state never grants
/// access by itself: the requester must still hold a live user projection
/// reference. During migration, shared and inline payloads are both readable.
enum V2PostgresMediaVisibilityAuthorization {
    static func isAuthorized(
        mediaID: UUID,
        requesterUserID: UUID,
        deviceID: UUID,
        on sql: any SQLDatabase
    ) async throws -> Bool {
        try await sql.raw("""
            SELECT EXISTS (
                SELECT 1
                FROM im_v2.media_objects AS media
                WHERE media.media_id = \(bind: mediaID)
                  AND media.state = 'available'
                  AND EXISTS (
                      SELECT 1
                      FROM im_v2.auth_devices AS authenticated_device
                      WHERE authenticated_device.user_id = \(bind: requesterUserID)
                        AND authenticated_device.device_id = \(bind: deviceID)
                        AND authenticated_device.revoked_at IS NULL
                  )
                  AND (
                      EXISTS (
                          SELECT 1
                          FROM im_v2.message_media_references AS reference
                          JOIN im_v2.messages AS message
                            ON message.message_id = reference.message_id
                          JOIN im_v2.rooms AS room
                            ON room.room_id = message.room_id
                          JOIN im_v2.room_memberships AS membership
                            ON membership.room_id = room.room_id
                           AND membership.user_id = \(bind: requesterUserID)
                           AND membership.joined_revision <= room.membership_revision
                           AND (membership.left_revision IS NULL OR membership.left_revision > room.membership_revision)
                          WHERE reference.media_id = media.media_id
                            AND message.withdrawn_at IS NULL
                            AND reference.revoked_at IS NULL
                            -- Current projection state is the durable delivery
                            -- authority after incremental log compaction. A
                            -- withdrawn/redacted message closes this version,
                            -- so old media cannot be re-authorized.
                            AND EXISTS (
                                SELECT 1
                                FROM im_v2.user_projection_versions AS delivery
                                LEFT JOIN im_v2.message_projection_state_values AS state
                                  ON state.state_id = delivery.message_state_id
                                WHERE delivery.user_id = \(bind: requesterUserID)
                                  AND delivery.projection_kind = 'message'
                                  AND delivery.entity_key = message.message_id::text
                                  AND delivery.valid_to_sequence IS NULL
                                  AND COALESCE(state.payload, delivery.payload)->>'event_type' = 'message.accepted'
                                  AND COALESCE(
                                      (COALESCE(state.payload, delivery.payload)->>'is_withdrawn')::boolean,
                                      FALSE
                                  ) = FALSE
                                  AND COALESCE(state.payload, delivery.payload)->'media_ids'
                                      @> jsonb_build_array(media.media_id::text)
                            )
                      )
                      OR EXISTS (
                          SELECT 1
                          FROM im_v2.public_user_profiles AS profile
                          WHERE profile.avatar_media_id = media.media_id
                            AND profile.state = 'active'
                            AND NOT EXISTS (
                                SELECT 1
                                FROM im_v2.user_blocks AS block
                                WHERE (block.blocker_user_id = \(bind: requesterUserID)
                                       AND block.blocked_user_id = profile.user_id)
                                   OR (block.blocker_user_id = profile.user_id
                                       AND block.blocked_user_id = \(bind: requesterUserID))
                            )
                            AND (
                                profile.user_id = \(bind: requesterUserID)
                                OR EXISTS (
                                    SELECT 1
                                    FROM im_v2.user_relationships AS relationship
                                    WHERE relationship.state IN ('pending', 'accepted')
                                      AND ((relationship.lower_user_id = \(bind: requesterUserID)
                                            AND relationship.higher_user_id = profile.user_id)
                                        OR (relationship.higher_user_id = \(bind: requesterUserID)
                                            AND relationship.lower_user_id = profile.user_id))
                                )
                                OR EXISTS (
                                    SELECT 1
                                    FROM im_v2.rooms AS room
                                    JOIN im_v2.room_memberships AS requester_membership
                                      ON requester_membership.room_id = room.room_id
                                     AND requester_membership.user_id = \(bind: requesterUserID)
                                     AND requester_membership.joined_revision <= room.membership_revision
                                     AND (requester_membership.left_revision IS NULL OR requester_membership.left_revision > room.membership_revision)
                                    JOIN im_v2.room_memberships AS profile_membership
                                      ON profile_membership.room_id = room.room_id
                                     AND profile_membership.user_id = profile.user_id
                                     AND profile_membership.joined_revision <= room.membership_revision
                                     AND (profile_membership.left_revision IS NULL OR profile_membership.left_revision > room.membership_revision)
                                )
                            )
                      )
                  )
            ) AS authorized
            """).first(decoding: MediaVisibilityAuthorizationRow.self)?.authorized ?? false
    }
}

private struct MediaVisibilityAuthorizationRow: Decodable {
    let authorized: Bool
}
