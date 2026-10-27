import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core
import IMV2ServerApplication
import IMV2ServerContracts
import SQLKit

extension PostgresV2RoomMediaAuthorizationAdapter {
    func resourceDirectory(_ request: V2ActorRoomResourceDirectoryWire) async throws -> V2RoomMediaAuthorizationResult {
        guard let roomID = request.roomID.uuidValue, let actorID = request.actorUserID.uuidValue else { throw V2MediaStoreError.downloadNotAuthorized }
        return try await ownedTransaction { transaction, _ in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            try await v2SetRoomActivationSQLTimeouts(.default, sql: sql)
            try await scope.require([roomID], sql: sql)
            // The room lock shares the membership/withdrawal serialization
            // boundary. Empty pages still require a current membership.
            guard let room = try await sql.raw("""
                SELECT room.room_sequence FROM im_v2.rooms room
                WHERE room.room_id=\(bind: roomID) AND EXISTS(
                    SELECT 1 FROM im_v2.room_memberships member WHERE member.room_id=room.room_id
                    AND member.user_id=\(bind: actorID) AND member.joined_revision<=room.membership_revision
                    AND (member.left_revision IS NULL OR member.left_revision>room.membership_revision))
                FOR SHARE OF room
                """).first(decoding: ResourceDirectoryRoomRow.self) else { return .notVisible }
            guard room.sequence >= 0 else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let upper = request.snapshotUpperRoomSequence ?? UInt64(room.sequence)
            guard upper <= UInt64(room.sequence) else { throw V2ResourceDirectoryError.invalidCursor }
            var predicate: SQLQueryString = "reference.room_id=\(bind: roomID) AND reference.room_sequence<=\(bind: Int64(upper))"
            if let before = request.before {
                guard let mediaID = before.mediaID.uuidValue else { throw V2ResourceDirectoryError.invalidCursor }
                predicate += " AND (reference.room_sequence,reference.ordinal,reference.media_id)<(\(bind: Int64(before.roomSequence)),\(bind: before.ordinal),\(bind: mediaID))"
            }
            if let before = request.query.before { predicate += " AND message.created_at<\(bind: Date(timeIntervalSince1970: Double(before)/1000))" }
            if let after = request.query.after { predicate += " AND message.created_at>=\(bind: Date(timeIntervalSince1970: Double(after + 1)/1000))" }
            switch request.query.category {
            case .all: break
            case .image: predicate += " AND media.content_type LIKE 'image/%'"
            case .video: predicate += " AND media.content_type LIKE 'video/%'"
            case .audio: predicate += " AND media.content_type LIKE 'audio/%'"
            case .file: predicate += " AND media.content_type NOT LIKE 'image/%' AND media.content_type NOT LIKE 'video/%' AND media.content_type NOT LIKE 'audio/%'"
            }
            let rows = try await sql.raw("""
                SELECT message.message_id,message.room_sequence,message.content_revision,message.created_at,
                    reference.ordinal,media.media_id,media.content_type,placement.byte_count,placement.sha256,
                    resource.display_name,resource.generation,resource.pixel_width,resource.pixel_height,resource.duration_ms
                FROM im_v2.message_media_references reference
                JOIN im_v2.messages message ON message.message_id=reference.message_id
                JOIN im_v2.rooms room ON room.room_id=message.room_id
                JOIN im_v2.media_objects media ON media.media_id=reference.media_id AND media.state='available'
                JOIN im_v2.resource_catalog resource ON resource.media_id=media.media_id
                    AND resource.home_kind='room' AND resource.home_id=room.room_id AND resource.usage_kind='message_attachment'
                JOIN im_v2.resource_blob_placements placement ON placement.media_id=resource.media_id
                    AND placement.generation=resource.generation AND placement.state='active'
                WHERE \(predicate) AND reference.revoked_at IS NULL AND message.withdrawn_at IS NULL
                    AND \(v2ForwardSourceVisibility(actorID: actorID))
                ORDER BY reference.room_sequence DESC,reference.ordinal DESC,reference.media_id DESC
                LIMIT \(bind: request.query.limit + 1)
                """).all(decoding: ResourceDirectoryItemRow.self)
            let items = try rows.prefix(request.query.limit).map { row in
                guard row.sequence > 0, row.revision > 0, row.createdAt.timeIntervalSince1970.isFinite,
                      row.createdAt.timeIntervalSince1970 >= 0, row.createdAt.timeIntervalSince1970 <= 253_402_300_799 else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                let descriptor = try V2ResourceDescriptor(key: .init(home: .room(request.roomID), mediaID: .init(uuid: row.mediaID)),
                    revision: row.generation, displayName: .init(row.displayName), contentType: row.contentType,
                    byteCount: row.byteCount, checksum: .init(value: row.sha256.map { String(format: "%02x", $0) }.joined()), state: .ready, pixelWidth: row.pixelWidth, pixelHeight: row.pixelHeight, durationMilliseconds: row.durationMilliseconds)
                return try V2RoomResourceItem(messageID: .init(uuid: row.messageID), messageRevision: UInt64(row.revision),
                    position: .init(roomSequence: UInt64(row.sequence), ordinal: row.ordinal, mediaID: descriptor.key.mediaID),
                    createdAt: Int64((row.createdAt.timeIntervalSince1970 * 1000).rounded(.down)), descriptor: descriptor)
            }
            return .resourceDirectory(try .init(items: items, snapshotUpperRoomSequence: upper, hasMore: rows.count > request.query.limit))
        }
    }
}

private struct ResourceDirectoryRoomRow: Decodable {
    let sequence: Int64
    enum CodingKeys: String, CodingKey { case sequence = "room_sequence" }
}
private struct ResourceDirectoryItemRow: Decodable {
    let messageID: UUID; let sequence: Int64; let revision: Int64; let createdAt: Date
    let ordinal: Int; let mediaID: UUID; let contentType: String; let byteCount: Int64; let sha256: Data
    let displayName: String; let generation: Int64
    let pixelWidth: Int?; let pixelHeight: Int?; let durationMilliseconds: Int64?
    enum CodingKeys: String, CodingKey {
        case messageID = "message_id", sequence = "room_sequence", revision = "content_revision", createdAt = "created_at"
        case ordinal, mediaID = "media_id", contentType = "content_type", byteCount = "byte_count", sha256
        case displayName = "display_name", generation, pixelWidth = "pixel_width", pixelHeight = "pixel_height", durationMilliseconds = "duration_ms"
    }
}
