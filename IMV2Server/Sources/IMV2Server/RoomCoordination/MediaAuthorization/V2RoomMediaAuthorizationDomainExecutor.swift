import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

/// Reads a message attachment's current room visibility during a granted
/// read turn. The media/control coordinator must also validate the device and
/// repeat this query before session exchange; this is not a provider grant.
public struct V2RoomMediaAuthorizationDomainExecutor: Sendable {
    private let database: any Database
    private let token: V2RoomActivationToken
    private let scope: V2RoomActivationWriteScope

    public init(database: any Database, token: V2RoomActivationToken) throws {
        self.database = database
        self.token = token
        self.scope = try .init(tokens: [token])
    }

    public func execute(_ query: V2RoomMediaAuthorizationQuery) async throws -> V2RoomMediaAuthorizationResult {
        guard query.roomID == token.roomID else {
            throw V2RoomActivationLeaseError.activationChanged
        }
        switch query {
        case .messageVisibility(let request):
            guard let room = request.roomID.uuidValue,
                  let message = request.messageID.uuidValue,
                  let media = request.mediaID.uuidValue,
                  let actor = request.actorUserID.uuidValue else {
                throw V2MediaStoreError.downloadNotAuthorized
            }
            return try await database.transaction { transaction in
                guard let sql = transaction as? any SQLDatabase else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                try await v2SetRoomActivationSQLTimeouts(.default, sql: sql)
                try await scope.require([room], sql: sql)
                let row = try await sql.raw("""
                    SELECT room.membership_revision, message.content_revision,
                           media.state_updated_at, media.upload_session_id
                    FROM im_v2.messages AS message
                    JOIN im_v2.rooms AS room ON room.room_id = message.room_id
                    JOIN im_v2.message_media_references AS reference
                      ON reference.message_id = message.message_id
                    JOIN im_v2.media_objects AS media ON media.media_id = reference.media_id
                    WHERE message.message_id = \(bind: message) AND message.room_id = \(bind: room)
                      AND media.media_id = \(bind: media) AND media.state = 'available'
                      AND reference.revoked_at IS NULL AND message.withdrawn_at IS NULL
                      AND \(v2ForwardSourceVisibility(actorID: actor))
                    FOR SHARE OF message, media
                    """).first(decoding: V2ActorMessageMediaVisibilityRow.self)
                guard let row else { return .notVisible }
                guard row.membershipRevision >= 0, row.contentRevision > 0,
                      row.mediaUpdatedAt.timeIntervalSince1970.isFinite else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                return .visible(.init(roomID: request.roomID, messageID: request.messageID,
                    mediaID: request.mediaID, membershipRevision: UInt64(row.membershipRevision),
                    contentRevision: UInt64(row.contentRevision),
                    mediaUpdatedAt: row.mediaUpdatedAt, uploadSessionID: row.uploadSessionID))
            }
        }
    }
}

private struct V2ActorMessageMediaVisibilityRow: Decodable {
    let membershipRevision: Int64
    let contentRevision: Int64
    let mediaUpdatedAt: Date
    let uploadSessionID: UUID

    enum CodingKeys: String, CodingKey {
        case membershipRevision = "membership_revision"
        case contentRevision = "content_revision"
        case mediaUpdatedAt = "state_updated_at"
        case uploadSessionID = "upload_session_id"
    }
}
