import Fluent
import Foundation
import SQLKit

/// The media edge may issue a transfer target only for a message projection
/// that was durably assigned to the requester.  Fan-out projections retain
/// their immutable payload once per source event, while control projections
/// keep an inline payload.  Keeping this lookup in one place prevents a new
/// payload representation from weakening (or accidentally denying) media
/// authorization at either the grant or claim fence.
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
                JOIN im_v2.message_media_references AS reference
                  ON reference.media_id = media.media_id
                JOIN im_v2.messages AS message
                  ON message.message_id = reference.message_id
                JOIN im_v2.rooms AS room
                  ON room.room_id = message.room_id
                JOIN im_v2.room_memberships AS membership
                  ON membership.room_id = room.room_id
                 AND membership.user_id = \(bind: requesterUserID)
                 AND membership.joined_revision <= room.membership_revision
                 AND (membership.left_revision IS NULL OR membership.left_revision > room.membership_revision)
                WHERE media.media_id = \(bind: mediaID)
                  AND media.state = 'available'
                  AND message.withdrawn_at IS NULL
                  AND reference.revoked_at IS NULL
                  AND EXISTS (
                      SELECT 1
                      FROM im_v2.auth_devices AS authenticated_device
                      WHERE authenticated_device.user_id = \(bind: requesterUserID)
                        AND authenticated_device.device_id = \(bind: deviceID)
                        AND authenticated_device.revoked_at IS NULL
                  )
                  AND EXISTS (
                      SELECT 1
                      FROM im_v2.user_sync_log AS delivery
                      LEFT JOIN im_v2.fanout_sync_payloads AS shared
                        ON shared.source_event_id = delivery.source_event_id
                       AND shared.projection_kind = delivery.projection_kind
                      WHERE delivery.user_id = \(bind: requesterUserID)
                        AND delivery.projection_kind = 'message'
                        AND (CASE WHEN delivery.payload_storage = 'inline'
                                  THEN delivery.payload ELSE shared.payload END)->>'event_type' = 'message.accepted'
                        AND (CASE WHEN delivery.payload_storage = 'inline'
                                  THEN delivery.payload ELSE shared.payload END)->>'message_id' = message.message_id::text
                        AND (CASE WHEN delivery.payload_storage = 'inline'
                                  THEN delivery.payload ELSE shared.payload END)->'media_ids' @> jsonb_build_array(media.media_id::text)
                  )
            ) AS authorized
            """).first(decoding: MediaVisibilityAuthorizationRow.self)?.authorized ?? false
    }
}

private struct MediaVisibilityAuthorizationRow: Decodable {
    let authorized: Bool
}
