import Fluent
import Foundation
import SQLKit

/// The media edge may issue a transfer target only for a message projection
/// that was durably assigned to the requester, or for an avatar whose profile
/// is currently visible to that requester. A shared message state never grants
/// access by itself: the requester must still hold a live user projection
/// reference plus current and historical content authorization. A stale
/// projection alone is insufficient. Shared and inline payloads are readable.
enum V2PostgresMediaVisibilityAuthorization {
    static func isAuthorized(
        mediaID: UUID,
        requesterUserID: UUID,
        deviceID: UUID,
        on sql: any SQLDatabase
    ) async throws -> Bool {
        let predicate = predicate(
            mediaID: "\(bind: mediaID)",
            requesterUserID: requesterUserID,
            deviceID: deviceID
        )
        return try await sql.raw("""
            SELECT \(predicate) AS authorized
            """).first(decoding: MediaVisibilityAuthorizationRow.self)?.authorized ?? false
    }

    /// Shared SQL predicate used by both read-only checks and atomic grant
    /// claims. The media expression is composed by trusted server code; every
    /// caller-controlled identifier remains a bind parameter.
    static func predicate(
        mediaID: SQLQueryString,
        requesterUserID: UUID,
        deviceID: UUID
    ) -> SQLQueryString {
        """
            EXISTS (
                SELECT 1
                FROM im_v2.media_objects AS media
                WHERE media.media_id = \(mediaID)
                  AND media.state = 'available'
                  AND EXISTS (
                      SELECT 1
                      FROM im_v2.auth_devices AS authenticated_device
                      JOIN im_v2.public_user_profiles AS authenticated_profile
                        ON authenticated_profile.user_id = authenticated_device.user_id
                       AND authenticated_profile.state = 'active'
                      WHERE authenticated_device.user_id = \(bind: requesterUserID)
                        AND authenticated_device.device_id = \(bind: deviceID)
                        AND authenticated_device.revoked_at IS NULL AND authenticated_device.session_expires_at > clock_timestamp()
                        AND NOT EXISTS (
                            SELECT 1 FROM im_v2.account_disables AS disabled
                            WHERE disabled.user_id = authenticated_device.user_id
                        )
                  )
                  AND (
                      EXISTS (
                          SELECT 1
                          FROM im_v2.message_media_references AS reference
                          JOIN im_v2.messages AS message
                            ON message.message_id = reference.message_id
                          JOIN im_v2.rooms AS room
                            ON room.room_id = message.room_id
                          WHERE reference.media_id = media.media_id
                            AND message.withdrawn_at IS NULL
                            AND reference.revoked_at IS NULL
                            AND (\(v2ForwardSourceVisibility(actorID: requesterUserID)))
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
                                  AND delivery.entity_key IN (message.message_id::text, upper(message.message_id::text))
                                  AND delivery.valid_to_sequence IS NULL
                                  AND delivery.scope_room_id = message.room_id
                                  AND lower(COALESCE(state.payload, delivery.payload)->>'message_id') = message.message_id::text
                                  AND lower(COALESCE(state.payload, delivery.payload)->>'room_id') = message.room_id::text
                                  AND COALESCE(state.payload, delivery.payload)->>'event_type' = 'message.accepted'
                                  AND COALESCE(
                                      (COALESCE(state.payload, delivery.payload)->>'is_withdrawn')::boolean,
                                      FALSE
                                  ) = FALSE
                                  AND (COALESCE(state.payload, delivery.payload)->'media_ids'
                                      @> jsonb_build_array(media.media_id::text)
                                    OR COALESCE(state.payload, delivery.payload)->'media_ids'
                                      @> jsonb_build_array(upper(media.media_id::text)))
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
            )
            """
    }
}

private struct MediaVisibilityAuthorizationRow: Decodable {
    let authorized: Bool
}
